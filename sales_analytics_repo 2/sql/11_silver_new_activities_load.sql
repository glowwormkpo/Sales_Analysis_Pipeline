/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data)
   11_silver_new_activities_load.sql

   Loads CALLS, SMS_MESSAGES, MEETINGS, NOTES, LEAD_MERGES, and
   LEAD_CREATED_EVENTS from the mixed activity stream in
   BRONZE.LEAD_ACTIVITIES_RAW.

   This is a one-time bulk historical load (28 real days loaded all at once),
   not the day-by-day simulation loop from Phase 3, so plain INSERT INTO ...
   SELECT is used rather than MERGE -- ALL_ACTIVITIES_TRANSIENT below already
   dedupes each activity down to its single latest version first, so a
   straight insert is correct. (Incremental MERGE logic can be layered on
   later if this needs to support daily refreshes going forward.)
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

-- One flatten + dedupe pass over the whole mixed activity stream, materialized
-- once so each type-specific load below queries it cheaply instead of each
-- re-flattening all 200,051 Bronze rows (~5.2M activities) from scratch.
CREATE OR REPLACE TRANSIENT TABLE SILVER.ALL_ACTIVITIES_TRANSIENT AS
SELECT
    f.value:id::STRING      AS ACTIVITY_ID,
    f.value:_type::STRING   AS ACTIVITY_TYPE,
    f.value:lead_id::STRING AS LEAD_ID,
    f.value                 AS ACTIVITY_JSON,
    b.INSERT_DATE            AS SOURCE_INSERT_DATE
FROM BRONZE.LEAD_ACTIVITIES_RAW b,
     LATERAL FLATTEN(input => b.JSON_OBJECT:data) f
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY f.value:id::STRING
    ORDER BY f.value:date_updated::TIMESTAMP_NTZ DESC NULLS LAST, b.INSERT_DATE DESC
) = 1;

TRUNCATE TABLE SILVER.CALLS;
TRUNCATE TABLE SILVER.SMS_MESSAGES;
TRUNCATE TABLE SILVER.MEETINGS;
TRUNCATE TABLE SILVER.NOTES;
TRUNCATE TABLE SILVER.LEAD_MERGES;
TRUNCATE TABLE SILVER.LEAD_CREATED_EVENTS;

-- ---------------------------------------------------------------------------
-- CALLS
-- ---------------------------------------------------------------------------
INSERT INTO SILVER.CALLS (
    ACTIVITY_ID, LEAD_ID, CONTACT_ID, USER_ID, USER_NAME, DIRECTION, STATUS, DISPOSITION,
    DURATION, RECORDING_DURATION, PHONE, LOCAL_PHONE, REMOTE_PHONE, NOTE, OUTCOME_ID,
    OUTCOME_REASON, OUTCOME_AUTOFILL_REASONING, OUTCOME_AUTOFILL_CONFIDENCE, HAS_RECORDING,
    RECORDING_URL, CALL_METHOD, SOURCE, COST, ACTIVITY_AT, DATE_ANSWERED, DATE_CREATED,
    DATE_UPDATED, CREATED_BY, CREATED_BY_NAME, ORGANIZATION_ID, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    ACTIVITY_ID,
    ACTIVITY_JSON:lead_id::STRING, ACTIVITY_JSON:contact_id::STRING, ACTIVITY_JSON:user_id::STRING,
    ACTIVITY_JSON:user_name::STRING, ACTIVITY_JSON:direction::STRING, ACTIVITY_JSON:status::STRING,
    ACTIVITY_JSON:disposition::STRING, ACTIVITY_JSON:duration::NUMBER, ACTIVITY_JSON:recording_duration::NUMBER,
    ACTIVITY_JSON:phone::STRING, ACTIVITY_JSON:local_phone::STRING, ACTIVITY_JSON:remote_phone::STRING,
    ACTIVITY_JSON:note::STRING, ACTIVITY_JSON:outcome_id::STRING, ACTIVITY_JSON:outcome_reason::STRING,
    ACTIVITY_JSON:outcome_autofill_reasoning::STRING, ACTIVITY_JSON:outcome_autofill_confidence::STRING,
    ACTIVITY_JSON:has_recording::BOOLEAN, ACTIVITY_JSON:recording_url::STRING, ACTIVITY_JSON:call_method::STRING,
    ACTIVITY_JSON:source::STRING, ACTIVITY_JSON:cost::STRING, ACTIVITY_JSON:activity_at::TIMESTAMP_NTZ,
    ACTIVITY_JSON:date_answered::TIMESTAMP_NTZ, ACTIVITY_JSON:date_created::TIMESTAMP_NTZ,
    ACTIVITY_JSON:date_updated::TIMESTAMP_NTZ, ACTIVITY_JSON:created_by::STRING, ACTIVITY_JSON:created_by_name::STRING,
    ACTIVITY_JSON:organization_id::STRING, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), MD5(ACTIVITY_JSON::STRING)
