# =========================================
# XGBoost playoff odds, 2026 WNBA playoffs
# =========================================
# xgboost predicts the home team's chance of winning one game from what both teams had done
# before it. trained on 2003-2023, tuned on 2024-25, tested on 2026 against elo, then used to
# simulate the rest of the playoffs.

library(wehoop)
library(dplyr)
library(tidyr)
library(ggplot2)
library(xgboost) 

# odds as of the end of this date (games are dated in local time). 2026-10-02 is the end of the
# first round and reproduces the README. set it to Sys.Date() to use every game played so far
as_of <- as.Date("2026-10-02")

# ============================
# Data & cleaning: one row per team per game
# ============================
box      <- as_tibble(load_wnba_team_box(seasons = 2003:2026))
schedule <- as_tibble(load_wnba_schedule(seasons = 2003:2026))

# playoff games that have tipped off but aren't in the nightly data yet (this part is a little extra)
new_ids <- schedule %>%
  filter(season == 2026, season_type == 3, home_abbreviation != "TBD", !game_id %in% box$game_id,
         as.POSIXct(date, format = "%Y-%m-%dT%H:%MZ", tz = "UTC") < Sys.time()) %>%
  pull(game_id)

for (id in new_ids) {
  b <- tryCatch(as_tibble(espn_wnba_team_box(game_id = id)), error = function(e) NULL)
  if (any(b[["team_winner"]] %in% TRUE)) box <- bind_rows(box, b)   # only games that are final
  else message("skipping game ", id, ": not final yet (or ESPN has no box score)")
}

cup_final  <- schedule$game_id[schedule$notes_headline %in% "WNBA Commissioner's Cup Championship"]
real_teams <- box %>% count(season, team_id) %>% filter(n >= 10)    # drops all star teams

team_games <- box %>%
  distinct(game_id, team_id, .keep_all = TRUE) %>%
  filter(!game_id %in% cup_final) %>%
  semi_join(real_teams, by = c("season", "team_id")) %>%
  semi_join(real_teams, by = c("season", opponent_team_id = "team_id")) %>%
  transmute(game_id, season, season_type, game_date = as.Date(game_date),
            team_id, team = team_display_name, abbr = team_abbreviation,
            opp_id = opponent_team_id, home = team_home_away == "home",
            pts = team_score, fgm = field_goals_made, fga = field_goals_attempted,
            fg3m = three_point_field_goals_made, ftm = free_throws_made, fta = free_throws_attempted,
            orb = offensive_rebounds, drb = defensive_rebounds, tov = total_turnovers) %>%
  filter(game_date <= as_of)

# put the opponent's numbers on the same row
count_cols <- c("pts", "fgm", "fga", "fg3m", "ftm", "fta", "orb", "drb", "tov")

team_games <- team_games %>%
  left_join(team_games %>%
              select(game_id, opp_id = team_id, all_of(count_cols)) %>%
              rename_with(~ paste0("opp_", .x), all_of(count_cols)),
            by = c("game_id", "opp_id")) %>%
  mutate(margin = pts - opp_pts,
         poss   = 0.5 * ((fga - orb + tov + 0.44 * fta) + (opp_fga - opp_orb + opp_tov + 0.44 * opp_fta))) #basic possessions calc

total_cols <- c(count_cols, paste0("opp_", count_cols), "poss")

# ============================
# Features: what each team had done before the game
# ============================
# net rating and the four factors from totals over any stretch of games
rates <- function(d) {
  with(d, tibble(
    net     = 100 * (pts - opp_pts) / poss,              # point margin per 100 possessions
    efg_off = (fgm + 0.5 * fg3m) / fga,                  # offense
    tov_off = tov / poss,
    orb_off = orb / (orb + opp_drb),
    ftr_off = ftm / fga,
    efg_def = (opp_fgm + 0.5 * opp_fg3m) / opp_fga,      # defense
    tov_def = opp_tov / poss,
    drb_def = drb / (drb + opp_orb),
    ftr_def = opp_ftm / opp_fga
  ))
}

before_game <- function(x) lag(cumsum(x), default = 0)   # totals from the games before this one
last_10     <- function(x) before_game(x) - lag(before_game(x), 10, default = 0)

