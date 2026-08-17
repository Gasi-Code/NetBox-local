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
    # No ValidateSet here: the installer appends a sentinel character to every
    # value (see Get-InstallerValue below), so parameter binding would reject a
    # perfectly valid mode before this script gets a chance to clean it up.
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

# MSI directory properties always end in a backslash, and a backslash directly
# before the closing quote escapes that quote on a Windows command line. The
# arguments after it then merge into one - a folder property would swallow
# everything up to the next quote, producing paths like
# "C:\Sync-Daten\NetBoxLocal" -NetBoxServer "https://...".
#
# The installer therefore appends a sentinel to every value so the closing quote
# can never sit behind a backslash. It is stripped here, together with any
# trailing separator.
function Get-InstallerValue {
    param([string]$Raw)

    if ($null -eq $Raw) { return '' }

    $value = $Raw
    if ($value.EndsWith('|')) { $value = $value.Substring(0, $value.Length - 1) }
    return $value.Trim().TrimEnd('\')
}

$Mode             = Get-InstallerValue $Mode
$Username         = Get-InstallerValue $Username
$Password         = Get-InstallerValue $Password
$ReadOnlyUsername = Get-InstallerValue $ReadOnlyUsername
$ReadOnlyPassword = Get-InstallerValue $ReadOnlyPassword
$SyncRoot         = Get-InstallerValue $SyncRoot
$NetBoxServer     = Get-InstallerValue $NetBoxServer
$ApiKey           = Get-InstallerValue $ApiKey
$ScriptPath       = Get-InstallerValue $ScriptPath

if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = 'readonly' }
if ([string]::IsNullOrWhiteSpace($Username)) { $Username = 'admin' }
if ([string]::IsNullOrWhiteSpace($ReadOnlyUsername)) { $ReadOnlyUsername = 'viewer' }

$Mode = $Mode.ToLowerInvariant()
if (@('readonly', 'superuser', 'both') -notcontains $Mode) {
    Write-Warning "Unknown mode '$Mode'; falling back to 'readonly'."
    $Mode = 'readonly'
}

# A path that arrived mangled would otherwise be written into the configuration
# and only surface later, when the launcher tries to use it.
foreach ($pair in @(@{ Name = 'SyncRoot'; Value = $SyncRoot }, @{ Name = 'ScriptPath'; Value = $ScriptPath })) {
    if ([string]::IsNullOrWhiteSpace($pair.Value)) { continue }
    if ($pair.Value.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or $pair.Value -match '["|]') {
        throw "The value for $($pair.Name) is not a usable path: $($pair.Value)"
    }
}

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

# --- Directories and scheduled task ---------------------------------------
#
# Configuring the export is not the same as having it run. Without these steps
# the sync folder never appears, no export is ever taken, and the first start
# reports "import source not available" with no hint as to why.

foreach ($directory in @($SyncRoot, $ScriptPath)) {
    if ([string]::IsNullOrWhiteSpace($directory)) { continue }
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Write-Host "Created $directory"
    }
}

$taskName = 'NetBox Local export'

try {
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ExportScriptPath + '"') `
        -WorkingDirectory (Split-Path $ExportScriptPath -Parent)

    # 17:00 is late enough that the day's changes are in, early enough that
    # someone is still around if it fails.
    $trigger = New-ScheduledTaskTrigger -Daily -At '17:00'

    # A notebook is rarely awake at exactly 17:00. Without a catch-up rule the
    # export is skipped on every day the machine happened to be off, which is
    # precisely how a dataset quietly goes stale.
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -DontStopIfGoingOnBatteries `
        -AllowStartIfOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 15)

    $principal = New-ScheduledTaskPrincipal `
        -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel Limited

    Register-ScheduledTask -TaskName $taskName `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Force | Out-Null

    Write-Host "Scheduled task '$taskName' registered for 17:00 daily"
}
catch {
    Write-Warning "Could not register the scheduled task: $($_.Exception.Message)"
    Write-Host 'Register it manually with src\export\Register-SyncTask.ps1'
}
