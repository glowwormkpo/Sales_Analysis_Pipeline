/* =============================================================================
   Sales Analytics Pipeline - Phase 3
   05_silver_transient_flatten.sql

   Transient staging tables + the DDL for every other Silver table (Phase 2
   entity reference). Transient tables are scratch space for "this run" only:
   LOAD_SILVER_TRANSIENT truncates and repopulates them from that day's Bronze
   row(s) via LATERAL FLATTEN on the "data" array, so 06_silver_merge_dedup.sql
   always MERGEs from a clean, current-batch source.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

-- ---------------------------------------------------------------------------
-- Transient staging tables (exact structure per the provided data model)
-- ---------------------------------------------------------------------------
CREATE TRANSIENT TABLE IF NOT EXISTS SILVER.CUSTOM_ACTIVITIES_TRANSIENT (
    JSON_OBJECT   VARIANT,
    INSERT_DATE   TIMESTAMP_NTZ
);

CREATE TRANSIENT TABLE IF NOT EXISTS SILVER.LEAD_ACTIVITIES_PROCESSED_TRANSIENT (
    JSON_OBJECT   VARIANT,
    INSERT_DATE   TIMESTAMP_NTZ
);

CREATE TRANSIENT TABLE IF NOT EXISTS SILVER.LEADS_ACTIVITIES_SUMMARY_TRANSIENT (
    ACTIVITY_ID                    STRING,
    LEAD_ID                        STRING,
    CONTACT_ID                     STRING,
    USER_ID                        STRING,
    TYPE                           STRING,
    TEXT                           STRING,
    CREATED_BY_NAME                STRING,
    UPDATED_BY_NAME                STRING,
    ATTENDEES                      VARIANT,
    CUSTOM_ACTIVITY_TYPE_ID         STRING,
    MEETING_STARTS_AT              TIMESTAMP_NTZ,
    MEETING_END_AT                 TIMESTAMP_NTZ,
    MEETING_STATUS                 STRING,
    ACTIVITY_AT                    TIMESTAMP_NTZ,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY_USER                STRING,
    UPDATED_BY_USER                STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    WRAPPED_ACTIVITIES             VARIANT,
    CUSTOM_ACTIVITY                STRING,
    CUSTOM_ACTIVITY_OUTCOME_NAME   STRING,
    CUSTOM_ACTIVITY_OUTCOME        STRING,
    DEA_INTERNAL_NAME              STRING,
    DEA_INTERNAL_EMAIL             STRING
);

-- ---------------------------------------------------------------------------
-- Final Silver tables (Phase 2 Sec. 4.1 entity reference)
--
-- REVISION (post explanation-video / transcript review): the original design
-- modeled CUSTOM_ACTIVITIES as one flat dictionary keyed on
-- (CUSTOM_ACTIVITY_ID, CUSTOM_ACTIVITY_OUTCOME_ID). That doesn't match the
-- real source shape. custom_activites_raw actually delivers a two-level
-- dictionary: (1) a CustomActivityType per activity type (Triage Call,
-- Strategy Call, ...), and (2) a nested "fields" array on each type mapping
-- an opaque field ID (custom.cf_<hash>) to a human field name (Setter,
-- Closer, Contract Value, "Triage Call Outcome", ...). Activity records then
-- carry their custom values as top-level custom.cf_<hash> keys that only
-- resolve to a meaning once joined through that type's field list. This
-- split into CUSTOM_ACTIVITY_TYPES + CUSTOM_ACTIVITY_FIELDS replaces the old
-- single CUSTOM_ACTIVITIES table so the model matches that reality.
-- CUSTOM_ACTIVITY_ID is renamed to CUSTOM_ACTIVITY_TYPE_ID everywhere below
-- for clarity, and the old CUSTOM_ACTIVITY_OUTCOME_ID addition is dropped --
-- it's no longer needed now that field resolution is dynamic.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SILVER.CLOSE_CRM_USERS_PROCESSED (
    USER_ID       STRING PRIMARY KEY,
    EMAIL         STRING,
    FIRST_NAME    STRING,
    LAST_NAME     STRING,
    MD5_HASH      STRING,
    DATE_CREATED  TIMESTAMP_NTZ,
    DATE_UPDATED  TIMESTAMP_NTZ,
    INSERT_DATE   TIMESTAMP_NTZ,
    UPDATE_DATE   TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS SILVER.CUSTOM_ACTIVITY_TYPES (
    CUSTOM_ACTIVITY_TYPE_ID    STRING PRIMARY KEY,
    CUSTOM_ACTIVITY_TYPE_NAME  STRING,
    MD5_HASH                   STRING,
    INSERT_DATE                TIMESTAMP_NTZ,
    UPDATE_DATE                TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS SILVER.CUSTOM_ACTIVITY_FIELDS (
    CUSTOM_ACTIVITY_TYPE_ID   STRING,
    FIELD_ID                  STRING,
    FIELD_NAME                STRING,
    FIELD_TYPE                STRING,
    MD5_HASH                  STRING,
    INSERT_DATE                TIMESTAMP_NTZ,
    UPDATE_DATE                TIMESTAMP_NTZ,
    PRIMARY KEY (CUSTOM_ACTIVITY_TYPE_ID, FIELD_ID)
);

CREATE TABLE IF NOT EXISTS SILVER.LEAD_ACTIVITIES_PROCESSED (
    ACTIVITY_ID                 STRING PRIMARY KEY,
    LEAD_ID                     STRING,
    CONTACT_ID                  STRING,
    USER_ID                     STRING,
    TYPE                        STRING,
    TEXT                        STRING,
    CREATED_BY_NAME             STRING,
    UPDATED_BY_NAME             STRING,
    ATTENDEES                   VARIANT,
    CUSTOM_ACTIVITY_TYPE_ID     STRING,
    MEETING_STARTS_AT           TIMESTAMP_NTZ,
    MEETING_END_AT               TIMESTAMP_NTZ,
    MEETING_STATUS               STRING,
    ACTIVITY_AT                  TIMESTAMP_NTZ,
    DATE_CREATED                 TIMESTAMP_NTZ,
    DATE_UPDATED                 TIMESTAMP_NTZ,
    CREATED_BY_USER              STRING,
    UPDATED_BY_USER              STRING,
    INSERT_DATE                  TIMESTAMP_NTZ,
    UPDATE_DATE                  TIMESTAMP_NTZ,
    MD5_HASH                     STRING
);

CREATE TABLE IF NOT EXISTS SILVER.LEAD_ACTIVITIES_EMAIL (
    LEAD_ID            STRING,
    ACTIVITY_AT        TIMESTAMP_NTZ,
    ATTACHMENTS_JSON    VARIANT,
    BODY_TEXT           STRING,
    DATE_CREATED        TIMESTAMP_NTZ,
    DATE_UPDATED        TIMESTAMP_NTZ,
    DIRECTION            STRING,
    ENVELOPE_JSON        VARIANT,
    SENDER_JSON          VARIANT,
    ACTIVITY_ID          STRING PRIMARY KEY,
    OPENS_JSON            VARIANT,
    SENDER                STRING,
    STATUS                STRING,
    SUBJECT               STRING,
    JSON_PAYLOAD           VARIANT,
    USER_ID                STRING,
    USER_NAME              STRING,
    TEMPLATE_ID             STRING,
    TEMPLATE_NAME           STRING,
    DATE_SENT               TIMESTAMP_NTZ,
    HAS_REPLY                BOOLEAN,
    INSERT_DATE              TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS SILVER.CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS (
    LEAD_ID              STRING,
    ACTIVITY_ID          STRING,
    ACTIVITY_AT          TIMESTAMP_NTZ,
    WRAPPED_ACTIVITIES   VARIANT,
    INSERT_DATE          TIMESTAMP_NTZ,
    UPDATE_DATE          TIMESTAMP_NTZ,
    MD5_HASH             STRING,
    PRIMARY KEY (LEAD_ID, ACTIVITY_ID)
);

CREATE TABLE IF NOT EXISTS SILVER.LEADS_ACTIVITIES_SUMMARY (
    ACTIVITY_ID                    STRING PRIMARY KEY,
    LEAD_ID                        STRING,
    CONTACT_ID                     STRING,
    USER_ID                        STRING,
    TYPE                           STRING,
    TEXT                           STRING,
    CREATED_BY_NAME                STRING,
    UPDATED_BY_NAME                STRING,
    ATTENDEES                      VARIANT,
    CUSTOM_ACTIVITY_TYPE_ID         STRING,
    MEETING_STARTS_AT              TIMESTAMP_NTZ,
    MEETING_END_AT                 TIMESTAMP_NTZ,
    MEETING_STATUS                 STRING,
    ACTIVITY_AT                    TIMESTAMP_NTZ,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY_USER                STRING,
    UPDATED_BY_USER                STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    WRAPPED_ACTIVITIES             VARIANT,
    CUSTOM_ACTIVITY                STRING,
    CUSTOM_ACTIVITY_OUTCOME_NAME   STRING,
    CUSTOM_ACTIVITY_OUTCOME        STRING,
    DEA_INTERNAL_NAME              STRING,
    DEA_INTERNAL_EMAIL             STRING
);

-- ---------------------------------------------------------------------------
-- Daily transient load: flattens that day's Bronze row(s) into one row per
-- activity / custom-activity-definition. Truncate first -- transient tables
-- hold only the current run's working set.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SILVER.LOAD_SILVER_TRANSIENT(LOAD_DATE DATE)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    TRUNCATE TABLE SILVER.LEAD_ACTIVITIES_PROCESSED_TRANSIENT;
    TRUNCATE TABLE SILVER.CUSTOM_ACTIVITIES_TRANSIENT;

    INSERT INTO SILVER.LEAD_ACTIVITIES_PROCESSED_TRANSIENT (JSON_OBJECT, INSERT_DATE)
    SELECT f.value, CURRENT_TIMESTAMP()
    FROM BRONZE.LEAD_ACTIVITIES_RAW b,
         LATERAL FLATTEN(input => b.JSON_OBJECT:data) f
    WHERE TO_DATE(b.INSERT_DATE) = :LOAD_DATE;

    INSERT INTO SILVER.CUSTOM_ACTIVITIES_TRANSIENT (JSON_OBJECT, INSERT_DATE)
    SELECT f.value, CURRENT_TIMESTAMP()
    FROM BRONZE.CUSTOM_ACTIVITIES_RAW b,
         LATERAL FLATTEN(input => b.JSON_OBJECT:data) f
    WHERE TO_DATE(b.INSERT_DATE) = :LOAD_DATE;

    RETURN 'Silver transient load complete for ' || TO_VARCHAR(:LOAD_DATE, 'YYYY-MM-DD');
END;
$$;

-- CALL SILVER.LOAD_SILVER_TRANSIENT('2026-08-03');
-- SELECT COUNT(*) FROM SILVER.LEAD_ACTIVITIES_PROCESSED_TRANSIENT;
