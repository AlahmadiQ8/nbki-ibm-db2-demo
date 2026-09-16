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
#   1. starts both VMs and waits for SSH
#   2. starts the container and waits for a real SELECT to succeed
#   3. re-creates FABRICRO if the container was rebuilt while it was away
#   4. confirms the gateway service is running and can still reach Db2
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

echo "==> Starting both VMs"
az vm start -g "${RG}" -n vm-db2 --no-wait
az vm start -g "${RG}" -n vm-gateway --no-wait
az vm wait -g "${RG}" -n vm-db2 --custom "instanceView.statuses[?code=='PowerState/running']" --timeout 900
az vm wait -g "${RG}" -n vm-gateway --custom "instanceView.statuses[?code=='PowerState/running']" --timeout 900

# Do this BEFORE trying to connect, not after failing to. The rule is deleted by
# a tenant control on a schedule, and this machine's public address moves, so by
# the time anyone runs start.sh the odds are against the rule still being valid.
# Without this the loop below spins for ten minutes and then blames the VM.
echo "==> Ensuring this machine can still reach SSH"
ensure_ssh_access

echo "==> Waiting for SSH on vm-db2"
for i in $(seq 1 40); do
  if ssh "${SSH_OPTS[@]}" "${TARGET}" true 2>/dev/null; then break; fi
  sleep 15
  if (( i == 40 )); then
    echo "ERROR: no SSH to ${DB2_HOST} after 10 minutes." >&2
    echo "       Check nsg-db2/allow-ssh-operator against your current address:" >&2
    echo "         az network nsg rule show -g ${RG} --nsg-name nsg-db2 -n allow-ssh-operator --query sourceAddressPrefix -o tsv" >&2
    echo "         curl -s https://api.ipify.org" >&2
    echo "       Interactive access always works through Azure Bastion." >&2
    exit 1
  fi
done

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

# ---------------------------------------------------------------------------
# FABRICRO lives in the container's /etc/passwd, not on the /database volume, so
# it is gone if the container was ever recreated. The GRANTs survive on the
# volume and point at a user that no longer exists, which presents as Fabric
# failing authentication for no visible reason.
# ---------------------------------------------------------------------------
echo "==> Checking FABRICRO still exists"
if ssh "${SSH_OPTS[@]}" "${TARGET}" 'docker exec db2demo id fabricro >/dev/null 2>&1'; then
  echo "    present"
else
  echo "    missing (container was rebuilt) -- recreating"
  "${REPO_ROOT}/scripts/14_create_fabricro.sh"
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
