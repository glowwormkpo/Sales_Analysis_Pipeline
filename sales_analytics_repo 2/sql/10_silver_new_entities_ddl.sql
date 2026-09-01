/* =============================================================================
   Sales Analytics Pipeline - Phase 4 (Real Data)
   10_silver_new_entities_ddl.sql

   DDL for all new Silver entities required by the real Postgres source data.
   Field lists are drawn directly from real sample rows inspected in Bronze,
   not guessed -- kept to the fields with clear analytical value rather than
   every single field Close CRM returns (some activity payloads carry 60+
   fields, many dialer/telephony-internal and not useful for reporting).

   Covers:
     - CALLS, SMS_MESSAGES, MEETINGS, NOTES, LEAD_MERGES, LEAD_CREATED_EVENTS
       (new activity-type tables -- lead_activites_raw mixes all activity
       types in one array per lead; existing CUSTOM_ACTIVITIES_ALL_LEADS_DETAILS
       and LEAD_ACTIVITIES_EMAIL pipelines are adapted, not rebuilt, to filter
       the correct _type out of that same mixed stream)
     - LEADS_PROCESSED, CONTACTS, OPPORTUNITIES, TASKS
       (leads_raw is NOT wrapped in a "data" array like the activity tables --
       each row is one lead record directly, with contacts/opportunities/tasks
       as embedded arrays and an already human-readable "custom" object)
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

-- ---------------------------------------------------------------------------
-- Activity-type tables (sourced from BRONZE.LEAD_ACTIVITIES_RAW, filtered by
-- _type during the Silver load -- see 11_silver_new_entities_load.sql)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SILVER.CALLS (
    ACTIVITY_ID                    STRING PRIMARY KEY,
    LEAD_ID                        STRING,
    CONTACT_ID                     STRING,
    USER_ID                        STRING,
    USER_NAME                      STRING,
    DIRECTION                      STRING,
    STATUS                         STRING,
    DISPOSITION                    STRING,
    DURATION                       NUMBER,
    RECORDING_DURATION             NUMBER,
    PHONE                          STRING,
    LOCAL_PHONE                    STRING,
    REMOTE_PHONE                   STRING,
    NOTE                           STRING,
    OUTCOME_ID                     STRING,
    OUTCOME_REASON                 STRING,
    OUTCOME_AUTOFILL_REASONING     STRING,
    OUTCOME_AUTOFILL_CONFIDENCE    STRING,
    HAS_RECORDING                  BOOLEAN,
    RECORDING_URL                  STRING,
    CALL_METHOD                    STRING,
    SOURCE                         STRING,
    COST                           STRING,
    ACTIVITY_AT                    TIMESTAMP_NTZ,
    DATE_ANSWERED                  TIMESTAMP_NTZ,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY                     STRING,
    CREATED_BY_NAME                STRING,
    ORGANIZATION_ID                STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    MD5_HASH                       STRING
);

CREATE TABLE IF NOT EXISTS SILVER.SMS_MESSAGES (
    ACTIVITY_ID                    STRING PRIMARY KEY,
    LEAD_ID                        STRING,
    CONTACT_ID                     STRING,
    USER_ID                        STRING,
    USER_NAME                      STRING,
    DIRECTION                      STRING,
    STATUS                         STRING,
    TEXT                           STRING,
    LOCAL_PHONE                    STRING,
    REMOTE_PHONE                   STRING,
    TEMPLATE_ID                    STRING,
    SEQUENCE_ID                    STRING,
    SEQUENCE_NAME                  STRING,
    ERROR_MESSAGE                  STRING,
    DATE_SENT                      TIMESTAMP_NTZ,
    ACTIVITY_AT                    TIMESTAMP_NTZ,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY                     STRING,
    ORGANIZATION_ID                STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    MD5_HASH                       STRING
);

CREATE TABLE IF NOT EXISTS SILVER.MEETINGS (
    ACTIVITY_ID                    STRING PRIMARY KEY,
    LEAD_ID                        STRING,
    CONTACT_ID                     STRING,
    USER_ID                        STRING,
    USER_NAME                      STRING,
    TITLE                          STRING,
    STATUS                         STRING,
    SOURCE                         STRING,
    NOTE                           STRING,
    LOCATION                       STRING,
    STARTS_AT                      TIMESTAMP_NTZ,
    ENDS_AT                        TIMESTAMP_NTZ,
    DURATION                       NUMBER,
    ACTUAL_DURATION                NUMBER,
    IS_RECURRING                   BOOLEAN,
    ATTENDEES                      VARIANT,
    CALENDAR_EVENT_UIDS            VARIANT,
    PROVIDER_CALENDAR_TYPE         STRING,
    OUTCOME_ID                     STRING,
    OUTCOME_REASON                 STRING,
    ACTIVITY_AT                    TIMESTAMP_NTZ,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY                     STRING,
    ORGANIZATION_ID                STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    MD5_HASH                       STRING
);

CREATE TABLE IF NOT EXISTS SILVER.NOTES (
    ACTIVITY_ID                    STRING PRIMARY KEY,
    LEAD_ID                        STRING,
    CONTACT_ID                     STRING,
    USER_ID                        STRING,
    USER_NAME                      STRING,
    NOTE                           STRING,
    NOTE_HTML                      STRING,
    TITLE                          STRING,
    PINNED                         BOOLEAN,
    ACTIVITY_AT                    TIMESTAMP_NTZ,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY                     STRING,
    ORGANIZATION_ID                STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    MD5_HASH                       STRING
);

CREATE TABLE IF NOT EXISTS SILVER.LEAD_MERGES (
    ACTIVITY_ID                    STRING PRIMARY KEY,
    LEAD_ID                        STRING,
    DESTINATION_LEAD_ID            STRING,
    DESTINATION_DISPLAY_NAME       STRING,
    SOURCE_LEAD_ID                 STRING,
    SOURCE_DISPLAY_NAME            STRING,
    MERGE_STATUS                   STRING,
    ERROR_MESSAGE                  STRING,
    USER_ID                        STRING,
    USER_NAME                      STRING,
    ACTIVITY_AT                    TIMESTAMP_NTZ,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY                     STRING,
    ORGANIZATION_ID                STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    MD5_HASH                       STRING
);

CREATE TABLE IF NOT EXISTS SILVER.LEAD_CREATED_EVENTS (
    ACTIVITY_ID                    STRING PRIMARY KEY,
    LEAD_ID                        STRING,
    USER_ID                        STRING,
    USER_NAME                      STRING,
    SOURCE                         STRING,
    IMPORT_ID                      STRING,
    ACTIVITY_AT                    TIMESTAMP_NTZ,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY                     STRING,
    ORGANIZATION_ID                STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    MD5_HASH                       STRING
);

-- ---------------------------------------------------------------------------
-- Lead entity tables (sourced directly from BRONZE.LEADS_RAW -- no "data"
-- wrapper; each row already is one lead, with contacts/opportunities/tasks
-- as embedded arrays flattened out during the Silver load)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SILVER.LEADS_PROCESSED (
    LEAD_ID                        STRING PRIMARY KEY,
    NAME                           STRING,
    DISPLAY_NAME                   STRING,
    STATUS_ID                      STRING,
    STATUS_LABEL                   STRING,
    DESCRIPTION                    STRING,
    URL                            STRING,
    HTML_URL                       STRING,
    CUSTOM                         VARIANT,
    ORGANIZATION_ID                STRING,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY                     STRING,
    CREATED_BY_NAME                STRING,
    UPDATED_BY                     STRING,
    UPDATED_BY_NAME                STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    MD5_HASH                       STRING
);

CREATE TABLE IF NOT EXISTS SILVER.CONTACTS (
    CONTACT_ID                     STRING PRIMARY KEY,
    LEAD_ID                        STRING,
    NAME                           STRING,
    DISPLAY_NAME                   STRING,
    TITLE                          STRING,
    EMAILS                         VARIANT,
    PHONES                         VARIANT,
    TIMEZONE                       STRING,
    ORGANIZATION_ID                STRING,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY                     STRING,
    UPDATED_BY                     STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    MD5_HASH                       STRING
);

CREATE TABLE IF NOT EXISTS SILVER.OPPORTUNITIES (
    OPPORTUNITY_ID                 STRING PRIMARY KEY,
    LEAD_ID                        STRING,
    CONTACT_ID                     STRING,
    CONTACT_NAME                   STRING,
    PIPELINE_ID                    STRING,
    PIPELINE_NAME                  STRING,
    STATUS_ID                      STRING,
    STATUS_LABEL                   STRING,
    STATUS_DISPLAY_NAME            STRING,
    STATUS_TYPE                    STRING,
    VALUE                          NUMBER,
    VALUE_CURRENCY                 STRING,
    VALUE_PERIOD                   STRING,
    VALUE_FORMATTED                STRING,
    EXPECTED_VALUE                 NUMBER,
    CONFIDENCE                     NUMBER,
    DATE_WON                       DATE,
    DATE_LOST                      DATE,
    USER_ID                        STRING,
    USER_NAME                      STRING,
    NOTE                           STRING,
    ORGANIZATION_ID                STRING,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY                     STRING,
    UPDATED_BY                     STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    MD5_HASH                       STRING
);

CREATE TABLE IF NOT EXISTS SILVER.TASKS (
    TASK_ID                        STRING PRIMARY KEY,
    LEAD_ID                        STRING,
    LEAD_NAME                      STRING,
    CONTACT_ID                     STRING,
    CONTACT_NAME                   STRING,
    TEXT                           STRING,
    TASK_DATE                      DATE,
    DUE_DATE                       DATE,
    PRIORITY                       STRING,
    IS_COMPLETE                    BOOLEAN,
    IS_DATELESS                    BOOLEAN,
    ASSIGNED_TO                    STRING,
    ASSIGNED_TO_NAME               STRING,
    SEQUENCE_ID                    STRING,
    SEQUENCE_SUBSCRIPTION_ID       STRING,
    VIEW                           STRING,
    ORGANIZATION_ID                STRING,
    DATE_CREATED                   TIMESTAMP_NTZ,
    DATE_UPDATED                   TIMESTAMP_NTZ,
    CREATED_BY                     STRING,
    INSERT_DATE                    TIMESTAMP_NTZ,
    UPDATE_DATE                    TIMESTAMP_NTZ,
    MD5_HASH                       STRING
);
