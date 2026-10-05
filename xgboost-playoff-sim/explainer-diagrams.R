# =========================================
# Explainer diagrams for the video: hand-built, not model output.
# the stats on them are typed in (as of 2026-10-02) and the win percentages are made up
# =========================================
library(ggplot2)

VIOLET <- "#AD96DC"   # valkyrie violet
GOLD   <- "#B9975B"   # valkyries gold
GRAY   <- "#8A8A86"
INK    <- "#010101"

toy_theme <- function() {
  theme_void(base_size = 15) +
    theme(plot.title.position   = "plot",
          plot.caption.position = "plot",
          plot.title    = element_text(face = "bold", colour = INK, size = 22),
          plot.subtitle = element_text(colour = GRAY, size = 14, margin = margin(t = 4, b = 10)),
          plot.caption  = element_text(colour = GRAY, size = 11, hjust = 0),
          plot.background = element_rect(fill = "white", colour = NA),
          plot.margin   = margin(18, 18, 14, 18),
          aspect.ratio  = 1.25)   # same shape at any window size, so boxes never collide
}

# ----------------------------
# 1. one decision tree: aces (home) vs valkyries
# ----------------------------
# the questions and their answers are real (2026 net rating incl. playoffs): the aces are not
# better than the valkyries over the season (+6.9 vs +8.9) but have been hotter over their last 10
# games (+18.9 vs +13.0). the win percentages at the bottom are made up (the real model says 61%)
nodes <- data.frame(
  x     = c(0.50, 0.22, 0.74, 0.56, 0.90),
  y     = c(0.86, 0.56, 0.56, 0.22, 0.22),
  label = c("are the aces better than\nthe valkyries this season?",
            "aces win\n75%",
            "have the aces been\nhotter lately?",
            "aces win\n55%",
            "aces win\n35%"),
  type  = c("question", "other", "question", "path", "other")
)

# arrows from each question down to its two branches. path = the way the aces actually go
edges <- data.frame(
  x    = c(0.50, 0.50, 0.74, 0.74),
  y    = c(0.86, 0.86, 0.56, 0.56),
  xend = c(0.22, 0.74, 0.56, 0.90),
  yend = c(0.56, 0.56, 0.22, 0.22),
  side = c("yes", "no", "yes", "no"),
  path = c(FALSE, TRUE, TRUE, FALSE)
)

# the real answers, next to the branches the aces take
facts <- data.frame(
  x     = c(0.80, 0.55),
  y     = c(0.70, 0.40),
  label = c("this season:\nvalkyries +8.9\naces +6.9", "last 10 games:\naces +18.9\nvalkyries +13.0"),
  hjust = c(0, 1)
)

ggplot() +
  geom_segment(data = edges, aes(x = x, y = y - 0.07, xend = xend, yend = yend + 0.08,
                                 colour = path, linewidth = path),
               arrow = arrow(length = unit(0.12, "inches"), type = "closed")) +
  geom_label(data = edges, aes(x = (x + xend) / 2, y = (y + yend) / 2, label = side),
             fill = "white", colour = INK, linewidth = 0, size = 6, fontface = "bold") +
  geom_text(data = facts, aes(x = x, y = y, label = label, hjust = hjust),
            colour = GRAY, size = 4.3, lineheight = 0.95) +
  geom_label(data = nodes, aes(x = x, y = y, label = label, fill = type, colour = type),
             size = 6, fontface = "bold", lineheight = 0.95,
             label.padding = unit(0.6, "lines"), label.r = unit(0.4, "lines"),
             linewidth = 0.6) +
  scale_fill_manual(values = c(question = "white", path = VIOLET, other = "white"), guide = "none") +
  scale_colour_manual(values = c(question = INK, path = INK, other = GRAY,
                                 `TRUE` = VIOLET, `FALSE` = GRAY), guide = "none") +
  scale_linewidth_manual(values = c(`TRUE` = 1.6, `FALSE` = 0.8), guide = "none") +
  scale_x_continuous(limits = c(-0.02, 1.06)) +
  scale_y_continuous(limits = c(0.1, 0.96)) +
  labs(title = "one decision tree: aces (home) vs valkyries",
       subtitle = "the questions and answers are real (net rating),\nbut the win percentages are made up",
       caption = "chart: @wnbadata") +
  toy_theme()

