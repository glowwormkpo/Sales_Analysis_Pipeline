/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data) - Reviewer-Flagged Fix
   32_label_unattributed.sql

   Confirmed via diagnostics (files 26/28/29/30): setter/closer attribution
   is genuinely incomplete in the source data -- roughly 55-60% of Strategy
   Call activity and ~90% of raw Outbound dial activity has no resolvable
   setter or closer, mainly because the "Setter"/"Closer" custom fields
   aren't always filled in by reps, and the fallback (the activity's raw CRM
   owner user_id) often doesn't match CLOSE_CRM_USERS_PROCESSED -- most
   plausibly because that roster reflects currently active staff only, and
   activity data goes back further than some reps' tenure.

   This isn't fixable from within the pipeline (the data genuinely isn't
   there), so per Jerry's decision, unresolved setter/closer values are now
   labeled 'Unattributed' instead of showing up as a blank name -- so
   reviewers see a real, quantified category instead of what looks like a
   broken row.

   Chosen approach: label at the four upstream Gold views that resolve
   identity (INBOUND_STRATEGIES_BOOKED, OUTBOUND_STRATEGIES_BOOKED,
   OUTBOUND_PROSPECT_DIALS, ALL_STRATEGIES_DETAILS) plus SALES_DETAILS and
   RPT_OBJECTIONS_FACED (which resolves CLOSER_NAME independently, straight
   off Silver). Every RPT_* export view reads from these without further
   transformation, so the label cascades through to all four reports
   automatically -- no changes needed to 08_export_unload.sql, 16, 19, or 22.

   Care taken in ALL_STRATEGIES_DETAILS and SALES_DETAILS: since
   INBOUND_STRATEGIES_BOOKED / OUTBOUND_STRATEGIES_BOOKED / ALL_STRATEGIES_
   DETAILS now emit the literal string 'Unattributed' instead of NULL when
   unresolved, any COALESCE chain built on top of them wraps each fallback
   source in NULLIF(x, 'Unattributed') first -- otherwise COALESCE would stop
   at the first non-null value (which could just be the sentinel string) and
   never check a later source that might actually have a real answer.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- 1. INBOUND_STRATEGIES_BOOKED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.INBOUND_STRATEGIES_BOOKED AS
SELECT
    LEAD_ID,
    ACTIVITY_AT::DATE                                                     AS ACTIVITY_LOG_DATE,
    COALESCE(NULLIF(TRIM(DEA_INTERNAL_EMAIL), ''), 'Unattributed')        AS SETTER_CLOSER_EMAIL,
    COALESCE(NULLIF(TRIM(DEA_INTERNAL_NAME), ''), 'Unattributed')         AS SETTER_CLOSER_NAME,
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
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.OUTBOUND_STRATEGIES_BOOKED AS
SELECT
    LEAD_ID,
    ACTIVITY_AT::DATE                                                     AS ACTIVITY_LOG_DATE,
    COALESCE(NULLIF(TRIM(DEA_INTERNAL_EMAIL), ''), 'Unattributed')        AS SETTER_CLOSER_EMAIL,
    COALESCE(NULLIF(TRIM(DEA_INTERNAL_NAME), ''), 'Unattributed')         AS SETTER_CLOSER_NAME,
    ACTIVITY_AT                                                            AS PROSPECT_CALL_DATE,
    IFF(CUSTOM_ACTIVITY_OUTCOME_NAME = '2. Strategy Call Scheduled', TRUE, FALSE) AS STRATEGY_CALL_BOOKED,
    TO_VARCHAR(ACTIVITY_AT, 'YYYY') || '-W' || LPAD(WEEKOFYEAR(ACTIVITY_AT), 2, '0') AS SC_YEAR_WEEK
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
WHERE TYPE = 'CustomActivity'
  AND CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_4tEv1xumZEk9vYYs7WxYy7', 'actitype_6ga7msjJ7kZcH2rGtYETwe')
QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY ACTIVITY_AT DESC) = 1;

-- ---------------------------------------------------------------------------
-- 3. OUTBOUND_PROSPECT_DIALS
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
    COALESCE(NULLIF(TRIM(DEA_INTERNAL_EMAIL), ''), 'Unattributed')        AS SETTER_CLOSER_EMAIL,
    COALESCE(NULLIF(TRIM(DEA_INTERNAL_NAME), ''), 'Unattributed')         AS SETTER_CLOSER_NAME
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
WHERE TYPE = 'CustomActivity'
  AND CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_4tEv1xumZEk9vYYs7WxYy7', 'actitype_6ga7msjJ7kZcH2rGtYETwe');

