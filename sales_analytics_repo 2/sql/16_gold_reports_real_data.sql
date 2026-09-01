/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data)
   16_gold_reports_real_data.sql

   Fixes the two GOLD.RPT_* export views that hardcoded synthetic-data
   literals (RPT_INBOUND_SETTER and RPT_OUTBOUND_SETTER don't hardcode any
   type IDs or outcome text -- they read from the already-fixed core Gold
   views, so they need no changes and aren't touched here).

   RPT_OBJECTIONS_FACED:
     - Reads directly from SILVER.LEADS_ACTIVITIES_SUMMARY (not from a Gold
       view), so it needs the real Strategy Call + Strategy Call Follow Up
       type IDs and the real per-type "Lost" outcome text ('7. Lost' for
       Strategy Call, '6. Lost' for Strategy Call Follow Up).
     - Real field name is "Objections Faced?" (with a question mark) --
       confirmed against real data, differs from the synthetic "Objections
       Faced". Confirmed it's still a genuine multi-select array (e.g.
       ["Money", "Wasn't Looking For What We Offered"]) already resolved
       correctly by the existing repair logic, so the LATERAL FLATTEN
       approach itself is unchanged -- only the field name/scope changed.
     - Real objection values line up with the existing 12 named buckets
       (Money, Fear, Logistical, Trust, Time, Think About It, Value,
       Partner, Talking to Other Coaches, Wasn't Looking For What We
       Offered, No Objections) with one exception: a real value of "No
       Show" was observed that doesn't map to any named bucket. It's not
       added as a new column (the report's column list matches the fixed
       data-model spec) -- it still counts toward TOTAL_CALLS, just not
       toward any specific named bucket. "Hung Up" has a named bucket but
       wasn't observed in the sample checked; left in place in case it
       shows up in the full dataset.

   RPT_CLOSER:
     - Reads from GOLD.ALL_STRATEGIES_DETAILS, which already includes both
       Strategy Call and Strategy Call Follow Up (per the Follow-Up rollup
       decision), so no type-ID scoping needed here -- just the outcome
       text buckets, since Follow Up uses different literal wording for the
       same semantic status in a couple of cases:
         CANCEL_NOT_INTEREST : Strategy Call = '3. Cancel- Not Interested'
                                Follow Up     = '2. Cancel- No Longer Interested'
         LOST                : Strategy Call = '7. Lost'
                                Follow Up     = '6. Lost'
       ADMIN_CANCEL, CANCEL_NURTURE, and NO_SHOW already happened to cover
       both types' wording (confirmed against the real distinct-value
       breakdown), so those are unchanged.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- Closer Report  ->  dea_closer_report/closer_report/
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_CLOSER AS
WITH calls AS (
    SELECT *, TO_VARCHAR(DATE_OF_STRATEGY_CALL, 'YYYY-MM') AS CALL_YEAR_MONTH
    FROM GOLD.ALL_STRATEGIES_DETAILS
),
sales_agg AS (
    SELECT CLOSER_NAME, TO_VARCHAR(DATE_OF_SALE, 'YYYY-MM') AS SALE_YEAR_MONTH,
           COUNT(*) AS SALE_COUNT, AVG(CONTRACTED_VALUE) AS AVG_VALUE, SUM(CASH_COLLECTED) AS CASH_COLLECTED
    FROM GOLD.SALES_DETAILS
    GROUP BY CLOSER_NAME, TO_VARCHAR(DATE_OF_SALE, 'YYYY-MM')
)
SELECT
    c.CLOSER_NAME,
    c.CALL_YEAR_MONTH,
    COUNT(*)                                                               AS CALL_BOOKED,
    COUNT_IF(c.STRATEGY_CALL_OUTCOME = '2. Admin Cancel')                  AS ADMIN_CANCEL,
    COUNT_IF(c.STRATEGY_CALL_OUTCOME IN ('7. Cancel- Nurture', '8. Cancel- Nurture')) AS CANCEL_NURTURE,
    COUNT_IF(c.STRATEGY_CALL_OUTCOME IN ('3. Cancel- Not Interested', '2. Cancel- No Longer Interested')) AS CANCEL_NOT_INTEREST,
    COUNT_IF(c.STRATEGY_CALL_OUTCOME IN
        ('2. Admin Cancel', '7. Cancel- Nurture', '8. Cancel- Nurture',
         '3. Cancel- Not Interested', '2. Cancel- No Longer Interested')) AS TOTAL_CANCEL,
    COUNT_IF(c.STRATEGY_CALL_OUTCOME IN ('4. No Show', '3. No Show'))      AS NO_SHOW,
    COUNT_IF(c.STATUS = 'Show')                                            AS STRTGY_CALL_SHW,
    COUNT_IF(c.STRATEGY_CALL_OUTCOME IN ('7. Lost', '6. Lost'))            AS LOST,
    COALESCE(s.SALE_COUNT, 0)                                              AS SALE,
    s.AVG_VALUE                                                            AS AVG_VAUE,   -- spelling matches source spec exactly
    COALESCE(s.CASH_COLLECTED, 0)                                          AS CASH_COLLECTED
FROM calls c
LEFT JOIN sales_agg s ON s.CLOSER_NAME = c.CLOSER_NAME AND s.SALE_YEAR_MONTH = c.CALL_YEAR_MONTH
GROUP BY c.CLOSER_NAME, c.CALL_YEAR_MONTH, s.SALE_COUNT, s.AVG_VALUE, s.CASH_COLLECTED;

-- ---------------------------------------------------------------------------
-- Objections Faced Report  ->  dea_closer_report/objections_faced/
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_OBJECTIONS_FACED AS
WITH sc AS (
    SELECT
        ACTIVITY_ID,
        DEA_INTERNAL_NAME                                  AS CLOSER_NAME,
        ACTIVITY_AT::DATE                                  AS ACTIVITY_DATE,
        WRAPPED_ACTIVITIES:"Objections Faced?"              AS OBJECTIONS_ARRAY
    FROM SILVER.LEADS_ACTIVITIES_SUMMARY
    WHERE TYPE = 'CustomActivity'
      AND CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_2VcSfZQX6FeIL8kkxy48C2', 'actitype_6IrDujYE2WKg9QCFJdpXJk')
      AND CUSTOM_ACTIVITY_OUTCOME_NAME IN ('7. Lost', '6. Lost')
),
sc_flat AS (
    -- OUTER => TRUE keeps calls with a NULL/empty Objections Faced? value
    -- (one row, OBJECTION = NULL) instead of dropping them from TOTAL_CALLS.
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
-- Sanity checks
-- ---------------------------------------------------------------------------
SELECT 'RPT_CLOSER' AS v, COUNT(*) AS n, SUM(CALL_BOOKED) AS calls, SUM(SALE) AS sales FROM GOLD.RPT_CLOSER
UNION ALL SELECT 'RPT_OBJECTIONS_FACED', COUNT(*), SUM(TOTAL_CALLS), NULL FROM GOLD.RPT_OBJECTIONS_FACED;
