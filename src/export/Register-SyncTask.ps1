#Requires -Version 5.1
<#
.SYNOPSIS
  Registers, changes or removes the scheduled NetBox export.

.DESCRIPTION
  The installer already registers this task. This script exists to change the
  schedule afterwards - a different time, other days - without reinstalling,
  and to repair the task if it was deleted.

  It writes the same task the installer writes ("NetBox Local export"), so
  running it replaces the existing schedule instead of adding a second one
  alongside it. Two tasks pulling full exports at the same time is exactly the
  kind of duplicate nobody notices until the server complains.

  The export runs completely independently of NetBox Local. The application
  never has to be started for the data to stay current - which is the whole
  point, because during an outage it is far too late to start collecting.

  Three problems of the older schtasks.exe-based predecessor are addressed:

    1. The password was passed as /RP <plaintext>. Command lines are readable
       by any process on the machine. The ScheduledTasks cmdlets take a
       PSCredential and hand the secret to the service without it ever
       appearing in a command line.

    2. The task ran as SYSTEM with /RL HIGHEST. A job that only makes HTTPS
       requests and writes into one folder does not need the most privileged
       account on the machine. It now runs as the invoking user with normal
       privileges.

    3. Registration failures were only visible as an exit code. The task is
       read back and its real properties printed, so a wrong account or a typo
       in the path is caught immediately.

.PARAMETER Time
  Start time as HH:mm. With several emergency notebooks, stagger the times so
  they do not all pull a full export at once.

.PARAMETER Days
  daily    - every day
  weekdays - Monday to Friday
  weekly   - Mondays only

.PARAMETER User
  Account to run the task under. Without this it runs as the user calling the
  script.

.PARAMETER AsSystem
  Registers the task under the SYSTEM account. Only use this if the export must
  run with no user logged on at all, and knowing that the API token in the
  export script becomes readable to every local administrator.

.PARAMETER Remove
  Removes the registered task.

.PARAMETER Status
  Prints the current task without changing anything.

.EXAMPLE
  .\Register-SyncTask.ps1 -Status
  .\Register-SyncTask.ps1 -Time "17:15"
  .\Register-SyncTask.ps1 -Days weekdays -Time "07:30"
  .\Register-SyncTask.ps1 -User "DOMAIN\svc-netboxsync"
  .\Register-SyncTask.ps1 -Remove
#>
[CmdletBinding()]
Param (
    [string]$ScriptPath = (Join-Path $PSScriptRoot "Sync-NetBoxExport.ps1"),
    [string]$TaskName   = "NetBox Local export",
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$Time       = "17:00",
    [ValidateSet('daily', 'weekdays', 'weekly')]
    [string]$Days       = 'daily',
    [string]$User,
    [switch]$AsSystem,
    [switch]$Remove,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'

function Show-Task {
    Param ([string]$Name)

    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Host "No task '$Name' is registered."
        Write-Host "Create it with: .\Register-SyncTask.ps1"
        return $false
    }

    $info   = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction Stop
    $action = $task.Actions | Select-Object -First 1
    $logon  = [string]$task.Principal.LogonType

    Write-Host ""
    Write-Host "  Name       : $($task.TaskName)"
    Write-Host "  State      : $($task.State)"
    Write-Host "  Account    : $($task.Principal.UserId) ($logon)"
    Write-Host "  Command    : $($action.Execute) $($action.Arguments)"
    Write-Host "  Next run   : $($info.NextRunTime)"
    Write-Host "  Last run   : $($info.LastRunTime)  (result $($info.LastTaskResult))"

    if ($logon -eq 'S4U' -or $logon -eq 'Password' -or $logon -eq 'ServiceAccount') {
        Write-Host "  Runs whether or not you are signed in."
    }
    else {
        Write-Host "  Runs while you are signed in. Missed runs are caught up at the next sign-in."
    }
    Write-Host ""
    return $true
}

# ---------------------------------------------------------------------------

if ($Status) {
    [void](Show-Task -Name $TaskName)
    return
}

if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        Write-Host "Task '$TaskName' does not exist."
        return
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Task '$TaskName' removed."
    Write-Host "The local dataset is no longer refreshed automatically."
    return
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Script '$ScriptPath' not found."
}

# Resolve to an absolute path. The scheduler has no notion of the working
# directory this script was started from, so a relative path would silently
# produce a task that fails every night.
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ScriptPath + '"') `
    -WorkingDirectory (Split-Path $ScriptPath -Parent)

switch ($Days) {
    'weekdays' {
        $trigger = New-ScheduledTaskTrigger -Weekly -At $Time `
                     -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday
        $scheduleText = "Monday to Friday at $Time"
    }
    'weekly' {
        $trigger = New-ScheduledTaskTrigger -Weekly -At $Time -DaysOfWeek Monday
        $scheduleText = "Mondays at $Time"
    }
    default {
        $trigger = New-ScheduledTaskTrigger -Daily -At $Time
        $scheduleText = "daily at $Time"
    }
}

# A notebook is rarely running at exactly 17:00. Without a catch-up rule the
# export is simply skipped on every day the machine happened to be off or
# asleep - which is exactly the sort of silent gap that leaves stale data on an
# emergency device.
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 15)

if ($AsSystem) {
    Write-Warning (
        "The task will run as SYSTEM. The NetBox API token in the export " +
        "script then becomes readable to every local administrator. Use a " +
        "token with read permissions only."
    )

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
}
elseif ([string]::IsNullOrWhiteSpace($User)) {
    # S4U runs the task whether or not the user is signed in, without storing a
    # password. It needs the "log on as a batch job" right, which managed
    # devices do not always grant - so fall back to Interactive rather than
    # leaving the notebook with no scheduled export at all.
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $registered  = $false

    foreach ($logonType in @('S4U', 'Interactive')) {
        try {
            $principal = New-ScheduledTaskPrincipal `
                -UserId $currentUser -LogonType $logonType -RunLevel Limited

            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null

            $registered = $true
            break
        }
        catch { }
    }

    if (-not $registered) { throw "Register-ScheduledTask failed for both logon types." }
}
else {
    $credential = Get-Credential -UserName $User `
        -Message ("Password for " + $User + " (needed only to register the task)")

    # The credential object is handed to the scheduler service directly; unlike
    # schtasks /RP the password never appears in a command line.
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -User $credential.UserName `
        -Password $credential.GetNetworkCredential().Password `
        -RunLevel Limited -Force | Out-Null
}

Write-Host ""
Write-Host "Task registered: $scheduleText" -ForegroundColor Green

# Read the task back rather than trusting the registration call. A request for
# S4U can be accepted and then quietly downgraded, and a task that runs as the
# wrong account fails silently every night.
[void](Show-Task -Name $TaskName)

Write-Host "Trigger a test run with:" -ForegroundColor Cyan
Write-Host ("  Start-ScheduledTask -TaskName '" + $TaskName + "'")
Write-Host ""
Write-Host "With several emergency notebooks, stagger the times so they do not all"
Write-Host "pull a full export at once (17:00, 17:15, 17:30 ...)."
