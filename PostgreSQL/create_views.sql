-- Drop all analytical views before recreating them.
-- All 12 views are independent (each queries fact_matches and dim_* directly),
-- so they can be dropped together in a single statement.
DROP VIEW IF EXISTS
    avg_goals_per_team,
    win_ratio_per_team,
    division_stats,
    v_team_elo_trend,
    v_team_shooting_efficiency,
    v_team_aggressiveness,
    v_team_scoring_efficiency,
    v_team_goal_difference,
    v_team_season_ranking,
    v_team_running_totals,
    v_team_mom_goals,
    v_team_performance_tier;

-- 1. avg_goals_per_team
-- Each team appears twice per match it plays: once as home, once as away.
-- UNION ALL combines both perspectives so every match is counted exactly once per team.
CREATE OR REPLACE VIEW avg_goals_per_team AS
WITH all_team_matches AS (
    -- Home perspective: the team is the home side
    SELECT
        m.home_team_key AS team_key,
        m.ft_home_goals AS goals_scored,
        m.ft_away_goals AS goals_conceded
    FROM fact_matches m

    UNION ALL

    -- Away perspective: the team is the away side
    SELECT
        m.away_team_key AS team_key,
        m.ft_away_goals AS goals_scored,
        m.ft_home_goals AS goals_conceded
    FROM fact_matches m
)
SELECT
    t.team_name,
    COUNT(*)                                      AS matches_played,
    AVG(a.goals_scored)                           AS avg_goals_scored,
    AVG(a.goals_conceded)                         AS avg_goals_conceded,
    AVG(a.goals_scored + a.goals_conceded)        AS avg_total_goals
FROM all_team_matches a
JOIN dim_team t ON t.team_key = a.team_key
GROUP BY t.team_name;

-- 2. win_ratio_per_team
CREATE OR REPLACE VIEW win_ratio_per_team AS
SELECT
    t.team_name,
    SUM(CASE WHEN m.ft_result = 'H' AND t.team_key = m.home_team_key THEN 1
             WHEN m.ft_result = 'A' AND t.team_key = m.away_team_key THEN 1 ELSE 0 END) 
             / NULLIF(COUNT(*),0)::float AS win_ratio
FROM fact_matches m
JOIN dim_team t ON t.team_key = m.home_team_key OR t.team_key = m.away_team_key
GROUP BY t.team_name;

-- 3. division_stats
CREATE OR REPLACE VIEW division_stats AS
SELECT
    d.division_name,
    COUNT(*) AS total_matches,
    AVG(m.ft_home_goals + m.ft_away_goals) AS avg_goals_per_match
FROM fact_matches m
JOIN dim_division d ON m.division_key = d.division_key
GROUP BY d.division_name;

-- 4. v_team_elo_trend: average ELO per team per calendar month
-- NULL ELO rows are excluded (WHERE clause) so they do not distort the average.
-- ORDER BY and LIMIT removed: Top-N filtering belongs in Power BI, not the warehouse view.
CREATE OR REPLACE VIEW v_team_elo_trend AS
SELECT
    t.team_name,
    DATE_TRUNC('month', d.full_date) AS month,
    ROUND(
        AVG(
            CASE
                WHEN m.home_team_key = t.team_key THEN m.home_elo
                ELSE m.away_elo
            END
        ),
        2
    ) AS avg_elo
FROM fact_matches m
JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
JOIN dim_date d ON d.date_key = m.date_key
WHERE (
    CASE
        WHEN m.home_team_key = t.team_key THEN m.home_elo
        ELSE m.away_elo
    END
) IS NOT NULL
GROUP BY t.team_name, DATE_TRUNC('month', d.full_date);

