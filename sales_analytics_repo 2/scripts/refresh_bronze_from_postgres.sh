#!/usr/bin/env bash
# =============================================================================
# Sales Analytics Pipeline - Automated Bronze Refresh
# refresh_bronze_from_postgres.sh
#
# Automates the exact manual process you've been running by hand: export
# each of the 4 raw tables from Postgres as gzipped NDJSON, PUT them to
# @BRONZE.RAW_LANDING via SnowSQL, then COPY INTO the Bronze tables.
#
# This runs OUTSIDE Snowflake, so it isn't blocked by the trial account's
# lack of External Access Integration -- that limitation only prevents
# Snowflake itself from reaching out to Postgres.
#
# NOTE: written to be portable across bash versions -- deliberately avoids
# associative arrays (declare -A), since macOS's default /bin/bash is an
# old 3.2 build that doesn't support them.
#
# NOTE: all 4 PUT statements and the COPY INTO step run as ONE SnowSQL
# session, so you only have to enter your password and approve a Duo
# push ONCE per run.
#
# NOTE: exports pull the `raw_data` column directly (confirmed via `\d`
# that every raw.* table is a 2-column (raw_data jsonb, insert_date
# timestamp) shape). Earlier versions used `row_to_json(t)`, which wraps
# the ENTIRE Postgres row -- including the insert_date bookkeeping
# column -- adding a spurious nesting level ({"insert_date":...,
# "raw_data":{...actual record...}}) that doesn't match what Bronze/
# Silver expect (JSON_OBJECT:id at the top level). That mismatch caused
# every LEAD_ID to resolve to NULL and the Silver MERGE to fail outright.
# Also uses plain `psql -tA -c "SELECT ..."` rather than
# `COPY ... TO STDOUT`, since COPY's TEXT format double-escapes
# backslashes and corrupts JSON text that already contains
# backslash-escaped characters.
#
# SETUP (one-time):
#   1. Requires `psql` and `snowsql` on PATH.
#   2. Postgres connection: uses standard libpq env vars (PGHOST, PGPORT,
#      PGDATABASE, PGUSER) plus a `.pgpass` file for the password.
#   3. Snowflake connection: uses a named SnowSQL connection from
#      ~/.snowsql/config (SNOWSQL_CONNECTION below).
#
# USAGE:
#   ./refresh_bronze_from_postgres.sh
#
# EXIT CODE: non-zero on any failure (export, PUT, or COPY INTO).
# =============================================================================

set -euo pipefail

# ---- Configuration -----------------------------------------------------
SNOWSQL_CONNECTION="${SNOWSQL_CONNECTION:-sales_analytics}"   # name in ~/.snowsql/config
RAW_SCHEMA="raw"
WORKDIR="$(mktemp -d)"
LOGFILE="${LOGFILE:-$HOME/sales_analytics_bronze_refresh.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COPY_INTO_SQL="$SCRIPT_DIR/36_copy_into_bronze.sql"

# Postgres tables to export -- stage subfolder name matches the table name
# exactly in every case, so a single list is enough (no associative array).
TABLES="leads_raw lead_activites_raw custom_activites_raw close_crm_users_raw"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

log "=== Bronze refresh started ==="
log "Work dir: $WORKDIR"

# ---- Step 1: Export each table's raw_data column as gzipped NDJSON ----
for table in $TABLES; do
    outfile="$WORKDIR/${table}.json.gz"
    log "Exporting ${RAW_SCHEMA}.${table}.raw_data -> ${outfile}"
    psql -tA -c "SELECT raw_data FROM ${RAW_SCHEMA}.${table}" \
        | gzip > "$outfile"
    rows=$(gunzip -c "$outfile" | wc -l | tr -d ' ')
    log "  -> ${rows} rows exported"
    if [ "$rows" -eq 0 ]; then
        log "  WARNING: 0 rows exported for ${table} -- check Postgres connection/table name"
    fi
done

# ---- Step 2: Build ONE SnowSQL session that PUTs all 4 files, then -----
# ---- runs the COPY INTO + verification queries. One login, one Duo push.
PUT_AND_LOAD_SQL="$WORKDIR/put_and_load.sql"
{
    for table in $TABLES; do
        echo "PUT file://$WORKDIR/${table}.json.gz @BRONZE.RAW_LANDING/${table}/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;"
    done
    cat "$COPY_INTO_SQL"
} > "$PUT_AND_LOAD_SQL"

log "Connecting to Snowflake (you'll be prompted for your password + Duo push once)..."
snowsql -c "$SNOWSQL_CONNECTION" -f "$PUT_AND_LOAD_SQL"

log "=== Bronze refresh completed successfully ==="
log "Next: confirm the row counts above look right, then either wait for"
log "the 9am scheduled Silver refresh or run EXECUTE TASK"
log "ORCHESTRATION.TASK_REFRESH_SILVER_REAL manually. Purge the stage"
log "(21_bronze_purge_real_data.sql) once you're confident the load is good."
