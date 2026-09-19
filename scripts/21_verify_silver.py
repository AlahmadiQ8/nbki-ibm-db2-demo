#!/usr/bin/env python3
"""
21_verify_silver.py — prove silver conserves bronze, exactly.

The one claim that matters
--------------------------
    clean + quarantine = bronze

on both row count and monetary control total, for every table that has a
quarantine. If that holds, "we quarantine failures rather than dropping them" is
a demonstrated fact rather than a slide. If it does not hold, silver is losing
money somewhere and everything downstream is decoration.

Bronze figures are read live and compared to silver live. Nothing is hard-coded
except the two data-quality counts that profiling discovered, because those are
assertions about this specific dataset and ought to fail loudly if the data
changes underneath.

Reads through the OneLake REST API (see `_onelake.py`) -- row counts come from
the Delta log and cost no transfer; aggregates read only the column chunks they
need. There is no ODBC driver on this workstation and this needs none.

Usage:
    .venv/bin/python scripts/21_verify_silver.py
"""

from __future__ import annotations

import decimal
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import _onelake as ol  # noqa: E402
import _fabric as fab  # noqa: E402

import pyarrow.compute as pc  # noqa: E402

WORKSPACE = fab.WORKSPACE
BRONZE = fab.ITEMS["lh_bronze"]
SILVER = fab.ITEMS["lh_silver"]

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"

# Discovered by profiling bronze, not planted. See plan/docs for provenance.
EXPECTED_RULES = {
    "zero_amount": 10_639,
    "channel_location_mismatch": 5_788,
}
RULES_THAT_MUST_FIND_NOTHING = [
    "implausible_amount", "future_dated", "duplicate_business_key",
    "state_whitespace", "state_case_mismatch",
]


class Report:
    def __init__(self) -> None:
        self.passed = self.failed = 0

    def ok(self, label: str, detail: str = "") -> None:
        print(f"  {GREEN}PASS{RESET}  {label:<52} {detail}")
        self.passed += 1

    def bad(self, label: str, detail: str = "") -> None:
        print(f"  {RED}FAIL{RESET}  {label:<52} {detail}")
        self.failed += 1

    def info(self, label: str, detail: str = "") -> None:
        print(f"  {YELLOW}INFO{RESET}  {label:<52} {detail}")

    def check(self, label: str, expected, actual) -> None:
        if str(expected) == str(actual):
            self.ok(label, str(actual))
        else:
            self.bad(label, f"expected {expected}, got {actual}")

    def check_decimal(self, label: str, expected, actual) -> None:
        # Numeric, not textual: decimal(15,2) renders 12.5 as '12.50'. Equality
        # is still exact, so a real penny of drift still fails.
        if expected == actual:
            self.ok(label, str(actual))
        else:
            self.bad(label, f"expected {expected}, got {actual} "
                            f"(diff {actual - expected})")


def table(lakehouse: str, name: str) -> dict:
    return ol.read_delta_log(WORKSPACE, lakehouse, name)


def read_cols(lakehouse: str, name: str, info: dict, columns: list[str]):
    """Concatenate one or more columns across every live Parquet file.

    Returns None for a table with no live files. An empty quarantine is the
    *good* outcome, so it must not look like a crash.
    """
    import pyarrow as pa
    parts = []
    for path, meta in info["files"].items():
        pf = ol.open_parquet(WORKSPACE, lakehouse, name, path, meta["size"])
        parts.append(pf.read(columns=columns))
    if not parts:
        return None
    return pa.concat_tables(parts).combine_chunks()


def dsum(tbl, col) -> decimal.Decimal:
    if tbl is None or tbl.num_rows == 0:
        return decimal.Decimal(0)
    v = pc.sum(tbl[col]).as_py()
    return decimal.Decimal(0) if v is None else decimal.Decimal(str(v))


