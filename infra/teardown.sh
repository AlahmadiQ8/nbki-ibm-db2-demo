#!/usr/bin/env bash
#
# teardown.sh — delete everything this demo created in Azure.
#
# Deletes the whole resource group, which is the only reliable way to be sure
# nothing is left billing. Requires the resource group name to be typed, because
# `az group delete` on the wrong group is not recoverable.
#
# What this does NOT delete, on purpose:
#   * ~/.nbki-demo -- the SSH key, passwords and the gateway recovery key. Remove
#     it by hand once you are certain you will not need to restore the gateway.
#   * the gateway cluster registration in the Fabric tenant. Deleting the VM
#     leaves an orphaned, permanently-offline cluster in "Manage connections and
#     gateways". Remove it there, or the next build inherits a confusing list.
#
set -Eeuo pipefail

RG="${NBKI_RG:-rg-nbki-db2-demo}"

echo "This will delete the resource group '${RG}' and everything in it:"
az resource list -g "${RG}" --query "[].{name:name,type:type}" -o table 2>/dev/null || {
  echo "  (resource group not found -- nothing to do)"; exit 0;
}

echo
read -r -p "Type the resource group name to confirm: " confirm
if [[ "${confirm}" != "${RG}" ]]; then
  echo "Did not match. Nothing deleted."
  exit 1
fi

echo "==> Deleting ${RG}"
az group delete -n "${RG}" --yes --no-wait
echo "    deletion running in the background"
echo
echo "Remember, separately:"
echo "  * remove the 'nbki-db2-gw' cluster in Fabric > Manage connections and gateways"
echo "  * delete ~/.nbki-demo when you no longer need the recovery key"
