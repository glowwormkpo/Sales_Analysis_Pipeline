/* =============================================================================
   Sales Analytics Pipeline - Reviewer-Flagged Issue Diagnostics
   31_duplicate_sale_check.sql

   lead_rj9F1r7NiKxaslSdrjXXJO3z949IAGtyLOxOU3yyI6O has two "7) New Sale"
   CustomActivity records ~4 minutes apart on 2026-08-17: one blank
   (00:40:06, the one that showed up in GOLD.SALES_DETAILS earlier), and one
   with real Contract Value ($20,000) and Cash Collected ($16,999.70) at
   00:35:52 that did NOT show up in that same SALES_DETAILS query. Since
   SALES_DETAILS has no dedup on New Sale activities, both should appear if
   both are in LEADS_ACTIVITIES_SUMMARY -- checking exact ACTIVITY_IDs and
   re-running the SALES_DETAILS query fresh to see if this is a genuine
   duplicate-activity data issue or just a load-timing gap that's since
   resolved via a scheduled refresh.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

-- 1) Confirm these are two distinct ACTIVITY_IDs, not the same record twice.
SELECT ACTIVITY_ID, LEAD_ID, ACTIVITY_AT, DATE_CREATED, DATE_UPDATED, INSERT_DATE, UPDATE_DATE,
       WRAPPED_ACTIVITIES:"Contract Value"::STRING AS contract_value,
       WRAPPED_ACTIVITIES:"Cash Collected"::STRING AS cash_collected
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
WHERE LEAD_ID = 'lead_rj9F1r7NiKxaslSdrjXXJO3z949IAGtyLOxOU3yyI6O'
  AND TYPE = 'CustomActivity' AND CUSTOM_ACTIVITY = '7) New Sale';

-- 2) Re-run the original check fresh -- does SALES_DETAILS now show 1 row
--    or 2 for this lead?
SELECT * FROM GOLD.SALES_DETAILS
WHERE LEAD_ID = 'lead_rj9F1r7NiKxaslSdrjXXJO3z949IAGtyLOxOU3yyI6O';
