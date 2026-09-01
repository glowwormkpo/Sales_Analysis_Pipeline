# Requirements vs. Reality

A log of every place the original requirements document and the provided Snowflake data model turned out not to match the actual PostgreSQL/Close CRM data, discovered over the course of building this pipeline against real data. Organized by requirements doc section for cross-reference. Distinguishes between "the source document was wrong or incomplete" (needed for judging whether the starting information was reliable) and "our own early implementation had a gap that the requirements were actually right about" (noted separately, so credit/blame lands in the right place).

## Section 2.1-2.3 — Source Data Explanation

**"Every source table contains... single quotes enclosing properties and values instead of standard double quotes" (line 104-105, stated as a blanket claim about every source table).**
Not true across the board. Only `custom_activites_raw` and `close_crm_users_raw` actually needed JSON repair — and even then, in a double-wrapped Python-repr form (not simple single-vs-double-quote substitution). `leads_raw` and `lead_activites_raw` turned out to be clean, valid JSON needing no repair at all. Confirmed before writing any Silver logic for these tables, rather than assumed.

**Custom Activity Types (Table 3): 10 named types listed** — Prospecting Activity, Triage Call, Strategy Call, Strategy Call Follow Up, New Sale, Payment Transaction, Post-Sale Activity, Refund Request, Referral Activity, Fathom Call.
Real data has 28 distinct custom activity types, not 10, including several the doc never mentions (Prospecting Follow Up, Triage Call Follow Up, Call Confirmation Activity, Onboarding Complete, Slack User Removal, Setter Hand Off Notes, Backend Sale, Office Hour Activity, CSM Prospecting Activity, CSM Strategy Call Activity, Additional Cash Collected, New Deposit, Pipeline Update, New Sale [Custom Payment Plan]) and two with different exact naming than what's listed ("Refund Request Initiated" vs. "Refund Request"; "New Referral Generated" vs. "Referral Activity"). Confirmed via `CUSTOM_ACTIVITY_TYPES` (28 rows, file 12).

**Business fields (Table 4): field named "Objections Faced".**
Real field name is `"Objections Faced?"` — with a trailing question mark. Confirmed via the real field dictionary; every query, view, and UDF referencing this field uses the exact real name.