-- ---------------------------------------------------------------------------
-- 4. ALL_STRATEGIES_DETAILS
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
    COALESCE(closer_u.EMAIL, s.DEA_INTERNAL_EMAIL, 'Unattributed')       AS CLOSER_EMAIL,
    COALESCE(
        NULLIF(TRIM(closer_u.FIRST_NAME || ' ' || closer_u.LAST_NAME), ''),
        NULLIF(s.DEA_INTERNAL_NAME, ''),
        'Unattributed'
    )                                                                     AS CLOSER_NAME,
    s.CUSTOM_ACTIVITY_OUTCOME_NAME                                        AS STRATEGY_CALL_OUTCOME,
    s.ACTIVITY_AT                                                          AS DATE_OF_STRATEGY_CALL,
    CASE
        WHEN s.WRAPPED_ACTIVITIES:"Offer Presented"::STRING = 'Yes' THEN 'Yes'
        WHEN CONTAINS(LOWER(COALESCE(s.CUSTOM_ACTIVITY_OUTCOME_NAME, '')), 'offer') THEN 'Yes'
        ELSE 'No'
    END                                                                   AS OFFER_PRESENTED,
    COALESCE(
        setter_u.EMAIL,
        NULLIF(ib.SETTER_CLOSER_EMAIL, 'Unattributed'),
        NULLIF(ob.SETTER_CLOSER_EMAIL, 'Unattributed'),
        'Unattributed'
    )                                                                     AS SETTER,
    COALESCE(
        NULLIF(TRIM(setter_u.FIRST_NAME || ' ' || setter_u.LAST_NAME), ''),
        NULLIF(ib.SETTER_CLOSER_NAME, 'Unattributed'),
        NULLIF(ob.SETTER_CLOSER_NAME, 'Unattributed'),
        'Unattributed'
    )                                                                     AS SETTER_NAME
FROM SILVER.LEADS_ACTIVITIES_SUMMARY s
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED setter_u ON setter_u.USER_ID = s.WRAPPED_ACTIVITIES:"Setter"::STRING
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED closer_u ON closer_u.USER_ID = s.WRAPPED_ACTIVITIES:"Closer"::STRING
LEFT JOIN GOLD.INBOUND_STRATEGIES_BOOKED ib ON ib.LEAD_ID = s.LEAD_ID AND ib.STRATEGY_CALL_BOOKED
LEFT JOIN GOLD.OUTBOUND_STRATEGIES_BOOKED ob ON ob.LEAD_ID = s.LEAD_ID AND ob.STRATEGY_CALL_BOOKED
WHERE s.TYPE = 'CustomActivity'
  AND s.CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_2VcSfZQX6FeIL8kkxy48C2', 'actitype_6IrDujYE2WKg9QCFJdpXJk');

-- ---------------------------------------------------------------------------
-- 5. SALES_DETAILS (base: 23_sales_details_custom_payment_plan.sql)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.SALES_DETAILS AS
WITH latest_show_strategy AS (
    SELECT LEAD_ID, SETTER, SETTER_NAME
    FROM GOLD.ALL_STRATEGIES_DETAILS
    WHERE STATUS = 'Show'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY DATE_OF_STRATEGY_CALL DESC) = 1
)
SELECT
    s.LEAD_ID,
    s.ACTIVITY_AT,
    COALESCE(s.WRAPPED_ACTIVITIES:"Contract Signed"::STRING, 'Yes')          AS SALE_STATUS,
    COALESCE(setter_u.EMAIL, NULLIF(asd.SETTER, 'Unattributed'), 'Unattributed') AS SETTER_EMAIL,
    COALESCE(
        NULLIF(TRIM(setter_u.FIRST_NAME || ' ' || setter_u.LAST_NAME), ''),
        NULLIF(asd.SETTER_NAME, 'Unattributed'),
        'Unattributed'
    )                                                                        AS SETTER_NAME,
    COALESCE(closer_u.EMAIL, s.DEA_INTERNAL_EMAIL, 'Unattributed')           AS CLOSER_EMAIL,
    COALESCE(
        NULLIF(TRIM(closer_u.FIRST_NAME || ' ' || closer_u.LAST_NAME), ''),
        NULLIF(s.DEA_INTERNAL_NAME, ''),
        'Unattributed'
    )                                                                        AS CLOSER_NAME,
    TRY_CAST(s.WRAPPED_ACTIVITIES:"Contract Value"::STRING AS NUMBER(12,2))  AS CONTRACTED_VALUE,
    s.ACTIVITY_AT::DATE                                                      AS DATE_OF_SALE,
    s.WRAPPED_ACTIVITIES:"Program"::STRING                                   AS PROGRAM,
    COALESCE(
        TRY_CAST(s.WRAPPED_ACTIVITIES:"Cash Collected"::STRING AS NUMBER(12,2)),
        TRY_CAST(s.WRAPPED_ACTIVITIES:"Initial Payment"::STRING AS NUMBER(12,2))
    )                                                                        AS CASH_COLLECTED,
    s.CUSTOM_ACTIVITY                                                       AS SALE_ACTIVITY_TYPE
FROM SILVER.LEADS_ACTIVITIES_SUMMARY s
JOIN latest_show_strategy asd ON asd.LEAD_ID = s.LEAD_ID
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED setter_u ON setter_u.USER_ID = s.WRAPPED_ACTIVITIES:"Setter"::STRING
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED closer_u ON closer_u.USER_ID = s.WRAPPED_ACTIVITIES:"Closer"::STRING
WHERE s.TYPE = 'CustomActivity'
  AND s.CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_3E85vFq3a06LlEzXT2N1kS', 'actitype_0FNk72Q8eSYX2MVd4A2UFx');

