#!/usr/bin/env python3
"""
07_make_csv_drop.py — build the fallback: the CSV extract NBKI makes today.

Two jobs, and they pull in opposite directions
----------------------------------------------
1. SAFETY NET. If the Db2 VM will not come up on the day, or the gateway
   refuses to connect from the demo network, the demo must still run. These
   files can be dropped into a Lakehouse folder and the entire medallion story
   proceeds unchanged from bronze onward.

2. THE "BEFORE" PICTURE. This is also the artefact that makes the argument.
   It is deliberately, specifically messy — every defect in it is one a human
   would actually produce exporting from a green-screen core banking system
   into a spreadsheet, and every one of them is something the Db2 path makes
   impossible by construction.

Because of (1) the numbers must reconcile exactly with what is in Db2. So the
rows are a deterministic slice of the same prepared data that was loaded: a
fixed set of months, no sampling, no randomness in *which* rows are chosen. The
mess is applied to the presentation of the values, never to the values
themselves — with the deliberate exception of the duplicate row, which is
counted and declared in the manifest.

The extract is denormalised — transaction joined to customer and card — because
that is what a report-builder's export looks like. Nobody hand-exports third
normal form.

Planted defects (all documented in csv-drop/README.md):
    1.  three preamble lines above the header      -> naive readers break
    2.  UK and ISO date formats in one column      -> 03/04/2019 is ambiguous
    3.  thousands separators and currency symbols  -> numeric column arrives as text
    4.  accounting-style negatives, (123.45)       -> parses as text or wrong sign
    5.  a grand-total row at the foot              -> double counts if ingested blindly
    6.  a blank line before the totals             -> truncates lazy parsers
    7.  inconsistent casing and padding on state   -> breaks GROUP BY
    8.  one exactly duplicated transaction         -> no key to dedupe on
    9.  three spellings of missing: '', N/A, NULL  -> three different nulls
    10. CRLF line endings                          -> stray \\r on the last column
    11. a trailing 'End of Report' line            -> more junk after the data
    12. as-at date in the filename, not the data   -> lineage lives in the filename

Usage:
    ./scripts/07_make_csv_drop.py
    ./scripts/07_make_csv_drop.py --months 2019-10 2019-11 2019-12
    ./scripts/07_make_csv_drop.py --clean          # also emit a clean version
"""

from __future__ import annotations

import argparse
import csv
import json
from collections import defaultdict
from datetime import datetime
from decimal import Decimal
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PREPARED = REPO_ROOT / "data" / "prepared"
DROP_DIR = REPO_ROOT / "csv-drop"
OUT_DIR = DROP_DIR / "incoming"
SAMPLE_DIR = DROP_DIR / "samples"

# The extract a business user would build: transaction facts plus the customer
# and card attributes they need for the report, flattened.
HEADER = [
    "Transaction Ref",
    "Posting Date",
    "Customer No",
    "Card No",
    "Card Brand",
    "Card Type",
    "Amount (USD)",
    "Entry Method",
    "Merchant",
    "Merchant City",
    "Merchant State",
    "Merchant Zip",
    "MCC",
    "Customer Age",
    "Credit Score",
    "Notes",
]

MISSING_SPELLINGS = ["", "N/A", "NULL"]


def iter_prepared(name: str):
    """Stream a prepared file a row at a time. Memory stays flat."""
    path = PREPARED / f"{name}.csv"
    if not path.exists():
        raise SystemExit(f"ERROR: {path} not found. Run ./scripts/03_prepare.py first.")
    with path.open(encoding="utf-8", newline="") as fh:
        yield from csv.DictReader(fh)


def read_prepared(name: str) -> list[dict[str, str]]:
    path = PREPARED / f"{name}.csv"
    if not path.exists():
        raise SystemExit(f"ERROR: {path} not found. Run ./scripts/03_prepare.py first.")
    with path.open(encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))


def mask_pan(pan: str) -> str:
    """A real extract would not carry a full PAN. Neither will this one."""
    digits = "".join(ch for ch in pan if ch.isdigit())
    return f"****{digits[-4:]}" if len(digits) >= 4 else "****"


def money_messy(amount: Decimal, idx: int) -> str:
    """Same number, formatted the way a spreadsheet export mangles it."""
    neg = amount < 0
    a = abs(amount)
    if idx % 4 == 0:
        s = f"{a:,.2f}"            # thousands separator
    elif idx % 4 == 1:
        s = f"${a:,.2f}"           # currency symbol
    elif idx % 4 == 2:
        s = f"{a:.2f}"             # plain
    else:
        s = f"USD {a:,.2f}"        # currency as a prefix word
    return f"({s})" if neg else s


def date_messy(ts: datetime, idx: int) -> str:
    """
    Alternating UK and ISO. This is the single most dangerous defect in the
    file: 03/04/2019 is the 3rd of April in London and the 4th of March in
    Redmond, and nothing in the file says which.
    """
    if idx % 3 == 0:
        return ts.strftime("%d/%m/%Y")
    if idx % 3 == 1:
        return ts.strftime("%Y-%m-%d")
    return ts.strftime("%d-%b-%Y")


