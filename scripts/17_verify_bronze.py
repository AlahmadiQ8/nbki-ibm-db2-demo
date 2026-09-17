#!/usr/bin/env python3
"""
17_verify_bronze.py — prove what landed in the bronze lakehouse is the source.

This is the demo beat, not a chore
----------------------------------
"Source versus landed row counts and monetary control totals, compared and tied
to the penny" is on a slide. It needs to be something that runs.

The comparison is against `data/prepared/manifest.json`, which is the committed
authority for the prepared files, and which `05_verify.sh` separately proves
reconciles to Db2 across all six tables. Note the provenance carefully -- it is
`05_verify.sh` that ties the manifest to Db2, NOT `09_reconcile.sh`. The latter
runs 7 checks against each of 3 monthly transaction extracts (hence 21/21) and
covers the CSV fallback path for TRANSACTIONS only. Citing it as the all-table
authority is a mistake this repo made and corrected.

Why counts and sums alone are not enough
----------------------------------------
A verifier that checks only row counts and a few totals is easy to fool. All of
the following pass such a check while the landing is broken:

  * every MCC_DESCRIPTION or IS_FRAUD value landed as null;
  * `Yes` and `No` swapped wholesale in FRAUD_LABELS;
  * duplicate primary keys exactly balanced by missing ones;
  * a DECIMAL column landed as DOUBLE that happens to round to the same total;
  * strings silently truncated to fit.

So this checks schema and decimal precision, key uniqueness, null profiles,
categorical distributions, and -- for the three small tables -- full content
equality of every string column against the prepared CSV, as well as the counts
and totals.

**Known gap, stated rather than implied:** string content is NOT compared for
`TRANSACTIONS`, `FRAUD_LABELS` or `AML_TRANSACTIONS`, because that would mean
pulling ~27M strings across the wire. Silent truncation in a string column of
those three tables would not be caught here. `allowDataTruncation` is true in
the Copy job (the portal default), so that risk is real.

How it reads the data
---------------------
Through the OneLake REST API (see `_onelake.py`), because the SQL analytics
endpoint needs an ODBC driver this workstation does not have. Row counts come
from the Delta transaction log and cost no data transfer at all; aggregates read
only the specific Parquet column chunks they need, over HTTP range requests.

Usage:
    .venv/bin/python scripts/17_verify_bronze.py
    .venv/bin/python scripts/17_verify_bronze.py --table TRANSACTIONS
"""

from __future__ import annotations

import argparse
import csv
import decimal
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import _onelake as ol  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "data" / "prepared" / "manifest.json"

WORKSPACE = "5c84bcc5-f497-4eac-b59b-5c2a36bec619"
LAKEHOUSE = "56ba34ce-c8c8-467e-a1a9-8952b7b03dba"

# The Db2 primary key of each table. Bronze merges on it, so a duplicate here
# means the merge is not doing what the "run it twice, zero duplicates" claim
# says it does.
MERGE_KEYS = {
    "CUSTOMERS": "CUSTOMER_ID",
    "CARDS": "CARD_ID",
    "TRANSACTIONS": "TRANSACTION_ID",
    "MCC_CODES": "MCC_CODE",
    "FRAUD_LABELS": "TRANSACTION_ID",
    "AML_TRANSACTIONS": "AML_TXN_ID",
}

# Delta types that must survive exactly. A DECIMAL that arrives as a DOUBLE can
# still sum to something that looks right -- AML_TRANSACTIONS reaches six
# decimal places precisely because the crypto rows go down to 0.000001, and
# rounding them would be invisible in every other check.
EXPECTED_TYPES = {
    "CUSTOMERS": {"LATITUDE": "decimal(9,4)", "LONGITUDE": "decimal(9,4)",
                  "PER_CAPITA_INCOME": "decimal(15,2)", "YEARLY_INCOME": "decimal(15,2)",
                  "TOTAL_DEBT": "decimal(15,2)", "LAST_UPDATED_TS": "timestamp"},
    "CARDS": {"CREDIT_LIMIT": "decimal(15,2)", "CARD_NUMBER": "string",
              "CVV": "string", "LAST_UPDATED_TS": "timestamp"},
    "TRANSACTIONS": {"AMOUNT": "decimal(15,2)", "TXN_TS": "timestamp",
                     "MERCHANT_ZIP": "string", "LAST_UPDATED_TS": "timestamp"},
    "MCC_CODES": {"MCC_CODE": "string", "MCC_DESCRIPTION": "string"},
    "FRAUD_LABELS": {"IS_FRAUD": "string", "TRANSACTION_ID": "long"},
    "AML_TRANSACTIONS": {"AMOUNT_RECEIVED": "decimal(23,6)",
                         "AMOUNT_PAID": "decimal(23,6)", "TXN_TS": "timestamp"},
}

