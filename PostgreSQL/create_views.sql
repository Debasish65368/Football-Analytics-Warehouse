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
    AVG(a.goals_scored)                          AS avg_goals_scored,
    AVG(a.goals_conceded)                        AS avg_goals_conceded,
    AVG(a.goals_scored + a.goals_conceded)       AS avg_total_goals
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

-- 4. v_team_elo_trend: átlag ELO időben (csapatonként, top 20)
CREATE OR REPLACE VIEW v_team_elo_trend AS
SELECT 
    t.team_name,
    DATE_TRUNC('month', d.full_date) AS month,
    COALESCE(
        ROUND(
            AVG(
                CASE 
                    WHEN m.home_team_key = t.team_key THEN COALESCE(m.home_elo,0)
                    ELSE COALESCE(m.away_elo,0)
                END
            ),
        2),
    0) AS avg_elo
FROM fact_matches m
JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
JOIN dim_date d ON d.date_key = m.date_key
GROUP BY t.team_name, DATE_TRUNC('month', d.full_date)
ORDER BY avg_elo DESC
LIMIT 20;

-- 5. v_team_shooting_efficiency
CREATE OR REPLACE VIEW v_team_shooting_efficiency AS
SELECT 
    t.team_name,
    COUNT(*) AS matches_played,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END), 0) AS total_shots,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END), 0) AS total_on_target,
    COALESCE(
        ROUND(
            COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END), 0)::numeric /
            NULLIF(COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END), 0), 0), 
            3
        ),
        0
    ) AS shooting_accuracy
FROM fact_matches m
JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
GROUP BY t.team_name
ORDER BY shooting_accuracy DESC
LIMIT 20;

-- 6. v_team_aggressiveness: Fouls / lapok: agresszivitás mutató
CREATE OR REPLACE VIEW v_team_aggressiveness AS
SELECT 
    t.team_name,
    COUNT(*) AS matches_played,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_fouls ELSE m.away_fouls END), 0) AS total_fouls,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_yellow ELSE m.away_yellow END), 0) AS total_yellow,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_red ELSE m.away_red END), 0) AS total_red,
    COALESCE(
        ROUND(
            (
                COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_yellow ELSE m.away_yellow END),0)*0.5 +
                COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_red ELSE m.away_red END),0)*1 +
                COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_fouls ELSE m.away_fouls END),0)*0.1
            ) / COUNT(*),
            2
        ),
        0
    ) AS aggressiveness_score
FROM fact_matches m
JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
GROUP BY t.team_name
ORDER BY aggressiveness_score DESC
LIMIT 20;

-- 7. v_team_scoring_efficiency: Csapat hatékonysági mutató: gól/lövés, gól/kapura lövés
CREATE OR REPLACE VIEW v_team_scoring_efficiency AS
SELECT 
    t.team_name,
    COUNT(*) AS matches_played,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.ft_home_goals ELSE m.ft_away_goals END), 0) AS total_goals,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END), 0) AS total_shots,
    COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END), 0) AS total_on_target,
    COALESCE(
        ROUND(
            COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.ft_home_goals ELSE m.ft_away_goals END),0)::numeric /
            NULLIF(COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_shots ELSE m.away_shots END),0),0),
            3
        ),
        0
    ) AS goals_per_shot,
    COALESCE(
        ROUND(
            COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.ft_home_goals ELSE m.ft_away_goals END),0)::numeric /
            NULLIF(COALESCE(SUM(CASE WHEN m.home_team_key = t.team_key THEN m.home_target ELSE m.away_target END),0),0),
            3
        ),
        0
    ) AS goals_per_on_target
FROM fact_matches m
JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
GROUP BY t.team_name
ORDER BY goals_per_shot DESC
LIMIT 20;

