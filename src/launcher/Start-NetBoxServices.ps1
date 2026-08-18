#Requires -Version 5.1
<#
.SYNOPSIS
  Initialises and runs the bundled NetBoxLocal stack (PostgreSQL, Garnet, NetBox).

.DESCRIPTION
  Brings up the three processes that make up a NetBoxLocal instance:

    postgres.exe      bundled PostgreSQL, cluster under the user profile
    GarnetServer.exe  Redis-protocol server (NetBox requires REDIS to start)
    waitress-serve    WSGI server for the NetBox Django application

  Everything lives under the user profile and binds to loopback only, so no
  administrator rights and no firewall exceptions are needed.

  On first run the script initialises the PostgreSQL cluster, generates a
  random database password and a Django SECRET_KEY, writes configuration.py
  and applies migrations. Subsequent runs reuse that state.

.PARAMETER DataRoot
  Where mutable state lives. Defaults to %LOCALAPPDATA%\NetBoxLocal.

.PARAMETER BundleRoot
  Where the immutable bundle lives. Defaults to dist\bundle relative to the repo.

.PARAMETER Init
  Discard any existing cluster and re-initialise from scratch.

.PARAMETER NoServe
  Start the backing services and apply migrations, but do not start the web
  server. Used by the Phase 0 verification run.

.PARAMETER Stop
  Stop a running NetBoxLocal stack and exit. Use this when a previous run was
  terminated without releasing its ports.
#>
[CmdletBinding()]
param(
    [string]$DataRoot   = (Join-Path $env:LOCALAPPDATA 'NetBoxLocal'),
    [string]$BundleRoot,
    [switch]$Init,
    [switch]$NoServe,
    [switch]$Stop
)

$ErrorActionPreference = 'Stop'

# When launched by double-click or "Run with PowerShell" the console closes the
# instant the script ends, taking any error message with it. Keeping the window
# open on failure is the difference between a usable error and a red flash.
$script:IsInteractiveConsole = -not [Environment]::UserInteractive -eq $false -and $Host.Name -eq 'ConsoleHost'

if (-not $BundleRoot) {
    $repoRoot   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $BundleRoot = Join-Path $repoRoot 'dist\bundle'
}

$PgPort     = 55432
$GarnetPort = 56379
$WebPort    = 8001

$PgBin      = Join-Path $BundleRoot 'pgsql\bin'
$PgData     = Join-Path $DataRoot   'pgdata'
$GarnetDir  = Join-Path $BundleRoot 'garnet'
$LogDir     = Join-Path $DataRoot   'logs'
$SecretsDir = Join-Path $DataRoot   'secrets'
$NetboxDir  = Join-Path $BundleRoot 'netbox\netbox'
$PythonExe  = Join-Path $BundleRoot 'python\python.exe'

$DbName = 'netbox'
$DbUser = 'netbox'

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    WARN $m" -ForegroundColor Yellow }

function New-RandomSecret {
    param([int]$Length = 50)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $sb = New-Object Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
    return $sb.ToString()
}

function Get-OrCreateSecret {
    param([string]$Name, [int]$Length = 50)
    $path = Join-Path $SecretsDir "$Name.txt"
    if (Test-Path $path) { return (Get-Content $path -Raw).Trim() }
    $value = New-RandomSecret -Length $Length
    Set-Content -Path $path -Value $value -Encoding ascii -NoNewline
    return $value
}

function Test-PortFree {
    param([int]$Port)
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    try { $listener.Start(); $listener.Stop(); return $true }
    catch { return $false }
}

function Assert-PortAvailable {
    param([int]$Port, [string]$What)
    if (Test-PortFree -Port $Port) { return }
    throw @"
Port $Port is already in use, so $What cannot start.

NetBoxLocal refuses to continue: if it connected to whatever already owns that
port it would silently read from a foreign database.

A NetBoxLocal instance that is still running is the usual cause. Stop it with:

    .\Start-NetBoxServices.ps1 -Stop

then start again.
"@
}

function Wait-ForPort {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 45,
        [string]$What = 'service',
        [System.Diagnostics.Process]$Process
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        # A dead process will never open the port, and waiting out the full
        # timeout would hide the real error sitting in its log file.
        if ($Process -and $Process.HasExited) {
            throw "$What exited with code $($Process.ExitCode) before opening port $Port. Check the logs in $LogDir."
        }
        $client = New-Object Net.Sockets.TcpClient
        try {
            $client.Connect('127.0.0.1', $Port)
            if ($client.Connected) { $client.Close(); return $true }
        }
        catch { Start-Sleep -Milliseconds 400 }
        finally { $client.Dispose() }
    }
    throw "$What did not become reachable on port $Port within $TimeoutSeconds seconds"
}

