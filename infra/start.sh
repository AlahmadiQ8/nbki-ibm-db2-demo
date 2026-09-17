#!/usr/bin/env bash
#
# start.sh — bring the demo back up after ./infra/stop.sh.
#
# `az vm start` is NOT sufficient, and this is the single most likely way to
# arrive at a customer session with a broken demo.
#
# The Db2 container is created without a Docker restart policy, deliberately --
# db2_up.sh owns the readiness contract and a restart policy would race it. So
# after the VM boots, Docker is running and `db2demo` is *stopped*. `docker ps`
# shows nothing, the port is closed, and the gateway reports the data source as
# unreachable with no clue as to why.
#
# This script therefore:
#   1. resumes the Fabric capacity if it is paused
#   2. starts both VMs and waits for SSH
#   3. starts the container and waits for a real SELECT to succeed
#   4. re-creates FABRICRO if the container was rebuilt while it was away
#   5. confirms the gateway service is running and can still reach Db2
#
# Two additions after a night when the environment took itself down:
#
# * A tenant automation deallocates BOTH VMs and pauses the F-SKU capacity,
#   unasked. A paused capacity is invisible here until Fabric starts returning a
#   bare HTTP 404 on every item call -- the real reason, `CapacityNotActive`, is
#   only in the response body. So it is checked and resumed first.
#
# * The SSH path needs the VPN, and the VPN drops. `--via-azure` does the whole
#   thing through `az vm run-command` instead, which needs no VPN, no SSH rule
#   and no open port. It is selected automatically when SSH is not reachable,
#   because the alternative is a ten-minute wait followed by a message blaming
#   the VM for a laptop-side problem.
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_DIR="${NBKI_SECRET_DIR:-${HOME}/.nbki-demo}"
# shellcheck source=/dev/null
source "${SECRET_DIR}/env.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/infra/_ensure_ssh_access.sh"

RG="${NBKI_RG:-rg-nbki-db2-demo}"
SSH_OPTS=(-i "${NBKI_SSH_KEY}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
# Reach the VM on whichever address the current posture allows. After
# ./infra/deploy.sh --lock-to-vpn the public address accepts nothing inbound, so
# using it here would fail with a timeout that looks like a dead VM.
DB2_HOST="${NBKI_DB2_HOST:-${NBKI_DB2_PUBLIC}}"
TARGET="${NBKI_ADMIN}@${DB2_HOST}"

VIA_AZURE=0
for arg in "$@"; do
  case "${arg}" in
    --via-azure) VIA_AZURE=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# The Fabric capacity. Nothing below depends on it, but everything a demo does
# afterwards depends on it, and a paused F-SKU reports itself as a bare HTTP 404
# on unrelated calls -- which reads like a wrong workspace id or a dead token.
# Far cheaper to assert it here than to debug it later.
# ---------------------------------------------------------------------------
CAP_RG="${NBKI_FABRIC_CAPACITY_RG:-fabric-playground-sweden}"
CAP_NAME="${NBKI_FABRIC_CAPACITY:-momof8sweden}"

echo "==> Checking the Fabric capacity (${CAP_NAME})"
cap_state="$(az resource show -g "${CAP_RG}" -n "${CAP_NAME}" \
              --resource-type Microsoft.Fabric/capacities \
              --query "properties.state" -o tsv 2>/dev/null || true)"
case "${cap_state}" in
  Active)
    echo "    Active" ;;
  Paused)
    echo "    Paused -- resuming"
    az rest --method post --url \
      "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${CAP_RG}/providers/Microsoft.Fabric/capacities/${CAP_NAME}/resume?api-version=2023-11-01" \
      >/dev/null
    for _ in $(seq 1 20); do
      sleep 15
      cap_state="$(az resource show -g "${CAP_RG}" -n "${CAP_NAME}" \
                    --resource-type Microsoft.Fabric/capacities \
                    --query "properties.state" -o tsv 2>/dev/null || true)"
      [[ "${cap_state}" == "Active" ]] && break
    done
    if [[ "${cap_state}" != "Active" ]]; then
      echo "WARNING: capacity is '${cap_state}', not Active. Fabric calls will" >&2
      echo "         fail with HTTP 404 CapacityNotActive until it resumes." >&2
    else
      echo "    Active"
    fi ;;
  "")
    echo "    could not read it -- skipping (set NBKI_FABRIC_CAPACITY/_RG to fix)" ;;
  *)
    echo "    state is '${cap_state}'" ;;
esac

