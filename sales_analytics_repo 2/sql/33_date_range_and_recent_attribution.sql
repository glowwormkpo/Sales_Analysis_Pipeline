/* =============================================================================
   Sales Analytics Pipeline - Reviewer Request
   33_date_range_and_recent_attribution.sql

   Reviewer asked for: (1) how much of a recent date's activity has no
   closer/setter/user attribution, and (2) the same for a 2024-2025 date, for
   comparison. Before running the 2024-2025 check, need to confirm that data
   actually exists in the activity stream the funnel/reports are built from
   -- the last date-range check (file 28) showed LEADS_ACTIVITIES_SUMMARY
   only going back to 2026-05-20. This checks both Silver (what the reports
   use) and Bronze (the raw source) date ranges, so if 2024-2025 data isn't
   in Silver, we can tell whether that's because it doesn't exist at all vs.
   it exists in Bronze but never made it through Silver processing.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;

-- 1) Date range + row counts by year, Silver (what reports actually run on).
SELECT
    YEAR(ACTIVITY_AT) AS activity_year,
    COUNT(*)          AS total_rows,
    MIN(ACTIVITY_AT)  AS earliest,
    MAX(ACTIVITY_AT)  AS latest
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
GROUP BY YEAR(ACTIVITY_AT)
ORDER BY activity_year;

-- 2) Date range in Bronze (the raw source) -- is there 2024-2025 activity
--    data sitting in Bronze that never made it into Silver, or does the
--    source itself only go back to 2026?
SELECT
    MIN(JSON_OBJECT:activity_at::TIMESTAMP_NTZ) AS earliest_in_bronze,
    MAX(JSON_OBJECT:activity_at::TIMESTAMP_NTZ) AS latest_in_bronze,
    COUNT(*) AS total_bronze_rows
FROM BRONZE.LEAD_ACTIVITIES_RAW,
     LATERAL FLATTEN(input => JSON_OBJECT:data)
WHERE TRY_CAST(VALUE:activity_at::STRING AS TIMESTAMP_NTZ) IS NOT NULL;

-- 3) Attribution gap for August 24-25, 2026.
SELECT
    'Aug 24-25, 2026' AS period,
    COUNT(*)                                                    AS total_rows,
    COUNT_IF(SETTER = 'Unattributed')                           AS unattributed_setter,
    ROUND(COUNT_IF(SETTER = 'Unattributed') * 100.0 / COUNT(*), 1) AS pct_unattributed_setter,
    COUNT_IF(CLOSER_NAME = 'Unattributed')                       AS unattributed_closer,
    ROUND(COUNT_IF(CLOSER_NAME = 'Unattributed') * 100.0 / COUNT(*), 1) AS pct_unattributed_closer
FROM GOLD.ALL_STRATEGIES_DETAILS
WHERE ACTIVITY_LOG_DATE BETWEEN '2026-08-24' AND '2026-08-25';

SELECT
    'Aug 24-25, 2026 (Outbound Dials)' AS period,
    COUNT(*)                                                       AS total_rows,
    COUNT_IF(SETTER_CLOSER_EMAIL = 'Unattributed')                 AS unattributed,
    ROUND(COUNT_IF(SETTER_CLOSER_EMAIL = 'Unattributed') * 100.0 / COUNT(*), 1) AS pct_unattributed
FROM GOLD.OUTBOUND_PROSPECT_DIALS
WHERE ACTIVITY_LOG_DATE BETWEEN '2026-08-24' AND '2026-08-25';
