# =========================================
# Elo (margin of victory) team ratings and playoff odds, 2026 WNBA season
# =========================================
# every team starts at 1500. after each game the winner takes points from the loser:
#   change = K * mult * (result - expected)
# expected = 1 / (1 + 10^(-(elo_home + home court - elo_away) / 400)), and mult grows with the
# margin (FiveThirtyEight's NBA multiplier), so bigger wins move the ratings more

library(wehoop)
library(dplyr)
library(ggplot2)

# ============================
# Data: one row for each game (home team)
# ============================
team_box <- load_wnba_team_box(seasons = 2026)
schedule <- load_wnba_schedule(seasons = 2026)

skip <- schedule$game_id[schedule$notes_headline %in% c("AT&T WNBA All-Star Game",
                                                        "WNBA Commissioner's Cup Championship")]

games <- team_box %>%
  filter(season_type == 2,                          # regular season
         team_home_away == "home",                  # one row per game
         !game_id %in% skip) %>%                    # no all star game or cup final
  mutate(game_date = as.Date(game_date),
         home = team_display_name,
         away = opponent_team_display_name,
         margin = team_score - opponent_team_score,
         .keep = "none") %>%
  arrange(game_date)

teams <- sort(unique(c(games$home, games$away)))

# ============================
# Elo ratings
# ============================
K         <- 30                   # chosen on 2024-25 in tune-k.R
ELO_START <- 1500

# home court in Elo points, set so two equal teams match the 2026 home win rate
home_win_rate <- mean(games$margin > 0)
HCA <- 400 * log10(home_win_rate / (1 - home_win_rate))

# chance of winning for a team with a rating edge of `gap`
elo_prob <- function(gap) 1 / (1 + 10^(-gap / 400))

elo <- setNames(rep(ELO_START, length(teams)), teams)
history <- vector("list", nrow(games))

for (i in seq_len(nrow(games))) {
  h <- games$home[i]
  a <- games$away[i]
  diff_home     <- elo[h] + HCA - elo[a]
  expected_home <- elo_prob(diff_home)
  result_home   <- as.numeric(games$margin[i] > 0)

  # grows with the margin, shrinks when the favorite wins
  diff_winner <- if (result_home == 1) diff_home else -diff_home
  mult <- (abs(games$margin[i]) + 3)^0.8 / (7.5 + 0.006 * diff_winner)

  elo[h] <- elo[h] + K * mult * (result_home - expected_home)
  elo[a] <- elo[a] - K * mult * (result_home - expected_home)

  history[[i]] <- tibble(game_date = games$game_date[i], team = c(h, a), elo = c(elo[h], elo[a]))
}

history <- bind_rows(history)

ratings <- tibble(team = names(elo), elo = unname(elo)) %>%
  arrange(desc(elo))

print(ratings, n = Inf)
HCA

# ============================
# Playoff predictions
# ============================
# 2026 format: fixed bracket, 1v8 and 4v5 on one side, 2v7 and 3v6 on the other
#   first round  best of 3, higher seed hosts games 1, 3
#   semifinals   best of 5, higher seed hosts games 1, 2, 5
#   finals       best of 7, higher seed hosts games 1, 2, 5, 7

seeds <- c("Minnesota Lynx", "Golden State Valkyries", "Las Vegas Aces", "Atlanta Dream",
           "Washington Mystics", "Indiana Fever", "Dallas Wings", "New York Liberty")

first_round <- c(TRUE, FALSE, TRUE)                          # TRUE = higher seed at home
semifinals  <- c(TRUE, TRUE, FALSE, FALSE, TRUE)
finals      <- c(TRUE, TRUE, FALSE, FALSE, TRUE, FALSE, TRUE)

# probability the higher seed wins a single game
p_game <- function(high, low, high_home) {
  elo_prob(elo[high] - elo[low] + ifelse(high_home, HCA, -HCA))
}

# probability the higher seed wins a series. pretend every game gets played, even the ones
# that wouldn't be needed: the higher seed wins the series exactly when it wins a majority
p_series <- function(high, low, pattern) {
  p <- p_game(high, low, pattern)             # one win probability per game
  wins <- 1                                   # wins[w + 1] = P(w wins so far); start at 0 wins
  for (pg in p) wins <- c(wins * (1 - pg), 0) + c(0, wins * pg)
  n <- length(p)
  sum(wins[(ceiling(n / 2) + 1):(n + 1)])     # P(at least a majority of wins)
}

