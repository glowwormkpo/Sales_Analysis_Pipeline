#!/usr/bin/env python3
"""
Sales Analytics Pipeline - Phase 3
Synthetic 7-day source data generator (v2).

Revised after reviewing the project's explanation video + transcript, which
showed the *actual* shape of Close CRM custom activity data:

  - Each CustomActivity record carries its custom fields as TOP-LEVEL keys
    named "custom.cf_<hash>" (a real, opaque field ID) -- NOT under a single
    readable-key nested blob like an earlier draft of this generator assumed.
  - To make sense of a value like {"custom.cf_h3tYb9...": "1. Strategy Call
    Scheduled"}, you must separately look up cf_h3tYb9... in the
    custom_activites_raw dictionary, which -- per the video -- stores each
    CustomActivityType as an object with a nested "fields" array mapping
    field ID -> human field name (e.g. "Triage Call Outcome", "Setter",
    "Closer", "Contract Value", "Program"). This generator reproduces both
    sides of that relationship.
  - The single-quote malformation described in the written requirements
    lines up with Close's handling of multi-select custom fields (e.g.
    "Objections Faced" can hold more than one value): the value arrives as a
    Python-list-repr STRING, e.g. "['Money', 'Trust']", instead of a proper
    JSON array -- and can contain a real apostrophe inside an element
    ("Wasn't Looking For What We Offered"), which is exactly the
    single-quote / apostrophe collision the repair UDF (04_json_repair_udf.sql)
    is built to handle. Only Objections Faced uses this shape here; every
    other custom field value is a plain string/number.

Output: ./sample_data/day_1/ ... ./sample_data/day_7/, each containing:
  lead_activites_raw.json, custom_activites_raw.json,
  close_crm_users_raw.json, leads_raw.json
"""
import hashlib
import json
import os
import random
from datetime import datetime, timedelta

random.seed(42)

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sample_data")
BASE_DATE = datetime(2026, 8, 3, 7, 30)  # simulated first daily load, 07:30 EST


def cf_id(type_id, field_key):
    """Deterministic, opaque-looking field ID, mimicking Close's cf_<hash> IDs."""
    h = hashlib.md5(f"{type_id}:{field_key}".encode()).hexdigest()
    return "cf_" + h[:24]


# ---------------------------------------------------------------------------
# Reference data: users
# ---------------------------------------------------------------------------
USERS = [
    {"id": "usr_101", "first_name": "Maria", "last_name": "Chen", "email": "maria.chen@dea-sales.com"},
    {"id": "usr_102", "first_name": "Jordan", "last_name": "Reyes", "email": "jordan.reyes@dea-sales.com"},
    {"id": "usr_201", "first_name": "Alicia", "last_name": "Novak", "email": "alicia.novak@dea-sales.com"},
    {"id": "usr_202", "first_name": "Sam", "last_name": "Whitfield", "email": "sam.whitfield@dea-sales.com"},
]
SETTERS = ["usr_101", "usr_102"]
CLOSERS = ["usr_201", "usr_202"]

