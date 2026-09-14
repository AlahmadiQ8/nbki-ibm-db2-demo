#!/usr/bin/env bash
#
# db2_up.sh — start the local Db2 validation container and wait until it is
# actually ready to accept SQL.
#
# This is the container the whole pipeline was proven against. The image tag is
# pinned deliberately: see docs/feasibility.md, but in short, Fabric's Db2
# connector documents LUW 11.x, and 12.1.4+ "AI Community Edition" is restricted
# to a single CPU. 11.5.9.0 is the version to demo on.
#
# On Apple silicon the image runs under emulation (--platform linux/amd64).
# That works — it is how this pipeline was validated — but first start takes
# several minutes. Be patient; it is not hung.
#
# Usage:
#   ./scripts/db2_up.sh            # start (or report already running)
#   ./scripts/db2_up.sh --recreate # destroy and rebuild, keeping the volume
#   ./scripts/db2_up.sh --wipe     # destroy including the data volume
#   ./scripts/db2_up.sh --status   # say what state things are in and exit
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/scripts/_db2_lib.sh"

DB2_IMAGE="${DB2_IMAGE:-icr.io/db2_community/db2:11.5.9.0}"
DB2_PASSWORD="${DB2_PASSWORD:-NbkiDemo#2024}"
DB2_PORT="${DB2_PORT:-50000}"
# Bound to loopback by default. This is a local validation container holding a
# banking-shaped dataset with a password that is written down in this repo;
# publishing it on every host interface is not something to do by accident.
# Set DB2_BIND=0.0.0.0 deliberately when a gateway or another host must reach it.
DB2_BIND="${DB2_BIND:-127.0.0.1}"
DB2_VOLUME="${DB2_VOLUME:-db2demo-data}"
WAIT_SECONDS="${WAIT_SECONDS:-900}"

RECREATE=0
WIPE=0
STATUS_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --recreate) RECREATE=1; shift ;;
    --wipe)     RECREATE=1; WIPE=1; shift ;;
    --status)   STATUS_ONLY=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: the Docker daemon is not running. Start Docker Desktop first." >&2
  exit 1
fi

container_state() {
  docker inspect -f '{{.State.Status}}' "${DB2_CONTAINER}" 2>/dev/null || echo "absent"
}

if [[ "${STATUS_ONLY}" -eq 1 ]]; then
  echo "image      ${DB2_IMAGE}"
  echo "container  ${DB2_CONTAINER}  [$(container_state)]"
  echo "volume     ${DB2_VOLUME}  [$(docker volume inspect "${DB2_VOLUME}" >/dev/null 2>&1 && echo present || echo absent)]"
  echo "database   ${DB2_DATABASE} on port ${DB2_PORT}"
  if [[ "$(container_state)" == "running" ]]; then
    if db2_query "SELECT 'ready' FROM SYSIBM.SYSDUMMY1" 2>/dev/null | grep -q ready; then
      echo "status     accepting SQL"
    else
      echo "status     container up, database not answering yet"
    fi
  fi
  exit 0
fi

if [[ "${RECREATE}" -eq 1 ]]; then
  echo "==> Removing existing container"
  docker rm -f "${DB2_CONTAINER}" >/dev/null 2>&1 || true
  if [[ "${WIPE}" -eq 1 ]]; then
    echo "==> Removing data volume ${DB2_VOLUME}"
    docker volume rm "${DB2_VOLUME}" >/dev/null 2>&1 || true
  fi
fi

state="$(container_state)"
case "${state}" in
  running)
    echo "==> Container '${DB2_CONTAINER}' is already running"
    ;;
  exited|created|paused)
    echo "==> Starting existing container '${DB2_CONTAINER}'"
    docker start "${DB2_CONTAINER}" >/dev/null
    ;;
  absent)
    echo "==> Creating container '${DB2_CONTAINER}' from ${DB2_IMAGE}"
    if ! docker image inspect "${DB2_IMAGE}" >/dev/null 2>&1; then
      echo "    Pulling image (this is a large download the first time)"
      docker pull --platform linux/amd64 "${DB2_IMAGE}"
    fi
    # --privileged is required by this image; it manages kernel parameters for
    # the instance at startup. AUTOCONFIG and SAMPLEDB are off to keep first
    # start as short as possible, and ARCHIVE_LOGS is off because nothing here
    # needs point-in-time recovery.
    docker run -d \
      --name "${DB2_CONTAINER}" \
      --platform linux/amd64 \
      --privileged=true \
      -p "${DB2_BIND}:${DB2_PORT}:50000" \
      -e LICENSE=accept \
      -e "DB2INST1_PASSWORD=${DB2_PASSWORD}" \
      -e "DBNAME=${DB2_DATABASE}" \
      -e ARCHIVE_LOGS=false \
      -e AUTOCONFIG=false \
      -e SAMPLEDB=false \
      -v "${DB2_VOLUME}:/database" \
      "${DB2_IMAGE}" >/dev/null
    ;;
  *)
    echo "ERROR: unexpected container state '${state}'" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Readiness. Db2's own log line is not sufficient — the instance announces
# itself before the database will actually answer a query. The only reliable
# test is a successful SELECT.
# ---------------------------------------------------------------------------
echo "==> Waiting for ${DB2_DATABASE} to accept SQL (up to ${WAIT_SECONDS}s)"
if [[ "$(uname -m)" == "arm64" ]]; then
  echo "    Apple silicon: running under emulation, first start takes a few minutes."
fi

deadline=$(( $(date +%s) + WAIT_SECONDS ))
attempt=0
while (( $(date +%s) < deadline )); do
  attempt=$((attempt + 1))
  if db2_query "SELECT 'ready' FROM SYSIBM.SYSDUMMY1" 2>/dev/null | grep -q ready; then
    echo
    echo "==> Db2 is up: database ${DB2_DATABASE}, ${DB2_BIND}:${DB2_PORT}, user ${DB2_INSTANCE}"
    db2_prep_stage
    echo
    echo "Next: ./scripts/04_load.sh"
    exit 0
  fi
  printf '    still starting (%ds elapsed)\r' "$(( attempt * 10 ))"
  sleep 10
done

echo >&2
echo "ERROR: Db2 did not become ready within ${WAIT_SECONDS}s." >&2
echo "       Check the logs:  docker logs --tail 50 ${DB2_CONTAINER}" >&2
exit 1