# first round
first_round_odds <- tibble(high = seeds[c(1, 4, 2, 3)],
                           low  = seeds[c(8, 5, 7, 6)]) %>%
  rowwise() %>%
  mutate(p_game_home = p_game(high, low, TRUE),
         p_game_away = p_game(high, low, FALSE),
         p_series    = p_series(high, low, first_round)) %>%
  ungroup()

print(first_round_odds)

# whole bracket: simulate it, using the exact series probabilities for each matchup
# P[i, j] = probability seed i beats seed j (i is the higher seed, so i < j)
series_matrix <- function(pattern) {
  outer(1:8, 1:8, Vectorize(function(i, j) if (i < j) p_series(seeds[i], seeds[j], pattern) else NA))
}
P_first  <- series_matrix(first_round)
P_semi   <- series_matrix(semifinals)
P_finals <- series_matrix(finals)

play <- function(a, b, P) {                   # a, b: seed numbers, one per simulation
  high <- pmin(a, b)
  low  <- pmax(a, b)
  ifelse(runif(length(a)) < P[cbind(high, low)], high, low)
}

set.seed(2026)
n_sims <- 100000

w18 <- play(rep(1, n_sims), rep(8, n_sims), P_first)
w45 <- play(rep(4, n_sims), rep(5, n_sims), P_first)
w27 <- play(rep(2, n_sims), rep(7, n_sims), P_first)
w36 <- play(rep(3, n_sims), rep(6, n_sims), P_first)

finalist_1 <- play(w18, w45, P_semi)
finalist_2 <- play(w27, w36, P_semi)

champion <- play(finalist_1, finalist_2, P_finals)

title_odds <- tibble(seed = 1:8,
                     team = seeds,
                     semis  = sapply(1:8, function(s) mean(w18 == s | w45 == s | w27 == s | w36 == s)),
                     finals = sapply(1:8, function(s) mean(finalist_1 == s | finalist_2 == s)),
                     title  = sapply(1:8, function(s) mean(champion == s)))

print(title_odds)

# ============================
# Charts
# ============================
VIOLET <- "#AD96DC"   # valkyrie violet
GOLD   <- "#B9975B"   # valkyries gold
GRAY   <- "#8A8A86"
FADED  <- "#D6D2DE"   # background lines
INK    <- "#010101"
CREDIT <- "elo model fit on the 2026 season  |  chart: @wnbadata\ndata: wehoop"

base_theme <- function() {
  theme_minimal(base_size = 15) +
    theme(
      plot.title.position   = "plot",
      plot.caption.position = "plot",
      plot.title    = element_text(face = "bold", colour = INK, size = 19),
      plot.subtitle = element_text(colour = GRAY, size = 13, margin = margin(b = 14)),
      plot.caption  = element_text(colour = GRAY, size = 11, hjust = 0, margin = margin(t = 14)),
      axis.text     = element_text(colour = INK, size = 13),
      panel.grid.minor   = element_blank(),
      panel.grid.major.y = element_blank(),
      panel.grid.major.x = element_line(colour = "#E3E3E0", linewidth = 0.3),
      plot.margin   = margin(18, 18, 14, 10)
    )
}

# short labels like "1 MIN" for the playoff teams
seed_labels <- tibble(team = seeds, seed = 1:8) %>%
  left_join(team_box %>% distinct(team = team_display_name, abbr = team_abbreviation), by = "team") %>%
  mutate(label = paste(seed, abbr))

# ----------------------------
# 1. team ratings
# ----------------------------
rating_plot_data <- ratings %>%
  mutate(playoff = team %in% seeds,
         team = factor(team, levels = rev(team)))   # highest at the top

