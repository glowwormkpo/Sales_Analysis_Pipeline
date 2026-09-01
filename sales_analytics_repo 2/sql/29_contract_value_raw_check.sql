/* =============================================================================
   Sales Analytics Pipeline - Reviewer-Flagged Issue Diagnostics
   29_contract_value_raw_check.sql

   All 3 of Christopher Garzon's 2026-08-17 sales have NULL CONTRACTED_VALUE
   and CASH_COLLECTED in GOLD.SALES_DETAILS. Both are computed via
   TRY_CAST(WRAPPED_ACTIVITIES:"..."::STRING AS NUMBER(12,2)), which fails
   silently (returns NULL, no error) if the raw value is formatted in a way
   NUMBER() can't parse -- e.g. "$5,000.00" instead of "5000.00". This checks
   the raw, uncast text so we can tell whether the fields are genuinely
   empty (not a bug) or present-but-malformed (a real casting bug to fix).
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

SELECT
    LEAD_ID,
    ACTIVITY_AT,
    WRAPPED_ACTIVITIES:"Contract Value"::STRING  AS raw_contract_value,
    WRAPPED_ACTIVITIES:"Cash Collected"::STRING  AS raw_cash_collected,
    WRAPPED_ACTIVITIES:"Program"::STRING         AS program
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
WHERE LEAD_ID IN (
    'lead_f1QKvXxx05H8VQHtD46MbsEjT0VVkoCY2XgX5tYNlhz',
    'lead_sRdHSc1N5JDJpdDQLUuIyt0rDJ4yGpNEjHcqEZ3bMMs',
    'lead_rj9F1r7NiKxaslSdrjXXJO3z949IAGtyLOxOU3yyI6O'
)
AND TYPE = 'CustomActivity'
AND CUSTOM_ACTIVITY = '7) New Sale';

-- Also check how common this is across ALL sales, not just these 3 --
-- if a large share of "7) New Sale" records have a non-castable Contract
-- Value, that confirms a systemic formatting issue rather than a one-off.
SELECT
    COUNT(*)                                                                          AS total_new_sales,
    COUNT_IF(WRAPPED_ACTIVITIES:"Contract Value" IS NOT NULL
             AND TRY_CAST(WRAPPED_ACTIVITIES:"Contract Value"::STRING AS NUMBER(12,2)) IS NULL) AS present_but_uncastable,
    COUNT_IF(WRAPPED_ACTIVITIES:"Contract Value" IS NULL)                              AS genuinely_null
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
WHERE TYPE = 'CustomActivity' AND CUSTOM_ACTIVITY = '7) New Sale';