-- 5. v_team_shooting_efficiency
-- shooting_accuracy is computed ONLY over matches where BOTH shots and target
-- are non-null, so the numerator and denominator always cover the same matches.
-- Returns NULL (not 0) when no qualifying matches exist.
CREATE OR REPLACE VIEW v_team_shooting_efficiency AS
SELECT 
    t.team_name,
    COUNT(*) AS matches_played,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END), 0) AS total_shots,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END), 0) AS total_on_target,
    -- Count of matches where both shots and on-target are recorded
    COUNT(*) FILTER (
        WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_shots  ELSE m.away_shots  END IS NOT NULL
          AND CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END IS NOT NULL
    ) AS matches_with_shot_data,
    ROUND(
        SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END)
            FILTER (
                WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_shots  ELSE m.away_shots  END IS NOT NULL
                  AND CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END IS NOT NULL
            )::numeric
        / NULLIF(
            SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END)
                FILTER (
                    WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_shots  ELSE m.away_shots  END IS NOT NULL
                      AND CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END IS NOT NULL
                ),
            0
          ),
        3
    ) AS shooting_accuracy,
    -- sufficient_data: true when at least 100 matches have shot data
    COUNT(*) FILTER (
        WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_shots  ELSE m.away_shots  END IS NOT NULL
          AND CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END IS NOT NULL
    ) >= 100 AS sufficient_data
FROM fact_matches m
JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
GROUP BY t.team_name;

-- 6. v_team_aggressiveness: Fouls and cards — aggressiveness indicator
-- aggressiveness_score is divided by the count of matches where fouls, yellow,
-- AND red are all non-null, so the score is not diluted by matches with no card data.
-- Returns NULL when no qualifying matches exist.
CREATE OR REPLACE VIEW v_team_aggressiveness AS
SELECT 
    t.team_name,
    COUNT(*) AS matches_played,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_fouls ELSE m.away_fouls END), 0) AS total_fouls,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_yellow ELSE m.away_yellow END), 0) AS total_yellow,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_red ELSE m.away_red END), 0) AS total_red,
    -- Count of matches where fouls, yellow, and red are all recorded
    COUNT(*) FILTER (
        WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_fouls  ELSE m.away_fouls  END IS NOT NULL
          AND CASE WHEN m.home_team_key = t.team_key THEN m.home_yellow ELSE m.away_yellow END IS NOT NULL
          AND CASE WHEN m.home_team_key = t.team_key THEN m.home_red    ELSE m.away_red    END IS NOT NULL
    ) AS matches_with_card_data,
    ROUND(
        (
            SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_yellow ELSE m.away_yellow END)
                FILTER (
                    WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_fouls  ELSE m.away_fouls  END IS NOT NULL
                      AND CASE WHEN m.home_team_key = t.team_key THEN m.home_yellow ELSE m.away_yellow END IS NOT NULL
                      AND CASE WHEN m.home_team_key = t.team_key THEN m.home_red    ELSE m.away_red    END IS NOT NULL
                ) * 0.5
            + SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_red ELSE m.away_red END)
                FILTER (
                    WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_fouls  ELSE m.away_fouls  END IS NOT NULL
                      AND CASE WHEN m.home_team_key = t.team_key THEN m.home_yellow ELSE m.away_yellow END IS NOT NULL
                      AND CASE WHEN m.home_team_key = t.team_key THEN m.home_red    ELSE m.away_red    END IS NOT NULL
                ) * 1
            + SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_fouls ELSE m.away_fouls END)
                FILTER (
                    WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_fouls  ELSE m.away_fouls  END IS NOT NULL
                      AND CASE WHEN m.home_team_key = t.team_key THEN m.home_yellow ELSE m.away_yellow END IS NOT NULL
                      AND CASE WHEN m.home_team_key = t.team_key THEN m.home_red    ELSE m.away_red    END IS NOT NULL
                ) * 0.1
        )
        / NULLIF(
            COUNT(*) FILTER (
                WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_fouls  ELSE m.away_fouls  END IS NOT NULL
                  AND CASE WHEN m.home_team_key = t.team_key THEN m.home_yellow ELSE m.away_yellow END IS NOT NULL
                  AND CASE WHEN m.home_team_key = t.team_key THEN m.home_red    ELSE m.away_red    END IS NOT NULL
            ),
            0
          ),
        2
    ) AS aggressiveness_score,
    -- sufficient_data: true when at least 100 matches have card data
    COUNT(*) FILTER (
        WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_fouls  ELSE m.away_fouls  END IS NOT NULL
          AND CASE WHEN m.home_team_key = t.team_key THEN m.home_yellow ELSE m.away_yellow END IS NOT NULL
          AND CASE WHEN m.home_team_key = t.team_key THEN m.home_red    ELSE m.away_red    END IS NOT NULL
    ) >= 100 AS sufficient_data
