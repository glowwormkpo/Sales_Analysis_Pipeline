USE DATABASE SALES_ANALYTICS;

-- Run this first, just this one query -- paste the single value it returns.
-- (Fixed: previous version referenced JSON_OBJECT:activity_at, which doesn't
-- exist at that level -- activity_at lives on each flattened VALUE, not the
-- raw top-level payload. That's why it came back NULL despite the row count
-- working.)
SELECT MAX(TRY_CAST(f.VALUE:activity_at::STRING AS TIMESTAMP_NTZ)) AS latest_in_bronze
FROM BRONZE.LEAD_ACTIVITIES_RAW,
     LATERAL FLATTEN(input => JSON_OBJECT:data) f
WHERE TRY_CAST(f.VALUE:activity_at::STRING AS TIMESTAMP_NTZ) IS NOT NULL;
