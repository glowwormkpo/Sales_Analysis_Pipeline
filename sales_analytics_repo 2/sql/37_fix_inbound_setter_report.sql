/* =============================================================================
   Sales Analytics Pipeline - Reviewer-Reported Bug Fix
   37_fix_inbound_setter_report.sql

   Reviewer flagged a row that made no sense: INBOUND_BOOKED=6, INBOUND_TAKEN=0,
   yet STRATEGY_CALL_BOOKED=2 for the same setter/date. Root cause, confirmed
   by reading the actual view SQL (08_export_unload.sql, never rewritten for
   real data since it "reconciled" on column totals during the earlier
   spot-check -- but totals matching doesn't guarantee per-row logic is
   correct, which is exactly what broke here):

   1. INBOUND_TAKEN was computed from STRATEGY_CALL_BOOKED (whether the
      triage led to a scheduled strategy call) -- a completely different
      concept from whether the triage call itself was actually held/taken.
      SHOW_RATE and TRIAGE_SET_RATE were also literally the same formula,
      copy-pasted, when they should mean different things.

   2. The reported STRATEGY_CALL_BOOKED column wasn't gated by any "booked"
      flag at all -- it counted any lead with a matching ALL_STRATEGIES_
      DETAILS row, joined on LEAD_ID + SETTER. That join used ALL_STRATEGIES_
      DETAILS.SETTER, which resolves identity through a totally different
      chain (current-roster match -> Setter/Closer custom fields) than
      INBOUND_STRATEGIES_BOOKED.SETTER_CLOSER_EMAIL (the triage activity's
      own raw logged owner). Those two values can differ for the same lead,
      which is exactly how INBOUND_TAKEN=0 and STRATEGY_CALL_BOOKED=2
      happened simultaneously -- two unrelated metrics from two different,
      mismatched joins.

   FIX:
   - INBOUND_STRATEGIES_BOOKED now exposes a real TRIAGE_TAKEN flag: TRUE
     unless the outcome is one of the 3 "call didn't happen" outcomes
     confirmed against the real taxonomy (6. No Show / 7. Reschedule /
     8. Cancel) -- same reasoning already applied to Strategy Call Show/
     No-Show classification in ALL_STRATEGIES_DETAILS.
   - RPT_INBOUND_SETTER rewritten: INBOUND_TAKEN uses the new TRIAGE_TAKEN
     flag; SHOW_RATE = taken/booked; TRIAGE_SET_RATE = strategy calls set /
     taken (not a duplicate of SHOW_RATE); STRATEGY_CALL_BOOKED now uses
     t.STRATEGY_CALL_BOOKED directly instead of the mismatched cross-join;
     STRATEGY_CALL_TAKEN's join to ALL_STRATEGIES_DETAILS drops the SETTER
     match requirement (LEAD_ID alone is sufficient and reliable -- t is
     already scoped to this setter's triage cohort via the outer GROUP BY,
     so re-matching on a differently-resolved SETTER field only introduced
     false negatives).

   RPT_OUTBOUND_SETTER was checked and does NOT have this bug -- its
   lead_booked/lead_strategy joins already match on LEAD_ID alone.

   CORRECTION (found after first deploy, via a second sanity-check row):
   the first version of this fix still let STRATEGY_CALL_TAKEN and
   OFFER_RATE sum ls.SHOW_FLAG/ls.OFFER_FLAG across the WHOLE triage
   cohort, ungated by t.STRATEGY_CALL_BOOKED -- producing another
   impossible combination (STRATEGY_CALL_BOOKED=0, STRATEGY_CALL_TAKEN=4).
   Both are now gated by IFF(t.STRATEGY_CALL_BOOKED, ..., 0), so a lead
   only counts toward "taken"/"offered" if their triage row actually
   indicates a strategy call was booked in the first place.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- 1. Add TRIAGE_TAKEN to INBOUND_STRATEGIES_BOOKED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.INBOUND_STRATEGIES_BOOKED AS
SELECT
    LEAD_ID,
    ACTIVITY_AT::DATE                                                     AS ACTIVITY_LOG_DATE,
    DEA_INTERNAL_EMAIL                                                    AS SETTER_CLOSER_EMAIL,
    DEA_INTERNAL_NAME                                                     AS SETTER_CLOSER_NAME,
    CUSTOM_ACTIVITY_OUTCOME_NAME                                          AS TRIAGE_CALL_OUTCOME,
    ACTIVITY_AT                                                            AS TRIAGE_CALL_DATE,
    IFF(CUSTOM_ACTIVITY_OUTCOME_NAME IS NOT NULL
        AND CUSTOM_ACTIVITY_OUTCOME_NAME NOT IN ('6. No Show', '7. Reschedule', '8. Cancel'),
        TRUE, FALSE)                                                      AS TRIAGE_TAKEN,
    IFF(CUSTOM_ACTIVITY_OUTCOME_NAME = '1. Strategy Call Scheduled', TRUE, FALSE) AS STRATEGY_CALL_BOOKED,
    TO_VARCHAR(ACTIVITY_AT, 'YYYY') || '-W' || LPAD(WEEKOFYEAR(ACTIVITY_AT), 2, '0') AS SC_YEAR_WEEK
FROM SILVER.LEADS_ACTIVITIES_SUMMARY
WHERE TYPE = 'CustomActivity'
  AND CUSTOM_ACTIVITY_TYPE_ID IN ('actitype_38341SWOKRkRHHAqWEqSJu', 'actitype_1zimBrwAdOLmRLK0Ncg6Lb')
QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAD_ID ORDER BY ACTIVITY_AT DESC) = 1;

-- ---------------------------------------------------------------------------
-- 2. Rewrite RPT_INBOUND_SETTER with corrected logic
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_INBOUND_SETTER AS
WITH lead_strategy AS (
    SELECT LEAD_ID,
           MAX(IFF(STATUS = 'Show', 1, 0))                                  AS SHOW_FLAG,
           MAX(IFF(STATUS = 'Show' AND OFFER_PRESENTED = 'Yes', 1, 0))      AS OFFER_FLAG
    FROM GOLD.ALL_STRATEGIES_DETAILS
    GROUP BY LEAD_ID
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
    COUNT(DISTINCT IFF(t.TRIAGE_TAKEN, t.LEAD_ID, NULL))                   AS INBOUND_TAKEN,
    DIV0(COUNT(DISTINCT IFF(t.TRIAGE_TAKEN, t.LEAD_ID, NULL)), COUNT(DISTINCT t.LEAD_ID)) AS SHOW_RATE,
    DIV0(COUNT(DISTINCT IFF(t.STRATEGY_CALL_BOOKED, t.LEAD_ID, NULL)), NULLIF(COUNT(DISTINCT IFF(t.TRIAGE_TAKEN, t.LEAD_ID, NULL)), 0)) AS TRIAGE_SET_RATE,
    COUNT(DISTINCT IFF(t.STRATEGY_CALL_BOOKED, t.LEAD_ID, NULL))           AS STRATEGY_CALL_BOOKED,
    SUM(IFF(t.STRATEGY_CALL_BOOKED, COALESCE(ls.SHOW_FLAG, 0), 0))         AS STRATEGY_CALL_TAKEN,
    DIV0(SUM(IFF(t.STRATEGY_CALL_BOOKED, COALESCE(ls.OFFER_FLAG, 0), 0)), NULLIF(SUM(IFF(t.STRATEGY_CALL_BOOKED, COALESCE(ls.SHOW_FLAG, 0), 0)), 0)) AS OFFER_RATE,
    SUM(COALESCE(lsa.SALE_COUNT, 0))                                       AS TOTAL_SALES,
    DIV0(SUM(COALESCE(lsa.SALE_COUNT, 0)), NULLIF(COUNT(DISTINCT IFF(t.STRATEGY_CALL_BOOKED, t.LEAD_ID, NULL)), 0)) AS SALE_RATE,
    DIV0(SUM(COALESCE(lsa.REVENUE, 0)), NULLIF(SUM(COALESCE(lsa.SALE_COUNT, 0)), 0)) AS AVERAGE_ORDER_VALUE
FROM GOLD.INBOUND_STRATEGIES_BOOKED t
LEFT JOIN lead_strategy ls ON ls.LEAD_ID = t.LEAD_ID
LEFT JOIN lead_sales lsa ON lsa.LEAD_ID = t.LEAD_ID
GROUP BY t.ACTIVITY_LOG_DATE, t.SETTER_CLOSER_EMAIL;

/* -----------------------------------------------------------------------------
   Sanity check -- confirm row 921's exact case (gregory@dataengineeracademy.com,
   2026-08-25) no longer produces a logically impossible combination:
SELECT * FROM GOLD.RPT_INBOUND_SETTER
WHERE SETTER = 'gregory@dataengineeracademy.com' AND TRIAGE_DATE = '2026-08-25';

   Also re-run the file 24 spot-check to confirm totals still reconcile
   (INBOUND_BOOKED total should still equal INBOUND_STRATEGIES_BOOKED row
   count -- that part of the view wasn't touched):
SELECT SUM(INBOUND_BOOKED) FROM GOLD.RPT_INBOUND_SETTER;
SELECT COUNT(*) FROM GOLD.INBOUND_STRATEGIES_BOOKED;
----------------------------------------------------------------------------- */
