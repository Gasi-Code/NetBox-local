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

    # Schedule for the export task. daily | weekdays | weekly, and HH:mm.
    [string]$SyncDays = 'daily',
    [string]$SyncTime = '17:00',

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
$SyncDays         = Get-InstallerValue $SyncDays
$SyncTime         = Get-InstallerValue $SyncTime

if ([string]::IsNullOrWhiteSpace($SyncDays)) { $SyncDays = 'daily' }
if ([string]::IsNullOrWhiteSpace($SyncTime)) { $SyncTime = '17:00' }
$SyncDays = $SyncDays.ToLowerInvariant()

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

# The import stays on whenever there is somewhere to import from. A server is
# not the only source: archives are just as often carried over on a stick or
# dropped on a share, and switching the import off because no server was named
# would leave those notebooks quietly ignoring the folder they were given.
# With neither a server nor a folder there is nothing to mirror at all, and
# standalone use is a first-class case here, not a misconfiguration.
if ([string]::IsNullOrWhiteSpace($NetBoxServer) -and [string]::IsNullOrWhiteSpace($SyncRoot)) {
    $config.import.autoImportOnStart = $false
}
else {
    $config.import.autoImportOnStart = $true
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
    Write-Host 'No NetBox server given; the automatic export stays switched off.'

    if ([string]::IsNullOrWhiteSpace($SyncRoot)) {
        Write-Host 'NetBox Local runs standalone - fill it with data through its own interface.'
    }
    else {
        Write-Host "Exports placed in $SyncRoot are still imported on every start,"
        Write-Host 'so archives copied there by hand or from a share work as usual.'
    }
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

    # The schedule is what keeps the local copy current, and it has to run while
    # the production NetBox is still reachable. During an outage it is too late.
    if ($SyncTime -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
        Write-Warning "'$SyncTime' is not a valid time (HH:mm). Falling back to 17:00."
        $SyncTime = '17:00'
    }

    switch ($SyncDays) {
        'weekdays' {
            $trigger = New-ScheduledTaskTrigger -Weekly -At $SyncTime `
                -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday
            $scheduleText = "Monday to Friday at $SyncTime"
        }
        'weekly' {
            $trigger = New-ScheduledTaskTrigger -Weekly -At $SyncTime -DaysOfWeek Monday
            $scheduleText = "Mondays at $SyncTime"
        }
        default {
            $trigger = New-ScheduledTaskTrigger -Daily -At $SyncTime
            $scheduleText = "daily at $SyncTime"
        }
    }

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

    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    # S4U runs the task whether or not the user is signed in, without storing a
    # password. It needs the "log on as a batch job" right, which managed
    # devices do not always grant - so fall back to Interactive rather than
    # leaving the notebook with no scheduled export at all.
    $registered = $false
    foreach ($logonType in @('S4U', 'Interactive')) {
        try {
            $principal = New-ScheduledTaskPrincipal `
                -UserId $currentUser -LogonType $logonType -RunLevel Limited

            Register-ScheduledTask -TaskName $taskName `
                -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
                -Force -ErrorAction Stop | Out-Null

            $registered = $true
            break
        }
        catch { }
    }

    if (-not $registered) { throw 'Register-ScheduledTask failed for both logon types.' }

    # Reading the task back is the only way to know it really exists and points
    # at the right script - registration can succeed and still be wrong.
    # It also decides what to report: a request for S4U can be accepted and then
    # quietly downgraded, and telling the operator the export runs without a
    # sign-in when it does not is how a notebook goes stale unnoticed.
    $check = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
    $actualLogon = [string]$check.Principal.LogonType

    Write-Host "Scheduled task '$taskName' registered: $scheduleText"
    if ($actualLogon -eq 'S4U' -or $actualLogon -eq 'Password') {
        Write-Host '  Runs whether or not you are signed in.'
    }
    else {
        Write-Host '  Runs while you are signed in. Missed runs are caught up at the next sign-in.'
    }
    Write-Host "  Account   : $($check.Principal.UserId) ($actualLogon)"
    Write-Host "  Next run  : $($info.NextRunTime)"
}
catch {
    Write-Warning "Could not register the scheduled task: $($_.Exception.Message)"
    Write-Host 'Register it manually with src\export\Register-SyncTask.ps1'
}
