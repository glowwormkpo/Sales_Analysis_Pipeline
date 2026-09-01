/* =============================================================================
   Sales Analytics Pipeline - Phase 3
   08_export_unload.sql

   Builds the four report views (aggregated to their exact grain and column
   list per the provided data model / Phase 2 Sec. 6) and unloads each to its
   target stage path. Views first, so you can SELECT * from them directly in
   Snowsight to sanity-check numbers before trusting the unloaded files.

   Fan-out guard: GOLD.ALL_STRATEGIES_DETAILS / SALES_DETAILS are per-activity
   grain (a lead can, in principle, have more than one strategy call attempt).
   The Inbound/Outbound Setter reports pre-aggregate to one row per lead in a
   CTE before joining to the cohort date, so summing revenue or counting sales
   never double-counts. The Closer and Objections reports intentionally stay
   at per-call grain, since they're measuring call-level outcomes.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- Inbound Setter Report  ->  dea_setter_report/inbound/
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_INBOUND_SETTER AS
WITH lead_strategy AS (
    SELECT LEAD_ID, SETTER,
           MAX(IFF(STATUS = 'Show', 1, 0))                                  AS SHOW_FLAG,
           MAX(IFF(STATUS = 'Show' AND OFFER_PRESENTED = 'Yes', 1, 0))      AS OFFER_FLAG
    FROM GOLD.ALL_STRATEGIES_DETAILS
    GROUP BY LEAD_ID, SETTER
),
lead_sales AS (
    SELECT LEAD_ID, SUM(CONTRACTED_VALUE) AS REVENUE, COUNT(*) AS SALE_COUNT
    FROM GOLD.SALES_DETAILS
    GROUP BY LEAD_ID
)
SELECT
    t.ACTIVITY_LOG_DATE                                                    AS TRIAGE_DATE,
    t.SETTER_CLOSER_EMAIL                                                  AS SETTER,
    COUNT(DISTINCT t.LEAD_ID)                                              AS INBOUND_BOOKED,
    COUNT(DISTINCT IFF(t.STRATEGY_CALL_BOOKED, t.LEAD_ID, NULL))           AS INBOUND_TAKEN,
    DIV0(COUNT(DISTINCT IFF(t.STRATEGY_CALL_BOOKED, t.LEAD_ID, NULL)), COUNT(DISTINCT t.LEAD_ID)) AS SHOW_RATE,
    DIV0(COUNT(DISTINCT IFF(t.STRATEGY_CALL_BOOKED, t.LEAD_ID, NULL)), COUNT(DISTINCT t.LEAD_ID)) AS TRIAGE_SET_RATE,
    COUNT(DISTINCT ls.LEAD_ID)                                             AS STRATEGY_CALL_BOOKED,
    SUM(COALESCE(ls.SHOW_FLAG, 0))                                         AS STRATEGY_CALL_TAKEN,
    DIV0(SUM(COALESCE(ls.OFFER_FLAG, 0)), NULLIF(SUM(COALESCE(ls.SHOW_FLAG, 0)), 0)) AS OFFER_RATE,
    SUM(COALESCE(lsa.SALE_COUNT, 0))                                       AS TOTAL_SALES,
    DIV0(SUM(COALESCE(lsa.SALE_COUNT, 0)), COUNT(DISTINCT IFF(t.STRATEGY_CALL_BOOKED, t.LEAD_ID, NULL))) AS SALE_RATE,
    DIV0(SUM(COALESCE(lsa.REVENUE, 0)), NULLIF(SUM(COALESCE(lsa.SALE_COUNT, 0)), 0)) AS AVERAGE_ORDER_VALUE
FROM GOLD.INBOUND_STRATEGIES_BOOKED t
LEFT JOIN lead_strategy ls ON ls.LEAD_ID = t.LEAD_ID AND ls.SETTER = t.SETTER_CLOSER_EMAIL
LEFT JOIN lead_sales lsa ON lsa.LEAD_ID = t.LEAD_ID
GROUP BY t.ACTIVITY_LOG_DATE, t.SETTER_CLOSER_EMAIL;

-- ---------------------------------------------------------------------------
-- Outbound Setter Report  ->  dea_setter_report/outbound/
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_OUTBOUND_SETTER AS
WITH lead_first_dial AS (
    SELECT LEAD_ID, SETTER_CLOSER_EMAIL AS SETTER,
           MIN(ACTIVITY_LOG_DATE) AS DIAL_DATE, COUNT(*) AS DIAL_COUNT
    FROM GOLD.OUTBOUND_PROSPECT_DIALS
    GROUP BY LEAD_ID, SETTER_CLOSER_EMAIL
),
lead_booked AS (
    SELECT LEAD_ID, MAX(IFF(STRATEGY_CALL_BOOKED, 1, 0)) AS SET_FLAG
    FROM GOLD.OUTBOUND_STRATEGIES_BOOKED
    GROUP BY LEAD_ID
),
lead_strategy AS (
    SELECT LEAD_ID,
           MAX(IFF(STATUS = 'Show', 1, 0)) AS SHOW_FLAG,
           MAX(IFF(STATUS = 'Show' AND OFFER_PRESENTED = 'Yes', 1, 0)) AS OFFER_FLAG
    FROM GOLD.ALL_STRATEGIES_DETAILS
    GROUP BY LEAD_ID
),
lead_sales AS (
    SELECT LEAD_ID, SUM(CONTRACTED_VALUE) AS REVENUE, COUNT(*) AS SALE_COUNT
    FROM GOLD.SALES_DETAILS
    GROUP BY LEAD_ID
)
SELECT
    fd.DIAL_DATE                                                           AS DIAL_DATE,
    fd.SETTER                                                              AS SETTER,
    SUM(fd.DIAL_COUNT)                                                     AS TOTAL_OUTBOUND_CALLS,
    COUNT(DISTINCT fd.LEAD_ID)                                             AS TOTAL_LEADS_TOUCHED,
    SUM(COALESCE(lb.SET_FLAG, 0))                                          AS OUTBOUND_SET,
    SUM(COALESCE(ls.SHOW_FLAG, 0))                                         AS TOTAL_CLOSER_SHOW,
    SUM(COALESCE(ls.OFFER_FLAG, 0))                                        AS TOTAL_OFFER,
    SUM(COALESCE(lsa.SALE_COUNT, 0))                                       AS TOTAL_SALE,
    DIV0(SUM(COALESCE(lb.SET_FLAG, 0)), SUM(fd.DIAL_COUNT))                AS DIAL_TO_SET_RATE,
    DIV0(SUM(COALESCE(ls.SHOW_FLAG, 0)), NULLIF(SUM(COALESCE(lb.SET_FLAG, 0)), 0)) AS SET_TO_SHOW_RATE,
    DIV0(SUM(COALESCE(lsa.SALE_COUNT, 0)), NULLIF(SUM(COALESCE(ls.SHOW_FLAG, 0)), 0)) AS SHOW_TO_SALE_RATE,
    SUM(COALESCE(lsa.REVENUE, 0))                                          AS TOTAL_REVENUE,
    DIV0(SUM(COALESCE(lsa.REVENUE, 0)), NULLIF(SUM(COALESCE(lsa.SALE_COUNT, 0)), 0)) AS AVERAGE_ORDER_VALUE
FROM lead_first_dial fd
LEFT JOIN lead_booked lb ON lb.LEAD_ID = fd.LEAD_ID
LEFT JOIN lead_strategy ls ON ls.LEAD_ID = fd.LEAD_ID
LEFT JOIN lead_sales lsa ON lsa.LEAD_ID = fd.LEAD_ID
GROUP BY fd.DIAL_DATE, fd.SETTER;

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
    COUNT_IF(c.STRATEGY_CALL_OUTCOME = '3. Cancel- Not Interested')        AS CANCEL_NOT_INTEREST,
    COUNT_IF(c.STRATEGY_CALL_OUTCOME IN
        ('2. Admin Cancel', '7. Cancel- Nurture', '8. Cancel- Nurture', '3. Cancel- Not Interested')) AS TOTAL_CANCEL,
    COUNT_IF(c.STRATEGY_CALL_OUTCOME IN ('4. No Show', '3. No Show'))      AS NO_SHOW,
    COUNT_IF(c.STATUS = 'Show')                                            AS STRTGY_CALL_SHW,
    COUNT_IF(c.STRATEGY_CALL_OUTCOME = '7. Lost')                          AS LOST,
    COALESCE(s.SALE_COUNT, 0)                                              AS SALE,
    s.AVG_VALUE                                                            AS AVG_VAUE,   -- spelling matches source spec exactly
    COALESCE(s.CASH_COLLECTED, 0)                                          AS CASH_COLLECTED
FROM calls c
LEFT JOIN sales_agg s ON s.CLOSER_NAME = c.CLOSER_NAME AND s.SALE_YEAR_MONTH = c.CALL_YEAR_MONTH
GROUP BY c.CLOSER_NAME, c.CALL_YEAR_MONTH, s.SALE_COUNT, s.AVG_VALUE, s.CASH_COLLECTED;

-- ---------------------------------------------------------------------------
-- Objections Faced Report  ->  dea_closer_report/objections_faced/
-- Scoped to Lost strategy calls, consistent with "reasons prospects do not
-- buy" (Phase 1 Sec. 6.4). "No Objections" is its own category for Lost
-- calls where no specific objection was logged.
--
-- REVISION: "Objections Faced" is a genuine multi-select field -- Close lets
-- a rep log more than one objection per call (confirmed by the transcript's
-- worked example, e.g. Lead F: ["Wasn't Looking For What We Offered",
-- "Money"]). SILVER already resolves it to a proper VARIANT ARRAY (via the
-- repair UDF in step 5 of 06_silver_merge_dedup.sql), so this view now
-- LATERAL FLATTENs that array per call instead of treating it as one scalar
-- string -- a call with 2 objections now correctly increments BOTH matching
-- category counts, rather than only ever matching (or not matching) one
-- exact string. TOTAL_CALLS still counts distinct calls (not flattened
-- rows), so the denominator isn't inflated by multi-objection calls.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_OBJECTIONS_FACED AS
WITH sc AS (
    SELECT
        ACTIVITY_ID,
        DEA_INTERNAL_NAME                                  AS CLOSER_NAME,
        ACTIVITY_AT::DATE                                  AS ACTIVITY_DATE,
        WRAPPED_ACTIVITIES:"Objections Faced"               AS OBJECTIONS_ARRAY
    FROM SILVER.LEADS_ACTIVITIES_SUMMARY
    WHERE TYPE = 'CustomActivity' AND CUSTOM_ACTIVITY_TYPE_ID = '300'
      AND CUSTOM_ACTIVITY_OUTCOME_NAME = '7. Lost'
),
sc_flat AS (
    -- OUTER => TRUE keeps calls with a NULL/empty Objections Faced value
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
-- Unloads: one COPY INTO per report, to its own stage subfolder.
-- Re-running is safe -- each unload overwrites that day's file (OVERWRITE = TRUE).
-- ---------------------------------------------------------------------------
COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_setter_report/inbound/
FROM (SELECT * FROM GOLD.RPT_INBOUND_SETTER)
FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
OVERWRITE = TRUE
SINGLE = TRUE
HEADER = TRUE;

COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_setter_report/outbound/
FROM (SELECT * FROM GOLD.RPT_OUTBOUND_SETTER)
FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
OVERWRITE = TRUE
SINGLE = TRUE
HEADER = TRUE;

COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_closer_report/closer_report/
FROM (SELECT * FROM GOLD.RPT_CLOSER)
FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
OVERWRITE = TRUE
SINGLE = TRUE
HEADER = TRUE;

COPY INTO @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS/dea_closer_report/objections_faced/
FROM (SELECT * FROM GOLD.RPT_OBJECTIONS_FACED)
FILE_FORMAT = (FORMAT_NAME = 'EXPORT_STAGE_OBJECTS.CSV_EXPORT_FORMAT')
OVERWRITE = TRUE
SINGLE = TRUE
HEADER = TRUE;

-- List what landed:
-- LIST @EXPORT_STAGE_OBJECTS.REPORT_EXPORTS;
