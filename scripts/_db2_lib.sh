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
#   DB2_MODE=docker|local|azure   how to reach Db2            (docker)
#   DB2_CONTAINER           container name                    (db2demo)
#   DB2_DATABASE            database name                     (NBKI)
#   DB2_INSTANCE            instance owner                    (db2inst1)
#   DB2_SCHEMA              schema name                       (NBKI)
#   DB2_AZ_RG               resource group, azure mode        (rg-nbki-db2-demo)
#   DB2_AZ_VM               VM name, azure mode               (vm-db2)
#
# DB2_MODE=azure — talking to Db2 without a VPN
# ---------------------------------------------
# `docker` assumes the container is reachable from this machine. Once the
# environment is locked to the VPN that is only true while the Azure VPN Client
# is connected, and it drops. A dropped VPN surfaces as SQL30081N with protocol
# error 60 (ETIMEDOUT), which reads like Db2 is down when it is fine.
#
# `azure` ships the SQL over the Azure control plane with `az vm run-command`
# instead, which needs no VPN, no SSH rule and no open port. The SQL is
# base64-encoded on the way in, because run-command takes the script as a shell
# string and SQL is full of quotes that would otherwise need several layers of
# escaping.
#
# It is slower -- each call is an ARM round trip of roughly 20-60 seconds -- so
# it is for verification and inspection, not for chatty loops. Bulk data staging
# is deliberately refused; see db2_stage_data.

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
DB2_AZ_RG="${DB2_AZ_RG:-rg-nbki-db2-demo}"
DB2_AZ_VM="${DB2_AZ_VM:-vm-db2}"

# Run a prepared SQL file on the VM via the Azure control plane. Echoes whatever
# the CLP printed. $1 = local path, $2 = db2 flags (e.g. "-x").
#
# The `su - db2inst1` matters: db2profile is only sourced by a login shell, and
# without it `db2` is not on PATH and the failure says "command not found",
# which looks like a broken image rather than a missing environment.
_db2_azure_run() {
  local f="$1" flags="${2:-}" b64 out rc
  b64="$(base64 < "${f}" | tr -d '\n')"

  # `az vm run-command invoke` exits 0 whenever the INVOCATION succeeded, even
  # if the remote script failed -- the remote exit status appears only inside
  # the message text. Without the __NBKI_RC__ marker below, a failed LOAD or a
  # syntax error in the SQL would be reported to the caller as success, and
  # every `|| rc=$?` in the scripts that use this would be inert.
  out="$(az vm run-command invoke \
          --resource-group "${DB2_AZ_RG}" --name "${DB2_AZ_VM}" \
          --command-id RunShellScript \
          --scripts "echo '${b64}' | base64 -d > /tmp/_nbki_q.sql
chmod 0644 /tmp/_nbki_q.sql
docker cp /tmp/_nbki_q.sql ${DB2_CONTAINER}:/tmp/_nbki_q.sql >/dev/null || { echo '__NBKI_RC__=90'; exit 0; }
docker exec ${DB2_CONTAINER} bash -lc \"su - ${DB2_INSTANCE} -c 'db2 ${flags} -tf /tmp/_nbki_q.sql'\"
echo \"__NBKI_RC__=\$?\"" \
          --query "value[0].message" -o tsv 2>&1)" || {
    echo "ERROR: az vm run-command failed against ${DB2_AZ_VM}." >&2
    echo "${out}" >&2
    return 1
  }

  rc="$(printf '%s' "${out}" | sed -n 's/.*__NBKI_RC__=\([0-9][0-9]*\).*/\1/p' | tail -1)"

  # Everything from [stdout] up to the marker is what the command printed.
  # NOTE: the [stderr] section is deliberately NOT discarded on failure -- a
  # docker or su error appears only there, and dropping it makes a transport
  # failure indistinguishable from an empty result set.
  printf '%s' "${out}" \
    | sed -n '/^\[stdout\]/,/^\[stderr\]/p' \
    | grep -Ev '^\[stdout\]$|^\[stderr\]$|__NBKI_RC__='

  if [[ -z "${rc}" ]]; then
    echo "ERROR: no exit status came back from ${DB2_AZ_VM}; treating as failure." >&2
    printf '%s\n' "${out}" >&2
    return 1
  fi
  if [[ "${rc}" == "90" ]]; then
    echo "ERROR: could not copy the SQL into container '${DB2_CONTAINER}'." >&2
    return 1
  fi
  if (( rc != 0 )); then
    # db2 returns 1 for warnings (e.g. SQL0100W no rows) and >=2 for errors.
    if (( rc >= 2 )); then
      echo "ERROR: db2 exited ${rc} on ${DB2_AZ_VM}." >&2
      printf '%s\n' "${out}" | sed -n '/^\[stderr\]/,$p' >&2
      return "${rc}"
    fi
  fi
  return 0
}

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
  elif [[ "${DB2_MODE}" == "azure" ]]; then
    _db2_azure_run "${tmp}" || rc=$?
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
  elif [[ "${DB2_MODE}" == "azure" ]]; then
    _db2_azure_run "${tmp}" || rc=$?
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
  elif [[ "${DB2_MODE}" == "azure" ]]; then
    out="$(_db2_azure_run "${tmp}" "-x")"
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
  if [[ "${DB2_MODE}" == "azure" ]]; then
    # Refused on purpose. run-command ships its payload as a base64 string in an
    # ARM request; the prepared CSVs run to 1.7 GB. Attempting it would either be
    # rejected by the size limit or take hours, and the useful failure is the one
    # that says so now rather than the one that says so at 90%.
    echo "ERROR: DB2_MODE=azure cannot stage bulk data." >&2
    echo "       run-command is a control-plane channel, not a data path." >&2
    echo "       Use ./scripts/11_sync_to_vm.sh over the VPN, then run the" >&2
    echo "       load on the VM itself." >&2
    exit 1
  fi
  if [[ "${DB2_MODE}" == "docker" ]]; then
    docker cp "$f" "${DB2_CONTAINER}:${DB2_STAGE}/${base}" >/dev/null
    docker exec "${DB2_CONTAINER}" chmod 0644 "${DB2_STAGE}/${base}"
    echo "${DB2_STAGE}/${base}"
  else
    echo "$f"
  fi
}

