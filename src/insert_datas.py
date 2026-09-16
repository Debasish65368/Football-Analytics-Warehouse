"""
load_data.py

ETL Load step:
- Insert into dimensions: dim_team, dim_division, dim_date
- Insert facts into fact_matches
"""
import logging
import pandas as pd
from src.connect_db import conn
from psycopg2.extras import execute_values

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

def load_teams(df: pd.DataFrame) -> None:
    """
    Load unique teams into the `dim_team` table.
    """
    home_teams = df[['home_team']].rename(columns={'home_team': 'team_name'})
    away_teams = df[['away_team']].rename(columns={'away_team': 'team_name'})
    df_teams = pd.concat([home_teams, away_teams]).drop_duplicates()

    cursor = conn.cursor()
    insert_query = """
        INSERT INTO dim_team (team_name)
        VALUES %s
        ON CONFLICT (team_name) DO NOTHING;
    """
    team_values = [(team,) for team in df_teams["team_name"]]
    try:
        execute_values(cursor, insert_query, team_values)
        conn.commit()
        logging.info(f"Inserted {len(team_values)} teams into `dim_team` table.")
    except Exception as e:
        conn.rollback()
        logging.error(f"Error inserting teams: {e}")
        raise
    finally:
        cursor.close()

def load_divisions(df: pd.DataFrame) -> None:
    """
    Load unique divisions into the `dim_division` table.
    """
    divisions = df[['division_name']].drop_duplicates().dropna().copy()
    calendar_leagues = {'SWE', 'NOR', 'USA', 'IRL', 'FIN', 'JAP', 'CHN', 'BRA', 'ARG'}
    divisions['season_style'] = divisions['division_name'].apply(
        lambda x: 'CALENDAR' if x in calendar_leagues else 'AUG_MAY'
    )
    cursor = conn.cursor()
    insert_query = """
        INSERT INTO dim_division (division_name, season_style)
        VALUES %s
        ON CONFLICT (division_name) DO NOTHING;
    """
    values = [tuple(x) for x in divisions[['division_name', 'season_style']].to_numpy()]
    try:
        execute_values(cursor, insert_query, values)
        conn.commit()
        logging.info(f"Inserted {len(values)} divisions into `dim_division` table.")
    except Exception as e:
        conn.rollback()
        logging.error(f"Error inserting divisions: {e}")
        raise
    finally:
        cursor.close()

def load_dates(df: pd.DataFrame) -> None:
    """
    Load a continuous date dimension covering the full range of match_date in the dataset.
    """
    df_dates = df.copy()
    df_dates['match_date'] = pd.to_datetime(df_dates['match_date'])
    min_date = df_dates['match_date'].min()
    max_date = df_dates['match_date'].max()
    date_range = pd.date_range(start=min_date, end=max_date)
    
    dates_data = []
    for d in date_range:
        date_key = int(d.strftime('%Y%m%d'))
        full_date = d.date()
        month = d.month
        quarter = d.quarter
        dates_data.append((date_key, full_date, month, quarter))
        
    cursor = conn.cursor()
    insert_query = """
        INSERT INTO dim_date (date_key, full_date, month, quarter)
        VALUES %s
        ON CONFLICT (date_key) DO NOTHING;
    """
    try:
        execute_values(cursor, insert_query, dates_data)
        conn.commit()
        logging.info(f"Inserted {len(dates_data)} dates into `dim_date` table.")
    except Exception as e:
        conn.rollback()
        logging.error(f"Error inserting dates: {e}")
        raise
    finally:
        cursor.close()

def load_matches(df: pd.DataFrame) -> None:
    """
    Load match data into the `fact_matches` table.
    """
    cursor = conn.cursor()
    df_matches = df[[
        'date_key', 'season', 'division_key', 'home_team_key', 'away_team_key',
        'ft_home_goals', 'ft_away_goals', 'ft_result',
        'home_elo', 'away_elo', 'home_form3', 'home_form5', 'away_form3', 'away_form5',
        'ht_home_goals', 'ht_away_goals', 'ht_result',
        'home_shots', 'away_shots', 'home_target', 'away_target',
        'home_fouls', 'away_fouls', 'home_corners', 'away_corners',
        'home_yellow', 'away_yellow', 'home_red', 'away_red'
    ]]

    values = [tuple(x) 
              for x in df_matches.astype(object).where(pd.notnull(df_matches), None).to_numpy()]

    insert_query = """
        INSERT INTO fact_matches (
            date_key, season, division_key, home_team_key, away_team_key,
            ft_home_goals, ft_away_goals, ft_result,
            home_elo, away_elo, home_form3, home_form5, away_form3, away_form5,
            ht_home_goals, ht_away_goals, ht_result,
            home_shots, away_shots, home_target, away_target,
            home_fouls, away_fouls, home_corners, away_corners,
            home_yellow, away_yellow, home_red, away_red
        )
        VALUES %s
        ON CONFLICT (date_key, home_team_key, away_team_key) DO NOTHING;
    """
    try:
        execute_values(cursor, insert_query, values)
        conn.commit()
        logging.info(f"Inserted {len(values)} matches into `fact_matches` table.")
    except Exception as e:
        conn.rollback()
        logging.error(f"Error inserting matches: {e}")
        raise
    finally:
        cursor.close()

def create_views(conn, sql_file="PostgreSQL/create_views.sql"):
    try:
        cursor = conn.cursor()
        with open(sql_file, "r", encoding="utf-8") as f:
            sql = f.read()
        cursor.execute(sql)
        conn.commit()
        logging.info("✅ Views created successfully.")
    except Exception as e:
        conn.rollback()
        logging.error(f"Error creating views: {e}", exc_info=True)
        raise
    finally:
        cursor.close()
