#!/usr/bin/env python3
"""
06_make_delta.py — generate the second batch that makes the incremental load real.

Why a delta batch is necessary
------------------------------
The initial bulk load stamps every row with a watermark inside the same few
milliseconds. That is correct — the first run is a full load — but it means the
watermark cannot be *seen* working. A second batch, applied after the first read,
is what demonstrates that Fabric picks up only what changed.

It contains three things deliberately:

  1. INSERTs with later business timestamps   -> new rows appear
  2. UPDATEs to existing rows                 -> proves ROW CHANGE TIMESTAMP fires
                                                 on modification, not just insert
  3. Business-rule violations                 -> gives the silver DQ rules and the
                                                 quarantine table something real to catch

On what "bad data" means here
-----------------------------
Db2 enforces the foreign keys and NOT NULL constraints, so structurally broken
rows cannot be inserted at all. That is the correct behaviour and we are not
going to disable it to stage a demo.

So the violations here are *business* violations that are structurally legal:
zero-value transactions, implausible amounts, future-dated rows, inconsistent
merchant-state casing, and a duplicated business key. Structural corruption —
orphan references, missing required fields — arrives through the CSV-drop path
instead (scripts/07_make_csv_drop.py), which is exactly how it reaches a bank in
real life: not from the database, but from a hand-made extract.

That split is worth stating out loud during the demo. It is the difference
between a governed source and a spreadsheet.

Idempotent: re-running produces the same statements, and applying them twice is
safe (deletes precede inserts for the same keys).

Usage:
    ./scripts/06_make_delta.py
    ./scripts/06_make_delta.py --new 500 --updates 100
"""

from __future__ import annotations

import argparse
import csv
import json
import random
from datetime import datetime, timedelta
from decimal import Decimal
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PREPARED = REPO_ROOT / "data" / "prepared"
OUT_DIR = REPO_ROOT / "db2" / "delta"

SEED = 991  # fixed: the delta must be identical on every rehearsal

# Deliberately small. The point is to be hand-checkable on stage — you should be
# able to show the quarantine table and have someone count the rows.
DEFAULT_NEW = 250
DEFAULT_UPDATES = 50


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
        raise SystemExit(
            f"ERROR: {path} not found. Run ./scripts/03_prepare.py first."
        )
    with path.open(encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))