FROM SILVER.ALL_ACTIVITIES_TRANSIENT
WHERE ACTIVITY_TYPE = 'Call';

-- ---------------------------------------------------------------------------
-- SMS_MESSAGES
-- ---------------------------------------------------------------------------
INSERT INTO SILVER.SMS_MESSAGES (
    ACTIVITY_ID, LEAD_ID, CONTACT_ID, USER_ID, USER_NAME, DIRECTION, STATUS, TEXT, LOCAL_PHONE,
    REMOTE_PHONE, TEMPLATE_ID, SEQUENCE_ID, SEQUENCE_NAME, ERROR_MESSAGE, DATE_SENT, ACTIVITY_AT,
    DATE_CREATED, DATE_UPDATED, CREATED_BY, ORGANIZATION_ID, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    ACTIVITY_ID,
    ACTIVITY_JSON:lead_id::STRING, ACTIVITY_JSON:contact_id::STRING, ACTIVITY_JSON:user_id::STRING,
    ACTIVITY_JSON:user_name::STRING, ACTIVITY_JSON:direction::STRING, ACTIVITY_JSON:status::STRING,
    ACTIVITY_JSON:text::STRING, ACTIVITY_JSON:local_phone::STRING, ACTIVITY_JSON:remote_phone::STRING,
    ACTIVITY_JSON:template_id::STRING, ACTIVITY_JSON:sequence_id::STRING, ACTIVITY_JSON:sequence_name::STRING,
    ACTIVITY_JSON:error_message::STRING, ACTIVITY_JSON:date_sent::TIMESTAMP_NTZ, ACTIVITY_JSON:activity_at::TIMESTAMP_NTZ,
    ACTIVITY_JSON:date_created::TIMESTAMP_NTZ, ACTIVITY_JSON:date_updated::TIMESTAMP_NTZ,
    ACTIVITY_JSON:created_by::STRING, ACTIVITY_JSON:organization_id::STRING,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), MD5(ACTIVITY_JSON::STRING)
FROM SILVER.ALL_ACTIVITIES_TRANSIENT
WHERE ACTIVITY_TYPE = 'SMS';

-- ---------------------------------------------------------------------------
-- MEETINGS
-- ---------------------------------------------------------------------------
INSERT INTO SILVER.MEETINGS (
    ACTIVITY_ID, LEAD_ID, CONTACT_ID, USER_ID, USER_NAME, TITLE, STATUS, SOURCE, NOTE, LOCATION,
    STARTS_AT, ENDS_AT, DURATION, ACTUAL_DURATION, IS_RECURRING, ATTENDEES, CALENDAR_EVENT_UIDS,
    PROVIDER_CALENDAR_TYPE, OUTCOME_ID, OUTCOME_REASON, ACTIVITY_AT, DATE_CREATED, DATE_UPDATED,
    CREATED_BY, ORGANIZATION_ID, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    ACTIVITY_ID,
    ACTIVITY_JSON:lead_id::STRING, ACTIVITY_JSON:contact_id::STRING, ACTIVITY_JSON:user_id::STRING,
    ACTIVITY_JSON:user_name::STRING, ACTIVITY_JSON:title::STRING, ACTIVITY_JSON:status::STRING,
    ACTIVITY_JSON:source::STRING, ACTIVITY_JSON:note::STRING, ACTIVITY_JSON:location::STRING,
    ACTIVITY_JSON:starts_at::TIMESTAMP_NTZ, ACTIVITY_JSON:ends_at::TIMESTAMP_NTZ, ACTIVITY_JSON:duration::NUMBER,
    ACTIVITY_JSON:actual_duration::NUMBER, ACTIVITY_JSON:is_recurring::BOOLEAN, ACTIVITY_JSON:attendees,
    ACTIVITY_JSON:calendar_event_uids, ACTIVITY_JSON:provider_calendar_type::STRING, ACTIVITY_JSON:outcome_id::STRING,
    ACTIVITY_JSON:outcome_reason::STRING, ACTIVITY_JSON:activity_at::TIMESTAMP_NTZ, ACTIVITY_JSON:date_created::TIMESTAMP_NTZ,
    ACTIVITY_JSON:date_updated::TIMESTAMP_NTZ, ACTIVITY_JSON:created_by::STRING, ACTIVITY_JSON:organization_id::STRING,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), MD5(ACTIVITY_JSON::STRING)
FROM SILVER.ALL_ACTIVITIES_TRANSIENT
WHERE ACTIVITY_TYPE = 'Meeting';

