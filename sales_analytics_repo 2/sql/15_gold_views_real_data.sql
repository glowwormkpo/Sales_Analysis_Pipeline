/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data)
   15_gold_views_real_data.sql

   Rebuilds the 5 Gold views (CREATE OR REPLACE -- supersedes the Phase 3
   definitions in sql/07_gold_views.sql in place) against the real
   custom_activites_raw type IDs and outcome taxonomy, confirmed against
   actual Bronze/Silver data before writing this rather than guessing:

   Real type ID -> funnel stage mapping (Phase 3 used synthetic IDs
   100/200/300/400; real Close CRM IDs are opaque per-org strings):
     Inbound / Triage   : actitype_38341SWOKRkRHHAqWEqSJu (Triage Call)
                           actitype_1zimBrwAdOLmRLK0Ncg6Lb (Triage Call Follow Up)
     Outbound/Prospecting: actitype_4tEv1xumZEk9vYYs7WxYy7 (Prospecting Activity)
                           actitype_6ga7msjJ7kZcH2rGtYETwe (Prospecting Follow Up)
     Strategy Call       : actitype_2VcSfZQX6FeIL8kkxy48C2 (Strategy Call)
                           actitype_6IrDujYE2WKg9QCFJdpXJk (Strategy Call Follow Up)
     New Sale            : actitype_3E85vFq3a06LlEzXT2N1kS (New Sale)
                           ("New Sale [Custom Payment Plan]" also exists as its
                           own type in the real dictionary but isn't folded in
                           here -- not modeled, revisit if it turns out to
                           carry real sale volume)

   Follow Up types (confirmed via user decision) roll into the same funnel
   stage as their parent type -- they use the same outcome field
   semantically (though not always the same literal field name -- e.g.
   Strategy Call uses "Strategy Call Outcome" but Strategy Call Follow Up
   uses "Follow Up Call Outcome"; both get resolved into
   CUSTOM_ACTIVITY_OUTCOME_NAME already via the dynamic field-name join in
   13_silver_customactivity_email_load.sql, so no extra handling needed here
   beyond including both type IDs in the WHERE clause).

   Outcome text taxonomy was confirmed against real distinct values (see
   conversation) -- the wording turned out to closely match what Phase 3
   assumed for Triage/Prospecting/Strategy booking checks ('1. Strategy Call
   Scheduled', '2. Strategy Call Scheduled', '6. Sale' all appear verbatim),
   but Strategy Call Follow Up uses different exact wording than Strategy
   Call itself (e.g. '3. No Show' vs '4. No Show'), so both are enumerated
   explicitly below rather than assumed identical.

   ASSUMPTION (flagged, not confirmed with user): 'Reschedule' outcomes on
   Strategy Call / Strategy Call Follow Up are classified as No Show /
   Cancelled, on the reasoning that a rescheduled call hasn't actually been
   held yet. Revisit if that's not the right call.

   New Sale has no "*Outcome*" field at all (confirmed against the real
   field dictionary) -- SALE_STATUS is now sourced from the "Contract
   Signed" custom field (Yes/No, confirmed present) instead of
   CUSTOM_ACTIVITY_OUTCOME_NAME, which is NULL for this type.

   Setter/Closer/Contract Value/Program/Cash Collected/Offer Presented field
   names were all confirmed to exist verbatim on the real Strategy Call / New
   Sale types, so that resolution logic is unchanged from Phase 3.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- 1. INBOUND_STRATEGIES_BOOKED
--    Grain: 1 row per lead (latest Triage Call or Triage Call Follow Up).
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
WHERE TYPE = 'CustomActivity'
  AND CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_38341SWOKRkRHHAqWEqSJu', 'actitype_1zimBrwAdOLmRLK0Ncg6Lb')
QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY ACTIVITY_AT DESC) = 1;

