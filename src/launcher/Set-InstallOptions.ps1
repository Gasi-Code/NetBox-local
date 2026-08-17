#Requires -Version 5.1
<#
.SYNOPSIS
  Writes the access mode and passwords chosen during installation into the
  configuration file.

.DESCRIPTION
  Called by the MSI once the files are in place, and usable by hand afterwards
  to change the mode or reset a password without editing JSON.

  Only the webUser section is touched; every other setting in the file survives,
  because the file is parsed and re-serialised rather than regenerated.

.PARAMETER Mode
  readonly  - one account with read permissions only (recommended for
              emergency notebooks)
  superuser - one account with full access, for using NetBox Local as a
              self-contained local NetBox
  both      - both accounts side by side

.PARAMETER Password
  Password for the primary account. Left empty, a random one is generated on
  first start and stored under %LOCALAPPDATA%\NetBoxLocal\secrets.

.EXAMPLE
  .\Set-InstallOptions.ps1 -Mode superuser -Username admin -Password 'Secret123'
  .\Set-InstallOptions.ps1 -Mode both -Password 'Secret123' -ReadOnlyPassword 'Look123'
  .\Set-InstallOptions.ps1 -Mode readonly
#>
[CmdletBinding()]
param(
    [ValidateSet('readonly', 'superuser', 'both')]
    [string]$Mode = 'readonly',

    [string]$Username = 'admin',
    [string]$Password = '',

    [string]$ReadOnlyUsername = 'viewer',
    [string]$ReadOnlyPassword = '',

    [string]$SyncRoot = '',
    [string]$NetBoxServer = '',
    [string]$ApiKey = '',
    [string]$ScriptPath = '',

    [string]$ConfigPath,
    [string]$ExportScriptPath
)

$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $rootDir    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $ConfigPath = Join-Path $rootDir 'config\NetBoxLocal.json'
}

if (-not (Test-Path $ConfigPath)) { throw "Configuration not found: $ConfigPath" }

if ($Mode -eq 'both' -and $Username -eq $ReadOnlyUsername) {
    throw "The read-only account must not have the same name as the primary one ('$Username')."
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$config.webUser.mode             = $Mode
$config.webUser.username         = $Username
$config.webUser.password         = $Password
$config.webUser.readOnlyUsername = $ReadOnlyUsername
$config.webUser.readOnlyPassword = $ReadOnlyPassword

if (-not [string]::IsNullOrWhiteSpace($SyncRoot)) {
    $config.import.syncRoot = $SyncRoot
}

# Without a server address there is nothing to mirror, so the automatic import
# would only produce a warning on every start. Standalone use is a first-class
# case here, not a misconfiguration.
if ([string]::IsNullOrWhiteSpace($NetBoxServer)) {
    $config.import.autoImportOnStart = $false
}

$config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding utf8

Write-Host "Access mode set to '$Mode' in $ConfigPath"

if ([string]::IsNullOrWhiteSpace($Password)) {
    Write-Host 'No password given; one will be generated on first start.'
}

# --- Export script --------------------------------------------------------

if (-not $ExportScriptPath) {
    $rootDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $ExportScriptPath = Join-Path $rootDir 'src\export\Sync-NetBoxExport.ps1'
}

if ([string]::IsNullOrWhiteSpace($NetBoxServer)) {
    Write-Host 'No NetBox server given; the API export stays switched off.'
    Write-Host 'NetBox Local runs standalone - fill it with data through its own interface.'
    return
}

if (-not (Test-Path $ExportScriptPath)) {
    Write-Warning "Export script not found: $ExportScriptPath"
    return
}

# The export script keeps its settings in assignments at the top of the file.
# Rewriting those lines is enough; the rest of the script is untouched.
$lines = Get-Content $ExportScriptPath

$replacements = @{
    '^\$NetBoxServer\s*=' = ('$NetBoxServer        = "{0}"' -f $NetBoxServer)
}

if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    $replacements['^\$APIKey\s*='] = ('$APIKey              = "{0}"' -f $ApiKey)
}
if (-not [string]::IsNullOrWhiteSpace($ScriptPath)) {
    $replacements['^\$global:ScriptPath\s*='] = ('$global:ScriptPath     = "{0}"' -f $ScriptPath)
}
if (-not [string]::IsNullOrWhiteSpace($SyncRoot)) {
    $replacements['^\$global:LocalSyncPath\s*='] = ('$global:LocalSyncPath  = "{0}"' -f $SyncRoot)
}

$updated = foreach ($line in $lines) {
    $result = $line
    foreach ($pattern in $replacements.Keys) {
        if ($line -match $pattern) { $result = $replacements[$pattern]; break }
    }
    $result
}

$updated | Set-Content -Path $ExportScriptPath -Encoding utf8

Write-Host "Export configured for $NetBoxServer"
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Host 'No API token given - add it to Sync-NetBoxExport.ps1 before the first export.'
}