db2_prep_stage() {
  if [[ "${DB2_MODE}" == "azure" ]]; then
    return 0  # _db2_azure_run stages into /tmp per call; nothing to prepare.
  fi
  if [[ "${DB2_MODE}" == "docker" ]]; then
    docker exec "${DB2_CONTAINER}" bash -c \
      "mkdir -p ${DB2_STAGE} && chmod 777 ${DB2_STAGE}" >/dev/null
  else
    mkdir -p "${DB2_STAGE}"
  fi
}

# Fail early and with an instruction rather than a confusing Db2 error later.
db2_require_running() {
  if [[ "${DB2_MODE}" == "azure" ]]; then
    # The container runs on the VM, not here. Check it through the same channel
    # the queries will use, so a green result means the query path really works.
    local raw st
    # `|| true` on BOTH the az call and the grep is load-bearing. Under
    # `set -Eeuo pipefail`, a deallocated VM makes az exit non-zero and grep
    # match nothing, and the assignment itself would then kill the script --
    # before the error message below could be printed. The caller would exit 1
    # with no output at all, which is precisely the confusion this function was
    # added to remove.
    raw="$(az vm run-command invoke \
            --resource-group "${DB2_AZ_RG}" --name "${DB2_AZ_VM}" \
            --command-id RunShellScript \
            --scripts "docker ps --format '{{.Names}}' | grep -qx ${DB2_CONTAINER} && echo up || echo down" \
            --query "value[0].message" -o tsv 2>&1 || true)"
    st="$(printf '%s' "${raw}" | grep -Eo '^(up|down)$' | head -1 || true)"

    if [[ "${st}" == "up" ]]; then
      return 0
    fi

    # Distinguish "cannot reach the VM" from "container is down". They need
    # different actions, and reporting the wrong one sends you to the wrong place.
    if [[ -z "${st}" ]]; then
      echo "ERROR: could not query ${DB2_AZ_VM} in ${DB2_AZ_RG} via az run-command." >&2
      if grep -q 'OperationNotAllowed\|requires the VM to be running' <<< "${raw}"; then
        echo "       The VM is DEALLOCATED. A tenant automation stops it overnight." >&2
        echo "         az vm start -g ${DB2_AZ_RG} -n ${DB2_AZ_VM}" >&2
        echo "       Then re-assert TLS -- the container entrypoint resets DB2COMM" >&2
        echo "       to TCPIP on every start. See docs/session-handoff.md." >&2
      else
        echo "       Check az login, the subscription, and the names above." >&2
        printf '       az said: %s\n' "$(printf '%s' "${raw}" | head -3)" >&2
      fi
    else
      echo "ERROR: container '${DB2_CONTAINER}' is not running on ${DB2_AZ_VM}." >&2
      echo "       Start it with ./infra/start.sh -- not 'az vm start', which" >&2
      echo "       leaves DB2COMM reset to TCPIP and the TLS listener gone." >&2
    fi
    exit 1
  fi
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