# ---------------------------------------------------------------------------
# Custom Activity Types + field definitions (this whole block is what
# custom_activites_raw delivers -- the dictionary the repair/mapping logic
# in Silver joins against).
# ---------------------------------------------------------------------------
ACTIVITY_TYPES = {
    "100": {
        "name": "Triage Call",
        "fields": {
            "outcome": "Triage Call Outcome",
            "setter": "Setter",
            "lead_quality": "Lead Quality",
            "notes": "Notes",
        },
        "outcomes": {
            "1": "1. Strategy Call Scheduled", "6": "6. No Show",
            "7": "7. Reschedule", "8": "8. Cancel",
        },
    },
    "200": {
        "name": "Prospecting Activity",
        "fields": {
            "outcome": "Prospecting Call Outcome",
            "setter": "Setter",
        },
        "outcomes": {
            "2": "2. Strategy Call Scheduled", "3": "Left Voicemail", "4": "Not Interested",
        },
    },
    "300": {
        "name": "Strategy Call",
        "fields": {
            "outcome": "Strategy Call Outcome",
            "closer": "Closer",
            "setter": "Setter",
            "offer_presented": "Offer Presented",
            "objections_faced": "Objections Faced",
        },
        "outcomes": {
            "1": "1. Follow Up", "2": "2. Admin Cancel", "3": "3. Cancel- Not Interested",
            "4": "4. No Show", "5": "5. Sale", "6": "6. Sale", "7": "7. Lost", "8": "8. Cancel- Nurture",
        },
    },
    "400": {
        "name": "New Sale",
        "fields": {
            "outcome": "Sales Outcome",
            "closer": "Closer",
            "setter": "Setter",
            "contract_value": "Contract Value",
            "cash_collected": "Cash Collected",
            "payment_type": "Payment Type",
            "program": "Program",
            "sales_type": "Sales Type",
        },
        "outcomes": {
            "7": "7) New Sale", "8": "8) New Sale [Custom Payment Plan]",
        },
    },
}
# Resolve field key -> cf_<hash> id, once, so it's stable across the whole run.
FIELD_IDS = {
    type_id: {fkey: cf_id(type_id, fkey) for fkey in spec["fields"]}
    for type_id, spec in ACTIVITY_TYPES.items()
}

OBJECTIONS = ["Money", "Fear", "Hung Up", "Logistical", "No Objections", "Talking to Other Coaches",
              "Partner", "Think About It", "Time", "Trust", "Value", "Wasn't Looking For What We Offered"]

_activity_seq = [1000]


def next_activity_id():
    _activity_seq[0] += 1
    return f"act_{_activity_seq[0]}"


def ts(day_offset, hour=10, minute=0):
    return (BASE_DATE + timedelta(days=day_offset, hours=hour - 7, minutes=minute)).strftime("%Y-%m-%dT%H:%M:%SZ")


def objections_raw_value(objection_list):
    """Builds the malformed single-quoted pseudo-JSON-array string exactly as
    described in the requirements -- structural single quotes around each
    element, which can collide with a real apostrophe inside one element."""
    parts = ["'" + o + "'" for o in objection_list]
    return "[" + ", ".join(parts) + "]"


def make_activity(lead_id, type_id, outcome_id, user_id, day_offset, activity_type="CustomActivity",
                   extra_fields=None, hour=10):
    spec = ACTIVITY_TYPES[type_id]
    outcome_value = spec["outcomes"][outcome_id]
    fids = FIELD_IDS[type_id]
    activity_id = next_activity_id()
    created = ts(day_offset, hour)

    obj = {
        "id": activity_id,
        "lead_id": lead_id,
        "contact_id": f"con_{lead_id}",
        "user_id": user_id,
        "type": activity_type,
        "custom_activity_type_id": type_id,
        "text": f"{spec['name']} - {outcome_value}",
        "created_by": user_id,
        "updated_by": user_id,
        "date_created": created,
        "date_updated": created,
        "activity_at": created,
    }
    # every custom field lands as a top-level "custom.cf_<hash>" key
    obj[f"custom.{fids['outcome']}"] = outcome_value
    extra_fields = extra_fields or {}
    for fkey, value in extra_fields.items():
        if fkey not in fids:
            continue
        if fkey == "objections_faced":
            obj[f"custom.{fids[fkey]}"] = objections_raw_value(value) if isinstance(value, list) else value
        else:
            obj[f"custom.{fids[fkey]}"] = value
    return obj


def maybe_setter_closer(type_id, setter=None, closer=None, offer=None, objections=None, **kw):
    extra = {}
    if setter and "setter" in ACTIVITY_TYPES[type_id]["fields"]:
        extra["setter"] = setter
    if closer and "closer" in ACTIVITY_TYPES[type_id]["fields"]:
        extra["closer"] = closer
    if offer is not None and "offer_presented" in ACTIVITY_TYPES[type_id]["fields"]:
        extra["offer_presented"] = offer
    if objections and "objections_faced" in ACTIVITY_TYPES[type_id]["fields"]:
        extra["objections_faced"] = objections
    extra.update(kw)
    return extra


