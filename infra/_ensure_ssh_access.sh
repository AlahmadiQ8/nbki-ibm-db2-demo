#!/usr/bin/env bash
#
# _ensure_ssh_access.sh — make sure this workstation can actually reach the VM.
#
# Not executable on its own. Source it, then call ensure_ssh_access.
#
# Two independent things break SSH to the Db2 VM, and they present identically
# as a connection timeout with nothing in any log:
#
#   1. This tenant runs an automated control that DELETES any NSG rule exposing
#      port 22 or 3389 to the internet, even pinned to a single /32. Both rules
#      vanished within about 45 minutes of the first deployment.
#
#   2. The operator's public address moves. It changed twice during the build.
#      A rule pinned to yesterday's address is no better than no rule.
#
# One function fixes both, because the fix is the same: read the current address
# and re-assert the rule.
#
# Anything INTERACTIVE should use Azure Bastion instead and not rely on this at
# all. This exists for the things Bastion's Developer SKU cannot carry -- bulk
# rsync -- and for unattended scripts that need a shell on the box.

ensure_ssh_access() {
  local rg="${NBKI_RG:-rg-nbki-db2-demo}"
  local nsg="${1:-nsg-db2}"
  local rule="${2:-allow-ssh-operator}"
  local ip current target

  # ---------------------------------------------------------------------------
  # Which posture are we in?
  #
  # This MUST come from NBKI_VPN_ONLY, which deploy.sh writes into env.sh, and
  # must NOT be inferred from which NSG rules exist. An earlier version guessed
  # by testing for "allow-ssh-vpn present, allow-ssh-operator absent" -- but that
  # is exactly the state produced when the tenant control deletes the operator
  # rule in the UNLOCKED posture, which is the precise failure this function
  # exists to repair. It would have refused to repair it, and said so confidently.
  # ---------------------------------------------------------------------------
  if [[ "${NBKI_VPN_ONLY:-0}" == "1" ]]; then
    # Test the route, not the local address. Pattern-matching ifconfig for the
    # client pool is both loose -- 172.16/12 also covers VMware's vmnet8 and
    # plenty of corporate LANs -- and indirect. Whether a packet actually reaches
    # the VNet is the real question, so ask that instead.
    target="${NBKI_DB2_PRIVATE:-}"
    if [[ -n "${target}" ]] && nc -z -w 5 "${target}" 22 2>/dev/null; then
      echo "    locked to VPN, and ${target}:22 is reachable -- nothing to do"
      return 0
    fi
    echo "ERROR: this environment is locked to the VPN, but ${target:-the Db2 VM} is unreachable." >&2
    echo "       Connect the Azure VPN Client, or use Azure Bastion from the portal." >&2
    echo "       Re-creating a public rule would not help here, and the next deploy" >&2
    echo "       would remove it again. To reopen the public path deliberately:" >&2
    echo "         ./infra/deploy.sh" >&2
    return 1
  fi

  # --- unlocked posture: the rule is supposed to exist, so assert it ----------
  #
  # Note `|| true` on the command substitutions, not merely 2>/dev/null. A
  # substitution takes its pipeline's exit status, and callers run with
  # `pipefail`, so a transient az or curl failure would otherwise tear down the
  # entire calling script with the redirect having swallowed any explanation.
  ip="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
  if [[ ! "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "    WARNING: could not read this machine's public IP; leaving ${rule} alone" >&2
    return 0
  fi

  current="$(az network nsg rule show -g "${rg}" --nsg-name "${nsg}" -n "${rule}" \
               --query "sourceAddressPrefix" -o tsv 2>/dev/null || true)"

  if [[ "${current}" == "${ip}/32" ]]; then
    echo "    SSH rule present and correct for ${ip}"
    return 0
  fi

  if [[ -z "${current}" ]]; then
    echo "    SSH rule is missing (the tenant control removes it). Re-creating for ${ip}"
  else
    echo "    SSH rule points at ${current}, this machine is ${ip}. Updating"
  fi

  az network nsg rule create -g "${rg}" --nsg-name "${nsg}" -n "${rule}" \
    --priority 100 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "${ip}/32" --destination-port-ranges 22 \
    -o none 2>/dev/null \
    || az network nsg rule update -g "${rg}" --nsg-name "${nsg}" -n "${rule}" \
         --source-address-prefixes "${ip}/32" -o none
}