-- 8. v_team_goal_difference: Gólkülönbségek (heatmaphez)
CREATE OR REPLACE VIEW v_team_goal_difference AS
SELECT 
    ht.team_name AS home_team,
    at.team_name AS away_team,
    COALESCE(SUM(m.ft_home_goals - m.ft_away_goals), 0) AS goal_difference
FROM fact_matches m
JOIN dim_team ht ON ht.team_key = m.home_team_key
JOIN dim_team at ON at.team_key = m.away_team_key
GROUP BY ht.team_name, at.team_name
ORDER BY ABS(SUM(m.ft_home_goals - m.ft_away_goals)) DESC
LIMIT 20;


-- NEW ANALYTICAL VIEWS

-- 9. v_team_season_ranking: Team ranking by wins and goals per season
CREATE OR REPLACE VIEW v_team_season_ranking AS
WITH team_season_stats AS (
    SELECT 
        d.season,
        t.team_name,
        SUM(CASE WHEN m.ft_result = 'H' AND t.team_key = m.home_team_key THEN 1
                 WHEN m.ft_result = 'A' AND t.team_key = m.away_team_key THEN 1 ELSE 0 END) AS total_wins,
        SUM(CASE WHEN t.team_key = m.home_team_key THEN m.ft_home_goals 
                 WHEN t.team_key = m.away_team_key THEN m.ft_away_goals ELSE 0 END) AS total_goals
    FROM fact_matches m
    JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
    JOIN dim_date d ON d.date_key = m.date_key
    GROUP BY d.season, t.team_name
)
SELECT 
    season,
    team_name,
    total_wins,
    RANK() OVER(PARTITION BY season ORDER BY total_wins DESC) AS win_rank,
    total_goals,
    RANK() OVER(PARTITION BY season ORDER BY total_goals DESC) AS goal_rank
FROM team_season_stats;

-- 10. v_team_running_totals: Running totals for points and goals across a season
CREATE OR REPLACE VIEW v_team_running_totals AS
SELECT 
    d.season,
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
    ) OVER (PARTITION BY d.season, t.team_name ORDER BY d.full_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_points,
    SUM(
        CASE 
            WHEN t.team_key = m.home_team_key THEN m.ft_home_goals 
            ELSE m.ft_away_goals 
        END
    ) OVER (PARTITION BY d.season, t.team_name ORDER BY d.full_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_goals
FROM fact_matches m
JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
JOIN dim_date d ON d.date_key = m.date_key;

-- 11. v_team_mom_goals: Month-over-month goals scored per team
CREATE OR REPLACE VIEW v_team_mom_goals AS
WITH monthly_goals AS (
    SELECT 
        t.team_name,
        d.season,
        EXTRACT(YEAR FROM d.full_date) AS year,
        d.month,
        SUM(CASE WHEN t.team_key = m.home_team_key THEN m.ft_home_goals 
                 ELSE m.ft_away_goals END) AS goals_scored
    FROM fact_matches m
    JOIN dim_team t ON t.team_key IN (m.home_team_key, m.away_team_key)
    JOIN dim_date d ON d.date_key = m.date_key
    GROUP BY t.team_name, d.season, EXTRACT(YEAR FROM d.full_date), d.month
)
SELECT 
    team_name,
    season,
    year,
    month,
    goals_scored,
    LAG(goals_scored) OVER (PARTITION BY team_name ORDER BY year, month) AS prev_month_goals,
    goals_scored - LAG(goals_scored) OVER (PARTITION BY team_name ORDER BY year, month) AS mom_diff
FROM monthly_goals;

-- 12. v_team_performance_tier: A team performance-tier segmentation view (High/Mid/Low)
CREATE OR REPLACE VIEW v_team_performance_tier AS
WITH win_ratios AS (
    SELECT
        t.team_name,
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
        WHEN win_ratio >= 0.5 THEN 'High'
        WHEN win_ratio >= 0.3 THEN 'Mid'
        ELSE 'Low' 
    END AS performance_tier
FROM win_ratios;
