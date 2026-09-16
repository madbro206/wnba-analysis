library(wehoop)
library(dplyr)
library(tidyr)
library(ggplot2)
library(gt)
library(stringr)
library(scales)

#load data, drop all star games and keep regular season only.
#all star rosters get named after the captains (TEAM CLARK, Team Wilson, etc)
#and no real franchise has "team" in its name, so this should catch future ones too
wnba_team_box <- load_wnba_team_box(seasons = c(2024:2026)) %>%
  filter(
    !str_detect(team_name, regex("\\bteam\\b", ignore_case = TRUE)),
    season_type == 2
  )


#win% for whoever led each stat in a game
leader_win_pct <- function(data, stats) {
  data %>%
    select(game_id, team_winner, all_of(stats)) %>%
    pivot_longer(
      cols = all_of(stats),
      names_to = "stat",
      values_to = "value"
    ) %>%
    group_by(game_id, stat) %>%
    mutate(leader = value == max(value, na.rm = TRUE)) %>%
    ungroup() %>%
    filter(leader) %>%
    group_by(stat) %>%
    summarise(
      games = n(),
      wins = sum(team_winner, na.rm = TRUE),
      win_pct = wins / games,
      .groups = "drop"
    ) %>%
    arrange(desc(win_pct))
}


#calculate team four factors
wnba_team_box_four_factors <- wnba_team_box %>%
  #need the opponent's defensive rebounds for ORB%
  group_by(game_id) %>%
  mutate(
    opp_def_reb = if_else(
      team_id == first(team_id),
      last(defensive_rebounds),
      first(defensive_rebounds)
    )
  ) %>%
  ungroup() %>%
  mutate(
    off_eFG_pct = (field_goals_made + 0.5 * three_point_field_goals_made) /
                  field_goals_attempted,

    #0.44 is the usual estimate for how many FTA end a possession
    off_TOV_pct = turnovers /
      (field_goals_attempted + 0.44 * free_throws_attempted + turnovers),

    off_ORB_pct = offensive_rebounds / (offensive_rebounds + opp_def_reb),

    off_FTr = free_throws_attempted / field_goals_attempted,

    #twos made
    two_point_field_goals_made = field_goals_made - three_point_field_goals_made
  )


#everything, including the four factors
stats_to_check <- c(
  "assists",
  "blocks",
  "steals",
  "total_rebounds",
  "field_goal_pct",
  "team_score",
  "three_point_field_goals_made",
  "off_eFG_pct",
  "off_TOV_pct",
  "off_ORB_pct",
  "off_FTr",
  "turnovers",
  "defensive_rebounds",
  "offensive_rebounds",
  "fouls"
)

#plain box score stuff for the charts
box_stats <- c(
  "assists",
  "blocks",
  "steals",
  "off_eFG_pct",
  "total_rebounds",
  "field_goal_pct",
  "team_score",
  "three_point_field_goals_made",
  "two_point_field_goals_made",
  "turnovers",
  "defensive_rebounds",
  "offensive_rebounds",
  "fouls"
)


#readable labels. note the "leader" in turnovers/fouls is the team with MORE
#of them, so those get labeled that way
label_stats <- function(df) {
  df %>%
    mutate(
      stat_label = case_when(
        stat == "off_eFG_pct"                  ~ "eFG%",
        stat == "off_TOV_pct"                  ~ "Turnover rate",
        stat == "off_ORB_pct"                  ~ "Offensive rebound rate",
        stat == "off_FTr"                      ~ "Free throw rate",
        stat == "field_goal_pct"               ~ "FG%",
        stat == "three_point_field_goals_made" ~ "3-pointers made",
        stat == "two_point_field_goals_made"   ~ "2-pointers made",
        stat == "turnovers"                    ~ "Most turnovers",
        stat == "fouls"                        ~ "Most fouls",
        stat == "team_score"                   ~ "Points",
        TRUE ~ str_to_sentence(str_replace_all(stat, "_", " "))
      )
    )
}


