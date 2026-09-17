# WNBA analysis

Curated analysis projects on women's basketball. Regression, network ranking, award
prediction, and whatever else I get curious about during the season (and want to write cleanly!)

I'm Maddy! I just finished a PhD in math and advanced data science at the University of Washington, and I run @wnbadata on [TikTok](https://www.tiktok.com/@wnbadata) and
[Instagram](https://www.instagram.com/wnbadata/), where I turn coding work like this into short
video explainers for 30k+ followers. I'm currently looking for data science work in
basketball (especially women's basketball!)

Each project below is its own folder with the R script, a write up of
what I found, and some charts. I have also included links to my video explanations as well.

## Projects

### [Which stats actually matter?](which-stats-actually-matter/)

Win% for the team that led each stat in a game, WNBA 2024-2026. Effective field goal
percentage is the best one at 79.2%, while steals (60.3%) and blocks (60.2%) are barely
better than a coin flip and offensive rebounds are a literal coin flip at 50.1%.

R, wehoop, ggplot2, gt ·
[video](https://www.instagram.com/p/DYFg-2SzWAI/)

### [What actually drives Defensive Player of the Year voting?](dpoy-predictions/)

A logistic regression that gives every player a probability of winning DPOY, WNBA 1997 to
2025. Defensive win shares, blocks and steals are the only inputs that matter, and adding
team defense actually makes it slightly worse. It gets 19 of 28 seasons right on data it
was trained on.

R, rvest, dplyr ·
[video one](https://www.instagram.com/p/DNi-fmrzeM-/) ·
[video two](https://www.instagram.com/p/DNqtVPhT7mL/)

### [What is a steal actually worth?](team-ridge-regression/)

Ridge regression on player box scores, WNBA 2024 to 2026, scaled so one point equals 1. A
steal comes out worth about 4 points and a turnover costs about 5.6, so the two biggest
effects in the box score are both possession events. Inspired by Benjamin Morris's NBA
version, where a steal was worth around 9.

R, wehoop, glmnet, ggplot2 ·
[video](https://www.instagram.com/reels/DXHsCdHzywf/)

More projects are going up as I clean them up.

## Data

Everything here uses on **public data**, mostly
[`wehoop`](https://wehoop.sportsdataverse.org/), the sportsdataverse R package for
women's basketball (ESPN play by play and box scores).

If a project needs data that isn't available through an API, like something hand
collected or scraped, the CSV will be committed next to the script in that project's `data/`
folder and the source is named in the project README.

## Related

- **@wnbadata** for the videos: [TikTok](https://www.tiktok.com/@wnbadata) and
  [Instagram](https://www.instagram.com/wnbadata/)
- **[madbro206/wnbadata](https://github.com/madbro206/wnbadata)** for the full working
  archive: about three years of exploratory scripts behind every video (unedited and definitely a little messy). This
  repo is the cleaned up subset of my best hits :)
