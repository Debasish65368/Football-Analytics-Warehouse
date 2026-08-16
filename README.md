# ⚽ Football Analytics Platform

An end-to-end data engineering and analytics project that transforms raw football match data (2000–2025, ~230K matches) into a fully containerized ETL pipeline with a dimensional data warehouse and an interactive Power BI dashboard.

---

## 📊 Dashboard Preview

### League Overview
![League Overview](screenshots/league-overview.png)

### Team Performance
![Team Performance](screenshots/team-performance.png)

### Top 20 Leaderboards
![Top 20 Leaderboards](screenshots/top-20-leaderboards.png)

### Win Ratios & Rivalries
![Win Ratios & Rivalries](screenshots/win-ratios-rivalries.png)

---

## 🏗️ Architecture

```
CSV (raw match data)
        ▼
Python ETL (clean → validate → load)
        ▼
PostgreSQL — Star Schema (Docker)
        ▼
Power BI — 4-page interactive dashboard
```

The entire stack — PostgreSQL and the Python ETL application — runs in Docker containers, orchestrated with Docker Compose.

---

## 🗃️ Data Model — Star Schema

The database was migrated from a flat two-table design to a proper dimensional star schema for analytical performance and clarity:

| Table | Type | Description |
|---|---|---|
| `dim_team` | Dimension | Surrogate-keyed team lookup (1,206 teams) |
| `dim_date` | Dimension | Fully populated date dimension (9,075 days) with month, quarter, and season |
| `dim_division` | Dimension | League/division lookup (38 divisions) |
| `fact_matches` | Fact | 230,554 match records with all pre-match, in-game, and result metrics |

**Why a star schema over the original flat design:** normalizing teams, divisions, and dates into dimension tables removes redundancy, enables consistent joins across all analytical views, and mirrors how real-world data warehouses are structured for BI consumption — a flat wide table doesn't scale cleanly once you need time-based aggregation (e.g. month-over-month trends, season-over-season rankings).

---

## 📈 Analytical Views

12 SQL views built on the star schema, covering both descriptive and advanced analytics:

**Descriptive**
- `avg_goals_per_team`, `win_ratio_per_team`, `division_stats`
- `v_team_elo_trend`, `v_team_shooting_efficiency`, `v_team_aggressiveness`, `v_team_scoring_efficiency`, `v_team_goal_difference`

**Advanced (window functions)**
- `v_team_season_ranking` — `RANK()` over wins/goals per season
- `v_team_running_totals` — cumulative points and goals across a season
- `v_team_mom_goals` — month-over-month scoring trend via `LAG()`
- `v_team_performance_tier` — `CASE`-based High/Mid/Low segmentation by win ratio

---

## 🐳 Tech Stack

- **Database:** PostgreSQL 15
- **ETL:** Python (pandas, psycopg2)
- **Containerization:** Docker & Docker Compose
- **Visualization:** Power BI Desktop
- **Version Control:** Git

---

## ⚙️ ETL Pipeline

`main.py` orchestrates an idempotent pipeline:

1. Checks whether the database is already initialized and populated (skips reload if so)
2. Loads raw CSV data and cleans/validates it (null handling, negative-goal filtering, future-date filtering)
3. Loads dimension tables: `dim_team`, `dim_division`, `dim_date`
4. Maps team/division/date keys onto the fact data
5. Bulk-loads `fact_matches`
6. Builds all 12 analytical views

---

## 🚀 Running the Project

```bash
# Clone the repo
git clone <your-repo-url>
cd Football-project-main

# Create a .env file with your DB credentials
DB_USER=postgres
DB_PASS=your_password
DB_HOST=football-db
DB_PORT=5432
DB_NAME=Football_stats

# Build and run
docker-compose up --build
```

Postgres will initialize the star schema automatically; the app container runs the full ETL and populates all tables and views on first launch.

---

## 📊 Power BI Dashboard

A 4-page interactive report built on top of the star schema and analytical views:

1. **League Overview** — KPI summary cards, match distribution by division, league stats table
2. **Team Performance** — cumulative points/season, season rankings, performance-tier breakdown, month-over-month trends (fully interactive, team/season slicers)
3. **Top 20 Leaderboards** — most aggressive teams, top ELO readings, most clinical finishers, shots vs. shooting accuracy
4. **Win Ratios & Rivalries** — top 20 teams by win ratio, biggest rivalry blowouts by goal difference

---

## 🔧 Key Engineering Challenges Solved

- **CHAR padding bug**: Postgres `CHAR(n)` right-pads values, which silently broke division-key lookups after the schema migration — fixed by switching to `VARCHAR`
- **Docker startup race condition**: the app container was connecting before Postgres finished initializing — resolved with a proper `healthcheck` + `depends_on: condition: service_healthy`
- **Stale image caching**: schema/code changes weren't reflected without `docker-compose up --build`, which cost significant debugging time before being identified
- **Port conflict**: a native Windows PostgreSQL service silently intercepted connections meant for the Docker container on port 5432

---

## 📁 Project Structure

```
Football-project-main/
├── Data/              # Raw and processed CSV files
├── PostgreSQL/         # Schema DDL and view definitions
├── Power-BI/           # .pbix dashboard file
├── screenshots/        # Dashboard page screenshots
├── src/                # ETL Python modules
├── main.py             # Pipeline entry point
├── Dockerfile
├── docker-compose.yml
└── requirements.txt
```