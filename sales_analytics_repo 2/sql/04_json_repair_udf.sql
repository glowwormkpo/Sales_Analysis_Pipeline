/* =============================================================================
   Sales Analytics Pipeline - Phase 3
   04_json_repair_udf.sql

   Fixes the malformation described in the requirements. Confirmed against
   the explanation video + transcript: it's not a single stringified blob of
   ALL custom fields on an activity -- it's specifically the value of
   multi-select custom fields (e.g. "Objections Faced"), which Close returns
   as a Python-list-repr STRING delimited with single quotes instead of a
   real JSON array:

     ['Money', 'Wasn't Looking For What We Offered']

   A naive global replace of ' with " corrupts genuine apostrophes inside free
   text (Wasn't -> Wasn"t), breaking the parse. The fix:
     1. Protect apostrophes that sit between two word characters (contractions,
        possessives -- can't, wasn't, lead's) with a placeholder token.
     2. Swap every remaining single quote (the structural, JSON-delimiter ones)
        for a double quote.
     3. Restore the placeholder tokens back to literal apostrophes -- now
        safely inside double-quoted strings, where no escaping is required.

   Two functions are provided:
     - REPAIR_SINGLE_QUOTED_JSON(STRING) -> STRING    (fixed text, for debugging)
     - REPAIR_AND_PARSE_JSON(STRING)     -> VARIANT   (fixed + parsed; this is
       what 05_silver_transient_flatten.sql actually calls)

   REPAIR_AND_PARSE_JSON returns NULL on any row it still can't parse rather
   than aborting the batch -- see the QC query at the bottom to find those rows.
   ============================================================================= */

USE DATABASE SALES_ANALYTICS;
USE SCHEMA SILVER;

CREATE OR REPLACE FUNCTION SILVER.REPAIR_SINGLE_QUOTED_JSON(RAW_STRING STRING)
RETURNS STRING
LANGUAGE JAVASCRIPT
STRICT
COMMENT = 'Converts single-quoted pseudo-JSON text to valid double-quoted JSON text, protecting real apostrophes (contractions/possessives) in free-text values.'
AS
$$
    var s = String(RAW_STRING);
    var PLACEHOLDER = "@@APOS@@";
    // Step 1: protect apostrophes that sit between two word characters
    // (e.g. can't, wasn't, don't, lead's) with a placeholder that will not
    // collide with ordinary source text.
    var protectedStr = s.replace(/(\w)'(\w)/g, "$1" + PLACEHOLDER + "$2");
    // Step 2: every remaining single quote is a structural JSON delimiter
    // (opens/closes a key or a value) -- swap it for a double quote.
    var swapped = protectedStr.split("'").join('"');
    // Step 3: restore the protected apostrophes as literal characters.
    var restored = swapped.split(PLACEHOLDER).join("'");
    return restored;
$$;

CREATE OR REPLACE FUNCTION SILVER.REPAIR_AND_PARSE_JSON(RAW_STRING STRING)
RETURNS VARIANT
LANGUAGE JAVASCRIPT
STRICT
COMMENT = 'Repairs single-quoted pseudo-JSON text and parses it to VARIANT in one step. Returns NULL (does not throw) if the repaired text still fails to parse.'
AS
$$
    var s = String(RAW_STRING);
    var PLACEHOLDER = "@@APOS@@";
    var protectedStr = s.replace(/(\w)'(\w)/g, "$1" + PLACEHOLDER + "$2");
    var swapped = protectedStr.split("'").join('"');
    var restored = swapped.split(PLACEHOLDER).join("'");
    try {
        return JSON.parse(restored);
    } catch (e) {
        return null;
    }
$$;

/* -----------------------------------------------------------------------------
   Smoke test -- run after creating the functions. Standard SQL string
   escaping: every literal single quote in the source text is doubled ('').

   Test 1: an object-shaped payload (kept for regression coverage -- the repair
   logic is purposely generic and doesn't care whether the JSON is an object or
   an array; JSON.parse handles both the same way).
   Test 2: the shape that actually occurs in this pipeline -- a multi-select
   custom field value ("Objections Faced"), a single-quoted Python-list-repr
   STRING whose one element contains a real apostrophe.
   ----------------------------------------------------------------------------- */
SELECT
    src,
    SILVER.REPAIR_SINGLE_QUOTED_JSON(src)  AS repaired_text,
    SILVER.REPAIR_AND_PARSE_JSON(src)      AS parsed
FROM (
    SELECT '{''Triage Call Outcome'': ''1. Strategy Call Scheduled'', ''Notes'': ''Client can''t talk long but is interested''}' AS src
    UNION ALL
    SELECT '[''Wasn''t Looking For What We Offered'', ''Money'']'
) t;
-- Expected repaired_text (row 1):
-- {"Triage Call Outcome": "1. Strategy Call Scheduled", "Notes": "Client can't talk long but is interested"}
-- Expected repaired_text (row 2):
-- ["Wasn't Looking For What We Offered", "Money"]
-- Expected parsed (row 2): a 2-element VARIANT ARRAY, apostrophe intact in element 1.

/* -----------------------------------------------------------------------------
   QC: find any custom.cf_<hash> field value in this batch that LOOKS like a
   single-quoted list (starts with '[' ) but still fails to repair+parse, so it
   can be reviewed and the repair heuristic refined (Phase 2 Sec. 8 open item).
   Run this after 05_silver_transient_flatten.sql has populated the transient
   tables.
   -----------------------------------------------------------------------------
SELECT
    t.JSON_OBJECT:id::STRING AS ACTIVITY_ID,
    f.key                    AS FIELD_KEY,
    f.value::STRING          AS RAW_VALUE
FROM SILVER.LEAD_ACTIVITIES_PROCESSED_TRANSIENT t,
     LATERAL FLATTEN(input => t.JSON_OBJECT) f
WHERE t.JSON_OBJECT:type::STRING = 'CustomActivity'
  AND f.key LIKE 'custom.cf\_%' ESCAPE '\'
  AND TRIM(f.value::STRING) LIKE '[%'
  AND SILVER.REPAIR_AND_PARSE_JSON(f.value::STRING) IS NULL;
----------------------------------------------------------------------------- */