-- ---------------------------------------------------------------------------
-- 2. OUTBOUND_STRATEGIES_BOOKED
--    Grain: 1 row per lead (latest Prospecting Activity or Follow Up).
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
WHERE TYPE = 'CustomActivity'
  AND CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_4tEv1xumZEk9vYYs7WxYy7', 'actitype_6ga7msjJ7kZcH2rGtYETwe')
QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY ACTIVITY_AT DESC) = 1;

-- ---------------------------------------------------------------------------
-- 3. OUTBOUND_PROSPECT_DIALS
--    Grain: 1 row per dial activity (Prospecting Activity + Follow Up).
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
WHERE TYPE = 'CustomActivity'
  AND CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_4tEv1xumZEk9vYYs7WxYy7', 'actitype_6ga7msjJ7kZcH2rGtYETwe');

-- ---------------------------------------------------------------------------
-- 4. ALL_STRATEGIES_DETAILS
--    Grain: 1 row per Strategy Call / Strategy Call Follow Up activity.
--    STATUS taxonomy enumerated explicitly per type since the two types use
--    different literal outcome wording (see header note).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.ALL_STRATEGIES_DETAILS AS
SELECT
    s.LEAD_ID,
    s.ACTIVITY_AT::DATE                                                   AS ACTIVITY_LOG_DATE,
    s.CUSTOM_ACTIVITY                                                     AS CUSTOM_ACTIVITY,
    CASE
        -- Strategy Call (actitype_2VcSfZQX6FeIL8kkxy48C2)
        WHEN s.CUSTOM_ACTIVITY_TYPE_ID = 'actitype_2VcSfZQX6FeIL8kkxy48C2' AND s.CUSTOM_ACTIVITY_OUTCOME_NAME IN
             ('4. No Show', '3. Cancel- Not Interested', '2. Admin Cancel', '8. Cancel- Nurture', '5. Reschedule')
            THEN 'No Show / Cancelled'
        WHEN s.CUSTOM_ACTIVITY_TYPE_ID = 'actitype_2VcSfZQX6FeIL8kkxy48C2' AND s.CUSTOM_ACTIVITY_OUTCOME_NAME IN
             ('1. Follow Up', '6. Sale', '7. Lost')
            THEN 'Show'
        -- Strategy Call Follow Up (actitype_6IrDujYE2WKg9QCFJdpXJk)
        WHEN s.CUSTOM_ACTIVITY_TYPE_ID = 'actitype_6IrDujYE2WKg9QCFJdpXJk' AND s.CUSTOM_ACTIVITY_OUTCOME_NAME IN
             ('3. No Show', '2. Cancel- No Longer Interested', '4. Reschedule', '7. Cancel- Nurture')
            THEN 'No Show / Cancelled'
        WHEN s.CUSTOM_ACTIVITY_TYPE_ID = 'actitype_6IrDujYE2WKg9QCFJdpXJk' AND s.CUSTOM_ACTIVITY_OUTCOME_NAME IN
             ('1. Follow Up', '5. Sale', '6. Lost')
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
WHERE s.TYPE = 'CustomActivity'
  AND s.CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_2VcSfZQX6FeIL8kkxy48C2', 'actitype_6IrDujYE2WKg9QCFJdpXJk');

