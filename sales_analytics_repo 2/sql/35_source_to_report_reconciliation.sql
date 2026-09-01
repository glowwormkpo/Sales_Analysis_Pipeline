/* =============================================================================
   Sales Analytics Pipeline - Reviewer Request
   35_source_to_report_reconciliation.sql

   Reviewer asked for a match vs. mismatch classification, source all the way
   to the reports. This breaks the pipeline into its three real transitions
   and measures survival/match rate at each:

     Bronze -> Silver : did the raw activity parse and land as a row at all?
     Silver -> Gold    : does it belong to one of the 8 report-relevant
                          activity types, and if so, does its setter/closer
                          identity resolve?
     Gold -> Reports    : every Gold row is aggregated into an RPT_* export;
                          this should be ~100% by construction since the
                          RPT_* views don't filter anything out, only group.

   Two different reasons a record can fail to "match": TYPE EXCLUSION (it's
   correctly filtered out because it's not one of the 4 report's relevant
   activity types -- e.g. a Note or a Payment Transaction -- expected
   behavior, not a defect) vs. IDENTITY MISMATCH (it IS a relevant type, but
   its setter/closer never resolves against CLOSE_CRM_USERS_PROCESSED --
   the real, quantified data-quality gap covered in the README's Reviewer
   Validation section and Requirements_vs_Reality.md).
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;

-- ---------------------------------------------------------------------------
-- STAGE 1: Bronze -> Silver
-- Every activity_id that shows up in the raw Bronze payload vs. how many
-- distinct activity_ids made it into Silver's master table. Bronze is
-- append-only (same activity reappears in every daily batch), so compare
-- DISTINCT activity_id counts, not raw row counts.
-- ---------------------------------------------------------------------------
WITH bronze_distinct AS (
    SELECT DISTINCT f.VALUE:id::STRING AS activity_id
    FROM BRONZE.LEAD_ACTIVITIES_RAW,
         LATERAL FLATTEN(input => JSON_OBJECT:data) f
    WHERE f.VALUE:id IS NOT NULL
)
SELECT
    'STAGE 1: Bronze -> Silver' AS stage,
    (SELECT COUNT(*) FROM bronze_distinct)                       AS distinct_activity_ids_in_bronze,
    (SELECT COUNT(DISTINCT ACTIVITY_ID) FROM SILVER.LEADS_ACTIVITIES_SUMMARY) AS distinct_activity_ids_in_silver,
    ROUND(
        (SELECT COUNT(DISTINCT ACTIVITY_ID) FROM SILVER.LEADS_ACTIVITIES_SUMMARY) * 100.0
        / NULLIF((SELECT COUNT(*) FROM bronze_distinct), 0)
    , 1) AS pct_matched;

-- ---------------------------------------------------------------------------
-- STAGE 2a: Silver -> Gold, by TYPE (expected exclusion, not a defect)
-- Of all Silver CustomActivity rows, how many belong to one of the 8 type
-- IDs that feed the 4 required reports (Triage/Triage FU, Prospecting/
-- Prospecting FU, Strategy/Strategy FU, New Sale/New Sale Custom Plan) vs.
-- the other 20 real types that are correctly out of scope for these reports.
-- ---------------------------------------------------------------------------
SELECT
    'STAGE 2a: Silver -> Gold (type scope)' AS stage,
    COUNT(*) AS total_customactivity_rows,
    COUNT_IF(CUSTOM_ACTIVITY_TYPE_ID IN (
        'actitype_38341SWOKRkRHHAqWEqSJu','actitype_1zimBrwAdOLmRLK0Ncg6Lb',  -- Triage / Follow Up
        'actitype_4tEv1xumZEk9vYYs7WxYy7','actitype_6ga7msjJ7kZcH2rGtYETwe',  -- Prospecting / Follow Up
        'actitype_2VcSfZQX6FeIL8kkxy48C2','actitype_6IrDujYE2WKg9QCFJdpXJk',  -- Strategy Call / Follow Up
        'actitype_3E85vFq3a06LlEzXT2N1kS','actitype_0FNk72Q8eSYX2MVd4A2UFx'   -- New Sale / Custom Payment Plan
    )) AS in_scope_for_reports,
    COUNT_IF(CUSTOM_ACTIVITY_TYPE_ID NOT IN (
        'actitype_38341SWOKRkRHHAqWEqSJu','actitype_1zimBrwAdOLmRLK0Ncg6Lb',
        'actitype_4tEv1xumZEk9vYYs7WxYy7','actitype_6ga7msjJ7kZcH2rGtYETwe',
        'actitype_2VcSfZQX6FeIL8kkxy48C2','actitype_6IrDujYE2WKg9QCFJdpXJk',
        'actitype_3E85vFq3a06LlEzXT2N1kS','actitype_0FNk72Q8eSYX2MVd4A2UFx'
    )) AS excluded_other_activity_types
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
WHERE TYPE = 'CustomActivity';

-- ---------------------------------------------------------------------------
-- STAGE 2b: Silver -> Gold, IDENTITY MATCH within in-scope types only
-- Of the in-scope Strategy Call / Strategy Call Follow Up rows that reach
-- ALL_STRATEGIES_DETAILS, how many fully match (both setter and closer
-- resolved), partially match (one of the two), or mismatch (neither)?
-- ---------------------------------------------------------------------------
SELECT
    'STAGE 2b: Gold identity resolution' AS stage,
    COUNT(*) AS total_rows,
    COUNT_IF(SETTER != 'Unattributed' AND CLOSER_NAME != 'Unattributed') AS full_match,
    COUNT_IF(SETTER != 'Unattributed' AND CLOSER_NAME = 'Unattributed')  AS partial_match_setter_only,
    COUNT_IF(SETTER = 'Unattributed' AND CLOSER_NAME != 'Unattributed')  AS partial_match_closer_only,
    COUNT_IF(SETTER = 'Unattributed' AND CLOSER_NAME = 'Unattributed')   AS full_mismatch,
    ROUND(COUNT_IF(SETTER != 'Unattributed' AND CLOSER_NAME != 'Unattributed') * 100.0 / COUNT(*), 1) AS pct_full_match
FROM GOLD.ALL_STRATEGIES_DETAILS;

-- ---------------------------------------------------------------------------
-- STAGE 3: Gold -> Reports
-- Every ALL_STRATEGIES_DETAILS / SALES_DETAILS row should be represented in
-- some RPT_* export (RPT_CLOSER_DAILY sums SALE by closer+date; totals
-- should reconcile exactly since RPT_* views only aggregate, never filter).
-- ---------------------------------------------------------------------------
SELECT 'GOLD.ALL_STRATEGIES_DETAILS (Show)' AS v, COUNT(*) AS n FROM GOLD.ALL_STRATEGIES_DETAILS WHERE STATUS = 'Show'
UNION ALL SELECT 'RPT_CLOSER_DAILY sum(CALL_BOOKED)', SUM(CALL_BOOKED) FROM GOLD.RPT_CLOSER_DAILY
UNION ALL SELECT 'GOLD.SALES_DETAILS', COUNT(*) FROM GOLD.SALES_DETAILS
UNION ALL SELECT 'RPT_CLOSER_DAILY sum(SALE)', SUM(SALE) FROM GOLD.RPT_CLOSER_DAILY
UNION ALL SELECT 'RPT_CLOSER sum(SALE)', SUM(SALE) FROM GOLD.RPT_CLOSER;
