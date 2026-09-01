/* =============================================================================
   Sales Analytics Pipeline - Reviewer-Flagged Issue Diagnostics
   26_setter_closer_diagnostics.sql

   Investigates three issues found while validating the 2026-08-17 report
   exports against a reviewer's check:

   1. RPT_INBOUND_SETTER: STRATEGY_CALL_BOOKED/TAKEN/TOTAL_SALES are all zero
      on every row, despite INBOUND_TAKEN being non-zero. Hypothesis: the
      SETTER join key between INBOUND_STRATEGIES_BOOKED and
      ALL_STRATEGIES_DETAILS doesn't match (different resolution paths per
      Architecture doc Section 6.1 -- one may resolve from the activity's own
      "Setter" field, the other from a fallback).

   2. RPT_OUTBOUND_SETTER / RPT_CLOSER_DAILY: a large share of rows have no
      setter/closer name at all (85/98 outbound dials, 59/77 closer calls on
      this one day). Need to know whether that's a real data gap (rep didn't
      log a Setter/Closer on the activity) or a join failure against
      CLOSE_CRM_USERS_PROCESSED.

   3. RPT_CLOSER_DAILY: Christopher Garzon shows SALE = 3 but AVG_VAUE is
      NULL and CASH_COLLECTED = 0 -- need to see the actual SALES_DETAILS
      rows behind that count.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- 1) Inbound join-key mismatch: compare SETTER values on both sides for
--    2026-08-17. If ls_setter and t_setter are consistently different
--    formats (e.g. one is an email, one is blank/a name), that's the bug.
-- ---------------------------------------------------------------------------
SELECT
    t.LEAD_ID,
    t.SETTER_CLOSER_EMAIL   AS inbound_booked_setter,
    asd.SETTER               AS all_strategies_setter,
    asd.SETTER_NAME          AS all_strategies_setter_name,
    asd.STATUS,
    asd.DATE_OF_STRATEGY_CALL
FROM GOLD.INBOUND_STRATEGIES_BOOKED t
LEFT JOIN GOLD.ALL_STRATEGIES_DETAILS asd ON asd.LEAD_ID = t.LEAD_ID
WHERE t.ACTIVITY_LOG_DATE = '2026-08-17'
ORDER BY t.LEAD_ID;

-- ---------------------------------------------------------------------------
-- 2) How pervasive is null setter/closer attribution overall (not just this
--    day)? Run each independently.
-- ---------------------------------------------------------------------------
SELECT
    COUNT(*)                                              AS total_rows,
    COUNT_IF(SETTER_CLOSER_EMAIL IS NULL)                 AS null_setter_rows,
    ROUND(COUNT_IF(SETTER_CLOSER_EMAIL IS NULL) * 100.0 / COUNT(*), 1) AS pct_null
FROM GOLD.OUTBOUND_PROSPECT_DIALS;

SELECT
    COUNT(*)                                              AS total_rows,
    COUNT_IF(CLOSER_NAME IS NULL)                         AS null_closer_rows,
    ROUND(COUNT_IF(CLOSER_NAME IS NULL) * 100.0 / COUNT(*), 1) AS pct_null
FROM GOLD.ALL_STRATEGIES_DETAILS;

-- Sample the raw WRAPPED_ACTIVITIES Setter/Closer values behind the null
-- rows, to see whether the source field is genuinely empty or just not
-- matching CLOSE_CRM_USERS_PROCESSED.
SELECT
    s.LEAD_ID, s.ACTIVITY_ID, s.CUSTOM_ACTIVITY,
    s.WRAPPED_ACTIVITIES:"Setter"::STRING  AS raw_setter_field,
    s.WRAPPED_ACTIVITIES:"Closer"::STRING  AS raw_closer_field,
    u.USER_ID AS matched_user_id, u.EMAIL AS matched_email
FROM SILVER.LEADS_ACTIVITIES_SUMMARY s
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED u
    ON u.USER_ID = COALESCE(s.WRAPPED_ACTIVITIES:"Setter"::STRING, s.WRAPPED_ACTIVITIES:"Closer"::STRING)
WHERE s.ACTIVITY_AT::DATE = '2026-08-17'
  AND s.TYPE = 'CustomActivity'
LIMIT 50;

-- ---------------------------------------------------------------------------
-- 3) Christopher Garzon's 3 sales on 2026-08-17 -- see the actual rows.
-- ---------------------------------------------------------------------------
SELECT *
FROM GOLD.SALES_DETAILS
WHERE CLOSER_NAME = 'Christopher Garzon'
  AND DATE_OF_SALE = '2026-08-17';
