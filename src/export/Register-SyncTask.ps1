#Requires -Version 5.1
<#
.SYNOPSIS
  Registriert den taeglichen NetBox-Gesamtexport als Taskplaner-Aufgabe.

.DESCRIPTION
  Basis: ein aelteres schtasks.exe-basiertes Registrierungsskript.

  Three problems with the schtasks.exe-based predecessor are addressed here:

    1. The password was passed as /RP <plaintext>. Command lines are readable by
       any process on the machine, so the account's password was exposed on
       every registration. The ScheduledTasks cmdlets take a PSCredential and
       hand the secret to the service without it appearing in a command line.

    2. The task ran as SYSTEM with /RL HIGHEST. A job that only needs to make
       HTTPS requests and write into one folder does not need the most
       privileged account on the machine. It now runs as the invoking user with
       normal privileges by default.

    3. Registration failures were only visible via an exit code. The task is now
       read back and its key properties printed, so a wrong account or a typo in
       the path is caught immediately.

.PARAMETER Uhrzeit
  Startzeit im Format HH:mm. Bei mehreren Notfallnotebooks staffeln, damit sie
  den Server nicht gleichzeitig treffen.

.PARAMETER Benutzer
  Konto, unter dem der Task laeuft. Ohne Angabe laeuft er als der Benutzer, der
  dieses Skript ausfuehrt - dann allerdings nur, wenn dieser angemeldet ist.

.PARAMETER AlsSystem
  Registriert den Task unter dem SYSTEM-Konto. Nur verwenden, wenn der Export
  auch ohne angemeldeten Benutzer laufen muss, und im Wissen, dass der
  API-Token damit fuer jeden lokalen Administrator lesbar wird.

.PARAMETER Entfernen
  Entfernt eine zuvor registrierte Aufgabe.

.EXAMPLE
  .\Register-SyncTask.ps1
  .\Register-SyncTask.ps1 -Uhrzeit "17:15"
  .\Register-SyncTask.ps1 -Benutzer "DOMAIN\svc-netboxsync"
  .\Register-SyncTask.ps1 -Entfernen
#>
[CmdletBinding()]
Param (
    [string]$SkriptPfad = (Join-Path $PSScriptRoot "Sync-NetBoxExport.ps1"),
    [string]$TaskName   = "NetBox-Gesamtexport",
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$Uhrzeit    = "17:00",
    [string]$Benutzer,
    [switch]$AlsSystem,
    [switch]$Entfernen
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------

If ($Entfernen) {
    $Vorhanden = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    If ($null -eq $Vorhanden) {
        Write-Host "Task '$TaskName' does not exist."
        Return
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Task '$TaskName' removed."
    Return
}

If (-not (Test-Path -Path $SkriptPfad)) {
    Throw "Script '$SkriptPfad' not found."
}

# Resolve to an absolute path. The scheduler has no notion of the working
# directory this script was started from, so a relative path would silently
# produce a task that fails every night.
$SkriptPfad = (Resolve-Path -Path $SkriptPfad).Path

$Aktion = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $SkriptPfad + '"') `
    -WorkingDirectory (Split-Path $SkriptPfad -Parent)

$Ausloeser = New-ScheduledTaskTrigger -Daily -At $Uhrzeit

# A notebook is rarely running at exactly 17:00. Without a catch-up rule the
# export is simply skipped on every day the machine happened to be off or
# asleep - which is exactly the sort of silent gap that leaves stale data on an
# emergency device.
$Einstellungen = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 15)

If ($AlsSystem) {
    Write-Warning (
        "Der Task wird als SYSTEM registriert. Der NetBox-API-Token im " +
        "Exportskript ist damit fuer jeden lokalen Administrator lesbar. " +
        "Verwende einen Token mit ausschliesslich Leserechten."
    )

    $Principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Limited

    $Registrierung = @{
        TaskName  = $TaskName
        Action    = $Aktion
        Trigger   = $Ausloeser
        Settings  = $Einstellungen
        Principal = $Principal
        Force     = $true
    }
}
ElseIf ([string]::IsNullOrWhiteSpace($Benutzer)) {
    # Runs in the context of the current user, only while they are logged on.
    $Principal = New-ScheduledTaskPrincipal `
        -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive `
        -RunLevel Limited

    $Registrierung = @{
        TaskName  = $TaskName
        Action    = $Aktion
        Trigger   = $Ausloeser
        Settings  = $Einstellungen
        Principal = $Principal
        Force     = $true
    }
}
Else {
    $Anmeldedaten = Get-Credential `
        -UserName $Benutzer `
        -Message ("Passwort fuer " + $Benutzer + " (wird nur zur Task-Registrierung benoetigt)")

    # The credential object is handed to the scheduler service directly; unlike
    # schtasks /RP the password never appears in a command line.
    $Registrierung = @{
        TaskName = $TaskName
        Action   = $Aktion
        Trigger  = $Ausloeser
        Settings = $Einstellungen
        User     = $Anmeldedaten.UserName
        Password = $Anmeldedaten.GetNetworkCredential().Password
        RunLevel = 'Limited'
        Force    = $true
    }
}

Register-ScheduledTask @Registrierung | Out-Null

# Read the task back rather than trusting the registration call. A task that
# exists but runs as the wrong account fails silently every night.
$Angelegt = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
$Info     = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop

Write-Host ""
Write-Host "Task registered:" -ForegroundColor Green
Write-Host ("  Name       : " + $Angelegt.TaskName)
Write-Host ("  Script     : " + $SkriptPfad)
Write-Host ("  Start time : " + $Uhrzeit + " daily")
Write-Host ("  Account    : " + $Angelegt.Principal.UserId)
Write-Host ("  Run level  : " + $Angelegt.Principal.RunLevel)
Write-Host ("  Next run   : " + $Info.NextRunTime)
Write-Host ""
Write-Host "Trigger a test run with:" -ForegroundColor Cyan
Write-Host ("  Start-ScheduledTask -TaskName '" + $TaskName + "'")
Write-Host ""
Write-Host "With several emergency notebooks, stagger the times so they do not all"
Write-Host "pull a full export at once (17:00, 17:15, 17:30 ...)."