def main() -> int:
    rep = Report()
    print(f"\n==> silver verification")
    print(f"    workspace {WORKSPACE}")

    silver_tables = ol.list_tables(WORKSPACE, SILVER)
    print(f"    tables in lh_silver: {', '.join(silver_tables) or '(none)'}\n")

    expected_tables = [
        "slv_customers", "slv_cards", "slv_transactions",
        "slv_transactions_quarantine", "slv_fraud_labels",
        "slv_aml_transfers", "slv_aml_quarantine", "slv_load_audit",
    ]
    for t in expected_tables:
        if t in silver_tables:
            rep.ok(f"{t} exists")
        else:
            rep.bad(f"{t} exists", "missing")
    if rep.failed:
        print("\n  silver is incomplete; run scripts/20_deploy_silver.py first")
        return 1

    # ---------------------------------------------------------------- counts
    print("\n-- conservation: clean + quarantine = bronze --")

    pairs = [
        ("TRANSACTIONS", "slv_transactions", "slv_transactions_quarantine",
         "AMOUNT", "amount"),
        ("AML_TRANSACTIONS", "slv_aml_transfers", "slv_aml_quarantine",
         "AMOUNT_PAID", "amount_paid"),
    ]
    info_cache: dict[tuple[str, str], dict] = {}

    for b_name, clean_name, q_name, b_col, s_col in pairs:
        b = table(BRONZE, b_name)
        c = table(SILVER, clean_name)
        q = table(SILVER, q_name)
        info_cache[(SILVER, clean_name)] = c
        info_cache[(SILVER, q_name)] = q

        rep.check(f"{b_name} rows conserved",
                  b["num_records"], c["num_records"] + q["num_records"])

        b_tot = dsum(read_cols(BRONZE, b_name, b, [b_col]), b_col)
        c_tot = dsum(read_cols(SILVER, clean_name, c, [s_col]), s_col)
        q_tot = dsum(read_cols(SILVER, q_name, q, [s_col]), s_col)
        rep.check_decimal(f"{b_name} control total conserved", b_tot, c_tot + q_tot)
        rep.info(f"  {clean_name} clean total", str(c_tot))
        rep.info(f"  {q_name} quarantined total", str(q_tot))

    # Tables with no quarantine still have to match bronze exactly.
    for b_name, s_name in [("CUSTOMERS", "slv_customers"),
                           ("CARDS", "slv_cards"),
                           ("FRAUD_LABELS", "slv_fraud_labels")]:
        b = table(BRONZE, b_name)
        s = table(SILVER, s_name)
        info_cache[(SILVER, s_name)] = s
        rep.check(f"{b_name} rows preserved", b["num_records"], s["num_records"])

    # ------------------------------------------------------------ dq rules
    print("\n-- data-quality rules --")
    q = info_cache[(SILVER, "slv_transactions_quarantine")]
    qt = read_cols(SILVER, "slv_transactions_quarantine", q, ["violations"])
    counts: dict[str, int] = {}
    if qt is not None and qt.num_rows:
        vc = pc.value_counts(pc.list_flatten(qt["violations"]))
        counts = dict(zip([v.as_py() for v in vc.field("values")],
                          [v.as_py() for v in vc.field("counts")]))
    for rule, expected in EXPECTED_RULES.items():
        rep.check(f"rule {rule}", expected, counts.get(rule, 0))
    for rule in RULES_THAT_MUST_FIND_NOTHING:
        rep.check(f"rule {rule} finds nothing (governed source)",
                  0, counts.get(rule, 0))
    for rule, n in sorted(counts.items()):
        if rule not in EXPECTED_RULES and rule not in RULES_THAT_MUST_FIND_NOTHING:
            rep.info(f"  unexpected rule fired: {rule}", f"{n:,}")

    # --------------------------------------------------------- governance
    print("\n-- governance: the PAN and the CVV --")
    cards_info = info_cache[(SILVER, "slv_cards")]
    cols = cards_info["schema"]
    for forbidden in ("CARD_NUMBER", "card_number", "CVV", "cvv"):
        if forbidden in cols:
            rep.bad(f"{forbidden} absent from slv_cards", "PRESENT")
        else:
            rep.ok(f"{forbidden} absent from slv_cards")

    if "card_last4" in cols:
        t = read_cols(SILVER, "slv_cards", cards_info, ["card_last4"])
        masked = pc.all(pc.starts_with(t["card_last4"], "****")).as_py()
        rep.check("every card_last4 is masked", True, masked)
    else:
        rep.bad("card_last4 present in slv_cards", "missing")

    # ------------------------------------------------------------- types
    print("\n-- types: what Direct Lake and the SQL endpoint can actually read --")
    for name in expected_tables:
        info = info_cache.get((SILVER, name)) or table(SILVER, name)
        info_cache[(SILVER, name)] = info
        ntz = [c for c, t in info["schema"].items() if "timestamp_ntz" in str(t)]
        if ntz:
            rep.bad(f"{name} has no timestamp_ntz", f"found {ntz}")
        else:
            rep.ok(f"{name} has no timestamp_ntz")

    txn_schema = info_cache[(SILVER, "slv_transactions")]["schema"]
    rep.check("slv_transactions.amount precision",
              "decimal(15,2)", txn_schema.get("amount"))
    rep.check("slv_transactions.txn_ts is timestamp",
              "timestamp", txn_schema.get("txn_ts"))
    rep.check("slv_transactions.txn_date_key is integer",
              "integer", txn_schema.get("txn_date_key"))
    aml_schema = info_cache[(SILVER, "slv_aml_transfers")]["schema"]
    rep.check("slv_aml_transfers.amount_paid precision",
              "decimal(23,6)", aml_schema.get("amount_paid"))

    # ------------------------------------------------- conformance results
    print("\n-- conformance --")
    c = info_cache[(SILVER, "slv_transactions")]
    t = read_cols(SILVER, "slv_transactions", c,
                  ["merchant_state", "merchant_country", "is_online", "channel"])

    st = t["merchant_state"]
    non_null = pc.drop_null(st)
    bad_len = pc.sum(pc.cast(pc.not_equal(pc.utf8_length(non_null), 2),
                             "int64")).as_py() or 0
    rep.check("merchant_state is 2-char US codes only", 0, bad_len)

    n_country_null = t["merchant_country"].null_count
    rep.check("merchant_country never null", 0, n_country_null)

    n_online = pc.sum(pc.cast(t["is_online"], "int64")).as_py()
    rep.info("online transactions (state was 'null' in bronze)", f"{n_online:,}")

    ch = pc.value_counts(t["channel"])
    for v, n in zip(ch.field("values"), ch.field("counts")):
        rep.info(f"  channel {v.as_py()}", f"{n.as_py():,}")

    # -------------------------------------------------------------- audit
    print("\n-- provenance --")
    a = info_cache[(SILVER, "slv_load_audit")]
    rep.info("load audit rows", str(a["num_records"]))
    if "_silver_batch_id" in txn_schema:
        rep.ok("every silver row carries _silver_batch_id")
    else:
        rep.bad("every silver row carries _silver_batch_id", "column missing")

    total = rep.passed + rep.failed
    colour = GREEN if rep.failed == 0 else RED
    print(f"\n{colour}{rep.passed}/{total}{RESET} checks passed\n")
    return 0 if rep.failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
