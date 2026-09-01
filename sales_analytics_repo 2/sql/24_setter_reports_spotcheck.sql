/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data) - Verification
   24_setter_reports_spotcheck.sql

   RPT_INBOUND_SETTER and RPT_OUTBOUND_SETTER were only ever defined once, in
   08_export_unload.sql (the original synthetic-data build), and were never
   rewritten for real data the way RPT_CLOSER / RPT_OBJECTIONS_FACED were.
   Unlike those two, their SQL has no hardcoded outcome strings or synthetic
   type IDs -- they read only the already-normalized semantic columns
   (STATUS, OFFER_PRESENTED, STRATEGY_CALL_BOOKED, CONTRACTED_VALUE) off of
   GOLD.INBOUND_STRATEGIES_BOOKED / OUTBOUND_STRATEGIES_BOOKED /
   ALL_STRATEGIES_DETAILS / OUTBOUND_PROSPECT_DIALS / SALES_DETAILS. Since
   views aren't materialized in Snowflake, once those five upstream views
   were swapped to their real-data definitions (file 15), RPT_INBOUND_SETTER
   and RPT_OUTBOUND_SETTER should have started reading real data automatically
   with zero code changes needed.

   This just confirms that theory holds by cross-checking each report's
   totals against its own upstream ground-truth view.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------------
-- Inbound Setter Report
-- INBOUND_BOOKED is COUNT(DISTINCT LEAD_ID) grouped by (date, setter); summed
-- across all groups it should equal the row count of INBOUND_STRATEGIES_BOOKED
-- itself, since each lead has one triage call under one date/setter.
-- ---------------------------------------------------------------------------
SELECT 'RPT_INBOUND_SETTER: SUM(INBOUND_BOOKED)' AS metric, SUM(INBOUND_BOOKED) AS value FROM GOLD.RPT_INBOUND_SETTER
UNION ALL
SELECT 'INBOUND_STRATEGIES_BOOKED: row count (ground truth)', COUNT(*) FROM GOLD.INBOUND_STRATEGIES_BOOKED
UNION ALL
SELECT 'RPT_INBOUND_SETTER: SUM(STRATEGY_CALL_TAKEN)', SUM(STRATEGY_CALL_TAKEN) FROM GOLD.RPT_INBOUND_SETTER
UNION ALL
SELECT 'RPT_INBOUND_SETTER: SUM(TOTAL_SALES)', SUM(TOTAL_SALES) FROM GOLD.RPT_INBOUND_SETTER;

-- ---------------------------------------------------------------------------
-- Outbound Setter Report
-- TOTAL_OUTBOUND_CALLS sums DIAL_COUNT per lead/setter/date, so its grand
-- total should equal the row count of OUTBOUND_PROSPECT_DIALS itself.
-- ---------------------------------------------------------------------------
SELECT 'RPT_OUTBOUND_SETTER: SUM(TOTAL_OUTBOUND_CALLS)' AS metric, SUM(TOTAL_OUTBOUND_CALLS) AS value FROM GOLD.RPT_OUTBOUND_SETTER
UNION ALL
SELECT 'OUTBOUND_PROSPECT_DIALS: row count (ground truth)', COUNT(*) FROM GOLD.OUTBOUND_PROSPECT_DIALS
UNION ALL
SELECT 'RPT_OUTBOUND_SETTER: SUM(TOTAL_CLOSER_SHOW)', SUM(TOTAL_CLOSER_SHOW) FROM GOLD.RPT_OUTBOUND_SETTER
UNION ALL
SELECT 'RPT_OUTBOUND_SETTER: SUM(TOTAL_SALE)', SUM(TOTAL_SALE) FROM GOLD.RPT_OUTBOUND_SETTER;

-- ---------------------------------------------------------------------------
-- Cross-check against the ground-truth sales total (178, per SALES_DETAILS).
-- Inbound TOTAL_SALES + Outbound TOTAL_SALE won't necessarily equal 178
-- exactly -- a sold lead only shows up in one cohort's sum if it went through
-- that specific booking path, and any lead that reached Sale without a
-- traceable Inbound/Outbound booking row (e.g. booked before this pipeline's
-- data window) won't appear in either. Close to 178, with any gap explained
-- by that edge case, is the expected healthy result -- not necessarily an
-- exact match.
-- ---------------------------------------------------------------------------
SELECT 'RPT_INBOUND_SETTER TOTAL_SALES + RPT_OUTBOUND_SETTER TOTAL_SALE' AS metric,
       (SELECT SUM(TOTAL_SALES) FROM GOLD.RPT_INBOUND_SETTER) + (SELECT SUM(TOTAL_SALE) FROM GOLD.RPT_OUTBOUND_SETTER) AS value
UNION ALL
SELECT 'SALES_DETAILS row count (ground truth)', COUNT(*) FROM GOLD.SALES_DETAILS;
