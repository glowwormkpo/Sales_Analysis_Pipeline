/* =============================================================================
   Sales Analytics Pipeline - Phase 3
   03_bronze_copy_into.sql

   Loads one day's worth of source files into Bronze. Each source file is a
   single JSON document ({"data": [...]}), so each COPY INTO produces exactly
   one Bronze row per table per day -- the whole payload lands as one VARIANT.
   Deep unwrapping of the "data" array into one row per activity happens in
   Silver (05_silver_transient_flatten.sql), not here. Bronze stays a literal,
   replayable copy of what was delivered.

   NOTE vs. Phase 2 ERD: the Phase 2 doc described Bronze grain as "1 row per
   activity record per daily load." Implementing the actual COPY INTO here
   showed that's only true if the source delivers one JSON object per
   activity; since the source instead delivers one {"data": [...]} document
   per table per day, Bronze grain is corrected to "1 row per file load."
   This is flagged in the Phase 3 runbook as a documented refinement.

   Wrapped in a stored procedure so the daily load is a single CALL --
   this is also what 09_orchestration_tasks_streams.sql schedules.

   NOTE on stage layout: this matches files by DATE + FILENAME anywhere under
   the stage (PATTERN = '.*dt=<date>.*<filename>'), rather than requiring a
   strict <table_name>/dt=<date>/<file> subfolder structure. This is
   deliberately more lenient than 01b_put_sample_data.sql's PUT layout,
   because Snowsight's manual "+ Files" upload dialog only lets you type one
   path prefix, and it's easy to end up with everything landing at
   dt=<date>/<file> without the table-name folder in front of it. Since each
   table's source file has a unique name, matching on filename is just as
   safe and works with either upload method.

   NOTE on INSERT_DATE: explicitly stamped with LOAD_DATE (the simulated day
   being loaded) rather than left to default to CURRENT_TIMESTAMP(). In real
   production, running once per actual calendar day, those would coincide
   anyway -- but the 7-day simulation in this runbook is typically run
   back-to-back in one sitting, so relying on the default would stamp every
   "day" with today's real timestamp and break 05_silver_transient_flatten.sql's
   WHERE TO_DATE(INSERT_DATE) = LOAD_DATE filter (0 rows matched, silently).
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA BRONZE;

CREATE OR REPLACE PROCEDURE BRONZE.LOAD_BRONZE_DAY(LOAD_DATE DATE)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    -- COPY INTO's PATTERN option only accepts a literal or a single bind
    -- variable, not an inline expression -- so each full pattern string is
    -- built with a plain assignment below, then referenced by variable name.
    dt_str STRING;
    pattern_lead STRING;
    pattern_custom STRING;
    pattern_users STRING;
    pattern_leads STRING;
    load_ts TIMESTAMP_NTZ;
BEGIN
    dt_str := TO_VARCHAR(:LOAD_DATE, 'YYYY-MM-DD');
    load_ts := :LOAD_DATE::TIMESTAMP_NTZ;
    pattern_lead := '.*dt=' || dt_str || '.*lead_activites_raw.json';
    pattern_custom := '.*dt=' || dt_str || '.*custom_activites_raw.json';
    pattern_users := '.*dt=' || dt_str || '.*close_crm_users_raw.json';
    pattern_leads := '.*dt=' || dt_str || '.*leads_raw.json';

    COPY INTO BRONZE.LEAD_ACTIVITIES_RAW (JSON_OBJECT, INSERT_DATE)
        FROM (SELECT $1, :load_ts FROM @BRONZE.RAW_LANDING)
        PATTERN = :pattern_lead
        FILE_FORMAT = (FORMAT_NAME = 'BRONZE.JSON_SOURCE_FORMAT')
        ON_ERROR = ABORT_STATEMENT;

    COPY INTO BRONZE.CUSTOM_ACTIVITIES_RAW (JSON_OBJECT, INSERT_DATE)
        FROM (SELECT $1, :load_ts FROM @BRONZE.RAW_LANDING)
        PATTERN = :pattern_custom
        FILE_FORMAT = (FORMAT_NAME = 'BRONZE.JSON_SOURCE_FORMAT')
        ON_ERROR = ABORT_STATEMENT;

    COPY INTO BRONZE.CLOSE_CRM_USERS_RAW (JSON_OBJECT, INSERT_DATE)
        FROM (SELECT $1, :load_ts FROM @BRONZE.RAW_LANDING)
        PATTERN = :pattern_users
        FILE_FORMAT = (FORMAT_NAME = 'BRONZE.JSON_SOURCE_FORMAT')
        ON_ERROR = ABORT_STATEMENT;

    COPY INTO BRONZE.LEADS_RAW (JSON_OBJECT, INSERT_DATE)
        FROM (SELECT $1, :load_ts FROM @BRONZE.RAW_LANDING)
        PATTERN = :pattern_leads
        FILE_FORMAT = (FORMAT_NAME = 'BRONZE.JSON_SOURCE_FORMAT')
        ON_ERROR = ABORT_STATEMENT;

    RETURN 'Bronze load complete for ' || dt_str;
END;
$$;

/* -----------------------------------------------------------------------------
   Manual 7-day simulation: run once per "day" to mimic the daily 07:30 AM EST
   source refresh. Each call is idempotent per date (re-running a date is safe
   because Silver's MERGE in 06_silver_merge_dedup.sql dedupes on
   LEAD_ID + ACTIVITY_ID, not on how many times Bronze saw the row).
   ----------------------------------------------------------------------------- */
-- CALL BRONZE.LOAD_BRONZE_DAY('2026-08-03');
-- CALL BRONZE.LOAD_BRONZE_DAY('2026-08-04');
-- CALL BRONZE.LOAD_BRONZE_DAY('2026-08-05');
-- CALL BRONZE.LOAD_BRONZE_DAY('2026-08-06');
-- CALL BRONZE.LOAD_BRONZE_DAY('2026-08-07');
-- CALL BRONZE.LOAD_BRONZE_DAY('2026-08-08');
-- CALL BRONZE.LOAD_BRONZE_DAY('2026-08-09');

-- Quick sanity check after each load:
-- SELECT COUNT(*) AS files_loaded, MAX(INSERT_DATE) AS last_load
-- FROM BRONZE.LEAD_ACTIVITIES_RAW;