function Invoke-Psql {
    param([string]$Sql, [string]$Database = 'postgres')
    $env:PGPASSWORD = $script:DbPassword
    $out = & (Join-Path $PgBin 'psql.exe') -h 127.0.0.1 -p $PgPort -U $DbUser -d $Database -tAc $Sql
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $out" }
    return $out
}

# ---------------------------------------------------------------------------

function Stop-NetBoxLocalStack {
    $stopped = 0

    # Ask PostgreSQL to shut down properly first. Killing it leaves the cluster
    # dirty, which forces a WAL replay on the next start - avoidable downtime on
    # a machine that is only ever used during an outage.
    if (Test-Path (Join-Path $PgBin 'pg_ctl.exe')) {
        if (Get-Process -Name 'postgres' -ErrorAction SilentlyContinue) {
            try {
                $stop = Start-Process -FilePath (Join-Path $PgBin 'pg_ctl.exe') `
                    -ArgumentList @('-D', $PgData, '-m', 'fast', '-w', '-t', '60', 'stop') `
                    -WindowStyle Hidden -Wait -PassThru
                if ($stop.ExitCode -eq 0) {
                    Write-Ok 'PostgreSQL shut down cleanly'
                    $stopped++
                }
            }
            catch { }
        }
    }

    # Whatever is still standing gets terminated.
    foreach ($name in @('postgres', 'GarnetServer')) {
        foreach ($p in (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try { $p.Kill(); $stopped++ } catch { }
        }
    }
    # waitress runs inside python.exe. Identifying it by executable path alone
    # is not enough: stopping from the source checkout would then leave a web
    # server started from an installed copy running. It keeps answering
    # requests and, having lost Garnet, reports a Redis connection error
    # instead of the browser simply reporting that nothing is listening.
    #
    # Whoever holds the web port is the web server, wherever it was started
    # from. The executable path is only a fallback.
    $bundlePython = Join-Path $BundleRoot 'python\python.exe'
    $webOwners = @()

    try {
        $webOwners = @(
            Get-NetTCPConnection -LocalPort $WebPort -State Listen -ErrorAction Stop |
                Select-Object -ExpandProperty OwningProcess -Unique
        )
    }
    catch {
        # Get-NetTCPConnection is missing on some builds; netstat always exists.
        $webOwners = @(
            netstat -ano -p TCP |
                Select-String -Pattern 'LISTENING' |
                Select-String -Pattern ":$WebPort\s" |
                ForEach-Object { ($_ -split '\s+')[-1] } |
                Sort-Object -Unique
        )
    }

    foreach ($processId in $webOwners) {
        try {
            $p = Get-Process -Id $processId -ErrorAction Stop
            $p.Kill()
            $stopped++
            Write-Ok "Web server stopped (pid $processId)"
        }
        catch { }
    }

    foreach ($p in (Get-Process -Name 'python' -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path -eq $bundlePython) { $p.Kill(); $stopped++ }
        }
        catch { }
    }

    return $stopped
}

if ($Stop) {
    Write-Step 'Stopping NetBoxLocal'
    $n = Stop-NetBoxLocalStack
    Start-Sleep -Seconds 2
    Write-Ok "$n process(es) stopped"
    return
}

Write-Step 'NetBoxLocal stack'
Write-Host "    bundle : $BundleRoot"
Write-Host "    data   : $DataRoot"

