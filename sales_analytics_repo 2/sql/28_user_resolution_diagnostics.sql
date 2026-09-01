/* =============================================================================
   Sales Analytics Pipeline - Reviewer-Flagged Issue Diagnostics (corrected)
   28_user_resolution_diagnostics.sql

   Query 3 in file 26 checked whether WRAPPED_ACTIVITIES:"Setter"/"Closer"
   resolve against CLOSE_CRM_USERS_PROCESSED -- but OUTBOUND_PROSPECT_DIALS'
   SETTER_CLOSER_EMAIL actually comes from DEA_INTERNAL_EMAIL, which resolves
   from the activity's own raw user_id field (LEADS_ACTIVITIES_SUMMARY.USER_ID),
   a completely different field. This corrects that and checks a second
   hypothesis: whether CLOSE_CRM_USERS_RAW (loaded 2025-11-25) is stale
   relative to activity data that runs through 2026, so newer staff never
   made it into CLOSE_CRM_USERS_PROCESSED at all.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

-- 1) USER_ID resolution rate, broken down by activity type. If Prospecting
--    Activity's user_id is mostly NULL (not just unmatched), that confirms
--    the dialer integration doesn't set it. If it's populated but still
--    unmatched, that points to a stale/incomplete user roster instead.
SELECT
    s.CUSTOM_ACTIVITY,
    COUNT(*)                                              AS total_rows,
    COUNT_IF(s.USER_ID IS NULL)                           AS null_user_id,
    COUNT_IF(s.USER_ID IS NOT NULL AND u.USER_ID IS NULL) AS user_id_present_but_unmatched,
    COUNT_IF(u.USER_ID IS NOT NULL)                       AS matched
FROM SILVER.LEADS_ACTIVITIES_SUMMARY s
LEFT JOIN SILVER.CLOSE_CRM_USERS_PROCESSED u ON u.USER_ID = s.USER_ID
WHERE s.TYPE = 'CustomActivity'
GROUP BY s.CUSTOM_ACTIVITY
ORDER BY total_rows DESC;

-- 2) Is the specific repeatedly-seen unmatched setter ID actually absent
--    from CLOSE_CRM_USERS_PROCESSED, or just a formatting mismatch?
SELECT * FROM SILVER.CLOSE_CRM_USERS_PROCESSED
WHERE USER_ID = 'user_p62zh76kPDTEjh5K8myfYtefWxYKBWZ5xd01sehdi2H';

-- 3) How stale is the user roster vs. the activity data it needs to cover?
SELECT
    (SELECT MAX(INSERT_DATE) FROM BRONZE.CLOSE_CRM_USERS_RAW)      AS user_roster_loaded_at,
    (SELECT MIN(ACTIVITY_AT) FROM SILVER.LEADS_ACTIVITIES_SUMMARY) AS earliest_activity,
    (SELECT MAX(ACTIVITY_AT) FROM SILVER.LEADS_ACTIVITIES_SUMMARY) AS latest_activity,
    (SELECT COUNT(DISTINCT USER_ID) FROM SILVER.CLOSE_CRM_USERS_PROCESSED) AS users_in_roster;

-- 4) SETTER null rate on ALL_STRATEGIES_DETAILS specifically (query 2 in
--    file 26 only checked CLOSER_NAME -- SETTER has a different fallback
--    chain and wasn't checked yet).
SELECT
    COUNT(*)                                    AS total_rows,
    COUNT_IF(SETTER IS NULL OR SETTER = '')      AS null_or_blank_setter,
    ROUND(COUNT_IF(SETTER IS NULL OR SETTER = '') * 100.0 / COUNT(*), 1) AS pct_null
FROM GOLD.ALL_STRATEGIES_DETAILS;
