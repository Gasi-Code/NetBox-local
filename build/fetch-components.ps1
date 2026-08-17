#Requires -Version 5.1
<#
.SYNOPSIS
  Downloads and extracts all binary components for the NetBoxLocal bundle.

.DESCRIPTION
  Reads build/components.json, downloads each component into build/cache,
  verifies its SHA256 against the manifest, and extracts it into dist/staging.

  On the first successful run the manifest has empty sha256 fields; this script
  records the observed hashes. From then on a mismatch aborts the build. That is
  the supply-chain guard: an unnoticed upstream change must never slip into a
  bundle that ends up on emergency notebooks.

  Requires no administrator rights and no pre-installed Python.

.PARAMETER Force
  Re-download components even when a cached copy is present.

.PARAMETER PinHashes
  Write observed SHA256 values back into components.json. Use once, after
  reviewing the downloads.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$PinHashes
)

$ErrorActionPreference = 'Stop'

$BuildDir     = $PSScriptRoot
$RootDir      = Split-Path $BuildDir -Parent
$CacheDir     = Join-Path $BuildDir 'cache'
$StagingDir   = Join-Path $RootDir  'dist\staging'
$ManifestPath = Join-Path $BuildDir 'components.json'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    OK   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    WARN $Message" -ForegroundColor Yellow }

function Get-FileHashHex {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-Download {
    param([string]$Url, [string]$Destination)

    # Invoke-WebRequest with the progress bar enabled is roughly an order of
    # magnitude slower on large files.
    $previousPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 600
    }
    finally {
        $ProgressPreference = $previousPreference
    }
}

function Expand-ZipTo {
    param([string]$Archive, [string]$Destination)

    # Expand-Archive insists on a .zip extension; .jar files are plain ZIPs.
    $source = $Archive
    if ([IO.Path]::GetExtension($Archive) -ne '.zip') {
        $source = [IO.Path]::ChangeExtension($Archive, '.zip')
        Copy-Item -Path $Archive -Destination $source -Force
    }
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    Expand-Archive -Path $source -DestinationPath $Destination -Force
}

function Expand-TarTo {
    param([string]$Archive, [string]$Destination)

    # Clear the target first. tar extracts alongside whatever is already there,
    # so switching NetBox versions used to leave both trees in staging - and the
    # build then picked whichever sorted first, quietly ignoring the switch.
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    # Windows ships bsdtar, which handles both gzip and xz.
    & tar.exe -xf $Archive -C $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "tar failed with exit code $LASTEXITCODE for $Archive"
    }
}

function Expand-Component {
    param($Component, [string]$ArchivePath, [string]$TargetPath)

    switch ($Component.archive) {
        'none' {
            $parent = Split-Path $TargetPath -Parent
            if (-not (Test-Path $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -Path $ArchivePath -Destination $TargetPath -Force
        }
        'zip' {
            Expand-ZipTo -Archive $ArchivePath -Destination $TargetPath
        }
        'tar.gz' {
            Expand-TarTo -Archive $ArchivePath -Destination $TargetPath
        }
        'jar-txz' {
            # Zonky ships PostgreSQL as a .txz nested inside a .jar (a ZIP).
            $unwrap = Join-Path $CacheDir ("unwrap-" + $Component.name)
            Expand-ZipTo -Archive $ArchivePath -Destination $unwrap
            $txz = Get-ChildItem -Path $unwrap -Filter '*.txz' -Recurse | Select-Object -First 1
            if ($null -eq $txz) { throw "No .txz found inside $($Component.name) archive" }
            Expand-TarTo -Archive $txz.FullName -Destination $TargetPath
            Remove-Item $unwrap -Recurse -Force
        }
        default {
            throw "Unknown archive type '$($Component.archive)' for $($Component.name)"
        }
    }
}

# ---------------------------------------------------------------------------

Write-Step "NetBoxLocal component fetch"

if (-not (Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

foreach ($dir in @($CacheDir, $StagingDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

$freeGB = [math]::Round((Get-PSDrive -Name ($RootDir.Substring(0,1))).Free / 1GB, 1)
Write-Host "    NetBox target version : $($manifest.netboxVersion)"
Write-Host "    Free disk space       : $freeGB GB"
if ($freeGB -lt 5) {
    Write-Warn "Less than 5 GB free. The bundle build needs roughly 3-4 GB of intermediates."
}

$hashesChanged = $false
$results = @()

foreach ($component in $manifest.components) {
    Write-Step "$($component.name) $($component.version)  ($($component.sizeMB) MB)"

    $fileName = Split-Path $component.url -Leaf
    if ($fileName -notmatch '\.') { $fileName = "$($component.name).bin" }
    $cachePath = Join-Path $CacheDir $fileName

    if ($Force -and (Test-Path $cachePath)) { Remove-Item $cachePath -Force }

    if (Test-Path $cachePath) {
        Write-Host "    cached: $fileName"
    }
    else {
        Write-Host "    downloading ..."
        Invoke-Download -Url $component.url -Destination $cachePath
    }

    $actualHash = Get-FileHashHex -Path $cachePath

    if ([string]::IsNullOrWhiteSpace($component.sha256)) {
        Write-Warn "No pinned hash yet. Observed: $actualHash"
        $component.sha256 = $actualHash
        $hashesChanged = $true
    }
    elseif ($component.sha256 -ne $actualHash) {
        throw @"
SHA256 MISMATCH for $($component.name).
  expected : $($component.sha256)
  actual   : $actualHash
  url      : $($component.url)
Refusing to build. Either upstream changed the artifact or the download is corrupt.
Investigate before re-pinning.
"@
    }
    else {
        Write-Ok "hash verified"
    }

    $targetPath = Join-Path $StagingDir $component.target
    Expand-Component -Component $component -ArchivePath $cachePath -TargetPath $targetPath
    Write-Ok "extracted to dist\staging\$($component.target)"

    $results += [pscustomobject]@{
        Component = $component.name
        Version   = $component.version
        Sha256    = $actualHash.Substring(0, 16) + '...'
    }
}

if ($hashesChanged) {
    if ($PinHashes) {
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $ManifestPath -Encoding utf8
        Write-Ok "Recorded observed hashes in components.json"
    }
    else {
        Write-Warn "Hashes were observed but NOT written. Re-run with -PinHashes once you have reviewed them."
    }
}

Write-Step "Summary"
$results | Format-Table -AutoSize | Out-String | Write-Host
Write-Ok "All components staged in dist\staging"