**Objections Faced — implicitly treated as a scalar field** (no mention of multi-select in the requirements doc's field table).
Confirmed to be a genuine multi-select array — Close lets a rep log more than one objection per call. Required a `LATERAL FLATTEN` rework of `RPT_OBJECTIONS_FACED` so a call with 2 objections increments both matching category counts instead of matching only one.

**Close CRM Users (Table 5): fields listed as `id, first_name, last_name, email, status, role, created_at, updated_at`.**
`status` and `role` do not exist on the real object at all. A sampled real user record contains only: `date_created, date_updated, email, email_verified_at, first_name, google_profile_image_url, id, image, last_name, last_used_timezone, organizations`. Confirmed directly against a raw sample pasted from the source (requirements audit gap #4) — `CLOSE_CRM_USERS_PROCESSED` was already correctly limited to fields that actually exist.

**Contact fields (Table 7): includes `linkedin_url`.**
This one the requirements doc got right — the field genuinely exists on real Contact records. The gap here was on our side: the original `CONTACTS` DDL didn't capture `urls`/`linkedin_url` even though the source data has it. Fixed in file 20 (requirements audit gap #5). Noted separately from the other items in this log because the *requirement* was accurate; the *implementation* just hadn't caught up to it yet.

**CustomActivity records — implicitly assumed to carry a `text` field** (via the Phase 3 synthetic design, which every real-data build initially inherited).
Real CustomActivity records have no `text` field at all. Left `NULL` in `LEAD_ACTIVITIES_PROCESSED` once confirmed (file 13).

**Email records — assumed to be simple** (Phase 3 placeholder columns: sender, status, subject, body).
Real Email records are far richer — nested `envelope`, `opens`, `attachments` objects, `template_id`/`template_name`, `has_reply`, etc. `LEAD_ACTIVITIES_EMAIL` already had columns for all of it; they simply weren't being populated until file 13 was rewritten against real samples.

## Section 3 — Business Hierarchy / Funnel Logic

**Outcome text taxonomy** — assumed to closely mirror the requirements doc's worked examples.
Mostly confirmed accurate (`'1. Strategy Call Scheduled'`, `'2. Strategy Call Scheduled'`, `'6. Sale'` all appear verbatim in real data), but Strategy Call Follow Up uses different literal outcome wording than Strategy Call itself for the same semantic status in several cases (e.g. `'3. No Show'` vs. `'4. No Show'`; `'6. Lost'` vs. `'7. Lost'`). Both had to be enumerated explicitly in `ALL_STRATEGIES_DETAILS` and `RPT_CLOSER`/`RPT_CLOSER_DAILY` rather than assumed identical (file 15/16/22).

**"Reschedule" outcome classification** — not addressed in the requirements doc's worked examples at all.
Assumption made (not confirmed by any source document or stakeholder): a Reschedule outcome is classified as No Show/Cancelled, on the reasoning that a rescheduled call hasn't actually been held yet. Flagged explicitly in file 15's header comments as an open assumption, not a confirmed fact.

**Setter/Closer resolution** — the requirements doc's worked examples (3.5/3.6) imply setter/closer identity is always cleanly knowable per lead.
Real data resolves Setter/Closer primarily from the activity's own custom field, with a fallback chain to the booking-view lookup — and even with that fallback chain, ~55-60% of Strategy Call activity and ~90% of raw Outbound dial activity has no resolvable identity at all (see the Reviewer Validation section of the README for the full investigation). This is the single largest gap between what the source documents implied and what the real data actually supports.

## Section 3.4 — Sales Outcome Stage

**Sale-deriving activity types — the doc's Table 3 lists "New Sale" as a type, and Section 3.4 worked examples only ever reference one sale event per lead.**
Section 3.4's own text (confirmed on closer reading) actually names two: "7) New Sale" and "8) New Sale [Custom Payment Plan]" — but only the first was modeled in the initial real-data build. The second has a structurally different field set (no `Contract Signed`/`Cash Collected`; uses an installment structure — `Initial Payment`, `Recurring Amount`, `Number of Billing Cycles` — instead). Fixed in file 23 (requirements audit gap #2) once the real field list for that type was confirmed.

**New Sale's outcome field** — implicitly assumed every custom activity type has a resolvable "*Outcome*" field, the way Triage/Strategy Call do.
New Sale has no Outcome-named field at all in the real dictionary. `SALE_STATUS` had to be sourced from `Contract Signed` (Yes/No) instead of the standard outcome-resolution path.

**Custom Activity Types dictionary — assumed a flat outcome list per the requirements doc's Table 2 field list** (id, name, description, fields, created_by, updated_by, date_created, date_updated, is_archived).
Table 2 turned out to be accurate about which fields exist, but the original real-data DDL didn't capture all of them (`is_archived`, `created_by`, `updated_by`, `date_created`, `date_updated` were missing from `CUSTOM_ACTIVITY_TYPES`). Fixed in file 20 (requirements audit gap #3) — same pattern as the Contacts/`linkedin_url` item: the requirement was right, the early implementation hadn't caught up.

## Section 4.1 — Deduplication & Cleansing Logic

**Dedup key specified exactly**: "Identify duplicates using: lead_id + activity_id. Keep the latest activity record using: activity_at."
The early real-data implementation didn't match this precisely. Fixed in file 20 (requirements audit gap #7) to dedup exactly as specified.

**Upserts specified exactly**: "Use MERGE INTO statements... utilizing INSERT_DATE and UPDATE_DATE for auditability."
The initial Phase 4 backfill used `TRUNCATE` + `INSERT` (full refresh) for expedience while getting the real-data structure right first, not the required upsert pattern. Rewritten in file 20 to the specified `MERGE INTO` approach (requirements audit gap #1), confirmed to reproduce identical row counts to the full-refresh version.

## Section 5 — Phased Project Execution

**"Ingestion: Create Stages and COPY INTO Bronze tables... Orchestration: Schedule daily job runs... purge processed files from stages using dynamic date patterns."**
This describes a fully automated daily pipeline. Two things about the real environment made this impossible to fully realize as specified: the Snowflake account provisioned for this project is a trial account, which cannot create an External Access Integration, so there's no way to automate a Postgres → S3 → Snowflake pull on a schedule — Bronze ingestion is a manual step instead. And real-data files have no date-partitioned naming convention the way the spec's daily-extract model assumes, so the "dynamic date pattern" purge approach doesn't apply — stage purge is a separate manual procedure instead (file 21). Only Silver refresh and Export made it into the automated Task DAG (file 18/20).

## Not addressed by the requirements doc at all

**Setter/Closer attribution completeness.** Nothing in the source documents anticipated that a meaningful share of real activity would have no resolvable owner. This surfaced only through reviewer validation against live CSV exports (files 26-32), not from anything in the original requirements or data model — worth knowing given it's now the single biggest data-quality caveat on the whole pipeline.

**Contract Value completeness.** 56 of 209 (27%) "New Sale" activities have no Contract Value entered at all — a rep data-entry gap, not something either source document flagged as a possibility.

## Net assessment

The provided Snowflake data model was explicitly framed by the SME as "a guide rather than a fixed spec" (per the Phase 1 doc's own Section 1), and that framing held up — most of the *structural* guidance (table/view names, Bronze→Silver→Gold→Export shape, the four required reports) was accurate and usable as-is. Where the source documents broke down was almost entirely at the level of specific values: type IDs, exact field names, exact outcome text, and — the biggest one — the assumption that setter/closer identity would be reliably present on real activity records. None of that is something a document review could have caught; all of it only became visible once real data was actually loaded and queried, which is exactly what happened at each of the points logged above.
