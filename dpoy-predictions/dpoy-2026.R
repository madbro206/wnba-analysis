#wnba dpoy predictor, 2026 edition
#this is the rewrite of dpoy-predictions.R: every stat becomes a within season
#percentile, one model instead of two, and it predicts the 2026 award
#inspired by https://www.linkedin.com/pulse/predicting-nba-defensive-player-year-dpoy-using-data-science-khatkar-0uh6c/
library(rvest)
library(purrr)
library(dplyr)
library(ggplot2)

years    <- 1997:2026

#the season being predicted. it has no winner yet, so it's held out of the accuracy
#numbers and it's the season top_ten() reports on
current_season <- 2026
base_url <- "https://www.basketball-reference.com/wnba/years/"

#only look at real rotation players. without this the model happily hands a high
#probability to someone who played 2 games and did nothing, since G and MP come out
#with negative coefficients
min_games <- 20
min_mpg   <- 15

eligible <- function(df) filter(df, G >= min_games, MP / G >= min_mpg)

#on a lot of season pages the whole row gets mashed into the player cell, like
#"A'ja WilsonLVAC40122840...". the team code is where the real name ends
fix_player <- function(player, team) {
  trimws(mapply(function(p, t) sub(paste0(t, ".*$"), "", p), player, team, USE.NAMES = FALSE))
}


#grab one table off one basketball reference season page
scrape_bref <- function(year, suffix, table_index = 1) {
  Sys.sleep(4)  #slow down, be polite
  tbl <- tryCatch(
    read_html(paste0(base_url, year, suffix)) %>%
      html_table(fill = TRUE) %>%
      .[[table_index]],
    error = function(e) NULL
  )
  if (!is.null(tbl)) tbl$Season <- year
  tbl
}


#advanced stats
advanced <- map(years, ~ scrape_bref(.x, "_advanced.html")) %>%
  Filter(Negate(is.null), .) %>%
  bind_rows() %>%
  filter(Team != "Team", Team != "TOT") %>%
  select(Player, Team, Season, G...4, MP...5, `BLK%`, `STL%`, DWS) %>%
  rename(G = G...4, MP = MP...5, BLK_pct = `BLK%`, STL_pct = `STL%`) %>%
  mutate(
    Player = fix_player(Player, Team),
    across(c(G, MP, BLK_pct, STL_pct, DWS), as.numeric)
  )


#defensive box score stats
totals <- map(years, ~ scrape_bref(.x, "_totals.html")) %>%
  Filter(Negate(is.null), .) %>%
  bind_rows() %>%
  filter(Team != "Team", Team != "TOT") %>%
  select(Player, Team, Season, BLK, STL, TRB, ORB) %>%
  mutate(
    Player = fix_player(Player, Team),
    across(c(BLK, STL, TRB, ORB), as.numeric),
    DRB = TRB - ORB
  )


#names don't always match between the awards page and the season tables, so join on
#a normalized key instead of the raw name. the awards page marks ties as "(T)"
clean_name <- function(x) {
  x <- gsub("\\s*\\(T\\)\\s*$", "", x)          #tie marker
  x <- gsub("\\*", "", x)                        #hall of fame asterisk
  x <- gsub("\u2019|\u02BC|\u0060", "'", x)       #curly apostrophes to straight
  x <- iconv(x, to = "ASCII//TRANSLIT")          #accents to plain letters
  trimws(gsub("\\s+", " ", x))
}

clean_name <- function(x) {
  x <- gsub("\\s*\\(T\\)\\s*$", "", x)          #tie marker
  x <- gsub("\\*", "", x)                        #hall of fame asterisk
  x <- gsub("\u2019|\u02BC|\u0060", "'", x)       #curly apostrophes to straight
  x <- iconv(x, to = "ASCII//TRANSLIT")          #accents to plain letters
  trimws(gsub("\\s+", " ", x))
}

joined_table <- advanced %>%
  left_join(totals, by = c("Player", "Team", "Season")) %>%
  mutate(
    Player     = gsub("\\*", "", Player),
    player_key = clean_name(Player)
  )


#team stats. the advanced table is the 7th one through 2015 and the 8th after
team_stats <- map(years, ~ scrape_bref(.x, ".html", if (.x <= 2015) 7 else 8)) %>%
  Filter(Negate(is.null), .) %>%
  bind_rows()

#renaming headers/columns for consistency
colnames(team_stats) <- as.character(unlist(team_stats[1, ]))
team_stats <- team_stats[-1, ]
names(team_stats) <- make.names(names(team_stats), unique = TRUE)
team_stats$Team <- gsub("\\*$", "", team_stats$Team)

