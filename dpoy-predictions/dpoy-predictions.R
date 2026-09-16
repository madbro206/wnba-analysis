#wnba dpoy predictor
#inspired by https://www.linkedin.com/pulse/predicting-nba-defensive-player-year-dpoy-using-data-science-khatkar-0uh6c/
library(rvest)
library(purrr)
library(dplyr)

years    <- 1997:2025
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

#the real header is sitting in the first row, so promote it.
#this also renames the Season column I added to the first year, hence X1997 below
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

#flag the winners, everyone else is a 0
joined_table <- joined_table %>%
  left_join(dpoy_key %>% select(Season, player_key) %>% mutate(dpoy = 1),
            by = c("player_key", "Season")) %>%
  mutate(dpoy = ifelse(is.na(dpoy), 0, dpoy))

#every winner should find a player row. if this prints anything, those names are
#spelled differently in the season tables
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

total_table <- joined_table %>%
  inner_join(team_stats, by = c("Team", "Season")) %>%
  mutate(across(c(W, L, DRtg, def_efg, def_tov_pct, opp_drb_pct, def_FT_ratio), as.numeric)) %>%
  eligible()


#####
#models
#####

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
    filter(Season != 2025) %>%   #2025 isn't done yet
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
    filter(Season != 2025) %>%
    group_by(Season) %>%
    slice_max(dpoy_prob_norm, n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    select(Season, Predicted = Player, dpoy_prob_norm)

  actual <- data %>%
    filter(dpoy == 1, Season != 2025) %>%
    select(Season, Actual = Player)

  predicted %>%
    left_join(actual, by = "Season") %>%
    arrange(Season)
}

top_ten <- function(data, cols) {
  data %>%
    filter(Season == 2025) %>%
    select(all_of(cols), dpoy_prob_norm) %>%
    arrange(desc(dpoy_prob_norm)) %>%
    head(10)
}


#player stats only. the BLK*STL term asks whether being good at both is worth
#more than being good at one
model <- glm(dpoy ~ G + MP + BLK_pct + STL_pct + BLK + STL + BLK*STL + DRB + DWS,
             data = joined_table_clean, family = binomial)
summary(model)

player_probs <- add_probs(joined_table_clean, model)
report_accuracy(season_accuracy(player_probs), "player stats")
print(compare_by_season(player_probs), n = 28)
top_ten(player_probs, c("Player", "Team", "STL", "BLK", "DRB", "DWS"))


#same model, but trained on 1997-2015 and checked on 2016 onward
train_set <- joined_table_clean %>% filter(Season <= 2015)
test_set  <- joined_table_clean %>% filter(Season >= 2016)

model_sub <- glm(dpoy ~ G + MP + BLK_pct + STL_pct + BLK + STL + BLK*STL + DRB + DWS,
                 data = train_set, family = binomial)

report_accuracy(season_accuracy(add_probs(test_set, model_sub)), "held out 2016+")


#now with team defense added
model2 <- glm(dpoy ~ G + MP + BLK_pct + STL_pct + BLK + STL + BLK*STL + DRB + DWS +
                DRtg + def_efg + def_tov_pct + opp_drb_pct + def_FT_ratio,
              data = total_table, family = binomial)
summary(model2)

team_probs <- add_probs(total_table, model2)
report_accuracy(season_accuracy(team_probs), "player + team stats")
print(compare_by_season(team_probs), n = 28)
top_ten(team_probs, c("Player", "Team", "STL", "BLK", "DRB", "DWS", "DRtg"))
