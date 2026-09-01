/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data) - Bug Fix
   22_gold_closer_reports_fix.sql

   Fixes a real bug found by running 19_gold_closer_report_daily.sql: the
   sanity check showed RPT_CLOSER (monthly) totaling 178 sales but
   RPT_CLOSER_DAILY totaling only 147 -- a 31-sale gap.

   Root cause: both views were built as `calls LEFT JOIN sales_agg`, matched
   on exact call date (daily) or exact call month (monthly). If a sale gets
   logged on a day (or, for the monthly view, in principle a month) where
   that closer has zero Strategy Call activity logged -- e.g. a contract
   gets signed a day after the actual call -- there's no call-row for the
   sale to attach to, so it never appears in the output at all. The monthly
   view happened to show 178/178 correctly only because a closer who made a
   sale in a given month almost always also had some call logged that same
   month, papering over the exact same structural flaw that the tighter
   day-level matching exposed.

   Fix: both views are rebuilt from the UNION of every (closer, date) that
   has *either* a call or a sale, instead of driving from calls alone. Every
   sale now has somewhere to land even on a day/month with no matching call
   row for that closer.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- Closer Report (Daily)  ->  dea_closer_report/closer_report_daily/
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_CLOSER_DAILY AS
WITH calls_agg AS (
    SELECT
        CLOSER_NAME, DATE_OF_STRATEGY_CALL::DATE AS RPT_DATE,
        COUNT(*)                                                               AS CALL_BOOKED,
        COUNT_IF(STRATEGY_CALL_OUTCOME = '2. Admin Cancel')                    AS ADMIN_CANCEL,
        COUNT_IF(STRATEGY_CALL_OUTCOME IN ('7. Cancel- Nurture', '8. Cancel- Nurture')) AS CANCEL_NURTURE,
        COUNT_IF(STRATEGY_CALL_OUTCOME IN ('3. Cancel- Not Interested', '2. Cancel- No Longer Interested')) AS CANCEL_NOT_INTEREST,
        COUNT_IF(STRATEGY_CALL_OUTCOME IN
            ('2. Admin Cancel', '7. Cancel- Nurture', '8. Cancel- Nurture',
             '3. Cancel- Not Interested', '2. Cancel- No Longer Interested'))  AS TOTAL_CANCEL,
        COUNT_IF(STRATEGY_CALL_OUTCOME IN ('4. No Show', '3. No Show'))        AS NO_SHOW,
        COUNT_IF(STATUS = 'Show')                                              AS STRTGY_CALL_SHW,
        COUNT_IF(STRATEGY_CALL_OUTCOME IN ('7. Lost', '6. Lost'))              AS LOST
    FROM GOLD.ALL_STRATEGIES_DETAILS
    GROUP BY CLOSER_NAME, DATE_OF_STRATEGY_CALL::DATE
),
sales_agg AS (
    SELECT CLOSER_NAME, DATE_OF_SALE AS RPT_DATE,
           COUNT(*) AS SALE_COUNT, AVG(CONTRACTED_VALUE) AS AVG_VALUE, SUM(CASH_COLLECTED) AS CASH_COLLECTED
    FROM GOLD.SALES_DETAILS
    GROUP BY CLOSER_NAME, DATE_OF_SALE
),
all_days AS (
    SELECT CLOSER_NAME, RPT_DATE FROM calls_agg
    UNION
    SELECT CLOSER_NAME, RPT_DATE FROM sales_agg
)
SELECT
    d.CLOSER_NAME,
    d.RPT_DATE                                                                AS CALL_DATE,
    COALESCE(ca.CALL_BOOKED, 0)                                               AS CALL_BOOKED,
    COALESCE(ca.ADMIN_CANCEL, 0)                                              AS ADMIN_CANCEL,
    COALESCE(ca.CANCEL_NURTURE, 0)                                            AS CANCEL_NURTURE,
    COALESCE(ca.CANCEL_NOT_INTEREST, 0)                                       AS CANCEL_NOT_INTEREST,
    COALESCE(ca.TOTAL_CANCEL, 0)                                              AS TOTAL_CANCEL,
    COALESCE(ca.NO_SHOW, 0)                                                   AS NO_SHOW,
    COALESCE(ca.STRTGY_CALL_SHW, 0)                                           AS STRTGY_CALL_SHW,
    COALESCE(ca.LOST, 0)                                                      AS LOST,
    COALESCE(sa.SALE_COUNT, 0)                                                AS SALE,
    sa.AVG_VALUE                                                              AS AVG_VAUE,   -- spelling matches source spec exactly
    COALESCE(sa.CASH_COLLECTED, 0)                                            AS CASH_COLLECTED
FROM all_days d
LEFT JOIN calls_agg ca ON ca.CLOSER_NAME = d.CLOSER_NAME AND ca.RPT_DATE = d.RPT_DATE
LEFT JOIN sales_agg sa ON sa.CLOSER_NAME = d.CLOSER_NAME AND sa.RPT_DATE = d.RPT_DATE;

