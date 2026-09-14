#!/usr/bin/env bash
#
# 08_apply_delta.sh — apply the second batch, then show that the watermark moved.
#
# Run this DURING the demo, after the first Fabric read has completed. It is the
# moment the incremental story becomes real rather than asserted.
#
# The changes are applied with INSERT and UPDATE, never LOAD. That matters:
# LOAD is a bulk utility that bypasses the row-level machinery, and the whole
# point here is to show ROW CHANGE TIMESTAMP maintaining itself as rows change.
#
# Usage:
#   ./scripts/08_apply_delta.sh              # apply the delta
#   ./scripts/08_apply_delta.sh --rollback   # remove the inserted rows
#   ./scripts/08_apply_delta.sh --watermark  # just report the current high-water mark
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/_db2_lib.sh"

DELTA_DIR="${REPO_ROOT}/db2/delta"
MODE="apply"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rollback)  MODE="rollback"; shift ;;
    --watermark) MODE="watermark"; shift ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

db2_require_running
db2_prep_stage

T="${DB2_SCHEMA}.TRANSACTIONS"

watermark_report() {
  local hi cnt
  hi="$(db2_query "SELECT MAX(LAST_UPDATED_TS) FROM ${T}")"
  cnt="$(db2_query "SELECT COUNT(*) FROM ${T}")"
  printf '    rows              %s\n' "${cnt// /}"
  printf '    high-water mark   %s\n' "${hi}"
}

if [[ "${MODE}" == "watermark" ]]; then
  echo "==> Current state of ${T}"
  watermark_report
  exit 0
fi

if [[ "${MODE}" == "rollback" ]]; then
  echo "==> Rolling back the delta"
  db2_sql_file "${DELTA_DIR}/delta_02_rollback.sql" "delta_rollback.sql" | tail -3
  echo "==> After rollback"
  watermark_report
  echo
  echo "Note: the UPDATEs cannot be reversed to their original values."
  echo "      For a clean slate, re-run ./scripts/04_load.sh"
  exit 0
fi

[[ -f "${DELTA_DIR}/delta_01_apply.sql" ]] || {
  echo "ERROR: ${DELTA_DIR}/delta_01_apply.sql not found." >&2
  echo "       Generate it with ./scripts/06_make_delta.py" >&2
  exit 1
}

echo "==> Before the delta"
BEFORE_HI="$(db2_query "SELECT MAX(LAST_UPDATED_TS) FROM ${T}")"
watermark_report
echo

echo "==> Applying delta_01_apply.sql"
# Db2 prints a line per statement; hundreds of DB20000I lines are noise. Errors
# are what matter, so the output is filtered down to anything that is not a
# success acknowledgement.
set +e
OUT="$(db2_sql_file "${DELTA_DIR}/delta_01_apply.sql" "delta_apply.sql" 2>&1)"
RC=$?
set -e
# Db2 suffixes messages by severity: N = error, C = critical, W = warning.
# Only N and C are failures. Warnings are surfaced but do not stop the run —
# notably SQL0100W, which the idempotency DELETE raises on a first run because
# there is legitimately nothing yet to remove.
ERRS="$(grep -E '^(DB21[0-9]+[NC]|SQL[0-9]+[NC])' <<< "${OUT}" || true)"
WARNS="$(grep -oE '^SQL[0-9]+W' <<< "${OUT}" | sort -u || true)"
if [[ -n "${ERRS}" ]]; then
  echo "ERROR: the delta did not apply cleanly:" >&2
  sed 's/^/    /' <<< "${ERRS}" | head -20 >&2
  exit 1
fi
# The Db2 CLP exit code is not a boolean:
#   0 = success            1 = no rows found (SQL0100W)
#   2 = warning            4 = error              8 = CLP error
# Our idempotency DELETE legitimately returns 1 on a first run, so anything
# below 4 is acceptable.
[[ ${RC} -lt 4 ]] || { echo "ERROR: db2 exited ${RC}" >&2; sed 's/^/    /' <<< "${OUT}" | tail -20 >&2; exit 1; }
echo "    applied with no errors"
if [[ -n "${WARNS}" ]]; then
  echo "    warnings (not fatal): $(tr '\n' ' ' <<< "${WARNS}")"
fi
echo

echo "==> After the delta"
watermark_report
echo

# ---------------------------------------------------------------------------
# The point of the exercise: how many rows an incremental read would now return,
# and — the part people miss — how many of those are CHANGED rather than NEW.
# ---------------------------------------------------------------------------
echo "==> What an incremental read would pick up"
CHANGED="$(db2_query "SELECT COUNT(*) FROM ${T} WHERE LAST_UPDATED_TS > TIMESTAMP('${BEFORE_HI}')" | tr -d ' ')"

# Derive the new/updated split from the delta's own ID range, not from row-count
# arithmetic. Re-running the delta deletes and re-inserts its rows, so comparing
# table sizes would report those as "updates" when they are in fact new rows.
# The ID range is true on a first run and on a repeat.
BASE_MAX_ID="$(python3 -c "import json;print(json.load(open('${DELTA_DIR}/delta_manifest.json'))['base_max_transaction_id'])")"
NEW_ROWS="$(db2_query "SELECT COUNT(*) FROM ${T} WHERE TRANSACTION_ID > ${BASE_MAX_ID} AND LAST_UPDATED_TS > TIMESTAMP('${BEFORE_HI}')" | tr -d ' ')"
UPDATED=$(( CHANGED - NEW_ROWS ))

printf '    WHERE LAST_UPDATED_TS > %s\n' "${BEFORE_HI}"
printf '      -> %s rows  (%s new, %s updated in place)\n' "${CHANGED}" "${NEW_ROWS}" "${UPDATED}"
echo
echo "    Those ${UPDATED} updated rows are the argument for a change-tracking"
echo "    column. A watermark on the business date would have missed every one."
echo
echo "    Still not captured: deletes. ROW CHANGE TIMESTAMP cannot see a row that"
echo "    is gone. Say so before someone in the room asks."

if [[ -f "${DELTA_DIR}/delta_manifest.json" ]]; then
  EXPECTED="$(python3 -c "import json;print(json.load(open('${DELTA_DIR}/delta_manifest.json'))['rows_an_incremental_read_should_return'])")"
  echo
  if [[ "${CHANGED}" == "${EXPECTED}" ]]; then
    printf '  \033[32mPASS\033[0m  incremental row count matches the manifest (%s)\n' "${EXPECTED}"
  else
    printf '  \033[31mFAIL\033[0m  expected %s changed rows, found %s\n' "${EXPECTED}" "${CHANGED}"
    exit 1
  fi
fi