def state_messy(state: str, idx: int) -> str:
    if idx % 5 == 0:
        return state.lower()
    if idx % 5 == 1:
        return f" {state}"
    if idx % 5 == 2:
        return f"{state} "
    return state


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--months", nargs="*", default=None,
                    help="YYYY-MM values. Default: the last three months present.")
    ap.add_argument("--clean", action="store_true",
                    help="also write a clean copy alongside, for comparison")
    args = ap.parse_args()

    # The dimension files are small enough to hold: a few thousand customers and
    # cards even in the full dataset. The transaction file is not — the real one
    # is ~13 million rows, so it is streamed twice rather than loaded.
    customers = {c["CUSTOMER_ID"]: c for c in read_prepared("CUSTOMERS")}
    cards = {c["CARD_ID"]: c for c in read_prepared("CARDS")}

    # Pass 1: which months exist, and how big is each. Counts only — nothing is
    # retained. An earlier version built a dict of every transaction grouped by
    # month, which is fine for a 5,000-row fixture and several gigabytes of
    # Python dictionaries for the real file.
    month_counts: dict[str, int] = defaultdict(int)
    for t in iter_prepared("TRANSACTIONS"):
        month_counts[t["TXN_TS"][:7]] += 1

    if not month_counts:
        raise SystemExit("ERROR: TRANSACTIONS.csv contains no rows.")

    months = args.months or sorted(month_counts)[-3:]
    missing = [m for m in months if m not in month_counts]
    if missing:
        raise SystemExit(
            f"ERROR: no transactions for {', '.join(missing)}.\n"
            f"       Available: {sorted(month_counts)[0]} .. {sorted(month_counts)[-1]}"
        )

    # Pass 2: keep only the months actually being written. For a three-month
    # window that is a few thousand rows regardless of how big the source is.
    wanted = set(months)
    by_month: dict[str, list[dict[str, str]]] = defaultdict(list)
    for t in iter_prepared("TRANSACTIONS"):
        m = t["TXN_TS"][:7]
        if m in wanted:
            by_month[m].append(t)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    SAMPLE_DIR.mkdir(parents=True, exist_ok=True)

    # Clear previously generated extracts. Running with a different --months set
    # otherwise leaves old files behind, and csv-drop/README tells the operator
    # to upload incoming/*.csv — so a stale month would be ingested without ever
    # appearing in the manifest or the reconciliation.
    for old_file in list(OUT_DIR.glob("Equation_Extract_*.csv")) + list(OUT_DIR.glob("clean_*.csv")):
        old_file.unlink()

    manifest: dict = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "purpose": (
            "Fallback for the Db2 path, and the 'before' artefact. Row counts and "
            "control totals below are the TRUTH and must match what Db2 returns for "
            "the same window. The file itself presents those values badly on purpose."
        ),
        "reconciliation_sql": (
            "SELECT COUNT(*), SUM(AMOUNT) FROM NBKI.TRANSACTIONS "
            "WHERE TXN_TS >= '{month}-01-00.00.00' AND TXN_TS < '{next_month}-01-00.00.00'"
        ),
        "files": [],
    }

    for month in months:
        rows = sorted(by_month[month], key=lambda r: (r["TXN_TS"], int(r["TRANSACTION_ID"])))
        fname = f"Equation_Extract_{month}.csv"
        path = OUT_DIR / fname

        true_count = len(rows)
        true_total = sum(Decimal(r["AMOUNT"]) for r in rows)

        out_rows: list[list[str]] = []
        for idx, t in enumerate(rows):
            cust = customers.get(t["CUSTOMER_ID"], {})
            card = cards.get(t["CARD_ID"], {})
            ts = datetime.strptime(t["TXN_TS"], "%Y-%m-%d %H:%M:%S")
            amt = Decimal(t["AMOUNT"])

            notes = t.get("ERROR_FLAGS") or ""
            if not notes:
                notes = MISSING_SPELLINGS[idx % len(MISSING_SPELLINGS)]

            out_rows.append([
                t["TRANSACTION_ID"],
                date_messy(ts, idx),
                t["CUSTOMER_ID"],
                mask_pan(card.get("CARD_NUMBER", "")),
                card.get("CARD_BRAND", "N/A"),
                card.get("CARD_TYPE", "N/A"),
                money_messy(amt, idx),
                t.get("USE_CHIP", ""),
                t.get("MERCHANT_ID", ""),
                t.get("MERCHANT_CITY", ""),
                state_messy(t.get("MERCHANT_STATE", ""), idx),
                t.get("MERCHANT_ZIP", ""),
                t.get("MCC_CODE", ""),
                cust.get("CURRENT_AGE", "NULL"),
                cust.get("CREDIT_SCORE", "NULL"),
                notes,
            ])

        # Defect 8: one transaction appears twice, with nothing to distinguish
        # the copies. Declared in the manifest so the reconciliation is honest.
        duplicated_ref = None
        dup_amount = Decimal(0)
        if len(out_rows) > 3:
            duplicated_ref = out_rows[2][0]
            dup_amount = Decimal(rows[2]["AMOUNT"])
            out_rows.insert(3, list(out_rows[2]))

        # The footer total is what a spreadsheet SUM() over the rows would give,
        # so it includes the duplicate. It therefore disagrees with the real
        # total by exactly one transaction — which is the point.
        apparent_total = true_total + dup_amount

        y, m = month.split("-")
        nxt = f"{int(y) + 1}-01" if m == "12" else f"{y}-{int(m) + 1:02d}"

        # Written with CRLF (defect 10) — a Windows export, because it was one.
        with path.open("w", encoding="utf-8", newline="") as fh:
            w = csv.writer(fh, lineterminator="\r\n")
            # Defect 1 + 12: provenance sits above the header, in prose.
            w.writerow([f"EQUATION CORE BANKING - CARD TRANSACTION EXTRACT"])
            w.writerow([f"Report run: {datetime.now().strftime('%d/%m/%Y %H:%M')}",
                        f"Period: {month}"])
            w.writerow([])
            w.writerow(HEADER)
            w.writerows(out_rows)
            # Defect 6 + 5 + 11: blank line, then a total, then more junk.
            w.writerow([])
            total_row = [""] * len(HEADER)
            total_row[0] = "TOTAL"
            total_row[6] = f"{apparent_total:,.2f}"
            w.writerow(total_row)
            w.writerow(["End of Report"])

        file_info = {
            "file": fname,
            "month": month,
            "data_rows_in_file": len(out_rows),
            "true_transaction_count": true_count,
            "true_amount_total": str(true_total),
            "footer_total_shown_in_file": str(apparent_total),
            "duplicated_transaction_ref": duplicated_ref,
            "reconciliation_sql": (
                f"SELECT COUNT(*), SUM(AMOUNT) FROM NBKI.TRANSACTIONS "
                f"WHERE TXN_TS >= '{month}-01 00:00:00' AND TXN_TS < '{nxt}-01 00:00:00'"
            ),
            "note": (
                f"The file holds {len(out_rows)} data rows but only {true_count} real "
                f"transactions: ref {duplicated_ref} is present twice. Bronze must "
                f"dedupe, or the month over-reports."
            ),
            "rows_to_skip_before_header": 3,
            "footer_rows_to_discard": 3,
        }
        manifest["files"].append(file_info)

        if args.clean:
            clean_path = OUT_DIR / f"clean_{month}.csv"
            with clean_path.open("w", encoding="utf-8", newline="") as fh:
                w = csv.writer(fh)
                w.writerow(HEADER)
                for t in rows:
                    cust = customers.get(t["CUSTOMER_ID"], {})
                    card = cards.get(t["CARD_ID"], {})
                    w.writerow([
                        t["TRANSACTION_ID"], t["TXN_TS"][:10], t["CUSTOMER_ID"],
                        mask_pan(card.get("CARD_NUMBER", "")),
                        card.get("CARD_BRAND", ""), card.get("CARD_TYPE", ""),
                        t["AMOUNT"], t.get("USE_CHIP", ""), t.get("MERCHANT_ID", ""),
                        t.get("MERCHANT_CITY", ""), t.get("MERCHANT_STATE", ""),
                        t.get("MERCHANT_ZIP", ""), t.get("MCC_CODE", ""),
                        cust.get("CURRENT_AGE", ""), cust.get("CREDIT_SCORE", ""),
                        t.get("ERROR_FLAGS", ""),
                    ])

    # A committed sample so the repo demonstrates the shape without carrying
    # the whole extract.
    first = manifest["files"][0]["file"]
    sample_src = (OUT_DIR / first).read_bytes().split(b"\r\n")
    sample = b"\r\n".join(sample_src[:15]) + b"\r\n"
    (SAMPLE_DIR / first).write_bytes(sample)

    grand_rows = sum(f["true_transaction_count"] for f in manifest["files"])
    grand_total = sum(Decimal(f["true_amount_total"]) for f in manifest["files"])
    manifest["totals"] = {
        "true_transaction_count": grand_rows,
        "true_amount_total": str(grand_total),
        "data_rows_across_files": sum(f["data_rows_in_file"] for f in manifest["files"]),
    }
    (DROP_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    print(f"Wrote {len(months)} extract(s) to {OUT_DIR.relative_to(REPO_ROOT)}/")
    for f in manifest["files"]:
        print(f"  {f['file']:<32} {f['data_rows_in_file']:>5} data rows "
              f"({f['true_transaction_count']} real)  total {f['true_amount_total']}")
    print()
    print(f"  TRUE totals: {grand_rows} transactions, {grand_total}")
    print(f"  Sample committed: csv-drop/samples/{first}")
    print(f"  Expectations:     csv-drop/manifest.json")
    print()
    print("These must reconcile against Db2. Each file carries the SQL to prove it.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