# ---------------------------------------------------------------------------
# Lead scripts: worked examples A-G (requirements Sec. 3.5 / 3.6) + filler
# ---------------------------------------------------------------------------
def build_lead_scripts():
    scripts = {}

    scripts["lead_A"] = [
        make_activity("lead_A", "100", "1", random.choice(SETTERS), 0,
                       extra_fields=maybe_setter_closer("100", setter="usr_101")),
        make_activity("lead_A", "300", "5", random.choice(CLOSERS), 1,
                       extra_fields=maybe_setter_closer("300", setter="usr_101", closer="usr_201", offer="Yes")),
        make_activity("lead_A", "400", "7", random.choice(CLOSERS), 1,
                       extra_fields=maybe_setter_closer("400", setter="usr_101", closer="usr_201",
                                                         contract_value="15000", cash_collected="5000",
                                                         payment_type="Split Pay", program="Emerald",
                                                         sales_type="New")),
    ]
    scripts["lead_B"] = [
        make_activity("lead_B", "100", "6", random.choice(SETTERS), 0,
                       extra_fields=maybe_setter_closer("100", setter="usr_102")),
    ]
    scripts["lead_C"] = [
        make_activity("lead_C", "100", "1", random.choice(SETTERS), 0,
                       extra_fields=maybe_setter_closer("100", setter="usr_102")),
        make_activity("lead_C", "300", "7", random.choice(CLOSERS), 1,
                       extra_fields=maybe_setter_closer("300", setter="usr_102", closer="usr_202",
                                                         offer="Yes", objections=[random.choice(OBJECTIONS)])),
    ]
    scripts["lead_D"] = [
        make_activity("lead_D", "200", "2", random.choice(SETTERS), 0,
                       extra_fields=maybe_setter_closer("200", setter="usr_101")),
        make_activity("lead_D", "300", "5", random.choice(CLOSERS), 2,
                       extra_fields=maybe_setter_closer("300", setter="usr_101", closer="usr_201", offer="Yes")),
        make_activity("lead_D", "400", "7", random.choice(CLOSERS), 2,
                       extra_fields=maybe_setter_closer("400", setter="usr_101", closer="usr_201",
                                                         contract_value="12000", cash_collected="12000",
                                                         payment_type="Paid in Full", program="Gold",
                                                         sales_type="New")),
    ]
    scripts["lead_E"] = [
        make_activity("lead_E", "200", "2", random.choice(SETTERS), 0,
                       extra_fields=maybe_setter_closer("200", setter="usr_102")),
        make_activity("lead_E", "300", "4", random.choice(CLOSERS), 2,
                       extra_fields=maybe_setter_closer("300", setter="usr_102", closer="usr_202")),
    ]
    scripts["lead_F"] = [
        make_activity("lead_F", "200", "2", random.choice(SETTERS), 0,
                       extra_fields=maybe_setter_closer("200", setter="usr_101")),
        make_activity("lead_F", "300", "7", random.choice(CLOSERS), 2,
                       extra_fields=maybe_setter_closer(
                           "300", setter="usr_101", closer="usr_202", offer="Yes",
                           objections=["Wasn't Looking For What We Offered", "Money"])),
    ]
    scripts["lead_G"] = [
        make_activity("lead_G", "200", "3", random.choice(SETTERS), 0,
                       extra_fields=maybe_setter_closer("200", setter="usr_102")),
    ]

    outcomes_pool = ["dial_only", "no_show_triage", "inbound_no_sale", "inbound_sale",
                      "outbound_no_show", "outbound_lost", "outbound_sale"]
    for i, letter in enumerate("HIJKLMNO"):
        lead_id = f"lead_{letter}"
        path = random.choice(outcomes_pool)
        d0 = random.randint(0, 3)
        setter, closer = random.choice(SETTERS), random.choice(CLOSERS)
        acts = []
        if path == "dial_only":
            acts.append(make_activity(lead_id, "200", random.choice(["3", "4"]), setter, d0,
                                       extra_fields=maybe_setter_closer("200", setter=setter)))
        elif path == "no_show_triage":
            acts.append(make_activity(lead_id, "100", random.choice(["6", "7", "8"]), setter, d0,
                                       extra_fields=maybe_setter_closer("100", setter=setter)))
        elif path in ("inbound_no_sale", "inbound_sale"):
            acts.append(make_activity(lead_id, "100", "1", setter, d0,
                                       extra_fields=maybe_setter_closer("100", setter=setter)))
            if path == "inbound_sale":
                acts.append(make_activity(lead_id, "300", random.choice(["5", "6"]), closer, d0 + 1,
                                           extra_fields=maybe_setter_closer("300", setter=setter, closer=closer, offer="Yes")))
                acts.append(make_activity(lead_id, "400", "7", closer, d0 + 1,
                                           extra_fields=maybe_setter_closer(
                                               "400", setter=setter, closer=closer,
                                               contract_value=str(random.randint(5000, 20000)),
                                               cash_collected=str(random.randint(2000, 20000)),
                                               payment_type="Paid in Full",
                                               program=random.choice(["Gold", "Emerald", "Platinum"]),
                                               sales_type="New")))
            else:
                acts.append(make_activity(lead_id, "300", "7", closer, d0 + 1,
                                           extra_fields=maybe_setter_closer(
                                               "300", setter=setter, closer=closer,
                                               offer=random.choice(["Yes", "No"]),
                                               objections=[random.choice(OBJECTIONS)])))
        elif path == "outbound_no_show":
            acts.append(make_activity(lead_id, "200", "2", setter, d0,
                                       extra_fields=maybe_setter_closer("200", setter=setter)))
            acts.append(make_activity(lead_id, "300", "4", closer, d0 + 2,
                                       extra_fields=maybe_setter_closer("300", setter=setter, closer=closer)))
        elif path == "outbound_lost":
            acts.append(make_activity(lead_id, "200", "2", setter, d0,
                                       extra_fields=maybe_setter_closer("200", setter=setter)))
            acts.append(make_activity(lead_id, "300", "7", closer, d0 + 2,
                                       extra_fields=maybe_setter_closer(
                                           "300", setter=setter, closer=closer, offer="Yes",
                                           objections=[random.choice(OBJECTIONS)])))
        elif path == "outbound_sale":
            acts.append(make_activity(lead_id, "200", "2", setter, d0,
                                       extra_fields=maybe_setter_closer("200", setter=setter)))
            acts.append(make_activity(lead_id, "300", random.choice(["5", "6"]), closer, d0 + 2,
                                       extra_fields=maybe_setter_closer("300", setter=setter, closer=closer, offer="Yes")))
            acts.append(make_activity(lead_id, "400", "7", closer, d0 + 2,
                                       extra_fields=maybe_setter_closer(
                                           "400", setter=setter, closer=closer,
                                           contract_value=str(random.randint(5000, 25000)),
                                           cash_collected=str(random.randint(2000, 25000)),
                                           payment_type="Paid in Full",
                                           program=random.choice(["Gold", "Emerald", "Platinum"]),
                                           sales_type="New")))
        scripts[lead_id] = acts
    return scripts