-- ---------------------------------------------------------------------------
-- NOTES
-- ---------------------------------------------------------------------------
INSERT INTO SILVER.NOTES (
    ACTIVITY_ID, LEAD_ID, CONTACT_ID, USER_ID, USER_NAME, NOTE, NOTE_HTML, TITLE, PINNED,
    ACTIVITY_AT, DATE_CREATED, DATE_UPDATED, CREATED_BY, ORGANIZATION_ID, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    ACTIVITY_ID,
    ACTIVITY_JSON:lead_id::STRING, ACTIVITY_JSON:contact_id::STRING, ACTIVITY_JSON:user_id::STRING,
    ACTIVITY_JSON:user_name::STRING, ACTIVITY_JSON:note::STRING, ACTIVITY_JSON:note_html::STRING,
    ACTIVITY_JSON:title::STRING, ACTIVITY_JSON:pinned::BOOLEAN, ACTIVITY_JSON:activity_at::TIMESTAMP_NTZ,
    ACTIVITY_JSON:date_created::TIMESTAMP_NTZ, ACTIVITY_JSON:date_updated::TIMESTAMP_NTZ,
    ACTIVITY_JSON:created_by::STRING, ACTIVITY_JSON:organization_id::STRING,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), MD5(ACTIVITY_JSON::STRING)
FROM SILVER.ALL_ACTIVITIES_TRANSIENT
WHERE ACTIVITY_TYPE = 'Note';

-- ---------------------------------------------------------------------------
-- LEAD_MERGES
-- ---------------------------------------------------------------------------
INSERT INTO SILVER.LEAD_MERGES (
    ACTIVITY_ID, LEAD_ID, DESTINATION_LEAD_ID, DESTINATION_DISPLAY_NAME, SOURCE_LEAD_ID,
    SOURCE_DISPLAY_NAME, MERGE_STATUS, ERROR_MESSAGE, USER_ID, USER_NAME, ACTIVITY_AT,
    DATE_CREATED, DATE_UPDATED, CREATED_BY, ORGANIZATION_ID, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    ACTIVITY_ID,
    ACTIVITY_JSON:lead_id::STRING, ACTIVITY_JSON:destination_lead_id::STRING, ACTIVITY_JSON:destination_display_name::STRING,
    ACTIVITY_JSON:source_lead_id::STRING, ACTIVITY_JSON:source_display_name::STRING, ACTIVITY_JSON:merge_status::STRING,
    ACTIVITY_JSON:error_message::STRING, ACTIVITY_JSON:user_id::STRING, ACTIVITY_JSON:user_name::STRING,
    ACTIVITY_JSON:activity_at::TIMESTAMP_NTZ, ACTIVITY_JSON:date_created::TIMESTAMP_NTZ, ACTIVITY_JSON:date_updated::TIMESTAMP_NTZ,
    ACTIVITY_JSON:created_by::STRING, ACTIVITY_JSON:organization_id::STRING,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), MD5(ACTIVITY_JSON::STRING)
FROM SILVER.ALL_ACTIVITIES_TRANSIENT
WHERE ACTIVITY_TYPE = 'LeadMerge';

-- ---------------------------------------------------------------------------
-- LEAD_CREATED_EVENTS
-- ---------------------------------------------------------------------------
INSERT INTO SILVER.LEAD_CREATED_EVENTS (
    ACTIVITY_ID, LEAD_ID, USER_ID, USER_NAME, SOURCE, IMPORT_ID, ACTIVITY_AT, DATE_CREATED,
    DATE_UPDATED, CREATED_BY, ORGANIZATION_ID, INSERT_DATE, UPDATE_DATE, MD5_HASH
)
SELECT
    ACTIVITY_ID,
    ACTIVITY_JSON:lead_id::STRING, ACTIVITY_JSON:user_id::STRING, ACTIVITY_JSON:user_name::STRING,
    ACTIVITY_JSON:source::STRING, ACTIVITY_JSON:import_id::STRING, ACTIVITY_JSON:activity_at::TIMESTAMP_NTZ,
    ACTIVITY_JSON:date_created::TIMESTAMP_NTZ, ACTIVITY_JSON:date_updated::TIMESTAMP_NTZ,
    ACTIVITY_JSON:created_by::STRING, ACTIVITY_JSON:organization_id::STRING,
    CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), MD5(ACTIVITY_JSON::STRING)
FROM SILVER.ALL_ACTIVITIES_TRANSIENT
WHERE ACTIVITY_TYPE = 'Created';

-- ---------------------------------------------------------------------------
-- Sanity check: row counts should roughly match the earlier activity-type
-- breakdown (Call 1,991,124 / SMS 1,653,141 / Meeting 141,700 / Note 73,855 /
-- LeadMerge 969 / Created 90,936) minus duplicates removed by dedup above.
-- ---------------------------------------------------------------------------
SELECT 'CALLS' AS t, COUNT(*) FROM SILVER.CALLS
UNION ALL SELECT 'SMS_MESSAGES', COUNT(*) FROM SILVER.SMS_MESSAGES
UNION ALL SELECT 'MEETINGS', COUNT(*) FROM SILVER.MEETINGS
UNION ALL SELECT 'NOTES', COUNT(*) FROM SILVER.NOTES
UNION ALL SELECT 'LEAD_MERGES', COUNT(*) FROM SILVER.LEAD_MERGES
UNION ALL SELECT 'LEAD_CREATED_EVENTS', COUNT(*) FROM SILVER.LEAD_CREATED_EVENTS;
