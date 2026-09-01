/* =============================================================================
   Sales Analytics Pipeline - Phase 3
   09_orchestration_tasks_streams.sql

   Daily orchestration DAG: Bronze -> Silver Transient -> Silver Merge -> Gold
   (views, so nothing to run) -> Export. Streams on the Bronze tables gate
   each downstream task so it only fires when that day's COPY INTO actually
   landed new rows -- if the 07:30 AM EST source refresh is late or fails,
   downstream tasks simply skip that run instead of processing stale/empty data.

   Trial-account note: CREATE TASK requires a schedule owner role with the
   EXECUTE TASK privilege, which trial accounts have by default for ACCOUNTADMIN.
   Tasks are created SUSPENDED -- resume the root task explicitly once you're
   ready to let it run on its own schedule; for the 7-day simulation, keep
   using the manual CALL sequence in the runbook instead so each "day" is
   under your control.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE WAREHOUSE SALES_ANALYTICS_WH;

-- ---------------------------------------------------------------------------
-- Streams: track new rows landed by each day's Bronze COPY INTO
-- ---------------------------------------------------------------------------
CREATE STREAM IF NOT EXISTS BRONZE.LEAD_ACTIVITIES_RAW_STREAM
    ON TABLE BRONZE.LEAD_ACTIVITIES_RAW
    APPEND_ONLY = TRUE
    COMMENT = 'Gates the Silver transient/merge tasks -- only run when a new daily file actually landed.';

CREATE STREAM IF NOT EXISTS SILVER.LEADS_ACTIVITIES_SUMMARY_STREAM
    ON TABLE SILVER.LEADS_ACTIVITIES_SUMMARY
    APPEND_ONLY = FALSE
    COMMENT = 'Gates the Export task -- only unload reports when Gold-feeding Silver data actually changed.';

-- ---------------------------------------------------------------------------
-- Export wrapper procedure (re-runs the COPY INTO unloads from 08_export_unload.sql)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GOLD.EXPORT_ALL_REPORTS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_setter_report/inbound/
        FROM (SELECT * FROM GOLD.RPT_INBOUND_SETTER)
        FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
        OVERWRITE = TRUE SINGLE = TRUE HEADER = TRUE;

    COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_setter_report/outbound/
        FROM (SELECT * FROM GOLD.RPT_OUTBOUND_SETTER)
        FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
        OVERWRITE = TRUE SINGLE = TRUE HEADER = TRUE;

    COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_closer_report/closer_report/
        FROM (SELECT * FROM GOLD.RPT_CLOSER)
        FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
        OVERWRITE = TRUE SINGLE = TRUE HEADER = TRUE;

    COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_closer_report/objections_faced/
        FROM (SELECT * FROM GOLD.RPT_OBJECTIONS_FACED)
        FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
        OVERWRITE = TRUE SINGLE = TRUE HEADER = TRUE;

    RETURN 'Export complete: ' || TO_VARCHAR(CURRENT_TIMESTAMP());
END;
$$;

-- ---------------------------------------------------------------------------
-- Stage cleanup: purge processed Bronze source files for a given date so the
-- landing stage doesn't grow unbounded (Phase 1 Sec. 8).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE BRONZE.PURGE_LOADED_FILES(LOAD_DATE DATE)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    dt_pattern STRING DEFAULT '.*dt=' || TO_VARCHAR(:LOAD_DATE, 'YYYY-MM-DD') || '.*';
BEGIN
    REMOVE @BRONZE.RAW_LANDING/lead_activites_raw/ PATTERN = :dt_pattern;
    REMOVE @BRONZE.RAW_LANDING/custom_activites_raw/ PATTERN = :dt_pattern;
    REMOVE @BRONZE.RAW_LANDING/close_crm_users_raw/ PATTERN = :dt_pattern;
    REMOVE @BRONZE.RAW_LANDING/leads_raw/ PATTERN = :dt_pattern;
    RETURN 'Purged stage files for ' || TO_VARCHAR(:LOAD_DATE, 'YYYY-MM-DD');
END;
$$;

-- ---------------------------------------------------------------------------
-- Task DAG (created SUSPENDED -- see trial-account note above)
-- ---------------------------------------------------------------------------
CREATE TASK IF NOT EXISTS BRONZE.TASK_LOAD_BRONZE
    WAREHOUSE = SALES_ANALYTICS_WH
    SCHEDULE = 'USING CRON 30 8 * * * America/New_York'  -- 08:30 AM EST, 1hr buffer after the 07:30 source refresh
    COMMENT = 'Root task: daily Bronze load.'
AS
    CALL BRONZE.LOAD_BRONZE_DAY(CURRENT_DATE());

CREATE TASK IF NOT EXISTS SILVER.TASK_SILVER_TRANSIENT
    WAREHOUSE = SALES_ANALYTICS_WH
    AFTER BRONZE.TASK_LOAD_BRONZE
    WHEN SYSTEM$STREAM_HAS_DATA('BRONZE.LEAD_ACTIVITIES_RAW_STREAM')
AS
    CALL SILVER.LOAD_SILVER_TRANSIENT(CURRENT_DATE());

CREATE TASK IF NOT EXISTS SILVER.TASK_SILVER_MERGE
    WAREHOUSE = SALES_ANALYTICS_WH
    AFTER SILVER.TASK_SILVER_TRANSIENT
AS
    CALL SILVER.MERGE_SILVER_DAY(CURRENT_DATE());

CREATE TASK IF NOT EXISTS GOLD.TASK_EXPORT_REPORTS
    WAREHOUSE = SALES_ANALYTICS_WH
    AFTER SILVER.TASK_SILVER_MERGE
    WHEN SYSTEM$STREAM_HAS_DATA('SILVER.LEADS_ACTIVITIES_SUMMARY_STREAM')
AS
    CALL GOLD.EXPORT_ALL_REPORTS();

CREATE TASK IF NOT EXISTS BRONZE.TASK_PURGE_STAGE
    WAREHOUSE = SALES_ANALYTICS_WH
    AFTER GOLD.TASK_EXPORT_REPORTS
AS
    CALL BRONZE.PURGE_LOADED_FILES(CURRENT_DATE());

/* -----------------------------------------------------------------------------
   Activate the DAG (leaf-to-root order is required by Snowflake):
   -----------------------------------------------------------------------------
ALTER TASK BRONZE.TASK_PURGE_STAGE RESUME;
ALTER TASK GOLD.TASK_EXPORT_REPORTS RESUME;
ALTER TASK SILVER.TASK_SILVER_MERGE RESUME;
ALTER TASK SILVER.TASK_SILVER_TRANSIENT RESUME;
ALTER TASK BRONZE.TASK_LOAD_BRONZE RESUME;

   Suspend the whole DAG the same way, with ALTER TASK ... SUSPEND, root-to-leaf.

   Monitor recent runs:
SELECT *
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP())))
ORDER BY SCHEDULED_TIME DESC;
----------------------------------------------------------------------------- */
