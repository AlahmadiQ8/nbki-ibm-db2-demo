#!/usr/bin/env bash
#
# stop.sh — deallocate both VMs.
#
# Deallocate, not shut down. A VM stopped from inside the guest is still
# allocated and still billed for compute; only `az vm deallocate` releases it.
# Two Standard_D4s_v5 left running is roughly $320 a month for a demo that gets
# used a handful of times.
#
# The static public IPs survive deallocation, so the NSG rules and the Fabric
# connection string stay valid across a stop/start cycle. That is why they are
# Static rather than Dynamic.
#
set -Eeuo pipefail

RG="${NBKI_RG:-rg-nbki-db2-demo}"

echo "==> Deallocating vm-db2 and vm-gateway"
az vm deallocate -g "${RG}" -n vm-db2      --no-wait
az vm deallocate -g "${RG}" -n vm-gateway  --no-wait

echo "    requested; deallocation continues in the background"
echo "    check with: az vm list -g ${RG} -d --query \"[].{n:name,s:powerState}\" -o table"

# A VPN gateway has no "stopped" state. This is the one cost that a stop/start
# cycle does not touch, and it is the largest single line item in this build.
if az network vnet-gateway show -g "${RG}" -n vgw-nbki -o none 2>/dev/null; then
  cat <<'EOF'

    NOTE: vgw-nbki is still running and still billing (~$153/month).
    A VPN gateway cannot be deallocated -- only deleted, and recreating it
    takes 30-45 minutes. If this environment is idle for a long stretch:

        az network vnet-gateway delete -g rg-nbki-db2-demo -n vgw-nbki --no-wait

    Rebuild later with ./infra/deploy.sh, then re-run
    ./infra/vpn_client_profile.sh -- the old client profile will not work
    against a new gateway.
EOF
fi

echo
echo "    Restart with ./infra/start.sh -- NOT with az vm start, which leaves Db2 down."
