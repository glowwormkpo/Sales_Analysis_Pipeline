/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data)
   17_silver_refresh_procedure.sql

   Wraps the real-data Silver load logic from 11_silver_new_activities_load.sql,
   12_silver_dictionary_and_users_load.sql, 13_silver_customactivity_email_load.sql,
   and 14_silver_leads_entities_load.sql into a single callable stored
   procedure, SILVER.REFRESH_ALL_REAL_DATA(), so orchestration has one thing
   to call instead of five separate scripts.

   This is a full-refresh procedure, not an incremental one -- it always
   rebuilds every Silver table from whatever is currently in Bronze
   (TRUNCATE + re-derive), the same "latest snapshot wins" pattern used
   throughout Phase 4. That's intentional: real Bronze ingestion here is a
   manual export-from-Postgres + PUT + COPY INTO process (Snowflake trial
   accounts can't use External Access Integration, so there's no way to pull
   fresh Postgres data automatically -- see orchestration notes in
   18_orchestration_real_data.sql), so there's no reliable "just today's new
   rows" concept to do a true incremental merge against. A full rebuild is
   safe and cheap enough at this data volume (~600K Bronze rows) to just
   always do it in full.

   Does NOT recreate the SILVER.REPAIR_AND_PARSE_JSON / REPAIR_SINGLE_QUOTED_
   JSON UDFs (04_json_repair_udf.sql) or SILVER.STRIP_DESCRIPTION_VALUES UDF
   (created inline in 12_silver_dictionary_and_users_load.sql) -- those are
   one-time object DDL, already created, just called here.

   Ordering matters (enforced by statement order below, not by Snowflake):
     1. ALL_ACTIVITIES_TRANSIENT must exist before anything that reads it
        (CALLS/SMS/MEETINGS/NOTES/LEAD_MERGES/LEAD_CREATED_EVENTS, and
        LEAD_ACTIVITIES_PROCESSED/LEAD_ACTIVITIES_EMAIL).
     2. CUSTOM_ACTIVITY_TYPES/FIELDS and CLOSE_CRM_USERS_PROCESSED must be
        loaded before CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS (joins to
        CUSTOM_ACTIVITY_FIELDS) and LEADS_ACTIVITIES_SUMMARY (joins to both).
     3. LEADS_PROCESSED/CONTACTS/OPPORTUNITIES/TASKS are independent of the
        activity chain (sourced straight from BRONZE.LEADS_RAW) and can run
        anywhere, kept last here for readability.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

CREATE OR REPLACE PROCEDURE SILVER.REFRESH_ALL_REAL_DATA()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- =========================================================================
    -- 1. Mixed activity stream: dedupe + type-specific loads
    --    (11_silver_new_activities_load.sql)
    -- =========================================================================
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

    -- =========================================================================
    -- 2. Custom activity dictionary + Close CRM users
    --    (12_silver_dictionary_and_users_load.sql)
    -- =========================================================================
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

    -- =========================================================================
    -- 3. CustomActivity + Email routing, outcome resolution
    --    (13_silver_customactivity_email_load.sql)
    -- =========================================================================
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

    -- =========================================================================
    -- 4. Lead entities: contacts, opportunities, tasks
    --    (14_silver_leads_entities_load.sql)
    -- =========================================================================
    CREATE OR REPLACE TRANSIENT TABLE SILVER.LEADS_TRANSIENT AS
    SELECT
        b.JSON_OBJECT   AS LEAD_JSON,
        b.INSERT_DATE   AS SOURCE_INSERT_DATE
    FROM BRONZE.LEADS_RAW b
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY b.JSON_OBJECT:id::STRING
        ORDER BY b.JSON_OBJECT:date_updated::TIMESTAMP_NTZ DESC NULLS LAST, b.INSERT_DATE DESC
    ) = 1;

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

    RETURN 'Silver real-data refresh complete: ' || TO_VARCHAR(CURRENT_TIMESTAMP());
END;
$$;

-- Test call:
-- CALL SILVER.REFRESH_ALL_REAL_DATA();
