/* =============================================================================
   Sales Analytics Pipeline - Reviewer Round 2 Fix
   39_outbound_closer_objections_reports.sql

   Rebuilds the remaining 3 of the 4 required KPI reports from
   GOLD.LEAD_JOURNEY_SUMMARY (see 38_lead_journey_summary_and_inbound_setter.sql
   for the corrected one-row-per-lead grain, validated 46 booked / 10 shown
   vs. the reference's 44 / 12 for Jordon Eggleston, Aug 2026).

   RPT_CLOSER is built at MONTH level, not daily, per Avirup's explicit
   correction on the review call: "the closer report on our end is at month
   level" -- a closer only enters the picture once a strategy call is
   booked, so day-level granularity doesn't apply the way it does for
   setters (who can touch many leads/days).

   RPT_OBJECTIONS_FACED flattens the OBJECTIONS_FACED array already captured
   in LEAD_JOURNEY_SUMMARY (from the activity's "Objections Faced?" custom
   field, a multi-select) to one row per closer per objection tag.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- 1. RPT_OUTBOUND_SETTER -- mirrors RPT_INBOUND_SETTER, filtered to the
--    outbound/prospecting channel.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW GOLD.RPT_OUTBOUND_SETTER AS
SELECT
    TRIAGE_BOOKED_AT::DATE                                                       AS PROSPECT_DATE,
    COALESCE(SETTER_EMAIL, 'unassigned')                                         AS SETTER,
    COUNT(*)                                                                     AS OUTBOUND_BOOKED,
    COUNT(IFF(TRIAGE_TAKEN, 1, NULL))                                            AS OUTBOUND_TAKEN,
    DIV0(COUNT(IFF(TRIAGE_TAKEN, 1, NULL)), COUNT(*))                            AS SHOW_RATE,
    DIV0(COUNT(IFF(STRATEGY_CALL_BOOKED, 1, NULL)), NULLIF(COUNT(IFF(TRIAGE_TAKEN, 1, NULL)), 0)) AS PROSPECT_SET_RATE,
    COUNT(IFF(STRATEGY_CALL_BOOKED, 1, NULL))                                    AS STRATEGY_CALL_BOOKED,
    COUNT(IFF(STRATEGY_CALL_TAKEN, 1, NULL))                                     AS STRATEGY_CALL_TAKEN,
    -- Same fix as RPT_INBOUND_SETTER: offers / booked, not offers / taken.
    DIV0(COUNT(IFF(OFFER_PRESENTED, 1, NULL)), NULLIF(COUNT(IFF(STRATEGY_CALL_BOOKED, 1, NULL)), 0)) AS OFFER_RATE,
    COUNT(IFF(SALE, 1, NULL))                                                    AS TOTAL_SALES,
    DIV0(COUNT(IFF(SALE, 1, NULL)), NULLIF(COUNT(IFF(STRATEGY_CALL_BOOKED, 1, NULL)), 0)) AS SALE_RATE,
    DIV0(SUM(COALESCE(CONTRACTED_VALUE, 0)), NULLIF(COUNT(IFF(SALE, 1, NULL)), 0)) AS AVERAGE_ORDER_VALUE
FROM GOLD.LEAD_JOURNEY_SUMMARY
WHERE CHANNEL = 'Outbound'
GROUP BY TRIAGE_BOOKED_AT::DATE, SETTER_EMAIL;

-- ---------------------------------------------------------------------------
-- 2. RPT_CLOSER -- MONTH level, one row per closer per month. Only leads
--    that actually reached STRATEGY_CALL_BOOKED = TRUE have a closer.
--    Not-shown outcomes broken out into the same categories used in the
--    reference CLOSER_REPORT.csv (Admin Cancel / Cancel- Nurture /
--    Cancel- Not Interested / No Show / Reschedule) since the FIRST_
--    STRATEGY_OUTCOME captured per lead is a single specific outcome value.
-- ---------------------------------------------------------------------------
-- PENDING_NO_CALL_LOGGED_YET catches leads whose triage outcome said
-- "Strategy Call Scheduled" but who don't have a Strategy Call activity
-- logged yet (call hasn't happened, or falls outside the current data
-- window) -- without this bucket these leads counted toward CALL_BOOKED
-- but fell into none of the outcome buckets, so CALL_BOOKED didn't equal
-- the sum of the other columns (caught in QA: 5 of 113 rows failed that
-- check). CLOSER_NAME is labeled 'Unassigned' rather than left null,
-- matching how unattributed setter/closer rows were already handled
-- elsewhere in this pipeline (32_label_unattributed.sql).
CREATE OR REPLACE VIEW GOLD.RPT_CLOSER AS
SELECT
    DATE_TRUNC('MONTH', TRIAGE_BOOKED_AT)::DATE                                  AS CALL_MONTH,
    CLOSER_EMAIL                                                                 AS CLOSER,
    COALESCE(CLOSER_NAME, 'Unassigned')                                          AS CLOSER_NAME,
    COUNT(*)                                                                     AS CALL_BOOKED,
    COUNT(IFF(FIRST_STRATEGY_OUTCOME IN ('2. Admin Cancel'), 1, NULL))           AS ADMIN_CANCEL,
    COUNT(IFF(FIRST_STRATEGY_OUTCOME IN ('8. Cancel- Nurture', '7. Cancel- Nurture'), 1, NULL)) AS CANCEL_NURTURE,
    COUNT(IFF(FIRST_STRATEGY_OUTCOME IN ('3. Cancel- Not Interested', '2. Cancel- No Longer Interested'), 1, NULL)) AS CANCEL_NOT_INTERESTED,
    COUNT(IFF(FIRST_STRATEGY_OUTCOME IN ('4. No Show', '3. No Show'), 1, NULL))  AS NO_SHOW,
    COUNT(IFF(FIRST_STRATEGY_OUTCOME IN ('5. Reschedule', '4. Reschedule'), 1, NULL)) AS RESCHEDULE,
    COUNT(IFF(FIRST_STRATEGY_OUTCOME IS NULL, 1, NULL))                          AS PENDING_NO_CALL_LOGGED_YET,
    COUNT(IFF(STRATEGY_CALL_TAKEN, 1, NULL))                                     AS STRATEGY_CALL_SHOW,
    DIV0(COUNT(IFF(STRATEGY_CALL_TAKEN, 1, NULL)), COUNT(*))                     AS SHOW_RATE,
    COUNT(IFF(SALE, 1, NULL))                                                    AS SALE,
    DIV0(COUNT(IFF(SALE, 1, NULL)), COUNT(*))                                    AS SALE_RATE,
    DIV0(SUM(COALESCE(CONTRACTED_VALUE, 0)), NULLIF(COUNT(IFF(SALE, 1, NULL)), 0)) AS AVG_VALUE,
    SUM(COALESCE(CASH_COLLECTED, 0))                                             AS CASH_COLLECTED
FROM GOLD.LEAD_JOURNEY_SUMMARY
WHERE STRATEGY_CALL_BOOKED
GROUP BY DATE_TRUNC('MONTH', TRIAGE_BOOKED_AT)::DATE, CLOSER_EMAIL, COALESCE(CLOSER_NAME, 'Unassigned');

-- ---------------------------------------------------------------------------
-- 3. RPT_OBJECTIONS_FACED -- one row per closer per objection tag.
-- ---------------------------------------------------------------------------
-- "No Show" (and any other outcome-shaped value that leaks into this
-- custom field) is excluded -- it describes what happened on the call, not
-- a reason the lead objected, and it isn't part of the reference report's
-- own objection taxonomy (Money, Partner, Think About It, Logistical,
-- Time, Trust, Fear, No Obj, Other Coaches, Value, Hung Up, Wasn't Looking
-- For What We Offered). It was the single largest "objection" category by
-- volume before this fix (1,526 occurrences), which is itself the tell
-- that it's mislabeled outcome data leaking through, not a real objection.
CREATE OR REPLACE VIEW GOLD.RPT_OBJECTIONS_FACED AS
SELECT
    DATE_TRUNC('MONTH', TRIAGE_BOOKED_AT)::DATE                                  AS CALL_MONTH,
    CLOSER_EMAIL                                                                 AS CLOSER,
    COALESCE(CLOSER_NAME, 'Unassigned')                                          AS CLOSER_NAME,
    obj.value::STRING                                                            AS OBJECTION,
    COUNT(*)                                                                     AS OBJECTION_COUNT
FROM GOLD.LEAD_JOURNEY_SUMMARY,
     LATERAL FLATTEN(input => OBJECTIONS_FACED) obj
WHERE STRATEGY_CALL_BOOKED
  AND obj.value::STRING NOT IN ('No Show', 'Reschedule', 'Cancel')
GROUP BY DATE_TRUNC('MONTH', TRIAGE_BOOKED_AT)::DATE, CLOSER_EMAIL, COALESCE(CLOSER_NAME, 'Unassigned'), obj.value::STRING;

/* -----------------------------------------------------------------------------
   Validation -- run after deploying:

   -- 1. Jordon Eggleston, Aug 2026, closer-side acceptance test (should be
   --    close to CALL_BOOKED=44, STRATEGY_CALL_SHOW=12 from CLOSER_REPORT.csv):
   SELECT * FROM GOLD.RPT_CLOSER
   WHERE CLOSER_NAME = 'Jordon Eggleston' AND CALL_MONTH = '2026-08-01';

   -- 2. Confirm RPT_OUTBOUND_SETTER has no impossible combos, same pattern
   --    as the inbound check:
   SELECT * FROM GOLD.RPT_OUTBOUND_SETTER
   WHERE OUTBOUND_TAKEN = 0 AND STRATEGY_CALL_BOOKED > 0;

   -- 3. Spot check objections against CLOSER_LEVEL reference file for one
   --    closer, e.g. Cody Guevara.
   SELECT * FROM GOLD.RPT_OBJECTIONS_FACED WHERE CLOSER_NAME = 'Cody Guevara';
   ----------------------------------------------------------------------------- */