-- ---------------------------------------------------------------------------
-- 5. SALES_DETAILS
--    Grain: 1 row per New Sale activity. SALE_STATUS now sourced from the
--    "Contract Signed" field (New Sale has no Outcome-named field at all).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.SALES_DETAILS AS
WITH latest_show_strategy AS (
    -- Rolling Follow Up types into ALL_STRATEGIES_DETAILS means a lead can
    -- have more than one 'Show' row (e.g. Strategy Call + its Follow Up).
    -- Dedup to one qualifying row per lead here so the join below can't
    -- fan out and duplicate New Sale rows.
    SELECT LEAD_ID, SETTER, SETTER_NAME
    FROM GOLD.ALL_STRATEGIES_DETAILS
    WHERE STATUS = 'Show'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY DATE_OF_STRATEGY_CALL DESC) = 1
)
SELECT
    s.LEAD_ID,
    s.ACTIVITY_AT,
    s.WRAPPED_ACTIVITIES:"Contract Signed"::STRING                        AS SALE_STATUS,
    COALESCE(setter_u.EMAIL, asd.SETTER)                                   AS SETTER_EMAIL,
    COALESCE(TRIM(setter_u.FIRST_NAME || ' ' || setter_u.LAST_NAME), asd.SETTER_NAME) AS SETTER_NAME,
    COALESCE(closer_u.EMAIL, s.DEA_INTERNAL_EMAIL)                         AS CLOSER_EMAIL,
    COALESCE(TRIM(closer_u.FIRST_NAME || ' ' || closer_u.LAST_NAME), s.DEA_INTERNAL_NAME) AS CLOSER_NAME,
    TRY_CAST(s.WRAPPED_ACTIVITIES:"Contract Value"::STRING AS NUMBER(12,2)) AS CONTRACTED_VALUE,
    s.ACTIVITY_AT::DATE                                                    AS DATE_OF_SALE,
    s.WRAPPED_ACTIVITIES:"Program"::STRING                                 AS PROGRAM,
    TRY_CAST(s.WRAPPED_ACTIVITIES:"Cash Collected"::STRING AS NUMBER(12,2)) AS CASH_COLLECTED
FROM SILVER.LEADS_ACTIVITIES_SUMMARY s
JOIN latest_show_strategy asd ON asd.LEAD_ID = s.LEAD_ID
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED setter_u ON setter_u.USER_ID = s.WRAPPED_ACTIVITIES:"Setter"::STRING
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED closer_u ON closer_u.USER_ID = s.WRAPPED_ACTIVITIES:"Closer"::STRING
WHERE s.TYPE = 'CustomActivity'
  AND s.CUSTOM_ACTIVITY_TYPE_ID = 'actitype_3E85vFq3a06LlEzXT2N1kS';

-- ---------------------------------------------------------------------------
-- Sanity checks
-- ---------------------------------------------------------------------------
SELECT 'INBOUND_STRATEGIES_BOOKED' AS v, COUNT(*) AS n, SUM(IFF(STRATEGY_CALL_BOOKED,1,0)) AS booked FROM GOLD.INBOUND_STRATEGIES_BOOKED
UNION ALL SELECT 'OUTBOUND_STRATEGIES_BOOKED', COUNT(*), SUM(IFF(STRATEGY_CALL_BOOKED,1,0)) FROM GOLD.OUTBOUND_STRATEGIES_BOOKED
UNION ALL SELECT 'OUTBOUND_PROSPECT_DIALS', COUNT(*), NULL FROM GOLD.OUTBOUND_PROSPECT_DIALS
UNION ALL SELECT 'ALL_STRATEGIES_DETAILS (Show)', COUNT(*), NULL FROM GOLD.ALL_STRATEGIES_DETAILS WHERE STATUS = 'Show'
UNION ALL SELECT 'ALL_STRATEGIES_DETAILS (No Show/Cancelled)', COUNT(*), NULL FROM GOLD.ALL_STRATEGIES_DETAILS WHERE STATUS = 'No Show / Cancelled'
UNION ALL SELECT 'ALL_STRATEGIES_DETAILS (Unknown)', COUNT(*), NULL FROM GOLD.ALL_STRATEGIES_DETAILS WHERE STATUS = 'Unknown'
UNION ALL SELECT 'SALES_DETAILS', COUNT(*), NULL FROM GOLD.SALES_DETAILS
UNION ALL SELECT 'SALES_DETAILS (Contract Signed = Yes)', COUNT(*), NULL FROM GOLD.SALES_DETAILS WHERE SALE_STATUS = 'Yes';