# ----------------------------
# 2. how xgboost adds trees together
# ----------------------------
# every game goes through every tree, and each tree adds a small nudge to the running total.
# tree 2 is built to fix what tree 1 got wrong (better teams that were cold lately won less
# often than tree 1 said). the highlighted path is a better home team that's been cold lately
boost_nodes <- data.frame(
  x     = c(0.50, 0.50, 0.27, 0.73, 0.50, 0.27, 0.73, 0.50),
  y     = c(0.91, 0.73, 0.58, 0.58, 0.37, 0.22, 0.22, 0.06),
  label = c("every game starts at\nhome team wins 54%",
            "tree 1: is the home team\nbetter this season?",
            "+10%", "-10%",
            "tree 2: have they been\ncold lately?",
            "-3%", "+1%",
            "better team, cold lately:\n54% + 10 - 3 = 61%"),
  type  = c("total", "question", "path", "other", "question", "path", "other", "total")
)

boost_edges <- data.frame(
  x    = c(0.50, 0.50, 0.50, 0.50),
  y    = c(0.73, 0.73, 0.37, 0.37),
  xend = c(0.27, 0.73, 0.27, 0.73),
  yend = c(0.58, 0.58, 0.22, 0.22),
  side = c("yes", "no", "yes", "no"),
  path = c(TRUE, FALSE, TRUE, FALSE)
)

ggplot() +
  # start -> tree 1, tree 1 -> tree 2, tree 2 -> total
  annotate("segment", x = 0.5, xend = 0.5, y = c(0.86, 0.53, 0.17), yend = c(0.79, 0.43, 0.12),
           colour = GRAY, linewidth = 0.8, linetype = "dashed",
           arrow = arrow(length = unit(0.1, "inches"), type = "closed")) +
  annotate("text", x = 0.52, y = 0.48, label = "tree 2 is built to fix\ntree 1's mistakes",
           hjust = 0, colour = GRAY, size = 4.6, fontface = "italic", lineheight = 0.95) +
  geom_segment(data = boost_edges,
               aes(x = x, y = y - 0.05, xend = xend, yend = yend + 0.04,
                   colour = path, linewidth = path),
               arrow = arrow(length = unit(0.12, "inches"), type = "closed")) +
  geom_label(data = boost_edges, aes(x = (x + xend) / 2, y = (y + yend) / 2 - 0.015, label = side),
             fill = "white", colour = INK, linewidth = 0, size = 5.5, fontface = "bold") +
  geom_label(data = boost_nodes, aes(x = x, y = y, label = label, fill = type, colour = type),
             size = 6, fontface = "bold", lineheight = 0.95,
             label.padding = unit(0.55, "lines"), label.r = unit(0.4, "lines"),
             linewidth = 0.6) +
  scale_fill_manual(values = c(question = "white", path = VIOLET, other = "white", total = "#F4F0FA"),
                    guide = "none") +
  scale_colour_manual(values = c(question = INK, path = INK, other = GRAY, total = INK,
                                 `TRUE` = VIOLET, `FALSE` = GRAY), guide = "none") +
  scale_linewidth_manual(values = c(`TRUE` = 1.6, `FALSE` = 0.8), guide = "none") +
  scale_x_continuous(limits = c(-0.02, 1.02)) +
  scale_y_continuous(limits = c(0, 0.97)) +
  labs(title = "how xgboost adds trees together",
       subtitle = "(made up numbers)",
       caption = "chart: @wnbadata") +
  toy_theme()