FROM fact_matches m
JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
GROUP BY t.team_name;

-- 7. v_team_scoring_efficiency: Team scoring efficiency — goals per shot, goals per shot on target
-- Goals are counted ONLY in matches where the corresponding denominator field (shots or
-- on-target) is non-null, so numerator and denominator always cover the same match set.
-- This prevents inflated ratios when a team has many matches without shot data.
-- Returns NULL (not 0) when there is no data.
CREATE OR REPLACE VIEW v_team_scoring_efficiency AS
SELECT 
    t.team_name,
    COUNT(*) AS matches_played,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.ft_home_goals ELSE m.ft_away_goals END), 0) AS total_goals,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END), 0) AS total_shots,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END), 0) AS total_on_target,
    -- Count of matches where shot data is recorded
    COUNT(*) FILTER (
        WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END IS NOT NULL
    ) AS matches_with_shot_data,
    -- goals_per_shot: numerator counts goals ONLY in matches where shots IS NOT NULL
    ROUND(
        SUM(CASE WHEN m.home_team_key = t.team_key THEN m.ft_home_goals ELSE m.ft_away_goals END)
            FILTER (WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END IS NOT NULL)::numeric
        / NULLIF(
            SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END),
            0
          ),
        3
    ) AS goals_per_shot,
    -- goals_per_on_target: numerator counts goals ONLY in matches where target IS NOT NULL
    ROUND(
        SUM(CASE WHEN m.home_team_key = t.team_key THEN m.ft_home_goals ELSE m.ft_away_goals END)
            FILTER (WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END IS NOT NULL)::numeric
        / NULLIF(
            SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END),
            0
          ),
        3
    ) AS goals_per_on_target,
    -- sufficient_data: true when at least 100 matches have shot data
    COUNT(*) FILTER (
        WHERE CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END IS NOT NULL
    ) >= 100 AS sufficient_data
FROM fact_matches m
JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
GROUP BY t.team_name;

-- 8. v_team_goal_difference: Head-to-head goal differences (for rivalry heatmap)
CREATE OR REPLACE VIEW v_team_goal_difference AS
SELECT 
    ht.team_name AS home_team,
    at.team_name AS away_team,
    COALESCE(SUM(m.ft_home_goals - m.ft_away_goals), 0) AS goal_difference
FROM fact_matches m
JOIN dim_team ht ON ht.team_key = m.home_team_key
JOIN dim_team at ON at.team_key = m.away_team_key
GROUP BY ht.team_name, at.team_name;


-- NEW ANALYTICAL VIEWS

-- 9. v_team_season_ranking: Team ranking by wins and goals per season
CREATE OR REPLACE VIEW v_team_season_ranking AS
WITH team_season_stats AS (
    SELECT 
        m.season,
        div.division_name,
        t.team_name,
        SUM(CASE WHEN m.ft_result = 'H' AND t.team_key = m.home_team_key THEN 1
                 WHEN m.ft_result = 'A' AND t.team_key = m.away_team_key THEN 1 ELSE 0 END) AS total_wins,
        SUM(CASE WHEN t.team_key = m.home_team_key THEN m.ft_home_goals 
                 WHEN t.team_key = m.away_team_key THEN m.ft_away_goals ELSE 0 END) AS total_goals
    FROM fact_matches m
    JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
    JOIN dim_date d ON d.date_key = m.date_key
    JOIN dim_division div ON div.division_key = m.division_key
    GROUP BY m.season, div.division_name, t.team_name
)
SELECT 
    season,
    division_name,
    team_name,
    total_wins,
    RANK() OVER(PARTITION BY season, division_name ORDER BY total_wins DESC) AS win_rank,
    total_goals,
    RANK() OVER(PARTITION BY season, division_name ORDER BY total_goals DESC) AS goal_rank