-- ---------------------------------------------------------------------------
-- Closer Report (Monthly)  ->  dea_closer_report/closer_report/
-- Same fix applied even though it wasn't visibly broken -- same underlying
-- flaw, just not exposed at this coarser grain in this particular dataset.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_CLOSER AS
WITH calls_agg AS (
    SELECT
        CLOSER_NAME, TO_VARCHAR(DATE_OF_STRATEGY_CALL, 'YYYY-MM') AS RPT_MONTH,
        COUNT(*)                                                               AS CALL_BOOKED,
        COUNT_IF(STRATEGY_CALL_OUTCOME = '2. Admin Cancel')                    AS ADMIN_CANCEL,
        COUNT_IF(STRATEGY_CALL_OUTCOME IN ('7. Cancel- Nurture', '8. Cancel- Nurture')) AS CANCEL_NURTURE,
        COUNT_IF(STRATEGY_CALL_OUTCOME IN ('3. Cancel- Not Interested', '2. Cancel- No Longer Interested')) AS CANCEL_NOT_INTEREST,
        COUNT_IF(STRATEGY_CALL_OUTCOME IN
            ('2. Admin Cancel', '7. Cancel- Nurture', '8. Cancel- Nurture',
             '3. Cancel- Not Interested', '2. Cancel- No Longer Interested'))  AS TOTAL_CANCEL,
        COUNT_IF(STRATEGY_CALL_OUTCOME IN ('4. No Show', '3. No Show'))        AS NO_SHOW,
        COUNT_IF(STATUS = 'Show')                                              AS STRTGY_CALL_SHW,
        COUNT_IF(STRATEGY_CALL_OUTCOME IN ('7. Lost', '6. Lost'))              AS LOST
    FROM GOLD.ALL_STRATEGIES_DETAILS
    GROUP BY CLOSER_NAME, TO_VARCHAR(DATE_OF_STRATEGY_CALL, 'YYYY-MM')
),
sales_agg AS (
    SELECT CLOSER_NAME, TO_VARCHAR(DATE_OF_SALE, 'YYYY-MM') AS RPT_MONTH,
           COUNT(*) AS SALE_COUNT, AVG(CONTRACTED_VALUE) AS AVG_VALUE, SUM(CASH_COLLECTED) AS CASH_COLLECTED
    FROM GOLD.SALES_DETAILS
    GROUP BY CLOSER_NAME, TO_VARCHAR(DATE_OF_SALE, 'YYYY-MM')
),
all_months AS (
    SELECT CLOSER_NAME, RPT_MONTH FROM calls_agg
    UNION
    SELECT CLOSER_NAME, RPT_MONTH FROM sales_agg
)
SELECT
    d.CLOSER_NAME,
    d.RPT_MONTH                                                               AS CALL_YEAR_MONTH,
    COALESCE(ca.CALL_BOOKED, 0)                                               AS CALL_BOOKED,
    COALESCE(ca.ADMIN_CANCEL, 0)                                              AS ADMIN_CANCEL,
    COALESCE(ca.CANCEL_NURTURE, 0)                                            AS CANCEL_NURTURE,
    COALESCE(ca.CANCEL_NOT_INTEREST, 0)                                       AS CANCEL_NOT_INTEREST,
    COALESCE(ca.TOTAL_CANCEL, 0)                                              AS TOTAL_CANCEL,
    COALESCE(ca.NO_SHOW, 0)                                                   AS NO_SHOW,
    COALESCE(ca.STRTGY_CALL_SHW, 0)                                           AS STRTGY_CALL_SHW,
    COALESCE(ca.LOST, 0)                                                      AS LOST,
    COALESCE(sa.SALE_COUNT, 0)                                                AS SALE,
    sa.AVG_VALUE                                                              AS AVG_VAUE,   -- spelling matches source spec exactly
    COALESCE(sa.CASH_COLLECTED, 0)                                            AS CASH_COLLECTED
FROM all_months d
LEFT JOIN calls_agg ca ON ca.CLOSER_NAME = d.CLOSER_NAME AND ca.RPT_MONTH = d.RPT_MONTH
LEFT JOIN sales_agg sa ON sa.CLOSER_NAME = d.CLOSER_NAME AND sa.RPT_MONTH = d.RPT_MONTH;

-- ---------------------------------------------------------------------------
-- Sanity check: both should now total the full 178 sales, and neither
-- should undercount relative to the other.
-- ---------------------------------------------------------------------------
SELECT 'RPT_CLOSER (monthly)' AS v, COUNT(*) AS n, SUM(CALL_BOOKED) AS calls, SUM(SALE) AS sales FROM GOLD.RPT_CLOSER
UNION ALL SELECT 'RPT_CLOSER_DAILY', COUNT(*), SUM(CALL_BOOKED), SUM(SALE) FROM GOLD.RPT_CLOSER_DAILY
UNION ALL SELECT 'SALES_DETAILS (ground truth)', COUNT(*), NULL, NULL FROM GOLD.SALES_DETAILS;