def sql_str(v: str) -> str:
    return "'" + v.replace("'", "''") + "'"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--new", type=int, default=DEFAULT_NEW)
    ap.add_argument("--updates", type=int, default=DEFAULT_UPDATES)
    ap.add_argument("--schema", default="NBKI")
    args = ap.parse_args()

    rng = random.Random(SEED)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    cards = read_prepared("CARDS")
    card_by_id = {c["CARD_ID"]: c for c in cards}

    # One streaming pass over the transaction file. It computes the maximum ID
    # and timestamp, and picks the rows to update by reservoir sampling, so
    # memory is bounded by --updates rather than by the size of the source. The
    # real transaction file is ~13 million rows; the previous version read it
    # into a list of dictionaries first.
    max_id = 0
    max_ts: datetime | None = None
    reservoir: list[dict[str, str]] = []
    k = args.updates
    seen = 0
    for t in iter_prepared("TRANSACTIONS"):
        seen += 1
        tid = int(t["TRANSACTION_ID"])
        if tid > max_id:
            max_id = tid
        ts = datetime.strptime(t["TXN_TS"], "%Y-%m-%d %H:%M:%S")
        if max_ts is None or ts > max_ts:
            max_ts = ts
        # Algorithm R. Keeps a uniform sample of size k in a single pass, and is
        # deterministic here because rng is seeded.
        if len(reservoir) < k:
            reservoir.append(t)
        else:
            j = rng.randrange(seen)
            if j < k:
                reservoir[j] = t

    if seen == 0:
        raise SystemExit("ERROR: TRANSACTIONS.csv is empty.")

    update_targets = sorted(reservoir, key=lambda r: int(r["TRANSACTION_ID"]))

    s = args.schema
    lines: list[str] = []
    manifest: dict = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "seed": SEED,
        "base_max_transaction_id": max_id,
        "base_max_txn_ts": max_ts.strftime("%Y-%m-%d %H:%M:%S"),
    }

    lines.append("--")
    lines.append("-- delta_01_apply.sql — GENERATED by scripts/06_make_delta.py")
    lines.append("--")
    lines.append("-- Apply AFTER the first bronze read, so the incremental run has")
    lines.append("-- something to find. Safe to run more than once.")
    lines.append("--")
    lines.append("")

    new_ids = list(range(max_id + 1, max_id + 1 + args.new))

    # Re-running must not collide on the primary key.
    #
    # Scoped to the exact ID range this delta owns. An earlier version used
    # "WHERE TRANSACTION_ID > max_id", which does not mean "remove this delta" —
    # it means "remove every transaction added since the snapshot", which would
    # take unrelated rows with it. On a demo database that is an inconvenience;
    # the same statement copied into anything real is data loss.
    lines.append("-- Idempotency: remove only the rows THIS delta owns.")
    lines.append("-- Scoped to an exact ID range on purpose - see the comment in the generator.")
    lines.append(
        f"DELETE FROM {s}.TRANSACTIONS "
        f"WHERE TRANSACTION_ID BETWEEN {new_ids[0]} AND {new_ids[-1]};"
    )
    lines.append("")

    # -- 1. new rows -------------------------------------------------------
    lines.append(f"-- 1. {args.new} new transactions, all timestamped after the base load.")
    lines.append("--    These are what a watermark-based incremental read should return.")
    good_total = Decimal(0)
    all_new_total = Decimal(0)
    bad_rows: list[tuple[int, str]] = []

    # A handful of business-rule violations mixed in among the good rows.
    violation_ids = set(rng.sample(new_ids, k=min(12, len(new_ids))))
    violations = [
        "zero_amount", "zero_amount",
        "implausible_amount", "implausible_amount",
        "future_dated", "future_dated",
        "state_case_mismatch", "state_case_mismatch",
        "state_whitespace",
        "negative_non_refund",
        "duplicate_business_key", "duplicate_business_key",
    ]
    rng.shuffle(violations)
    vmap = dict(zip(sorted(violation_ids), violations))

    # A canonical transaction for the duplicate-key violation. Every row flagged
    # "duplicate_business_key" is emitted from THIS template, differing only in
    # TRANSACTION_ID — otherwise the two rows share nothing but an amount and a
    # timestamp, and no sensible business key would ever match them. A silver
    # rule keyed on card + timestamp + amount + merchant has to actually catch
    # these, or the demo asserts something the data does not show.
    dup_card = card_by_id[sorted(card_by_id)[0]]
    dup_template = {
        "card": dup_card,
        "ts": max_ts + timedelta(minutes=999),
        "amount": Decimal("123.45"),
        "state": "NY",
        "city": "New York",
        "mcc": "5812",
        "merchant": 55555,
        "zip": "10017",
    }

    for tid in new_ids:
        card = card_by_id[rng.choice(list(card_by_id))]
        ts = max_ts + timedelta(minutes=rng.randint(1, 60 * 24 * 7))
        amount = Decimal(str(round(rng.uniform(2.0, 850.0), 2)))
        state = rng.choice(["CA", "NY", "TX", "FL", "WA"])
        city = rng.choice(["Los Angeles", "New York", "Houston", "Miami", "Seattle"])
        mcc = rng.choice(["5812", "5411", "5541", "4121", "5912"])
        merchant = rng.randint(1000, 99999)
        note = vmap.get(tid)

        if note == "zero_amount":
            amount = Decimal("0.00")
        elif note == "implausible_amount":
            amount = Decimal("9999999.99")      # far outside observed range
        elif note == "future_dated":
            # Anchored to the data, not to wall-clock time: using datetime.now()
            # here made the generated SQL differ on every run, which contradicts
            # the fixed seed and made the output impossible to diff.
            ts = max_ts + timedelta(days=rng.randint(400, 800))
        elif note == "state_case_mismatch":
            state = state.lower()
        elif note == "state_whitespace":
            state = f" {state} "
        elif note == "negative_non_refund":
            amount = Decimal("-250.00")
            mcc = "4900"                        # a utility bill should not be negative
        elif note == "duplicate_business_key":
            # The same real-world event twice, under two different primary keys.
            # Every business attribute is taken from the template so the rows are
            # genuinely indistinguishable apart from TRANSACTION_ID.
            card = dup_template["card"]
            ts = dup_template["ts"]
            amount = dup_template["amount"]
            state = dup_template["state"]
            city = dup_template["city"]
            mcc = dup_template["mcc"]
            merchant = dup_template["merchant"]

        if note:
            bad_rows.append((tid, note))
        else:
            good_total += amount
        # Every new row, planted violations included. 05_verify.sh needs this to
        # predict the post-delta control total; good_total alone would leave it
        # short by the value of the deliberately-wrong rows.
        all_new_total += amount

        lines.append(
            f"INSERT INTO {s}.TRANSACTIONS "
            f"(TRANSACTION_ID, TXN_TS, CUSTOMER_ID, CARD_ID, AMOUNT, USE_CHIP, "
            f"MERCHANT_ID, MERCHANT_CITY, MERCHANT_STATE, MERCHANT_ZIP, MCC_CODE, ERROR_FLAGS) "
            f"VALUES ({tid}, TIMESTAMP({sql_str(ts.strftime('%Y-%m-%d %H:%M:%S'))}), "
            f"{card['CUSTOMER_ID']}, {card['CARD_ID']}, {amount}, "
            f"{sql_str('Chip Transaction')}, {merchant}, {sql_str(city)}, "
            f"{sql_str(state)}, {sql_str(dup_template['zip'] if note == 'duplicate_business_key' else str(rng.randint(10000, 99999)))}, "
            f"{sql_str(mcc)}, {sql_str('')});"
        )
    lines.append("")

    # -- 2. updates --------------------------------------------------------
    lines.append(f"-- 2. {len(update_targets)} updates to pre-existing rows.")
    lines.append("--    The rows are NOT new, so only a watermark on LAST_UPDATED_TS finds")
    lines.append("--    them. A high-water mark on TXN_TS alone would miss every one.")
    for t in update_targets:
        new_flag = rng.choice(["Reviewed", "Adjusted", "Re-presented"])
        lines.append(
            f"UPDATE {s}.TRANSACTIONS SET ERROR_FLAGS = {sql_str(new_flag)} "
            f"WHERE TRANSACTION_ID = {t['TRANSACTION_ID']};"
        )
    lines.append("")
    lines.append("COMMIT;")
    lines.append("")

    (OUT_DIR / "delta_01_apply.sql").write_text("\n".join(lines), encoding="utf-8")

    # -- rollback ----------------------------------------------------------
    rb = [
        "--",
        "-- delta_02_rollback.sql — GENERATED by scripts/06_make_delta.py",
        "--",
        "-- Returns the table to its post-load state so the demo can be run again.",
        "-- Note: the UPDATEs cannot be undone to their exact prior values, so a full",
        "-- reset means re-running ./scripts/04_load.sh. This just removes the inserts.",
        "--",
        "",
        f"DELETE FROM {s}.TRANSACTIONS "
        f"WHERE TRANSACTION_ID BETWEEN {new_ids[0]} AND {new_ids[-1]};",
        "COMMIT;",
        "",
    ]
    (OUT_DIR / "delta_02_rollback.sql").write_text("\n".join(rb), encoding="utf-8")

    # -- expectations ------------------------------------------------------
    manifest.update({
        "new_rows": args.new,
        "new_transaction_id_range": [new_ids[0], new_ids[-1]],
        "updated_rows": len(update_targets),
        "updated_transaction_ids": sorted(int(t["TRANSACTION_ID"]) for t in update_targets),
        "rows_an_incremental_read_should_return": args.new + len(update_targets),
        "clean_new_row_amount_total": str(good_total),
        "new_row_amount_total": str(all_new_total),
        # The UPDATEs only touch ERROR_FLAGS, never AMOUNT, so the post-delta
        # control total is exactly base + new_row_amount_total. If that ever
        # stops being true, 05_verify.sh's delta arithmetic breaks with it.
        "updates_change_amount": False,
        "planted_violations": [
            {"transaction_id": tid, "rule": rule} for tid, rule in sorted(bad_rows)
        ],
        "violation_summary": {
            r: sum(1 for _, x in bad_rows if x == r) for r in sorted({x for _, x in bad_rows})
        },
        "_note": (
            "Structural corruption (orphan keys, missing required fields) is NOT here. "
            "Db2 enforces those constraints and we are not disabling them. That class of "
            "error arrives through the CSV-drop path instead, which is how it reaches a "
            "bank in reality."
        ),
    })
    (OUT_DIR / "delta_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    print(f"Wrote {OUT_DIR.relative_to(REPO_ROOT)}/")
    print(f"  delta_01_apply.sql      {args.new} inserts + {len(update_targets)} updates")
    print(f"  delta_02_rollback.sql")
    print(f"  delta_manifest.json     expected results for the incremental read")
    print()
    print(f"An incremental read should return {args.new + len(update_targets)} rows "
          f"({args.new} new, {len(update_targets)} changed).")
    print(f"Planted business-rule violations: {len(bad_rows)}")
    for rule, n in sorted(manifest["violation_summary"].items()):
        print(f"    {rule:<24} {n}")
    print()
    print("Apply with:  ./scripts/08_apply_delta.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
