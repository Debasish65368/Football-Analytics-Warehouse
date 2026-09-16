
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

def map_dimensions_to_fact(csv_file: str, csv_file_out: str) -> None:
    """
    Map dimensional keys (team, date, division) to the fact table data
    and save the updated matches to a new CSV file.

    Args:
        csv_file (str): Path to the input CSV.
        csv_file_out (str): Path to the output CSV with dimensional keys.
    """

    matches_df = pd.read_csv(csv_file)

    # Map teams
    teams_df = pd.read_sql("SELECT * FROM dim_team;", conn)
    team_mapping = dict(zip(teams_df['team_name'], teams_df['team_key']))
    matches_df = matches_df.rename(columns={"home_team": "home_team_key", "away_team": "away_team_key"})
    matches_df['home_team_key'] = matches_df['home_team_key'].map(team_mapping)
    matches_df['away_team_key'] = matches_df['away_team_key'].map(team_mapping)

    if matches_df["home_team_key"].isnull().any() or matches_df["away_team_key"].isnull().any():
        logging.warning("Some team names could not be mapped to keys.")

    # Map divisions
    divs_df = pd.read_sql("SELECT * FROM dim_division;", conn)
    div_mapping = dict(zip(divs_df['division_name'], divs_df['division_key']))
    matches_df['division_key'] = matches_df['division_name'].map(div_mapping)

    if matches_df["division_key"].isnull().any():
        logging.warning("Some division names could not be mapped to keys.")

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
        if row['season_style'] == 'CALENDAR':
            return str(y)
        else:
            return f"{y}-{(y+1)%100:02d}" if row['month'] >= 8 else f"{y-1}-{y%100:02d}"

    matches_df['season'] = matches_df.apply(get_season, axis=1)
    matches_df.drop(columns=['match_date_dt', 'year', 'month', 'season_style'], inplace=True)

    # Save it into new csv file
    matches_df.to_csv(csv_file_out, index=False)
    logging.info(f"File {csv_file_out} created successfully.")

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
    - Remove negative goal counts
    - Remove matches with future dates
    """
    today = datetime.date.today()

    # Strip trailing spaces from team names
    df['home_team'] = df['home_team'].str.strip()
    df['away_team'] = df['away_team'].str.strip()

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

    # save it again
    df.to_csv('Data/Matches.csv', index=False)

    logging.info("Values validated successfully.")

    return df
