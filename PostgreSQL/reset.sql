-- reset.sql
--
-- DESTRUCTIVE reset script — drops ALL views and tables and recreates them.
-- Use this ONLY for manual full resets (e.g., during development or when you
-- need to rebuild the warehouse from scratch).
--
-- Usage:
--   docker exec -i football-db psql -U postgres -d Football_stats < PostgreSQL/reset.sql
--
-- WARNING: This will permanently delete all data in the warehouse.

-- 1. Drop all dependent views first
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
    v_team_performance_tier
CASCADE;

-- 2. Then drop the tables
DROP TABLE IF EXISTS fact_matches CASCADE;
DROP TABLE IF EXISTS dim_division CASCADE;
DROP TABLE IF EXISTS dim_date CASCADE;
DROP TABLE IF EXISTS dim_team CASCADE;
DROP TABLE IF EXISTS matches CASCADE;
DROP TABLE IF EXISTS teams CASCADE;
