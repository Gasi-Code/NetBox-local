#Requires -Version 5.1
<#
.SYNOPSIS
  Checks whether the configured NetBox can be reached and read.

.DESCRIPTION
  Answers, in order, the questions that decide whether an export can work:

    1. Is the server reachable at all?
    2. Does the token authenticate?
    3. Which NetBox version is it, and does it match the bundle?
    4. Which endpoints can the token actually read?

  Run it before blaming the export. A token that authenticates is not
  necessarily a token that may read anything: NetBox object permissions are
  per-model, so a valid token can still return 403 on most endpoints.

  Reads only. Nothing is written, on either side.

.PARAMETER FromConfig
  Take the server and token out of Sync-NetBoxExport.ps1 instead of passing
  them. This is the usual case - it tests exactly what the export would use.

.PARAMETER Detailed
  Probe every endpoint individually and list which ones are readable. Slower,
  but it shows precisely which permissions are missing.

.EXAMPLE
  .\Test-NetBoxConnection.ps1 -FromConfig
  .\Test-NetBoxConnection.ps1 -FromConfig -Detailed
  .\Test-NetBoxConnection.ps1 -Server https://netbox.example.com/ -ApiToken abc123
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$ApiToken,
    [switch]$FromConfig,
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'

# Kept identical to Sync-NetBoxExport.ps1 on purpose: a diagnosis that connects
# under different rules than the real export is worse than no diagnosis.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

try {
    $systemProxy = [Net.WebRequest]::GetSystemWebProxy()
    $systemProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
    [Net.WebRequest]::DefaultWebProxy = $systemProxy
}
catch { }

function Write-Check {
    param([bool]$Ok, [string]$Label, [string]$Detail = '')
    if ($Ok) {
        Write-Host ("  [ok]   " + $Label) -ForegroundColor Green
    }
    else {
        Write-Host ("  [FAIL] " + $Label) -ForegroundColor Red
    }
    if ($Detail) { Write-Host ("         " + $Detail) -ForegroundColor DarkGray }
}

# --- Where do server and token come from? ----------------------------------

if ($FromConfig -or (-not $Server)) {
    $exportScript = Join-Path $PSScriptRoot 'Sync-NetBoxExport.ps1'
    if (-not (Test-Path $exportScript)) { throw "Export script not found: $exportScript" }

    $Server = ((Select-String -Path $exportScript -Pattern '^\$NetBoxServer\s*=' |
        Select-Object -First 1).Line -replace '^\$NetBoxServer\s*=\s*"' -replace '"\s*$').Trim()
    $ApiToken = ((Select-String -Path $exportScript -Pattern '^\$APIKey\s*=' |
        Select-Object -First 1).Line -replace '^\$APIKey\s*=\s*"' -replace '"\s*$').Trim()

    Write-Host ''
    Write-Host "  Settings from $exportScript" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  NetBox connection test' -ForegroundColor Cyan
Write-Host '  ----------------------' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Server : $Server"
if ($ApiToken) {
    $masked = $ApiToken.Substring(0, [Math]::Min(4, $ApiToken.Length)) + ('*' * 8)
    Write-Host "  Token  : $masked ($($ApiToken.Length) characters)"
}
else {
    Write-Host '  Token  : none'
}
Write-Host ''

# --- 1. Configuration present ----------------------------------------------

if ([string]::IsNullOrWhiteSpace($Server)) {
    Write-Check $false 'No server configured' 'NetBox Local runs standalone; nothing to test.'
    return
}

$tokenLooksUnset = [string]::IsNullOrWhiteSpace($ApiToken) -or $ApiToken -match '^X+$'
if ($tokenLooksUnset) {
    Write-Check $false 'No API token configured' 'Still a placeholder in Sync-NetBoxExport.ps1.'
    return
}

$headers = @{ 'Authorization' = "Token $ApiToken"; 'Accept' = 'application/json' }
$baseUrl = $Server.TrimEnd('/')

# --- 2. Reachability --------------------------------------------------------

try {
    $null = Invoke-WebRequest -Uri $baseUrl -Method Head -TimeoutSec 20 -UseBasicParsing
    Write-Check $true 'Server reachable'
}
catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code) {
        Write-Check $true 'Server reachable' "answered HTTP $code without a token, which is fine"
    }
    else {
        Write-Check $false 'Server not reachable' $_.Exception.Message
        Write-Host ''
        Write-Host '  Check the address, DNS and whether a VPN is required.'

        # On a managed machine the cause is usually one of three things, and
        # the raw .NET message names none of them.
        $reason = $_.Exception.Message
        if ($reason -match 'SSL|TLS|trust relationship|secure channel') {
            Write-Host ''
            Write-Host '  The message points at the certificate. If your network inspects TLS,'
            Write-Host '  the inspection CA has to be trusted by this machine. Opening the same'
            Write-Host '  address in a browser here shows whether it is.'
        }
        elseif ($reason -match '407|proxy') {
            Write-Host ''
            Write-Host '  The message points at a proxy. This script already sends your Windows'
            Write-Host '  credentials to it; if that is refused, the proxy needs a rule for this'
            Write-Host '  destination, or the account needs permission to reach it.'
        }
        return
    }
}

# --- 3. Authentication ------------------------------------------------------

