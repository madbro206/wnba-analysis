# =========================================
# Bradley-Terry (margin version) team ratings and playoff odds, 2026 WNBA season
# =========================================
# margin_k = home_adv + lambda_home - lambda_away + error,  error ~ Normal(0, sigma^2)
# fit by least squares, so lambda is in points

library(wehoop)
library(dplyr)
library(qvcalc)
library(ggplot2)

# ============================
# Data: one row per game, from the home team's side
# ============================
team_box <- load_wnba_team_box(seasons = 2026)

games <- team_box %>%
  filter(season_type == 2) %>%                                      # regular season
  filter(!team_name %in% c("TEAM COOP", "TEAM SPOON")) %>%          # no all star game
  filter(as.Date(game_date) != as.Date("2026-06-30")) %>%           # no commissioners cup final
  filter(team_home_away == "home") %>%                              # one row per game
  mutate(game_date,
         home = team_display_name,
         away = opponent_team_display_name,
         margin = team_score - opponent_team_score,
         .keep = "none")

# ============================
# Design matrix: +1 home team, -1 away team, 0 otherwise
# ============================
teams <- sort(unique(c(games$home, games$away)))

X_home <- model.matrix(~ factor(home, levels = teams) - 1, data = games)
X_away <- model.matrix(~ factor(away, levels = teams) - 1, data = games)
X <- X_home - X_away
colnames(X) <- teams

X <- X[, -1]   # drop the first team so its lambda is fixed at 0 (Atlanta is the reference)

# ============================
# Fit
# ============================
# the intercept is home court advantage in points
fit <- lm(games$margin ~ X)

summary(fit)

# ============================
# Team strengths
# ============================
strengths <- tibble(team = teams,
                    lambda = c(0, coef(fit)[-1]),
                    se = c(0, summary(fit)$coefficients[-1, "Std. Error"])) %>%
  mutate(vs_avg = lambda - mean(lambda)) %>%   # same ratings, shifted so the average team is 0
  arrange(desc(lambda))

print(strengths, n = Inf)

coef(fit)[1]   # home court advantage (points)
sigma(fit)     # sd of a single game's margin around its prediction

# ============================
# Quasi standard errors
# ============================
# the SEs above are each team vs Atlanta. quasi SEs give every team its own SE so any two
# teams can be compared: SE(lambda_i - lambda_j) is about sqrt(quasiSE_i^2 + quasiSE_j^2)

# covariance matrix of all 15 lambdas, with Atlanta added back as a row/column of zeros
V <- matrix(0, length(teams), length(teams), dimnames = list(teams, teams))
V[-1, -1] <- vcov(fit)[-1, -1]

qv <- qvcalc(V, estimates = c(0, coef(fit)[-1]), labels = teams)

summary(qv)   # also reports how closely the quasi variances match the true pairwise variances

strengths_qv <- qv$qvframe %>%
  mutate(team = teams,
         vs_avg = estimate - mean(estimate)) %>%
  select(team, vs_avg, quasiSE) %>%
  arrange(desc(vs_avg))

print(strengths_qv, row.names = FALSE)

# ============================
# Playoff predictions
# ============================
# 2026 format: fixed bracket, 1v8 and 4v5 on one side, 2v7 and 3v6 on the other
#   first round  best of 3, higher seed hosts games 1, 3
#   semifinals   best of 5, higher seed hosts games 1, 2, 5
#   finals       best of 7, higher seed hosts games 1, 2, 5, 7

seeds <- c("Minnesota Lynx", "Golden State Valkyries", "Las Vegas Aces", "Atlanta Dream",
            "Washington Mystics", "Indiana Fever","Dallas Wings", "New York Liberty")

first_round <- c(TRUE, FALSE, TRUE)                          # TRUE = higher seed at home
semifinals  <- c(TRUE, TRUE, FALSE, FALSE, TRUE)
finals      <- c(TRUE, TRUE, FALSE, FALSE, TRUE, FALSE, TRUE)

lambda   <- setNames(c(0, coef(fit)[-1]), teams)
home_adv <- coef(fit)[1]
sig      <- sigma(fit)

