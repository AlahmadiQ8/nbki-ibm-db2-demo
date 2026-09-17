#!/usr/bin/env bash
#
# 05_verify.sh — prove the data in Db2 matches what we prepared.
#
# "The load reported no errors" is not verification. LOAD counts rows; it does
# not tell you whether the money is right, whether the foreign keys resolve, or
# whether the watermark column is usable for an incremental read.
#
# This checks:
#   1. row counts        vs data/prepared/manifest.json
#   2. control totals    vs the same manifest, to the penny
#   3. referential integrity  (orphans should be impossible, so prove it)
#   4. watermark sanity  (populated, and enough distinct values to page on)
#   5. reserved-word and type landmines actually avoided
#
# Exit code is non-zero if anything fails, so it can gate a pipeline.
#
# Environment: same as 04_load.sh (DB2_MODE, DB2_CONTAINER, DB2_DATABASE, ...)
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${REPO_ROOT}/data/prepared/manifest.json"

source "${REPO_ROOT}/scripts/_db2_lib.sh"

PASS=0
FAIL=0

check() {                  # $1 = label, $2 = expected, $3 = actual
  if [[ "$2" == "$3" ]]; then
    printf '  \033[32mPASS\033[0m  %-44s %s\n' "$1" "$3"
    PASS=$((PASS + 1))
  else
    printf '  \033[31mFAIL\033[0m  %-44s expected %s, got %s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

expect_zero() {            # $1 = label, $2 = actual count
  local n="${2//[[:space:]]/}"
  if [[ "${n}" == "0" ]]; then
    printf '  \033[32mPASS\033[0m  %-44s 0\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  \033[31mFAIL\033[0m  %-44s expected 0, got %s\n' "$1" "${n}"
    FAIL=$((FAIL + 1))
  fi
}

if [[ ! -f "${MANIFEST}" ]]; then
  echo "ERROR: ${MANIFEST} not found. Run ./scripts/03_prepare.py first." >&2
  exit 1
fi

echo "==> Verifying ${DB2_SCHEMA} in ${DB2_DATABASE}"

# Check the database is actually reachable BEFORE running 23 checks against it.
# Without this, an unreachable Db2 -- a deallocated VM, a stopped container --
# makes every single check fail with an empty result, and the report reads as
# "the data is catastrophically wrong" rather than "nothing was asked". That is
# a genuinely alarming way to start a demo day, and it is a lie.
db2_require_running
echo

# -- Has the delta been applied? ---------------------------------------------
# The manifest describes the table as it was *loaded*. Once 08_apply_delta.sh
# runs, the table legitimately no longer matches it. Without this, a presenter
# who runs the delta and then re-runs verify gets "Verification FAILED. Do not
# demo from this data." on perfectly good data — the worst possible moment for
# a false alarm. So: detect the delta and fold it into the expectations.
DELTA_MANIFEST="${REPO_ROOT}/db2/delta/delta_manifest.json"
DELTA_ROWS=0
DELTA_AMOUNT="0"
DELTA_STATE="not applied"

if [[ -f "${DELTA_MANIFEST}" ]]; then
  read -r d_lo d_hi d_rows d_amount d_upd_amt < <(python3 -c "
import json
m = json.load(open('${DELTA_MANIFEST}'))
lo, hi = m['new_transaction_id_range']
print(lo, hi, m['new_rows'],
      m.get('new_row_amount_total', 'MISSING'),
      m.get('updates_change_amount', 'MISSING'))")

  if [[ "${d_amount}" == "MISSING" || "${d_upd_amt}" == "MISSING" ]]; then
    echo "  NOTE: delta manifest predates the amount bookkeeping; regenerate it"
    echo "        with ./scripts/06_make_delta.py to get delta-aware verification."
  else
    present="$(db2_query "SELECT COUNT(*) FROM ${DB2_SCHEMA}.TRANSACTIONS
                          WHERE TRANSACTION_ID BETWEEN ${d_lo} AND ${d_hi}" | tr -d ' ')"
    if [[ "${present}" == "${d_rows}" ]]; then
      DELTA_ROWS="${d_rows}"
      DELTA_AMOUNT="${d_amount}"
      DELTA_STATE="applied (${d_rows} rows, ${d_amount})"
    elif [[ "${present}" != "0" ]]; then
      # Neither cleanly absent nor cleanly present. That is a genuine problem
      # and must not be silently absorbed into the expected figures.
      printf '  \033[31mFAIL\033[0m  %-44s expected 0 or %s, got %s\n' \
        "delta applied cleanly (IDs ${d_lo}-${d_hi})" "${d_rows}" "${present}"
      FAIL=$((FAIL + 1))
      DELTA_STATE="PARTIAL — ${present} of ${d_rows} rows present"
    fi
  fi
fi

echo "-- Delta state: ${DELTA_STATE}"
echo
echo "-- Row counts (source of truth: data/prepared/manifest.json)"

TABLES="$(python3 -c "
import json
m = json.load(open('${MANIFEST}'))
for t in m['tables']:
    rows = t['rows_out']
    if t['table'] == 'TRANSACTIONS':
        rows += ${DELTA_ROWS}
    print(t['table'], rows)
")"

while read -r table expected; do
  [[ -n "${table}" ]] || continue
  actual="$(db2_query "SELECT COUNT(*) FROM ${DB2_SCHEMA}.${table}" | tr -d ' ')"
  check "${table} row count" "${expected}" "${actual}"
done <<< "${TABLES}"

echo
echo "-- Control totals (must tie exactly; a penny of drift is a failure)"

TOTALS="$(python3 -c "
import json
from decimal import Decimal
m = json.load(open('${MANIFEST}'))
for t in m['tables']:
    for col, total in t.get('control_totals', {}).items():
        if t['table'] == 'TRANSACTIONS' and col == 'AMOUNT':
            total = str(Decimal(str(total)) + Decimal('${DELTA_AMOUNT}'))
        print(t['table'], col, total)
")"

while read -r table col expected; do
  [[ -n "${table}" ]] || continue
  # Trim to the same scale the manifest recorded, so formatting differences do
  # not masquerade as data differences.
  scale="$(python3 -c "
v = '${expected}'
print(len(v.split('.')[1]) if '.' in v else 0)")"
  actual="$(db2_query "SELECT CAST(SUM(${col}) AS DECIMAL(31,${scale})) FROM ${DB2_SCHEMA}.${table}" | tr -d ' ')"
  norm_expected="$(python3 -c "
from decimal import Decimal
print(Decimal('${expected}').quantize(Decimal(1).scaleb(-${scale})))")"
  norm_actual="$(python3 -c "
from decimal import Decimal
print(Decimal('${actual}').quantize(Decimal(1).scaleb(-${scale})))" 2>/dev/null || echo "${actual}")"
  check "${table}.${col} sum" "${norm_expected}" "${norm_actual}"
done <<< "${TOTALS}"

echo
echo "-- Referential integrity (SET INTEGRITY should make these impossible)"

expect_zero "CARDS with no CUSTOMER" "$(db2_query "
  SELECT COUNT(*) FROM ${DB2_SCHEMA}.CARDS c
  WHERE NOT EXISTS (SELECT 1 FROM ${DB2_SCHEMA}.CUSTOMERS u WHERE u.CUSTOMER_ID = c.CUSTOMER_ID)")"

expect_zero "TRANSACTIONS with no CUSTOMER" "$(db2_query "
  SELECT COUNT(*) FROM ${DB2_SCHEMA}.TRANSACTIONS t
  WHERE NOT EXISTS (SELECT 1 FROM ${DB2_SCHEMA}.CUSTOMERS u WHERE u.CUSTOMER_ID = t.CUSTOMER_ID)")"

expect_zero "TRANSACTIONS with no CARD" "$(db2_query "
  SELECT COUNT(*) FROM ${DB2_SCHEMA}.TRANSACTIONS t
  WHERE NOT EXISTS (SELECT 1 FROM ${DB2_SCHEMA}.CARDS c WHERE c.CARD_ID = t.CARD_ID)")"

# MCC is not enforced by a foreign key, because the real dataset may legitimately
# carry codes absent from the reference file. Reported, not failed.
orphan_mcc="$(db2_query "
  SELECT COUNT(DISTINCT t.MCC_CODE) FROM ${DB2_SCHEMA}.TRANSACTIONS t
  WHERE NOT EXISTS (SELECT 1 FROM ${DB2_SCHEMA}.MCC_CODES m WHERE m.MCC_CODE = t.MCC_CODE)" | tr -d ' ')"
printf '  \033[33mINFO\033[0m  %-44s %s\n' "MCC codes not in the reference file" "${orphan_mcc}"

echo
echo "-- Watermark (this is what makes an incremental read possible)"

for table in TRANSACTIONS AML_TRANSACTIONS; do
  exists="$(db2_query "SELECT COUNT(*) FROM SYSCAT.TABLES WHERE TABSCHEMA='${DB2_SCHEMA}' AND TABNAME='${table}'" | tr -d ' ')"
  [[ "${exists}" == "1" ]] || continue
  expect_zero "${table}.LAST_UPDATED_TS nulls" "$(db2_query "
    SELECT COUNT(*) FROM ${DB2_SCHEMA}.${table} WHERE LAST_UPDATED_TS IS NULL")"
  range="$(db2_query "SELECT VARCHAR(MIN(LAST_UPDATED_TS)) || ' .. ' || VARCHAR(MAX(LAST_UPDATED_TS))
             FROM ${DB2_SCHEMA}.${table}")"
  printf '  \033[33mINFO\033[0m  %-44s %s\n' "${table} watermark range" "$(tr -s ' ' <<< "${range}")"
done

# The business timestamp is what a watermark would filter on if the engine column
# were unavailable. Mass ties there are the failure mode worth knowing about.
ties="$(db2_query "
  SELECT COUNT(*) FROM (
    SELECT TXN_TS FROM ${DB2_SCHEMA}.TRANSACTIONS
    GROUP BY TXN_TS HAVING COUNT(*) > 1
  ) AS d" | tr -d ' ')"
printf '  \033[33mINFO\033[0m  %-44s %s\n' "TXN_TS values shared by >1 row" "${ties}"

echo
echo "-- Type landmines"

# DATE is reserved in Db2; if the rename had not happened the column would not exist.
renamed="$(db2_query "SELECT COUNT(*) FROM SYSCAT.COLUMNS
  WHERE TABSCHEMA='${DB2_SCHEMA}' AND TABNAME='TRANSACTIONS' AND COLNAME='TXN_TS'" | tr -d ' ')"
check "TRANSACTIONS.TXN_TS exists (DATE renamed)" "1" "${renamed}"

amount_type="$(db2_query "SELECT TRIM(TYPENAME) FROM SYSCAT.COLUMNS
  WHERE TABSCHEMA='${DB2_SCHEMA}' AND TABNAME='TRANSACTIONS' AND COLNAME='AMOUNT'" | tr -d ' ')"
check "TRANSACTIONS.AMOUNT is DECIMAL not FLOAT" "DECIMAL" "${amount_type}"

# A zero-padded identifier cast to a number loses its padding permanently.
zip_type="$(db2_query "SELECT TRIM(TYPENAME) FROM SYSCAT.COLUMNS
  WHERE TABSCHEMA='${DB2_SCHEMA}' AND TABNAME='TRANSACTIONS' AND COLNAME='MERCHANT_ZIP'" | tr -d ' ')"
check "MERCHANT_ZIP kept as text" "VARCHAR" "${zip_type}"

echo
echo "============================================================"
printf '  %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "============================================================"

if [[ "${FAIL}" -gt 0 ]]; then
  echo
  echo "Verification FAILED. Do not demo from this data." >&2
  exit 1
fi
echo
echo "Next: ./scripts/06_make_delta.py   (the incremental batch)"
