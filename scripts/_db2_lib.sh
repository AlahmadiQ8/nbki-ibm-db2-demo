#!/usr/bin/env bash
#
# _db2_lib.sh — shared transport for talking to Db2, whether it is running in a
# local container or on a real server.
#
# Not executable on its own. Source it:
#     source "$(dirname "${BASH_SOURCE[0]}")/_db2_lib.sh"
#
# Why this file exists
# --------------------
# Every script here has to get SQL into Db2 and results back out. Doing that
# reliably turned out to involve a handful of non-obvious details, each of which
# cost real debugging time. They are recorded below rather than rediscovered:
#
#   1. mktemp creates files 0600, and `docker cp` preserves the mode. The
#      instance owner inside the container then cannot read the file, and Db2
#      reports a bare DB21005E that says nothing about permissions.
#      -> chmod 0644 before every copy.
#
#   2. Each `db2` invocation is a separate CLP process. A connection made by one
#      does not reliably survive into the next, so every statement is shipped as
#      a self-contained file that connects, runs, and disconnects.
#
#   3. The generated DDL deliberately contains no CONNECT statement — it should
#      not hard-code a database name. The connect is prepended here instead.
#
#   4. `db2 -x` suppresses column headings but NOT the CONNECT banner or the
#      trailing DB20000I. Blacklisting those lines is fragile, so db2_query
#      fences the real output with markers and takes only what lies between.
#
# Environment (all optional, defaults shown):
#   DB2_MODE=docker|local   how to reach Db2                  (docker)
#   DB2_CONTAINER           container name                    (db2demo)
#   DB2_DATABASE            database name                     (NBKI)
#   DB2_INSTANCE            instance owner                    (db2inst1)
#   DB2_SCHEMA              schema name                       (NBKI)
#

DB2_MODE="${DB2_MODE:-docker}"
DB2_CONTAINER="${DB2_CONTAINER:-db2demo}"
DB2_DATABASE="${DB2_DATABASE:-NBKI}"
DB2_INSTANCE="${DB2_INSTANCE:-db2inst1}"
# The schema name has ONE source of truth: db2/ddl/overlay.json, which is what
# the DDL generator uses. Defaulting it from anywhere else lets the scripts and
# the generated SQL disagree — objects get created in one schema and loaded into
# another, which previously produced a confusing failure rather than a clear one.
_DB2_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_OVERLAY_SCHEMA="$(python3 -c "
import json, pathlib
p = pathlib.Path('${_DB2_LIB_ROOT}/db2/ddl/overlay.json')
print(json.loads(p.read_text())['schema'] if p.exists() else 'NBKI')
" 2>/dev/null || echo NBKI)"
DB2_SCHEMA="${DB2_SCHEMA:-${_OVERLAY_SCHEMA}}"

if [[ "${DB2_SCHEMA}" != "${_OVERLAY_SCHEMA}" ]]; then
  echo "ERROR: DB2_SCHEMA is '${DB2_SCHEMA}' but the generated DDL targets '${_OVERLAY_SCHEMA}'." >&2
  echo "       Objects would be created in one schema and loaded into another." >&2
  echo "       Change \"schema\" in db2/ddl/overlay.json and re-run" >&2
  echo "       ./scripts/02_generate_ddl.py, rather than overriding it here." >&2
  exit 1
fi
DB2_STAGE="${DB2_STAGE:-/tmp/nbki_load}"

# Run a file of SQL. $1 = local path, $2 = optional remote basename.
db2_sql_file() {
  local f="$1" base tmp rc=0
  base="${2:-$(basename "$f")}"
  tmp="$(mktemp)"
  printf 'CONNECT TO %s;\n' "${DB2_DATABASE}" > "${tmp}"
  cat "$f" >> "${tmp}"
  printf '\nCONNECT RESET;\n' >> "${tmp}"
  chmod 0644 "${tmp}"

  if [[ "${DB2_MODE}" == "docker" ]]; then
    docker cp "${tmp}" "${DB2_CONTAINER}:${DB2_STAGE}/${base}" >/dev/null
    docker exec "${DB2_CONTAINER}" su - "${DB2_INSTANCE}" \
      -c "db2 -tf ${DB2_STAGE}/${base}" || rc=$?
  else
    db2 -tf "${tmp}" || rc=$?
  fi
  rm -f "${tmp}"
  return "${rc}"
}