# last season's net rating. team_id stays with a franchise when it moves
season_end <- team_games %>%
  group_by(team_id, season) %>%
  summarise(net_prev = 100 * (sum(pts) - sum(opp_pts)) / sum(poss), .groups = "drop") %>%
  mutate(season = season + 1)

pregame <- team_games %>%
  arrange(game_date) %>%
  group_by(team_id, season) %>%
  mutate(gp         = row_number() - 1,
         rest       = pmin(coalesce(as.numeric(game_date - lag(game_date)), 4), 4),   # days, capped at 4
         net_last10 = 100 * (last_10(pts) - last_10(opp_pts)) / last_10(poss),
         across(all_of(total_cols), before_game)) %>%
  ungroup() %>%
  mutate(rates(.)) %>%
  left_join(season_end, by = c("team_id", "season"))

# the model sees home minus away for each stat, the smaller of the two games played counts, and
# the season (home teams won 62% of games in 2003-09 and 54% since 2021)
gap_stats <- c("net", "net_last10", "net_prev", "efg_off", "tov_off", "orb_off", "ftr_off",
               "efg_def", "tov_def", "drb_def", "ftr_def", "rest")
features  <- c(paste0(gap_stats, "_gap"), "gp_min", "season")

matchup <- function(h, a) {
  out <- as_tibble(setNames(lapply(gap_stats, function(s) h[[s]] - a[[s]]), paste0(gap_stats, "_gap")))
  out$gp_min <- pmin(h$gp, a$gp)
  out
}

home_rows <- pregame %>% filter(home) %>% arrange(game_id)
away_rows <- pregame %>% filter(!home) %>% arrange(game_id)

games <- home_rows %>%
  transmute(game_id, season, season_type, game_date,
            home = team, away = away_rows$team, margin, home_win = as.numeric(margin > 0)) %>%
  bind_cols(matchup(home_rows, away_rows)) %>%
  arrange(game_date) %>%
  # the games we score: regular season, after the first third (same as tune-k.R)
  group_by(season) %>%
  mutate(scored = season_type == 2 &
           game_date >= sort(game_date[season_type == 2])[round(sum(season_type == 2) / 3) + 1]) %>%
  ungroup()

# ============================
# Elo, for comparison (same as elo-playoff-sim: margin of victory, K = 30, 1500 start in 2026)
# ============================
K <- 30

elo_prob <- function(gap) 1 / (1 + 10^(-gap / 400))
hca_from <- function(g) 400 * log10(mean(g$home_win) / (1 - mean(g$home_win)))

# home team's pregame win probability for each game, and the ratings after the last one
run_elo <- function(g, HCA) {
  teams <- sort(unique(c(g$home, g$away)))
  elo <- setNames(rep(1500, length(teams)), teams)
  p <- numeric(nrow(g))
  for (i in seq_len(nrow(g))) {
    h <- g$home[i]
    a <- g$away[i]
    diff_home   <- elo[h] + HCA - elo[a]
    p[i]        <- elo_prob(diff_home)
    diff_winner <- if (g$home_win[i] == 1) diff_home else -diff_home
    mult <- (abs(g$margin[i]) + 3)^0.8 / (7.5 + 0.006 * diff_winner)
    elo[h] <- elo[h] + K * mult * (g$home_win[i] - p[i])
    elo[a] <- elo[a] - K * mult * (g$home_win[i] - p[i])
  }
  list(p = p, elo = elo)
}

# ============================
# XGBoost
# ============================
to_dmatrix <- function(d) xgb.DMatrix(as.matrix(d[features]), label = d$home_win)

# a better net rating should never lower a team's chances, and the same for each four factor
monotone <- c(net_gap = 1, net_last10_gap = 1, net_prev_gap = 1,
              efg_off_gap = 1, tov_off_gap = -1, orb_off_gap = 1, ftr_off_gap = 1,
              efg_def_gap = -1, tov_def_gap = 1, drb_def_gap = 1, ftr_def_gap = -1,
              rest_gap = 0, gp_min = 0, season = 0)

