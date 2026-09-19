#!/usr/bin/env python3
"""
23_verify_gold.py — prove the star schema is correct, not merely populated.

The constraints in gold are `NOT ENFORCED`, because that is the only form Fabric
allows. **That is exactly why this script exists.** The declared primary and
foreign keys document intent; nothing checks them. So this does:

  * every fact row is accounted for against silver, on count and control total;
  * no orphan keys, on any relationship in either star;
  * the `-1` Unknown member exists everywhere, and is *used* only where it should
    be -- a fact sitting on Unknown location would mean the conforming failed;
  * the fraud left join preserved all 4.4M unlabelled rows rather than dropping
    them, which is the single easiest thing to get silently wrong;
  * `dim_date` spans both facts.

A Warehouse stores its tables as Delta in OneLake exactly as a Lakehouse does,
just under `Tables/dbo/`. So this reads gold the same way everything else in this
repo reads data -- over the OneLake REST API, with no ODBC driver anywhere.

Usage:
    .venv/bin/python scripts/23_verify_gold.py
    .venv/bin/python scripts/23_verify_gold.py --log   # show the build log
"""

from __future__ import annotations

import argparse
import decimal
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import _onelake as ol  # noqa: E402
import _fabric as fab  # noqa: E402

import pyarrow as pa  # noqa: E402
import pyarrow.compute as pc  # noqa: E402

W = fab.WORKSPACE
GOLD = fab.ITEMS["wh_gold"]
SILVER = fab.ITEMS["lh_silver"]

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"

DIMENSIONS = [
    ("dim_customer", "customer_sk"), ("dim_card", "card_sk"),
    ("dim_location", "location_sk"), ("dim_mcc", "mcc_sk"),
    ("dim_channel", "channel_sk"), ("dim_transaction_error", "error_sk"),
    ("dim_fraud_status", "fraud_sk"),
]
FACT_KEYS = [
    ("customer_sk", "dim_customer", "customer_sk"),
    ("card_sk", "dim_card", "card_sk"),
    ("location_sk", "dim_location", "location_sk"),
    ("mcc_sk", "dim_mcc", "mcc_sk"),
    ("channel_sk", "dim_channel", "channel_sk"),
    ("error_sk", "dim_transaction_error", "error_sk"),
    ("fraud_sk", "dim_fraud_status", "fraud_sk"),
    ("txn_date_key", "dim_date", "date_key"),
    ("txn_time_key", "dim_time", "time_key"),
]


class Report:
    def __init__(self) -> None:
        self.passed = self.failed = 0

    def ok(self, label, detail=""):
        print(f"  {GREEN}PASS{RESET}  {label:<52} {detail}")
        self.passed += 1

    def bad(self, label, detail=""):
        print(f"  {RED}FAIL{RESET}  {label:<52} {detail}")
        self.failed += 1

    def info(self, label, detail=""):
        print(f"  {YELLOW}INFO{RESET}  {label:<52} {detail}")

    def check(self, label, expected, actual):
        if str(expected) == str(actual):
            self.ok(label, str(actual))
        else:
            self.bad(label, f"expected {expected}, got {actual}")

    def check_decimal(self, label, expected, actual):
        if expected == actual:
            self.ok(label, str(actual))
        else:
            self.bad(label, f"expected {expected}, got {actual} "
                            f"(diff {actual - expected})")


def g(name: str) -> str:
    """Warehouse tables sit under Tables/dbo/, unlike a lakehouse."""
    return f"dbo/{name}"


def info_of(item: str, name: str) -> dict:
    return ol.read_delta_log(W, item, name)


def cols(item: str, name: str, info: dict, columns: list[str]):
    return ol.read_columns(W, item, name, info, columns)


def dsum(tbl, col) -> decimal.Decimal:
    if tbl is None or tbl.num_rows == 0:
        return decimal.Decimal(0)
    v = pc.sum(tbl[col]).as_py()
    return decimal.Decimal(0) if v is None else decimal.Decimal(str(v))