foreach ($d in @($DataRoot, $LogDir, $SecretsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$script:DbPassword = Get-OrCreateSecret -Name 'db-password' -Length 40
$secretKey         = Get-OrCreateSecret -Name 'django-secret-key' -Length 50
$tokenPepper       = Get-OrCreateSecret -Name 'api-token-pepper' -Length 50

# --- PostgreSQL cluster ---------------------------------------------------

if ($Init -and (Test-Path $PgData)) {
    Write-Warn 'Removing existing cluster (-Init)'
    Remove-Item $PgData -Recurse -Force
}

if (-not (Test-Path $PgData)) {
    Write-Step 'PostgreSQL: initialise cluster'

    $pwFile = Join-Path $SecretsDir 'initdb-pw.txt'
    Set-Content -Path $pwFile -Value $script:DbPassword -Encoding ascii -NoNewline

    # scram-sha-256 for host connections; the cluster only ever listens on
    # loopback, but a password is still required so nothing on the machine can
    # connect anonymously.
    & (Join-Path $PgBin 'initdb.exe') `
        --pgdata=$PgData `
        --username=$DbUser `
        --pwfile=$pwFile `
        --encoding=UTF8 `
        --locale=C `
        --auth-host=scram-sha-256 `
        --auth-local=scram-sha-256 | Out-Null

    Remove-Item $pwFile -Force
    if ($LASTEXITCODE -ne 0) { throw "initdb failed with exit code $LASTEXITCODE" }
    Write-Ok "cluster created at $PgData"
}
else {
    Write-Ok 'cluster present'
}

Write-Step 'PostgreSQL: start'

# postgres.exe is started directly rather than through pg_ctl. On Windows the
# server inherits pg_ctl's stdio handles, so `pg_ctl -w start` only returns once
# every handle is closed - which never happens while the server runs. Starting
# the server ourselves avoids that and yields a PID we can shut down cleanly.
Assert-PortAvailable -Port $PgPort -What 'PostgreSQL'
$pgProc = Start-Process -FilePath (Join-Path $PgBin 'postgres.exe') `
    -ArgumentList @('-D', $PgData, '-p', "$PgPort", '-c', 'listen_addresses=127.0.0.1') `
    -RedirectStandardOutput (Join-Path $LogDir 'postgres.out.log') `
    -RedirectStandardError  (Join-Path $LogDir 'postgres.err.log') `
    -WindowStyle Hidden -PassThru
Wait-ForPort -Port $PgPort -What 'PostgreSQL' -Process $pgProc | Out-Null

# An open TCP port does not mean PostgreSQL accepts queries. After an unclean
# shutdown - a flat battery on a notebook, say - the server listens while it
# replays WAL and rejects every connection with "the database system is not yet
# accepting connections". Recovery can take a while on a large database, so wait
# for readiness rather than for the socket.
$pgIsReady = Join-Path $PgBin 'pg_isready.exe'
$readyDeadline = (Get-Date).AddSeconds(300)
$announcedRecovery = $false
while ($true) {
    & $pgIsReady -h 127.0.0.1 -p $PgPort -q
    if ($LASTEXITCODE -eq 0) { break }
    if ($pgProc.HasExited) {
        throw "PostgreSQL exited with code $($pgProc.ExitCode) during startup. See $LogDir\postgres.err.log."
    }
    if ((Get-Date) -gt $readyDeadline) {
        throw "PostgreSQL did not become ready within 300 seconds. See $LogDir\postgres.err.log."
    }
    if (-not $announcedRecovery) {
        Write-Warn 'Database is recovering from an unclean shutdown; waiting for it to finish.'
        $announcedRecovery = $true
    }
    Start-Sleep -Milliseconds 500
}

Write-Ok "ready on 127.0.0.1:$PgPort (pid $($pgProc.Id))"

$dbExists = Invoke-Psql -Sql "SELECT 1 FROM pg_database WHERE datname = '$DbName'"
if (-not $dbExists) {
    Write-Step 'PostgreSQL: create database'
    Invoke-Psql -Sql "CREATE DATABASE $DbName OWNER $DbUser" | Out-Null
    Write-Ok "database '$DbName' created"
}
else {
    Write-Ok "database '$DbName' present"
}

# --- Garnet ---------------------------------------------------------------

Write-Step 'Garnet: start'
$garnetExe = Join-Path $GarnetDir 'GarnetServer.exe'
if (-not (Test-Path $garnetExe)) { throw "GarnetServer.exe not found at $garnetExe" }

# Garnet's published binaries are framework-dependent, so the apphost looks for
# a shared .NET runtime. Point it at the one shipped inside the bundle rather
# than at whatever the machine happens to have installed - emergency notebooks
# have nothing installed at all.
$dotnetRoot = Join-Path $BundleRoot 'dotnet'
if (-not (Test-Path (Join-Path $dotnetRoot 'dotnet.exe'))) {
    throw "Bundled .NET runtime not found at $dotnetRoot. Run build\fetch-components.ps1 and build\build-bundle.ps1."
}
$env:DOTNET_ROOT = $dotnetRoot
$env:DOTNET_MULTILEVEL_LOOKUP = '0'
Write-Ok "using bundled .NET runtime at $dotnetRoot"

Assert-PortAvailable -Port $GarnetPort -What 'Garnet'
$garnetProc = Start-Process -FilePath $garnetExe `
    -ArgumentList @('--bind', '127.0.0.1', '--port', "$GarnetPort") `
    -WorkingDirectory $GarnetDir `
    -RedirectStandardOutput (Join-Path $LogDir 'garnet.log') `
    -RedirectStandardError  (Join-Path $LogDir 'garnet.err.log') `
    -WindowStyle Hidden -PassThru
Wait-ForPort -Port $GarnetPort -What 'Garnet' -Process $garnetProc | Out-Null
Write-Ok "listening on 127.0.0.1:$GarnetPort (pid $($garnetProc.Id))"

# --- NetBox configuration -------------------------------------------------

Write-Step 'NetBox: write configuration'

$configPath = Join-Path $NetboxDir 'netbox\configuration.py'

# Both Redis roles share database 0. NetBox's example config puts caching on
# database 1, but Garnet exposes a single logical database by default and the
# two key namespaces do not collide.
$config = @"
# Generated by Start-NetBoxServices.ps1 - do not edit by hand.
ALLOWED_HOSTS = ['127.0.0.1', 'localhost']

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': '$DbName',
        'USER': '$DbUser',
        'PASSWORD': '$($script:DbPassword)',
        'HOST': '127.0.0.1',
        'PORT': '$PgPort',
        'CONN_MAX_AGE': 300,
    }
}

REDIS = {
    'tasks': {
        'HOST': '127.0.0.1',
        'PORT': $GarnetPort,
        'USERNAME': '',
        'PASSWORD': '',
        'DATABASE': 0,
        'SSL': False,
    },
    'caching': {
        'HOST': '127.0.0.1',
        'PORT': $GarnetPort,
        'USERNAME': '',
        'PASSWORD': '',
        'DATABASE': 0,
        'SSL': False,
    },
}

SECRET_KEY = '$secretKey'

# Without this NetBox prints a warning on every command it runs. Nothing here
# issues API tokens - the accounts exist for the web interface only - but a
# warning shown on every start is a warning people stop reading, and then miss
# the one that matters.
#
# The shape is fixed by utilities/security.py: a dict keyed by an integer
# between 0 and 32767, whose value is a string of at least 50 characters.
API_TOKEN_PEPPERS = {0: '$tokenPepper'}

DEBUG = False
LOGIN_REQUIRED = True

# This instance is a read-only replica of the production NetBox. Background
# jobs never run here, so housekeeping and changelog retention are pointless.
CHANGELOG_RETENTION = 0
JOB_RETENTION = 0
"@

Set-Content -Path $configPath -Value $config -Encoding utf8
Write-Ok "configuration.py written ($($config.Length) bytes)"

# --- Migrations -----------------------------------------------------------

Write-Step 'NetBox: apply migrations'
Push-Location $NetboxDir
try {
    & $PythonExe 'manage.py' 'migrate' '--no-input'
    if ($LASTEXITCODE -ne 0) { throw "migrate failed with exit code $LASTEXITCODE" }
    Write-Ok 'migrations applied'

    & $PythonExe 'manage.py' 'collectstatic' '--no-input' | Select-Object -Last 1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "collectstatic failed with exit code $LASTEXITCODE" }
    Write-Ok 'static files collected'
}
finally { Pop-Location }

