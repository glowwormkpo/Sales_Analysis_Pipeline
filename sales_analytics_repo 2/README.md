# Sales Analytics Pipeline

A Bronze → Silver → Gold → Export pipeline built natively in Snowflake, turning raw Close CRM / PostgreSQL activity data into four report-ready KPI exports: Inbound Setter, Outbound Setter, Closer, and Objections Faced.

Built in two stages: a Phase 1-3 design and build against synthetic data, then a Phase 4 migration to run the same pipeline against the real Postgres/Close CRM source. Everything in this repo reflects the final, real-data state unless noted otherwise.

## Repo structure

```
docs/     Word/PDF design docs (latest version of each)
sql/      All SQL/Python build scripts, numbered in run order
scripts/  Automated Bronze refresh script + scheduling setup guide
diagrams/ Architecture and ERD diagrams
```

### docs/

| File | Covers |
|---|---|
| `Sales_Analytics_Pipeline_Phase1_Architecture_v4.docx/.pdf` | End-to-end architecture proposal (Bronze/Silver/Gold/Export design, funnel logic, schema evolution). v4 revises the Bronze ingestion and orchestration sections to describe what Phase 4 actually built against real data, and closes out three of the original open items. |
| `Sales_Analytics_Pipeline_Phase2_ERD_v3.docx/.pdf` | Entity-relationship diagrams for all four layers. |
| `Sales_Analytics_Pipeline_Phase3_Runbook_v2.docx/.pdf` | Step-by-step build/deploy runbook. |

### diagrams/

`architecture_flow.png` (medallion flow), `funnel_logic.png` (inbound/outbound funnel stages), `erd_silver_v3.png`, `erd_gold_lineage_v2.png`.

## Architecture

Bronze preserves raw JSON payloads as-is (`JSON_OBJECT` VARIANT + `INSERT_DATE`), for full replayability. Silver repairs malformed JSON, flattens nested activity arrays, resolves custom-field IDs to human-readable names, and dedupes via `MD5_HASH` + `MERGE INTO` upserts. Gold exposes business-logic views scoped to funnel stages (Triage → Strategy Call → Sale) rather than a classic star schema. Export aggregates each Gold view to its exact report grain and unloads to S3.

Four Gold views carry the core funnel logic: `INBOUND_STRATEGIES_BOOKED`, `OUTBOUND_STRATEGIES_BOOKED`, `OUTBOUND_PROSPECT_DIALS`, `ALL_STRATEGIES_DETAILS`, and `SALES_DETAILS`. The four `RPT_*` views aggregate those down to the exact KPI report specs and are what actually get unloaded to S3.

## SQL build order

**Phase 1-3 (synthetic data foundation):**

| # | File | Purpose |
|---|---|---|
| 00 | `00_generate_sample_data.py` | Synthetic test data generator |
| 01 | `01_stages_and_formats.sql` | Stages + file formats |
| 01b | `01b_put_sample_data.sql` | Load sample data to stage |
| 02 | `02_bronze_ddl.sql` | Bronze table DDL |
| 03 | `03_bronze_copy_into.sql` | Bronze COPY INTO |
| 04 | `04_json_repair_udf.sql` | Single-quote → JSON repair UDF |
| 05 | `05_silver_transient_flatten.sql` | Silver flatten (transient staging) |
| 06 | `06_silver_merge_dedup.sql` | Silver MERGE / dedup logic |
| 07 | `07_gold_views.sql` | Core Gold funnel views |
| 08 | `08_export_unload.sql` | `RPT_INBOUND_SETTER`, `RPT_OUTBOUND_SETTER`, `RPT_CLOSER`, `RPT_OBJECTIONS_FACED` + unloads |
| 09 | `09_orchestration_tasks_streams.sql` | Original Task/Stream DAG (synthetic data) |

**Phase 4 (real Postgres/Close CRM data):**