team_stats <- team_stats %>%
  filter(Rk != "", Rk != "Rk") %>%
  rename(
    def_efg      = eFG..1,
    def_tov_pct  = TOV..1,
    opp_drb_pct  = DRB.,
    def_FT_ratio = FT.FGA.1,
    Season       = X1997
  ) %>%
  select(Team, Season, W, L, DRtg, def_efg, def_tov_pct, opp_drb_pct, def_FT_ratio)


#dpoy winners
dpoy_table <- read_html("https://www.basketball-reference.com/wnba/awards/dpoy.html") %>%
  html_table(fill = TRUE) %>%
  .[[1]]

dpoy_key <- dpoy_table[-1, ] %>%
  setNames(as.character(unlist(dpoy_table[1, ]))) %>%
  as_tibble() %>%
  select(Season = Year, Player) %>%
  mutate(
    Season     = as.numeric(Season),
    player_key = clean_name(as.character(Player))
  ) %>%
  filter(!is.na(Season))

#flag the winners as 1, everyone else is a 0
joined_table <- joined_table %>%
  left_join(dpoy_key %>% select(Season, player_key) %>% mutate(dpoy = 1),
            by = c("player_key", "Season")) %>%
  mutate(dpoy = ifelse(is.na(dpoy), 0, dpoy))

#every winner should find a player row. if this prints anything, those names are spelled differently in the season tables
setdiff(dpoy_key$player_key, joined_table$player_key)

joined_table_clean <- joined_table %>%
  filter(if_all(c(G, MP, BLK_pct, STL_pct, BLK, STL, DRB), ~ !is.na(.))) %>%
  eligible()


#team names are spelled out on the team page and abbreviated on the player pages
team_key <- tibble::tribble(
  ~Team_Full,                 ~Team_Abbr,
  "Houston Comets",           "HOU",
  "Phoenix Mercury",          "PHO",
  "New York Liberty",         "NYL",
  "Los Angeles Sparks",       "LAS",
  "Cleveland Rockers",        "CLE",
  "Charlotte Sting",          "CHA",
  "Sacramento Monarchs",      "SAC",
  "Utah Starzz",              "UTA",
  "Indiana Fever",            "IND",
  "Atlanta Dream",            "ATL",
  "Detroit Shock",            "DET",
  "Washington Mystics",       "WAS",
  "Orlando Miracle",          "ORL",
  "Minnesota Lynx",           "MIN",
  "Portland Fire",            "POR",
  "Miami Sol",                "MIA",
  "Seattle Storm",            "SEA",
  "Connecticut Sun",          "CON",
  "San Antonio Silver Stars", "SAS",
  "Chicago Sky",              "CHI",
  "Tulsa Shock",              "TUL",
  "Dallas Wings",             "DAL",
  "Las Vegas Aces",           "LVA",
  "Golden State Valkyries",   "GSV"
)

team_stats <- team_stats %>%
  left_join(team_key, by = c("Team" = "Team_Full")) %>%
  mutate(Team = Team_Abbr) %>%
  select(-Team_Abbr)

total_table <- joined_table_clean %>%
  inner_join(team_stats, by = c("Team", "Season")) %>%
  mutate(across(c(W, L, DRtg, def_efg, def_tov_pct, opp_drb_pct, def_FT_ratio), as.numeric))


#####
#model
#####

model_stats <- c("G", "MP", "BLK_pct", "STL_pct", "BLK", "STL", "DRB", "DWS",
                 "DRtg", "def_efg", "def_tov_pct", "opp_drb_pct", "def_FT_ratio")

#turn every stat into a within season percentile. the award is relative: voters compare a
#player to the rest of that season's field, not to 1998. this also handles the season
#getting longer and the league getting bigger over 30 years
add_percentiles <- function(data, stats = model_stats) {
  data %>%
    filter(if_all(all_of(stats), ~ !is.na(.))) %>%
    group_by(Season) %>%
    mutate(across(all_of(stats), percent_rank, .names = "p_{.col}")) %>%
    ungroup()
}

model_data <- add_percentiles(total_table)

#per season, scale everyone's probability so the season adds to 100
add_probs <- function(data, model) {
  data$dpoy_prob <- predict(model, newdata = data, type = "response")
  data %>%
    group_by(Season) %>%
    mutate(dpoy_prob_norm = dpoy_prob / sum(dpoy_prob, na.rm = TRUE) * 100) %>%
    ungroup()
}

