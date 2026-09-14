#!/usr/bin/env python3
"""
dev_make_fixtures.py — synthesise small stand-in files shaped like the real Kaggle data.

Why this exists
---------------
Two reasons, and the second is the important one.

1. The real download needs Kaggle credentials. Fixtures let the whole pipeline be
   built and proven before those exist.

2. **They are a permanent smoke test.** The real files are 1.4 GB; you do not want
   to re-download them to check that a change to the prepare step still works.
   These run the entire chain — profile, DDL, prepare, load, verify — in seconds.

The fixtures deliberately reproduce the *awkward* properties we expect, not the
convenient ones: currency strings, MM/YYYY dates, nested JSON, CRLF endings,
embedded commas, nulls and negative amounts. A pipeline that only works on clean
data has not been tested.

These are NOT a substitute for profiling the real files. Column names here reflect
what we expect; `01_profile.py` on real data is what settles it.

Usage:
    ./scripts/dev_make_fixtures.py                 # 500 users, ~5000 transactions
    ./scripts/dev_make_fixtures.py --scale 5       # 5x that
    ./scripts/dev_make_fixtures.py --out data/raw  # default
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from datetime import datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO_ROOT / "data" / "raw"

SEED = 20240613  # fixed, so fixtures are reproducible and control totals are stable

CARD_BRANDS = ["Visa", "Mastercard", "Amex", "Discover"]
CARD_TYPES = ["Debit", "Credit", "Debit (Prepaid)"]
US_STATES = ["CA", "NY", "TX", "FL", "IL", "WA", "MA", "GA", "NC", "OH"]
CITIES = ["Los Angeles", "New York", "Houston", "Miami", "Chicago", "Seattle", "Boston"]
USE_CHIP = ["Swipe Transaction", "Chip Transaction", "Online Transaction"]
ERRORS = ["", "", "", "", "Insufficient Balance", "Bad PIN", "Technical Glitch"]

MCC = {
    "5812": "Eating Places and Restaurants",
    "5411": "Grocery Stores, Supermarkets",
    "5541": "Service Stations",
    "4121": "Taxicabs and Limousines",
    "5912": "Drug Stores and Pharmacies",
    "4900": "Utilities - Electric, Gas, Water",
    "5732": "Electronics Sales",
    "3001": "Airlines - Hotels, Travel",
    "6011": "Automated Cash Disbursements",
    "5999": "Miscellaneous and Specialty Retail",
}

CURRENCIES = ["US Dollar", "Euro", "Yuan", "Rupee", "Yen", "UK Pound", "Bitcoin"]
PAYMENT_FORMATS = ["Cheque", "Credit Card", "ACH", "Wire", "Reinvestment", "Bitcoin", "Cash"]


def money(x: float) -> str:
    """Format as the dataset does: '$1,234.56', negatives as '-$12.00'."""
    s = f"${abs(x):,.2f}"
    return f"-{s}" if x < 0 else s


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--scale", type=int, default=1, help="multiplier on the base row counts")
    ap.add_argument("--force", action="store_true",
                    help="overwrite real downloaded data (you almost certainly do not want this)")
    args = ap.parse_args()

    # Guard: never silently destroy real data.
    #
    # This writes to the same paths, with the same filenames, as the real
    # Kaggle download — deliberately, so the rest of the pipeline needs no
    # special cases. The cost of that choice is that an absent-minded run here
    # would overwrite a ~1.8 GB download that is rate-limited, slow, and needs
    # credentials to repeat. 00_download.sh refuses to write over fixtures;
    # this is the same guard pointing the other way.
    prov = args.out / ".provenance"
    if prov.exists() and not args.force:
        try:
            existing = json.loads(prov.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            existing = {}
        if existing.get("source") == "kaggle":
            print(f"ERROR: {args.out} holds REAL data downloaded from Kaggle", file=sys.stderr)
            print(f"       ({existing.get('downloaded_at', 'unknown date')}, "
                  f"variant {existing.get('aml_variant', '?')}).", file=sys.stderr)
            print(file=sys.stderr)
            print("       Overwriting it with fixtures would throw away a ~1.8 GB", file=sys.stderr)
            print("       download that needs credentials to repeat.", file=sys.stderr)
            print(file=sys.stderr)
            print("       To generate fixtures somewhere harmless:", file=sys.stderr)
            print("         ./scripts/dev_make_fixtures.py --out data/fixtures", file=sys.stderr)
            print(file=sys.stderr)
            print("       If you really do mean to replace the real data, pass --force.", file=sys.stderr)
            return 1

    rng = random.Random(SEED)
    n_users = 500 * args.scale
    n_txn = 5000 * args.scale

    primary = args.out / "computingvictor"
    aml = args.out / "aml"
    primary.mkdir(parents=True, exist_ok=True)
    aml.mkdir(parents=True, exist_ok=True)

    # -- users -------------------------------------------------------------
    # Money columns are currency STRINGS, which is the whole point.
    users = []
    for uid in range(1, n_users + 1):
        age = rng.randint(18, 85)
        income = rng.randint(18_000, 240_000)
        users.append({
            "id": uid,
            "current_age": age,
            "retirement_age": rng.randint(60, 70),
            "birth_year": datetime.now().year - age,
            "birth_month": rng.randint(1, 12),
            "gender": rng.choice(["Male", "Female"]),
            # Embedded comma inside a quoted field — a classic LOAD breaker.
            "address": f"{rng.randint(1, 9999)} {rng.choice(['Oak', 'Main', 'Elm'])} Street, Apt {rng.randint(1, 99)}",
            "latitude": round(rng.uniform(25.0, 48.0), 4),
            "longitude": round(rng.uniform(-124.0, -67.0), 4),
            "per_capita_income": money(rng.randint(12_000, 90_000)),
            "yearly_income": money(income),
            "total_debt": money(rng.randint(0, 400_000)),
            # ~2% missing, to give the profiler a real null rate to find.
            "credit_score": "" if rng.random() < 0.02 else rng.randint(480, 850),
            "num_credit_cards": rng.randint(1, 7),
        })

    write_csv(primary / "users_data.csv", users)

    # -- cards -------------------------------------------------------------
    # MM/YYYY dates: no day component, so DATE would have to invent one.
    cards = []
    card_id = 0
    for u in users:
        for _ in range(rng.randint(1, 3)):
            card_id += 1
            cards.append({
                "id": card_id,
                "client_id": u["id"],
                "card_brand": rng.choice(CARD_BRANDS),
                "card_type": rng.choice(CARD_TYPES),
                "card_number": f"{rng.randint(4000, 5999)}{rng.randint(100000000000, 999999999999)}",
                "expires": f"{rng.randint(1, 12):02d}/{rng.randint(2024, 2030)}",
                "cvv": f"{rng.randint(1, 999):03d}",
                "has_chip": rng.choice(["YES", "NO"]),
                "num_cards_issued": rng.randint(1, 3),
                "credit_limit": money(rng.randrange(500, 50_000, 500)),
                "acct_open_date": f"{rng.randint(1, 12):02d}/{rng.randint(2002, 2019)}",
                "year_pin_last_changed": rng.randint(2010, 2020),
                "card_on_dark_web": rng.choice(["No", "No", "No", "Yes"]),
            })
    write_csv(primary / "cards_data.csv", cards)

    # -- transactions ------------------------------------------------------
    # Full timestamps here, which is what makes a watermark viable.
    start = datetime(2010, 1, 1)
    span_seconds = int((datetime(2019, 12, 31) - start).total_seconds())
    txns = []
    for tid in range(1, n_txn + 1):
        card = rng.choice(cards)
        ts = start + timedelta(seconds=rng.randrange(span_seconds))
        # ~3% refunds, so negatives are exercised rather than theoretical.
        amt = round(rng.uniform(1.0, 900.0), 2) * (-1 if rng.random() < 0.03 else 1)
        txns.append({
            "id": tid,
            "date": ts.strftime("%Y-%m-%d %H:%M:%S"),
            "client_id": card["client_id"],
            "card_id": card["id"],
            "amount": money(amt),
            "use_chip": rng.choice(USE_CHIP),
            "merchant_id": rng.randint(1_000, 99_999),
            "merchant_city": rng.choice(CITIES),
            "merchant_state": rng.choice(US_STATES),
            "zip": rng.randint(10_000, 99_999),
            "mcc": rng.choice(list(MCC.keys())),
            "errors": rng.choice(ERRORS),
        })
    txns.sort(key=lambda r: r["date"])
    # CRLF on this one file, on purpose: the real files may well have it and the
    # prepare step has to survive it.
    write_csv(primary / "transactions_data.csv", txns, newline="\r\n")

    # -- reference JSON ----------------------------------------------------
    (primary / "mcc_codes.json").write_text(json.dumps(MCC, indent=2), encoding="utf-8")

    # Nested under a "target" wrapper — not a table, must be flattened.
    labels = {
        "target": {
            str(t["id"]): ("Yes" if rng.random() < 0.012 else "No")
            for t in txns
            if rng.random() < 0.6  # deliberately partial: not every txn is labelled
        }
    }
    (primary / "train_fraud_labels.json").write_text(json.dumps(labels, indent=2), encoding="utf-8")

    # -- AML ---------------------------------------------------------------
    # Note the two quirks we must handle: spaces in every header, and a column
    # literally named "Account.1".
    aml_start = datetime(2022, 9, 1)
    aml_rows = []
    n_accounts = max(50, n_users // 4)
    accounts = [f"{rng.randint(0x10000000, 0xFFFFFFFF):08X}" for _ in range(n_accounts)]
    banks = [f"{rng.randint(1, 30000):06d}" for _ in range(20)]
    for _ in range(n_txn * 2):
        cur = rng.choice(CURRENCIES)
        amt = round(rng.uniform(5.0, 250_000.0), 2)
        ts = aml_start + timedelta(seconds=rng.randrange(10 * 24 * 3600))
        aml_rows.append({
            "Timestamp": ts.strftime("%Y/%m/%d %H:%M"),
            "From Bank": rng.choice(banks),
            "Account": rng.choice(accounts),
            "To Bank": rng.choice(banks),
            "Account.1": rng.choice(accounts),
            "Amount Received": f"{amt:.2f}",
            "Receiving Currency": cur,
            "Amount Paid": f"{amt:.2f}",
            "Payment Currency": cur,
            "Payment Format": rng.choice(PAYMENT_FORMATS),
            "Is Laundering": 1 if rng.random() < 0.001 else 0,
        })
    aml_rows.sort(key=lambda r: r["Timestamp"])
    write_csv(aml / "HI-Small_Trans.csv", aml_rows)

    # Provenance marker. The fixtures deliberately use the same filenames as the
    # real Kaggle download so the rest of the pipeline needs no special cases —
    # which means without this marker, a later `00_download.sh` would see the
    # files, decide the data was already present, and silently leave synthetic
    # data in place. Every downstream script reads this.
    (args.out / ".provenance").write_text(
        json.dumps({
            "source": "fixtures",
            "generated_by": "scripts/dev_make_fixtures.py",
            "seed": SEED,
            "scale": args.scale,
            "generated_at": datetime.now().isoformat(timespec="seconds"),
            "warning": "SYNTHETIC DATA. Not the real dataset. Never show these figures to a customer.",
        }, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"Fixtures written to {args.out}")
    print(f"  users_data.csv         {len(users):,}")
    print(f"  cards_data.csv         {len(cards):,}")
    print(f"  transactions_data.csv  {len(txns):,}   (CRLF line endings, on purpose)")
    print(f"  mcc_codes.json         {len(MCC)} codes")
    print(f"  train_fraud_labels.json {len(labels['target']):,} labels (nested, partial)")
    print(f"  HI-Small_Trans.csv     {len(aml_rows):,}")
    print(f"  .provenance            source=fixtures")
    print("\n  ** SYNTHETIC DATA ** — stands in for the real files so the pipeline")
    print("  is provable without Kaggle credentials. Run ./scripts/01_profile.py next.")
    return 0


def write_csv(path: Path, rows: list[dict], newline: str = "\n") -> None:
    """Write with csv so quoting is correct, but control the line ending ourselves."""
    import csv
    import io

    if not rows:
        return
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=list(rows[0].keys()), lineterminator=newline)
    w.writeheader()
    w.writerows(rows)
    path.write_text(buf.getvalue(), encoding="utf-8", newline="")


if __name__ == "__main__":
    raise SystemExit(main())