-- ---------------------------------------------------------------------------
-- 6. RPT_OBJECTIONS_FACED -- only CLOSER_NAME changes (labeled), everything
--    else identical to 16_gold_reports_real_data.sql.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_OBJECTIONS_FACED AS
WITH sc AS (
    SELECT
        ACTIVITY_ID,
        COALESCE(NULLIF(DEA_INTERNAL_NAME, ''), 'Unattributed')  AS CLOSER_NAME,
        ACTIVITY_AT::DATE                                          AS ACTIVITY_DATE,
        WRAPPED_ACTIVITIES:"Objections Faced?"                     AS OBJECTIONS_ARRAY
    FROM SILVER.LEADS_ACTIVITIES_SUMMARY
    WHERE TYPE = 'CustomActivity'
      AND CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_2VcSfZQX6FeIL8kkxy48C2', 'actitype_6IrDujYE2WKg9QCFJdpXJk')
      AND CUSTOM_ACTIVITY_OUTCOME_NAME IN ('7. Lost', '6. Lost')
),
sc_flat AS (
    SELECT
        sc.ACTIVITY_ID, sc.CLOSER_NAME, sc.ACTIVITY_DATE,
        COALESCE(f.value::STRING, 'No Objections') AS OBJECTION
    FROM sc
    LEFT JOIN LATERAL FLATTEN(input => sc.OBJECTIONS_ARRAY, OUTER => TRUE) f
)
SELECT
    CLOSER_NAME,
    ACTIVITY_DATE,
    COUNT(DISTINCT ACTIVITY_ID)                            AS TOTAL_CALLS,
    COUNT_IF(OBJECTION = 'Money')                          AS MONEY_COUNT,
    COUNT_IF(OBJECTION = 'Fear')                           AS FEAR_COUNT,
    COUNT_IF(OBJECTION = 'Hung Up')                        AS HUNG_UP_COUNT,
    COUNT_IF(OBJECTION = 'Logistical')                     AS LOGISTICAL_COUNT,
    COUNT_IF(OBJECTION = 'No Objections')                  AS NO_OBJ_COUNT,
    COUNT_IF(OBJECTION = 'Talking to Other Coaches')        AS OTHER_COACHES_COUNT,
    COUNT_IF(OBJECTION = 'Partner')                          AS PARTNER_COUNT,
    COUNT_IF(OBJECTION = 'Think About It')                   AS THINK_ABT_IT_COUNT,
    COUNT_IF(OBJECTION = 'Time')                             AS TIME_COUNT,
    COUNT_IF(OBJECTION = 'Trust')                            AS TRUST_COUNT,
    COUNT_IF(OBJECTION = 'Value')                            AS VALUE_COUNT,
    COUNT_IF(OBJECTION = 'Wasn''t Looking For What We Offered') AS NOT_LOOKING_COUNT,
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Money'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)                          AS "Money%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Fear'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)                           AS "Fear%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Hung Up'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)                        AS "Hung Up%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Logistical'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)                     AS "Logistical%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'No Objections'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)                  AS "No Obj%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Talking to Other Coaches'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)        AS "Other Coaches%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Partner'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)                         AS "Partner%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Think About It'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)                  AS "Think Abt It%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Time'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)                            AS "Time%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Trust'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)                           AS "Trust%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Value'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2)                           AS "Value%",
    ROUND(DIV0(COUNT_IF(OBJECTION = 'Wasn''t Looking For What We Offered'), COUNT(DISTINCT ACTIVITY_ID)) * 100, 2) AS "Wsn't Lkng Fr Wht We Offrd%"
FROM sc_flat
GROUP BY CLOSER_NAME, ACTIVITY_DATE;

-- ---------------------------------------------------------------------------
-- Sanity checks: totals should be unchanged from before (this only relabels
-- blank/null identity fields, it doesn't add, drop, or duplicate any rows).
-- ---------------------------------------------------------------------------
SELECT 'SALES_DETAILS' AS v, COUNT(*) AS n FROM GOLD.SALES_DETAILS
UNION ALL SELECT 'ALL_STRATEGIES_DETAILS (Show)', COUNT(*) FROM GOLD.ALL_STRATEGIES_DETAILS WHERE STATUS = 'Show'
UNION ALL SELECT 'RPT_CLOSER total sales', SUM(SALE) FROM GOLD.RPT_CLOSER
UNION ALL SELECT 'RPT_CLOSER_DAILY total sales', SUM(SALE) FROM GOLD.RPT_CLOSER_DAILY;

-- Spot-check: how many rows now explicitly say 'Unattributed' vs a real name.
SELECT CLOSER_NAME, COUNT(*) FROM GOLD.ALL_STRATEGIES_DETAILS GROUP BY CLOSER_NAME ORDER BY 2 DESC LIMIT 10;