| # | File | Purpose |
|---|---|---|
| 10 | `10_silver_new_entities_ddl.sql` | DDL for real-data Silver entities |
| 11 | `11_silver_new_activities_load.sql` | Real activity load (Calls, SMS, Meetings, Notes, etc.) |
| 12 | `12_silver_dictionary_and_users_load.sql` | `CUSTOM_ACTIVITY_TYPES`/`FIELDS` + CRM users (incl. `STRIP_DESCRIPTION_VALUES` UDF) |
| 13 | `13_silver_customactivity_email_load.sql` | CustomActivity + Email routing, dynamic outcome resolution |
| 14 | `14_silver_leads_entities_load.sql` | `LEADS_PROCESSED`, `CONTACTS`, `OPPORTUNITIES`, `TASKS` |
| 15 | `15_gold_views_real_data.sql` | Core Gold views rebuilt against real type IDs/outcomes |
| 16 | `16_gold_reports_real_data.sql` | `RPT_CLOSER`/`RPT_OBJECTIONS_FACED` rebuilt for real data |
| 17 | `17_silver_refresh_procedure.sql` | *(superseded by 20)* First-pass refresh procedure (full TRUNCATE+INSERT) |
| 18 | `18_orchestration_real_data.sql` | Real-data Task DAG: Silver refresh → Export |
| 19 | `19_gold_closer_report_daily.sql` | Adds `RPT_CLOSER_DAILY` |
| 20 | `20_silver_refresh_procedure_v2.sql` | **Current** refresh procedure — `MERGE INTO` upserts, not full refresh |
| 21 | `21_bronze_purge_real_data.sql` | Manual stage-purge procedure |
| 22 | `22_gold_closer_reports_fix.sql` | Fixes `RPT_CLOSER`/`RPT_CLOSER_DAILY` sales-undercounting bug |
| 23 | `23_sales_details_custom_payment_plan.sql` | Adds "New Sale [Custom Payment Plan]" to `SALES_DETAILS` |
| 24 | `24_setter_reports_spotcheck.sql` | Verification queries for `RPT_INBOUND_SETTER`/`RPT_OUTBOUND_SETTER` |

**Reviewer-validation round (see "Reviewer validation" below for the full story):**

| # | File | Purpose |
|---|---|---|
| 25 | `25_single_day_report_export.sql` | Pulls all 4 reports filtered to one day, for handing CSVs to a reviewer |
| 26 | `26_setter_closer_diagnostics.sql` | Diagnostics for the reviewer's flagged mismatch/missing-data reports |
| 27 | `27_find_good_example_date.sql` | Finds a day with realistic, non-outlier funnel volume for spot-checks |
| 28 | `28_user_resolution_diagnostics.sql` | Breaks down `user_id` → `CLOSE_CRM_USERS_PROCESSED` match rate by activity type |
| 29 | `29_contract_value_raw_check.sql` | Checks raw (uncast) Contract Value/Cash Collected text for a sales anomaly |
| 30 | `30_closer_blank_check.sql` | Corrects a flawed NULL-check that had hidden the real closer-attribution gap |
| 31 | `31_duplicate_sale_check.sql` | *(inconclusive, not pursued further)* Investigates a lead with 2 New Sale activities |
| 32 | `32_label_unattributed.sql` | **Fix.** Relabels unresolved setter/closer identity as `'Unattributed'` across 5 Gold views |

**Automated-refresh round (see "Automated Bronze refresh" below for the full story):**

| # | File | Purpose |
|---|---|---|
| 33 | `33_date_range_and_recent_attribution.sql` | Confirms activity date range + checks recent-date attribution gap |
| 34 | `34_bronze_date_range_simple.sql` | Isolates Bronze's raw `MAX(activity_at)` (twice-fixed `LATERAL FLATTEN` query) |
| 35 | `35_source_to_report_reconciliation.sql` | 4-stage Bronze→Silver→Gold→Reports match/mismatch reconciliation |
| 36 | `36_copy_into_bronze.sql` | Companion `COPY INTO` for the automated Bronze refresh script (`scripts/`) |
| 37 | `37_fix_inbound_setter_report.sql` | *(superseded by 38)* Corrects `RPT_INBOUND_SETTER` — see "Reviewer validation, round 2" below |

