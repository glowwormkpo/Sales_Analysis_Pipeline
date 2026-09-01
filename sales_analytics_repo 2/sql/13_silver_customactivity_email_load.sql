/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data)
   13_silver_customactivity_email_load.sql

   Loads the two remaining activity types (CustomActivity, Email) out of
   SILVER.ALL_ACTIVITIES_TRANSIENT (built by 11_silver_new_activities_load.sql
   -- one row per unique activity, already deduped to its latest snapshot
   across all 28 days of Bronze history) into the pre-existing Phase 3 Silver
   tables: LEAD_ACTIVITIES_PROCESSED, LEAD_ACTIVITIES_EMAIL,
   CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS, LEADS_ACTIVITIES_SUMMARY.

   This replaces 06_silver_merge_dedup.sql's MERGE_SILVER_DAY logic for these
   four tables (that procedure assumed a day-by-day incremental simulation
   against synthetic data; the real-data backfill is a one-time full load
   instead, same pattern as 11_silver_new_activities_load.sql). The procedure
   itself is left in place -- it can still be pointed at future daily Bronze
   loads once this pipeline moves from backfill to steady-state ingestion.

   Two real-shape differences from the original design, confirmed against
   actual Bronze rows before writing this:
     1. Real CustomActivity records carry NO "text" field (the old MERGE
        logic assumed one) -- left NULL here.
     2. Real Email records are far richer than the Phase 3 placeholder
        columns assumed (nested envelope/opens/attachments objects,
        template_id/name, etc.) -- LEAD_ACTIVITIES_EMAIL already has columns
        for all of it, they just weren't being populated before.

   Outcome resolution (CUSTOM_ACTIVITY_OUTCOME_NAME / CUSTOM_ACTIVITY_OUTCOME
   on LEADS_ACTIVITIES_SUMMARY) is also rebuilt: the old logic branched on
   4 hardcoded synthetic type IDs ('100'/'200'/'300'/'400'). Real Close CRM
   type IDs are opaque per-org strings (28 real types here, not 4), so
   outcome resolution is now dynamic -- for each CustomActivity's
   CUSTOM_ACTIVITY_TYPE_ID, find that type's field whose name matches
   '%outcome%' in CUSTOM_ACTIVITY_FIELDS (confirmed 1:1, no type has more
   than one), then pull that field by name out of WRAPPED_ACTIVITIES via
   GET(). No hardcoding required, and it covers all 28 types automatically
   (types with no outcome-ish field, e.g. "0) Pipeline Update" or "Backend
   Sale Pitch", simply get NULL, which is correct -- they're one-shot deal
   events, not funnel-stage calls).
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

-- ---------------------------------------------------------------------------
-- 1. LEAD_ACTIVITIES_PROCESSED (CustomActivity records only)
-- ---------------------------------------------------------------------------
TRUNCATE TABLE SILVER.LEAD_ACTIVITIES_PROCESSED;

