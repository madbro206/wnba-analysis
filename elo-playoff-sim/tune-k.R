# =========================================
# Choosing K for the margin-of-victory Elo, using 2024 and 2025
# =========================================
# walk-forward test: each game is predicted from the ratings going into it, and every game
# after the first third of each season is scored with log loss (lower is better).
# every team starts each season at 1500, the same as elo-sim.R

library(wehoop)
library(dplyr)
library(ggplot2)

load_season <- function(yr) {
  sch  <- load_wnba_schedule(seasons = yr)
  skip <- sch$game_id[sch$notes_headline %in% c("AT&T WNBA All-Star Game",
                                                "WNBA Commissioner's Cup Championship")]
  load_wnba_team_box(seasons = yr) %>%
    filter(season_type == 2, team_home_away == "home", !game_id %in% skip) %>%
    transmute(game_date = as.Date(game_date),
              home = team_display_name,
              away = opponent_team_display_name,
              margin = team_score - opponent_team_score) %>%
    arrange(game_date) %>%
    mutate(scored = game_date >= game_date[round(n() / 3) + 1])   # first third is warm-up only
}

seasons <- lapply(c(2024, 2025), load_season)

# home court from these two seasons, set the same way as in elo-sim.R
home_win_rate <- mean(bind_rows(seasons)$margin > 0)
HCA <- 400 * log10(home_win_rate / (1 - home_win_rate))

elo_prob <- function(gap) 1 / (1 + 10^(-gap / 400))

# the home team's win probability for every game, using the ratings going into it
elo_predict <- function(g, K) {
  teams <- sort(unique(c(g$home, g$away)))
  elo <- setNames(rep(1500, length(teams)), teams)
  p <- numeric(nrow(g))
  for (i in seq_len(nrow(g))) {
    h <- g$home[i]
    a <- g$away[i]
    diff_home   <- elo[h] + HCA - elo[a]
    p[i]        <- elo_prob(diff_home)
    result_home <- as.numeric(g$margin[i] > 0)
    diff_winner <- if (result_home == 1) diff_home else -diff_home
    mult <- (abs(g$margin[i]) + 3)^0.8 / (7.5 + 0.006 * diff_winner)
    elo[h] <- elo[h] + K * mult * (result_home - p[i])
    elo[a] <- elo[a] - K * mult * (result_home - p[i])
  }
  p
}

log_loss <- function(K) {
  mean(unlist(lapply(seasons, function(g) {
    p   <- elo_predict(g, K)[g$scored]
    won <- g$margin[g$scored] > 0
    -(won * log(p) + (1 - won) * log(1 - p))
  })))
}

k_results <- tibble(K = seq(5, 60, by = 5)) %>%
  mutate(log_loss = sapply(K, log_loss))

print(k_results)
best_k <- k_results$K[which.min(k_results$log_loss)]
best_k

# ============================
# Chart
# ============================
VIOLET <- "#AD96DC"
GRAY   <- "#8A8A86"
INK    <- "#010101"

best <- k_results %>% filter(K == best_k)

ggplot(k_results, aes(x = K, y = log_loss)) +
  geom_line(colour = GRAY, linewidth = 1) +
  geom_point(colour = GRAY, size = 2.5) +
  geom_point(data = best, colour = VIOLET, size = 5) +
  geom_text(data = best, aes(label = sprintf("K = %d", K)), vjust = -1.2, colour = INK,
            size = 5, fontface = "bold") +
  scale_x_continuous(breaks = seq(10, 60, by = 10)) +
  scale_y_continuous(expand = expansion(mult = c(0.08, 0.05))) +
  labs(title = "choosing K",
       subtitle = "average log loss predicting 2024 and 2025 games from earlier games\n(lower is better)",
       caption = "elo model  |  chart: @wnbadata\ndata: wehoop",
       x = "K", y = "log loss") +
  theme_minimal(base_size = 15) +
  theme(plot.title.position   = "plot",
        plot.caption.position = "plot",
        plot.title    = element_text(face = "bold", colour = INK, size = 19),
        plot.subtitle = element_text(colour = GRAY, size = 13, margin = margin(b = 14)),
        plot.caption  = element_text(colour = GRAY, size = 11, hjust = 0, margin = margin(t = 14)),
        axis.text     = element_text(colour = INK, size = 13),
        axis.title    = element_text(colour = GRAY, size = 12),
        panel.grid.minor = element_blank(),
        plot.margin   = margin(18, 18, 14, 10))
