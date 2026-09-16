#!/usr/bin/env bash
#
# vpn_client_profile.sh — fetch the Azure VPN Client profile for this gateway.
#
# Produces ~/.nbki-demo/azurevpnconfig.xml, which you import into the Azure VPN
# Client on macOS. Authentication is Microsoft Entra ID, so there is no
# certificate to generate, distribute or rotate, and nothing to install on the
# gateway side.
#
# Why there is no app registration step
# -------------------------------------
# Most walkthroughs of Entra-authenticated P2S tell you to register an
# enterprise application and grant admin consent. That belongs to the OLDER,
# manually-registered audience values. This gateway uses the Microsoft-registered
# Azure VPN Client app ID (c632b3df-fb67-4d84-bdcf-b95ad541b5c8), for which
# Microsoft states explicitly that admin consent is not required. Do not
# "helpfully" register an app -- it is not needed and it will not be used.
#
# Re-run this whenever the gateway's P2S configuration changes. The profile
# embeds the gateway FQDN and the audience, so a stale one fails to connect for
# reasons that are not visible in the client UI.
#
# Usage:  ./infra/vpn_client_profile.sh
#
set -Eeuo pipefail

SECRET_DIR="${NBKI_SECRET_DIR:-${HOME}/.nbki-demo}"
RG="${NBKI_RG:-rg-nbki-db2-demo}"
GW="${NBKI_VPN_GATEWAY:-vgw-nbki}"

mkdir -p "${SECRET_DIR}"

state="$(az network vnet-gateway show -g "${RG}" -n "${GW}" \
          --query provisioningState -o tsv 2>/dev/null || true)"
if [[ -z "${state}" ]]; then
  echo "ERROR: VPN gateway '${GW}' not found in ${RG}." >&2
  echo "       Deploy it with ./infra/deploy.sh (deployVpnGateway must be true)." >&2
  exit 1
fi
if [[ "${state}" != "Succeeded" ]]; then
  echo "ERROR: gateway '${GW}' is '${state}', not 'Succeeded'." >&2
  echo "       A VPN gateway takes 30-45 minutes to provision. Wait, then re-run." >&2
  exit 1
fi

echo "==> Generating the client profile"
# For Entra-authenticated gateways this returns a short-lived SAS URL to a zip
# containing an AzureVPN/ folder. There is no certificate material in it.
url="$(az network vnet-gateway vpn-client generate -g "${RG}" -n "${GW}" -o tsv)"
if [[ -z "${url}" ]]; then
  echo "ERROR: Azure returned no profile URL." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "==> Downloading"
curl -fsSL "${url}" -o "${tmp}/vpnclient.zip"

# unzip's exit code is not a boolean. 0 is success, 1 is "completed with
# warnings", and only 2+ are real errors. Azure builds this zip with Windows-style
# backslash path separators, which makes unzip emit
#     warning: ... appears to use backslashes as path separators
# and return 1 -- while extracting everything perfectly correctly. Under
# `set -e` that aborts the script on a completely successful extraction.
# Same family as the db2 CLP exit codes recorded in the README.
rc=0
unzip -q -o "${tmp}/vpnclient.zip" -d "${tmp}/extracted" || rc=$?
if (( rc > 1 )); then
  echo "ERROR: unzip failed with exit code ${rc}." >&2
  exit 1
fi

cfg="$(find "${tmp}/extracted" -name 'azurevpnconfig*.xml' -type f | head -1)"
if [[ -z "${cfg}" ]]; then
  echo "ERROR: no azurevpnconfig.xml in the downloaded profile." >&2
  echo "       Contents were:" >&2
  find "${tmp}/extracted" -type f >&2
  echo "       This usually means the gateway is not configured for Entra ID" >&2
  echo "       authentication over OpenVPN." >&2
  exit 1
fi

cp "${cfg}" "${SECRET_DIR}/azurevpnconfig.xml"
chmod 0600 "${SECRET_DIR}/azurevpnconfig.xml"

pool="$(az network vnet-gateway show -g "${RG}" -n "${GW}" \
         --query "vpnClientConfiguration.vpnClientAddressPool.addressPrefixes[0]" -o tsv)"

cat <<EOF

==> Profile written to ${SECRET_DIR}/azurevpnconfig.xml

  Import it once, on this Mac:

    1. Open the Azure VPN Client.
    2. Import  ->  ${SECRET_DIR}/azurevpnconfig.xml
    3. Connect, and sign in with your Entra account.

  Connected, you hold an address in ${pool} and can reach the VNet directly:

    Db2        10.20.1.4:50001   (TLS, as FABRICRO)
    vm-db2     10.20.1.4:22
    vm-gateway 10.20.2.x:3389

  Point DBeaver at 10.20.1.4 rather than the public address. Verify with:

    NBKI_DB2_HOST=10.20.1.4 .venv/bin/python scripts/15_client_test.py

  Once that passes, take Db2 off the public internet for good:

    ./infra/deploy.sh --lock-to-vpn

  Azure Bastion stays enabled either way, as break-glass.
EOF
