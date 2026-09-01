/* =============================================================================
   Sales Analytics Pipeline - Automated Bronze Refresh
   36_copy_into_bronze.sql

   Companion to scripts/refresh_bronze_from_postgres.sh. Run via:
       snowsql -c <your_connection_name> -f 36_copy_into_bronze.sql

   Loads whatever was just PUT to @BRONZE.RAW_LANDING into the 4 Bronze
   tables, then prints row counts so the calling script can confirm the
   load actually landed data before it purges the stage.

   NOTE ON FILE_FORMAT: this assumes gzipped newline-delimited JSON (NDJSON
   -- one JSON object per line), matching the export in
   scripts/refresh_bronze_from_postgres.sh, which pulls the `raw_data`
   jsonb column directly from each raw.* Postgres table (confirmed via
   `\d raw.<table>` that every source table is a 2-column (raw_data jsonb,
   insert_date timestamp) shape -- do NOT use row_to_json(t) on the whole
   row, it adds a spurious wrapper level that breaks LEAD_ID/ACTIVITY_ID
   extraction downstream).
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA BRONZE;

COPY INTO BRONZE.LEADS_RAW (JSON_OBJECT, INSERT_DATE)
FROM (
    SELECT $1, CURRENT_TIMESTAMP()
    FROM @BRONZE.RAW_LANDING/leads_raw/
)
FILE_FORMAT = (TYPE = JSON)
ON_ERROR = 'ABORT_STATEMENT';

COPY INTO BRONZE.LEAD_ACTIVITIES_RAW (JSON_OBJECT, INSERT_DATE)
FROM (
    SELECT $1, CURRENT_TIMESTAMP()
    FROM @BRONZE.RAW_LANDING/lead_activites_raw/
)
FILE_FORMAT = (TYPE = JSON)
ON_ERROR = 'ABORT_STATEMENT';

COPY INTO BRONZE.CUSTOM_ACTIVITIES_RAW (JSON_OBJECT, INSERT_DATE)
FROM (
    SELECT $1, CURRENT_TIMESTAMP()
    FROM @BRONZE.RAW_LANDING/custom_activites_raw/
)
FILE_FORMAT = (TYPE = JSON)
ON_ERROR = 'ABORT_STATEMENT';

COPY INTO BRONZE.CLOSE_CRM_USERS_RAW (JSON_OBJECT, INSERT_DATE)
FROM (
    SELECT $1, CURRENT_TIMESTAMP()
    FROM @BRONZE.RAW_LANDING/close_crm_users_raw/
)
FILE_FORMAT = (TYPE = JSON)
ON_ERROR = 'ABORT_STATEMENT';

-- Post-load sanity check -- confirm the newest INSERT_DATE in each table
-- is from just now (proves this run actually loaded new rows, not a no-op).
SELECT 'LEADS_RAW' AS bronze_table, COUNT(*) AS total_rows, MAX(INSERT_DATE) AS latest_insert FROM BRONZE.LEADS_RAW
UNION ALL
SELECT 'LEAD_ACTIVITIES_RAW', COUNT(*), MAX(INSERT_DATE) FROM BRONZE.LEAD_ACTIVITIES_RAW
UNION ALL
SELECT 'CUSTOM_ACTIVITIES_RAW', COUNT(*), MAX(INSERT_DATE) FROM BRONZE.CUSTOM_ACTIVITIES_RAW
UNION ALL
SELECT 'CLOSE_CRM_USERS_RAW', COUNT(*), MAX(INSERT_DATE) FROM BRONZE.CLOSE_CRM_USERS_RAW;

/* -----------------------------------------------------------------------------
   Once you've confirmed the counts above look right, kick off the Silver/Gold/
   Export refresh so the new data actually flows through (don't wait for the
   9am scheduled task if you want it live now):
EXECUTE TASK ORCHESTRATION.TASK_REFRESH_SILVER_REAL;

   And once that + the stage purge (21_bronze_purge_real_data.sql) both look
   clean, the stage won't keep re-accumulating the files this run just PUT.
----------------------------------------------------------------------------- */
