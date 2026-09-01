/* =============================================================================
   Sales Analytics Pipeline - Phase 3
   06_silver_merge_dedup.sql

   The CDC / dedup / upsert logic (Phase 1 Sec. 5.4-5.6, Phase 2 Sec. 4.2):
     - MD5_HASH detects real changes vs. re-delivery of unchanged rows.
     - Dedup key: LEAD_ID + ACTIVITY_ID (a day's cumulative file can, in
       principle, carry more than one snapshot of the same activity --
       QUALIFY ... ROW_NUMBER() keeps the latest ACTIVITY_AT before MERGE).
     - MERGE INTO: insert new, update existing only when MD5_HASH changed,
       maintaining INSERT_DATE / UPDATE_DATE.
     - PK resolution (Phase 2 Sec. 8 open item): ACTIVITY_ID is used as the
       global primary key on LEAD_ACTIVITIES_PROCESSED / LEADS_ACTIVITIES_SUMMARY,
       consistent with Close CRM activity IDs being globally unique; LEAD_ID
       is still carried as an attribute (and as part of the dedup partition)
       for defense-in-depth. Resolves that open item.

   Everything here operates on SILVER.*_TRANSIENT, populated for "today" by
   05_silver_transient_flatten.sql's LOAD_SILVER_TRANSIENT procedure, so run
   that first.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

CREATE OR REPLACE PROCEDURE SILVER.MERGE_SILVER_DAY(LOAD_DATE DATE)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- =========================================================================
    -- 1. CLOSE_CRM_USERS_PROCESSED  (flattened straight from Bronze; no transient)
    -- =========================================================================
    MERGE INTO SILVER.CLOSE_CRM_USERS_PROCESSED tgt
    USING (
        SELECT
            f.value:id::STRING           AS USER_ID,
            f.value:email::STRING        AS EMAIL,
            f.value:first_name::STRING   AS FIRST_NAME,
            f.value:last_name::STRING    AS LAST_NAME,
            f.value:created_at::TIMESTAMP_NTZ AS DATE_CREATED,
            f.value:updated_at::TIMESTAMP_NTZ AS DATE_UPDATED,
            MD5(CONCAT_WS('|', f.value:id::STRING, COALESCE(f.value:email::STRING,''),
                          COALESCE(f.value:first_name::STRING,''), COALESCE(f.value:last_name::STRING,''),
                          TO_VARCHAR(f.value:updated_at::TIMESTAMP_NTZ))) AS MD5_HASH
        FROM BRONZE.CLOSE_CRM_USERS_RAW b,
             LATERAL FLATTEN(input => b.JSON_OBJECT:data) f
        WHERE TO_DATE(b.INSERT_DATE) = :LOAD_DATE
        QUALIFY ROW_NUMBER() OVER (PARTITION BY f.value:id::STRING ORDER BY f.value:updated_at::TIMESTAMP_NTZ DESC) = 1
    ) src
    ON tgt.USER_ID = src.USER_ID
    WHEN MATCHED AND tgt.MD5_HASH != src.MD5_HASH THEN UPDATE SET
        EMAIL = src.EMAIL, FIRST_NAME = src.FIRST_NAME, LAST_NAME = src.LAST_NAME,
        DATE_CREATED = src.DATE_CREATED, DATE_UPDATED = src.DATE_UPDATED,
        UPDATE_DATE = CURRENT_TIMESTAMP(), MD5_HASH = src.MD5_HASH
    WHEN NOT MATCHED THEN INSERT (USER_ID, EMAIL, FIRST_NAME, LAST_NAME, MD5_HASH, DATE_CREATED, DATE_UPDATED, INSERT_DATE, UPDATE_DATE)
        VALUES (src.USER_ID, src.EMAIL, src.FIRST_NAME, src.LAST_NAME, src.MD5_HASH, src.DATE_CREATED, src.DATE_UPDATED, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

    -- =========================================================================
    -- 2a. CUSTOM_ACTIVITY_TYPES  (activity-type dictionary -- Triage Call,
    --     Prospecting Activity, Strategy Call, New Sale, ...)
    -- =========================================================================
    MERGE INTO SILVER.CUSTOM_ACTIVITY_TYPES tgt
    USING (
        SELECT
            t.JSON_OBJECT:id::STRING    AS CUSTOM_ACTIVITY_TYPE_ID,
            t.JSON_OBJECT:name::STRING  AS CUSTOM_ACTIVITY_TYPE_NAME,
            MD5(CONCAT_WS('|', t.JSON_OBJECT:id::STRING, COALESCE(t.JSON_OBJECT:name::STRING,''))) AS MD5_HASH
        FROM SILVER.CUSTOM_ACTIVITIES_TRANSIENT t
        QUALIFY ROW_NUMBER() OVER (PARTITION BY t.JSON_OBJECT:id::STRING ORDER BY t.INSERT_DATE DESC) = 1
    ) src
    ON tgt.CUSTOM_ACTIVITY_TYPE_ID = src.CUSTOM_ACTIVITY_TYPE_ID
    WHEN MATCHED AND tgt.MD5_HASH != src.MD5_HASH THEN UPDATE SET
        CUSTOM_ACTIVITY_TYPE_NAME = src.CUSTOM_ACTIVITY_TYPE_NAME, UPDATE_DATE = CURRENT_TIMESTAMP(), MD5_HASH = src.MD5_HASH
    WHEN NOT MATCHED THEN INSERT (CUSTOM_ACTIVITY_TYPE_ID, CUSTOM_ACTIVITY_TYPE_NAME, MD5_HASH, INSERT_DATE, UPDATE_DATE)
        VALUES (src.CUSTOM_ACTIVITY_TYPE_ID, src.CUSTOM_ACTIVITY_TYPE_NAME, src.MD5_HASH, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

    -- =========================================================================
    -- 2b. CUSTOM_ACTIVITY_FIELDS  (per-type field dictionary -- resolves the
    --     opaque custom.cf_<hash> keys on activity records to human field
    --     names, e.g. cf_h3tYb9... -> "Setter". Source: the nested "fields"
    --     array on each CustomActivityType object in custom_activites_raw.)
    -- =========================================================================
    MERGE INTO SILVER.CUSTOM_ACTIVITY_FIELDS tgt
    USING (
        SELECT
            t.JSON_OBJECT:id::STRING    AS CUSTOM_ACTIVITY_TYPE_ID,
            f.value:id::STRING          AS FIELD_ID,
            f.value:name::STRING        AS FIELD_NAME,
            f.value:type::STRING        AS FIELD_TYPE,
            MD5(CONCAT_WS('|', t.JSON_OBJECT:id::STRING, f.value:id::STRING,
                          COALESCE(f.value:name::STRING,''), COALESCE(f.value:type::STRING,''))) AS MD5_HASH
        FROM SILVER.CUSTOM_ACTIVITIES_TRANSIENT t,
             LATERAL FLATTEN(input => t.JSON_OBJECT:fields) f
        QUALIFY ROW_NUMBER() OVER (PARTITION BY t.JSON_OBJECT:id::STRING, f.value:id::STRING ORDER BY t.INSERT_DATE DESC) = 1
    ) src
    ON tgt.CUSTOM_ACTIVITY_TYPE_ID = src.CUSTOM_ACTIVITY_TYPE_ID AND tgt.FIELD_ID = src.FIELD_ID
    WHEN MATCHED AND tgt.MD5_HASH != src.MD5_HASH THEN UPDATE SET
        FIELD_NAME = src.FIELD_NAME, FIELD_TYPE = src.FIELD_TYPE, UPDATE_DATE = CURRENT_TIMESTAMP(), MD5_HASH = src.MD5_HASH
    WHEN NOT MATCHED THEN INSERT (CUSTOM_ACTIVITY_TYPE_ID, FIELD_ID, FIELD_NAME, FIELD_TYPE, MD5_HASH, INSERT_DATE, UPDATE_DATE)
        VALUES (src.CUSTOM_ACTIVITY_TYPE_ID, src.FIELD_ID, src.FIELD_NAME, src.FIELD_TYPE, src.MD5_HASH, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

    -- =========================================================================
    -- 3. LEAD_ACTIVITIES_PROCESSED  (the core deduplicated activity table)
    -- =========================================================================
    MERGE INTO SILVER.LEAD_ACTIVITIES_PROCESSED tgt
    USING (
        WITH src AS (
            SELECT
                t.JSON_OBJECT:id::STRING                       AS ACTIVITY_ID,
                t.JSON_OBJECT:lead_id::STRING                  AS LEAD_ID,
                t.JSON_OBJECT:contact_id::STRING               AS CONTACT_ID,
                t.JSON_OBJECT:user_id::STRING                  AS USER_ID,
                t.JSON_OBJECT:type::STRING                     AS TYPE,
                t.JSON_OBJECT:text::STRING                     AS TEXT,
                t.JSON_OBJECT:created_by::STRING               AS CREATED_BY_NAME,
                t.JSON_OBJECT:updated_by::STRING               AS UPDATED_BY_NAME,
                NULL                                            AS ATTENDEES,
                t.JSON_OBJECT:custom_activity_type_id::STRING  AS CUSTOM_ACTIVITY_TYPE_ID,
                NULL::TIMESTAMP_NTZ                             AS MEETING_STARTS_AT,
                NULL::TIMESTAMP_NTZ                             AS MEETING_END_AT,
                NULL::STRING                                    AS MEETING_STATUS,
                t.JSON_OBJECT:activity_at::TIMESTAMP_NTZ        AS ACTIVITY_AT,
                t.JSON_OBJECT:date_created::TIMESTAMP_NTZ       AS DATE_CREATED,
                t.JSON_OBJECT:date_updated::TIMESTAMP_NTZ       AS DATE_UPDATED,
                t.JSON_OBJECT:created_by::STRING                AS CREATED_BY_USER,
                t.JSON_OBJECT:updated_by::STRING                AS UPDATED_BY_USER
            FROM SILVER.LEAD_ACTIVITIES_PROCESSED_TRANSIENT t
        ),
        deduped AS (
            SELECT *,
                MD5(CONCAT_WS('|', ACTIVITY_ID, LEAD_ID, COALESCE(USER_ID,''), COALESCE(TYPE,''), COALESCE(TEXT,''),
                              COALESCE(CUSTOM_ACTIVITY_TYPE_ID,''),
                              TO_VARCHAR(ACTIVITY_AT), TO_VARCHAR(DATE_UPDATED))) AS MD5_HASH
            FROM src
            QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID, ACTIVITY_ID ORDER BY ACTIVITY_AT DESC NULLS LAST) = 1
        )
        SELECT * FROM deduped
    ) src
    ON tgt.ACTIVITY_ID = src.ACTIVITY_ID
    WHEN MATCHED AND tgt.MD5_HASH != src.MD5_HASH THEN UPDATE SET
        LEAD_ID = src.LEAD_ID, CONTACT_ID = src.CONTACT_ID, USER_ID = src.USER_ID, TYPE = src.TYPE, TEXT = src.TEXT,
        CREATED_BY_NAME = src.CREATED_BY_NAME, UPDATED_BY_NAME = src.UPDATED_BY_NAME, ATTENDEES = src.ATTENDEES,
        CUSTOM_ACTIVITY_TYPE_ID = src.CUSTOM_ACTIVITY_TYPE_ID,
        MEETING_STARTS_AT = src.MEETING_STARTS_AT, MEETING_END_AT = src.MEETING_END_AT, MEETING_STATUS = src.MEETING_STATUS,
        ACTIVITY_AT = src.ACTIVITY_AT, DATE_CREATED = src.DATE_CREATED, DATE_UPDATED = src.DATE_UPDATED,
        CREATED_BY_USER = src.CREATED_BY_USER, UPDATED_BY_USER = src.UPDATED_BY_USER,
        UPDATE_DATE = CURRENT_TIMESTAMP(), MD5_HASH = src.MD5_HASH
    WHEN NOT MATCHED THEN INSERT (
        ACTIVITY_ID, LEAD_ID, CONTACT_ID, USER_ID, TYPE, TEXT, CREATED_BY_NAME, UPDATED_BY_NAME, ATTENDEES,
        CUSTOM_ACTIVITY_TYPE_ID, MEETING_STARTS_AT, MEETING_END_AT, MEETING_STATUS,
        ACTIVITY_AT, DATE_CREATED, DATE_UPDATED, CREATED_BY_USER, UPDATED_BY_USER, INSERT_DATE, UPDATE_DATE, MD5_HASH
    ) VALUES (
        src.ACTIVITY_ID, src.LEAD_ID, src.CONTACT_ID, src.USER_ID, src.TYPE, src.TEXT, src.CREATED_BY_NAME, src.UPDATED_BY_NAME, src.ATTENDEES,
        src.CUSTOM_ACTIVITY_TYPE_ID, src.MEETING_STARTS_AT, src.MEETING_END_AT, src.MEETING_STATUS,
        src.ACTIVITY_AT, src.DATE_CREATED, src.DATE_UPDATED, src.CREATED_BY_USER, src.UPDATED_BY_USER, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), src.MD5_HASH
    );

    -- =========================================================================
    -- 4. LEAD_ACTIVITIES_EMAIL  (type = 'Email'; none in the sample generator,
    --    included for completeness -- the source schema supports it)
    -- =========================================================================
    MERGE INTO SILVER.LEAD_ACTIVITIES_EMAIL tgt
    USING (
        SELECT
            t.JSON_OBJECT:id::STRING            AS ACTIVITY_ID,
            t.JSON_OBJECT:lead_id::STRING        AS LEAD_ID,
            t.JSON_OBJECT:user_id::STRING        AS USER_ID,
            t.JSON_OBJECT:subject::STRING         AS SUBJECT,
            t.JSON_OBJECT:body_text::STRING       AS BODY_TEXT,
            t.JSON_OBJECT:direction::STRING       AS DIRECTION,
            t.JSON_OBJECT:status::STRING          AS STATUS,
            t.JSON_OBJECT:date_sent::TIMESTAMP_NTZ AS DATE_SENT,
            t.JSON_OBJECT:has_reply::BOOLEAN       AS HAS_REPLY,
            t.JSON_OBJECT:activity_at::TIMESTAMP_NTZ AS ACTIVITY_AT,
            t.JSON_OBJECT:date_created::TIMESTAMP_NTZ AS DATE_CREATED,
            t.JSON_OBJECT:date_updated::TIMESTAMP_NTZ AS DATE_UPDATED
        FROM SILVER.LEAD_ACTIVITIES_PROCESSED_TRANSIENT t
        WHERE t.JSON_OBJECT:type::STRING = 'Email'
        QUALIFY ROW_NUMBER() OVER (PARTITION BY t.JSON_OBJECT:id::STRING ORDER BY t.JSON_OBJECT:date_updated::TIMESTAMP_NTZ DESC) = 1
    ) src
    ON tgt.ACTIVITY_ID = src.ACTIVITY_ID
    WHEN MATCHED THEN UPDATE SET
        SUBJECT = src.SUBJECT, BODY_TEXT = src.BODY_TEXT, DIRECTION = src.DIRECTION, STATUS = src.STATUS,
        DATE_SENT = src.DATE_SENT, HAS_REPLY = src.HAS_REPLY, DATE_UPDATED = src.DATE_UPDATED
    WHEN NOT MATCHED THEN INSERT (
        LEAD_ID, ACTIVITY_ID, ACTIVITY_AT, USER_ID, SUBJECT, BODY_TEXT, DIRECTION, STATUS, DATE_SENT, HAS_REPLY,
        DATE_CREATED, DATE_UPDATED, INSERT_DATE
    ) VALUES (
        src.LEAD_ID, src.ACTIVITY_ID, src.ACTIVITY_AT, src.USER_ID, src.SUBJECT, src.BODY_TEXT, src.DIRECTION, src.STATUS,
        src.DATE_SENT, src.HAS_REPLY, src.DATE_CREATED, src.DATE_UPDATED, CURRENT_TIMESTAMP()
    );

    -- =========================================================================
    -- 5. CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS  (resolve every top-level
    --    custom.cf_<hash> key on a CustomActivity record to its human field
    --    name via CUSTOM_ACTIVITY_FIELDS, repair+parse any value that is a
    --    single-quoted pseudo-JSON array (multi-select fields like
    --    "Objections Faced" -- this is the JSON-repair UDF's main consumer),
    --    then re-wrap everything into one VARIANT object per activity.
    --
    --    REVISION: the earlier design called REPAIR_AND_PARSE_JSON once per
    --    activity against a single custom_fields_raw blob. The real source
    --    shape has no such blob -- each custom field is its own top-level
    --    "custom.cf_<hash>" key, and only SOME of those values (multi-select
    --    fields) are single-quoted pseudo-JSON that need repairing; the rest
    --    are plain scalars. FLATTEN + per-field repair replaces that.
    -- =========================================================================
    MERGE INTO SILVER.CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS tgt
    USING (
        WITH raw_fields AS (
            SELECT
                t.JSON_OBJECT:id::STRING                      AS ACTIVITY_ID,
                t.JSON_OBJECT:lead_id::STRING                 AS LEAD_ID,
                t.JSON_OBJECT:activity_at::TIMESTAMP_NTZ       AS ACTIVITY_AT,
                t.JSON_OBJECT:custom_activity_type_id::STRING  AS CUSTOM_ACTIVITY_TYPE_ID,
                REPLACE(f.key, 'custom.', '')                  AS FIELD_ID,
                f.value                                        AS RAW_VALUE
            FROM SILVER.LEAD_ACTIVITIES_PROCESSED_TRANSIENT t,
                 LATERAL FLATTEN(input => t.JSON_OBJECT) f
            WHERE t.JSON_OBJECT:type::STRING = 'CustomActivity'
              AND f.key LIKE 'custom.cf\_%' ESCAPE '\'
        ),
        resolved_fields AS (
            SELECT
                r.ACTIVITY_ID, r.LEAD_ID, r.ACTIVITY_AT, r.CUSTOM_ACTIVITY_TYPE_ID,
                COALESCE(caf.FIELD_NAME, r.FIELD_ID) AS FIELD_NAME,
                -- Multi-select field values arrive as a single-quoted,
                -- Python-list-repr STRING (e.g. "['Money', 'Wasn''t Looking
                -- For What We Offered']") instead of a real JSON array; every
                -- other field is a plain scalar and passes through as-is.
                CASE
                    WHEN TRIM(r.RAW_VALUE::STRING) LIKE '[%' AND TRIM(r.RAW_VALUE::STRING) LIKE '%]'
                        THEN SILVER.REPAIR_AND_PARSE_JSON(r.RAW_VALUE::STRING)
                    ELSE r.RAW_VALUE
                END AS RESOLVED_VALUE
            FROM raw_fields r
            LEFT JOIN SILVER.CUSTOM_ACTIVITY_FIELDS caf
                ON caf.CUSTOM_ACTIVITY_TYPE_ID = r.CUSTOM_ACTIVITY_TYPE_ID AND caf.FIELD_ID = r.FIELD_ID
        )
        SELECT
            LEAD_ID, ACTIVITY_ID, MAX(ACTIVITY_AT) AS ACTIVITY_AT,
            OBJECT_AGG(FIELD_NAME, RESOLVED_VALUE) AS WRAPPED_ACTIVITIES
        FROM resolved_fields
        GROUP BY LEAD_ID, ACTIVITY_ID
    ) src
    ON tgt.LEAD_ID = src.LEAD_ID AND tgt.ACTIVITY_ID = src.ACTIVITY_ID
    WHEN MATCHED AND MD5(TO_VARCHAR(tgt.WRAPPED_ACTIVITIES)) != MD5(TO_VARCHAR(src.WRAPPED_ACTIVITIES)) THEN UPDATE SET
        ACTIVITY_AT = src.ACTIVITY_AT, WRAPPED_ACTIVITIES = src.WRAPPED_ACTIVITIES,
        UPDATE_DATE = CURRENT_TIMESTAMP(), MD5_HASH = MD5(TO_VARCHAR(src.WRAPPED_ACTIVITIES))
    WHEN NOT MATCHED THEN INSERT (LEAD_ID, ACTIVITY_ID, ACTIVITY_AT, WRAPPED_ACTIVITIES, INSERT_DATE, UPDATE_DATE, MD5_HASH)
        VALUES (src.LEAD_ID, src.ACTIVITY_ID, src.ACTIVITY_AT, src.WRAPPED_ACTIVITIES, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), MD5(TO_VARCHAR(src.WRAPPED_ACTIVITIES)));

    -- =========================================================================
    -- 6. LEADS_ACTIVITIES_SUMMARY  (master table: join of steps 1, 2a, 3, 5,
    --    scoped to activities touched in today's batch)
    --
    --    CUSTOM_ACTIVITY_OUTCOME_NAME is now resolved dynamically out of
    --    WRAPPED_ACTIVITIES: each activity type stores its own outcome under
    --    a different field name ("Triage Call Outcome", "Strategy Call
    --    Outcome", ...), so the CASE below picks the right key per type. Add
    --    a WHEN here if a new custom activity type is introduced upstream.
    --    CUSTOM_ACTIVITY_OUTCOME (the leading numeric code, e.g. '1' out of
    --    '1. Strategy Call Scheduled') is parsed out of that same string
    --    since the source no longer ships a separate outcome_id -- the
    --    outcome text itself is the only identifier Close provides.
    -- =========================================================================
    MERGE INTO SILVER.LEADS_ACTIVITIES_SUMMARY tgt
    USING (
        SELECT
            p.ACTIVITY_ID, p.LEAD_ID, p.CONTACT_ID, p.USER_ID, p.TYPE, p.TEXT, p.CREATED_BY_NAME, p.UPDATED_BY_NAME, p.ATTENDEES,
            p.CUSTOM_ACTIVITY_TYPE_ID, p.MEETING_STARTS_AT, p.MEETING_END_AT, p.MEETING_STATUS, p.ACTIVITY_AT, p.DATE_CREATED, p.DATE_UPDATED,
            p.CREATED_BY_USER, p.UPDATED_BY_USER,
            w.WRAPPED_ACTIVITIES,
            ct.CUSTOM_ACTIVITY_TYPE_NAME       AS CUSTOM_ACTIVITY,
            CASE p.CUSTOM_ACTIVITY_TYPE_ID
                WHEN '100' THEN w.WRAPPED_ACTIVITIES:"Triage Call Outcome"::STRING
                WHEN '200' THEN w.WRAPPED_ACTIVITIES:"Prospecting Call Outcome"::STRING
                WHEN '300' THEN w.WRAPPED_ACTIVITIES:"Strategy Call Outcome"::STRING
                WHEN '400' THEN w.WRAPPED_ACTIVITIES:"Sales Outcome"::STRING
            END                                  AS CUSTOM_ACTIVITY_OUTCOME_NAME,
            REGEXP_SUBSTR(
                CASE p.CUSTOM_ACTIVITY_TYPE_ID
                    WHEN '100' THEN w.WRAPPED_ACTIVITIES:"Triage Call Outcome"::STRING
                    WHEN '200' THEN w.WRAPPED_ACTIVITIES:"Prospecting Call Outcome"::STRING
                    WHEN '300' THEN w.WRAPPED_ACTIVITIES:"Strategy Call Outcome"::STRING
                    WHEN '400' THEN w.WRAPPED_ACTIVITIES:"Sales Outcome"::STRING
                END, '^[0-9]+')                  AS CUSTOM_ACTIVITY_OUTCOME,
            TRIM(COALESCE(u.FIRST_NAME,'') || ' ' || COALESCE(u.LAST_NAME,'')) AS DEA_INTERNAL_NAME,
            u.EMAIL                              AS DEA_INTERNAL_EMAIL
        FROM SILVER.LEAD_ACTIVITIES_PROCESSED p
        JOIN SILVER.LEAD_ACTIVITIES_PROCESSED_TRANSIENT t ON t.JSON_OBJECT:id::STRING = p.ACTIVITY_ID
        LEFT JOIN SILVER.CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS w ON w.LEAD_ID = p.LEAD_ID AND w.ACTIVITY_ID = p.ACTIVITY_ID
        LEFT JOIN SILVER.CUSTOM_ACTIVITY_TYPES ct ON ct.CUSTOM_ACTIVITY_TYPE_ID = p.CUSTOM_ACTIVITY_TYPE_ID
        LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED u ON u.USER_ID = p.USER_ID
    ) src
    ON tgt.ACTIVITY_ID = src.ACTIVITY_ID
    WHEN MATCHED THEN UPDATE SET
        LEAD_ID = src.LEAD_ID, CONTACT_ID = src.CONTACT_ID, USER_ID = src.USER_ID, TYPE = src.TYPE, TEXT = src.TEXT,
        CREATED_BY_NAME = src.CREATED_BY_NAME, UPDATED_BY_NAME = src.UPDATED_BY_NAME, ATTENDEES = src.ATTENDEES,
        CUSTOM_ACTIVITY_TYPE_ID = src.CUSTOM_ACTIVITY_TYPE_ID, MEETING_STARTS_AT = src.MEETING_STARTS_AT, MEETING_END_AT = src.MEETING_END_AT,
        MEETING_STATUS = src.MEETING_STATUS, ACTIVITY_AT = src.ACTIVITY_AT, DATE_CREATED = src.DATE_CREATED, DATE_UPDATED = src.DATE_UPDATED,
        CREATED_BY_USER = src.CREATED_BY_USER, UPDATED_BY_USER = src.UPDATED_BY_USER, UPDATE_DATE = CURRENT_TIMESTAMP(),
        WRAPPED_ACTIVITIES = src.WRAPPED_ACTIVITIES, CUSTOM_ACTIVITY = src.CUSTOM_ACTIVITY,
        CUSTOM_ACTIVITY_OUTCOME_NAME = src.CUSTOM_ACTIVITY_OUTCOME_NAME, CUSTOM_ACTIVITY_OUTCOME = src.CUSTOM_ACTIVITY_OUTCOME,
        DEA_INTERNAL_NAME = src.DEA_INTERNAL_NAME, DEA_INTERNAL_EMAIL = src.DEA_INTERNAL_EMAIL
    WHEN NOT MATCHED THEN INSERT (
        ACTIVITY_ID, LEAD_ID, CONTACT_ID, USER_ID, TYPE, TEXT, CREATED_BY_NAME, UPDATED_BY_NAME, ATTENDEES,
        CUSTOM_ACTIVITY_TYPE_ID, MEETING_STARTS_AT, MEETING_END_AT, MEETING_STATUS, ACTIVITY_AT, DATE_CREATED, DATE_UPDATED,
        CREATED_BY_USER, UPDATED_BY_USER, INSERT_DATE, UPDATE_DATE, WRAPPED_ACTIVITIES, CUSTOM_ACTIVITY,
        CUSTOM_ACTIVITY_OUTCOME_NAME, CUSTOM_ACTIVITY_OUTCOME, DEA_INTERNAL_NAME, DEA_INTERNAL_EMAIL
    ) VALUES (
        src.ACTIVITY_ID, src.LEAD_ID, src.CONTACT_ID, src.USER_ID, src.TYPE, src.TEXT, src.CREATED_BY_NAME, src.UPDATED_BY_NAME, src.ATTENDEES,
        src.CUSTOM_ACTIVITY_TYPE_ID, src.MEETING_STARTS_AT, src.MEETING_END_AT, src.MEETING_STATUS, src.ACTIVITY_AT, src.DATE_CREATED, src.DATE_UPDATED,
        src.CREATED_BY_USER, src.UPDATED_BY_USER, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), src.WRAPPED_ACTIVITIES, src.CUSTOM_ACTIVITY,
        src.CUSTOM_ACTIVITY_OUTCOME_NAME, src.CUSTOM_ACTIVITY_OUTCOME, src.DEA_INTERNAL_NAME, src.DEA_INTERNAL_EMAIL
    );

    RETURN 'Silver merge complete for ' || TO_VARCHAR(:LOAD_DATE, 'YYYY-MM-DD');
END;
$$;

-- CALL SILVER.MERGE_SILVER_DAY('2026-08-03');
-- SELECT COUNT(*) FROM SILVER.LEADS_ACTIVITIES_SUMMARY;