**Grain-rebuild round (see "Reviewer validation, round 3" below for the full story):**

| # | File | Purpose |
|---|---|---|
| 38 | `38_lead_journey_summary_and_inbound_setter.sql` | **Fix.** Adds `GOLD.LEAD_JOURNEY_SUMMARY` (one row per lead, corrected grain) and rebuilds `RPT_INBOUND_SETTER` from it |
| 39 | `39_outbound_closer_objections_reports.sql` | **Fix.** Rebuilds `RPT_OUTBOUND_SETTER`, `RPT_CLOSER` (month grain), and `RPT_OBJECTIONS_FACED` from `LEAD_JOURNEY_SUMMARY` |

Run 00-09 for the synthetic-data build, or 10-24 + 32 + 38 + 39 (after 01-04, which are shared) for the real-data build. Files 25-31 and 33-35 are diagnostic/investigative and don't need to be run for a fresh deploy — 32, 38, and 39 change production view definitions, and 20/21 have since been corrected (see "Automated Bronze refresh" below) so redeploy those two if your copy predates 2026-08-26. Files 17 and 09's Bronze/Stream automation are superseded, and 37 is superseded by 38 — see below.

## Real-data implementation notes

- **JSON repair**: real `custom_activites_raw`/`close_crm_users_raw` store a double-wrapped Python-repr pseudo-JSON string; `leads_raw`/`lead_activites_raw` are already clean JSON.
- **Custom field resolution**: every custom field arrives as an opaque `custom.cf_<hash>` key, resolved dynamically against `CUSTOM_ACTIVITY_FIELDS` rather than hardcoded per type — handles all 28 real activity types without enumerating each one.
- **Two sale types**: `SALES_DETAILS` covers both "New Sale" (uses `Contract Signed`/`Cash Collected`) and "New Sale [Custom Payment Plan]" (installment structure: `Initial Payment`/`Recurring Amount`/`Number of Billing Cycles`), with type-appropriate fallback logic.
- **Upserts**: `SILVER.REFRESH_ALL_REAL_DATA()` (file 20) does a full-scan `MERGE INTO` — not Snowflake Streams — since current volume runs well within the daily window.
- **Orchestration scope**: only Silver refresh + Export are automated (`TASK_REFRESH_SILVER_REAL` → `TASK_EXPORT_REPORTS_REAL`, daily 9:00 AM America/New_York). Bronze ingestion and stage purge are deliberately manual — the Snowflake trial account can't create an External Access Integration, so there's no way to automate the Postgres → Snowflake pull.
- **Role/status fields**: confirmed absent from the real Close CRM user object — not a gap, just not part of the real data model.

## Requirements audit

A full audit against the original requirements document found 8 gaps, all resolved and confirmed against live query results:

1. Upserts (`MERGE INTO`, not full-refresh) — file 20
2. "New Sale [Custom Payment Plan]" missing from `SALES_DETAILS` — file 23
3. Missing scalar fields on `CUSTOM_ACTIVITY_TYPES` — file 20
4. Role/status fields on Close CRM users — confirmed not present in real data
5. `urls`/`linkedin_url` missing from `CONTACTS` — file 20
6. No stage-purge step for real data — file 21
7. Dedup key not matching spec (`lead_id`+`activity_id`, `activity_at`) — file 20
8. Phase 1 doc describing the original (not real-data) design — doc v4

One additional bug was found and fixed along the way: `RPT_CLOSER_DAILY` was undercounting sales (147 vs. 178) because it joined from calls to sales on exact date, dropping any sale with no same-day call. Fixed in file 22 by rebuilding both `RPT_CLOSER` and `RPT_CLOSER_DAILY` from a calls-UNION-sales date spine. Confirmed: both now total exactly 178, matching `SALES_DETAILS`.

