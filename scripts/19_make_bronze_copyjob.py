#!/usr/bin/env python3
"""
19_make_bronze_copyjob.py — generate the six-table bronze Copy job definition.

Why generate it rather than build it in the portal
--------------------------------------------------
The repo's standing rule is "build in the portal, export, commit", and it was
written for good reason: three hand-authored *pipeline* definitions each failed
differently, because the Db2 source schema was not documented well enough to
write blind.

That condition no longer holds. `fabric/copyjob_bronze_customers.json` is an
exported, known-good Db2 -> Lakehouse Copy job, and this session proved the
create path round-trips it byte-for-byte and that a generated definition built
from it runs successfully against MCC_CODES. The six activities differ only in
table name, merge key and destination table, so generating them is mechanical
substitution into a proven shape, not guesswork.

Generating also buys something the portal cannot: the definition is reviewable
in a diff, and rebuilding it after an accident is one command rather than a
wizard run that nobody can check afterwards. The Copy job built in the previous
session vanished from the workspace; that is exactly the failure this guards.

Job mode, and two failures worth knowing about
----------------------------------------------
The default is `CDC` -- Fabric's name for the watermark machinery -- because that
is the only configuration proven to work here. It is NOT a claim that incremental
works. Read on.

**1. The initial snapshot works. The incremental run does not.**

Reduced to a minimal reproduction: a single-table Copy job, Db2 `MCC_CODES` (109
rows) into a Lakehouse table.

    run 1, initial snapshot .................. Completed
    touch one source row (watermark advances)
    run 2, incremental ....................... Failed

It fails identically with `writeBehavior: Upsert` and with `Append`, so the
failure is in the incremental READ from Db2, not the merge. Db2's own
`db2diag.log` records nothing for the attempt. The portal-built definition
configures it identically, so this is not an artefact of generating the JSON.

Consequence: **a CDC job works once.** Every run after the first takes the
incremental path and fails. To re-land, delete and recreate the job so the next
run is an initial snapshot again -- see `16_fabric_pipeline.sh --reland`.

**2. Hand-authored `Batch` mode does not work either, and the reason matters.**

Setting `jobMode: Batch` (full snapshot every run, which would sidestep the
problem above) fails immediately with:

    The expression 'if(equals(pipeline().parameters?.latestCheckpoints
    ?[item().checkpointName], null), ...)' cannot be evaluated because property
    'checkpointName' doesn't exist

The runtime expects every activity to carry a `checkpointName`. In CDC mode it
is evidently derived from `changeDataSettings`; with no change-data settings
there is nothing to derive it from, and the job cannot start. Adding
`checkpointName` by hand at the obvious place does not satisfy it.

**The useful finding underneath: `--export` is not lossless.** A definition
exported from a working portal-built job does not round-trip into every mode --
it carries no `checkpointName`, and nothing in the published Copy job definition
schema mentions one. "Build in the portal, export, commit" remains the right
rule, and this is a concrete limit on how far a committed definition can be
edited afterwards.

`--batch` regenerates the Batch variant for anyone retesting when the product
changes. It is known broken; do not ship it without re-running the above.

What is deliberately NOT here: audit columns
--------------------------------------------
Copy job supports per-row audit columns (extraction time, run id, workspace id,
incremental window bounds, custom static values), and they would satisfy the
demo's provenance claim directly.

They are not generated here because **the JSON shape is unpublished**. It is
absent from the Copy job definition schema, and an unverified shape found online
was tested and REJECTED by the API with HTTP 400 -- the identical definition was
accepted the moment the block was removed. Writing a guess into the file the
demo depends on is precisely the mistake this repo keeps warning about.

Adding them is a portal pass followed by `--export`. See docs/session-handoff.md.

Usage:
    ./scripts/19_make_bronze_copyjob.py [-o fabric/cj_bronze_db2.json]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import uuid

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = REPO_ROOT / "fabric" / "copyjob_bronze_customers.json"
DEFAULT_OUT = REPO_ROOT / "fabric" / "cj_bronze_db2.json"

# One entry per source table, in ascending size order. Copy job tracks
# incremental state per table, so the ordering is presentational rather than
# functional -- but a run that does the cheap tables first gives a far more
# useful progress signal if something is wrong with the connection.
#
# The merge key is the Db2 PRIMARY KEY in every case. Upsert on it is what makes
# a re-run idempotent; Append would duplicate every row.
#
# The watermark is LAST_UPDATED_TS everywhere: every table carries a
# ROW CHANGE TIMESTAMP, which is set on insert and advanced on update, and is
# the reason this dataset exists in the shape it does. A watermark on the
# business date would miss in-place updates entirely.
TABLES = [
    {"table": "MCC_CODES",        "key": "MCC_CODE",       "rows": 109},
    {"table": "CUSTOMERS",        "key": "CUSTOMER_ID",    "rows": 2_000},
    {"table": "CARDS",            "key": "CARD_ID",        "rows": 6_146},
    {"table": "AML_TRANSACTIONS", "key": "AML_TXN_ID",     "rows": 5_078_345},
    {"table": "FRAUD_LABELS",     "key": "TRANSACTION_ID", "rows": 8_914_963},
    {"table": "TRANSACTIONS",     "key": "TRANSACTION_ID", "rows": 13_305_915},
]

WATERMARK = "LAST_UPDATED_TS"
SCHEMA = "NBKI"


def build(template: dict, allow_truncation: bool = False,
          incremental: bool = True) -> dict:
    ref = template["activities"][0]

    activities = []
    for spec in TABLES:
        act = json.loads(json.dumps(ref))  # deep copy of the proven activity
        # Deterministic ids from the table name: regenerating the file produces
        # an identical result, so `git diff` shows real changes only.
        act["id"] = str(uuid.uuid5(uuid.NAMESPACE_URL,
                                   f"nbki-bronze/{spec['table']}"))
        props = act["properties"]

        props["source"]["datasetSettings"] = {"schema": SCHEMA, "table": spec["table"]}
        props["destination"]["datasetSettings"] = {"table": spec["table"]}

        if incremental:
            props["source"]["changeDataSettings"] = {
                "readMethod": "SnapshotPlusIncremental",
                "columns": [{"name": WATERMARK, "type": "DateTime"}],
                # Skip, not Fail: a null watermark would otherwise abort the
                # whole run. Every row here has one (05_verify.sh asserts zero
                # nulls), so this is a guard, not a silent filter.
                "nullWatermarkBehavior": "Skip",
            }
            props["destination"]["writeBehavior"] = "Upsert"
            props["destination"]["upsertSettings"] = {"keys": [spec["key"]]}
        else:
            # Batch: each run replaces the table wholesale, which is what makes
            # a re-run idempotent here. Note that upsert settings are NOT what
            # delivers idempotency in this mode -- `fullLoadBehavior: Truncate`
            # is, and the Delta log records the operation as `ReplaceTable`.
            props["source"].pop("changeDataSettings", None)
            props["destination"].pop("upsertSettings", None)
            props["destination"]["writeBehavior"] = "Overwrite"

        # allowDataTruncation lets a too-narrow target column drop characters
        # with no error. MERCHANT_STATE already had to be widened once for
        # exactly that reason, and 17_verify_bronze.py can only detect it on the
        # three small tables -- comparing 27M strings is not affordable.
        #
        # So the default here is FALSE: fail loudly rather than land something
        # subtly shorter than the source. This is not a guess -- the full 27.3M
        # row load was run with it false and completed cleanly.
        # `--allow-truncation` restores the portal default if it ever gets in
        # the way.
        props.setdefault("typeConversionSettings", {}).setdefault("typeConversion", {})
        props["typeConversionSettings"]["typeConversion"]["allowDataTruncation"] = allow_truncation

        activities.append(act)

    properties = json.loads(json.dumps(template["properties"]))
    properties["jobMode"] = "CDC" if incremental else "Batch"
    return {"properties": properties, "activities": activities}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", type=pathlib.Path, default=DEFAULT_OUT)
    ap.add_argument("--allow-truncation", action="store_true",
                    help="set allowDataTruncation=true, the portal default "
                         "(off here on purpose -- see the note in this file)")
    ap.add_argument("--batch", action="store_true",
                    help="generate the Batch variant -- KNOWN BROKEN, see above")
    args = ap.parse_args()

    if not TEMPLATE.exists():
        raise SystemExit(f"ERROR: template not found: {TEMPLATE}")

    doc = build(json.loads(TEMPLATE.read_text()),
                allow_truncation=args.allow_truncation,
                incremental=not args.batch)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(doc, indent=2) + "\n")

    total = sum(t["rows"] for t in TABLES)
    # relative_to raises for a path outside the repo, which -o legitimately
    # allows (writing a throwaway variant to /tmp to compare against the
    # committed one is the normal way to check a flag).
    try:
        shown = args.out.resolve().relative_to(REPO_ROOT)
    except ValueError:
        shown = args.out
    print(f"wrote {shown}")
    print(f"  {len(doc['activities'])} activities, {total:,} source rows")
    detail = ("full snapshot, replaces the table" if args.batch
              else f"merge on {{key}}, watermark {WATERMARK}")
    for spec in TABLES:
        print(f"    {spec['table']:<18} {spec['rows']:>11,}  "
              + detail.format(key=spec["key"]))
    print(f"\n  jobMode: {doc['properties']['jobMode']}")
    if args.batch:
        print("  WARNING: Batch mode FAILS here -- the runtime wants a checkpointName")
        print("           that no exported definition carries. See this file's header.")
    else:
        print("  NOTE: the initial snapshot works and is proven at 27.3M rows.")
        print("        The INCREMENTAL leg fails, so this job works once. Re-land")
        print("        with ./scripts/16_fabric_pipeline.sh --reland.")
    print("  NOTE: no audit columns -- the JSON shape is unpublished and an")
    print("        unverified one was rejected with HTTP 400. Add via the portal.")


if __name__ == "__main__":
    main()
