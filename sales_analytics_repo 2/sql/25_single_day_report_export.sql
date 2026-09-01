/* =============================================================================
   Sales Analytics Pipeline - Reviewer Handoff
   25_single_day_report_export.sql

   Pulls all four required KPI reports (Section 6 of the requirements doc)
   filtered to a single day, so each can be downloaded as its own CSV for a
   reviewer to spot-check.

   How to use in Snowsight:
     1. Run the whole script (or each SELECT one at a time).
     2. For each result grid, click the "..." menu in the top-right of the
        results pane -> Download -> .csv.
     3. Name the four files something like:
        inbound_setter_<date>.csv, outbound_setter_<date>.csv,
        closer_<date>.csv, objections_faced_<date>.csv

   REPORT_DATE is set to 2026-07-03, picked via 27_find_good_example_date.sql
   as a day with realistic, non-outlier funnel volume (190 leads triaged, 43
   showed, 14 sold) -- unlike the first attempt (2026-08-17, chosen as "most
   recent sale date"), which picked a TRIAGE_DATE cohort that hadn't had time
   to reach Show/Sale yet, making the Inbound report look broken when it
   wasn't. 2026-08-15/08-14 were also ruled out here -- each has 5-10x the
   triage volume of every other day in the dataset, almost certainly a
   backfill/bulk-import artifact rather than a real single day, so not a fair
   example either. Swap in any specific date you'd rather use instead -- just
   replace the SET statement with, e.g.:
     SET REPORT_DATE = '2026-08-10';

   Note: it's normal for one or two of these to come back with zero rows on
   a given day (e.g. a day with a sale but no outbound dials logged) -- these
   activity types don't all necessarily occur together every single day.
   Zero rows isn't a defect, it's an accurate reflection of that day's data.

   Note on grain: the requirements doc's own Closer Report (RPT_CLOSER) rolls
   up to month, not day, so it can't be filtered to a single date the way the
   other three can. This uses RPT_CLOSER_DAILY (added in file 19/22) instead,
   which is the same report at day grain -- better suited to a single-day
   spot check.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

SET REPORT_DATE = '2026-07-03';

SELECT $REPORT_DATE AS report_date_used;

-- 1) Inbound Setter Report
SELECT * FROM GOLD.RPT_INBOUND_SETTER WHERE TRIAGE_DATE = $REPORT_DATE ORDER BY SETTER;

-- 2) Outbound Setter Report
SELECT * FROM GOLD.RPT_OUTBOUND_SETTER WHERE DIAL_DATE = $REPORT_DATE ORDER BY SETTER;

-- 3) Closer Report (day grain)
SELECT * FROM GOLD.RPT_CLOSER_DAILY WHERE CALL_DATE = $REPORT_DATE ORDER BY CLOSER_NAME;

-- 4) Objections Faced Report
SELECT * FROM GOLD.RPT_OBJECTIONS_FACED WHERE ACTIVITY_DATE = $REPORT_DATE ORDER BY CLOSER_NAME;
