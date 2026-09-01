/* =============================================================================
   Sales Analytics Pipeline - Reviewer-Flagged Issue Diagnostics
   27_find_good_example_date.sql

   The 2026-08-17 example day looked broken in RPT_INBOUND_SETTER because
   TRIAGE_DATE and DATE_OF_SALE are unrelated points in a lead's journey --
   2026-08-17 was picked as "most recent date with a sale," but that sale's
   own triage call almost certainly happened well before 2026-08-17, so
   filtering Inbound to "leads triaged on 2026-08-17" showed a funnel that
   hadn't had time to play out yet (19 of 21 triage-booked leads that day
   have no Strategy Call logged at all).

   This finds a TRIAGE_DATE where a meaningful number of that day's
   triage-booked leads went on to actually Show for their Strategy Call --
   i.e. a day where the funnel has had enough time to resolve, so a
   single-day cross-section will show real, non-zero numbers all the way
   down to Offer/Sale.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

SELECT
    t.ACTIVITY_LOG_DATE                                      AS triage_date,
    COUNT(DISTINCT t.LEAD_ID)                                 AS leads_triaged,
    COUNT(DISTINCT IFF(asd.STATUS = 'Show', t.LEAD_ID, NULL)) AS leads_showed,
    COUNT(DISTINCT sd.LEAD_ID)                                AS leads_sold
FROM GOLD.INBOUND_STRATEGIES_BOOKED t
LEFT JOIN GOLD.ALL_STRATEGIES_DETAILS asd ON asd.LEAD_ID = t.LEAD_ID
LEFT JOIN GOLD.SALES_DETAILS sd ON sd.LEAD_ID = t.LEAD_ID
GROUP BY t.ACTIVITY_LOG_DATE
HAVING COUNT(DISTINCT IFF(asd.STATUS = 'Show', t.LEAD_ID, NULL)) > 0
ORDER BY leads_showed DESC, triage_date DESC
LIMIT 20;
