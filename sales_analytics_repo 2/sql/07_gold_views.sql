/* =============================================================================
   Sales Analytics Pipeline - Phase 3
   07_gold_views.sql

   The five Gold business-logic views (Phase 2 Sec. 5.1), implementing the
   funnel rules from Phase 1 Sec. 3 / Phase 2 Sec. 6.2 directly against
   SILVER.LEADS_ACTIVITIES_SUMMARY. Column lists match the provided Snowflake
   Data Architecture Model exactly.

   Custom activity type IDs (from the sample dictionary in
   00_generate_sample_data.py / SILVER.CUSTOM_ACTIVITY_TYPES): 100 = Triage
   Call, 200 = Prospecting Activity, 300 = Strategy Call, 400 = New Sale. A
   real source may use different IDs -- confirm against the live
   custom_activites_raw dictionary before pointing this at production data.

   REVISION: SETTER/CLOSER are now resolved primarily from
   WRAPPED_ACTIVITIES:"Setter" / "Closer" (the actual custom fields Close
   captures on each activity, confirmed via the explanation video), joined to
   SILVER.CLOSE_CRM_USERS_PROCESSED for name/email. The original join-back-to-
   booking-view logic is kept as a fallback for rows where that custom field
   wasn't captured, so nothing regresses if a historical record is missing it.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- 1. INBOUND_STRATEGIES_BOOKED
--    Inbound Initial Contact qualification (Phase 1 Sec. 3.1.1): a Triage
--    Call only counts as booking a Strategy Call when the outcome is
--    exactly '1. Strategy Call Scheduled'. Grain: 1 row per lead (latest
--    Triage Call).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.INBOUND_STRATEGIES_BOOKED AS
SELECT
    LEAD_ID,
    ACTIVITY_AT::DATE                                                     AS ACTIVITY_LOG_DATE,
    DEA_INTERNAL_EMAIL                                                    AS SETTER_CLOSER_EMAIL,
    DEA_INTERNAL_NAME                                                     AS SETTER_CLOSER_NAME,
    CUSTOM_ACTIVITY_OUTCOME_NAME                                          AS TRIAGE_CALL_OUTCOME,
    ACTIVITY_AT                                                            AS TRIAGE_CALL_DATE,
    IFF(CUSTOM_ACTIVITY_OUTCOME_NAME = '1. Strategy Call Scheduled', TRUE, FALSE) AS STRATEGY_CALL_BOOKED,
    TO_VARCHAR(ACTIVITY_AT, 'YYYY') || '-W' || LPAD(WEEKOFYEAR(ACTIVITY_AT), 2, '0') AS SC_YEAR_WEEK
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
WHERE TYPE = 'CustomActivity' AND CUSTOM_ACTIVITY_TYPE_ID = '100'
QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY ACTIVITY_AT DESC) = 1;

-- ---------------------------------------------------------------------------
-- 2. OUTBOUND_STRATEGIES_BOOKED
--    Outbound Initial Contact qualification (Phase 1 Sec. 3.1.2): a
--    prospecting/outbound call counts as booking a Strategy Call when the
--    outcome is exactly '2. Strategy Call Scheduled'. Grain: 1 row per lead.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.OUTBOUND_STRATEGIES_BOOKED AS
SELECT
    LEAD_ID,
    ACTIVITY_AT::DATE                                                     AS ACTIVITY_LOG_DATE,
    DEA_INTERNAL_EMAIL                                                    AS SETTER_CLOSER_EMAIL,
    DEA_INTERNAL_NAME                                                     AS SETTER_CLOSER_NAME,
    ACTIVITY_AT                                                            AS PROSPECT_CALL_DATE,
    IFF(CUSTOM_ACTIVITY_OUTCOME_NAME = '2. Strategy Call Scheduled', TRUE, FALSE) AS STRATEGY_CALL_BOOKED,
    TO_VARCHAR(ACTIVITY_AT, 'YYYY') || '-W' || LPAD(WEEKOFYEAR(ACTIVITY_AT), 2, '0') AS SC_YEAR_WEEK
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
WHERE TYPE = 'CustomActivity' AND CUSTOM_ACTIVITY_TYPE_ID = '200'
QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY ACTIVITY_AT DESC) = 1;

-- ---------------------------------------------------------------------------
-- 3. OUTBOUND_PROSPECT_DIALS
--    Top-of-funnel raw dial volume: every prospecting/outbound dial,
--    regardless of outcome (Lead G "dial only" case, Phase 1 Sec. 3.6).
--    Grain: 1 row per dial activity.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.OUTBOUND_PROSPECT_DIALS AS
SELECT
    LEAD_ID,
    ACTIVITY_AT::DATE                                                     AS ACTIVITY_LOG_DATE,
    TO_VARCHAR(ACTIVITY_AT, 'YYYY') || '-W' || LPAD(WEEKOFYEAR(ACTIVITY_AT), 2, '0') AS PROSPECT_YEAR_WEEK,
    CUSTOM_ACTIVITY                                                       AS CUSTOM_ACTIVITY,
    CUSTOM_ACTIVITY_OUTCOME_NAME                                          AS STATUS,
    CUSTOM_ACTIVITY_OUTCOME_NAME                                          AS CUSTOM_ACTIVITY_OUTCOME_NAME,
    CUSTOM_ACTIVITY_OUTCOME                                               AS CUSTOM_ACTIVITY_OUTCOME,
    DEA_INTERNAL_EMAIL                                                    AS SETTER_CLOSER_EMAIL,
    DEA_INTERNAL_NAME                                                     AS SETTER_CLOSER_NAME
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
WHERE TYPE = 'CustomActivity' AND CUSTOM_ACTIVITY_TYPE_ID = '200';

-- ---------------------------------------------------------------------------
-- 4. ALL_STRATEGIES_DETAILS
--    Strategy Call Taken / Show logic (Phase 1 Sec. 3.2.2) and Offer
--    detection (Sec. 3.3).
--
--    SETTER/CLOSER resolution (revised): Close actually captures "Setter"
--    and "Closer" as custom fields directly on the Strategy Call activity
--    (confirmed via the explanation video), so those are now the primary
--    source -- resolved to name/email via CLOSE_CRM_USERS_PROCESSED. The
--    original look-back to whichever booking view has this lead is kept as
--    a fallback for SETTER only, for rows where that custom field is blank.
--    Grain: 1 row per Strategy Call activity.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.ALL_STRATEGIES_DETAILS AS
SELECT
    s.LEAD_ID,
    s.ACTIVITY_AT::DATE                                                   AS ACTIVITY_LOG_DATE,
    s.CUSTOM_ACTIVITY                                                     AS CUSTOM_ACTIVITY,
    CASE
        WHEN s.CUSTOM_ACTIVITY_OUTCOME_NAME IN
             ('4. No Show', '3. Cancel- Not Interested', '2. Admin Cancel',
              '7. Cancel- Nurture', '3. No Show', '8. Cancel- Nurture')
            THEN 'No Show / Cancelled'
        WHEN s.CUSTOM_ACTIVITY_OUTCOME_NAME IN ('1. Follow Up', '5. Sale', '6. Sale', '7. Lost')
            THEN 'Show'
        ELSE 'Unknown'
    END                                                                   AS STATUS,
    COALESCE(closer_u.EMAIL, s.DEA_INTERNAL_EMAIL)                        AS CLOSER_EMAIL,
    COALESCE(TRIM(closer_u.FIRST_NAME || ' ' || closer_u.LAST_NAME), s.DEA_INTERNAL_NAME) AS CLOSER_NAME,
    s.CUSTOM_ACTIVITY_OUTCOME_NAME                                        AS STRATEGY_CALL_OUTCOME,
    s.ACTIVITY_AT                                                          AS DATE_OF_STRATEGY_CALL,
    CASE
        WHEN s.WRAPPED_ACTIVITIES:"Offer Presented"::STRING = 'Yes' THEN 'Yes'
        WHEN CONTAINS(LOWER(COALESCE(s.CUSTOM_ACTIVITY_OUTCOME_NAME, '')), 'offer') THEN 'Yes'
        ELSE 'No'
    END                                                                   AS OFFER_PRESENTED,
    COALESCE(setter_u.EMAIL, ib.SETTER_CLOSER_EMAIL, ob.SETTER_CLOSER_EMAIL)              AS SETTER,
    COALESCE(TRIM(setter_u.FIRST_NAME || ' ' || setter_u.LAST_NAME), ib.SETTER_CLOSER_NAME, ob.SETTER_CLOSER_NAME) AS SETTER_NAME
FROM SILVER.LEADS_ACTIVITIES_SUMMARY s
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED setter_u ON setter_u.USER_ID = s.WRAPPED_ACTIVITIES:"Setter"::STRING
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED closer_u ON closer_u.USER_ID = s.WRAPPED_ACTIVITIES:"Closer"::STRING
LEFT JOIN GOLD.INBOUND_STRATEGIES_BOOKED ib ON ib.LEAD_ID = s.LEAD_ID AND ib.STRATEGY_CALL_BOOKED
LEFT JOIN GOLD.OUTBOUND_STRATEGIES_BOOKED ob ON ob.LEAD_ID = s.LEAD_ID AND ob.STRATEGY_CALL_BOOKED
WHERE s.TYPE = 'CustomActivity' AND s.CUSTOM_ACTIVITY_TYPE_ID = '300';

-- ---------------------------------------------------------------------------
-- 5. SALES_DETAILS
--    Sale Qualification Rules (Phase 1 Sec. 3.4.1): a sale is only valid
--    when the lead has an attended ("Show") Strategy Call on record.
--    SETTER/CLOSER resolved primarily from the New Sale activity's own
--    "Setter"/"Closer" custom fields (mirrors ALL_STRATEGIES_DETAILS),
--    falling back to the matched Strategy Call's SETTER/closer if the Sale
--    activity itself didn't capture them. Grain: 1 row per New Sale activity.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.SALES_DETAILS AS
SELECT
    s.LEAD_ID,
    s.ACTIVITY_AT,
    s.CUSTOM_ACTIVITY_OUTCOME_NAME                                        AS SALE_STATUS,
    COALESCE(setter_u.EMAIL, asd.SETTER)                                   AS SETTER_EMAIL,
    COALESCE(TRIM(setter_u.FIRST_NAME || ' ' || setter_u.LAST_NAME), asd.SETTER_NAME) AS SETTER_NAME,
    COALESCE(closer_u.EMAIL, s.DEA_INTERNAL_EMAIL)                         AS CLOSER_EMAIL,
    COALESCE(TRIM(closer_u.FIRST_NAME || ' ' || closer_u.LAST_NAME), s.DEA_INTERNAL_NAME) AS CLOSER_NAME,
    TRY_CAST(s.WRAPPED_ACTIVITIES:"Contract Value"::STRING AS NUMBER(12,2)) AS CONTRACTED_VALUE,
    s.ACTIVITY_AT::DATE                                                    AS DATE_OF_SALE,
    s.WRAPPED_ACTIVITIES:"Program"::STRING                                 AS PROGRAM,
    TRY_CAST(s.WRAPPED_ACTIVITIES:"Cash Collected"::STRING AS NUMBER(12,2)) AS CASH_COLLECTED
FROM SILVER.LEADS_ACTIVITIES_SUMMARY s
JOIN GOLD.ALL_STRATEGIES_DETAILS asd ON asd.LEAD_ID = s.LEAD_ID AND asd.STATUS = 'Show'
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED setter_u ON setter_u.USER_ID = s.WRAPPED_ACTIVITIES:"Setter"::STRING
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED closer_u ON closer_u.USER_ID = s.WRAPPED_ACTIVITIES:"Closer"::STRING
WHERE s.TYPE = 'CustomActivity' AND s.CUSTOM_ACTIVITY_TYPE_ID = '400';

/* -----------------------------------------------------------------------------
   Spot checks -- run after 06_silver_merge_dedup.sql has processed all 7
   simulated days.
   -----------------------------------------------------------------------------
SELECT * FROM GOLD.INBOUND_STRATEGIES_BOOKED ORDER BY LEAD_ID;
SELECT * FROM GOLD.OUTBOUND_STRATEGIES_BOOKED ORDER BY LEAD_ID;
SELECT * FROM GOLD.OUTBOUND_PROSPECT_DIALS ORDER BY LEAD_ID;
SELECT * FROM GOLD.ALL_STRATEGIES_DETAILS ORDER BY LEAD_ID;
SELECT * FROM GOLD.SALES_DETAILS ORDER BY LEAD_ID;
-- Expect: lead_A and lead_D in SALES_DETAILS; lead_C and lead_F in
-- ALL_STRATEGIES_DETAILS with STATUS='Show' but no matching SALES_DETAILS row;
-- lead_B, lead_E not in ALL_STRATEGIES_DETAILS at all (E is a No Show, not absent --
-- check it appears with STATUS='No Show / Cancelled'); lead_G only in
-- OUTBOUND_PROSPECT_DIALS.
----------------------------------------------------------------------------- */
