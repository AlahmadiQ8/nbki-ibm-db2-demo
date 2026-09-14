#!/usr/bin/env bash
#
# 09_reconcile.sh — prove the CSV fallback and the Db2 path tell the same story.
#
# This is the check that makes the fallback safe to use. If the Db2 VM fails on
# the day and you switch to the CSV drop, every number on every slide has to
# stay the same. If these two sources disagree, the fallback is not a fallback,
# it is a second, contradictory demo.
#
# It reconciles THREE things, not two:
#
#     the physical CSV files   (parsed by scripts/csv_check.py, defects undone)
#       vs the manifest        (what we claim the files contain)
#       vs Db2                 (SELECT COUNT(*), SUM(AMOUNT) for the same window)
#
# The third leg matters and was missing from the first version of this script:
# it compared the manifest against Db2 and never opened a CSV at all. A missing,
# stale, truncated or hand-edited extract would still have reported a clean
# reconciliation, and would then have been uploaded on the day in that state.
#
# It also reports the gap between each file's own footer total and the truth,
# because that gap is the pitch: the number a person reads off the bottom of
# today's spreadsheet is wrong, and it is wrong silently.
#
# Usage:
#   ./scripts/09_reconcile.sh
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/_db2_lib.sh"

MANIFEST="${REPO_ROOT}/csv-drop/manifest.json"
DELTA_MANIFEST="${REPO_ROOT}/db2/delta/delta_manifest.json"

[[ -f "${MANIFEST}" ]] || {
  echo "ERROR: ${MANIFEST} not found. Run ./scripts/07_make_csv_drop.py first." >&2
  exit 1
}

db2_require_running
db2_prep_stage

PASS=0
FAIL=0
T="${DB2_SCHEMA}.TRANSACTIONS"