#how often is the top predicted player the actual winner
season_accuracy <- function(data) {
  data %>%
    filter(Season != current_season) %>%
    group_by(Season) %>%
    slice_max(dpoy_prob_norm, n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    summarise(correct = sum(dpoy == 1), total = n(), accuracy = correct / total * 100)
}

report_accuracy <- function(acc, label) {
  cat("🎯", label, "-", acc$correct, "of", acc$total, "seasons,",
      round(acc$accuracy, 1), "%\n")
}

#who the model picked vs who actually won, by season
compare_by_season <- function(data) {
  predicted <- data %>%
    filter(Season != current_season) %>%
    group_by(Season) %>%
    slice_max(dpoy_prob_norm, n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    select(Season, Predicted = Player, dpoy_prob_norm)

  #2025 was a tie, so collapse co-winners into one row instead of duplicating the season
  actual <- data %>%
    filter(dpoy == 1, Season != current_season) %>%
    group_by(Season) %>%
    summarise(Actual = paste(sort(unique(Player)), collapse = " / "), .groups = "drop")

  predicted %>%
    left_join(actual, by = "Season") %>%
    arrange(Season)
}

top_ten <- function(data, cols) {
  data %>%
    filter(Season == current_season) %>%
    select(all_of(cols), dpoy_prob_norm) %>%
    arrange(desc(dpoy_prob_norm)) %>%
    head(10)
}


# #player stats plus the team's defensive four factors, all as within season percentiles.
# #the BLK*STL term asks whether being good at both is worth more than being good at one
# dpoy_formula <- dpoy ~ p_G + p_MP + p_BLK_pct + p_STL_pct + p_BLK + p_STL + p_BLK*p_STL +
#   p_DRB + p_DWS + p_DRtg + p_def_efg + p_def_tov_pct + p_opp_drb_pct + p_def_FT_ratio
#
# model <- glm(dpoy_formula, data = model_data, family = binomial)
# summary(model)
#
# probs <- add_probs(model_data, model)
# report_accuracy(season_accuracy(probs), "player + team stats")
# print(compare_by_season(probs), n = 29)
# top_ten(probs, c("Player", "Team", "STL", "BLK", "DRB", "DWS", "DRtg"))


#player stats only, no team defense. the five team terms were doing nothing (every one
#of them p > 0.49) and cutting them takes this from 14 predictors to 9, which matters
#when there are only about 30 winners to learn from. it also drops the inner join with
#team_stats, so no player seasons get lost to a team that didn't match
player_stats <- c("G", "MP", "BLK_pct", "STL_pct", "BLK", "STL", "DRB", "DWS")

player_data <- add_percentiles(joined_table_clean, player_stats)

player_formula <- dpoy ~ p_G + p_MP + p_BLK_pct + p_STL_pct + p_BLK + p_STL + p_BLK*p_STL +
  p_DRB + p_DWS

player_model <- glm(player_formula, data = player_data, family = binomial)
summary(player_model)

player_probs <- add_probs(player_data, player_model)
report_accuracy(season_accuracy(player_probs), "player stats only")
print(compare_by_season(player_probs), n = 29)
top_ten(player_probs, c("Player", "Team", "STL", "BLK", "DRB", "DWS"))



#gabby
player_data %>% filter(grepl("Gabby Williams", Player), Season >= 2024) %>%
  select(Season, Team, G, MP, STL, BLK, DRB, DWS) %>%
  mutate(stl_per36 = STL / MP * 36, blk_per36 = BLK / MP * 36)


#####
#charts for the video
#####

accent <- "#E8730C"
muted  <- "grey70"

wnbadata_theme <- theme_minimal(base_size = 13) +
  theme(
    panel.grid.minor = element_blank(),
    panel.grid.major.y = element_blank(),
    plot.title.position = "plot",
    legend.position = "top"
  )


#1. rhyne vs gabby, the "more of everything" chart
head_to_head <- player_probs %>%
  filter(Season == current_season,
         Player %in% c("Rhyne Howard", "Gabby Williams")) %>%
  select(Player, Steals = STL, Blocks = BLK, `Def rebounds` = DRB, `Def win shares` = DWS) %>%
  tidyr::pivot_longer(-Player, names_to = "stat", values_to = "value")

ggplot(head_to_head, aes(x = Player, y = value, fill = Player)) +
  geom_col(width = 0.65) +
  geom_text(aes(label = value), vjust = -0.4, size = 4.5) +
  facet_wrap(~ stat, scales = "free_y", nrow = 1) +
  scale_fill_manual(values = c("Rhyne Howard" = accent, "Gabby Williams" = muted)) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.18))) +
  labs(x = NULL, y = NULL, title = "Rhyne Howard has more of everything the model looks at",
       subtitle = "WNBA 2026", caption = "data: basketball reference | chart: @wnbadata") +
  wnbadata_theme +
  theme(legend.position = "none", axis.text.y = element_blank())

# ggsave("figures/rhyne-vs-gabby.png", width = 10, height = 4.5, dpi = 200)


#2. which stats the model actually leans on, greyed out where it isn't significant
coef_tbl <- as.data.frame(summary(player_model)$coefficients)
names(coef_tbl) <- c("estimate", "se", "z", "p")
coef_tbl$term <- rownames(coef_tbl)

