/* =============================================================================
   Sales Analytics Pipeline - Phase 3
   02_bronze_ddl.sql

   Bronze tables: raw JSON landing, no business logic applied. Column structure
   matches the provided Snowflake Data Architecture Model exactly (Phase 1/2,
   Sec. 4 / 3): JSON_OBJECT VARIANT + INSERT_DATE only. LEADS_RAW is the one
   addition beyond the original model (Phase 1 decision, Sec. 4.1) -- ingested
   here, modeling deferred until a report needs it.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA BRONZE;

CREATE TABLE IF NOT EXISTS BRONZE.LEAD_ACTIVITIES_RAW (
    JSON_OBJECT   VARIANT      NOT NULL,
    INSERT_DATE   TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw daily lead activity payloads (Triage, Strategy Call, SMS, Calls, Meetings, Notes). Append-only; same activity re-appears across daily batches.';

CREATE TABLE IF NOT EXISTS BRONZE.CUSTOM_ACTIVITIES_RAW (
    JSON_OBJECT   VARIANT      NOT NULL,
    INSERT_DATE   TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw daily custom activity type / outcome dictionary payloads.';

CREATE TABLE IF NOT EXISTS BRONZE.CLOSE_CRM_USERS_RAW (
    JSON_OBJECT   VARIANT      NOT NULL,
    INSERT_DATE   TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw daily CRM user/setter/closer roster payloads.';

CREATE TABLE IF NOT EXISTS BRONZE.LEADS_RAW (
    JSON_OBJECT   VARIANT      NOT NULL,
    INSERT_DATE   TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw daily lead/contact/opportunity/task payloads. Added per Phase 1 Sec. 4.1 decision -- landed for optionality, not yet modeled past Bronze.';