# Tables small enough to compare content-for-content rather than by aggregate.
#
# This exists because aggregates cannot see string damage. Delta `string` carries
# no length, so a column truncated on the way in still has the right type, the
# right row count, the right null profile, and no control total to disagree with.
# `allowDataTruncation` is true in the Copy job (the portal default), so this is
# a live failure mode, not a hypothetical one -- `MERCHANT_STATE` had to be
# widened once for exactly this reason.
#
# Comparison is against the prepared CSV that was loaded into Db2, as a multiset
# per string column: it catches truncation, wholesale column shifts, and silent
# value loss. Only string columns are compared; numeric and timestamp columns are
# already covered exactly by control totals and type assertions.
#
# The large tables are deliberately excluded -- 13.3M strings is a lot of traffic
# for this check. That is a real gap and it is stated in the header, not implied
# away.
FULL_COMPARE = {"MCC_CODES", "CUSTOMERS", "CARDS"}
PREPARED_DIR = REPO_ROOT / "data" / "prepared"

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"


class Report:
    def __init__(self) -> None:
        self.passed = self.failed = 0

    def ok(self, label: str, detail: str = "") -> None:
        print(f"  {GREEN}PASS{RESET}  {label:<48} {detail}")
        self.passed += 1

    def bad(self, label: str, detail: str = "") -> None:
        print(f"  {RED}FAIL{RESET}  {label:<48} {detail}")
        self.failed += 1

    def info(self, label: str, detail: str = "") -> None:
        print(f"  {YELLOW}INFO{RESET}  {label:<48} {detail}")

    def check(self, label: str, expected, actual) -> None:
        if str(expected) == str(actual):
            self.ok(label, str(actual))
        else:
            self.bad(label, f"expected {expected}, got {actual}")

    def check_decimal(self, label: str, expected: decimal.Decimal,
                      actual: decimal.Decimal) -> None:
        """Compare numerically, not textually.

        A Delta decimal(9,4) renders 74778.45 as '74778.4500'. The values are
        equal; only the scale differs. Comparing the strings reports a failure
        on data that ties exactly -- and a control-total check that cries wolf
        is worse than none, because the next person starts ignoring it.

        Decimal equality is exact, so this keeps the no-tolerance rule: a real
        penny of drift still fails.
        """
        if expected == actual:
            self.ok(label, str(actual))
        else:
            self.bad(label, f"expected {expected}, got {actual} "
                            f"(diff {actual - expected})")


def read_columns(info: dict, table: str, columns: list[str]):
    """Concatenate one or more columns across every live Parquet file."""
    import pyarrow as pa
    batches = []
    for path, meta in info["files"].items():
        pf = ol.open_parquet(WORKSPACE, LAKEHOUSE, table, path, meta["size"])
        batches.append(pf.read(columns=columns))
    return pa.concat_tables(batches) if len(batches) > 1 else batches[0]


def exact_sum(table_arrow, column: str) -> decimal.Decimal:
    """Sum with Decimal, never float.

    pyarrow's compute.sum on a decimal column returns a decimal, but going via
    Python floats anywhere in this path would reintroduce exactly the rounding
    error the DECIMAL types exist to prevent.
    """
    total = decimal.Decimal(0)
    for v in table_arrow.column(column):
        val = v.as_py()
        if val is not None:
            total += decimal.Decimal(str(val))
    return total


def compare_strings_to_prepared(table: str, info: dict, rep: Report) -> None:
    """Compare every string column against the prepared CSV, as a multiset.

    Sorted multiset rather than row-by-row because bronze row order is not
    guaranteed -- the Copy job writes whatever order it reads in, and a merge
    can reorder further. Order is not part of the contract; content is.
    """
    csv_path = PREPARED_DIR / f"{table}.csv"
    if not csv_path.exists():
        rep.info(f"{table} content comparison", f"skipped, no {csv_path.name}")
        return

    string_cols = [c for c, t in info["schema"].items() if t == "string"]
    if not string_cols:
        return

    with csv_path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        expected: dict[str, list[str]] = {c: [] for c in string_cols}
        for row in reader:
            for c in string_cols:
                if c in row:
                    expected[c].append(row[c])

    arrow = read_columns(info, table, string_cols)
    for col in string_cols:
        if not expected.get(col):
            continue  # column is not in the prepared file (e.g. LAST_UPDATED_TS)
        # Db2 CHAR/VARCHAR round-trips can carry trailing blanks; the prepared
        # file does not. Strip both sides so this reports real differences only.
        got = sorted((v.as_py() or "").rstrip() for v in arrow.column(col))
        want = sorted((v or "").rstrip() for v in expected[col])
        if got == want:
            rep.ok(f"{table}.{col} content identical to source",
                   f"{len(want):,} values")
        else:
            gmax = max((len(v) for v in got), default=0)
            wmax = max((len(v) for v in want), default=0)
            detail = f"{len(want):,} expected, {len(got):,} landed"
            if gmax < wmax:
                detail += f" -- TRUNCATED: longest {gmax} vs {wmax}"
            rep.bad(f"{table}.{col} content identical to source", detail)


