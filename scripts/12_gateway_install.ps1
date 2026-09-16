# 12_gateway_install.ps1 — install the on-premises data gateway, unattended.
#
# Run through `az vm run-command invoke`, which executes as SYSTEM in Windows
# PowerShell 5.1.
#
# Two things here are not what the documentation leads you to expect, and both
# cost time to discover:
#
#   1. `Install-DataGateway -AcceptConditions` LOOKS like the unattended install
#      path. It is not: it fails with "Login first with
#      Login-DataGatewayServiceAccount". The cmdlet needs an authenticated
#      session merely to fetch and run the installer. So the module is no use to
#      us here -- we run the vendor installer binary directly, which has no such
#      requirement and is genuinely silent.
#
#   2. `Install-PackageProvider -Name NuGet` is Windows PowerShell 5.1 advice.
#      Under PowerShell 7 it fails with "No match was found for the specified
#      search criteria for the provider 'NuGet'". PowerShellGet 2.x already has
#      what it needs.
#
# Registration is still not done here, and cannot be: `Add-DataGatewayCluster` is
# documented "This command must be run with a user based credential". That is
# 13_gateway_register.ps1, over RDP, once.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is ~10x slower with a progress bar

function Write-Step { param($m) Write-Output "==> $m" }

# ---------------------------------------------------------------------------
# PowerShell 7 — not needed for the install itself, but the DataGateway module
# requires 7.0.6+ and the registration step will want it already present.
# ---------------------------------------------------------------------------
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (-not (Test-Path $pwsh)) {
    Write-Step 'Installing PowerShell 7'
    $msi = Join-Path $env:TEMP 'PowerShell-7.msi'
    Invoke-WebRequest -UseBasicParsing `
        -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi' `
        -OutFile $msi
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "PowerShell 7 MSI failed with exit code $($p.ExitCode)" }
    Remove-Item $msi -Force
}
Write-Step ("PowerShell 7 present: " + (& $pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'))

# ---------------------------------------------------------------------------
# The gateway binaries, straight from the vendor installer.
# ---------------------------------------------------------------------------
$svc = Get-Service -Name 'PBIEgwService' -ErrorAction SilentlyContinue
if ($svc) {
    Write-Step "Gateway already installed; service is $($svc.Status)"
} else {
    Write-Step 'Downloading the on-premises data gateway installer'
    $exe = Join-Path $env:TEMP 'GatewayInstall.exe'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://go.microsoft.com/fwlink/?LinkId=2116849' -OutFile $exe
    Write-Step ("Installer size: {0:N1} MB" -f ((Get-Item $exe).Length / 1MB))

    Write-Step 'Installing silently (this takes a few minutes)'
    # -q silent, -norestart so run-command's session is not cut off underneath us.
    $p = Start-Process -FilePath $exe -ArgumentList '-q','-norestart','ACCEPTEULA=yes' -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "GatewayInstall.exe returned exit code $($p.ExitCode)" }
    Remove-Item $exe -Force
}

# ---------------------------------------------------------------------------
# The DataGateway module, for the registration step. Installing it now means the
# single interactive RDP session is as short as possible.
# ---------------------------------------------------------------------------
Write-Step 'Installing the DataGateway PowerShell module for the registration step'
$inner = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
    Register-PSRepository -Default
}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

if (-not (Get-Module -ListAvailable -Name DataGateway)) {
    Install-Module -Name DataGateway -Force -Scope AllUsers -AllowClobber
}
Get-Module DataGateway -ListAvailable |
    Select-Object -First 1 -ExpandProperty Version |
    ForEach-Object { Write-Output "DataGateway module version: $_" }
'@
$innerFile = Join-Path $env:TEMP 'gw_inner.ps1'
Set-Content -Path $innerFile -Value $inner -Encoding UTF8
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $innerFile
if ($LASTEXITCODE -ne 0) { throw "DataGateway module install failed with exit code $LASTEXITCODE" }
Remove-Item $innerFile -Force

$svc = Get-Service -Name 'PBIEgwService' -ErrorAction SilentlyContinue
if (-not $svc) { throw 'PBIEgwService not found after install' }
Write-Step "Done. Service '$($svc.Name)' is $($svc.Status)."
Write-Output ''
Write-Output 'Installed but NOT registered. Registration needs an interactive user'
Write-Output 'sign-in: RDP in and run scripts/13_gateway_register.ps1.'
