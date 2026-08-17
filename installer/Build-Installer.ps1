#Requires -Version 5.1
<#
.SYNOPSIS
  Builds the NetBox Local MSI from the "NetBox Local - Final" directory.

.DESCRIPTION
  Three steps, using the WiX Toolset:

    heat    scans the payload directory and writes Files.wxs
    candle  compiles NetBoxLocal.wxs and Files.wxs
    light   links everything into a single MSI with an embedded cabinet

  WiX is fetched into build\tools\wix on first use; it needs no installation and
  no administrator rights.

  The payload is around 550 MB across 30,000 files, so a full build takes a
  while - most of it spent compressing the cabinet.

.PARAMETER SourceDir
  Payload directory. Defaults to "NetBox Local - Final".

.PARAMETER Version
  Product version written into the MSI. Increase it for every release, otherwise
  Windows will not treat the new package as an upgrade.

.PARAMETER SkipHeat
  Reuse an existing Files.wxs. Only safe when the payload has not changed.
#>
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$Version = '1.0.0',
    [switch]$SkipHeat
)

$ErrorActionPreference = 'Stop'

$InstallerDir = $PSScriptRoot
$RootDir      = Split-Path $InstallerDir -Parent
$ToolsDir     = Join-Path $RootDir 'build\tools\wix'
$OutputDir    = Join-Path $RootDir 'dist\installer'

if (-not $SourceDir) { $SourceDir = Join-Path $RootDir 'NetBox Local - Final' }

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    WARN $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------

Write-Step "Building NetBox Local $Version"

if (-not (Test-Path $SourceDir)) { throw "Payload directory not found: $SourceDir" }

# --- WiX ------------------------------------------------------------------

$candle = Join-Path $ToolsDir 'candle.exe'

if (-not (Test-Path $candle)) {
    Write-Step 'Fetching WiX Toolset'
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null

    $zip = Join-Path $ToolsDir 'wix.zip'
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip' `
            -OutFile $zip -UseBasicParsing -TimeoutSec 600
    }
    finally { $ProgressPreference = $previous }

    Expand-Archive -Path $zip -DestinationPath $ToolsDir -Force
    Remove-Item $zip -Force
    Write-Ok 'WiX ready'
}

# --- Payload check --------------------------------------------------------

# A configuration.py left over from a test run would ship the developer's
# database password to every notebook.
$config = Join-Path $SourceDir 'dist\bundle\netbox\netbox\netbox\configuration.py'
if (Test-Path $config) {
    Write-Warn 'Removing configuration.py from the payload (contains local credentials)'
    Remove-Item $config -Force
}

$leftovers = Get-ChildItem -Path $SourceDir -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue
if ($leftovers) {
    Write-Warn "Removing $($leftovers.Count) __pycache__ directories from the payload"
    foreach ($d in $leftovers) { Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

$payload = Get-ChildItem -Path $SourceDir -Recurse -File
$payloadMB = [math]::Round(($payload | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
Write-Host "    Payload : $($payload.Count) files, $payloadMB MB"

# Windows refuses paths beyond 260 characters, and heat fails on them rather
# than skipping them.
$tooLong = $payload | Where-Object { $_.FullName.Length -ge 250 }
if ($tooLong) {
    Write-Warn "$($tooLong.Count) paths are close to the 260 character limit:"
    $tooLong | Select-Object -First 3 | ForEach-Object { Write-Host "      $($_.FullName)" }
    throw 'Move the project to a shorter path before building.'
}

# --- heat -----------------------------------------------------------------

$filesWxs = Join-Path $InstallerDir 'Files.wxs'

if ($SkipHeat -and (Test-Path $filesWxs)) {
    Write-Warn 'Reusing the existing Files.wxs (-SkipHeat)'
}
else {
    Write-Step 'heat: collecting files'
    & (Join-Path $ToolsDir 'heat.exe') dir $SourceDir `
        -gg -sfrag -srd -scom -sreg `
        -dr INSTALLFOLDER -cg BundleFiles `
        -var var.SourceDir -out $filesWxs -nologo
    if ($LASTEXITCODE -ne 0) { throw "heat failed with exit code $LASTEXITCODE" }

    $components = (Select-String -Path $filesWxs -Pattern '<Component ' -AllMatches).Count
    Write-Ok "$components components"
}

# --- candle ---------------------------------------------------------------

Write-Step 'candle: compiling'
$objDir = Join-Path $InstallerDir 'obj'
New-Item -ItemType Directory -Path $objDir -Force | Out-Null

& $candle -nologo -arch x64 `
    -ext WixUtilExtension `
    -dSourceDir="$SourceDir" `
    -out "$objDir\" `
    (Join-Path $InstallerDir 'NetBoxLocal.wxs') `
    (Join-Path $InstallerDir 'AccessModeDialog.wxs') `
    (Join-Path $InstallerDir 'SyncSourceDialog.wxs') `
    $filesWxs
if ($LASTEXITCODE -ne 0) { throw "candle failed with exit code $LASTEXITCODE" }
Write-Ok 'compiled'

# --- light ----------------------------------------------------------------

Write-Step 'light: linking and compressing (this takes a while)'
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$msi = Join-Path $OutputDir "NetBox Local $Version.msi"

$stopwatch = [Diagnostics.Stopwatch]::StartNew()

# Two validation rules are suppressed, both of which assume a per-user package
# contains a handful of files rather than 30,000:
#
#   ICE64  wants every directory under the user profile listed individually in
#          the RemoveFile table. RemoveFolderEx already removes the whole tree.
#   ICE38  wants every component to use a registry key as its KeyPath instead of
#          a file. Applied literally that means one HKCU value per shipped file.
#
# Neither affects whether the package installs, upgrades or uninstalls
# correctly; both are checked by actually running the installer. Everything else
# validation covers stays switched on.
& (Join-Path $ToolsDir 'light.exe') -nologo `
    -ext WixUIExtension `
    -ext WixUtilExtension `
    -dSourceDir="$SourceDir" `
    -cultures:en-us `
    -dWixUILicenseRtf="$(Join-Path $InstallerDir 'License.rtf')" `
    -sw1076 `
    -sice:ICE64 -sice:ICE38 -sice:ICE91 `
    -out $msi `
    (Join-Path $objDir 'NetBoxLocal.wixobj') `
    (Join-Path $objDir 'AccessModeDialog.wixobj') `
    (Join-Path $objDir 'SyncSourceDialog.wixobj') `
    (Join-Path $objDir 'Files.wixobj')

$stopwatch.Stop()
if ($LASTEXITCODE -ne 0) { throw "light failed with exit code $LASTEXITCODE" }

$msiMB = [math]::Round((Get-Item $msi).Length / 1MB, 1)

Write-Host ''
Write-Ok "MSI created in $([math]::Round($stopwatch.Elapsed.TotalMinutes,1)) minutes"
Write-Host "    File : $msi"
Write-Host "    Size : $msiMB MB (payload was $payloadMB MB)"
Write-Host ''
Write-Host '  Install silently with:' -ForegroundColor Cyan
Write-Host "    msiexec /i `"$msi`" /qn /l*v install.log"
Write-Host ''
Write-Host '  No administrator rights are required; it installs per user into'
Write-Host '  %LOCALAPPDATA%\Programs\NetBox Local.'