params <- xgb.params(objective = "binary:logistic",
                     eval_metric = "logloss",
                     learning_rate = 0.02,        # each tree adds 2% of its correction
                     max_depth = 3,               # up to 3 yes/no questions per tree
                     min_child_weight = 25,       # roughly 100+ games in every leaf
                     subsample = 0.8,             # each tree sees a random 80% of games
                     colsample_bytree = 0.8,      # and 80% of the stats
                     monotone_constraints = unname(monotone[features]),
                     seed = 2026, nthread = 1)

# 2020 was played in the bubble, so it has no real home teams
train_tune <- games %>% filter(season <= 2023, season != 2020)
valid      <- games %>% filter(season %in% 2024:2025, scored)

# how many trees: keep adding them until predictions for 2024-25 stop improving.
# (max_depth 1-3 and min_child_weight 5 or 25 all finished within 0.005 log loss here)
tune <- xgb.train(params, to_dmatrix(train_tune), nrounds = 3000,
                  evals = list(valid = to_dmatrix(valid)), early_stopping_rounds = 200, verbose = 0)
n_trees <- xgb.attr(tune, "best_iteration") + 1   # best_iteration counts from 0
n_trees

# ============================
# Test: train on 2003-2025, score 2026 once
# ============================
xgb_test <- xgb.train(params, to_dmatrix(games %>% filter(season <= 2025, season != 2020)),
                      nrounds = n_trees)

reg_2026 <- games %>% filter(season == 2026, season_type == 2)
elo_2026 <- run_elo(reg_2026, hca_from(games %>% filter(season %in% 2024:2025, season_type == 2)))

test <- games %>%
  filter(season == 2026, scored) %>%
  mutate(p_xgboost = predict(xgb_test, to_dmatrix(.)),
         p_elo     = elo_2026$p[match(game_id, reg_2026$game_id)])

game_loss <- function(p) -(test$home_win * log(p) + (1 - test$home_win) * log(1 - p))

model_test <- tibble(model    = c("elo", "xgboost"),
                     log_loss = c(mean(game_loss(test$p_elo)), mean(game_loss(test$p_xgboost))))
model_test

# z for the difference: |z| under 2 means no real difference
d <- game_loss(test$p_xgboost) - game_loss(test$p_elo)
mean(d) / (sd(d) / sqrt(length(d)))

# ============================
# Final model: every game through 'tonight' (whatever day that is :))
# ============================
xgb_final  <- xgb.train(params, to_dmatrix(games %>% filter(season != 2020)), nrounds = n_trees)
importance <- xgb.importance(xgb_final)
importance

# ============================
# Playoff simulation
# ============================
# 2026 format: fixed bracket, 1v8 and 4v5 on one side, 2v7 and 3v6 on the other
#   first round  best of 3, higher seed hosts games 1, 3
#   semifinals   best of 5, higher seed hosts games 1, 2, 5
#   finals       best of 7, higher seed hosts games 1, 2, 5, 7
seeds <- c("Minnesota Lynx", "Golden State Valkyries", "Las Vegas Aces", "Atlanta Dream",
           "Washington Mystics", "Indiana Fever", "Dallas Wings", "New York Liberty")

# home advantages
first_round <- c(TRUE, FALSE, TRUE)                          # TRUE = higher seed at home
semifinals  <- c(TRUE, TRUE, FALSE, FALSE, TRUE)
finals      <- c(TRUE, TRUE, FALSE, FALSE, TRUE, FALSE, TRUE)

# each playoff team's stats over all of its 2026 games so far
current <- team_games %>%
  filter(season == 2026) %>%
  arrange(game_date) %>%
  group_by(team_id, team) %>%
  summarise(gp         = n(),
            net_last10 = 100 * (sum(tail(pts, 10)) - sum(tail(opp_pts, 10))) / sum(tail(poss, 10)),
            across(all_of(total_cols), sum),
            .groups = "drop") %>%
  mutate(rates(.), rest = 2) %>%                             # even rest for future games
  left_join(season_end %>% filter(season == 2026), by = "team_id")

current <- current[match(seeds, current$team), ]

# P[i, j] = chance seed i beats seed j with i at home
pairs <- expand_grid(i = 1:8, j = 1:8) %>% filter(i != j)

