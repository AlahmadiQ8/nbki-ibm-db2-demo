#!/usr/bin/env bash
#
# deploy.sh — provision the Azure footprint for the demo.
#
# Idempotent: re-running it is a no-op if nothing has changed, because the work
# is done by an ARM deployment rather than a pile of `az ... create` calls that
# each have to guess whether they already ran.
#
# Secrets
# -------
# There is no Key Vault in this design, and that is a finding rather than an
# oversight. This subscription is governed by an ASC DataProtection policy that
# sets `publicNetworkAccess: Disabled` on Key Vault and Storage immediately after
# creation, and disables shared-key auth. A workstation therefore cannot write a
# secret to a vault here without first standing up a private endpoint and a
# private DNS zone, which is a disproportionate amount of machinery for a demo.
#
# Instead: secrets are generated locally into ~/.nbki-demo (0600), and the Db2
# password reaches the VM over SSH rather than through cloud-init user-data.
# See docs/runbook-phase1.md. Putting these in Key Vault behind a private
# endpoint is the right production answer and is recorded in the roadmap.
#
# Usage:
#   ./infra/deploy.sh                 # provision
#   ./infra/deploy.sh --what-if       # show the change plan and stop
#   ./infra/deploy.sh --lock-to-vpn   # provision, and remove every inbound rule
#                                     # sourced from the public internet
#   ./infra/deploy.sh --gateway-cleartext
#                                     # also let the gateway NIC reach Db2 on
#                                     # cleartext 50000, inside the VNet only
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RG="${NBKI_RG:-rg-nbki-db2-demo}"
LOCATION="${NBKI_LOCATION:-swedencentral}"
SECRET_DIR="${NBKI_SECRET_DIR:-${HOME}/.nbki-demo}"
SSH_KEY="${SECRET_DIR}/id_ed25519"
WIN_PW_FILE="${SECRET_DIR}/windows-admin.pw"
DB2_PW_FILE="${SECRET_DIR}/db2inst1.pw"
FABRICRO_PW_FILE="${SECRET_DIR}/fabricro.pw"
# The gateway's recovery key. Generated here rather than at registration time so
# that it exists before it is needed and is never typed from memory. There is no
# copy of this held by Microsoft: without it the gateway cannot be restored onto
# another machine, and a second cluster node cannot be added. Losing it means
# rebuilding the gateway and recreating every connection bound to it.
RECOVERY_KEY_FILE="${SECRET_DIR}/gateway-recovery.key"

WHATIF=0
LOCK_TO_VPN=0
GW_CLEARTEXT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --what-if)     WHATIF=1; shift ;;
    --lock-to-vpn) LOCK_TO_VPN=1; shift ;;
    --gateway-cleartext) GW_CLEARTEXT=1; shift ;;
    -h|--help)     sed -n '/^# Usage:/,/^#$/p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "${SECRET_DIR}"
chmod 0700 "${SECRET_DIR}"

