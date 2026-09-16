#https://wehoop.sportsdataverse.org/articles/getting-started-wehoop.html
library(wehoop)
library(dplyr)
library(tictoc)
library(progressr)
library(ggplot2)
library(glmnet)

#load data
#wnba player full box score. plus minus only exists from 2024 on, everything older
#comes back with no plus minus at all, so there's no point pulling it
tictoc::tic()
progressr::with_progress({
  wnba_player_box <- wehoop::load_wnba_player_box(season = c(2024:2026))
})
tictoc::toc()

box_stats <- c("points", "rebounds", "assists", "steals", "blocks", "turnovers", "fouls")

wnba_active <- wnba_player_box %>%
  filter(did_not_play == FALSE, active == TRUE) %>%
  mutate(plus_minus = as.numeric(as.character(plus_minus))) %>%
  #model.matrix drops incomplete rows on its own, which would knock X and y out of
  #alignment, so take complete cases up front instead
  filter(!is.na(plus_minus), if_all(all_of(box_stats), ~ !is.na(.)))

#regression with regularization
#matrix
X <- model.matrix(
  plus_minus ~ points + rebounds + assists + steals + blocks + turnovers + fouls,
  data = wnba_active
)[, -1]

y <- wnba_active$plus_minus

#cross-validated ridge
set.seed(123)
ridge_cv <- cv.glmnet(
  X, y,
  alpha = 0, #0 = ridge
  nfolds = 10,
  standardize = TRUE
)

#best lambda
ridge_cv$lambda.min

#final model at best lambda
ridge_model <- glmnet(X, y, alpha = 0, lambda = ridge_cv$lambda.min)

#convert coefs to a numeric named vector
coefs <- coef(ridge_model)
coefs_vec <- as.numeric(coefs)
names(coefs_vec) <- rownames(coefs)

#scale
scaled_coefs <- coefs_vec / coefs_vec["points"]
scaled_coefs


#get predictions
#use the same design matrix for prediction
ridge_preds <- predict(
  ridge_model,
  newx = X,
  s = ridge_cv$lambda.min,   #same lambda used to fit ridge model
  type = "response"
)

#predict() returns a matrix; coerce to numeric vector
wnba_active$predicted_plus_minus_ridge <- as.numeric(ridge_preds)

#who does the model like more or less than their actual plus minus?
player_summary_ridge <- wnba_active %>%
  group_by(athlete_display_name) %>%
  summarize(
    games     = n(),
    actual    = mean(plus_minus, na.rm = TRUE),
    predicted = mean(predicted_plus_minus_ridge, na.rm = TRUE),
    gap       = actual - predicted,
    .groups = "drop"
  ) %>%
  filter(games >= 20)

#model likes them less than they actually are
player_summary_ridge %>% arrange(desc(gap)) %>% head(10)

#model likes them more than they actually are
player_summary_ridge %>% arrange(gap) %>% head(10)

#plot predicted vs actual plus minus
ggplot(wnba_active, aes(x = predicted_plus_minus_ridge, y = plus_minus)) +
  geom_point(size=0.8, color= "#6821f5", alpha=0.5) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "red") +
  labs(
    x = "Predicted Plus-Minus",
    y = "Actual Plus-Minus",
    title = "Predicted vs. Actual Plus-Minus by Player (Ridge Regression)",
    subtitle ="each point represents one player game, WNBA 2024-2026"
  ) +
  theme_minimal()


#coefficient plot
coef_df <- data.frame(
  stat = names(scaled_coefs),
  scaled = as.numeric(scaled_coefs)
) %>%
  filter(stat != "(Intercept)")

ggplot(coef_df, aes(x = reorder(stat, scaled), y = scaled)) +
  geom_col(fill = "#B897D4") +
  geom_hline(yintercept = 0, linetype = "dashed", color = "black") +
  geom_text(
    aes(label = round(scaled, 2)),
    hjust = ifelse(coef_df$scaled >= 0, -0.1, 1.1)
  ) +
  coord_flip() +
  scale_y_continuous(
    limits = ~ c(-max(abs(.)) * 1.1, max(abs(.)) * 1.1)
  ) +
  labs(
    x = "Box Score Stat",
    y = "Effect Relative to Points",
    title = "Player box score impact toward plus minus",
    subtitle = "scaled so that points = 1"
  ) +
  theme_minimal()