def make_edit_case(scripts):
    """Lead C's Strategy Call outcome gets corrected from a bad initial log
    ('1. Follow Up') to the correct 'Lost' on day 4, exercising the
    MD5_HASH change-detection / MERGE update path."""
    for act in scripts["lead_C"]:
        if act["custom_activity_type_id"] == "300":
            act["_late_correction_day"] = 3
            act["_original_outcome_id"] = "1"
    return scripts


def activity_as_of(activity, day_offset):
    a = dict(activity)
    if "_late_correction_day" in a:
        correction_day = a.pop("_late_correction_day")
        original_outcome_id = a.pop("_original_outcome_id")
        type_id = a["custom_activity_type_id"]
        spec = ACTIVITY_TYPES[type_id]
        outcome_field_id = FIELD_IDS[type_id]["outcome"]
        if day_offset < correction_day:
            a[f"custom.{outcome_field_id}"] = spec["outcomes"][original_outcome_id]
            a["text"] = f"{spec['name']} - {spec['outcomes'][original_outcome_id]}"
        else:
            a["date_updated"] = ts(correction_day, 16)
    else:
        a.pop("_late_correction_day", None)
        a.pop("_original_outcome_id", None)
    return a


def custom_activites_dictionary():
    """The custom_activites_raw payload: one CustomActivityType object per
    type, each with a nested 'fields' array -- this is what Silver joins
    cf_<hash> keys against."""
    rows = []
    for type_id, spec in ACTIVITY_TYPES.items():
        fields = [{"id": FIELD_IDS[type_id][fkey], "name": fname,
                   "type": "multi_choice" if fkey == "objections_faced" else
                           ("choices" if fkey in ("outcome", "offer_presented") else
                            ("user" if fkey in ("setter", "closer") else "text"))}
                  for fkey, fname in spec["fields"].items()]
        rows.append({
            "id": type_id,
            "_type": "CustomActivityType",
            "name": spec["name"],
            "fields": fields,
            "created_by": "usr_admin",
            "updated_by": "usr_admin",
            "date_created": ts(0, 6),
            "date_updated": ts(0, 6),
            "is_archived": False,
        })
    return rows


