/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data)
   12_silver_dictionary_and_users_load.sql

   Rebuilds CUSTOM_ACTIVITY_TYPES / CUSTOM_ACTIVITY_FIELDS and
   CLOSE_CRM_USERS_PROCESSED from the real Bronze tables.

   Both BRONZE.CUSTOM_ACTIVITIES_RAW and BRONZE.CLOSE_CRM_USERS_RAW use the
   same wrapped shape: JSON_OBJECT = {"INSERT_DATE": ..., "JSON_OBJECT":
   "<single-quoted pseudo-JSON string>"}. That's one extra unwrap step versus
   the Phase 3 design, which assumed JSON_OBJECT itself was directly the
   single-quoted "{'data': [...]}" text. Fix: pull out the nested JSON_OBJECT
   string first, then run it through the existing REPAIR_AND_PARSE_JSON UDF
   exactly as before.

   Each table holds one full snapshot per real calendar day (28 rows each,
   or 28 for custom_activites_raw / matching for close_crm_users_raw) --
   type definitions and the user roster barely change day to day, so this
   takes only the most recent snapshot of each rather than trying to merge
   28 near-duplicate dumps.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

-- ---------------------------------------------------------------------------
-- Helper UDF: neutralize "description" field values before JSON repair.
--
-- Real "description" values in this table contain unescaped, ambiguous
-- single quotes (literal content quotes mixed with the pseudo-JSON's own
-- string delimiters -- e.g. "...any of 'Reschedule,' or 'No Show'or '
-- Cancellation'..."), which breaks REPAIR_SINGLE_QUOTED_JSON's quote
-- disambiguation. "description" isn't consumed anywhere downstream (only
-- id/name for types and id/name/type for fields are used).
--
-- First attempt used REGEXP_REPLACE assuming every "description" is
-- immediately followed by the literal key "editable_with_roles". That's
-- true at the type level but NOT at the field level (254 "description"
-- occurrences total vs. ~27 types -- most of them live inside each type's
-- fields[] array, followed by other keys like "field_type" or "required").
-- Snowflake's native REGEXP_REPLACE has no lookahead, so the non-greedy
-- match kept skipping forward past unmatched field-level descriptions all
-- the way to the first real "editable_with_roles" anywhere in the whole
-- document, swallowing dozens of type/field objects into one replacement
-- and collapsing the array down to 1 element.
--
-- Fix: a JS UDF (V8 supports lookahead) that ends each match at the next
-- *real* key boundary, whatever that key's name is, instead of assuming a
-- fixed key always follows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION SILVER.STRIP_DESCRIPTION_VALUES(RAW_STRING STRING)
RETURNS STRING
LANGUAGE JAVASCRIPT
STRICT
COMMENT = 'Neutralizes description field values to null before JSON repair, since their free text contains ambiguous unescaped single quotes. Ends each match at the next real key boundary (whatever key it is), not a fixed key name.'
AS
$$
    var s = String(RAW_STRING);
    return s.replace(/'description':\s*'.*?'(?=,\s*'[A-Za-z_][A-Za-z0-9_]*':)/gs, "'description': null");
$$;

-- ---------------------------------------------------------------------------
-- CUSTOM_ACTIVITY_TYPES + CUSTOM_ACTIVITY_FIELDS (most recent snapshot only)
-- ---------------------------------------------------------------------------
TRUNCATE TABLE SILVER.CUSTOM_ACTIVITY_TYPES;
TRUNCATE TABLE SILVER.CUSTOM_ACTIVITY_FIELDS;

CREATE OR REPLACE TRANSIENT TABLE SILVER.CUSTOM_ACTIVITY_TYPES_TRANSIENT AS
SELECT
    t.value AS TYPE_JSON
FROM (
    SELECT REPAIR_AND_PARSE_JSON(
        SILVER.STRIP_DESCRIPTION_VALUES(JSON_OBJECT:"JSON_OBJECT"::STRING)
    ) AS PARSED
    FROM BRONZE.CUSTOM_ACTIVITIES_RAW
    QUALIFY ROW_NUMBER() OVER (ORDER BY INSERT_DATE DESC) = 1
) latest,
LATERAL FLATTEN(input => latest.PARSED:data) t;

INSERT INTO SILVER.CUSTOM_ACTIVITY_TYPES (
    CUSTOM_ACTIVITY_TYPE_ID, CUSTOM_ACTIVITY_TYPE_NAME, MD5_HASH, INSERT_DATE, UPDATE_DATE
)
SELECT
    TYPE_JSON:id::STRING, TYPE_JSON:name::STRING, MD5(TYPE_JSON::STRING),
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
FROM SILVER.CUSTOM_ACTIVITY_TYPES_TRANSIENT;

INSERT INTO SILVER.CUSTOM_ACTIVITY_FIELDS (
    CUSTOM_ACTIVITY_TYPE_ID, FIELD_ID, FIELD_NAME, FIELD_TYPE, MD5_HASH, INSERT_DATE, UPDATE_DATE
)
SELECT
    t.TYPE_JSON:id::STRING,
    f.value:id::STRING,
    f.value:name::STRING,
    f.value:type::STRING,
    MD5(f.value::STRING),
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
FROM SILVER.CUSTOM_ACTIVITY_TYPES_TRANSIENT t,
     LATERAL FLATTEN(input => t.TYPE_JSON:fields) f;

-- ---------------------------------------------------------------------------
-- CLOSE_CRM_USERS_PROCESSED (most recent snapshot only)
-- ---------------------------------------------------------------------------
TRUNCATE TABLE SILVER.CLOSE_CRM_USERS_PROCESSED;

INSERT INTO SILVER.CLOSE_CRM_USERS_PROCESSED (
    USER_ID, EMAIL, FIRST_NAME, LAST_NAME, MD5_HASH, DATE_CREATED, DATE_UPDATED, INSERT_DATE, UPDATE_DATE
)
SELECT
    u.value:id::STRING, u.value:email::STRING, u.value:first_name::STRING, u.value:last_name::STRING,
    MD5(u.value::STRING), u.value:date_created::TIMESTAMP_NTZ, u.value:date_updated::TIMESTAMP_NTZ,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
FROM (
    SELECT REPAIR_AND_PARSE_JSON(JSON_OBJECT:"JSON_OBJECT"::STRING) AS PARSED
    FROM BRONZE.CLOSE_CRM_USERS_RAW
    QUALIFY ROW_NUMBER() OVER (ORDER BY INSERT_DATE DESC) = 1
) latest,
LATERAL FLATTEN(input => latest.PARSED:data) u;

-- ---------------------------------------------------------------------------
-- Sanity checks
-- ---------------------------------------------------------------------------
SELECT 'CUSTOM_ACTIVITY_TYPES' AS t, COUNT(*) FROM SILVER.CUSTOM_ACTIVITY_TYPES
UNION ALL SELECT 'CUSTOM_ACTIVITY_FIELDS', COUNT(*) FROM SILVER.CUSTOM_ACTIVITY_FIELDS
UNION ALL SELECT 'CLOSE_CRM_USERS_PROCESSED', COUNT(*) FROM SILVER.CLOSE_CRM_USERS_PROCESSED;
