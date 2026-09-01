/* =============================================================================
   Sales Analytics Pipeline - Phase 3
   01_stages_and_formats.sql

   Creates the database/schema structure, warehouse, file format, and stage(s)
   used to land daily JSON drops into Bronze.

   Trial-account note:
   Setting up a STORAGE INTEGRATION against a real S3 bucket requires an AWS
   account and IAM trust relationship, which most trial accounts don't have
   configured out of the box. This script creates an INTERNAL named stage so
   you can PUT the sample_data/ files straight from your laptop with SnowSQL
   or the Snowsight "Upload files to stage" UI and run the whole pipeline
   end-to-end today. The commented-out block at the bottom shows the exact
   swap to a real external S3 stage once a storage integration exists -- no
   other script changes are required, since everything downstream reads from
   the stage by name, not by URL.
   ============================================================================= */

CREATE DATABASE IF NOT EXISTS SALES_ANALYTICS;
USE DATABASE SALES_ANALYTICS;

CREATE SCHEMA IF NOT EXISTS BRONZE;
CREATE SCHEMA IF NOT EXISTS SILVER;
CREATE SCHEMA IF NOT EXISTS GOLD;
CREATE SCHEMA IF NOT EXISTS EXPORT_STAGE_OBJECTS;  -- holds export file formats/stages only

CREATE WAREHOUSE IF NOT EXISTS SALES_ANALYTICS_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Warehouse for the Sales Analytics Pipeline (Bronze -> Silver -> Gold -> Export)';

USE WAREHOUSE SALES_ANALYTICS_WH;

-- ---------------------------------------------------------------------------
-- File format: source files are one JSON document per day, {"data": [ ... ]}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT BRONZE.JSON_SOURCE_FORMAT
    TYPE = JSON
    STRIP_OUTER_ARRAY = FALSE
    COMMENT = 'Raw daily source JSON: outer document is {"data": [...]}, loaded whole into a VARIANT column.';

-- ---------------------------------------------------------------------------
-- Internal stage for trial-account / local testing (PUT sample_data/*.json here)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE STAGE BRONZE.RAW_LANDING
    FILE_FORMAT = BRONZE.JSON_SOURCE_FORMAT
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Internal landing stage for daily JSON drops. One subfolder per table, per day: /lead_activites_raw/dt=YYYY-MM-DD/, etc.';

-- ---------------------------------------------------------------------------
-- Export stage: where the four KPI report unloads land (Section 7 / 08_export_unload.sql)
-- Note: HEADER is a COPY INTO copy option (used on unload), not a valid
-- CREATE FILE FORMAT parameter -- it belongs on the COPY INTO statements in
-- 08_export_unload.sql (where it already is), not here.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT
    TYPE = CSV
    FIELD_DELIMITER = ','
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('')
    EMPTY_FIELD_AS_NULL = TRUE;

CREATE OR REPLACE STAGE EXPORT_STAGE_OBJECTS.REPORT_EXPORTS
    FILE_FORMAT = EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Export landing zone. Report subfolders mirror the real target paths: dea_setter_report/inbound/, dea_setter_report/outbound/, dea_closer_report/closer_report/, dea_closer_report/objections_faced/.';

/* -----------------------------------------------------------------------------
   PRODUCTION SWAP: real S3 source (uncomment once a storage integration exists)
   -----------------------------------------------------------------------------

CREATE STORAGE INTEGRATION S3_SALES_ANALYTICS_INT
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = '<arn:aws:iam::...:role/...>'
    STORAGE_ALLOWED_LOCATIONS = ('s3://<bucket>/raw/');

-- DESC INTEGRATION S3_SALES_ANALYTICS_INT;  -- grab STORAGE_AWS_IAM_USER_ARN / EXTERNAL_ID and
--                                               add them to the AWS IAM role's trust policy first.

CREATE OR REPLACE STAGE BRONZE.RAW_LANDING
    URL = 's3://<bucket>/raw/'
    STORAGE_INTEGRATION = S3_SALES_ANALYTICS_INT
    FILE_FORMAT = BRONZE.JSON_SOURCE_FORMAT
    DIRECTORY = (ENABLE = TRUE);

----------------------------------------------------------------------------- */