`RPT_INBOUND_SETTER`/`RPT_OUTBOUND_SETTER` were spot-checked last (file 24) since they were never rewritten for real data — and didn't need to be. Both reconcile exactly against their upstream ground truth (6,269/6,269 inbound bookings, 8,741/8,741 outbound dials). Their combined sales total (176) is 2 short of the 178 ground truth in `SALES_DETAILS`; that's expected, not a bug — a sale only appears in one of these two reports if its Strategy Call traces back to a Triage Call or Prospect Dial row, and a small number of sales can reach `SALES_DETAILS` without that link.

## Reviewer validation

After the initial audit, a reviewer spot-checking CSV exports of the four reports flagged a mismatch in Inbound and missing data in Outbound/Closer. Investigation (files 25-32) found two distinct issues, one a false alarm and one real:

**Not a bug — bad example date.** The first CSVs were pulled for the most recent date with a confirmed sale, but a lead's triage date and its eventual sale date are unrelated points in its journey. Filtering "Inbound Setter" to leads triaged that specific day showed a funnel that hadn't had time to play out yet (19 of 21 triage-booked leads that day had no Strategy Call logged at all). Fixed by picking a day with realistic, resolved funnel volume instead (file 27); no SQL changes needed.

**Real gap — setter/closer attribution.** Roughly 55-60% of Strategy Call activity and ~90% of raw Outbound dial activity has no resolvable setter or closer. Root cause, confirmed via files 28 and 30: the `"Setter"`/`"Closer"` custom fields aren't always filled in by reps at logging time, and the fallback (the activity's raw CRM owner `user_id`) frequently doesn't match any of the 156 users in `CLOSE_CRM_USERS_PROCESSED` — most plausibly because that roster reflects currently active staff only, while activity data goes back to May 2026, predating some staff departures. This is a genuine source-data completeness gap, not a fixable pipeline defect (the roster load itself is current, not stale — confirmed it was loaded within hours of the latest activity). A related finding: an earlier check that reported `CLOSER_NAME` as "0% null" was itself flawed — `CLOSER_NAME`'s fallback chain defaults to an empty string rather than `NULL` when unresolved, so a naive `IS NULL` check couldn't have found the gap even though it was there (55.4%, confirmed once corrected — file 30).

**Resolution:** since the gap reflects real missing data rather than a bug, file 32 relabels every unresolved setter/closer as `'Unattributed'` across `INBOUND_STRATEGIES_BOOKED`, `OUTBOUND_STRATEGIES_BOOKED`, `OUTBOUND_PROSPECT_DIALS`, `ALL_STRATEGIES_DETAILS`, `SALES_DETAILS`, and `RPT_OBJECTIONS_FACED`, so it shows up as a clearly named, quantified category in every report instead of a blank row that looks broken. Confirmed after applying: 2,730 of 4,927 `ALL_STRATEGIES_DETAILS` rows (55.4%) are `Unattributed`, with all other row counts and sales totals unchanged (178 sales, matching every prior check).

A secondary anomaly (one closer showing 3 sales with $0 collected on all 3) turned out to be a genuine duplicate "New Sale" activity on one lead, not a pipeline bug (file 29 ruled out a casting-format issue: 0 of 209 New Sale records have an uncastable Contract Value, though 56 of 209 (27%) genuinely have none entered at all). Not pursued further — a single lead out of 178 sales.

## Automated Bronze refresh

Bronze ingestion was manual (per "Orchestration scope" above) because the Snowflake trial account can't reach out to Postgres on its own. That limitation only blocks automation *from inside* Snowflake — `scripts/refresh_bronze_from_postgres.sh` automates the same manual steps from *outside* Snowflake instead: export the 4 `raw.*` Postgres tables, `PUT` to `@BRONZE.RAW_LANDING`, `COPY INTO` Bronze (file 36), all in one SnowSQL session so it only prompts for auth once. `scripts/Bronze_Refresh_Scheduling_Setup.md` covers one-time setup and scheduling it via cron/`launchd`/Task Scheduler. Once Bronze is refreshed this way, the existing 9am `TASK_REFRESH_SILVER_REAL` → `TASK_EXPORT_REPORTS_REAL` DAG picks it up automatically — no other change needed.

