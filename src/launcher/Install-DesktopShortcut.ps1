#Requires -Version 5.1
<#
.SYNOPSIS
  Creates the "NetBox Local" desktop shortcut.

.DESCRIPTION
  Creates a shortcut pointing at NetBoxLocal.cmd and gives it the NetBox Local
  icon. Per user by default, which needs no administrator rights - the same
  reasoning as the rest of the installation.

.PARAMETER AllUsers
  Place it on the shared desktop instead of the current user's.
  Requires administrator rights.

.PARAMETER Remove
  Remove the shortcut.

.EXAMPLE
  .\Install-DesktopShortcut.ps1
  .\Install-DesktopShortcut.ps1 -AllUsers
  .\Install-DesktopShortcut.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$ShortcutName = 'NetBox Local',
    [switch]$AllUsers,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$LauncherDir = $PSScriptRoot
$RootDir     = Split-Path (Split-Path $LauncherDir -Parent) -Parent

$target = Join-Path $LauncherDir 'NetBoxLocal.cmd'
$icon   = Join-Path $RootDir 'assets\netbox-local.ico'

if ($AllUsers) {
    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
}
else {
    $desktop = [Environment]::GetFolderPath('Desktop')
}

$shortcutPath = Join-Path $desktop "$ShortcutName.lnk"

if ($Remove) {
    if (Test-Path $shortcutPath) {
        Remove-Item $shortcutPath -Force
        Write-Host "Shortcut removed: $shortcutPath"
    }
    else {
        Write-Host "There is no shortcut at $shortcutPath"
    }
    return
}

foreach ($required in @($target, $icon)) {
    if (-not (Test-Path $required)) { throw "Not found: $required" }
}

$shell    = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)

$shortcut.TargetPath       = $target
$shortcut.WorkingDirectory = $LauncherDir
$shortcut.IconLocation     = "$icon,0"
$shortcut.Description      = 'Start NetBox Local and load the current dataset'
$shortcut.WindowStyle      = 1

$shortcut.Save()

[Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null

Write-Host ''
Write-Host 'Shortcut created:' -ForegroundColor Green
Write-Host "  File   : $shortcutPath"
Write-Host "  Target : $target"
Write-Host "  Icon   : $icon"
Write-Host ''
Write-Host 'Double-clicking it starts NetBox Local, loads the most recent'
Write-Host 'dataset and opens the interface in a browser.'
