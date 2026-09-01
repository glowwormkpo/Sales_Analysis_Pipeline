/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data)
   19_gold_closer_report_daily.sql

   Adds a day-level Closer report (GOLD.RPT_CLOSER_DAILY) alongside the
   existing month-level one (GOLD.RPT_CLOSER, unchanged -- kept exactly as
   it was so nothing that already depends on that view name breaks).

   Same aggregation logic and column list as RPT_CLOSER, just grouped by
   exact call date instead of year-month, and the sales join matches on
   exact date instead of year-month. Sourced from the same two Gold views
   (ALL_STRATEGIES_DETAILS / SALES_DETAILS) that RPT_CLOSER already uses, so
   it reflects the same real-data outcome taxonomy fixed in
   16_gold_reports_real_data.sql (Strategy Call + Strategy Call Follow Up
   rolled together, per-type wording differences for Cancel/Lost handled).

   Also updates GOLD.EXPORT_ALL_REPORTS() to unload the new daily report to
   its own stage subfolder (dea_closer_report/closer_report_daily/),
   alongside the existing monthly one (dea_closer_report/closer_report/).
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- Closer Report (Daily)  ->  dea_closer_report/closer_report_daily/
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_CLOSER_DAILY AS
WITH calls AS (
    SELECT * FROM GOLD.ALL_STRATEGIES_DETAILS
),
sales_agg AS (
    SELECT CLOSER_NAME, DATE_OF_SALE,
           COUNT(*) AS SALE_COUNT, AVG(CONTRACTED_VALUE) AS AVG_VALUE, SUM(CASH_COLLECTED) AS CASH_COLLECTED
    FROM GOLD.SALES_DETAILS
    GROUP BY CLOSER_NAME, DATE_OF_SALE
)
SELECT
    c.CLOSER_NAME,
    c.DATE_OF_STRATEGY_CALL::DATE                                          AS CALL_DATE,
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
    s.AVG_VALUE                                                            AS AVG_VAUE,   -- spelling matches RPT_CLOSER exactly
    COALESCE(s.CASH_COLLECTED, 0)                                          AS CASH_COLLECTED
FROM calls c
LEFT JOIN sales_agg s ON s.CLOSER_NAME = c.CLOSER_NAME AND s.DATE_OF_SALE = c.DATE_OF_STRATEGY_CALL::DATE
GROUP BY c.CLOSER_NAME, c.DATE_OF_STRATEGY_CALL::DATE, s.SALE_COUNT, s.AVG_VALUE, s.CASH_COLLECTED;

-- ---------------------------------------------------------------------------
-- Updated export procedure: adds the daily closer unload, keeps the other
-- three (inbound setter, outbound setter, monthly closer, objections faced)
-- exactly as they were.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GOLD.EXPORT_ALL_REPORTS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_setter_report/inbound/
        FROM (SELECT * FROM GOLD.RPT_INBOUND_SETTER)
        FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
        OVERWRITE = TRUE SINGLE = TRUE HEADER = TRUE;

    COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_setter_report/outbound/
        FROM (SELECT * FROM GOLD.RPT_OUTBOUND_SETTER)
        FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
        OVERWRITE = TRUE SINGLE = TRUE HEADER = TRUE;

    COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_closer_report/closer_report/
        FROM (SELECT * FROM GOLD.RPT_CLOSER)
        FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
        OVERWRITE = TRUE SINGLE = TRUE HEADER = TRUE;

    COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_closer_report/closer_report_daily/
        FROM (SELECT * FROM GOLD.RPT_CLOSER_DAILY)
        FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
        OVERWRITE = TRUE SINGLE = TRUE HEADER = TRUE;

    COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_closer_report/objections_faced/
        FROM (SELECT * FROM GOLD.RPT_OBJECTIONS_FACED)
        FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
        OVERWRITE = TRUE SINGLE = TRUE HEADER = TRUE;

    RETURN 'Export complete: ' || TO_VARCHAR(CURRENT_TIMESTAMP());
END;
$$;

-- ---------------------------------------------------------------------------
-- Sanity check: daily rows should sum back to the monthly totals per closer.
-- ---------------------------------------------------------------------------
SELECT 'RPT_CLOSER (monthly)' AS v, COUNT(*) AS n, SUM(CALL_BOOKED) AS calls, SUM(SALE) AS sales FROM GOLD.RPT_CLOSER
UNION ALL SELECT 'RPT_CLOSER_DAILY', COUNT(*), SUM(CALL_BOOKED), SUM(SALE) FROM GOLD.RPT_CLOSER_DAILY;
