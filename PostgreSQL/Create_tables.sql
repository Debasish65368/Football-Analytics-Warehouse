-- Dimension Tables
CREATE TABLE IF NOT EXISTS dim_team (
    team_key SERIAL PRIMARY KEY,
    team_name VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS dim_date (
    date_key INT PRIMARY KEY,
    full_date DATE NOT NULL UNIQUE,
    month INT NOT NULL,
    quarter INT NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_division (
    division_key SERIAL PRIMARY KEY,
    division_name VARCHAR(4) NOT NULL UNIQUE,
    season_style VARCHAR(10) NOT NULL
);

-- Fact Table
CREATE TABLE IF NOT EXISTS fact_matches (
    match_id SERIAL PRIMARY KEY,
    date_key INT NOT NULL REFERENCES dim_date(date_key),
    season VARCHAR(10) NOT NULL,
    division_key INT NOT NULL REFERENCES dim_division(division_key),
    home_team_key INT NOT NULL REFERENCES dim_team(team_key),
    away_team_key INT NOT NULL REFERENCES dim_team(team_key),
    ft_home_goals INT,
    ft_away_goals INT,
    ft_result CHAR(1),  -- H / D / A
    home_elo NUMERIC(7,2),
    away_elo NUMERIC(7,2),
    home_form3 INT,
    home_form5 INT,
    away_form3 INT,
    away_form5 INT,	
    ht_home_goals INT,
    ht_away_goals INT,
    ht_result CHAR(1),   -- H / D / A
    home_shots INT,
    away_shots INT,
    home_target INT,
    away_target INT,
    home_fouls INT,
    away_fouls INT,
    home_corners INT,
    away_corners INT,
    home_yellow INT,
    away_yellow INT,
    home_red INT,
    away_red INT,
    UNIQUE (date_key, home_team_key, away_team_key)
);

-- Indexes for fast lookups
CREATE INDEX IF NOT EXISTS idx_fact_matches_date ON fact_matches(date_key);
CREATE INDEX IF NOT EXISTS idx_fact_matches_division ON fact_matches(division_key);
CREATE INDEX IF NOT EXISTS idx_fact_matches_teams ON fact_matches(home_team_key, away_team_key);