INSERT INTO SILVER.LEAD_ACTIVITIES_PROCESSED (
    ACTIVITY_ID, LEAD_ID, CONTACT_ID, USER_ID, TYPE, TEXT, CREATED_BY_NAME, UPDATED_BY_NAME, ATTENDEES,
    CUSTOM_ACTIVITY_TYPE_ID, MEETING_STARTS_AT, MEETING_END_AT, MEETING_STATUS, ACTIVITY_AT, DATE_CREATED, DATE_UPDATED,
    CREATED_BY_USER, UPDATED_BY_USER, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    t.ACTIVITY_ID,
    t.LEAD_ID,
    t.ACTIVITY_JSON:contact_id::STRING                 AS CONTACT_ID,
    t.ACTIVITY_JSON:user_id::STRING                     AS USER_ID,
    t.ACTIVITY_TYPE                                     AS TYPE,
    NULL                                                  AS TEXT,
    t.ACTIVITY_JSON:created_by_name::STRING             AS CREATED_BY_NAME,
    t.ACTIVITY_JSON:updated_by_name::STRING             AS UPDATED_BY_NAME,
    NULL                                                  AS ATTENDEES,
    t.ACTIVITY_JSON:custom_activity_type_id::STRING     AS CUSTOM_ACTIVITY_TYPE_ID,
    NULL::TIMESTAMP_NTZ                                   AS MEETING_STARTS_AT,
    NULL::TIMESTAMP_NTZ                                   AS MEETING_END_AT,
    NULL::STRING                                           AS MEETING_STATUS,
    t.ACTIVITY_JSON:activity_at::TIMESTAMP_NTZ            AS ACTIVITY_AT,
    t.ACTIVITY_JSON:date_created::TIMESTAMP_NTZ           AS DATE_CREATED,
    t.ACTIVITY_JSON:date_updated::TIMESTAMP_NTZ           AS DATE_UPDATED,
    t.ACTIVITY_JSON:created_by::STRING                    AS CREATED_BY_USER,
    t.ACTIVITY_JSON:updated_by::STRING                    AS UPDATED_BY_USER,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(),
    MD5(t.ACTIVITY_JSON::STRING)                          AS MD5_HASH
FROM SILVER.ALL_ACTIVITIES_TRANSIENT t
WHERE t.ACTIVITY_TYPE = 'CustomActivity';

-- ---------------------------------------------------------------------------
-- 2. LEAD_ACTIVITIES_EMAIL
-- ---------------------------------------------------------------------------
TRUNCATE TABLE SILVER.LEAD_ACTIVITIES_EMAIL;

INSERT INTO SILVER.LEAD_ACTIVITIES_EMAIL (
    LEAD_ID, ACTIVITY_AT, ATTACHMENTS_JSON, BODY_TEXT, DATE_CREATED, DATE_UPDATED, DIRECTION, ENVELOPE_JSON,
    SENDER_JSON, ACTIVITY_ID, OPENS_JSON, SENDER, STATUS, SUBJECT, JSON_PAYLOAD, USER_ID, USER_NAME,
    TEMPLATE_ID, TEMPLATE_NAME, DATE_SENT, HAS_REPLY, INSERT_DATE
)
SELECT
    t.LEAD_ID,
    t.ACTIVITY_JSON:activity_at::TIMESTAMP_NTZ    AS ACTIVITY_AT,
    t.ACTIVITY_JSON:attachments                     AS ATTACHMENTS_JSON,
    t.ACTIVITY_JSON:body_text::STRING                AS BODY_TEXT,
    t.ACTIVITY_JSON:date_created::TIMESTAMP_NTZ      AS DATE_CREATED,
    t.ACTIVITY_JSON:date_updated::TIMESTAMP_NTZ      AS DATE_UPDATED,
    t.ACTIVITY_JSON:direction::STRING                 AS DIRECTION,
    t.ACTIVITY_JSON:envelope                            AS ENVELOPE_JSON,
    t.ACTIVITY_JSON:envelope:sender                      AS SENDER_JSON,
    t.ACTIVITY_ID,
    t.ACTIVITY_JSON:opens                                 AS OPENS_JSON,
    t.ACTIVITY_JSON:sender::STRING                        AS SENDER,
    t.ACTIVITY_JSON:status::STRING                        AS STATUS,
    t.ACTIVITY_JSON:subject::STRING                       AS SUBJECT,
    t.ACTIVITY_JSON                                        AS JSON_PAYLOAD,
    t.ACTIVITY_JSON:user_id::STRING                        AS USER_ID,
    t.ACTIVITY_JSON:user_name::STRING                      AS USER_NAME,
    t.ACTIVITY_JSON:template_id::STRING                    AS TEMPLATE_ID,
    t.ACTIVITY_JSON:template_name::STRING                  AS TEMPLATE_NAME,
    t.ACTIVITY_JSON:date_sent::TIMESTAMP_NTZ               AS DATE_SENT,
    t.ACTIVITY_JSON:has_reply::BOOLEAN                     AS HAS_REPLY,
    CURRENT_TIMESTAMP()                                      AS INSERT_DATE
FROM SILVER.ALL_ACTIVITIES_TRANSIENT t
WHERE t.ACTIVITY_TYPE = 'Email';

-- ---------------------------------------------------------------------------
-- 3. CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS
--    Resolve every top-level custom.cf_<hash> key on each CustomActivity
--    record to its human field name (via CUSTOM_ACTIVITY_FIELDS), repair any
--    value that looks like a single-quoted pseudo-JSON array (multi-select
--    fields), then wrap into one VARIANT object per activity.
-- ---------------------------------------------------------------------------
TRUNCATE TABLE SILVER.CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS;

INSERT INTO SILVER.CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS (
    LEAD_ID, ACTIVITY_ID, ACTIVITY_AT, WRAPPED_ACTIVITIES, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
WITH raw_fields AS (
    SELECT
        t.LEAD_ID,
        t.ACTIVITY_ID,
        t.ACTIVITY_JSON:activity_at::TIMESTAMP_NTZ       AS ACTIVITY_AT,
        t.ACTIVITY_JSON:custom_activity_type_id::STRING  AS CUSTOM_ACTIVITY_TYPE_ID,
        REPLACE(f.key, 'custom.', '')                     AS FIELD_ID,
        f.value                                           AS RAW_VALUE
    FROM SILVER.ALL_ACTIVITIES_TRANSIENT t,
         LATERAL FLATTEN(input => t.ACTIVITY_JSON) f
    WHERE t.ACTIVITY_TYPE = 'CustomActivity'
      AND f.key LIKE 'custom.cf!_%' ESCAPE '!'
),
resolved_fields AS (
    SELECT
        r.LEAD_ID, r.ACTIVITY_ID, r.ACTIVITY_AT,
        COALESCE(caf.FIELD_NAME, r.FIELD_ID) AS FIELD_NAME,
        CASE
            WHEN TRIM(r.RAW_VALUE::STRING) LIKE '[%' AND TRIM(r.RAW_VALUE::STRING) LIKE '%]'
                THEN SILVER.REPAIR_AND_PARSE_JSON(r.RAW_VALUE::STRING)
            ELSE r.RAW_VALUE
        END AS RESOLVED_VALUE
    FROM raw_fields r
    LEFT JOIN SILVER.CUSTOM_ACTIVITY_FIELDS caf
        ON caf.CUSTOM_ACTIVITY_TYPE_ID = r.CUSTOM_ACTIVITY_TYPE_ID AND caf.FIELD_ID = r.FIELD_ID
),
aggregated AS (
    SELECT
        LEAD_ID, ACTIVITY_ID, MAX(ACTIVITY_AT) AS ACTIVITY_AT,
        OBJECT_AGG(FIELD_NAME, RESOLVED_VALUE) AS WRAPPED_ACTIVITIES
    FROM resolved_fields
    GROUP BY LEAD_ID, ACTIVITY_ID
)
SELECT
    LEAD_ID, ACTIVITY_ID, ACTIVITY_AT, WRAPPED_ACTIVITIES,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), MD5(TO_VARCHAR(WRAPPED_ACTIVITIES))
FROM aggregated;

-- ---------------------------------------------------------------------------
-- 4. LEADS_ACTIVITIES_SUMMARY
--    Master table: LEAD_ACTIVITIES_PROCESSED joined to CUSTOM_ACTIVITIES_
--    ALL_LEADS_DETAILS, CUSTOM_ACTIVITY_TYPES, and CLOSE_CRM_USERS_PROCESSED.
--    Outcome resolved dynamically per type via the type's own "*Outcome*"
--    field (see header note) instead of a hardcoded type-ID CASE.
-- ---------------------------------------------------------------------------
TRUNCATE TABLE SILVER.LEADS_ACTIVITIES_SUMMARY;

INSERT INTO SILVER.LEADS_ACTIVITIES_SUMMARY (
    ACTIVITY_ID, LEAD_ID, CONTACT_ID, USER_ID, TYPE, TEXT, CREATED_BY_NAME, UPDATED_BY_NAME, ATTENDEES,
    CUSTOM_ACTIVITY_TYPE_ID, MEETING_STARTS_AT, MEETING_END_AT, MEETING_STATUS, ACTIVITY_AT, DATE_CREATED, DATE_UPDATED,
    CREATED_BY_USER, UPDATED_BY_USER, INSERT_DATE, UPDATE_DATE, WRAPPED_ACTIVITIES, CUSTOM_ACTIVITY,
    CUSTOM_ACTIVITY_OUTCOME_NAME, CUSTOM_ACTIVITY_OUTCOME, DEA_INTERNAL_NAME, DEA_INTERNAL_EMAIL
)
WITH outcome_field AS (
    SELECT CUSTOM_ACTIVITY_TYPE_ID, FIELD_NAME
    FROM SILVER.CUSTOM_ACTIVITY_FIELDS
    WHERE FIELD_NAME ILIKE '%outcome%'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CUSTOM_ACTIVITY_TYPE_ID ORDER BY FIELD_NAME) = 1
)
SELECT
    p.ACTIVITY_ID, p.LEAD_ID, p.CONTACT_ID, p.USER_ID, p.TYPE, p.TEXT, p.CREATED_BY_NAME, p.UPDATED_BY_NAME, p.ATTENDEES,
    p.CUSTOM_ACTIVITY_TYPE_ID, p.MEETING_STARTS_AT, p.MEETING_END_AT, p.MEETING_STATUS, p.ACTIVITY_AT, p.DATE_CREATED, p.DATE_UPDATED,
    p.CREATED_BY_USER, p.UPDATED_BY_USER, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(),
    w.WRAPPED_ACTIVITIES,
    ct.CUSTOM_ACTIVITY_TYPE_NAME AS CUSTOM_ACTIVITY,
    CASE WHEN ouf.FIELD_NAME IS NOT NULL THEN GET(w.WRAPPED_ACTIVITIES, ouf.FIELD_NAME)::STRING END AS CUSTOM_ACTIVITY_OUTCOME_NAME,
    REGEXP_SUBSTR(
        CASE WHEN ouf.FIELD_NAME IS NOT NULL THEN GET(w.WRAPPED_ACTIVITIES, ouf.FIELD_NAME)::STRING END,
        '^[0-9]+'
    ) AS CUSTOM_ACTIVITY_OUTCOME,
    TRIM(COALESCE(u.FIRST_NAME,'') || ' ' || COALESCE(u.LAST_NAME,'')) AS DEA_INTERNAL_NAME,
    u.EMAIL AS DEA_INTERNAL_EMAIL