# Run a single statement. $1 = SQL without the trailing semicolon.
db2_cmd() {
  local tmp rc=0
  tmp="$(mktemp)"
  printf 'CONNECT TO %s;\n%s;\nCONNECT RESET;\n' "${DB2_DATABASE}" "$1" > "${tmp}"
  chmod 0644 "${tmp}"
  if [[ "${DB2_MODE}" == "docker" ]]; then
    docker cp "${tmp}" "${DB2_CONTAINER}:${DB2_STAGE}/stmt.sql" >/dev/null
    docker exec "${DB2_CONTAINER}" su - "${DB2_INSTANCE}" \
      -c "db2 -tf ${DB2_STAGE}/stmt.sql" || rc=$?
  else
    db2 -tf "${tmp}" || rc=$?
  fi
  rm -f "${tmp}"
  return "${rc}"
}

# Run a query and echo ONLY the result rows. $1 = SQL without trailing semicolon.
db2_query() {
  local tmp out
  tmp="$(mktemp)"
  {
    printf 'CONNECT TO %s;\n' "${DB2_DATABASE}"
    printf 'ECHO __QBEGIN__;\n'
    printf '%s;\n' "$1"
    printf 'ECHO __QEND__;\n'
    printf 'CONNECT RESET;\n'
  } > "${tmp}"
  chmod 0644 "${tmp}"
  if [[ "${DB2_MODE}" == "docker" ]]; then
    docker cp "${tmp}" "${DB2_CONTAINER}:${DB2_STAGE}/q.sql" >/dev/null
    out="$(docker exec "${DB2_CONTAINER}" su - "${DB2_INSTANCE}" \
      -c "db2 -x -tf ${DB2_STAGE}/q.sql")"
  else
    out="$(db2 -x -tf "${tmp}")"
  fi
  rm -f "${tmp}"
  sed -n '/__QBEGIN__/,/__QEND__/p' <<< "${out}" \
    | grep -v '__QBEGIN__\|__QEND__' \
    | sed 's/[[:space:]]*$//' \
    | grep -v '^$' || true
}

# Put a data file where Db2 can read it. Echoes the path Db2 should use.
db2_stage_data() {
  local f="$1" base
  base="$(basename "$f")"
  chmod 0644 "$f" 2>/dev/null || true
  if [[ "${DB2_MODE}" == "docker" ]]; then
    docker cp "$f" "${DB2_CONTAINER}:${DB2_STAGE}/${base}" >/dev/null
    docker exec "${DB2_CONTAINER}" chmod 0644 "${DB2_STAGE}/${base}"
    echo "${DB2_STAGE}/${base}"
  else
    echo "$f"
  fi
}

db2_prep_stage() {
  if [[ "${DB2_MODE}" == "docker" ]]; then
    docker exec "${DB2_CONTAINER}" bash -c \
      "mkdir -p ${DB2_STAGE} && chmod 777 ${DB2_STAGE}" >/dev/null
  else
    mkdir -p "${DB2_STAGE}"
  fi
}

# Fail early and with an instruction rather than a confusing Db2 error later.
db2_require_running() {
  [[ "${DB2_MODE}" == "docker" ]] || return 0
  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: the Docker daemon is not running." >&2
    echo "       Start Docker Desktop, then ./scripts/db2_up.sh" >&2
    exit 1
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "${DB2_CONTAINER}"; then
    echo "ERROR: container '${DB2_CONTAINER}' is not running." >&2
    echo "       Start it with ./scripts/db2_up.sh" >&2
    exit 1
  fi
}
