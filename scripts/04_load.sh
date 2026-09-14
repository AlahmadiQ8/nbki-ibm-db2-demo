#!/usr/bin/env bash
#
# 04_load.sh — create the schema and load the prepared files into Db2.
#
# Works against either the local validation container or a real Db2 server, so
# the same script that is proven here is the one that runs on the Azure VM.
#
#   DB2_MODE=docker   (default)  run through `docker exec` against a local container
#   DB2_MODE=local               run `db2` directly; you are already the instance owner
#
# Environment:
#   DB2_CONTAINER   container name              (default: db2demo)
#   DB2_DATABASE    database name               (default: NBKI)
#   DB2_INSTANCE    instance owner              (default: db2inst1)
#   DB2_SCHEMA      schema name                 (default: NBKI)
#
# Usage:
#   ./scripts/04_load.sh              # drop, recreate, load everything
#   ./scripts/04_load.sh --no-drop    # load into an existing schema
#   ./scripts/04_load.sh --ddl-only   # create the objects, load nothing
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARED="${REPO_ROOT}/data/prepared"
DDL_DIR="${REPO_ROOT}/db2/ddl"

# Transport (docker vs local, staging, and the several sharp edges that go with
# them) lives in one place so it cannot drift between scripts.
source "${REPO_ROOT}/scripts/_db2_lib.sh"

DO_DROP=1
DDL_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-drop)  DO_DROP=0; shift ;;
    --ddl-only) DDL_ONLY=1; shift ;;
    -h|--help)  sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

db2_require_running

if [[ ! -d "${PREPARED}" || -z "$(ls -A "${PREPARED}"/*.csv 2>/dev/null)" ]]; then
  if [[ "${DDL_ONLY}" -eq 0 ]]; then
    echo "ERROR: nothing in ${PREPARED}. Run ./scripts/03_prepare.py first." >&2
    exit 1
  fi
fi

db2_prep_stage
echo "==> Db2 ${DB2_MODE} mode, database ${DB2_DATABASE}, schema ${DB2_SCHEMA}"

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

if [[ "${DO_DROP}" -eq 1 ]]; then
  echo "==> Dropping existing objects (nothing to drop on a first run)"
  db2_sql_file "${DDL_DIR}/99_drop.sql" >/dev/null 2>&1 || true
  # RESTRICT fails if anything is left in the schema, which is the behaviour we
  # want: it surfaces objects the generated drop script does not know about.
  drop_out="$(db2_cmd "DROP SCHEMA ${DB2_SCHEMA} RESTRICT" 2>&1 || true)"
  if grep -qE '^SQL[0-9]+N' <<< "${drop_out}"; then
    if grep -q 'SQL0204N' <<< "${drop_out}"; then
      echo "    schema did not exist"
    else
      echo "${drop_out}" | grep -E '^SQL[0-9]+N' | sed 's/^/    /'
      echo "    (continuing — CREATE will report if this actually matters)"
    fi
  else
    echo "    schema ${DB2_SCHEMA} dropped"
  fi
fi

echo "==> Creating schema and tables"
out="$(db2_sql_file "${DDL_DIR}/01_schema.sql" 2>&1 || true)"
# SQL0601N here means the schema already exists, which is harmless: --no-drop is
# a supported mode, and Db2 also auto-creates a schema on first qualified use.
if grep -qE '^SQL[0-9]+N' <<< "${out}" && ! grep -q 'SQL0601N' <<< "${out}"; then
  echo "${out}" | grep -E '^SQL[0-9]+N' | sed 's/^/    /'
  echo "ERROR: schema creation failed." >&2
  exit 1
fi
echo "    schema ${DB2_SCHEMA} ready"

out="$(db2_sql_file "${DDL_DIR}/02_tables.sql" 2>&1 || true)"
if grep -qE '^SQL[0-9]+N' <<< "${out}"; then
  echo "${out}" | grep -E '^SQL[0-9]+N' | sed 's/^/    /'
  echo "ERROR: table creation failed." >&2
  exit 1
fi
echo "    core tables created: $(grep -c 'DB20000I' <<< "${out}") statement(s) OK"

# Optional tables are only created when their source data was actually prepared.
if [[ -f "${DDL_DIR}/03_tables_optional.sql" ]]; then
  if [[ -f "${PREPARED}/AML_TRANSACTIONS.csv" ]]; then
    echo "==> Creating optional tables"
    out="$(db2_sql_file "${DDL_DIR}/03_tables_optional.sql" 2>&1 || true)"
    if grep -qE '^SQL[0-9]+N' <<< "${out}"; then
      echo "${out}" | grep -E '^SQL[0-9]+N' | sed 's/^/    /'
      echo "ERROR: optional table creation failed." >&2
      exit 1
    fi
    echo "    optional tables created"
  else
    echo "==> Skipping optional tables (no AML data prepared)"
  fi
fi

if [[ "${DDL_ONLY}" -eq 1 ]]; then
  echo "==> --ddl-only, stopping here"
  exit 0
fi

# ---------------------------------------------------------------------------
# Load
#
# Parents before children, so the foreign keys have something to point at.
# ---------------------------------------------------------------------------

LOAD_ORDER=(CUSTOMERS CARDS MCC_CODES TRANSACTIONS FRAUD_LABELS AML_TRANSACTIONS)

