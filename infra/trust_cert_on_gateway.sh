#!/usr/bin/env bash
#
# trust_cert_on_gateway.sh — make the gateway VM trust the Db2 certificate.
#
# The Microsoft driver validates the server certificate chain when "Use
# Encrypted Connection" is set, and Db2 here presents a self-signed certificate.
# Nothing trusts that by default, so without this step the Fabric connection
# fails at "Test connection" with a transport error that says nothing about
# certificates — one of the easier hours to lose in this build.
#
# Idempotent. Run it again after infra/start_db2.sh --recreate regenerates the
# keystore, because the certificate will be a different one.
#
# Usage:  ./infra/trust_cert_on_gateway.sh
#
set -Eeuo pipefail

SECRET_DIR="${NBKI_SECRET_DIR:-${HOME}/.nbki-demo}"
# shellcheck source=/dev/null
source "${SECRET_DIR}/env.sh"

CERT_FILE="${SECRET_DIR}/db2cert.arm"
RG="${NBKI_RG:-rg-nbki-db2-demo}"

if [[ ! -s "${CERT_FILE}" ]]; then
  echo "ERROR: ${CERT_FILE} is missing. Run ./infra/start_db2.sh first." >&2
  exit 1
fi

SCRIPT="$(mktemp)"
trap 'rm -f "${SCRIPT}"' EXIT

{
  echo '$ErrorActionPreference = "Stop"'
  echo '$pem = @"'
  cat "${CERT_FILE}"
  echo '"@'
  cat <<'PS'
$path = Join-Path $env:TEMP 'db2cert.cer'
Set-Content -Path $path -Value $pem -Encoding ASCII

# Match on thumbprint, not subject: after a keystore regeneration the subject is
# identical but the certificate is not, and silently keeping the stale one would
# fail in a way that looks like a network problem.
$new = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $path
$existing = Get-ChildItem Cert:\LocalMachine\Root |
    Where-Object { $_.Thumbprint -eq $new.Thumbprint }

if ($existing) {
    Write-Output "Already trusted: $($existing.Thumbprint)"
} else {
    Get-ChildItem Cert:\LocalMachine\Root |
        Where-Object { $_.Subject -like '*NBKI Demo*' } |
        ForEach-Object {
            Write-Output "Removing superseded certificate $($_.Thumbprint)"
            Remove-Item $_.PSPath -Force
        }
    $c = Import-Certificate -FilePath $path -CertStoreLocation Cert:\LocalMachine\Root
    Write-Output "Imported: $($c.Thumbprint)  $($c.Subject)"
}
Remove-Item $path -Force
PS
} > "${SCRIPT}"

echo "==> Importing the Db2 certificate into LocalMachine\\Root on vm-gateway"
az vm run-command invoke -g "${RG}" -n vm-gateway \
  --command-id RunPowerShellScript --scripts "@${SCRIPT}" \
  --query "value[].message" -o tsv

echo
echo "==> Verifying the gateway can reach Db2 over TLS"
az vm run-command invoke -g "${RG}" -n vm-gateway \
  --command-id RunPowerShellScript \
  --scripts "(Test-NetConnection -ComputerName ${NBKI_DB2_PRIVATE} -Port 50001 -WarningAction SilentlyContinue).TcpTestSucceeded" \
  --query "value[0].message" -o tsv | grep -q True \
  && echo "    ${NBKI_DB2_PRIVATE}:50001 reachable from the gateway" \
  || { echo "ERROR: the gateway cannot reach Db2 on 50001. Check nsg-db2 and the asg-gateway rule." >&2; exit 1; }
