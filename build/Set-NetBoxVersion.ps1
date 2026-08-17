#Requires -Version 5.1
<#
.SYNOPSIS
  Selects which NetBox version the bundle is built for.

.DESCRIPTION
  The bundle contains exactly one NetBox version, chosen at build time. It has
  to match the instance being mirrored: fields and models differ between minor
  releases, and the importer refuses to run on a mismatch rather than silently
  losing data.

  Getting that version wrong is the single most likely way to end up with an
  unusable bundle, so this script removes the guesswork. Three ways to use it:

    -FromServer   ask a running NetBox for its version and use that. The most
                  reliable option, and the one to use when mirroring.
    -List         show the ten most recent releases and pick one interactively.
    -Version      set a specific version directly.

  Only build/components.json is changed. Run the build afterwards:

    .\build\fetch-components.ps1 -PinHashes
    .\build\build-bundle.ps1

.PARAMETER FromServer
  URL of a NetBox instance, for example https://netbox.example.com/. Its
  version is read from /api/status/ and applied.

.PARAMETER ApiToken
  Token for -FromServer. Optional: many instances expose /api/status/ without
  authentication.

.PARAMETER Version
  An explicit version such as 4.6.8.

.PARAMETER List
  Show the ten most recent releases and choose one.

.EXAMPLE
  .\Set-NetBoxVersion.ps1 -FromServer https://netbox.example.com/ -ApiToken abc123
  .\Set-NetBoxVersion.ps1 -List
  .\Set-NetBoxVersion.ps1 -Version 4.6.8
#>
[CmdletBinding()]
param(
    [string]$FromServer,
    [string]$ApiToken,
    [string]$Version,
    [switch]$List
)

$ErrorActionPreference = 'Stop'

$BuildDir     = $PSScriptRoot
$ManifestPath = Join-Path $BuildDir 'components.json'

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    WARN $m" -ForegroundColor Yellow }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-RecentReleases {
    # Returns the ten most recent stable NetBox releases, newest first.
    $url = 'https://api.github.com/repos/netbox-community/netbox/releases?per_page=30'
    $headers = @{ 'User-Agent' = 'NetBoxLocal-Build'; 'Accept' = 'application/vnd.github+json' }

    $releases = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 60

    return $releases |
        Where-Object { -not $_.prerelease -and -not $_.draft } |
        ForEach-Object {
            [pscustomobject]@{
                Version   = $_.tag_name.TrimStart('v')
                Published = [datetime]$_.published_at
            }
        } |
        Select-Object -First 10
}