P_xgboost <- matrix(NA, 8, 8)
P_xgboost[cbind(pairs$i, pairs$j)] <- predict(xgb_final, to_dmatrix(
  matchup(current[pairs$i, ], current[pairs$j, ]) %>% mutate(season = 2026, home_win = NA)))

# elo through the regular season and the playoffs so far, home court from 2026 (as in elo-sim.R)
elo_now <- run_elo(games %>% filter(season == 2026), hca_from(reg_2026))

P_elo <- matrix(NA, 8, 8)
P_elo[cbind(pairs$i, pairs$j)] <- elo_prob(elo_now$elo[seeds[pairs$i]] - elo_now$elo[seeds[pairs$j]] +
                                             hca_from(reg_2026))

# playoff wins so far. in a fixed bracket two teams can only meet in one round
playoff_results <- games %>%
  filter(season == 2026, season_type == 3) %>%
  transmute(winner = ifelse(home_win == 1, home, away), loser = ifelse(home_win == 1, away, home))
playoff_results

wins_vs <- function(a, b) sum(playoff_results$winner == a & playoff_results$loser == b)

# chance the higher seed i beats j from the current series score. pretend every remaining game
# gets played: the higher seed wins the series exactly when it reaches a majority
p_series <- function(P, i, j, pattern) {
  need      <- ceiling(length(pattern) / 2)
  high_wins <- wins_vs(seeds[i], seeds[j])
  low_wins  <- wins_vs(seeds[j], seeds[i])
  if (high_wins >= need) return(1)
  if (low_wins >= need) return(0)
  left <- pattern[(high_wins + low_wins + 1):length(pattern)]
  p <- ifelse(left, P[i, j], 1 - P[j, i])                   # one win probability per game left
  wins <- 1                                                 # wins[w + 1] = P(w more wins)
  for (pg in p) wins <- c(wins * (1 - pg), 0) + c(0, wins * pg)
  sum(wins[(need - high_wins + 1):(length(p) + 1)])
}

simulate_playoffs <- function(P, n_sims = 100000) {
  series_matrix <- function(pattern) {
    outer(1:8, 1:8, Vectorize(function(i, j) if (i < j) p_series(P, i, j, pattern) else NA))
  }
  P_first  <- series_matrix(first_round)
  P_semi   <- series_matrix(semifinals)
  P_finals <- series_matrix(finals)

  play <- function(a, b, S) {                               # a, b: seed numbers, one per simulation
    high <- pmin(a, b)
    low  <- pmax(a, b)
    ifelse(runif(length(a)) < S[cbind(high, low)], high, low)
  }

  set.seed(2026)
  w18 <- play(rep(1, n_sims), rep(8, n_sims), P_first)
  w45 <- play(rep(4, n_sims), rep(5, n_sims), P_first)
  w27 <- play(rep(2, n_sims), rep(7, n_sims), P_first)
  w36 <- play(rep(3, n_sims), rep(6, n_sims), P_first)

  finalist_1 <- play(w18, w45, P_semi)
  finalist_2 <- play(w27, w36, P_semi)
  champion   <- play(finalist_1, finalist_2, P_finals)

  tibble(seed   = 1:8,
         team   = seeds,
         semis  = sapply(1:8, function(s) mean(w18 == s | w45 == s | w27 == s | w36 == s)),
         finals = sapply(1:8, function(s) mean(finalist_1 == s | finalist_2 == s)),
         title  = sapply(1:8, function(s) mean(champion == s)))
}

odds <- simulate_playoffs(P_xgboost) %>%
  mutate(title_elo = simulate_playoffs(P_elo)$title)
odds








# ================================================================================================================
# Charts
# ================================================================================================================
VIOLET <- "#AD96DC"   # valkyrie violet
GOLD   <- "#B9975B"   # valkyries gold
GRAY   <- "#8A8A86"
INK    <- "#010101"
CREDIT <- "xgboost model trained on WNBA games since 2003  |  chart: @wnbadata\ndata: wehoop"

