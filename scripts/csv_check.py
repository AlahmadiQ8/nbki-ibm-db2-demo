#!/usr/bin/env python3
"""
csv_check.py — parse the messy extracts and report what they ACTUALLY contain.

Used by 09_reconcile.sh. Kept separate because reconciling a deliberately
malformed CSV is parsing work, not shell work.

This exists because of a real flaw in the first version of the reconciliation:
it compared `csv-drop/manifest.json` against Db2 and never opened a CSV file at
all. Every check passed on the manifest alone, which meant a missing, edited,
stale or truncated extract would still have reported a clean reconciliation —
and the fallback would have been uploaded on the day in that state.

So this reads the physical files and undoes each planted defect, deriving:
    - the physical data-row count (duplicates included)
    - the deduplicated transaction count
    - the physical amount total, and the deduplicated total
    - which transaction refs are duplicated, and how often
    - a SHA-256 of the file as it sits on disk

Output is JSON on stdout so the shell can consume it without parsing prose.

Usage:
    ./scripts/csv_check.py csv-drop/manifest.json
"""

from __future__ import annotations

import csv
import hashlib
import json
import re
import sys
from collections import Counter
from decimal import Decimal, InvalidOperation
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

RE_NOT_NUMERIC = re.compile(r"[^0-9.\-]")


def parse_money(raw: str) -> Decimal:
    """
    Undo defects 3 and 4: thousands separators, currency symbols and prefixes,
    and accounting-style negatives such as (250.00).
    """
    v = raw.strip()
    if not v:
        raise InvalidOperation("empty")
    negative = v.startswith("(") and v.endswith(")")
    if negative:
        v = v[1:-1]
    v = RE_NOT_NUMERIC.sub("", v)
    if not v or v in {"-", "."}:
        raise InvalidOperation(f"unparseable: {raw!r}")
    d = Decimal(v)
    return -d if negative else d


def check_file(path: Path, spec: dict) -> dict:
    skip = spec.get("rows_to_skip_before_header", 3)
    footer = spec.get("footer_rows_to_discard", 3)

    raw_bytes = path.read_bytes()
    sha = hashlib.sha256(raw_bytes).hexdigest()

    # newline="" lets csv handle the CRLF line endings (defect 10) itself.
    with path.open("r", encoding="utf-8", newline="") as fh:
        all_rows = list(csv.reader(fh))

    header = all_rows[skip]
    body = all_rows[skip + 1:]
    # Drop the footer block (blank line, TOTAL, End of Report) by position, then
    # defensively strip anything else that is blank or clearly not a data row.
    body = body[:-footer] if footer else body
    body = [r for r in body
            if r and any(c.strip() for c in r)
            and r[0].strip().upper() not in {"TOTAL", "END OF REPORT"}]

    try:
        ref_i = header.index("Transaction Ref")
        amt_i = header.index("Amount (USD)")
    except ValueError as e:
        return {"file": path.name, "error": f"unexpected header: {e}"}

    refs: list[str] = []
    physical_total = Decimal(0)
    seen: set[str] = set()
    dedup_total = Decimal(0)
    problems: list[str] = []

    for n, r in enumerate(body, start=1):
        if len(r) <= max(ref_i, amt_i):
            problems.append(f"row {n}: only {len(r)} columns")
            continue
        ref = r[ref_i].strip()
        try:
            amt = parse_money(r[amt_i])
        except (InvalidOperation, ArithmeticError) as e:
            problems.append(f"row {n} (ref {ref}): bad amount {r[amt_i]!r} — {e}")
            continue
        refs.append(ref)
        physical_total += amt
        if ref not in seen:
            seen.add(ref)
            dedup_total += amt

    dupes = {ref: c for ref, c in Counter(refs).items() if c > 1}

    return {
        "file": path.name,
        "sha256": sha,
        "physical_data_rows": len(body),
        "parsed_rows": len(refs),
        "distinct_transaction_refs": len(seen),
        "physical_amount_total": str(physical_total),
        "dedup_amount_total": str(dedup_total),
        "duplicated_refs": dupes,
        "problems": problems,
    }


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    manifest_path = Path(sys.argv[1])
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    incoming = manifest_path.parent / "incoming"

    results = []
    declared = set()
    for spec in manifest["files"]:
        declared.add(spec["file"])
        path = incoming / spec["file"]
        if not path.exists():
            results.append({"file": spec["file"], "error": "MISSING from csv-drop/incoming/"})
            continue
        results.append(check_file(path, spec))

    # Files nobody declared are a real risk: csv-drop/README tells the operator
    # to upload incoming/*.csv, so a leftover extract from an earlier run with
    # different --months would be ingested without ever being reconciled.
    stray = sorted(p.name for p in incoming.glob("*.csv")
                   if p.name not in declared and not p.name.startswith("clean_")) \
        if incoming.exists() else []

    print(json.dumps({"results": results, "stray_files": stray}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