# --- Web server -----------------------------------------------------------

if ($NoServe) {
    Write-Ok 'Backing services running; web server skipped (-NoServe)'
    Write-Host "    PostgreSQL : port $PgPort (pid $($pgProc.Id))"
    Write-Host "    Garnet     : port $GarnetPort (pid $($garnetProc.Id))"
    return
}

Assert-PortAvailable -Port $WebPort -What 'the web server'

Write-Step "NetBox: serve on http://127.0.0.1:$WebPort"
Write-Host ''
Write-Host "    Open http://127.0.0.1:$WebPort in a browser." -ForegroundColor White
Write-Host '    Press Ctrl+C here to shut everything down.' -ForegroundColor White
Write-Host ''

Push-Location $NetboxDir
try {
    # netboxlocal_wsgi wraps NetBox in WhiteNoise so static files are served
    # without an nginx in front. Serving netbox.wsgi directly yields NetBox's
    # "Static Media Failure" page, because Django only serves static files
    # itself when DEBUG is on.
    & $PythonExe '-m' 'waitress' `
        "--listen=127.0.0.1:$WebPort" `
        '--threads=4' `
        'netboxlocal_wsgi:application'
}
finally {
    Pop-Location
    Write-Step 'Shutting down'
    if ($garnetProc -and -not $garnetProc.HasExited) { Stop-Process -Id $garnetProc.Id -Force }
    # pg_ctl stop is safe to pipe: it exits on its own rather than holding the
    # server's handles.
    Start-Process -FilePath (Join-Path $PgBin 'pg_ctl.exe') `
        -ArgumentList @('-D', $PgData, '-m', 'fast', 'stop') `
        -WindowStyle Hidden -Wait
    Write-Ok 'stopped'
}