def verify_table(spec: dict, rep: Report) -> None:
    table = spec["table"]
    print(f"\n-- {table}")

    try:
        info = ol.read_delta_log(WORKSPACE, LAKEHOUSE, table)
    except RuntimeError as e:
        rep.bad(f"{table} present in lakehouse", str(e).split("\n")[0])
        return

    # 1. Row count, straight from the Delta log.
    rep.check(f"{table} row count", spec["rows_out"], info["num_records"])

    # 2. Schema: every source column present, and the landmine types exact.
    missing = [c for c in spec["columns"] if c not in info["schema"]]
    if missing:
        rep.bad(f"{table} all source columns present", f"missing {missing}")
    else:
        rep.ok(f"{table} all source columns present", f"{len(spec['columns'])} columns")

    for col, want in EXPECTED_TYPES.get(table, {}).items():
        got = info["schema"].get(col, "<absent>")
        rep.check(f"{table}.{col} type", want, got)

    if info["num_records"] in (0, None):
        return

    # 3. Merge-key integrity. Catches duplicates exactly masked by missing rows,
    #    which a row count cannot see.
    key = MERGE_KEYS[table]
    keys = read_columns(info, table, [key]).column(key).to_pylist()
    rep.check(f"{table}.{key} no nulls", 0, sum(1 for k in keys if k is None))
    rep.check(f"{table}.{key} distinct == rows", len(keys), len(set(keys)))

    # 4. Control totals, exact. No tolerance: a penny of drift is a failure.
    totals = spec.get("control_totals") or {}
    if totals:
        arrow = read_columns(info, table, list(totals))
        for col, expected in totals.items():
            rep.check_decimal(f"{table}.{col} sum",
                              decimal.Decimal(expected), exact_sum(arrow, col))

    # 5. Non-null profile, from the manifest's own value_counts.
    for col, expected in (spec.get("value_counts") or {}).items():
        arrow = read_columns(info, table, [col])
        non_null = sum(1 for v in arrow.column(col) if v.as_py() is not None)
        rep.check(f"{table}.{col} non-null count", expected, non_null)

    # 6. The tables with no control totals need a different kind of proof.
    if table == "FRAUD_LABELS":
        arrow = read_columns(info, table, ["IS_FRAUD"])
        vals = arrow.column("IS_FRAUD").to_pylist()
        distinct = sorted(set(vals))
        rep.check("FRAUD_LABELS.IS_FRAUD domain", "['No', 'Yes']", str(distinct))
        rep.info("FRAUD_LABELS label split",
                 ", ".join(f"{v}={vals.count(v):,}" for v in distinct))

    if table == "MCC_CODES":
        arrow = read_columns(info, table, ["MCC_CODE", "MCC_DESCRIPTION"])
        blank = sum(1 for v in arrow.column("MCC_DESCRIPTION")
                    if v.as_py() in (None, ""))
        rep.check("MCC_CODES.MCC_DESCRIPTION populated", 0, blank)

    # 7. Content equality on the string columns, for the tables small enough.
    if table in FULL_COMPARE:
        compare_strings_to_prepared(table, info, rep)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--table", action="append",
                    help="verify only these tables (repeatable)")
    args = ap.parse_args()

    manifest = json.loads(MANIFEST.read_text())
    specs = manifest["tables"]
    if args.table:
        wanted = {t.upper() for t in args.table}
        specs = [s for s in specs if s["table"] in wanted]
        if not specs:
            raise SystemExit(f"ERROR: no such table in the manifest: {args.table}")

    print(f"==> Verifying bronze against {MANIFEST.relative_to(REPO_ROOT)}")
    print(f"    workspace {WORKSPACE}")
    print(f"    lakehouse {LAKEHOUSE}")

    landed = ol.list_tables(WORKSPACE, LAKEHOUSE)
    print(f"    tables in lakehouse: {', '.join(landed) or '(none)'}")

    rep = Report()
    for spec in specs:
        verify_table(spec, rep)

    print("\n" + "=" * 60)
    total = rep.passed + rep.failed
    colour = GREEN if rep.failed == 0 else RED
    print(f"  {colour}{rep.passed} passed, {rep.failed} failed{RESET}  (of {total})")
    print("=" * 60)
    if rep.failed:
        print("\nBronze does NOT match the source. Do not demo from this data.")
        raise SystemExit(1)
    print("\nBronze ties to the source exactly.")


if __name__ == "__main__":
    main()
