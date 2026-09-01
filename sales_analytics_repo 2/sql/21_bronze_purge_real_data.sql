/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data) - Requirements Audit Fixes
   21_bronze_purge_real_data.sql

   Fixes gap #6: Phase 3's stage-purge step (BRONZE.PURGE_LOADED_FILES) has
   no real-data equivalent, so the files manually PUT to @BRONZE.RAW_LANDING
   (leads_raw_part_*, lead_activites_raw_part_*, close_crm_users_raw_part_*,
   custom_activites_raw.csv.gz) just accumulate indefinitely.

   Why this ISN'T added to the scheduled orchestration DAG (unlike Phase 3's
   version, which ran automatically after every export): Phase 3's purge
   used a dt=YYYY-MM-DD pattern match because each day's synthetic file was
   named with that date. Real-data files have no such date component --
   they're arbitrary split part-files (leads_raw_part_aa, _ab, ...) from a
   manual export you run whenever you choose to refresh from Postgres, not
   on a fixed daily cadence. Auto-purging on the same schedule as the Silver
   refresh risks deleting files you just PUT but haven't COPY INTO'd yet, if
   your manual refresh happens to overlap with the scheduled run. Safer to
   keep this a deliberate, manual step you run right after confirming a
   fresh COPY INTO succeeded -- same reasoning already applied to why Bronze
   ingestion itself stays out of the automated DAG.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA BRONZE;

/* -----------------------------------------------------------------------------
   CORRECTION (confirmed 2026-08-26): the stored-procedure wrapper this file
   originally shipped with (BRONZE.PURGE_REAL_DATA_STAGE(), calling REMOVE
   from inside a LANGUAGE SQL procedure body) does not work. Snowflake
   rejects it at CALL time with:

       Uncaught exception of type 'STATEMENT_ERROR' ... Unsupported
       statement type 'REMOVE_FILES'.

   File-management commands (REMOVE, PUT, GET, LIST) can only be run as
   direct SQL statements in a client/worksheet, not from inside a stored
   procedure body. The procedure has been dropped; run the REMOVE
   statements directly instead. This is still a deliberate manual step,
   run yourself right after confirming a fresh COPY INTO succeeded --
   same reasoning as before, just without the (broken) CALL wrapper.
   ----------------------------------------------------------------------------- */

DROP PROCEDURE IF EXISTS BRONZE.PURGE_REAL_DATA_STAGE();

/* -----------------------------------------------------------------------------
   To check what's currently sitting in the stage before purging:
LIST @BRONZE.RAW_LANDING;

   Run these directly, only after confirming a fresh COPY INTO for all 4
   tables succeeded (matching row counts, no errors):
REMOVE @BRONZE.RAW_LANDING/lead_activites_raw/;
REMOVE @BRONZE.RAW_LANDING/leads_raw/;
REMOVE @BRONZE.RAW_LANDING/close_crm_users_raw/;
REMOVE @BRONZE.RAW_LANDING/custom_activites_raw/;
----------------------------------------------------------------------------- */