check() {                  # $1 = label, $2 = expected, $3 = actual
  if [[ "$2" == "$3" ]]; then
    printf '  \033[32mPASS\033[0m  %-44s %s\n' "$1" "$3"
    PASS=$((PASS + 1))
  else
    printf '  \033[31mFAIL\033[0m  %-44s expected %s, got %s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Read the physical files first. Everything below compares against what is
# actually on disk, not against what the manifest claims is on disk.
# ---------------------------------------------------------------------------
echo "==> Reading the physical extracts in csv-drop/incoming/"
CSV_FACTS="$(mktemp)"
trap 'rm -f "${CSV_FACTS}"' EXIT
"${REPO_ROOT}/scripts/csv_check.py" "${MANIFEST}" > "${CSV_FACTS}"

STRAY="$(python3 -c "import json;print(' '.join(json.load(open('${CSV_FACTS}'))['stray_files']))")"
if [[ -n "${STRAY}" ]]; then
  echo "ERROR: undeclared file(s) in csv-drop/incoming/: ${STRAY}" >&2
  echo "       csv-drop/README tells the operator to upload incoming/*.csv, so a" >&2
  echo "       leftover extract from an earlier run would be ingested without ever" >&2
  echo "       being reconciled. Remove it, or regenerate the whole drop." >&2
  exit 1
fi

MISSING="$(python3 -c "
import json
d = json.load(open('${CSV_FACTS}'))
print(' '.join(r['file'] for r in d['results'] if 'error' in r))")"
if [[ -n "${MISSING}" ]]; then
  echo "ERROR: declared but unreadable: ${MISSING}" >&2
  echo "       Regenerate with ./scripts/07_make_csv_drop.py" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# The CSV drop is cut from the prepared files — the state of the world at the
# initial load. If the delta has since been applied, Db2 legitimately holds rows
# the extract could never have contained, so they are excluded by their exact ID
# range rather than by "anything newer", which would also hide genuine base rows.
# ---------------------------------------------------------------------------
ID_SCOPE=""
if [[ -f "${DELTA_MANIFEST}" ]]; then
  read -r DELTA_LO DELTA_HI < <(python3 -c "
import json
lo, hi = json.load(open('${DELTA_MANIFEST}'))['new_transaction_id_range']
print(lo, hi)")
  DELTA_PRESENT="$(db2_query "SELECT COUNT(*) FROM ${T} WHERE TRANSACTION_ID BETWEEN ${DELTA_LO} AND ${DELTA_HI}" | tr -d ' ')"
  if [[ "${DELTA_PRESENT}" != "0" ]]; then
    ID_SCOPE=" AND TRANSACTION_ID NOT BETWEEN ${DELTA_LO} AND ${DELTA_HI}"
    echo "    ${DELTA_PRESENT} delta rows present (IDs ${DELTA_LO}-${DELTA_HI}), excluded;"
    echo "    the CSV extract predates them."
  fi
fi
echo

echo "==> Reconciling file -> manifest -> ${DB2_DATABASE}.${DB2_SCHEMA}"
echo

N_FILES="$(python3 -c "import json;print(len(json.load(open('${MANIFEST}'))['files']))")"

for i in $(seq 0 $((N_FILES - 1))); do
  read -r MONTH NXT EXP_CNT EXP_SUM FOOTER EXP_ROWS DUP \
          CSV_ROWS CSV_DISTINCT CSV_PHYS CSV_DEDUP CSV_DUPREF \
       < <(python3 - "$i" <<PY
import json, sys
i = int(sys.argv[1])
f = json.load(open("${MANIFEST}"))["files"][i]
c = json.load(open("${CSV_FACTS}"))["results"][i]
y, m = f["month"].split("-")
nxt = f"{int(y)+1}-01" if m == "12" else f"{y}-{int(m)+1:02d}"
dupes = c["duplicated_refs"]
dupref = ",".join(sorted(dupes)) if dupes else "none"
print(f["month"], nxt, f["true_transaction_count"], f["true_amount_total"],
      f["footer_total_shown_in_file"], f["data_rows_in_file"],
      f["duplicated_transaction_ref"],
      c["physical_data_rows"], c["distinct_transaction_refs"],
      c["physical_amount_total"], c["dedup_amount_total"], dupref)
PY
)

  WHERE="TXN_TS >= '${MONTH}-01 00:00:00' AND TXN_TS < '${NXT}-01 00:00:00'${ID_SCOPE}"
  DB_CNT="$(db2_query "SELECT COUNT(*) FROM ${T} WHERE ${WHERE}" | tr -d ' ')"
  DB_SUM="$(db2_query "SELECT SUM(AMOUNT) FROM ${T} WHERE ${WHERE}" | tr -d ' ')"

  echo "  ${MONTH}"
  # Leg 1 — does the file on disk match what the manifest says about it?
  check "file rows match manifest" "${EXP_ROWS}" "${CSV_ROWS}"
  check "file duplicate ref matches manifest" "${DUP}" "${CSV_DUPREF}"
  check "file footer total matches manifest" "${FOOTER}" "${CSV_PHYS}"
  # Leg 2 — does the file, deduplicated and cleaned, match Db2?
  check "file distinct txns vs Db2" "${DB_CNT}" "${CSV_DISTINCT}"
  check "file dedup total vs Db2" "${DB_SUM}" "${CSV_DEDUP}"
  # Leg 3 — does the manifest's claimed truth match Db2?
  check "manifest count vs Db2" "${EXP_CNT}" "${DB_CNT}"
  check "manifest total vs Db2" "${EXP_SUM}" "${DB_SUM}"

  DRIFT="$(python3 -c "
from decimal import Decimal
print(Decimal('${CSV_PHYS}') - Decimal('${CSV_DEDUP}'))")"
  printf '  \033[33mINFO\033[0m  %-44s %s\n' \
    "footer over-reports by ${DRIFT}" "${CSV_PHYS} vs ${CSV_DEDUP}"
  printf '        duplicate ref %s, present twice, is why\n' "${CSV_DUPREF}"
  echo
done

echo "============================================================"
if [[ "${FAIL}" -eq 0 ]]; then
  printf '  \033[32m%d passed, %d failed\033[0m\n' "${PASS}" "${FAIL}"
  echo "============================================================"
  echo
  echo "  The files on disk, the manifest, and Db2 all agree. The CSV drop"
  echo "  is safe to fall back to: the numbers on your slides will not move."
  echo
  echo "  Note the gap between each file's footer and its true total. In an"
  echo "  unmanaged extract process a defect like that can reach management"
  echo "  or regulatory reporting with no automated control to catch it --"
  echo "  which is what the Db2 path removes."
else
  printf '  \033[31m%d passed, %d failed\033[0m\n' "${PASS}" "${FAIL}"
  echo "============================================================"
  echo
  echo "  The fallback does NOT match Db2. Do not demo until this is fixed:" >&2
  echo "  switching sources mid-demo would change the numbers on screen." >&2
  exit 1
fi