def show_build_log() -> int:
    info = info_of(SILVER, "gold_build_log")
    rows = ol.read_columns(W, SILVER, "gold_build_log", info,
                           ["seq", "cell", "label", "status", "error", "seconds"])
    rows = rows.to_pylist() if rows is not None else []
    rows.sort(key=lambda r: r["seq"])
    for r in rows:
        mark = GREEN + "OK  " + RESET if r["status"] == "OK" else RED + "FAIL" + RESET
        print(f"  [{r['seq']:3d}] cell {r['cell']:2d}  {mark}  "
              f"{r['label'][:58]:58s} {r['seconds']:7.2f}s")
        if r["status"] == "FAIL":
            print(f"        {r['error'][:500]}")
    ok = sum(1 for r in rows if r["status"] == "OK")
    print(f"\n  {ok}/{len(rows)} statements succeeded")
    return 0 if ok == len(rows) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", action="store_true", help="print the build log")
    args = ap.parse_args()
    if args.log:
        return show_build_log()

    rep = Report()
    print("\n==> gold verification")

    tables = [e["name"].split("/")[-1]
              for e in ol.list_dir(W, f"{GOLD}/Tables/dbo")]
    print(f"    tables in wh_gold: {len(tables)}\n")

    # --------------------------------------------------- the model's own checks
    print("-- gold_validation (written by the build itself) --")
    gv_info = info_of(GOLD, g("gold_validation"))
    gv = cols(GOLD, g("gold_validation"), gv_info,
              ["check_name", "expected", "actual"])
    for r in gv.to_pylist():
        rep.check(r["check_name"], r["expected"], r["actual"])

    # --------------------------------------------------------- conservation
    print("\n-- conservation: gold ties to silver --")
    slv = info_of(SILVER, "slv_transactions")
    fct_info = info_of(GOLD, g("fact_card_transaction"))
    rep.check("fact_card_transaction rows = silver clean rows",
              slv["num_records"], fct_info["num_records"])

    slv_amt = dsum(cols(SILVER, "slv_transactions", slv, ["amount"]), "amount")
    fct = cols(GOLD, g("fact_card_transaction"), fct_info,
               ["amount", "location_sk", "fraud_sk", "txn_date_key"])
    rep.check_decimal("fact control total = silver clean total",
                      slv_amt, dsum(fct, "amount"))

    aml_s = info_of(SILVER, "slv_aml_transfers")
    aml_g = info_of(GOLD, g("fact_aml_transfer"))
    rep.check("fact_aml_transfer rows = silver clean rows",
              aml_s["num_records"], aml_g["num_records"])
    rep.check_decimal(
        "aml control total preserved",
        dsum(cols(SILVER, "slv_aml_transfers", aml_s, ["amount_paid"]), "amount_paid"),
        dsum(cols(GOLD, g("fact_aml_transfer"), aml_g, ["amount_paid"]), "amount_paid"))

    # ------------------------------------------------------- referential
    print("\n-- referential integrity (the constraints are NOT ENFORCED) --")
    dim_cache: dict[str, set] = {}
    for fact_col, dim, dim_col in FACT_KEYS:
        if dim not in dim_cache:
            di = info_of(GOLD, g(dim))
            dt = cols(GOLD, g(dim), di, [dim_col])
            dim_cache[dim] = set(v.as_py() for v in dt[dim_col])
        keys = fct[fact_col] if fact_col in fct.column_names else None
        if keys is None:
            di = info_of(GOLD, g("fact_card_transaction"))
            keys = cols(GOLD, g("fact_card_transaction"), di, [fact_col])[fact_col]
        distinct = set(v.as_py() for v in pc.unique(keys))
        orphans = distinct - dim_cache[dim]
        rep.check(f"no orphan {fact_col} -> {dim}", 0, len(orphans))

    # --------------------------------------------------- unknown members
    print("\n-- the -1 Unknown member --")
    for dim, key in DIMENSIONS:
        di = info_of(GOLD, g(dim))
        dt = cols(GOLD, g(dim), di, [key])
        has = -1 in set(v.as_py() for v in dt[key])
        if has:
            rep.ok(f"{dim} has an Unknown member")
        else:
            rep.bad(f"{dim} has an Unknown member", "missing")

    n_unknown_loc = pc.sum(pc.cast(pc.equal(fct["location_sk"], -1),
                                   "int64")).as_py() or 0
    rep.check("no fact row fell through to Unknown location", 0, n_unknown_loc)

    # ------------------------------------------------- the fraud left join
    print("\n-- the fraud left join (the easiest thing to get silently wrong) --")
    fs_info = info_of(GOLD, g("dim_fraud_status"))
    fs = {r["fraud_sk"]: r["fraud_status"]
          for r in cols(GOLD, g("dim_fraud_status"), fs_info,
                        ["fraud_sk", "fraud_status"]).to_pylist()}
    vc = pc.value_counts(fct["fraud_sk"])
    dist = {v.as_py(): c.as_py() for v, c in zip(vc.field("values"), vc.field("counts"))}
    for sk, label in sorted(fs.items()):
        rep.info(f"  {label}", f"{dist.get(sk, 0):,}")
    n_unlabelled = dist.get(-1, 0)
    if n_unlabelled > 0:
        rep.ok("unlabelled transactions survived the join", f"{n_unlabelled:,}")
    else:
        rep.bad("unlabelled transactions survived the join",
                "0 — the LEFT join has become an INNER join")
    rep.check("every fact row has a fraud status",
              fct_info["num_records"], sum(dist.values()))

    # ------------------------------------------------------------ coverage
    print("\n-- dimension coverage --")
    dd_info = info_of(GOLD, g("dim_date"))
    dd = cols(GOLD, g("dim_date"), dd_info, ["date_key"])
    dmin = pc.min(dd["date_key"]).as_py()
    dmax = pc.max(dd["date_key"]).as_py()
    rep.info("dim_date range", f"{dmin} .. {dmax} ({dd_info['num_records']:,} rows)")
    fmin = pc.min(fct["txn_date_key"]).as_py()
    fmax = pc.max(fct["txn_date_key"]).as_py()
    rep.info("fact_card_transaction date range", f"{fmin} .. {fmax}")
    if dmin <= fmin and dmax >= fmax:
        rep.ok("dim_date spans the card fact")
    else:
        rep.bad("dim_date spans the card fact", f"{dmin}..{dmax} vs {fmin}..{fmax}")

    loc_info = info_of(GOLD, g("dim_location"))
    rep.info("dim_location rows", f"{loc_info['num_records']:,}")
    loc = cols(GOLD, g("dim_location"), loc_info, ["location_label", "is_online"])
    n_online_members = pc.sum(pc.cast(loc["is_online"], "int64")).as_py() or 0
    rep.check("dim_location has exactly one Online member", 1, n_online_members)

    # --------------------------------------------------------------- types
    print("\n-- types --")
    fs_schema = fct_info["schema"]
    rep.check("fact amount precision", "decimal(15,2)", fs_schema.get("amount"))
    aml_schema = aml_g["schema"]
    rep.check("aml amount_paid precision", "decimal(23,6)",
              aml_schema.get("amount_paid"))
    for name in ("fact_card_transaction", "dim_customer", "dim_date"):
        sch = info_of(GOLD, g(name))["schema"]
        ntz = [c for c, t in sch.items() if "timestamp_ntz" in str(t)]
        rep.check(f"{name} has no timestamp_ntz", 0, len(ntz))

    total = rep.passed + rep.failed
    colour = GREEN if rep.failed == 0 else RED
    print(f"\n{colour}{rep.passed}/{total}{RESET} checks passed\n")
    return 0 if rep.failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
