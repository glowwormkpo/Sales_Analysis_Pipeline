/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data)
   18_orchestration_real_data.sql

   Rebuilds the Task DAG in SALES_ANALYTICS.ORCHESTRATION (the schema you
   already created to work around Snowflake's cross-schema AFTER-predecessor
   restriction) to run the real-data pipeline instead of the Phase 3
   synthetic-data procedures.

   IMPORTANT CHANGE FROM THE PHASE 3 DAG: Bronze ingestion (BRONZE.
   TASK_LOAD_BRONZE) is dropped from the automated DAG entirely. Real Bronze
   data only gets there via a manual process on your machine -- export from
   Postgres with psql, PUT the files to the stage with SnowSQL, then COPY
   INTO Bronze -- because Snowflake trial accounts can't use External Access
   Integration (confirmed earlier), so there's no way for a scheduled Task
   to reach out and pull fresh Postgres data on its own. That's a hard
   platform limitation, not something this DAG can route around.

   What IS automated: once you've manually refreshed Bronze, this DAG keeps
   Silver and the exported reports in sync with it on a schedule, so you
   don't have to remember to re-run the Silver/Gold/export scripts by hand
   every time. SILVER.REFRESH_ALL_REAL_DATA() is a full rebuild (not
   incremental), so it's safe to run on a schedule even if Bronze hasn't
   changed since the last run -- it just re-derives the same result.

   DAG shape (2 tasks instead of Phase 3's 5 -- no Bronze load task, and no
   separate "transient" vs "merge" split since the real-data load is a
   single full-refresh procedure rather than day-by-day incremental MERGE):

     SILVER.TASK_REFRESH_SILVER_REAL  (root, scheduled)
       -> calls SILVER.REFRESH_ALL_REAL_DATA()
     GOLD.TASK_EXPORT_REPORTS_REAL  (AFTER the above)
       -> calls GOLD.EXPORT_ALL_REPORTS()  (existing procedure, unchanged --
          it just re-runs the same 4 COPY INTO unloads against whatever the
          GOLD.RPT_* views currently return)

   Both created SUSPENDED, same as Phase 3 -- resume explicitly when ready.
   The old Phase 3 tasks (ORCHESTRATION.TASK_LOAD_BRONZE / TASK_SILVER_
   TRANSIENT / TASK_SILVER_MERGE / TASK_EXPORT_REPORTS / TASK_PURGE_STAGE, or
   whatever they ended up named in your ORCHESTRATION schema) are left alone
   here -- suspend/drop them yourself once you've confirmed the new DAG works,
   so there's no window where both are trying to run against the same tables.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE WAREHOUSE SALES_ANALYTICS_WH;
USE SCHEMA ORCHESTRATION;

CREATE OR REPLACE TASK ORCHESTRATION.TASK_REFRESH_SILVER_REAL
    WAREHOUSE = SALES_ANALYTICS_WH
    SCHEDULE = 'USING CRON 0 9 * * * America/New_York'  -- 09:00 AM EST daily; adjust to taste
    COMMENT = 'Root task: full rebuild of real-data Silver from whatever is currently in Bronze.'
AS
    CALL SILVER.REFRESH_ALL_REAL_DATA();

CREATE OR REPLACE TASK ORCHESTRATION.TASK_EXPORT_REPORTS_REAL
    WAREHOUSE = SALES_ANALYTICS_WH
    COMMENT = 'Re-exports the 4 report CSVs after the Silver refresh completes.'
    AFTER ORCHESTRATION.TASK_REFRESH_SILVER_REAL
AS
    CALL GOLD.EXPORT_ALL_REPORTS();

/* -----------------------------------------------------------------------------
   Activate the DAG (leaf-to-root order is required by Snowflake):
   -----------------------------------------------------------------------------
ALTER TASK ORCHESTRATION.TASK_EXPORT_REPORTS_REAL RESUME;
ALTER TASK ORCHESTRATION.TASK_REFRESH_SILVER_REAL RESUME;

   Suspend the same way, root-to-leaf:
ALTER TASK ORCHESTRATION.TASK_REFRESH_SILVER_REAL SUSPEND;
ALTER TASK ORCHESTRATION.TASK_EXPORT_REPORTS_REAL SUSPEND;

   Manual one-off run (don't wait for the schedule):
ALTER TASK ORCHESTRATION.TASK_REFRESH_SILVER_REAL RESUME;
EXECUTE TASK ORCHESTRATION.TASK_REFRESH_SILVER_REAL;

   Monitor recent runs:
SELECT *
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP())))
ORDER BY SCHEDULED_TIME DESC;

   Find + retire the old Phase 3 synthetic-data tasks once you've confirmed
   the new DAG works:
SHOW TASKS IN SCHEMA SALES_ANALYTICS.ORCHESTRATION;
----------------------------------------------------------------------------- */
