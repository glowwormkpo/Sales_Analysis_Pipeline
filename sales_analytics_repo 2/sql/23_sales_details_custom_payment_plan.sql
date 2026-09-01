/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data) - Requirements Audit Fix
   23_sales_details_custom_payment_plan.sql

   Fixes gap #2: Section 3.4 of the requirements explicitly lists two
   sale-deriving activity types -- '7) New Sale' and '8) New Sale [Custom
   Payment Plan]'. GOLD.SALES_DETAILS only covered the first.

   Confirmed the Custom Payment Plan type's real field list before adding
   it (actitype_0FNk72Q8eSYX2MVd4A2UFx). Two structural differences from
   the primary New Sale type:
     - No "Contract Signed" field. New Sale uses this as the SALE_STATUS
       gate (Yes/No/blank); Custom Payment Plan has nothing equivalent, so
       there's no signed/not-signed signal to check. Since the activity's
       mere existence represents a committed payment plan (no draft/pending
       concept like New Sale apparently has), SALE_STATUS now falls back to
       'Yes' when "Contract Signed" isn't present rather than leaving it
       NULL, which would have silently excluded these sales from any
       downstream filter on SALE_STATUS = 'Yes'.
     - No "Cash Collected" field. Instead: "Initial Payment" (immediate
       amount collected), "Recurring Amount", and "Number of Billing
       Cycles" (installment structure). Per Section 3.4.2's own definition
       of cash_collected as "immediate realized revenue," "Initial Payment"
       is the correct equivalent for this type -- not the full plan value.
       CASH_COLLECTED now falls back to "Initial Payment" when "Cash
       Collected" isn't present.

   "Setter", "Closer", "Contract Value", "Program", "Sales Type" use the
   same field names on both types, so no change needed for those.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

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
    COALESCE(setter_u.EMAIL, asd.SETTER)                                     AS SETTER_EMAIL,
    COALESCE(TRIM(setter_u.FIRST_NAME || ' ' || setter_u.LAST_NAME), asd.SETTER_NAME) AS SETTER_NAME,
    COALESCE(closer_u.EMAIL, s.DEA_INTERNAL_EMAIL)                           AS CLOSER_EMAIL,
    COALESCE(TRIM(closer_u.FIRST_NAME || ' ' || closer_u.LAST_NAME), s.DEA_INTERNAL_NAME) AS CLOSER_NAME,
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
-- Sanity check: total should now be >= the previous 178 (New Sale only);
-- the breakdown shows how many came from each type.
-- ---------------------------------------------------------------------------
SELECT SALE_ACTIVITY_TYPE, COUNT(*) AS n, SUM(CASH_COLLECTED) AS total_cash_collected
FROM GOLD.SALES_DETAILS
GROUP BY SALE_ACTIVITY_TYPE
ORDER BY n DESC;