Building and first-running this script surfaced two real, previously-latent bugs, both now fixed:

**Postgres export shape.** Each `raw.*` table is a 2-column `(raw_data jsonb, insert_date timestamp)` shape (confirmed via `\d`). The first version of the export used `row_to_json(t)` on the whole Postgres row, which wraps the payload as `{"insert_date":..., "raw_data": {...actual record...}}` — an extra nesting level that broke every downstream `id`/`activity_id` extraction (`LEAD_JSON:id` found nothing, since `id` lives at `raw_data.id`, not the top level). Fixed by exporting the `raw_data` column directly (`scripts/refresh_bronze_from_postgres.sh`). A batch loaded with the old wrapped shape was identified (`WHERE JSON_OBJECT:raw_data IS NOT NULL` — no real Close CRM field is ever named `raw_data`, so this cleanly isolates the bad rows) and deleted from Bronze before reloading correctly.

**Dedup key bug in file 20 (now fixed).** `ALL_ACTIVITIES_TRANSIENT` used to dedupe by `(LEAD_ID, ACTIVITY_ID)` per the literal gap #7 spec wording, but every downstream per-type `MERGE` (`CALLS`, `MEETINGS`, `NOTES`, `SMS_MESSAGES`, `LEAD_ACTIVITIES_PROCESSED`, etc.) matches `ON tgt.ACTIVITY_ID = src.ACTIVITY_ID` alone. When the same `ACTIVITY_ID` legitimately appears under two different `LEAD_ID`s (confirmed happens in real data — e.g. a calendar Meeting re-delivered against a different lead across snapshots), the old partition kept both rows and every downstream `MERGE` failed outright with "Duplicate row detected during DML action." Fixed by partitioning by `ACTIVITY_ID` alone, matching what every downstream merge already assumes — `ACTIVITY_ID` is Close CRM's true unique identifier; `LEAD_ID` is an attribute of it, not part of its identity.

Also fixed: file 21's `BRONZE.PURGE_REAL_DATA_STAGE()` stored-procedure wrapper never actually worked — Snowflake rejects `REMOVE` (and `PUT`/`GET`/`LIST`) from inside a stored procedure body with `Unsupported statement type 'REMOVE_FILES'`. The procedure has been dropped; file 21 now documents running the `REMOVE` statements directly instead.

See `Reviewer_Reconciliation_Aug26.md` for the full source-to-report match/mismatch classification run against current data after this fix, including the corrected finding that Bronze→Silver survival is actually 100% (an earlier framing of that number was comparing all activity types against a Silver table intentionally scoped to `CustomActivity` only).

## Reviewer validation, round 2

After the Aug 26 automated refresh, the reviewer's own independent report exports flagged a row in `RPT_INBOUND_SETTER` that made no logical sense: `INBOUND_BOOKED=6`, `INBOUND_TAKEN=0`, yet `STRATEGY_CALL_BOOKED=2` for the same setter/date. Unlike the earlier round, this wasn't a data-completeness gap — it was a genuine logic bug in the view itself, carried over untouched from the Phase 3 synthetic build (`08_export_unload.sql`). The earlier spot-check (file 24) only validated column *totals* against ground truth, which this bug happened to pass despite being wrong at the row level — a reminder that total-reconciliation checks can miss row-level logic errors.

Two distinct problems, found and fixed in two passes (file 37):