base_theme <- function() {
  theme_minimal(base_size = 15) +
    theme(
      plot.title.position   = "plot",
      plot.caption.position = "plot",
      plot.title    = element_text(face = "bold", colour = INK, size = 19),
      plot.subtitle = element_text(colour = GRAY, size = 13, margin = margin(b = 14)),
      plot.caption  = element_text(colour = GRAY, size = 11, hjust = 0, margin = margin(t = 14)),
      axis.text     = element_text(colour = INK, size = 13),
      axis.title    = element_text(colour = GRAY, size = 12),
      panel.grid.minor   = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_line(colour = "#E3E3E0", linewidth = 0.3),
      plot.margin   = margin(18, 18, 14, 10)
    )
}

seed_labels <- tibble(seed = 1:8, team = seeds) %>%
  left_join(team_games %>% filter(season == 2026) %>% distinct(team, abbr), by = "team") %>%
  mutate(label = paste(seed, abbr))

# ----------------------------
# 1. how the models did on 2026
# ----------------------------
ggplot(model_test, aes(y = model, x = log_loss, fill = model)) +
  geom_col(width = 0.5) +
  geom_text(aes(label = sprintf("%.3f", log_loss)), hjust = -0.2, colour = INK, size = 5.5, fontface = "bold") +
  scale_fill_manual(values = c(xgboost = VIOLET, elo = GOLD), guide = "none") +
  scale_x_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(title = "how well each model predicted 2026",
       subtitle = sprintf("log loss on %d games after the first third of the season\n(lower is better, a coin flip is 0.693)", nrow(test)),
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme()

# ----------------------------
# 2. what the model leans on
# ----------------------------
stat_names <- c(net_gap = "net rating, this season", net_last10_gap = "net rating, last 10 games",
                net_prev_gap = "net rating, last season", efg_off_gap = "shooting (eFG%)",
                tov_off_gap = "turnovers committed", orb_off_gap = "offensive rebounding",
                ftr_off_gap = "free throw rate", efg_def_gap = "opponent shooting",
                tov_def_gap = "turnovers forced", drb_def_gap = "defensive rebounding",
                ftr_def_gap = "opponent free throw rate", rest_gap = "days of rest",
                gp_min = "games played so far this season", season = "year (home court has shrunk)")

importance_plot_data <- importance %>%
  mutate(stat = factor(stat_names[Feature], levels = rev(stat_names[Feature])))

ggplot(importance_plot_data, aes(y = stat, x = Gain)) +
  geom_col(fill = VIOLET, width = 0.6) +
  geom_text(aes(label = scales::percent(Gain, accuracy = 1)), hjust = -0.2, colour = INK, size = 4.5) +
  scale_x_continuous(labels = scales::percent, expand = expansion(mult = c(0, 0.12))) +
  labs(title = "stats xgboost uses",
       subtitle = "share of the model's improvement from each stat (gain)\n(every stat is home team minus away team)",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme()

# ----------------------------
# 4. title odds, xgboost vs elo
# ----------------------------
# a table of both models' title odds. rows where they disagree by 10+ points are highlighted,
# shading whichever model is higher
title_table <- odds %>%
  filter(title > 0 | title_elo > 0) %>%                     # teams still alive
  left_join(seed_labels %>% select(seed, label), by = "seed") %>%
  mutate(xgb       = round(100 * title),
         elo       = round(100 * title_elo),
         gap       = xgb - elo,
         highlight = abs(gap) >= 10,
         label     = factor(label, levels = rev(label)))

title_cells <- bind_rows(
  title_table %>% transmute(label, highlight, col = "xgboost", text = paste0(xgb, "%"),
                            shade = ifelse(highlight & gap > 0, "xgboost", "none")),
  title_table %>% transmute(label, highlight, col = "elo", text = paste0(elo, "%"),
                            shade = ifelse(highlight & gap < 0, "elo", "none")),
) %>%
  mutate(col = factor(col, levels = c("xgboost", "elo")))

ggplot(title_cells, aes(x = col, y = label)) +
  geom_tile(aes(fill = shade), colour = "white", linewidth = 2) +
  geom_text(aes(label = text, colour = highlight, fontface = ifelse(highlight, "bold", "plain")),
            size = 6) +
  scale_fill_manual(values = c(xgboost = VIOLET, elo = GOLD, none = "#F4F0FA"), guide = "none") +
  scale_colour_manual(values = c(`TRUE` = INK, `FALSE` = GRAY), guide = "none") +
  scale_x_discrete(position = "top") +
  labs(title = "chance to win the 2026 title",
       subtitle = "100,000 simulated brackets, starting from semifinals",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(panel.grid.major.x = element_blank(),
        axis.text.x = element_text(face = "bold", size = 15),
        axis.text.y = element_text(size = 15))

# ----------------------------
# 5. round by round
# ----------------------------
round_plot_data <- odds %>%
  left_join(seed_labels %>% select(seed, label), by = "seed") %>%
  pivot_longer(c(semis, finals, title), names_to = "round", values_to = "p") %>%
  mutate(round = factor(round, levels = c("semis", "finals", "title"),
                        labels = c("make semis", "make finals", "win title")),
         label = factor(label, levels = rev(seed_labels$label)))

ggplot(round_plot_data, aes(x = round, y = label, fill = p)) +
  geom_tile(colour = "white", linewidth = 2) +
  geom_text(aes(label = scales::percent(p, accuracy = 1)), colour = INK, size = 5.5, fontface = "bold") +
  scale_fill_gradient(low = "#F4F0FA", high = VIOLET, limits = c(0, 1), guide = "none") +
  scale_x_discrete(position = "top") +
  labs(title = "round by round",
       subtitle = "chance to reach each round in 100,000 simulated brackets using xgboost",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(panel.grid.major.x = element_blank(), axis.text.x = element_text(face = "bold"))

# ----------------------------
# 6. one matchup: what the model sees for dream vs liberty
# ----------------------------
home_team <- "Atlanta Dream"
away_team <- "New York Liberty"
h <- match(home_team, seeds)
a <- match(away_team, seeds)

matchup_stats <- tribble(
  ~stat,                        ~col,         ~scale, ~suffix, ~higher_better,
  "net rating",                 "net",        1,      "",      TRUE,
  "net rating, last 10 games",  "net_last10", 1,      "",      TRUE,
  "net rating, last season",    "net_prev",   1,      "",      TRUE,
  "shooting (eFG%)",            "efg_off",    100,    "%",     TRUE,
  "turnovers per 100 poss.",    "tov_off",    100,    "",      FALSE,
  "defensive rebounding",       "drb_def",    100,    "%",     TRUE
) %>%
  mutate(home  = sapply(col, function(s) current[[s]][h]) * scale,
         away  = sapply(col, function(s) current[[s]][a]) * scale,
         stat  = factor(stat, levels = rev(stat))) %>%
  pivot_longer(c(home, away), names_to = "side", values_to = "value") %>%
  group_by(stat) %>%
  mutate(better = if (first(higher_better)) value == max(value) else value == min(value)) %>%
  ungroup() %>%
  mutate(team  = factor(ifelse(side == "home", seed_labels$abbr[h], seed_labels$abbr[a]),
                        levels = c(seed_labels$abbr[h], seed_labels$abbr[a])),
         label = paste0(ifelse(col %in% c("net", "net_last10", "net_prev") & value > 0, "+", ""),
                        sprintf("%.1f", value), suffix))

ggplot(matchup_stats, aes(x = team, y = stat)) +
  geom_tile(aes(fill = better), colour = "white", linewidth = 2) +
  geom_text(aes(label = label, fontface = ifelse(better, "bold", "plain")), colour = INK, size = 6) +
  scale_fill_manual(values = c(`TRUE` = VIOLET, `FALSE` = "#F4F0FA"), guide = "none") +
  scale_x_discrete(position = "top") +
  labs(title = "what the model sees: dream vs liberty",
       subtitle = sprintf("game 1 of the semis in atlanta. xgboost gives the dream %.0f%%\nto win the game and %.0f%% to win the series. violet = better",
                          100 * P_xgboost[h, a], 100 * p_series(P_xgboost, h, a, semifinals)),
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(panel.grid.major.x = element_blank(),
        axis.text.x = element_text(face = "bold", size = 15))