# probability the higher seed wins a single game: P(margin > 0) = pnorm(expected margin / sigma)
p_game <- function(high, low, high_home) {
  expected_margin <- lambda[high] - lambda[low] + ifelse(high_home, home_adv, -home_adv)
  pnorm(expected_margin / sig)
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

play <- function(a, b, P) {             # a, b: seed numbers, one per simulation
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
HI     <- "#C8102E"
GRAY   <- "#8A8A86"
LIGHT  <- "#B4B2A9"
INK    <- "#15171D"
CREDIT <- "bradley-terry model fit on the 2026 season  |  chart: @wnbadata\ndata: wehoop"

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
# 1. team strength
# ----------------------------
# bars are +/- 1.39 quasi SEs: two teams' bars stop overlapping right when their gap is
# big enough to be significant at the 5% level (1.96 * sqrt(2) * quasiSE = 2 * 1.39 * quasiSE)
strength_plot_data <- strengths_qv %>%
  mutate(playoff = team %in% seeds,
         low  = vs_avg - 1.39 * quasiSE,
         high = vs_avg + 1.39 * quasiSE,
         team = factor(team, levels = rev(team)))   # strongest at the top

ggplot(strength_plot_data, aes(y = team, x = vs_avg, colour = playoff)) +
  geom_vline(xintercept = 0, colour = GRAY, linewidth = 0.4) +
  geom_errorbar(aes(xmin = low, xmax = high), orientation = "y", width = 0, linewidth = 1.2) +
  geom_point(size = 3.5) +
  scale_colour_manual(values = c(`TRUE` = HI, `FALSE` = LIGHT), guide = "none") +
  scale_x_continuous(labels = function(x) ifelse(x > 0, paste0("+", x), x)) +
  labs(title = "team strength",
       subtitle = "points better or worse than an average team.\nplayoff teams in red. overlapping bars: not clearly different",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme()

# ----------------------------
# 2. title odds
# ----------------------------
title_plot_data <- title_odds %>%
  left_join(seed_labels %>% select(seed, label), by = "seed") %>%
  mutate(label = factor(label, levels = rev(label)))   # 1 seed at the top

ggplot(title_plot_data, aes(y = label, x = title)) +
  geom_col(fill = HI, width = 0.6) +
  geom_text(aes(label = scales::percent(title, accuracy = 1)), hjust = -0.2,
            colour = INK, size = 5.5, fontface = "bold") +
  scale_x_continuous(labels = scales::percent, expand = expansion(mult = c(0, 0.12))) +
  labs(title = "chance to win the 2026 title",
       subtitle = "100,000 simulated playoff brackets",
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
  geom_text(aes(label = scales::percent(p, accuracy = 1), colour = p > 0.5),
            size = 5.5, fontface = "bold") +
  scale_fill_gradient(low = "#FBE9EC", high = HI, limits = c(0, 1), guide = "none") +
  scale_colour_manual(values = c(`TRUE` = "white", `FALSE` = INK), guide = "none") +
  scale_x_discrete(position = "top") +
  labs(title = "round by round",
       subtitle = "chance to reach each round in 100,000 simulated brackets",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(panel.grid.major.x = element_blank(), axis.text.x = element_text(face = "bold"))

# ----------------------------
# 4. first round
# ----------------------------
# one bar per series: higher seed's chance in red from the left, lower seed's in gray from the right
first_round_plot_data <- first_round_odds %>%
  left_join(seed_labels %>% select(high = team, high_label = label), by = "high") %>%
  left_join(seed_labels %>% select(low = team, low_label = label), by = "low") %>%
  mutate(series = paste(high_label, "vs", low_label)) %>%
  arrange(p_series) %>%
  mutate(series = factor(series, levels = series))   # most lopsided at the top

ggplot(first_round_plot_data, aes(y = series)) +
  geom_col(aes(x = 1), fill = LIGHT, width = 0.6) +
  geom_col(aes(x = p_series), fill = HI, width = 0.6) +
  geom_vline(xintercept = 0.5, linetype = "dashed", colour = INK, linewidth = 0.5) +
  geom_text(aes(x = 0.02, label = paste(high_label, scales::percent(p_series, accuracy = 1))),
            hjust = 0, colour = "white", size = 5.5, fontface = "bold") +
  geom_text(aes(x = 0.98, label = paste(scales::percent(1 - p_series, accuracy = 1), low_label)),
            hjust = 1, colour = INK, size = 5.5, fontface = "bold") +
  scale_x_continuous(labels = scales::percent, expand = expansion(mult = 0)) +
  labs(title = "first round series odds",
       subtitle = "chance each team wins its best of 3 series",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(axis.text.y = element_blank(), panel.grid.major.x = element_blank())

# ----------------------------
# 5. one game: lynx at home vs liberty
# ----------------------------
# the final margin is normal around the expected margin, and the lynx win when it lands above 0
ex_high <- "Minnesota Lynx"
ex_low  <- "New York Liberty"
ex_mu   <- home_adv + lambda[ex_high] - lambda[ex_low]
ex_p    <- p_game(ex_high, ex_low, TRUE)

curve_data <- tibble(margin = seq(-40, 50, by = 0.1)) %>%
  mutate(density = dnorm(margin, mean = ex_mu, sd = sig),
         lynx_win = margin > 0)

ggplot(curve_data, aes(x = margin, y = density)) +
  geom_area(aes(fill = lynx_win), show.legend = FALSE) +
  geom_line(colour = INK, linewidth = 0.6) +
  geom_vline(xintercept = 0, linetype = "dashed", colour = INK, linewidth = 0.5) +
  annotate("text", x = 12, y = dnorm(ex_mu, ex_mu, sig) * 0.4,
           label = paste0("lynx win\n", round(100 * ex_p), "%"),
           colour = "white", size = 6, fontface = "bold") +
  annotate("text", x = -27, y = dnorm(ex_mu, ex_mu, sig) * 0.35,
           label = paste0("liberty win\n", round(100 * (1 - ex_p)), "%"),
           colour = INK, size = 6, fontface = "bold") +
  annotate("text", x = ex_mu + 2, y = dnorm(ex_mu, ex_mu, sig) * 1.06, hjust = 0,
           label = sprintf("expected: lynx by %.1f", ex_mu), colour = INK, size = 4.5) +
  scale_fill_manual(values = c(`TRUE` = HI, `FALSE` = LIGHT)) +
  scale_x_continuous(labels = function(x) ifelse(x > 0, paste0("+", x), x)) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.12))) +
  labs(title = "lynx at home vs liberty",
       subtitle = "one game's final margin, lynx points minus liberty points",
       caption = CREDIT, x = NULL, y = NULL) +
  base_theme() +
  theme(axis.text.y = element_blank(), panel.grid.major.x = element_blank())