$version = $null
try {
    $status = Invoke-RestMethod -Uri "$baseUrl/api/status/" -Headers $headers -TimeoutSec 20
    $version = $status.'netbox-version'
    Write-Check $true 'Token accepted' "NetBox $version"

    $plugins = @()
    if ($status.plugins) { $plugins = $status.plugins.PSObject.Properties.Name }
    if ($plugins.Count) {
        Write-Host "         Plugins: $($plugins -join ', ')" -ForegroundColor DarkGray
        Write-Host '         Their objects cannot be imported locally.' -ForegroundColor DarkGray
    }
}
catch {
    $code = $_.Exception.Response.StatusCode.value__

    if ($code -eq 401) {
        Write-Check $false 'Token rejected (401)' 'The token does not exist or has expired.'
    }
    elseif ($code -eq 403) {
        Write-Check $false 'Token refused (403)' 'The token exists but may not read this endpoint.'
    }
    else {
        Write-Check $false "Authentication failed (HTTP $code)" $_.Exception.Message
    }

    Write-Host ''
    Write-Host '  What to do:' -ForegroundColor Yellow
    Write-Host '    1. In NetBox: Admin - API Tokens. Does the token still exist and is it enabled?'
    Write-Host '    2. Is it past its expiry date?'
    Write-Host '    3. Does its user have a permission granting "view" on the object types?'
    Write-Host '       A token authenticates as its user - without object permissions it sees nothing.'
    Write-Host '    4. Is the token restricted to certain source IP addresses?'
    Write-Host ''
    return
}

# --- 4. Version against the bundle -----------------------------------------

$manifestPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'build\components.json'
if (Test-Path $manifestPath) {
    $bundleVersion = (Get-Content $manifestPath -Raw | ConvertFrom-Json).netboxVersion
    $remoteMinor = ($version -split '\.')[0..1] -join '.'
    $bundleMinor = ($bundleVersion -split '\.')[0..1] -join '.'

    if ($remoteMinor -eq $bundleMinor) {
        Write-Check $true "Version matches the bundle ($bundleVersion)"
    }
    else {
        Write-Check $false 'Version mismatch' "instance $version, bundle $bundleVersion"
        Write-Host '         The import will refuse to run. Rebuild with:' -ForegroundColor Yellow
        Write-Host "         .\build\Set-NetBoxVersion.ps1 -FromServer $Server" -ForegroundColor Yellow
    }
}

# --- 5. Read permissions ----------------------------------------------------

Write-Host ''
Write-Host '  Read access' -ForegroundColor Cyan

$probes = @(
    'dcim/sites', 'dcim/devices', 'dcim/manufacturers', 'dcim/racks',
    'ipam/prefixes', 'ipam/ip-addresses', 'ipam/vlans',
    'tenancy/tenants', 'circuits/circuits', 'virtualization/virtual-machines'
)

if ($Detailed) {
    $root = Invoke-RestMethod -Uri "$baseUrl/api/" -Headers $headers -TimeoutSec 20
    $probes = @()
    foreach ($app in $root.PSObject.Properties) {
        if ($app.Name -eq 'status') { continue }
        try {
            $appDoc = Invoke-RestMethod -Uri "$baseUrl/api/$($app.Name)/" -Headers $headers -TimeoutSec 20
            foreach ($model in $appDoc.PSObject.Properties) {
                if ([string]$model.Value -match '^https?://') { $probes += "$($app.Name)/$($model.Name)" }
            }
        }
        catch { }
    }
}

$readable = @()
$denied = @()

foreach ($probe in $probes) {
    try {
        $null = Invoke-RestMethod -Uri "$baseUrl/api/$probe/?limit=1" -Headers $headers -TimeoutSec 20
        $readable += $probe
    }
    catch {
        $denied += $probe
    }
}

Write-Host ("    readable : {0}" -f $readable.Count) -ForegroundColor Green
if ($denied.Count) {
    Write-Host ("    denied   : {0}" -f $denied.Count) -ForegroundColor Red
}
else {
    Write-Host ("    denied   : 0") -ForegroundColor Green
}

if ($denied.Count) {
    Write-Host ''
    Write-Host '    Denied endpoints:' -ForegroundColor Yellow
    $denied | Select-Object -First 15 | ForEach-Object { Write-Host "      $_" }
    if ($denied.Count -gt 15) { Write-Host "      ... and $($denied.Count - 15) more" }
}

# --- Verdict ----------------------------------------------------------------

Write-Host ''
if ($denied.Count -eq 0) {
    Write-Host '  Everything checks out - the export will produce a complete dataset.' -ForegroundColor Green
}
elseif ($readable.Count -eq 0) {
    Write-Host '  The token authenticates but may not read anything.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  In NetBox: Admin - Permissions. Create a permission with:' -ForegroundColor Yellow
    Write-Host '    Object types : all (or at least DCIM, IPAM, Tenancy, Circuits)'
    Write-Host '    Actions      : view'
    Write-Host '    Assigned to  : the user the token belongs to'
}
else {
    Write-Host '  Partially readable - the export will be marked "partial".' -ForegroundColor Yellow
    Write-Host '  Extend the permissions of the token user for the endpoints listed above.'
}
Write-Host ''