# ---------------------------------------------------------------------------
# The operator's public address. Every inbound rule is pinned to this single
# host, so it is read fresh rather than hard-coded: home IPs move, and a stale
# constant here produces a confusing "the VM is up but nothing connects".
# ---------------------------------------------------------------------------
OPERATOR_IP="${NBKI_OPERATOR_IP:-$(curl -fsS https://api.ipify.org)}"
if [[ ! "${OPERATOR_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: could not determine this machine's public IP (got '${OPERATOR_IP}')." >&2
  echo "       Set NBKI_OPERATOR_IP explicitly." >&2
  exit 1
fi
echo "==> Operator address: ${OPERATOR_IP}  (the only source any port is open to)"

# ---------------------------------------------------------------------------
# Secrets. Generated once and reused, so re-running deploy.sh does not silently
# rotate the password the running database is already using.
#
# The alphabet is restricted on purpose, and other scripts depend on it.
#
# These values are interpolated into nested heredocs in infra/start_db2.sh and
# scripts/14_create_fabricro.sh, into `su - db2inst1 -c "..."` command strings,
# and into Db2 CLP scripts -- several layers of shell quoting deep. Restricting
# them to [A-Za-z0-9] plus a fixed suffix means none of those layers can be
# broken out of, so the quoting does not have to be perfect to be safe.
#
# If you widen this alphabet, re-check every one of those call sites first.
# The suffix supplies the character classes Windows requires without
# introducing a single shell metacharacter.
# ---------------------------------------------------------------------------
# Note the shape of this pipeline. The obvious version --
#     tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 28
# -- makes `head` close the pipe as soon as it has its 28 bytes, `tr` dies of
# SIGPIPE, and under `set -o pipefail` the whole script exits 141 before it has
# done anything. Reading a bounded chunk FIRST means every stage runs to
# completion and nothing is killed mid-pipe.
gen_password() {
  local body
  body="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-28)"
  if (( ${#body} < 28 )); then
    echo "ERROR: could not generate enough entropy for a password." >&2
    return 1
  fi
  # Guarantee the classes Windows requires, without introducing shell metachars.
  printf '%sAa9-' "${body}"
}

for f in "${WIN_PW_FILE}" "${DB2_PW_FILE}" "${FABRICRO_PW_FILE}" "${RECOVERY_KEY_FILE}"; do
  if [[ ! -s "$f" ]]; then
    gen_password > "$f"
    chmod 0600 "$f"
    echo "    generated $(basename "$f")"
  fi
done

if [[ ! -f "${SSH_KEY}" ]]; then
  echo "==> Generating an SSH keypair for this demo"
  ssh-keygen -t ed25519 -N '' -C 'nbki-db2-demo' -f "${SSH_KEY}" >/dev/null
fi

echo "==> Ensuring resource group ${RG} in ${LOCATION}"
# A resource-group-scoped deployment cannot create its own resource group, so
# this has to happen first and separately.
az group create -n "${RG}" -l "${LOCATION}" -o none

ARGS=(
  --resource-group "${RG}"
  --template-file "${REPO_ROOT}/infra/main.bicep"
  --parameters
    operatorIp="${OPERATOR_IP}"
    sshPublicKey="$(cat "${SSH_KEY}.pub")"
    windowsAdminPassword="$(cat "${WIN_PW_FILE}")"
    lockToVpnOnly="$( ((LOCK_TO_VPN)) && echo true || echo false )"
    allowGatewayCleartext="$( ((GW_CLEARTEXT)) && echo true || echo false )"
)

if (( LOCK_TO_VPN )); then
  cat <<'WARN'

==> --lock-to-vpn: every inbound rule sourced from the public internet will be
    removed. After this, Db2 and both VMs are reachable only over the VPN, or
    through Azure Bastion as break-glass.

    Do not do this until you have connected over the VPN successfully at least
    once. Afterwards, env.sh points the scripts at the private address, so:
        source ~/.nbki-demo/env.sh
        .venv/bin/python scripts/15_client_test.py

WARN
fi

if (( WHATIF )); then
  echo "==> what-if"
  az deployment group what-if "${ARGS[@]}"
  exit 0
fi

echo "==> Deploying (VM creation takes a few minutes)"
az deployment group create --name nbki-phase1 "${ARGS[@]}" -o none

DB2_PUBLIC="$(az deployment group show -g "${RG}" -n nbki-phase1 --query properties.outputs.db2PublicIp.value -o tsv)"
DB2_PRIVATE="$(az deployment group show -g "${RG}" -n nbki-phase1 --query properties.outputs.db2PrivateIpOut.value -o tsv)"
GW_PUBLIC="$(az deployment group show -g "${RG}" -n nbki-phase1 --query properties.outputs.gatewayPublicIp.value -o tsv)"
ADMIN="$(az deployment group show -g "${RG}" -n nbki-phase1 --query properties.outputs.adminUsernameOut.value -o tsv)"

# Which address the other scripts should actually use.
#
# After --lock-to-vpn the public address still EXISTS -- the VM keeps its public
# IP for outbound -- but nothing is allowed inbound to it. Every script here
# SSHes to the host, so continuing to hand them the public address would break
# all of them with a timeout that looks like a dead VM. NBKI_DB2_HOST is the
# address that actually works; NBKI_DB2_PUBLIC and NBKI_DB2_PRIVATE remain
# available as plain facts.
if (( LOCK_TO_VPN )); then
  DB2_HOST="${DB2_PRIVATE}"
  GW_HOST="$(az network nic show -g "${RG}" -n nic-gateway \
              --query 'ipConfigurations[0].privateIPAddress' -o tsv 2>/dev/null || echo '')"
else
  DB2_HOST="${DB2_PUBLIC}"
  GW_HOST="${GW_PUBLIC}"
fi

cat > "${SECRET_DIR}/env.sh" <<EOF
# Generated by infra/deploy.sh — source this before the other scripts.
export NBKI_RG='${RG}'
export NBKI_DB2_PUBLIC='${DB2_PUBLIC}'
export NBKI_DB2_PRIVATE='${DB2_PRIVATE}'
export NBKI_GW_PUBLIC='${GW_PUBLIC}'
export NBKI_ADMIN='${ADMIN}'
export NBKI_SSH_KEY='${SSH_KEY}'
# The address to reach the VMs on, given the current network posture.
export NBKI_DB2_HOST='${DB2_HOST}'
export NBKI_GW_HOST='${GW_HOST}'
export NBKI_VPN_ONLY='$( ((LOCK_TO_VPN)) && echo 1 || echo 0 )'
EOF
chmod 0600 "${SECRET_DIR}/env.sh"

if (( LOCK_TO_VPN )); then
  cat <<EOF

==> Provisioned, and locked to the VPN

  Nothing is reachable from the public internet any more. These are private
  addresses — they work only while the Azure VPN Client is connected.

  vm-db2      ${DB2_PRIVATE}        (Db2 TLS on 50001)
  vm-gateway  ${GW_HOST}        (RDP 3389)

  ssh -i ${SSH_KEY} ${ADMIN}@${DB2_PRIVATE}

  Break-glass if the VPN is down: Azure Bastion, from the portal.
  To reopen the public path:      ./infra/deploy.sh   (without --lock-to-vpn)

  Verify:  .venv/bin/python scripts/15_client_test.py
EOF
else
  cat <<EOF

==> Provisioned

  vm-db2      ${DB2_PUBLIC}   (private ${DB2_PRIVATE})
  vm-gateway  ${GW_PUBLIC}
  admin user  ${ADMIN}

  Secrets and connection details:  ${SECRET_DIR}
  Source them with:                source ${SECRET_DIR}/env.sh

  ssh -i ${SSH_KEY} ${ADMIN}@${DB2_PUBLIC}
EOF
fi