function Test-VersionAvailable {
    param([string]$Candidate)

    $url = "https://github.com/netbox-community/netbox/archive/refs/tags/v$Candidate.tar.gz"
    try {
        $response = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 30 -UseBasicParsing
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

function Get-PythonRequirement {
    param([string]$Candidate)

    $url = "https://raw.githubusercontent.com/netbox-community/netbox/v$Candidate/docs/installation/index.md"
    try {
        $doc = Invoke-WebRequest -Uri $url -TimeoutSec 30 -UseBasicParsing
        $line = ($doc.Content -split "`n") | Where-Object { $_ -match '\|\s*Python\s*\|' } | Select-Object -First 1
        if ($line) { return ($line -replace '.*\|\s*Python\s*\|\s*', '' -replace '\s*\|.*', '').Trim() }
    }
    catch { }
    return $null
}

# ---------------------------------------------------------------------------

if (-not (Test-Path $ManifestPath)) { throw "components.json not found at $ManifestPath" }
$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

Write-Host ''
Write-Host "  Current bundle version: $($manifest.netboxVersion)" -ForegroundColor White
Write-Host ''

# --- Determine the target version -----------------------------------------

if ($FromServer) {
    Write-Step "Reading the version from $FromServer"

    $statusUrl = $FromServer.TrimEnd('/') + '/api/status/'
    $headers = @{ 'Accept' = 'application/json' }
    if ($ApiToken) { $headers['Authorization'] = "Token $ApiToken" }

    try {
        $status = Invoke-RestMethod -Uri $statusUrl -Headers $headers -TimeoutSec 30
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 403 -or $code -eq 401) {
            throw "The instance answered $code. Supply a valid -ApiToken, or read the version from its interface and pass -Version instead."
        }
        throw "Could not reach $statusUrl : $($_.Exception.Message)"
    }

    $Version = $status.'netbox-version'
    if (-not $Version) { throw 'The response contained no netbox-version field.' }

    Write-Ok "Instance reports NetBox $Version"

    $plugins = @()
    if ($status.plugins) { $plugins = $status.plugins.PSObject.Properties.Name }
    if ($plugins.Count) {
        Write-Warn "The instance runs plugins: $($plugins -join ', ')"
        Write-Host '         Objects belonging to them cannot be imported locally,'
        Write-Host '         because the plugins are not part of the bundle.'
    }
}
elseif ($List -or (-not $Version)) {
    Write-Step 'Fetching the ten most recent NetBox releases'

    $releases = Get-RecentReleases

    Write-Host ''
    for ($i = 0; $i -lt $releases.Count; $i++) {
        $marker = ' '
        if ($releases[$i].Version -eq $manifest.netboxVersion) { $marker = '*' }
        Write-Host ("  {0}{1,2}. {2,-10} {3}" -f $marker, ($i + 1), $releases[$i].Version, $releases[$i].Published.ToString('yyyy-MM-dd'))
    }
    Write-Host ''
    Write-Host '  * = currently configured' -ForegroundColor DarkGray
    Write-Host ''

    $choice = Read-Host 'Number of the version to build (Enter to cancel)'
    if ([string]::IsNullOrWhiteSpace($choice)) { Write-Host 'Cancelled.'; return }

    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $releases.Count) {
        throw "Invalid selection: $choice"
    }

    $Version = $releases[$index - 1].Version
}

# --- Verify -----------------------------------------------------------------

Write-Step "Checking NetBox $Version"

if (-not (Test-VersionAvailable -Candidate $Version)) {
    throw "NetBox $Version has no release tarball on GitHub. Check the version number."
}
Write-Ok 'release tarball available'

$python = Get-PythonRequirement -Candidate $Version
if ($python) {
    Write-Host "    Requires Python: $python"

    $bundledPython = ($manifest.components | Where-Object { $_.name -eq 'python' }).version
    $bundledMinor = ($bundledPython -split '\.')[0..1] -join '.'

    if ($python -notmatch [regex]::Escape($bundledMinor)) {
        Write-Warn "The bundle ships Python $bundledPython, which this version does not list as supported."
        Write-Host '         Adjust the python component in components.json before building.'
    }
    else {
        Write-Ok "bundled Python $bundledPython is supported"
    }
}

if ($Version -eq $manifest.netboxVersion) {
    Write-Host ''
    Write-Ok "components.json already targets $Version - nothing to do."
    return
}

# --- Apply ------------------------------------------------------------------

Write-Step "Switching from $($manifest.netboxVersion) to $Version"

$manifest.netboxVersion = $Version

$netbox = $manifest.components | Where-Object { $_.name -eq 'netbox' }
$netbox.version = $Version
$netbox.url     = "https://github.com/netbox-community/netbox/archive/refs/tags/v$Version.tar.gz"
# Clearing the hash makes fetch-components record the new one instead of
# aborting on a mismatch against the previous release.
$netbox.sha256  = ''
$netbox.note    = "IMPORTANT: this version MUST match the NetBox instance being mirrored. Set with build\Set-NetBoxVersion.ps1 on $(Get-Date -Format 'yyyy-MM-dd'). The importer refuses to run when the minor versions differ, because fields and models change between releases."

$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $ManifestPath -Encoding utf8

Write-Ok "components.json now targets NetBox $Version"

Write-Host ''
Write-Host '  Next steps:' -ForegroundColor Cyan
Write-Host '    .\build\fetch-components.ps1 -PinHashes'
Write-Host '    .\build\build-bundle.ps1'
Write-Host '    .\src\launcher\Start-NetBoxServices.ps1 -Init -NoServe'
Write-Host '    .\installer\Build-Installer.ps1 -Version 1.3.0'
Write-Host ''
Write-Host '  The third step recreates the database for the new schema and'
Write-Host '  discards the current local dataset.' -ForegroundColor DarkGray