ggplot(rating_plot_data, aes(y = team, x = elo, colour = playoff)) +
  geom_vline(xintercept = ELO_START, colour = GRAY, linewidth = 0.4) +
  geom_segment(aes(x = ELO_START, xend = elo, yend = team), linewidth = 1.2) +
  geom_point(size = 3.5) +
  scale_colour_manual(values = c(`TRUE` = VIOLET, `FALSE` = GOLD), guide = "none") +
  labs(title = "elo ratings after regular season",
       subtitle = "(every team started at 1500)\nplayoff teams in violet",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme()

# ----------------------------
# 2. title odds
# ----------------------------
title_plot_data <- title_odds %>%
  left_join(seed_labels %>% select(seed, label), by = "seed") %>%
  mutate(label = factor(label, levels = rev(label)))   # 1 seed at the top

ggplot(title_plot_data, aes(y = label, x = title)) +
  geom_col(fill = VIOLET, width = 0.6) +
  geom_text(aes(label = scales::percent(title, accuracy = 1)), hjust = -0.2,
            colour = INK, size = 5.5, fontface = "bold") +
  scale_x_continuous(labels = scales::percent, expand = expansion(mult = c(0, 0.12))) +
  labs(title = "chance to win the 2026 title",
       subtitle = "100,000 simulated playoff brackets using elo",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme()

# ----------------------------
# 3. round by round
# ----------------------------
round_plot_data <- title_odds %>%
  left_join(seed_labels %>% select(seed, label), by = "seed") %>%
  tidyr::pivot_longer(c(semis, finals, title), names_to = "round", values_to = "p") %>%
  mutate(round = factor(round, levels = c("semis", "finals", "title"),
                        labels = c("make semis", "make finals", "win title")),
         label = factor(label, levels = rev(seed_labels$label)))

ggplot(round_plot_data, aes(x = round, y = label, fill = p)) +
  geom_tile(colour = "white", linewidth = 2) +
  geom_text(aes(label = scales::percent(p, accuracy = 1)), colour = INK,
            size = 5.5, fontface = "bold") +
  scale_fill_gradient(low = "#F4F0FA", high = VIOLET, limits = c(0, 1), guide = "none") +
  scale_x_discrete(position = "top") +
  labs(title = "round by round",
       subtitle = "chance to reach each round in 100,000 simulated brackets using elo",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(panel.grid.major.x = element_blank(), axis.text.x = element_text(face = "bold"))

# ----------------------------
# 4. first round
# ----------------------------
# one bar per series: higher seed's chance in violet from the left, lower seed's in gold from the right
first_round_plot_data <- first_round_odds %>%
  left_join(seed_labels %>% select(high = team, high_label = label), by = "high") %>%
  left_join(seed_labels %>% select(low = team, low_label = label), by = "low") %>%
  mutate(series = paste(high_label, "vs", low_label)) %>%
  arrange(p_series) %>%
  mutate(series = factor(series, levels = series))   # most lopsided at the top

ggplot(first_round_plot_data, aes(y = series)) +
  geom_col(aes(x = 1), fill = GOLD, width = 0.6) +
  geom_col(aes(x = p_series), fill = VIOLET, width = 0.6) +
  geom_vline(xintercept = 0.5, linetype = "dashed", colour = INK, linewidth = 0.5) +
  geom_text(aes(x = 0.02, label = paste(high_label, scales::percent(p_series, accuracy = 1))),
            hjust = 0, colour = INK, size = 5.5, fontface = "bold") +
  geom_text(aes(x = 0.98, label = paste(scales::percent(1 - p_series, accuracy = 1), low_label)),
            hjust = 1, colour = INK, size = 5.5, fontface = "bold") +
  scale_x_continuous(labels = scales::percent, expand = expansion(mult = 0)) +
  labs(title = "first round series odds",
       subtitle = "chance each team wins its best of 3 series, using elo",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(axis.text.y = element_blank(), panel.grid.major.x = element_blank())

# ----------------------------
# 5. ratings through the season
# ----------------------------
# the top two seeds in color, the rest of the playoff teams in gray
season_plot_data <- history %>%
  filter(team %in% seeds) %>%
  mutate(highlight = ifelse(team %in% seeds[1:2], team, "other"))

end_labels <- season_plot_data %>%
  filter(highlight != "other") %>%
  group_by(team) %>%
  slice_max(game_date, n = 1) %>%
  ungroup() %>%
  left_join(seed_labels %>% select(team, label), by = "team")

ggplot(season_plot_data, aes(x = game_date, y = elo, group = team, colour = highlight)) +
  geom_hline(yintercept = ELO_START, colour = GRAY, linewidth = 0.4) +
  geom_step(data = filter(season_plot_data, highlight == "other"), linewidth = 0.6) +
  geom_step(data = filter(season_plot_data, highlight != "other"), linewidth = 1.2) +
  geom_text(data = end_labels, aes(label = label), hjust = -0.15, size = 5, fontface = "bold") +
  scale_colour_manual(values = setNames(c(VIOLET, INK, FADED), c(seeds[2], seeds[1], "other")),
                      guide = "none") +
  scale_x_date(date_labels = "%b", expand = expansion(mult = c(0.02, 0.16))) +
  labs(title = "elo through the season",
       subtitle = "playoff teams, with the top two seeds highlighted",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(panel.grid.major.y = element_line(colour = "#E3E3E0", linewidth = 0.3))

# ----------------------------
# 6. win probability by rating gap
# ----------------------------
gap_curve <- tibble(gap = seq(-600, 600, by = 2), p = elo_prob(gap))

gap_points <- tibble(gap   = c(0, 400),
                      label = c("equal teams\n50%", "400 points\n91% (10 to 1)")) %>%
  mutate(p = elo_prob(gap))

ggplot(gap_curve, aes(x = gap, y = p)) +
  geom_hline(yintercept = 0.5, colour = GRAY, linewidth = 0.4) +
  geom_vline(xintercept = 0, colour = GRAY, linewidth = 0.4) +
  geom_line(colour = VIOLET, linewidth = 1.4) +
  geom_point(data = gap_points, size = 3.5, colour = INK) +
  geom_text(data = gap_points, aes(label = label), hjust = 1.08, vjust = -0.4,
            colour = INK, size = 4.5, lineheight = 0.9) +
  scale_y_continuous(labels = scales::percent, limits = c(0, 1)) +
  scale_x_continuous(labels = function(x) ifelse(x > 0, paste0("+", x), x)) +
  labs(title = "win probability by elo gap",
       subtitle = "chance a team wins, by team rating difference,\n(on a neutral court)",
       caption = CREDIT, x = "rating gap", y = NULL) +
  base_theme() +
  theme(panel.grid.major.y = element_line(colour = "#E3E3E0", linewidth = 0.3),
        axis.title.x = element_text(colour = GRAY, size = 12, margin = margin(t = 8)))

# ----------------------------
# 7. one game: the winner takes points from the loser
# ----------------------------
ex_date  <- as.Date("2026-09-24")
ex_teams <- c("Minnesota Lynx", "Indiana Fever")
ex_game  <- games %>% filter(game_date == ex_date, home == ex_teams[1], away == ex_teams[2])

# a team's rating going into date d
elo_on <- function(t, d) {
  prior <- history %>% filter(team == t, game_date < d)
  if (nrow(prior) == 0) ELO_START else tail(prior$elo, 1)
}

swap_data <- tibble(team   = ex_teams,
                    before = sapply(ex_teams, elo_on, d = ex_date),
                    after  = sapply(ex_teams, function(t) history$elo[history$team == t & history$game_date == ex_date])) %>%
  left_join(team_box %>% distinct(team = team_display_name, abbr = team_abbreviation), by = "team") %>%
  mutate(change = after - before) %>%
  tidyr::pivot_longer(c(before, after), names_to = "when", values_to = "elo") %>%
  mutate(when = factor(when, levels = c("before", "after")),
         label = ifelse(when == "before",
                        sprintf("%s %.0f", abbr, elo),
                        sprintf("%s %.0f (%+.0f)", abbr, elo, change)))

ggplot(swap_data, aes(x = when, y = elo, group = abbr, colour = abbr)) +
  geom_line(linewidth = 2) +
  geom_point(size = 5) +
  geom_text(data = filter(swap_data, when == "before"), aes(label = label),
            hjust = 1.2, size = 5.5, fontface = "bold", colour = INK) +
  geom_text(data = filter(swap_data, when == "after"), aes(label = label),
            hjust = -0.15, size = 5.5, fontface = "bold", colour = INK) +
  scale_colour_manual(values = c(MIN = VIOLET, IND = GOLD), guide = "none") +
  scale_x_discrete(position = "top", expand = expansion(add = 0.9)) +
  scale_y_continuous(expand = expansion(mult = 0.15)) +
  labs(title = "the winner takes points from the loser",
       subtitle = sprintf("lynx beat the fever by %d at home on september 24", ex_game$margin),
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(axis.text.x = element_text(face = "bold", size = 15), axis.text.y = element_blank(),
        panel.grid.major.x = element_blank())

# ----------------------------
# 8. upsets move ratings more than expected wins
# ----------------------------
game_example <- function(d, winner, loser, label) {
  g <- games %>% filter(game_date == d, home %in% c(winner, loser), away %in% c(winner, loser))
  winner_home <- g$home == winner
  gap <- elo_on(winner, d) - elo_on(loser, d) + ifelse(winner_home, HCA, -HCA)
  tibble(label  = label,
         chance = elo_prob(gap),
         moved  = history$elo[history$team == winner & history$game_date == d] - elo_on(winner, d))
}

upset_data <- bind_rows(
  game_example(as.Date("2026-09-19"), "Golden State Valkyries", "Seattle Storm",
               "sept 19: valkyries beat the storm by 13"),
  game_example(as.Date("2026-09-22"), "Portland Fire", "Golden State Valkyries",
               "sept 22: fire beat the valkyries by 8")) %>%
  mutate(label = factor(label, levels = rev(label)),
         text  = sprintf("%.0f points", moved))

ggplot(upset_data, aes(y = label, x = moved)) +
  geom_col(fill = VIOLET, width = 0.35) +
  geom_text(aes(x = 0, label = label), hjust = 0, vjust = 0, nudge_y = 0.26, colour = INK, size = 5.5) +
  geom_text(aes(x = moved + 0.5, label = text), hjust = 0, colour = INK, size = 5, fontface = "bold") +
  scale_x_continuous(limits = c(0, 75), expand = expansion(mult = 0)) +
  labs(title = "upsets move ratings more",
       subtitle = "elo points each team moved",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(axis.text = element_blank(), panel.grid.major.x = element_blank())

# ----------------------------
# 9. bigger wins move ratings more, with diminishing returns
# ----------------------------
# the lynx's rating change against the valkyries on a neutral court, using final ratings,
# for every final margin from the lynx's side (negative = the valkyries won)
lynx_change <- function(m) {
  gap  <- elo["Minnesota Lynx"] - elo["Golden State Valkyries"]
  won  <- m > 0
  gap_winner <- ifelse(won, gap, -gap)
  mult <- (abs(m) + 3)^0.8 / (7.5 + 0.006 * gap_winner)
  unname(K * mult * (as.numeric(won) - elo_prob(gap)))
}

margin_curve <- tibble(margin = c(-40:-1, 1:40)) %>%
  mutate(change = lynx_change(margin),
         side   = ifelse(margin > 0, "lynx win", "valkyries win"))

# what the change would be if it grew in proportion to the margin, matched at +/- 20
proportional <- tibble(margin = c(-40, -1, 1, 40)) %>%
  mutate(side   = ifelse(margin > 0, "lynx win", "valkyries win"),
         change = ifelse(margin > 0, lynx_change(20) / 20, lynx_change(-20) / -20) * margin)

end_labels <- margin_curve %>% filter(abs(margin) == 40)

ggplot(margin_curve, aes(x = margin, y = change, group = side)) +
  geom_hline(yintercept = 0, colour = GRAY, linewidth = 0.4) +
  geom_vline(xintercept = 0, colour = GRAY, linewidth = 0.4) +
  geom_line(data = proportional, linetype = "dashed", colour = GRAY, linewidth = 0.8) +
  geom_line(aes(colour = side), linewidth = 1.8) +
  geom_text(data = end_labels, aes(label = sprintf("%+.0f", change)),
            hjust = ifelse(end_labels$margin > 0, -0.25, 1.25), colour = INK, size = 5, fontface = "bold") +
  annotate("text", x = 36, y = lynx_change(20) / 20 * 36, label = "if it grew in proportion",
           hjust = 1.05, vjust = -0.4, colour = GRAY, size = 4.2) +
  annotate("text", x = 20, y = -12, label = "lynx win", hjust = 0, colour = INK, size = 5, fontface = "bold") +
  annotate("text", x = -20, y = 12, label = "valkyries win", hjust = 1, colour = INK, size = 5, fontface = "bold") +
  scale_colour_manual(values = c(`lynx win` = INK, `valkyries win` = VIOLET), guide = "none") +
  scale_x_continuous(breaks = c(-40, -20, 0, 20, 40), labels = function(x) ifelse(x > 0, paste0("+", x), x),
                     expand = expansion(mult = 0.12)) +
  scale_y_continuous(labels = function(x) ifelse(x > 0, paste0("+", x), x)) +
  labs(title = "bigger wins count more, but it levels off",
       subtitle = "change in the lynx's elo against the valkyries,\nby final margin (neutral court)",
       caption = CREDIT, x = "lynx margin", y = NULL) +
  base_theme() +
  theme(panel.grid.major.y = element_line(colour = "#E3E3E0", linewidth = 0.3),
        axis.title.x = element_text(colour = GRAY, size = 12, margin = margin(t = 8)))
