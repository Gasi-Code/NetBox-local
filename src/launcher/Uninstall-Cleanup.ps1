#Requires -Version 5.1
<#
.SYNOPSIS
  Shuts NetBox Local down and removes its scheduled task. Runs before the files
  are deleted.

.DESCRIPTION
  Called by the installer during uninstall, and safe to run by hand.

  Two things outlive an uninstall that has nothing to remove them:

    1. The services. PostgreSQL, Garnet and the web server are ordinary
       processes started by the launcher, not services registered with Windows.
       Uninstalling while they run leaves them running - and their files locked,
       so part of the installation stays behind in a directory the uninstaller
       believes it removed.

    2. The scheduled export. It is registered under the user's account and
       points at a script inside the installation directory. Once that
       directory is gone the task remains, firing on schedule and failing every
       time, for as long as the machine exists.

  Both are cleaned up here. Nothing in this script touches the data directory:
  the database, the credentials and the downloaded exports are deliberately
  kept, so reinstalling picks up where the previous installation left off.

.PARAMETER TaskName
  Scheduled task to remove. Matches the name used by Register-SyncTask.ps1.

.PARAMETER KeepTask
  Leaves the scheduled task in place. Only useful when the export is meant to
  carry on feeding a folder that another installation reads.
#>
[CmdletBinding()]
Param (
    [string]$TaskName = 'NetBox Local export',
    [switch]$KeepTask
)

# An uninstall must not fail because cleanup did. Anything unexpected here is
# reported and stepped over - a stale task left behind is a nuisance, a blocked
# uninstall is worse.
$ErrorActionPreference = 'Continue'

Write-Host 'NetBox Local: cleaning up before removal'

# --- Services --------------------------------------------------------------

$servicesScript = Join-Path $PSScriptRoot 'Start-NetBoxServices.ps1'

if (Test-Path -LiteralPath $servicesScript) {
    try {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File ('"{0}"' -f $servicesScript) -Stop | Out-Null
        Write-Host '  services stopped'
    }
    catch {
        Write-Host "  could not stop the services: $($_.Exception.Message)"
    }
}

# The stop script identifies the web server by whoever holds its port, which
# covers the normal case. This is the fallback for an installation whose
# configuration has already gone: anything still running out of this directory
# is ours.
$installRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

foreach ($name in @('postgres', 'GarnetServer', 'python')) {
    foreach ($process in (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -and
                $process.Path.StartsWith($installRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $process.Kill()
                Write-Host "  stopped $name (pid $($process.Id))"
            }
        }
        catch { }
    }
}

# --- Scheduled task --------------------------------------------------------

if (-not $KeepTask) {
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Host "  scheduled task '$TaskName' removed"
        }
    }
    catch {
        Write-Host "  could not remove the scheduled task: $($_.Exception.Message)"
        Write-Host "  remove it by hand: Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
    }
}

Write-Host '  done. The data directory and its exports are kept.'
exit 0
