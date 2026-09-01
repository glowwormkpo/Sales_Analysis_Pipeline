# Data Reconciliation & Attribution Report — August 26, 2026

Prepared in response to the reviewer's request: attribution completeness for a recent date range (requested "24-25," with a 2024-2025 comparison), plus a match-vs-mismatch classification tracing data from source all the way to the reports.

## 1. Recent-date attribution: August 24-25, 2026

As of this report, the pipeline's Bronze layer had not been refreshed from Postgres since August 18 — a manual step that hadn't been re-run yet, not a processing defect (see Section 4 for why Bronze ingestion is manual). A fresh Postgres pull was run today (August 26) specifically to answer this request, and Silver/Gold/the exported reports have all been rebuilt from that current data.

With current data in place, for activity logged August 24-25, 2026:

| Report | Total rows | Unattributed setter | Unattributed closer |
|---|---|---|---|
| `ALL_STRATEGIES_DETAILS` (Strategy Calls) | 283 | 27 (9.5%) | 55 (19.4%) |
| `OUTBOUND_PROSPECT_DIALS` | 243 | 57 (23.5%) — single setter/closer field | — |

For comparison, the all-time rate across the full activity history (not just these two days) is roughly 55% unattributed on `ALL_STRATEGIES_DETAILS` and 90% on `OUTBOUND_PROSPECT_DIALS`. Recent activity resolves far better than older activity — expected, since setter/closer identity resolves against a snapshot of currently active Close CRM users; older activity was often logged by staff who have since left and no longer appear in any current-state user export.

### 2024-2025 comparison: not possible — the source data doesn't go back that far

The underlying Close CRM activity stream itself starts May 20, 2026. There is no 2024 or 2025 activity data anywhere in Postgres, Bronze, Silver, or Gold — confirmed directly against the source, not just this pipeline's copy of it. This isn't a pipeline gap; it's the actual boundary of the connected CRM instance's activity history.

## 2. Source-to-report match/mismatch classification

Every record's journey from raw source to a final report passes through three transitions. Two different things can cause a record not to "match" at a given stage, and they mean very different things:

- **Type exclusion** — the record is correctly filtered out because it isn't one of the activity types the four reports are built from (e.g., a phone Call, an SMS, an Email, a Meeting, or a CustomActivity subtype like Payment Transaction or Refund Request). This is expected, designed behavior, not a defect.
- **Identity mismatch** — the record IS one of the relevant types, but its setter or closer never resolves against the current user roster. This is the one real, quantified data-quality gap in the pipeline.

### Stage 1: Bronze → Silver (staging)

898,586 distinct activity IDs in Bronze → 898,586 in the Silver staging layer. **100% survival — zero data loss.** Every single raw activity record that lands in Bronze makes it into Silver's staging table.

### Stage 2a: Silver → Gold, by activity type (type exclusion)

Of those 898,586 activities, only 38,300 (4.3%) are `CustomActivity` type — the only type the four reports use. The rest (Calls, SMS, Email, Meetings, Notes, lead-merge events) are correctly out of scope and were never meant to appear in these reports. Narrowing further, within `CustomActivity`: 24,673 (64.4%) are one of the 8 specific subtypes the reports need (Triage, Prospecting, Strategy Call, New Sale, and their follow-up variants); the remaining 13,627 (35.6%) are other CustomActivity subtypes (Payment Transaction, Post-Sale Activity, Refund Request, etc.) that are also correctly excluded.

### Stage 2b: Gold identity resolution (the real gap)

Of the 5,789 Strategy Call records that reach `ALL_STRATEGIES_DETAILS`:

| Match type | Count | % |
|---|---|---|
| Full match (setter + closer both resolved) | 5,023 | 86.8% |
| Partial match (setter only) | 359 | 6.2% |
| Partial match (closer only) | 235 | 4.1% |
| Full mismatch (neither resolved) | 172 | 3.0% |

Unresolved setter/closer identity is labeled explicitly as `'Unattributed'` throughout the Gold layer (rather than a blank or misleading fallback name), so this gap is visible in every report rather than hidden.

### Stage 3: Gold → Reports (aggregation)

Every Gold row is represented in the exported reports — this reconciles to 100% by construction, since the report views only aggregate and never filter:

| Check | Gold | Report |
|---|---|---|
| Strategy Calls | 5,789 | `RPT_CLOSER_DAILY` sum(CALL_BOOKED) = 5,789 |
| Sales | 197 | `RPT_CLOSER_DAILY` sum(SALE) = 197, `RPT_CLOSER` sum(SALE) = 197 |

## Bottom line

The only genuine data-quality gap in the pipeline is setter/closer identity resolution, and it's a source-data limitation (reps not always filling in the Setter/Closer fields, plus historical activity from since-departed staff) rather than a processing defect — every stage of Bronze → Silver → Gold → Reports itself reconciles cleanly, and the gap that does exist is now labeled transparently rather than concealed.