#table version
gt_leader_table <- function(df,
                            title    = "Which stats actually matter?",
                            subtitle = "Win% for the team that led each stat, WNBA regular season 2024-2026") {
  df %>%
    label_stats() %>%
    select(stat_label, games, wins, win_pct) %>%
    gt() %>%
    tab_header(title = md(paste0("**", title, "**")), subtitle = subtitle) %>%
    cols_label(
      stat_label = "Stat led",
      games      = "Games",
      wins       = "Wins",
      win_pct    = "Win%"
    ) %>%
    fmt_number(columns = c(games, wins), decimals = 0, use_seps = TRUE) %>%
    fmt_percent(columns = win_pct, decimals = 1) %>%
    #shade from the 50% coin flip up, not from the worst stat
    data_color(
      columns = win_pct,
      palette = c("#FFF1E0", "#FDBE7A", "#E8730C"),
      domain  = c(0.5, max(df$win_pct, na.rm = TRUE))
    ) %>%
    cols_align(align = "left",  columns = stat_label) %>%
    cols_align(align = "right", columns = c(games, wins, win_pct)) %>%
    tab_source_note(source_note = md("Data: `wehoop` | @wnbadata")) %>%
    tab_options(
      table.font.size            = px(14),
      heading.title.font.size    = px(20),
      heading.subtitle.font.size = px(13),
      column_labels.font.weight  = "bold",
      data_row.padding           = px(5),
      table.border.top.style     = "none",
      source_notes.font.size     = px(11)
    )
}

leader_table <- gt_leader_table(leader_win_pct(wnba_team_box_four_factors, stats_to_check))
leader_table


#bar chart version
plot_win_pct <- function(df, keep = NULL, label_size = 3, axis_size = 11) {
  if (!is.null(keep)) df <- filter(df, stat %in% keep)

  ggplot(df, aes(x = reorder(stat_label, desc(win_pct)), y = win_pct)) +
    geom_col(fill = "darkorange") +
    geom_text(aes(label = percent(win_pct, accuracy = 1)), vjust = -0.3, size = label_size) +
    scale_y_continuous(labels = percent_format(accuracy = 1), limits = c(0, 1.05)) +
    labs(
      x = NULL,
      y = "Win%",
      title = "Team Win% when leading game in [stat]",
      subtitle = "WNBA 2024-2026",
      caption = "data: wehoop | chart: @wnbadata"
    ) +
    theme_minimal(base_size = 12) +
    theme(axis.text.x = element_text(angle = 45, hjust = 1, size = axis_size))
}

win_stats <- leader_win_pct(wnba_team_box_four_factors, box_stats) %>%
  label_stats()

#all of the stats
plot_win_pct(win_stats)


#games where a team won rebounds, steals, blocks AND turnovers and still lost
#(each game is two rows, so the opponent's value is just the other row)
opp_val <- function(x) if_else(row_number() == 1, lead(x), lag(x))

hustle_upsets <- wnba_team_box %>%
  group_by(game_id) %>%
  mutate(
    out_rebounded  = total_rebounds > opp_val(total_rebounds),
    out_stolen     = steals > opp_val(steals),
    out_blocked    = blocks > opp_val(blocks),
    out_turnovered = turnovers < opp_val(turnovers)   #fewer turnovers is better
  ) %>%
  ungroup() %>%
  filter(out_rebounded, out_stolen, out_blocked, out_turnovered, !team_winner)

hustle_upsets %>%
  filter(season == 2025) %>%
  select(game_date, team_name, team_score, opponent_team_name, opponent_team_score,
         total_rebounds, steals, blocks, turnovers)


#how big is the eFG% gap when the less efficient team still wins?
efg_margins <- wnba_team_box_four_factors %>%
  group_by(game_id) %>%
  summarise(
    efg_leader  = max(off_eFG_pct, na.rm = TRUE),
    efg_trailer = min(off_eFG_pct, na.rm = TRUE),
    efg_diff    = efg_leader - efg_trailer,
    trailer_won = any(off_eFG_pct == min(off_eFG_pct, na.rm = TRUE) & team_winner),
    .groups = "drop"
  )

gap_summary <- function(df) {
  df %>%
    summarise(
      n_games     = n(),
      mean_diff   = mean(efg_diff, na.rm = TRUE),
      median_diff = median(efg_diff, na.rm = TRUE),
      p90_diff    = quantile(efg_diff, 0.9, na.rm = TRUE),
      max_diff    = max(efg_diff, na.rm = TRUE)
    )
}

bind_rows(
  gap_summary(efg_margins) %>% mutate(sample = "all games"),
  gap_summary(filter(efg_margins, trailer_won)) %>% mutate(sample = "eFG% trailer wins")
) %>%
  select(sample, everything())