coef_tbl <- coef_tbl %>%
  filter(term != "(Intercept)") %>%
  mutate(
    label = recode(term,
      p_G = "Games", p_MP = "Minutes", p_BLK = "Blocks", p_STL = "Steals",
      p_DRB = "Def rebounds", p_BLK_pct = "Block %", p_STL_pct = "Steal %",
      p_DWS = "Def win shares", `p_BLK:p_STL` = "Blocks x steals"),
    sig = ifelse(p < 0.05, "significant", "not significant")
  )

ggplot(coef_tbl, aes(x = reorder(label, estimate), y = estimate, fill = sig)) +
  geom_col(width = 0.7) +
  geom_hline(yintercept = 0, color = "black") +
  coord_flip() +
  scale_fill_manual(values = c("significant" = accent, "not significant" = muted)) +
  labs(x = NULL, y = "Coefficient", fill = NULL,
       title = "Defensive win shares is the only stat that really holds up",
       subtitle = "everything is a within-season percentile, so the sizes are comparable",
       caption = "chart: @wnbadata") +
  wnbadata_theme

# ggsave("figures/dpoy-coefficients.png", width = 8, height = 5, dpi = 200)


#3. the 2026 board, with atlanta lit up
board <- player_probs %>%
  filter(Season == current_season) %>%
  arrange(desc(dpoy_prob_norm)) %>%
  head(10) %>%
  mutate(is_atl = ifelse(Team == "ATL", "Atlanta", "everyone else"))

ggplot(board, aes(x = reorder(Player, dpoy_prob_norm), y = dpoy_prob_norm, fill = is_atl)) +
  geom_col(width = 0.7) +
  geom_text(aes(label = paste0(round(dpoy_prob_norm, 1), "%")), hjust = -0.15, size = 4) +
  coord_flip() +
  scale_fill_manual(values = c("Atlanta" = accent, "everyone else" = muted)) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(x = NULL, y = NULL, fill = NULL,
       title = "My model's 2026 DPOY board",
       subtitle = "three of the top ten are Dream players",
       caption = "chart: @wnbadata") +
  wnbadata_theme

# ggsave("figures/board-2026.png", width = 8, height = 5.5, dpi = 200)


#4. my model vs the betting market
implied <- function(american) {
  ifelse(american < 0, -american / (-american + 100), 100 / (american + 100))
}

odds <- tibble::tribble(
  ~Player,             ~american,
  "Gabby Williams",       -125,
  "A'ja Wilson",           175,
  "Shakira Austin",        550,
  "Angel Reese",          1000,
  "Kiah Stokes",          9000,
  "Natasha Howard",      10000,
  "Veronica Burton",     15000,
  "Rhyne Howard",        25000
) %>%
  mutate(vegas = implied(american) * 100)

vs_market <- player_probs %>%
  filter(Season == current_season) %>%
  select(Player, model = dpoy_prob_norm) %>%
  inner_join(odds, by = "Player")

#anything on the dashed line means we agree. gabby is bottom right, rhyne is top left
ggplot(vs_market, aes(x = vegas, y = model)) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = muted) +
  geom_point(size = 4, color = accent) +
  ggrepel::geom_text_repel(aes(label = Player), size = 4, seed = 1, box.padding = 0.5) +
  coord_equal(xlim = c(0, 60), ylim = c(0, 60)) +
  labs(x = "betting odds, implied chance (%)", y = "my model (%)",
       title = "Where my model and the betting market disagree",
       subtitle = "on the dashed line we agree. gabby williams and rhyne howard are opposite corners",
       caption = "chart: @wnbadata") +
  wnbadata_theme +
  theme(panel.grid.major.y = element_line(color = "grey92"))

# ggsave("figures/model-vs-market.png", width = 8, height = 5, dpi = 200)


#5. being elite at blocks AND steals barely beats being elite at one
b <- coef(player_model)
archetype_score <- function(blk, stl) {
  b["p_BLK"] * blk + b["p_STL"] * stl + b["p_BLK:p_STL"] * blk * stl
}

archetypes <- tibble::tribble(
  ~who,                 ~blk, ~stl,
  "blocks only",         0.9,  0.1,
  "steals only",         0.1,  0.9,
  "both",                0.9,  0.9
) %>%
  mutate(score = archetype_score(blk, stl))

ggplot(archetypes, aes(x = factor(who, levels = who), y = score)) +
  geom_col(width = 0.6, fill = accent) +
  geom_text(aes(label = round(score, 1)), vjust = -0.4, size = 5) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.15))) +
  labs(x = NULL, y = "model score from blocks + steals",
       title = "Being elite at both barely beats being elite at one",
       subtitle = "90th percentile vs 10th percentile, using the fitted coefficients",
       caption = "chart: @wnbadata") +
  wnbadata_theme

# ggsave("figures/blocks-and-steals.png", width = 7, height = 5, dpi = 200)
