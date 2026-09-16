# What actually drives Defensive Player of the Year voting?

**A logistic regression that gives every player a probability of winning DPOY.
WNBA, 1997 to 2025.**

I made two videos off this during the 2025 season, back when the race was still open:
[part one](https://www.instagram.com/p/DNi-fmrzeM-/) and
[part two](https://www.instagram.com/p/DNqtVPhT7mL/).

## The question

Defense is the hardest thing to see in a box score. Blocks and steals are basically the
only counting stats for it, and both of them reward gambling about as much as they
reward good positioning. So DPOY voting is really a test of what voters can actually
measure. I wanted to know which stats the voting tracks, and whether a model could pick
the winner.

I got the idea from
[someone on LinkedIn](https://www.linkedin.com/pulse/predicting-nba-defensive-player-year-dpoy-using-data-science-khatkar-0uh6c/)
who did this for the NBA.

## The data

Basketball Reference, scraped with `rvest`, every season from 1997 to 2025.

I usually use wehoop to pull everything from ESPN really fast, but it doesn't have the
defensive stats I wanted, like block percentage, steal percentage and defensive win
shares. So I scraped three tables per season (advanced stats, totals, and team stats),
shoved them into one table, and joined on the list of past DPOY winners.

The scraper sleeps 4 seconds between pages. That is there because the first time I ran
it, Basketball Reference banned me for about an hour.

Two things that made the scrape annoying. The team advanced stats table sits in a
different spot on the page depending on the season, so it's the 7th table through 2015
and the 8th after that. And on a lot of season pages the entire row gets mashed into the
player cell, so A'ja Wilson comes through as `A'ja WilsonLVAC40122840...`. The team code
is where the real name ends, which is what `fix_player()` uses to cut it back off. Until
I caught that, six winners were silently labeled as non-winners because their names never
matched.

Players also have to have played at least 20 games and 15 minutes a game to be included.
Without that cutoff the model happily hands the award to someone who played twice and did
nothing, since games and minutes both come out with negative coefficients.

## The method

Binomial logistic regression, which fits here because the outcome is binary: you won the
award or you didn't. The model takes a player season and returns a probability, and then
I scale the probabilities within each season so they add up to 100.

There are two versions.

**Model 1 is player stats only.** Games, minutes, block percentage, steal percentage,
raw blocks and steals, defensive rebounds, defensive win shares, and a blocks times
steals interaction. That interaction is asking whether being good at both is worth more
than being good at one.

**Model 2 adds team defense.** Exactly the same player terms, plus the team's defensive
rating and the four defensive factors. I added this because a lot of people told me the
first one was missing team context. I do think people underrate how much team defense is
already baked into defensive win shares, but they had a point. Keeping the player side
identical means the only thing separating the two models is those five team stats.

## The finding

Only four things come out significant in the player model, and they're the obvious ones:

| Term | Estimate | p |
|---|---|---|
| Defensive win shares | 2.765 | 0.00009 |
| Steals | 0.180 | 0.007 |
| Blocks | 0.163 | 0.011 |
| Blocks × steals | -0.001 | 0.011 |
| Games | -0.133 | 0.21 |
| Minutes | -0.009 | 0.07 |
| Block % | -0.851 | 0.21 |
| Steal % | -1.437 | 0.21 |
| Defensive rebounds | -0.005 | 0.50 |

Defensive win shares dominates. The rate stats (block % and steal %) add nothing once the
raw counts are in there, which surprised me. And the interaction is negative, so being
elite at blocks and steals at the same time is worth slightly less than adding the two up
separately, not more.

Adding team defense doesn't help. None of the five team terms come close to significant:

| Team term | Estimate | p |
|---|---|---|
| Defensive rating | 0.575 | 0.34 |
| Opponent eFG% | -49.78 | 0.61 |
| Defensive turnover rate | 0.768 | 0.39 |
| Opponent offensive rebound rate | 0.289 | 0.33 |
| Defensive free throw rate | -23.08 | 0.34 |

It also does slightly worse: 18 of 28 seasons against 19 for the player model. The two
trade picks rather than one just being better everywhere. The team model gains 1999
(Yolanda Griffith) and 2001 (Debbie Black), and loses 2011, 2016 and 2022, where it goes
for Angel McCoughtry, Brittney Griner and Alyssa Thomas over Sylvia Fowles, Sylvia Fowles
and A'ja Wilson.

| Season | Player model | Player + team model | Actual |
|---|---|---|---|
| 1997 | Teresa Weatherspoon | Teresa Weatherspoon | Teresa Weatherspoon |
| 1998 | Teresa Weatherspoon | Teresa Weatherspoon | Teresa Weatherspoon |
| 1999 | Sheryl Swoopes | Yolanda Griffith | Yolanda Griffith |
| 2000 | Sheryl Swoopes | Sheryl Swoopes | Sheryl Swoopes |
| 2001 | Margo Dydek | Debbie Black | Debbie Black |
| 2002 | Sheryl Swoopes | Sheryl Swoopes | Sheryl Swoopes |
| 2003 | Sheryl Swoopes | Sheryl Swoopes | Sheryl Swoopes |
| 2004 | Lisa Leslie | Lisa Leslie | Lisa Leslie |
| 2005 | Tamika Catchings | Tamika Catchings | Tamika Catchings |
| 2006 | Tamika Catchings | Tamika Catchings | Tamika Catchings |
| 2007 | Tamika Catchings | Tamika Catchings | Lauren Jackson |
| 2008 | Lisa Leslie | Lisa Leslie | Lisa Leslie |
| 2009 | Tamika Catchings | Tamika Catchings | Tamika Catchings |
| 2010 | Tamika Catchings | Tamika Catchings | Tamika Catchings |
| 2011 | Sylvia Fowles | Angel McCoughtry | Sylvia Fowles |
| 2012 | Sancho Lyttle | Sancho Lyttle | Tamika Catchings |
| 2013 | Angel McCoughtry | Tamika Catchings | Sylvia Fowles |
| 2014 | Brittney Griner | Brittney Griner | Brittney Griner |
| 2015 | Brittney Griner | Brittney Griner | Brittney Griner |
| 2016 | Sylvia Fowles | Brittney Griner | Sylvia Fowles |
| 2017 | Sylvia Fowles | Sylvia Fowles | Alana Beard |
| 2018 | Jessica Breland | Natasha Howard | Alana Beard |
| 2019 | Natasha Howard | Natasha Howard | Natasha Howard |
| 2020 | Breanna Stewart | A'ja Wilson | Candace Parker |
| 2021 | Sylvia Fowles | Sylvia Fowles | Sylvia Fowles |
| 2022 | A'ja Wilson | Alyssa Thomas | A'ja Wilson |
| 2023 | A'ja Wilson | A'ja Wilson | A'ja Wilson |
| 2024 | A'ja Wilson | A'ja Wilson | Napheesa Collier |

Here's 2025, as percent chance of winning within the season:

| Player | Player model | Player + team model |
|---|---|---|
| A'ja Wilson | 40.1 | 32.5 |
| Gabby Williams | 24.3 | 14.0 |
| Alanna Smith | 15.0 | 19.6 |
| Napheesa Collier | 9.1 | 15.8 |
| Ezi Magbegor | 3.5 | 6.5 |
| Rhyne Howard | 1.5 | 3.6 |

2025 ended in a tie between A'ja Wilson and Alanna Smith, which is exactly the top two of
the team model. The player model had them first and third.

The videos ran mid season on partial data, so the names there don't match these. At the
time the player model liked Gabby Williams and the team model flipped to Alanna Smith.

## Caveats

The 19 of 28 number is the model scoring seasons it was trained on. The held out version,
trained on 1997 through 2015 and asked about 2016 onward, gets 3 of 9. That is the number
that actually says how well this predicts, and 33% is not great.

I picked the stats that went into this, and I am not a DPOY voter. A model like this can
only find patterns in the numbers I decided to hand it.

There is one winner per season (or so you'd think), so across every season there are only about 30 positive
cases against a couple thousand player seasons. That is a very small positive class and it
makes the coefficients unstable.

Blocks and steals are also just bad proxies for defensive value. They miss everything that
doesn't get recorded, like positioning, rotations, and the shots that never get taken. And
award voting has reputation effects that don't get captured in the box score.

## Run it

```r
source("dpoy-predictions.R")
```

Requires: `rvest`, `purrr`, `dplyr`.

It scrapes about 87 pages with a 4 second pause on each one, so give it roughly six
minutes.