FROM SILVER.LEAD_ACTIVITIES_PROCESSED p
LEFT JOIN SILVER.CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS w ON w.LEAD_ID = p.LEAD_ID AND w.ACTIVITY_ID = p.ACTIVITY_ID
LEFT JOIN SILVER.CUSTOM_ACTIVITY_TYPES ct ON ct.CUSTOM_ACTIVITY_TYPE_ID = p.CUSTOM_ACTIVITY_TYPE_ID
LEFT JOIN outcome_field ouf ON ouf.CUSTOM_ACTIVITY_TYPE_ID = p.CUSTOM_ACTIVITY_TYPE_ID
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED u ON u.USER_ID = p.USER_ID;

-- ---------------------------------------------------------------------------
-- Sanity checks
-- ---------------------------------------------------------------------------
SELECT 'LEAD_ACTIVITIES_PROCESSED (CustomActivity)' AS t, COUNT(*) AS n FROM SILVER.LEAD_ACTIVITIES_PROCESSED
UNION ALL SELECT 'LEAD_ACTIVITIES_EMAIL', COUNT(*) FROM SILVER.LEAD_ACTIVITIES_EMAIL
UNION ALL SELECT 'CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS', COUNT(*) FROM SILVER.CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS
UNION ALL SELECT 'LEADS_ACTIVITIES_SUMMARY', COUNT(*) FROM SILVER.LEADS_ACTIVITIES_SUMMARY
UNION ALL SELECT 'LEADS_ACTIVITIES_SUMMARY w/ outcome resolved', COUNT(*) FROM SILVER.LEADS_ACTIVITIES_SUMMARY WHERE CUSTOM_ACTIVITY_OUTCOME_NAME IS NOT NULL;
