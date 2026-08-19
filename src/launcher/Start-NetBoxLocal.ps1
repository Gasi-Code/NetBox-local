#Requires -Version 5.1
<#
.SYNOPSIS
  One-click start for NetBox Local: bring up, load data, open.

.DESCRIPTION
  This is what the desktop icon runs. In order:

    1. read config\NetBoxLocal.json
    2. start PostgreSQL, Garnet and the web server
    3. import the most recent export found under the configured sync root
    4. make sure the login account exists and has the configured password
    5. open the browser

  Everything is driven by the configuration file so that a notebook can be set
  up once and then simply used.

.PARAMETER SkipImport
  Start only, do not load a dataset.

.PARAMETER ConfigPath
  Use a different configuration file.
#>
[CmdletBinding()]
param(
    [switch]$SkipImport,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$LauncherDir = $PSScriptRoot
$RootDir     = Split-Path (Split-Path $LauncherDir -Parent) -Parent
$BundleRoot  = Join-Path $RootDir 'dist\bundle'

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $RootDir 'config\NetBoxLocal.json'
}

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    WARN $m" -ForegroundColor Yellow }

function Test-PortInUse {
    param([int]$Port)
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start(); $listener.Stop(); return $false }
    catch { return $true }
}

function New-RandomSecret {
    param([int]$Length = 16)
    $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $sb = New-Object Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  NetBox Local' -ForegroundColor Cyan
Write-Host '  ------------' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path $ConfigPath)) { throw "Configuration not found: $ConfigPath" }
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$dataRoot = $config.paths.dataRoot
if ([string]::IsNullOrWhiteSpace($dataRoot)) {
    $dataRoot = Join-Path $env:LOCALAPPDATA 'NetBoxLocal'
}

$webPort   = $config.ports.web
$pythonExe = Join-Path $BundleRoot 'python\python.exe'
$netboxDir = Join-Path $BundleRoot 'netbox\netbox'

if (-not (Test-Path $pythonExe)) {
    throw "Bundle missing at $BundleRoot. Run build\fetch-components.ps1 and build\build-bundle.ps1 first."
}

$env:DOTNET_ROOT = Join-Path $BundleRoot 'dotnet'

# --- 1. Services -----------------------------------------------------------

# A listening port is not proof that *this* installation is running, and
# reusing whatever answers there is how an upgrade ends up serving pages from a
# directory that no longer exists. Two things have to hold before the services
# are left alone: the process must live inside this bundle, and the generated
# configuration.py must still be on disk. An upgrade removes that file along
# with the old bundle, and every Django command - the import, the account setup
# - fails without it.
$configPy     = Join-Path $netboxDir 'netbox\configuration.py'
$reuseRunning = $false

if (Test-PortInUse -Port $webPort) {
    $ownerPath = $null
    $conn = Get-NetTCPConnection -LocalPort $webPort -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if ($conn) {
        $ownerPath = (Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue).Path
    }

    $belongsHere = $ownerPath -and
                   $ownerPath.StartsWith($BundleRoot, [StringComparison]::OrdinalIgnoreCase)

    if ($belongsHere -and (Test-Path -LiteralPath $configPy)) {
        $reuseRunning = $true
        Write-Ok "NetBox Local is already running on port $webPort"
    }
    else {
        if (-not $belongsHere) {
            Write-Warn "Port $webPort is held by an older or foreign instance."
            if ($ownerPath) { Write-Warn "  $ownerPath" }
        }
        else {
            Write-Warn 'The running instance lost its configuration, most likely through an upgrade.'
        }

        Write-Step 'Stopping it before starting this installation'
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File ('"{0}"' -f (Join-Path $LauncherDir 'Start-NetBoxServices.ps1')) -Stop |
            Out-Null

        $stopDeadline = (Get-Date).AddSeconds(60)
        while ((Test-PortInUse -Port $webPort) -and (Get-Date) -lt $stopDeadline) {
            Start-Sleep -Seconds 2
        }

        if (Test-PortInUse -Port $webPort) {
            throw "Port $webPort is still in use. Close the other instance, then start again."
        }

        Write-Ok 'stopped'
    }
}

