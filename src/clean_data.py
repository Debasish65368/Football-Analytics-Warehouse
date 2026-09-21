
"""
clean_data.py

Data cleaning and validation utilities for football matches dataset.
- Normalizes column names
- Removes invalid or incomplete rows
- Validates values (no future matches, no negative goals)
- Maps team names to database IDs
"""

import pandas as pd
import datetime
import logging
from .connect_db import conn

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

def map_dimensions_to_fact(df: pd.DataFrame) -> pd.DataFrame:
    """
    Map dimensional keys (team, date, division) to the fact table data
    and return the updated matches DataFrame.

    Args:
        df (pd.DataFrame): The cleaned DataFrame.
        
    Returns:
        pd.DataFrame: The mapped DataFrame ready for fact loading.
    """

    matches_df = df.copy()

    # Map teams
    with conn.cursor() as cur:
        cur.execute("SELECT team_key, team_name FROM dim_team;")
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    teams_df = pd.DataFrame(rows, columns=cols)
    team_mapping = dict(zip(teams_df['team_name'], teams_df['team_key']))
    matches_df = matches_df.rename(columns={"home_team": "home_team_key", "away_team": "away_team_key"})
    matches_df['home_team_key'] = matches_df['home_team_key'].map(team_mapping)
    matches_df['away_team_key'] = matches_df['away_team_key'].map(team_mapping)

    if matches_df["home_team_key"].isnull().any() or matches_df["away_team_key"].isnull().any():
        missing_home = matches_df['home_team_key'].isnull().sum()
        missing_away = matches_df['away_team_key'].isnull().sum()
        raise ValueError(f"Team mapping failed! Unmapped Home Teams: {missing_home}, Away Teams: {missing_away}")

    # Map divisions
    with conn.cursor() as cur:
        cur.execute("SELECT division_key, division_name, season_style FROM dim_division;")
        rows = cur.fetchall()
        cols = [desc[0] for desc in cur.description]
    divs_df = pd.DataFrame(rows, columns=cols)
    div_mapping = dict(zip(divs_df['division_name'], divs_df['division_key']))
    matches_df['division_key'] = matches_df['division_name'].map(div_mapping)

    if matches_df["division_key"].isnull().any():
        missing_div = matches_df['division_key'].isnull().sum()
        raise ValueError(f"Division mapping failed! Unmapped Divisions: {missing_div}")

    # Map dates (create date_key as YYYYMMDD)
    matches_df['date_key'] = pd.to_datetime(matches_df['match_date']).dt.strftime('%Y%m%d').astype(int)

    # Generate season
    matches_df['match_date_dt'] = pd.to_datetime(matches_df['match_date'])
    matches_df['year'] = matches_df['match_date_dt'].dt.year
    matches_df['month'] = matches_df['match_date_dt'].dt.month

    style_mapping = dict(zip(divs_df['division_name'], divs_df['season_style']))
    matches_df['season_style'] = matches_df['division_name'].map(style_mapping)

    def get_season(row):
        y = row['year']
        m = row['month']
        if row['season_style'] == 'CALENDAR':
            return str(y)
        else:
            # AUG_MAY divisions: month >= 7 starts the new season.
            # Most European leagues open in late July or August, so July openers
            # belong to the upcoming season (e.g. 2000-07-28 → "2000-01").
            #
            # ONE EXCEPTION: July 2020 matches belong to 2019-20.
            # COVID-19 suspended play from March–June 2020; leagues finished
            # their 2019-20 seasons in June/July 2020 before 2020-21 opened in Aug/Sep.
            if y == 2020 and m == 7:
                return "2019-20"
            return f"{y}-{(y+1)%100:02d}" if m >= 7 else f"{y-1}-{y%100:02d}"

    matches_df['season'] = matches_df.apply(get_season, axis=1)
    matches_df.drop(columns=['match_date_dt', 'year', 'month', 'season_style'], inplace=True)

    return matches_df

def validate_data_column_names(df: pd.DataFrame) -> pd.DataFrame:
    """
    Normalize column names: lowercase, strip spaces, replace spaces with underscores.
    """
    df.columns = (
        df.columns
        .str.strip()
        .str.lower()
        .str.replace(" ", "_")
    )
    return df

def drop_null_values(df: pd.DataFrame) -> pd.DataFrame:
    """
    Drop rows with null values in mandatory columns.
    """
    df = df.dropna(subset=['match_date', 'home_team', 'away_team',
                           'ft_home_goals','ft_away_goals','ft_result'])

    return df


def validate_values(df: pd.DataFrame) -> pd.DataFrame:
    """
    Validate dataset values:
    - Fix known encoding-mangled team names
    - Remove negative goal counts
    - Remove matches with future dates
    """
    today = datetime.date.today()

    # Strip trailing spaces from team names
    df['home_team'] = df['home_team'].str.strip()
    df['away_team'] = df['away_team'].str.strip()

    # --- Explicit fixes for encoding-mangled team names in the source CSV ---
    # "Preussen Munster" is the ASCII variant; the proper German name uses ß and ü.
    # "Preu\u00c3\u0178en M\u00c3\u00bcnster" is double-encoded mojibake of "Preußen Münster":
    #   the UTF-8 bytes for ß/ü were re-encoded, producing Ã+Ÿ and Ã+¼.
    # "King\u00c2\u2019s Lynn" is a double-encoded right single quote (Â + '):
    #   the original UTF-8 bytes for ' (U+2019: E2 80 99) were re-encoded as
    #   UTF-8 → Latin-1 → UTF-8, producing C3 82 (Â) + E2 80 99 (').
    TEAM_NAME_FIXES = {
        "Preussen Munster": "Preu\u00dfen M\u00fcnster",              # ASCII → proper German
        "Preu\u00c3\u0178en M\u00c3\u00bcnster": "Preu\u00dfen M\u00fcnster",  # double-encoded mojibake → proper German
        "King\u00c2\u2019s Lynn": "King's Lynn",                       # Â' (double-encoded) → ASCII apostrophe
    }
    df['home_team'] = df['home_team'].replace(TEAM_NAME_FIXES)
    df['away_team'] = df['away_team'].replace(TEAM_NAME_FIXES)

    # Log any team names that still contain non-ASCII characters
    all_teams = set(df['home_team'].dropna().unique()) | set(df['away_team'].dropna().unique())
    non_ascii_teams = sorted([t for t in all_teams if any(ord(c) > 127 for c in t)])
    if non_ascii_teams:
        logging.warning(
            "Team names with non-ASCII characters after cleaning: %s",
            non_ascii_teams
        )

    # Remove negative goals
    df = df[(df['ft_home_goals'] >= 0) & (df['ft_away_goals'] >= 0)]

    # Remove future matches
    df['match_date'] = pd.to_datetime(df['match_date'], errors='coerce')
    df = df[df['match_date'].dt.date <= today]

    return df

def clean_and_validate(df: pd.DataFrame) -> pd.DataFrame:
    """
    Clean and validate a matches DataFrame.
    Steps:
    1. Normalize column names
    2. Drop rows with null values
    3. Validate logical consistency of data
    """

    df = validate_data_column_names(df)
    df = drop_null_values(df)
    df = validate_values(df)


    logging.info("Values validated successfully.")

    return df
