#!/usr/bin/env bash
#
# 18_assert_pristine.sh — prove the delta has NOT been applied to Db2.
#
# Why this exists
# ---------------
# The demo's best moment is the watermark reveal: apply a small batch of changes
# to Db2, re-run the Fabric Copy job, and show it pick up 250 new rows *and* 50
# in-place updates that a watermark on the business date would have missed.
#
# That reveal can only be spent once. Landing bronze from a source that has
# already had the delta applied -- or half-applied -- silently ruins it, and
# bakes a contaminated baseline into every downstream layer.
#
# The problem: 05_verify.sh cannot detect that state.
# ---------------------------------------------------
# 05_verify.sh decides whether the delta is present by looking for the 250
# inserted TRANSACTION_IDs (23761875-23762124). That is sound for a clean apply.
# It is NOT sound after a rollback, because:
#
#   * 08_apply_delta.sh --rollback deletes the 250 inserts, so the ID probe goes
#     back to reporting "not applied";
#   * but rollback is partial by design and CANNOT restore the 50 rows it
#     updated in place; and
#   * delta_manifest.json records updates_change_amount = false, so the monetary
#     control totals do not move either.
#
# A half-spent delta therefore passes 05_verify.sh 23/23 with nothing amiss.
# This script closes that gap.
#
# How it detects the 50 updates without before-images
# ---------------------------------------------------
# The delta manifest carries no before-images, and does not need to. The 50
# updates set ERROR_FLAGS to one of three values that do not occur in the base
# data, and -- because the column is a ROW CHANGE TIMESTAMP -- updating a row
# also advances LAST_UPDATED_TS to the moment of the update.
#
# The base load is the giveaway. Every row loaded by 04_load.sh carries a
# LAST_UPDATED_TS from the load itself, and a LOAD writes the whole table in one
# short burst -- observed span for 13.3M rows is about fourteen seconds. A row
# updated days later by the delta stands out by orders of magnitude.
#
# So no constant is hard-coded. The base window is measured from the rows the
# delta does not touch, and the 50 suspects are compared against it.
#
# Usage:
#   DB2_MODE=azure ./scripts/18_assert_pristine.sh     # no VPN needed
#   DB2_MODE=docker ./scripts/18_assert_pristine.sh    # on the VM itself
#
# Exit status is 0 only if all three checks pass. Anything else means: reload
# with ./scripts/04_load.sh before landing bronze.
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/_db2_lib.sh"

DELTA_MANIFEST="${REPO_ROOT}/db2/delta/delta_manifest.json"
[[ -f "${DELTA_MANIFEST}" ]] || { echo "ERROR: ${DELTA_MANIFEST} not found" >&2; exit 1; }

PASS=0
FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Both snippets take the manifest path as argv rather than interpolating it into
# the Python source, and neither is wrapped in double quotes: macOS ships bash
# 3.2, which mis-parses a single-quoted string containing double quotes when it
# sits inside "$( ... )". The symptom is a syntax error reported against a later,
# innocent line.
read -r D_LO D_HI D_ROWS D_UPD < <(python3 - "${DELTA_MANIFEST}" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
lo, hi = m["new_transaction_id_range"]
print(lo, hi, m["new_rows"], m["updated_rows"])
PY
)

UPD_IDS=$(python3 - "${DELTA_MANIFEST}" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(",".join(str(i) for i in m["updated_transaction_ids"]))
PY
)

# The three values 06_make_delta.py writes into ERROR_FLAGS. They are not
# present in the base data, so any hit means the delta touched that row.
MARKERS="'Adjusted','Re-presented','Reviewed'"

echo "==> Asserting the delta is unspent  (mode: ${DB2_MODE})"
echo "    delta: ${D_ROWS} inserts in ${D_LO}-${D_HI}, ${D_UPD} in-place updates"
echo

db2_require_running

# ---------------------------------------------------------------------------
# 1. The 250 inserted rows must be absent.
#    This is the check 05_verify.sh already makes. Repeated here so this script
#    stands alone, and so a clean apply is caught as well as a rollback.
# ---------------------------------------------------------------------------
INSERTS="$(db2_query "SELECT COUNT(*) FROM ${DB2_SCHEMA}.TRANSACTIONS
                       WHERE TRANSACTION_ID BETWEEN ${D_LO} AND ${D_HI}" | tr -d ' ')"
if [[ "${INSERTS}" == "0" ]]; then
  ok "delta inserts absent (0 rows in ${D_LO}-${D_HI})"
else
  bad "delta inserts PRESENT: ${INSERTS} rows in ${D_LO}-${D_HI} -- delta applied"
fi

# ---------------------------------------------------------------------------
# 2. None of the 50 update targets may carry a delta ERROR_FLAGS marker.
#    This is the check that survives a rollback, which check 1 does not.
# ---------------------------------------------------------------------------
read -r FOUND MARKED < <(db2_query "
  SELECT COUNT(*), SUM(CASE WHEN ERROR_FLAGS IN (${MARKERS}) THEN 1 ELSE 0 END)
    FROM ${DB2_SCHEMA}.TRANSACTIONS WHERE TRANSACTION_ID IN (${UPD_IDS})" \
  | awk '{print $1, $2}')

if [[ "${FOUND}" != "${D_UPD}" ]]; then
  bad "expected all ${D_UPD} update targets to exist, found ${FOUND} -- source is not the base dataset"
elif [[ "${MARKED}" == "0" ]]; then
  ok "no update markers on the ${D_UPD} target rows"
else
  bad "${MARKED} of ${D_UPD} target rows carry a delta ERROR_FLAGS value -- delta applied, and a rollback would NOT have undone this"
fi

# ---------------------------------------------------------------------------
# 3. The update targets' row-change timestamps must sit inside the base-load
#    window, measured from rows the delta never touches. An applied delta moves
#    them to the moment it ran, which is far outside a load that spans seconds.
# ---------------------------------------------------------------------------
BASE_MAX="$(db2_query "SELECT MAX(LAST_UPDATED_TS) FROM ${DB2_SCHEMA}.TRANSACTIONS
                        WHERE TRANSACTION_ID NOT IN (${UPD_IDS})
                          AND TRANSACTION_ID NOT BETWEEN ${D_LO} AND ${D_HI}" | tr -d ' ')"
UPD_MAX="$(db2_query "SELECT MAX(LAST_UPDATED_TS) FROM ${DB2_SCHEMA}.TRANSACTIONS
                       WHERE TRANSACTION_ID IN (${UPD_IDS})" | tr -d ' ')"

echo
echo "    base-load window ends   ${BASE_MAX}"
echo "    update targets max      ${UPD_MAX}"

if [[ -z "${BASE_MAX}" || -z "${UPD_MAX}" ]]; then
  bad "could not read row-change timestamps"
elif [[ ! "${UPD_MAX}" > "${BASE_MAX}" ]]; then
  ok "update targets' row-change timestamps lie within the base-load window"
else
  bad "update targets carry timestamps AFTER the base load -- they have been modified"
fi

echo
if (( FAIL == 0 )); then
  printf '\033[32m%s\033[0m\n' "Source is pristine: ${PASS}/${PASS}. The delta is unspent."
  exit 0
fi
printf '\033[31m%s\033[0m\n' "Source is NOT pristine: ${FAIL} failed, ${PASS} passed."
echo "Do not land bronze from this state. Restore with ./scripts/04_load.sh."
exit 1
