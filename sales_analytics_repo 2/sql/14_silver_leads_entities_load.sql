/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data)
   14_silver_leads_entities_load.sql

   Loads LEADS_PROCESSED, CONTACTS, OPPORTUNITIES, TASKS from BRONZE.LEADS_RAW.

   Unlike custom_activites_raw / close_crm_users_raw, leads_raw's raw_data
   was stored as clean valid JSON in Postgres (same as lead_activites_raw) --
   no REPAIR_AND_PARSE_JSON unwrap needed, plain VARIANT access works
   directly. Confirmed by 11_silver_new_activities_load.sql already doing
   the same thing successfully against lead_activites_raw.

   leads_raw carries one full snapshot of every lead per day (28 days of
   history), and each row IS the lead record directly (no "data" array
   wrapper, unlike the activity tables) -- contacts/opportunities/tasks are
   embedded arrays on that record. First dedupe to one row per lead (latest
   date_updated wins, same pattern as SILVER.ALL_ACTIVITIES_TRANSIENT), then
   flatten the three embedded arrays out to their own tables.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

-- ---------------------------------------------------------------------------
-- 0. Dedup transient: one row per lead, latest snapshot across all 28 days
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRANSIENT TABLE SILVER.LEADS_TRANSIENT AS
SELECT
    b.JSON_OBJECT   AS LEAD_JSON,
    b.INSERT_DATE   AS SOURCE_INSERT_DATE
FROM BRONZE.LEADS_RAW b
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY b.JSON_OBJECT:id::STRING
    ORDER BY b.JSON_OBJECT:date_updated::TIMESTAMP_NTZ DESC NULLS LAST, b.INSERT_DATE DESC
) = 1;

-- ---------------------------------------------------------------------------
-- 1. LEADS_PROCESSED
-- ---------------------------------------------------------------------------
TRUNCATE TABLE SILVER.LEADS_PROCESSED;