echo "==> Starting both VMs"
az vm start -g "${RG}" -n vm-db2 --no-wait
az vm start -g "${RG}" -n vm-gateway --no-wait
az vm wait -g "${RG}" -n vm-db2 --custom "instanceView.statuses[?code=='PowerState/running']" --timeout 900
az vm wait -g "${RG}" -n vm-gateway --custom "instanceView.statuses[?code=='PowerState/running']" --timeout 900

# ---------------------------------------------------------------------------
# Decide how to reach the VM.
#
# The SSH path is the better one when it works -- start_db2.sh does more than
# the minimum, including rebuilding the JKS truststore. But it needs the VPN,
# and the VPN drops. Probing first turns a ten-minute timeout that blames the
# VM into an immediate, correct choice.
# ---------------------------------------------------------------------------
if (( VIA_AZURE == 0 )); then
  echo "==> Ensuring this machine can still reach SSH"
  ensure_ssh_access || true

  echo "==> Probing SSH on vm-db2"
  ssh_ok=0
  for i in $(seq 1 20); do
    if ssh "${SSH_OPTS[@]}" "${TARGET}" true 2>/dev/null; then ssh_ok=1; break; fi
    sleep 15
  done
  if (( ssh_ok == 0 )); then
    echo "    no SSH after 5 minutes -- falling back to az vm run-command."
    echo "    (usually the VPN is down; --via-azure skips this probe entirely)"
    VIA_AZURE=1
  else
    echo "    reachable"
  fi
fi

if (( VIA_AZURE == 0 )); then
  echo "==> Starting Db2, re-asserting TLS, and waiting for it to answer SQL"
  # Deliberately delegating to start_db2.sh rather than calling db2_up.sh directly.
  #
  # Starting the container is not enough. The Db2 Community Edition image's
  # entrypoint sets DB2COMM=TCPIP on every container start, which silently drops
  # the SSL protocol. Everything else survives on the /database volume -- the
  # keystore, SSL_SVCENAME, SSL_SVR_LABEL -- and the port is still published, so
  # the configuration LOOKS correct while nothing listens on 50001 at all. Fabric
  # then reports the source as unreachable with no useful error.
  #
  # start_db2.sh re-applies DB2COMM and restarts the instance, and is idempotent:
  # it leaves the existing keystore alone, so the certificate the gateway already
  # trusts stays valid.
  "${REPO_ROOT}/infra/start_db2.sh" \
    | sed -n '/Configuring the TLS/,$p' \
    | { grep -v '11_sync_to_vm.sh' || true; }   # that script's closing advice is for a first build, not a restart
         # `|| true` because grep -v exits 1 when it emits nothing, which under
         # pipefail would abort start.sh without printing a word.

  # -------------------------------------------------------------------------
  # FABRICRO lives in the container's /etc/passwd, not on the /database volume,
  # so it is gone if the container was ever recreated. The GRANTs survive on the
  # volume and point at a user that no longer exists, which presents as Fabric
  # failing authentication for no visible reason.
  # -------------------------------------------------------------------------
  echo "==> Checking FABRICRO still exists"
  if ssh "${SSH_OPTS[@]}" "${TARGET}" 'docker exec db2demo id fabricro >/dev/null 2>&1'; then
    echo "    present"
  else
    echo "    missing (container was rebuilt) -- recreating"
    "${REPO_ROOT}/scripts/14_create_fabricro.sh"
  fi
else
  # -------------------------------------------------------------------------
  # The same work, over the Azure control plane. No VPN, no SSH rule, no open
  # port. This is the path that was used to recover the environment by hand
  # after a tenant automation deallocated both VMs overnight.
  #
  # It does NOT rebuild ~/.nbki-demo/db2-truststore.jks, because that is a
  # workstation-side artefact and the certificate is untouched by a restart. If
  # a JDBC client starts rejecting the certificate, run start_db2.sh over the
  # VPN once.
  # -------------------------------------------------------------------------
  echo "==> Starting Db2 and re-asserting TLS via az vm run-command"
  out="$(az vm run-command invoke -g "${RG}" -n vm-db2 \
          --command-id RunShellScript --scripts '
set -e
SSLDIR=/database/config/db2inst1/ssl
TLS_PORT=50001
docker start db2demo >/dev/null 2>&1 || true
for i in $(seq 1 60); do
  if docker exec db2demo bash -lc "su - db2inst1 -c \"db2 connect to NBKI\"" >/dev/null 2>&1; then break; fi
  sleep 10
  [ "$i" = "60" ] && { echo "TIMEOUT waiting for Db2 to answer SQL"; exit 1; }