if (-not $reuseRunning) {
    Write-Step 'Starting services'

    # The stack runs detached so this script can carry on and do the import.
    # Start-NetBoxServices.ps1 blocks on the web server by design.
    # The path must be quoted explicitly. Start-Process does not add quotes
    # around ArgumentList entries, so an installation directory containing a
    # space - and the default one is "NetBox Local" - would be cut in half:
    # powershell then reports that "...\Programs\NetBox" is not a .ps1 file.
    $servicesScript = Join-Path $LauncherDir 'Start-NetBoxServices.ps1'

    $stack = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $servicesScript)
        ) `
        -WindowStyle Hidden -PassThru

    # A start that fails part of the way through leaves PostgreSQL and Garnet
    # behind - they are separate processes and outlive the script that spawned
    # them. Every later attempt then stops at "port 55432 is already in use",
    # which describes the symptom of the first failure rather than its cause,
    # and the way out takes knowledge the person in front of the machine has no
    # reason to have. So clean up before reporting.
    $failure  = $null
    $deadline = (Get-Date).AddMinutes(6)

    while (-not (Test-PortInUse -Port $webPort)) {
        if ($stack.HasExited) {
            $failure = "Startup failed. See the logs in $dataRoot\logs."
            break
        }
        if ((Get-Date) -gt $deadline) {
            $failure = "Timed out waiting for startup. See the logs in $dataRoot\logs."
            break
        }
        Start-Sleep -Seconds 2
    }

    if ($failure) {
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File ('"{0}"' -f $servicesScript) -Stop | Out-Null
        throw $failure
    }

    Write-Ok "Services running (port $webPort)"
}

# --- 2. Load the dataset ---------------------------------------------------

if ($SkipImport -or -not $config.import.autoImportOnStart) {
    Write-Warn 'Import skipped; showing the dataset from the previous run.'
}
else {
    $syncRoot = $config.import.syncRoot

    # Test-Path throws on a malformed path rather than returning false, which
    # would abort the whole start over a single bad configuration value. A
    # missing or unusable data source is not a reason to refuse to run: the
    # previously imported dataset is still there and still useful.
    $syncRootUsable = $false
    if (-not [string]::IsNullOrWhiteSpace($syncRoot)) {
        try { $syncRootUsable = Test-Path -LiteralPath $syncRoot }
        catch {
            Write-Warn "The configured import source is not a valid path: $syncRoot"
            Write-Warn "Correct 'import.syncRoot' in $ConfigPath."
        }
    }

    # Nothing to import yet, but an export is configured: take one now rather
    # than starting empty and leaving the user to work out why. This is the
    # first-run case - afterwards the scheduled task keeps the data current.
    $exportScript = Join-Path $RootDir 'src\export\Sync-NetBoxExport.ps1'
    $haveExport = $false

    # Declared here because the messages further down depend on it even when
    # the block that determines it is skipped.
    $serverSet = $false

    if ($syncRootUsable) {
        $haveExport = [bool](
            (Get-ChildItem -Path $syncRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue) -or
            (Get-ChildItem -Path $syncRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') })
        )
    }

    if (-not $haveExport -and (Test-Path $exportScript)) {
        $configuredServer = (Select-String -Path $exportScript -Pattern '^\$NetBoxServer\s*=' |
            Select-Object -First 1).Line -replace '^\$NetBoxServer\s*=\s*"' -replace '"\s*$'
        $configuredKey = (Select-String -Path $exportScript -Pattern '^\$APIKey\s*=' |
            Select-Object -First 1).Line -replace '^\$APIKey\s*=\s*"' -replace '"\s*$'

        $serverSet = -not [string]::IsNullOrWhiteSpace($configuredServer)
        $keySet = (-not [string]::IsNullOrWhiteSpace($configuredKey)) -and ($configuredKey -notmatch '^X+$')

        if ($serverSet -and $keySet) {
            Write-Step "No dataset yet - fetching one from $configuredServer"
            Write-Host '    This runs once and may take several minutes.'

            if (-not (Test-Path $syncRoot)) {
                New-Item -ItemType Directory -Path $syncRoot -Force | Out-Null
            }

            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ('"{0}"' -f $exportScript) |
                Select-Object -Last 2 | Write-Host

            $syncRootUsable = Test-Path -LiteralPath $syncRoot
        }
        elseif ($serverSet) {
            Write-Warn 'A NetBox server is configured but no API token. Add it to src\export\Sync-NetBoxExport.ps1.'
        }
    }

    if (-not $syncRootUsable) {
        Write-Warn 'Import source not available. Showing the dataset from the previous run.'
    }
    else {
        # Accept both an already extracted export directory and a weekday ZIP.
        $candidates = @()

        $candidates += Get-ChildItem -Path $syncRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } |
            ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Time = $_.LastWriteTime; Zip = $null } }

        $candidates += Get-ChildItem -Path $syncRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ Path = $null; Time = $_.LastWriteTime; Zip = $_.FullName } }

        $newest = $candidates | Sort-Object Time -Descending | Select-Object -First 1

        if ($null -eq $newest) {
            # An empty folder means two very different things. With a server
            # configured it is a failure worth flagging - the export should
            # have produced something. Without one, the folder is simply a
            # drop point nobody has used yet, and warning about it on every
            # start trains people to ignore the warnings that do matter.
            if ($serverSet) {
                Write-Warn "No export found in $syncRoot."
                Write-Warn 'Check the schedule: src\export\Register-SyncTask.ps1 -Status'
            }
            else {
                Write-Host "    No export in $syncRoot yet - keeping the existing dataset."
            }
        }
        else {
            $exportDir = $newest.Path

            if ($newest.Zip) {
                Write-Step "Extracting archive: $(Split-Path $newest.Zip -Leaf)"
                $exportDir = Join-Path $dataRoot ('import-' + [IO.Path]::GetFileNameWithoutExtension($newest.Zip))
                if (Test-Path $exportDir) { Remove-Item $exportDir -Recurse -Force }
                Expand-Archive -Path $newest.Zip -DestinationPath $exportDir -Force
            }

            # Warn loudly about a stale dataset. Believing an old snapshot is
            # current is worse during an outage than having no data at all.
            $manifestPath = Join-Path $exportDir 'manifest.json'
            if (Test-Path $manifestPath) {
                $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
                $exportTime = [datetime]::Parse($manifest.exportTime)
                $ageDays = [math]::Round(((Get-Date) - $exportTime).TotalDays, 1)

                Write-Host "    Dataset date : $($exportTime.ToString('yyyy-MM-dd HH:mm')) ($ageDays days old)"

                if ($ageDays -gt $config.import.maxAgeWarningDays) {
                    Write-Host ''
                    Write-Host '  ####################################################' -ForegroundColor Red
                    Write-Host "  #  WARNING: this dataset is $ageDays days old." -ForegroundColor Red
                    Write-Host '  #  The synchronisation may no longer be running.' -ForegroundColor Red
                    Write-Host '  ####################################################' -ForegroundColor Red
                    Write-Host ''
                }

                if ($manifest.status -ne 'complete') {
                    Write-Warn "Export is incomplete (status: $($manifest.status)). Some data is missing."
                }
            }

            Write-Step 'Loading dataset (the previous one is replaced)'

            Push-Location $netboxDir
            try {
                & $pythonExe (Join-Path $RootDir 'src\import\Import-NetBoxExport.py') $exportDir
                $importExit = $LASTEXITCODE
            }
            finally { Pop-Location }

            if ($importExit -eq 0) {
                Write-Ok 'Dataset loaded'
            }
            elseif ($importExit -eq 4) {
                # Not a failure: the import declined an export holding far less
                # than what is already here. The reasoning is printed above.
                Write-Warn 'Import declined - the export looked implausibly small.'
                Write-Warn 'The previous dataset is unchanged and still in use.'
            }
            else {
                Write-Warn "Import failed (code $importExit). Showing the previous dataset."
            }
        }
    }
}

# --- 3. Ensure the login account -------------------------------------------

Write-Step 'Checking login account'

$secretsDir = Join-Path $dataRoot 'secrets'
if (-not (Test-Path $secretsDir)) { New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null }

# Resolves a password: the configuration wins, then a previously generated one,
# and failing both a fresh random value. Whatever is used ends up in the secrets
# file so it can be looked up later.
function Resolve-Password {
    param([string]$Configured, [string]$File)

    if (-not [string]::IsNullOrWhiteSpace($Configured)) { $value = $Configured }
    elseif (Test-Path $File) { $value = (Get-Content $File -Raw).Trim() }
    else { $value = New-RandomSecret -Length 16 }

    Set-Content -Path $File -Value $value -Encoding ascii -NoNewline
    return $value
}

$mode = $config.webUser.mode
if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'readonly' }
$mode = $mode.ToLowerInvariant()

if (@('readonly', 'superuser', 'both') -notcontains $mode) {
    Write-Warn "Unknown mode '$mode' in the configuration; falling back to 'readonly'."
    $mode = 'readonly'
}

$username     = $config.webUser.username
$passwordFile = Join-Path $secretsDir 'admin-password.txt'
$password     = Resolve-Password -Configured $config.webUser.password -File $passwordFile

$roUsername     = $config.webUser.readOnlyUsername
$roPasswordFile = Join-Path $secretsDir 'viewer-password.txt'
$roPassword     = $null

if ($mode -eq 'both') {
    $roPassword = Resolve-Password -Configured $config.webUser.readOnlyPassword -File $roPasswordFile
}

# Creating or updating the accounts is idempotent, so a changed password or a
# changed mode takes effect on the next start without any manual step.
$ensureScript = Join-Path $RootDir 'src\launcher\ensure_user.py'

Push-Location $netboxDir
try {
    $env:NETBOXLOCAL_MODE     = $mode
    $env:NETBOXLOCAL_USERNAME = $username
    $env:NETBOXLOCAL_PASSWORD = $password

    if ($mode -eq 'both') {
        $env:NETBOXLOCAL_RO_USERNAME = $roUsername
        $env:NETBOXLOCAL_RO_PASSWORD = $roPassword
    }

    & $pythonExe $ensureScript
    if ($LASTEXITCODE -ne 0) { Write-Warn 'Could not set up the login accounts.' }
}
finally {
    Pop-Location
    Remove-Item Env:\NETBOXLOCAL_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:\NETBOXLOCAL_RO_PASSWORD -ErrorAction SilentlyContinue
}

# --- 4. Open ---------------------------------------------------------------

$url = "http://127.0.0.1:$webPort/"

Write-Host ''
Write-Host '  Ready.' -ForegroundColor Green
Write-Host "  Address  : $url"
Write-Host ''

if ($mode -eq 'both') {
    Write-Host '  Full access account' -ForegroundColor White
    Write-Host "    Username : $username"
    Write-Host "    Password : $password"
    Write-Host ''
    Write-Host '  Read-only account' -ForegroundColor White
    Write-Host "    Username : $roUsername"
    Write-Host "    Password : $roPassword"
}
else {
    if ($mode -eq 'readonly') { $access = 'read-only' } else { $access = 'full access' }
    Write-Host "  Username : $username"
    Write-Host "  Password : $password"
    Write-Host "  Access   : $access" -ForegroundColor Yellow
}

Write-Host ''
Write-Host "  Passwords are also stored in $secretsDir" -ForegroundColor DarkGray
Write-Host "  To change them or switch the access mode, edit:" -ForegroundColor DarkGray
Write-Host "    $ConfigPath" -ForegroundColor DarkGray
Write-Host '  and start NetBox Local again.' -ForegroundColor DarkGray
Write-Host ''

if ($config.browser.openOnStart) {
    Start-Process $url | Out-Null
}