def main():
    scripts = build_lead_scripts()
    scripts = make_edit_case(scripts)
    custom_dict = custom_activites_dictionary()

    for day in range(7):
        day_dir = os.path.join(OUT_DIR, f"day_{day + 1}")
        os.makedirs(day_dir, exist_ok=True)

        activities_today = []
        for lead_id, acts in scripts.items():
            for a in acts:
                created_day = int(a["date_created"][8:10]) - BASE_DATE.day
                if created_day <= day:
                    activities_today.append(activity_as_of(a, day))
        with open(os.path.join(day_dir, "lead_activites_raw.json"), "w") as f:
            json.dump({"data": activities_today}, f, indent=2)

        with open(os.path.join(day_dir, "custom_activites_raw.json"), "w") as f:
            json.dump({"data": custom_dict}, f, indent=2)

        user_rows = [{
            "id": u["id"], "first_name": u["first_name"], "last_name": u["last_name"],
            "email": u["email"], "status": "active",
            "created_at": ts(0, 6), "updated_at": ts(0, 6),
        } for u in USERS]
        with open(os.path.join(day_dir, "close_crm_users_raw.json"), "w") as f:
            json.dump({"data": user_rows}, f, indent=2)

        lead_rows = []
        for lead_id in scripts:
            lead_rows.append({
                "id": lead_id, "name": lead_id.replace("_", " ").title(),
                "display_name": lead_id.replace("_", " ").title(),
                "status_id": "st_1", "status_label": "Active",
                "created_by": "usr_admin", "updated_by": "usr_admin",
                "date_created": ts(0, 6), "date_updated": ts(0, 6),
                "description": "", "html_url": f"https://app.close.com/lead/{lead_id}",
                "organization_id": "org_dea",
                "tasks": [], "contacts": [{"contact_id": f"con_{lead_id}", "contact_name": lead_id}],
                "opportunities": [], "custom": {},
            })
        with open(os.path.join(day_dir, "leads_raw.json"), "w") as f:
            json.dump({"data": lead_rows}, f, indent=2)

    print(f"Generated 7 days of sample data under: {OUT_DIR}")
    print("Field ID map (for reference while testing):")
    for type_id, fids in FIELD_IDS.items():
        print(f"  {ACTIVITY_TYPES[type_id]['name']} ({type_id}):")
        for fkey, fid in fids.items():
            print(f"    {fid}  ->  {ACTIVITY_TYPES[type_id]['fields'][fkey]}")


if __name__ == "__main__":
    main()