FROM team_season_stats;

-- 10. v_team_running_totals: Running totals for points and goals across a season
CREATE OR REPLACE VIEW v_team_running_totals AS
SELECT 
    m.season,
    d.full_date,
    t.team_name,
    CASE 
        WHEN m.ft_result = 'H' AND t.team_key = m.home_team_key THEN 3
        WHEN m.ft_result = 'A' AND t.team_key = m.away_team_key THEN 3
        WHEN m.ft_result = 'D' THEN 1
        ELSE 0 
    END AS points_earned,
    CASE 
        WHEN t.team_key = m.home_team_key THEN m.ft_home_goals 
        ELSE m.ft_away_goals 
    END AS goals_scored,
    SUM(
        CASE 
            WHEN m.ft_result = 'H' AND t.team_key = m.home_team_key THEN 3
            WHEN m.ft_result = 'A' AND t.team_key = m.away_team_key THEN 3
            WHEN m.ft_result = 'D' THEN 1
            ELSE 0 
        END
    ) OVER (PARTITION BY m.season, t.team_name ORDER BY d.full_date, m.match_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_points,
    SUM(
        CASE 
            WHEN t.team_key = m.home_team_key THEN m.ft_home_goals 
            ELSE m.ft_away_goals 
        END
    ) OVER (PARTITION BY m.season, t.team_name ORDER BY d.full_date, m.match_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_goals
FROM fact_matches m
JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
JOIN dim_date d ON d.date_key = m.date_key;

-- 11. v_team_mom_goals: Month-over-month goals scored per team
CREATE OR REPLACE VIEW v_team_mom_goals AS
WITH monthly_goals AS (
    SELECT 
        t.team_name,
        m.season,
        EXTRACT(YEAR FROM d.full_date) AS year,
        d.month,
        SUM(CASE WHEN t.team_key = m.home_team_key THEN m.ft_home_goals 
                 ELSE m.ft_away_goals END) AS goals_scored
    FROM fact_matches m
    JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
    JOIN dim_date d ON d.date_key = m.date_key
    GROUP BY t.team_name, m.season, EXTRACT(YEAR FROM d.full_date), d.month
)
SELECT 
    team_name,
    season,
    year,
    month,
    goals_scored,
    CASE
        WHEN (year * 12 + month) - LAG(year * 12 + month) OVER (PARTITION BY team_name ORDER BY year, month) = 1
        THEN LAG(goals_scored) OVER (PARTITION BY team_name ORDER BY year, month)
    END AS prev_month_goals,
    CASE
        WHEN (year * 12 + month) - LAG(year * 12 + month) OVER (PARTITION BY team_name ORDER BY year, month) = 1
        THEN goals_scored - LAG(goals_scored) OVER (PARTITION BY team_name ORDER BY year, month)
    END AS mom_diff
FROM monthly_goals;

-- 12. v_team_performance_tier: A team performance-tier segmentation view (High/Mid/Low)
CREATE OR REPLACE VIEW v_team_performance_tier AS
WITH win_ratios AS (
    SELECT
        t.team_name,
        COUNT(*) AS matches_played,
        SUM(CASE WHEN m.ft_result = 'H' AND t.team_key = m.home_team_key THEN 1
                 WHEN m.ft_result = 'A' AND t.team_key = m.away_team_key THEN 1 ELSE 0 END) 
                 / NULLIF(COUNT(*),0)::float AS win_ratio
    FROM fact_matches m
    JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
    GROUP BY t.team_name
)
SELECT 
    team_name,
    win_ratio,
    CASE 
        WHEN matches_played < 10 THEN 'Insufficient Data'
        WHEN win_ratio >= 0.5 THEN 'High'
        WHEN win_ratio >= 0.3 THEN 'Mid'
        ELSE 'Low' 
    END AS performance_tier
FROM win_ratios;