for table in "${LOAD_ORDER[@]}"; do
  src="${PREPARED}/${table}.csv"
  [[ -f "${src}" ]] || { echo "==> ${table}: no prepared file, skipping"; continue; }

  # Db2 LOAD has no header-skip modifier for delimited files, so the header is
  # removed here. Keeping it in the prepared file is deliberate — those files
  # should stay readable by a human.
  hdr="$(head -1 "${src}")"
  body="${PREPARED}/.${table}.del"
  tail -n +2 "${src}" > "${body}"

  rows="$(wc -l < "${body}" | tr -d ' ')"
  remote="$(db2_stage_data "${body}")"

  # METHOD P maps input columns positionally; the explicit INSERT column list is
  # what keeps a generated identity column from being fed the wrong field.
  #
  # Built with paste rather than `seq -s ', '` on purpose: BSD seq (macOS) emits
  # a TRAILING separator where GNU seq does not, so seq would silently produce
  # "(1, 2, 3, )" here and fail with SQL0104N — and would do it on only one of
  # the two platforms this script has to run on.
  n=$(awk -F',' '{print NF; exit}' <<< "${hdr}")
  positions="$(seq 1 "${n}" | paste -sd, - | sed 's/,/, /g')"

  echo "==> Loading ${table} (${rows} rows)"
  # CHARDEL is deliberately omitted: Db2's default character delimiter is already
  # the double quote, and specifying it here would have to survive three layers
  # of shell quoting (local -> docker exec -> su -c) to arrive intact.
  set +e
  load_out="$(db2_cmd "LOAD CLIENT FROM ${remote} OF DEL \
MODIFIED BY COLDEL, DELPRIORITYCHAR USEDEFAULTS \
METHOD P (${positions}) \
MESSAGES ${DB2_STAGE}/${table}.msg \
INSERT INTO ${DB2_SCHEMA}.${table} (${hdr}) \
NONRECOVERABLE" 2>&1)"
  set -e

  grep -E 'Number of rows|SQL[0-9]+[NWC]' <<< "${load_out}" | sed 's/^/    /' || true

  # The load result is checked rather than assumed. The previous version piped
  # straight into grep with `|| true`, which meant a failed load printed nothing
  # unusual and the script still announced success at the end.
  load_err="$(grep -E 'SQL[0-9]+[NC]' <<< "${load_out}" || true)"
  if [[ -n "${load_err}" ]]; then
    echo "ERROR: loading ${table} failed:" >&2
    sed 's/^/    /' <<< "${load_err}" >&2
    echo "       Messages: docker exec ${DB2_CONTAINER} cat ${DB2_STAGE}/${table}.msg" >&2
    exit 1
  fi

  rejected="$(grep 'Number of rows rejected' <<< "${load_out}" | tr -dc '0-9' || true)"
  loaded="$(grep 'Number of rows loaded' <<< "${load_out}" | tr -dc '0-9' || true)"
  if [[ -n "${rejected}" && "${rejected}" != "0" ]]; then
    echo "ERROR: ${table} rejected ${rejected} row(s). Refusing to continue." >&2
    echo "       A partial load is worse than no load: it looks like success." >&2
    exit 1
  fi
  if [[ -z "${loaded}" ]]; then
    echo "ERROR: could not determine how many rows loaded into ${table}." >&2
    exit 1
  fi

  rm -f "${body}"
done

# ---------------------------------------------------------------------------
# Constraint checking
#
# LOAD leaves tables that carry foreign keys in "check pending" state. Until
# SET INTEGRITY runs they cannot be queried at all — SQL0668N, reason code 1.
# This is the single most common Db2 LOAD surprise, so it is handled here
# rather than left for someone to hit live.
# ---------------------------------------------------------------------------

echo "==> Checking integrity on constrained tables"
set +e
si_out="$(db2_cmd "SET INTEGRITY FOR ${DB2_SCHEMA}.CARDS, ${DB2_SCHEMA}.TRANSACTIONS IMMEDIATE CHECKED" 2>&1)"
set -e
grep -E 'DB20000I|SQL[0-9]+[NWC]' <<< "${si_out}" | sed 's/^/    /' || true

# If this fails the tables stay in check-pending and cannot be queried at all,
# so there is no value in carrying on to RUNSTATS and declaring victory.
si_err="$(grep -E 'SQL[0-9]+[NC]' <<< "${si_out}" || true)"
if [[ -n "${si_err}" ]]; then
  echo "ERROR: SET INTEGRITY failed; the tables remain in check-pending." >&2
  sed 's/^/    /' <<< "${si_err}" >&2
  exit 1
fi

echo "==> Updating statistics (the optimiser is useless without them)"
for table in "${LOAD_ORDER[@]}"; do
  [[ -f "${PREPARED}/${table}.csv" ]] || continue
  set +e
  rs_out="$(db2_cmd "RUNSTATS ON TABLE ${DB2_SCHEMA}.${table} WITH DISTRIBUTION AND DETAILED INDEXES ALL" 2>&1)"
  set -e
  # Genuinely non-fatal: bad statistics make queries slow, not wrong. But a
  # silent failure here is how a demo ends up inexplicably sluggish, so it is
  # reported rather than discarded.
  if grep -qE 'SQL[0-9]+[NC]' <<< "${rs_out}"; then
    echo "    WARNING: RUNSTATS failed for ${table} (queries may be slow)" >&2
  fi
done

echo
echo "==> Load complete. Verify it: ./scripts/05_verify.sh"
