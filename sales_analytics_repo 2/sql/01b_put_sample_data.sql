/* =============================================================================
   Sales Analytics Pipeline - Phase 3
   01b_put_sample_data.sql

   Run this with SnowSQL (snowsql -f 01b_put_sample_data.sql --variable...),
   from the sql/ directory so the relative sample_data/ paths resolve. This
   pushes all 7 simulated days of source files up to the internal stage in
   the dt=YYYY-MM-DD subfolder layout that 03_bronze_copy_into.sql expects.

   Snowsight alternative: use "Upload Files" on stage BRONZE.RAW_LANDING and
   manually create each dt=YYYY-MM-DD subfolder per table, one day at a time,
   to keep the daily-batch simulation honest.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA BRONZE;

-- Day 1 (2026-08-03)
PUT file://sample_data/day_1/lead_activites_raw.json @BRONZE.RAW_LANDING/lead_activites_raw/dt=2026-08-03/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_1/custom_activites_raw.json @BRONZE.RAW_LANDING/custom_activites_raw/dt=2026-08-03/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_1/close_crm_users_raw.json @BRONZE.RAW_LANDING/close_crm_users_raw/dt=2026-08-03/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_1/leads_raw.json @BRONZE.RAW_LANDING/leads_raw/dt=2026-08-03/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Day 2 (2026-08-04)
PUT file://sample_data/day_2/lead_activites_raw.json @BRONZE.RAW_LANDING/lead_activites_raw/dt=2026-08-04/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_2/custom_activites_raw.json @BRONZE.RAW_LANDING/custom_activites_raw/dt=2026-08-04/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_2/close_crm_users_raw.json @BRONZE.RAW_LANDING/close_crm_users_raw/dt=2026-08-04/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_2/leads_raw.json @BRONZE.RAW_LANDING/leads_raw/dt=2026-08-04/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Day 3 (2026-08-05)
PUT file://sample_data/day_3/lead_activites_raw.json @BRONZE.RAW_LANDING/lead_activites_raw/dt=2026-08-05/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_3/custom_activites_raw.json @BRONZE.RAW_LANDING/custom_activites_raw/dt=2026-08-05/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_3/close_crm_users_raw.json @BRONZE.RAW_LANDING/close_crm_users_raw/dt=2026-08-05/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_3/leads_raw.json @BRONZE.RAW_LANDING/leads_raw/dt=2026-08-05/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Day 4 (2026-08-06)
PUT file://sample_data/day_4/lead_activites_raw.json @BRONZE.RAW_LANDING/lead_activites_raw/dt=2026-08-06/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_4/custom_activites_raw.json @BRONZE.RAW_LANDING/custom_activites_raw/dt=2026-08-06/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_4/close_crm_users_raw.json @BRONZE.RAW_LANDING/close_crm_users_raw/dt=2026-08-06/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_4/leads_raw.json @BRONZE.RAW_LANDING/leads_raw/dt=2026-08-06/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Day 5 (2026-08-07)
PUT file://sample_data/day_5/lead_activites_raw.json @BRONZE.RAW_LANDING/lead_activites_raw/dt=2026-08-07/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_5/custom_activites_raw.json @BRONZE.RAW_LANDING/custom_activites_raw/dt=2026-08-07/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_5/close_crm_users_raw.json @BRONZE.RAW_LANDING/close_crm_users_raw/dt=2026-08-07/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_5/leads_raw.json @BRONZE.RAW_LANDING/leads_raw/dt=2026-08-07/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Day 6 (2026-08-08)
PUT file://sample_data/day_6/lead_activites_raw.json @BRONZE.RAW_LANDING/lead_activites_raw/dt=2026-08-08/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_6/custom_activites_raw.json @BRONZE.RAW_LANDING/custom_activites_raw/dt=2026-08-08/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_6/close_crm_users_raw.json @BRONZE.RAW_LANDING/close_crm_users_raw/dt=2026-08-08/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_6/leads_raw.json @BRONZE.RAW_LANDING/leads_raw/dt=2026-08-08/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Day 7 (2026-08-09)
PUT file://sample_data/day_7/lead_activites_raw.json @BRONZE.RAW_LANDING/lead_activites_raw/dt=2026-08-09/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_7/custom_activites_raw.json @BRONZE.RAW_LANDING/custom_activites_raw/dt=2026-08-09/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_7/close_crm_users_raw.json @BRONZE.RAW_LANDING/close_crm_users_raw/dt=2026-08-09/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT file://sample_data/day_7/leads_raw.json @BRONZE.RAW_LANDING/leads_raw/dt=2026-08-09/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