INSERT INTO SILVER.LEADS_PROCESSED (
    LEAD_ID, NAME, DISPLAY_NAME, STATUS_ID, STATUS_LABEL, DESCRIPTION, URL, HTML_URL, CUSTOM,
    ORGANIZATION_ID, DATE_CREATED, DATE_UPDATED, CREATED_BY, CREATED_BY_NAME, UPDATED_BY, UPDATED_BY_NAME,
    INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    t.LEAD_JSON:id::STRING                    AS LEAD_ID,
    t.LEAD_JSON:name::STRING                  AS NAME,
    t.LEAD_JSON:display_name::STRING          AS DISPLAY_NAME,
    t.LEAD_JSON:status_id::STRING             AS STATUS_ID,
    t.LEAD_JSON:status_label::STRING          AS STATUS_LABEL,
    t.LEAD_JSON:description::STRING           AS DESCRIPTION,
    t.LEAD_JSON:url::STRING                   AS URL,
    t.LEAD_JSON:html_url::STRING              AS HTML_URL,
    t.LEAD_JSON:custom                        AS CUSTOM,
    t.LEAD_JSON:organization_id::STRING       AS ORGANIZATION_ID,
    t.LEAD_JSON:date_created::TIMESTAMP_NTZ   AS DATE_CREATED,
    t.LEAD_JSON:date_updated::TIMESTAMP_NTZ   AS DATE_UPDATED,
    t.LEAD_JSON:created_by::STRING            AS CREATED_BY,
    t.LEAD_JSON:created_by_name::STRING       AS CREATED_BY_NAME,
    t.LEAD_JSON:updated_by::STRING            AS UPDATED_BY,
    t.LEAD_JSON:updated_by_name::STRING       AS UPDATED_BY_NAME,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(),
    MD5(t.LEAD_JSON::STRING)                  AS MD5_HASH
FROM SILVER.LEADS_TRANSIENT t;

-- ---------------------------------------------------------------------------
-- 2. CONTACTS
-- ---------------------------------------------------------------------------
TRUNCATE TABLE SILVER.CONTACTS;

INSERT INTO SILVER.CONTACTS (
    CONTACT_ID, LEAD_ID, NAME, DISPLAY_NAME, TITLE, EMAILS, PHONES, TIMEZONE, ORGANIZATION_ID,
    DATE_CREATED, DATE_UPDATED, CREATED_BY, UPDATED_BY, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    c.value:id::STRING                    AS CONTACT_ID,
    t.LEAD_JSON:id::STRING                 AS LEAD_ID,
    c.value:name::STRING                    AS NAME,
    c.value:display_name::STRING            AS DISPLAY_NAME,
    c.value:title::STRING                    AS TITLE,
    c.value:emails                            AS EMAILS,
    c.value:phones                            AS PHONES,
    c.value:timezone::STRING                  AS TIMEZONE,
    c.value:organization_id::STRING           AS ORGANIZATION_ID,
    c.value:date_created::TIMESTAMP_NTZ        AS DATE_CREATED,
    c.value:date_updated::TIMESTAMP_NTZ        AS DATE_UPDATED,
    c.value:created_by::STRING                 AS CREATED_BY,
    c.value:updated_by::STRING                 AS UPDATED_BY,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(),
    MD5(c.value::STRING)                        AS MD5_HASH
FROM SILVER.LEADS_TRANSIENT t,
     LATERAL FLATTEN(input => t.LEAD_JSON:contacts) c
QUALIFY ROW_NUMBER() OVER (PARTITION BY c.value:id::STRING ORDER BY t.LEAD_JSON:date_updated::TIMESTAMP_NTZ DESC) = 1;

-- ---------------------------------------------------------------------------
-- 3. OPPORTUNITIES
-- ---------------------------------------------------------------------------
TRUNCATE TABLE SILVER.OPPORTUNITIES;

INSERT INTO SILVER.OPPORTUNITIES (
    OPPORTUNITY_ID, LEAD_ID, CONTACT_ID, CONTACT_NAME, PIPELINE_ID, PIPELINE_NAME, STATUS_ID, STATUS_LABEL,
    STATUS_DISPLAY_NAME, STATUS_TYPE, VALUE, VALUE_CURRENCY, VALUE_PERIOD, VALUE_FORMATTED, EXPECTED_VALUE,
    CONFIDENCE, DATE_WON, DATE_LOST, USER_ID, USER_NAME, NOTE, ORGANIZATION_ID, DATE_CREATED, DATE_UPDATED,
    CREATED_BY, UPDATED_BY, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    o.value:id::STRING                       AS OPPORTUNITY_ID,
    t.LEAD_JSON:id::STRING                    AS LEAD_ID,
    o.value:contact_id::STRING                 AS CONTACT_ID,
    o.value:contact_name::STRING               AS CONTACT_NAME,
    o.value:pipeline_id::STRING                 AS PIPELINE_ID,
    o.value:pipeline_name::STRING               AS PIPELINE_NAME,
    o.value:status_id::STRING                   AS STATUS_ID,
    o.value:status_label::STRING                AS STATUS_LABEL,
    o.value:status_display_name::STRING          AS STATUS_DISPLAY_NAME,
    o.value:status_type::STRING                  AS STATUS_TYPE,
    o.value:value::NUMBER                         AS VALUE,
    o.value:value_currency::STRING                AS VALUE_CURRENCY,
    o.value:value_period::STRING                  AS VALUE_PERIOD,
    o.value:value_formatted::STRING                AS VALUE_FORMATTED,
    o.value:expected_value::NUMBER                 AS EXPECTED_VALUE,
    o.value:confidence::NUMBER                      AS CONFIDENCE,
    o.value:date_won::DATE                           AS DATE_WON,
    o.value:date_lost::DATE                           AS DATE_LOST,
    o.value:user_id::STRING                            AS USER_ID,
    o.value:user_name::STRING                           AS USER_NAME,
    o.value:note::STRING                                 AS NOTE,
    o.value:organization_id::STRING                       AS ORGANIZATION_ID,
    o.value:date_created::TIMESTAMP_NTZ                    AS DATE_CREATED,
    o.value:date_updated::TIMESTAMP_NTZ                     AS DATE_UPDATED,
    o.value:created_by::STRING                               AS CREATED_BY,
    o.value:updated_by::STRING                                AS UPDATED_BY,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(),
    MD5(o.value::STRING)                                        AS MD5_HASH
FROM SILVER.LEADS_TRANSIENT t,
     LATERAL FLATTEN(input => t.LEAD_JSON:opportunities) o
QUALIFY ROW_NUMBER() OVER (PARTITION BY o.value:id::STRING ORDER BY t.LEAD_JSON:date_updated::TIMESTAMP_NTZ DESC) = 1;

-- ---------------------------------------------------------------------------
-- 4. TASKS
-- ---------------------------------------------------------------------------
TRUNCATE TABLE SILVER.TASKS;

INSERT INTO SILVER.TASKS (
    TASK_ID, LEAD_ID, LEAD_NAME, CONTACT_ID, CONTACT_NAME, TEXT, TASK_DATE, DUE_DATE, PRIORITY,
    IS_COMPLETE, IS_DATELESS, ASSIGNED_TO, ASSIGNED_TO_NAME, SEQUENCE_ID, SEQUENCE_SUBSCRIPTION_ID, VIEW,
    ORGANIZATION_ID, DATE_CREATED, DATE_UPDATED, CREATED_BY, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    k.value:id::STRING                       AS TASK_ID,
    t.LEAD_JSON:id::STRING                    AS LEAD_ID,
    k.value:lead_name::STRING                   AS LEAD_NAME,
    k.value:contact_id::STRING                    AS CONTACT_ID,
    k.value:contact_name::STRING                    AS CONTACT_NAME,
    k.value:text::STRING                              AS TEXT,
    k.value:date::DATE                                  AS TASK_DATE,
    k.value:due_date::DATE                                AS DUE_DATE,
    k.value:priority::STRING                                AS PRIORITY,
    k.value:is_complete::BOOLEAN                              AS IS_COMPLETE,
    k.value:is_dateless::BOOLEAN                                AS IS_DATELESS,
    k.value:assigned_to::STRING                                  AS ASSIGNED_TO,
    k.value:assigned_to_name::STRING                                AS ASSIGNED_TO_NAME,
    k.value:sequence_id::STRING                                       AS SEQUENCE_ID,
    k.value:sequence_subscription_id::STRING                            AS SEQUENCE_SUBSCRIPTION_ID,
    k.value:view::STRING                                                  AS VIEW,
    k.value:organization_id::STRING                                        AS ORGANIZATION_ID,
    k.value:date_created::TIMESTAMP_NTZ                                     AS DATE_CREATED,
    k.value:date_updated::TIMESTAMP_NTZ                                      AS DATE_UPDATED,
    k.value:created_by::STRING                                                AS CREATED_BY,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(),
    MD5(k.value::STRING)                                                        AS MD5_HASH
FROM SILVER.LEADS_TRANSIENT t,
     LATERAL FLATTEN(input => t.LEAD_JSON:tasks) k
QUALIFY ROW_NUMBER() OVER (PARTITION BY k.value:id::STRING ORDER BY t.LEAD_JSON:date_updated::TIMESTAMP_NTZ DESC) = 1;

-- ---------------------------------------------------------------------------
-- Sanity checks
-- ---------------------------------------------------------------------------
SELECT 'LEADS_TRANSIENT (distinct leads)' AS t, COUNT(*) AS n FROM SILVER.LEADS_TRANSIENT
UNION ALL SELECT 'LEADS_PROCESSED', COUNT(*) FROM SILVER.LEADS_PROCESSED
UNION ALL SELECT 'CONTACTS', COUNT(*) FROM SILVER.CONTACTS
UNION ALL SELECT 'OPPORTUNITIES', COUNT(*) FROM SILVER.OPPORTUNITIES
UNION ALL SELECT 'TASKS', COUNT(*) FROM SILVER.TASKS;
