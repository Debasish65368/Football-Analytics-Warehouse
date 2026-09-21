import os
import logging
import psycopg2
from dotenv import load_dotenv

# --- Load env variables ---
load_dotenv()

DB_USER = os.getenv("DB_USER")
DB_PASS = os.getenv("DB_PASS")
DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT")
DB_NAME = os.getenv("DB_NAME")

CREATE_TABLES_PATH  = "PostgreSQL/Create_tables.sql"

# --- Setup logging ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

# --- Create global connection ---
try:
    conn = psycopg2.connect(
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASS,
        host=DB_HOST,
        port=DB_PORT
    )
    conn.autocommit = True
    logging.info("Connected to PostgreSQL database successfully.")
except Exception as e:
    logging.error("Database connection failed", exc_info=True)
    raise

def ensure_database_initialized() -> bool:
    """
    Ensures that the required tables (teams, matches) exist in the database.
    If missing, creates them from the SQL script.
    
    Returns:
        bool: True if tables exist and contain data, False otherwise.
    """

    required_tables = {"dim_team", "dim_date", "dim_division", "fact_matches"}
    has_data = True

    try:
        with conn.cursor() as cursor:
            # Get existing tables
            cursor.execute("""
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
            """)
            existing_tables = {row[0] for row in cursor.fetchall()}

            if required_tables.issubset(existing_tables):
                # Check if tables have data
                for table in required_tables:
                    cursor.execute(f"SELECT 1 FROM {table} LIMIT 1;")
                    if not cursor.fetchone():
                        has_data = False
                        break
            else:
                present = required_tables & existing_tables
                missing = required_tables - existing_tables

                if present:
                    # PARTIAL schema: some required tables exist, others don't.
                    # Running Create_tables.sql would DROP existing tables and
                    # destroy data. Abort with a clear error instead.
                    raise RuntimeError(
                        f"Partial database schema detected — automatic initialization aborted "
                        f"to prevent data loss. "
                        f"Present tables: {sorted(present)}. "
                        f"Missing tables: {sorted(missing)}. "
                        f"Resolve manually: either drop the remaining tables to allow a "
                        f"clean initialization, or create the missing tables by hand."
                    )

                # Completely fresh database: no required tables exist at all.
                with open(CREATE_TABLES_PATH, "r", encoding="utf-8") as f:
                    cursor.execute(f.read())
                logging.info("Missing tables created from SQL script.")
                has_data = False

    except Exception as e:
        logging.error("Error while initializing database", exc_info=True)
        raise

    return has_data