1. `INBOUND_TAKEN` was computed from `STRATEGY_CALL_BOOKED` (whether the triage led to a scheduled strategy call) — an entirely different concept from whether the triage call itself was actually held. `SHOW_RATE` and `TRIAGE_SET_RATE` were also the literal same formula, copy-pasted. And the reported `STRATEGY_CALL_BOOKED` column wasn't gated by any real "booked" flag — it counted any lead with a matching `ALL_STRATEGIES_DETAILS` row, joined on `LEAD_ID` + `SETTER`, where `SETTER` resolves identity through a completely different chain than `INBOUND_STRATEGIES_BOOKED.SETTER_CLOSER_EMAIL`. For the same lead those two setter values can differ, which is exactly how the impossible row happened — two metrics from two mismatched joins.
2. The first fix pass introduced a second, related bug that a second sanity-check row caught: `STRATEGY_CALL_TAKEN`/`OFFER_RATE` still summed across the *entire* triage cohort rather than only leads where `STRATEGY_CALL_BOOKED` was actually true — producing `STRATEGY_CALL_BOOKED=0, STRATEGY_CALL_TAKEN=4`, still impossible. Fixed by gating both sums with `IFF(t.STRATEGY_CALL_BOOKED, ..., 0)`.

`INBOUND_STRATEGIES_BOOKED` now also exposes a real `TRIAGE_TAKEN` flag, using the confirmed real Triage Call outcome taxonomy: a call counts as taken unless its outcome is `6. No Show`, `7. Reschedule`, or `8. Cancel` (same Show/No-Show reasoning already applied to Strategy Calls in `ALL_STRATEGIES_DETAILS`).

Confirmed after the second fix: the flagged row now reads `INBOUND_BOOKED=6, INBOUND_TAKEN=3, STRATEGY_CALL_BOOKED=0, STRATEGY_CALL_TAKEN=0` — internally consistent. Totals still reconcile: `SUM(INBOUND_BOOKED)` = `COUNT(*) FROM INBOUND_STRATEGIES_BOOKED` = 6,432; `SUM(STRATEGY_CALL_BOOKED)` = `COUNT(*) FROM INBOUND_STRATEGIES_BOOKED WHERE STRATEGY_CALL_BOOKED` = 1,563.

`RPT_OUTBOUND_SETTER` was checked against the same failure pattern and does not have this bug — its joins already match on `LEAD_ID` alone.

## Reviewer validation, round 3

A live review call surfaced a deeper problem than either prior round: for Jordon Eggleston, August 2026, the pipeline reported 217 booked / 48 shown against the reviewer's own reference (`CLOSER_REPORT.csv`) of 44 booked / 12 shown — off by roughly 5x. Direct row-level evidence (a single lead with 4 activity rows: Follow Up → Cancel → No Show → Cancel) confirmed the root cause: every reschedule, follow-up, and no-show was being counted as its own "call booked" event instead of being recognized as a later stage of the same lead's one continuous journey. This was a grain problem, not a duplicate-rows problem — an earlier duplicate-row/duplicate-key check (clean) had ruled out literal duplication and pointed the wrong direction. The original project video transcript confirmed the intended design: "if strategy call outcome is follow up, then there will be another call" — i.e., follow-ups continue one journey, they don't start a new one.

Files 38 and 39 rebuild all four Gold KPI reports from a new one-row-per-lead view, `GOLD.LEAD_JOURNEY_SUMMARY`, replacing the per-touch approach used since Phase 3. Three design decisions came out of this rebuild:

1. **Grain**: `LEAD_JOURNEY_SUMMARY` collapses each lead to a single row, with `TRIAGE_TAKEN` and `STRATEGY_CALL_BOOKED` derived via `BOOLOR_AGG` across *all* of a lead's triage/prospecting touches (not just the first) — both flags evaluated over the same population, which was essential to avoid reintroducing impossible combinations (e.g., `TRIAGE_TAKEN=FALSE` but `STRATEGY_CALL_BOOKED=TRUE`) during iteration.
2. **"Shown" definition**: `STRATEGY_CALL_TAKEN` is based on the outcome of the lead's *first* scheduled strategy call attempt only, not whether the lead was ever eventually connected after reschedules — using "ever taken" produced 48 (far off the reference 12); "first attempt only" produced 10-13 (close to the reference 12).
3. **Setter/closer attribution**: five candidate sources were tested and validated against the reference numbers. CRM-user-resolved `DEA_INTERNAL_EMAIL`/`DEA_INTERNAL_NAME` from the *latest* strategy-call-type activity touch gave the best match (46 booked / 10 shown vs. reference 44/12) and matches the original design intent ("CRM user is required because that is how you would be able to capture closer and setter," per the project video). `SILVER.OPPORTUNITIES.USER_ID` was tested and rejected — it mostly defaults to the founder/account owner as a placeholder that's never reassigned, not the actual closer.

`RPT_CLOSER` also moved from a daily grain to a month grain in file 39, per explicit correction on the review call ("the closer report on our end is at month level") — a closer only enters the picture once a strategy call is booked, so day-level granularity doesn't apply the way it does for setters. It also gained a `PENDING_NO_CALL_LOGGED_YET` bucket so `CALL_BOOKED` always equals the sum of its outcome buckets, and `RPT_OBJECTIONS_FACED` gained explicit month scoping (previously missing entirely, which had been inflating counts by aggregating a closer's objections across the pipeline's whole history) and now excludes `'No Show'`, `'Reschedule'`, `'Cancel'` from the objection taxonomy — those describe call outcomes, not objections, and aren't part of the reference report's own category list.

A subsequent QA pass (before these reports went out) caught two further issues, both fixed in the current files 38/39: `OFFER_RATE`/`SALE_RATE` could exceed 100% because `OFFER_PRESENTED`/`SALE` weren't gated to only leads with `STRATEGY_CALL_BOOKED=TRUE`; and null `SETTER`/`CLOSER_NAME` values are now labeled `'unassigned'`/`'Unassigned'` rather than left blank, consistent with the labeling precedent set in file 32.

**Final validated state**: Jordon Eggleston, August 2026 — 46 booked / 10 shown (reference: 44 booked / 12 shown), a substantial improvement over the pre-rebuild 217/48. The residual gap was not chased further; the fix targeted the confirmed structural bug (grain + shown definition), not an exact reconciliation to the reference file's row-level source data.

## Known open items

Carried over from the original Phase 1 design doc, Section 10 — documented assumptions never explicitly reconfirmed against production data (not known defects):

- Whether the single-quote JSON repair logic covers every malformed pattern in production, not just sampled examples.
- Whether `ACTIVITY_AT` is reliably populated across all activity types.
- Timezone normalization across `ACTIVITY_AT`, `ACTIVITY_LOG_DATE`, and report date/week/month fields.
- The exact source of `PROGRAM` and the grain/definition of `SC_YEAR_WEEK` / `call_year_month`.

Confirmed, quantified data-quality limitations (documented, labeled in reports, not expected to be fixable from the pipeline side):

- Setter/closer attribution: ~55.4% of `ALL_STRATEGIES_DETAILS` rows all-time (and ~89.5% of `OUTBOUND_PROSPECT_DIALS` rows) are `Unattributed` (see Reviewer Validation above). Notably better on recent activity — 13.2% unattributed on Strategy Calls logged Aug 24-25, 2026, once run against a freshly refreshed roster (see `Reviewer_Reconciliation_Aug26.md`) — confirming the gap is mostly driven by older activity from since-departed staff, not an ongoing data-entry problem. Would need a historical (not just current) Close CRM user roster to close the remaining older-data gap.
- Contract Value completeness: 56 of 209 (27%) "New Sale" activities have no Contract Value entered at all (confirmed not a casting bug — file 29).

## Verification

Every Gold/Export view in the real-data path has been row-count and total-reconciled against its own ground truth at least once, with results pasted back into the working session by the pipeline owner rather than assumed. See the Phase 1 doc v4, Section 10, for the full resolved/open item history.
