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

    [string]$ConfigPath
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

$config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding utf8

Write-Host "Access mode set to '$Mode' in $ConfigPath"

if ([string]::IsNullOrWhiteSpace($Password)) {
    Write-Host 'No password given; one will be generated on first start.'
}