done
# Re-applied on EVERY start: the image entrypoint resets DB2COMM to TCPIP, which
# silently drops SSL while every other setting still looks correct.
docker exec db2demo su - db2inst1 -c "
  set -e
  db2 update dbm cfg using SSL_SVR_KEYDB $SSLDIR/key.kdb
  db2 update dbm cfg using SSL_SVR_STASH $SSLDIR/key.sth
  db2 update dbm cfg using SSL_SVR_LABEL db2cert
  db2 update dbm cfg using SSL_SVCENAME $TLS_PORT
  db2set -i db2inst1 DB2COMM=TCPIP,SSL
" >/dev/null
docker exec db2demo su - db2inst1 -c "db2stop force" >/dev/null 2>&1 || true
docker exec db2demo su - db2inst1 -c "db2start" >/dev/null
docker exec db2demo su - db2inst1 -c "db2 activate database NBKI" >/dev/null 2>&1 || true
docker exec db2demo su - db2inst1 -c "db2set -all" 2>/dev/null | grep -i db2comm
for i in $(seq 1 20); do
  if docker exec db2demo bash -c "ss -ltn 2>/dev/null | grep -q :$TLS_PORT || netstat -ltn 2>/dev/null | grep -q :$TLS_PORT"; then
    echo "TLS_LISTENING=yes"; break
  fi
  sleep 5
  [ "$i" = "20" ] && echo "TLS_LISTENING=no"
done
docker exec db2demo id fabricro >/dev/null 2>&1 && echo "FABRICRO=present" || echo "FABRICRO=missing"
' --query "value[0].message" -o tsv 2>&1)" || {
    echo "ERROR: could not drive vm-db2 through az vm run-command." >&2
    echo "${out}" >&2
    exit 1
  }

  printf '%s\n' "${out}" | grep -E 'DB2COMM|TLS_LISTENING|FABRICRO|TIMEOUT' | sed 's/^/    /' || true

  if ! grep -q 'TLS_LISTENING=yes' <<< "${out}"; then
    echo >&2
    echo "ERROR: Db2 is not listening on 50001." >&2
    echo "       DB2COMM must read TCPIP,SSL -- see the line above. Fabric will" >&2
    echo "       report the source as unreachable until it does." >&2
    exit 1
  fi
  if grep -q 'FABRICRO=missing' <<< "${out}"; then
    echo "    FABRICRO missing (container was rebuilt) -- recreating"
    "${REPO_ROOT}/scripts/14_create_fabricro.sh"
  fi
fi

echo "==> Checking the gateway"
az vm run-command invoke -g "${RG}" -n vm-gateway --command-id RunPowerShellScript \
  --scripts "(Get-Service PBIEgwService).Status; 'db2 reachable: ' + (Test-NetConnection -ComputerName ${NBKI_DB2_PRIVATE} -Port 50001 -WarningAction SilentlyContinue).TcpTestSucceeded" \
  --query "value[0].message" -o tsv | { grep -vE '^\s*$' || true; } | tail -3 | tee /tmp/nbki_gw_check.txt

if ! grep -q 'db2 reachable: True' /tmp/nbki_gw_check.txt; then
  echo >&2
  echo "ERROR: the gateway cannot reach Db2 on ${NBKI_DB2_PRIVATE}:50001." >&2
  echo "       Most likely the TLS listener did not come up -- check DB2COMM:" >&2
  echo "         ssh ${TARGET} 'docker exec db2demo su - db2inst1 -c \"db2set -all\" | grep -i db2comm'" >&2
  echo "       It must read TCPIP,SSL. If it reads TCPIP, re-run ./infra/start_db2.sh" >&2
  exit 1
fi
rm -f /tmp/nbki_gw_check.txt

if [[ "${NBKI_VPN_ONLY:-0}" == "1" ]]; then
cat <<EOF

==> Up, and locked to the VPN.

  These are private addresses; they work only with the Azure VPN Client connected.

  Db2 TLS     ${NBKI_DB2_PRIVATE}:50001   (SQL client, as FABRICRO)
  Gateway VM  ${NBKI_GW_HOST:-10.20.2.4}:3389   (RDP)

  Verify:  .venv/bin/python scripts/15_client_test.py

  Confirm the gateway shows Online in Fabric before demoing. A gateway that has
  been offline for a while can take a minute to reappear.
EOF
else
cat <<EOF

==> Up.

  Db2 TLS     ${NBKI_DB2_PUBLIC}:50001   (SQL client, as FABRICRO)
  Db2 private ${NBKI_DB2_PRIVATE}:50001  (the Fabric connection)
  Gateway     ${NBKI_GW_PUBLIC}

  Confirm the gateway shows Online in Fabric before demoing. A gateway that has
  been offline for a while can take a minute to reappear.
EOF
fi
