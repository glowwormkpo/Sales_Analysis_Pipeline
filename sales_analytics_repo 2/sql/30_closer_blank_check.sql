/* =============================================================================
   Sales Analytics Pipeline - Reviewer-Flagged Issue Diagnostics
   30_closer_blank_check.sql

   Correction: file 26's query 2 checked COUNT_IF(CLOSER_NAME IS NULL) and
   got 0%, which looked like clean attribution. But CLOSER_NAME is built via
   TRIM(COALESCE(first,'') || ' ' || COALESCE(last,'')) chains that default
   to an empty string, not NULL, whenever the underlying join fails -- so
   that check could never have found a real gap even if one exists. This
   redoes it correctly (matching how query 4 tested SETTER), and also checks
   CLOSER_EMAIL and the Closer-report-relevant view (which is what actually
   feeds the blank-name bucket seen in RPT_CLOSER_DAILY).
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA GOLD;

SELECT
    COUNT(*)                                                  AS total_rows,
    COUNT_IF(CLOSER_NAME IS NULL OR CLOSER_NAME = '')          AS null_or_blank_closer_name,
    ROUND(COUNT_IF(CLOSER_NAME IS NULL OR CLOSER_NAME = '') * 100.0 / COUNT(*), 1) AS pct_null_name,
    COUNT_IF(CLOSER_EMAIL IS NULL OR CLOSER_EMAIL = '')        AS null_or_blank_closer_email,
    ROUND(COUNT_IF(CLOSER_EMAIL IS NULL OR CLOSER_EMAIL = '') * 100.0 / COUNT(*), 1) AS pct_null_email
FROM GOLD.ALL_STRATEGIES_DETAILS;
