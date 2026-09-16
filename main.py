"""
main.py

Entry point of the ETL pipeline:
- Reads raw match data from CSV
- Cleans and validates the data
- Inserts teams and matches into PostgreSQL
- Prevents duplicate loading if data already exists
"""

import pandas as pd
import logging

from src.insert_datas import load_teams, load_divisions, load_dates, load_matches, create_views
from src.clean_data import clean_and_validate, map_dimensions_to_fact
from src.connect_db import ensure_database_initialized
from src.connect_db import conn

# CSV files paths
CSV_RAW_PATH = "Data/Matches.csv" 

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

def main():
    # check if database exists if not then create it
    try:
        if not ensure_database_initialized():
            logging.info("Database empty or not existing. Starting data load...")

            # Load csv data
            df = pd.read_csv(CSV_RAW_PATH,encoding='utf-8',sep=',')

            # Clean data
            df = clean_and_validate(df)

            # Load dimension tables
            load_teams(df)
            load_divisions(df)
            load_dates(df)

            # Map dimensions to facts
            df_mapped = map_dimensions_to_fact(df)

            # Insert matches
            load_matches(df_mapped)
            logging.info("Datas loaded into the database successfully!")

            # ---> View-k létrehozása
            create_views(conn)

        else:
            logging.info("Datas already exists")        
        conn.close()
    except Exception as e:
        logging.error("ETL process failed",exc_info=True)
        raise
    finally:
        conn.close()
        logging.info("Database connection closed.")

if __name__ == "__main__":
    main()