#Requires -Version 5.1
<#
.SYNOPSIS
  Assembles the staged components into a runnable NetBoxLocal bundle.

.DESCRIPTION
  Turns dist/staging into dist/bundle by:
    1. enabling site-packages in the embeddable Python and bootstrapping pip
    2. patching NetBox's requirements.txt for Windows
    3. installing all Python dependencies into the embedded interpreter
    4. selecting one Garnet runtime flavour and discarding the rest
    5. trimming the PostgreSQL distribution down to what is actually shipped
    6. placing the NetBox source tree

  The result is self-contained: no system Python, no PostgreSQL install, no
  .NET runtime, no administrator rights.

.PARAMETER GarnetRuntime
  Which Garnet runtime directory to ship. Defaults to net10.0 (longer support
  window than net8.0, which reaches end of life in Nov 2026).

.PARAMETER SkipPip
  Skip dependency installation. Useful when iterating on the trimming steps.
#>
[CmdletBinding()]
param(
    [string]$GarnetRuntime = 'net10.0',
    [switch]$SkipPip
)

$ErrorActionPreference = 'Stop'

$BuildDir     = $PSScriptRoot
$RootDir      = Split-Path $BuildDir -Parent
$StagingDir   = Join-Path $RootDir 'dist\staging'
$BundleDir    = Join-Path $RootDir 'dist\bundle'
$ManifestPath = Join-Path $BuildDir 'components.json'

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    OK   $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    WARN $m" -ForegroundColor Yellow }

function Get-DirSizeMB {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $sum = (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [math]::Round($sum / 1MB, 1)
}

function Copy-Tree {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path $Source)) { throw "Source not found: $Source" }
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
}

# ---------------------------------------------------------------------------

Write-Step 'NetBoxLocal bundle build'

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

# A running instance holds open handles inside dist\bundle, and Remove-Item then
# fails with "the file is in use". Shutting it down here is friendlier than
# aborting the build halfway through.
$stopScript = Join-Path $RootDir 'src\launcher\Start-NetBoxServices.ps1'
if ((Test-Path $stopScript) -and (Get-Process -Name 'postgres', 'GarnetServer' -ErrorAction SilentlyContinue)) {
    Write-Step 'Stopping the running instance'
    & $stopScript -Stop | Out-Null
    Start-Sleep -Seconds 3
}

foreach ($p in (Get-Process -Name 'python' -ErrorAction SilentlyContinue)) {
    try {
        if ($p.Path -eq (Join-Path $BundleDir 'python\python.exe')) { $p.Kill() }
    }
    catch { }
}

if (Test-Path $BundleDir) { Remove-Item $BundleDir -Recurse -Force }
New-Item -ItemType Directory -Path $BundleDir -Force | Out-Null

# --- 1. Python ------------------------------------------------------------

Write-Step 'Python: enable site-packages and bootstrap pip'

$pythonSrc = Join-Path $StagingDir 'python'
$pythonDst = Join-Path $BundleDir  'python'
Copy-Tree -Source $pythonSrc -Destination $pythonDst

# The embeddable distribution ships with `import site` commented out and no
# site-packages entry, which disables pip entirely. Both are required.
$pth = Get-ChildItem -Path $pythonDst -Filter 'python*._pth' | Select-Object -First 1
if ($null -eq $pth) { throw 'No python*._pth found in embeddable distribution' }

# A ._pth file puts the interpreter into isolated mode: sys.path is built
# solely from this file, and both PYTHONPATH and the script's own directory are
# ignored. Django would therefore fail to import the 'netbox' package even when
# invoked from manage.py's directory, so the project root is listed explicitly.
# Paths are resolved relative to the directory holding python.exe.
@(
    $pth.Name.Replace('._pth', '.zip')
    '.'
    'Lib\site-packages'
    '..\netbox\netbox'
    'import site'
) | Set-Content -Path $pth.FullName -Encoding ascii
Write-Ok "patched $($pth.Name)"

$pythonExe = Join-Path $pythonDst 'python.exe'
$getPip    = Join-Path $pythonDst 'get-pip.py'

& $pythonExe $getPip --no-warn-script-location | Select-Object -Last 3 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) { throw "get-pip.py failed with exit code $LASTEXITCODE" }
Remove-Item $getPip -Force
Write-Ok 'pip bootstrapped'

# --- 2. NetBox source + patched requirements ------------------------------

Write-Step 'NetBox: place source tree and patch requirements'

$netboxRoot = Get-ChildItem -Path (Join-Path $StagingDir 'netbox') -Directory |
              Where-Object { $_.Name -like 'netbox-*' } |
              Select-Object -First 1
if ($null -eq $netboxRoot) { throw 'NetBox source directory not found in staging' }

$netboxDst = Join-Path $BundleDir 'netbox'
Copy-Tree -Source $netboxRoot.FullName -Destination $netboxDst

# The WSGI wrapper has to sit next to manage.py so it is importable through the
# path entry added to python*._pth. Without it waitress serves NetBox directly
# and every page renders unstyled behind a "Static Media Failure" notice.
Copy-Item `
    -Path (Join-Path $RootDir 'src\launcher\netboxlocal_wsgi.py') `
    -Destination (Join-Path $netboxDst 'netbox\netboxlocal_wsgi.py') `
    -Force
Write-Ok 'netboxlocal_wsgi.py placed'

$reqPath  = Join-Path $netboxDst 'requirements.txt'
$original = Get-Content $reqPath
$patched  = @()
$applied  = @()

foreach ($line in $original) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { $patched += $line; continue }

    $rule = $manifest.requirementPatches | Where-Object { $trimmed.StartsWith($_.match) } | Select-Object -First 1

    if ($null -eq $rule) {
        $patched += $line
    }
    elseif ($rule.action -eq 'remove') {
        $applied += "removed  $trimmed"
    }
    elseif ($rule.action -eq 'replace') {
        $new = $trimmed.Replace($rule.match, $rule.with)
        $patched += $new
        $applied += "replaced $trimmed  ->  $new"
    }
}

foreach ($extra in $manifest.extraRequirements) {
    $patched += $extra
    $applied += "added    $extra"
}

$patched | Set-Content -Path $reqPath -Encoding ascii
foreach ($a in $applied) { Write-Ok $a }

if ($applied.Count -lt 3) {
    Write-Warn "Only $($applied.Count) requirement patches applied. Upstream requirements.txt may have changed - verify before shipping."
}

# --- 3. Dependencies ------------------------------------------------------

if ($SkipPip) {
    Write-Warn 'Skipping pip install (-SkipPip)'
}
else {
    # The embeddable distribution's ._pth breaks sys.path inside pip's isolated
    # build environments, so 'setuptools.build_meta' cannot be imported there.
    # Every NetBox dependency ships a wheel except django-pglocks (a 4 kB pure
    # Python sdist), so providing setuptools locally and disabling isolation is
    # sufficient and keeps the install deterministic.
    Write-Step 'Python: provide build backend for sdist-only packages'
    & $pythonExe -m pip install --no-warn-script-location --disable-pip-version-check setuptools wheel
    if ($LASTEXITCODE -ne 0) { throw "installing setuptools/wheel failed with exit code $LASTEXITCODE" }

    Write-Step 'Python: install NetBox dependencies'
    & $pythonExe -m pip install --no-warn-script-location --disable-pip-version-check --no-build-isolation -r $reqPath
    if ($LASTEXITCODE -ne 0) { throw "pip install failed with exit code $LASTEXITCODE" }
    Write-Ok 'dependencies installed'
}

# --- 4. Garnet ------------------------------------------------------------

Write-Step "Garnet: select runtime $GarnetRuntime"

$garnetSrc = Join-Path $StagingDir "garnet\$GarnetRuntime"
if (-not (Test-Path $garnetSrc)) {
    $available = (Get-ChildItem -Path (Join-Path $StagingDir 'garnet') -Directory).Name -join ', '
    throw "Garnet runtime '$GarnetRuntime' not found. Available: $available"
}
Copy-Tree -Source $garnetSrc -Destination (Join-Path $BundleDir 'garnet')
Write-Ok "garnet $GarnetRuntime staged ($(Get-DirSizeMB (Join-Path $BundleDir 'garnet')) MB)"

# Garnet ships framework-dependent, so the runtime travels with the bundle.
Write-Step '.NET runtime'
Copy-Tree -Source (Join-Path $StagingDir 'dotnet') -Destination (Join-Path $BundleDir 'dotnet')
Write-Ok "runtime staged ($(Get-DirSizeMB (Join-Path $BundleDir 'dotnet')) MB)"

# --- 5. PostgreSQL --------------------------------------------------------

Write-Step 'PostgreSQL: trim distribution'

$pgSrc = Join-Path $StagingDir 'pgsql\pgsql'
if (-not (Test-Path $pgSrc)) { throw "PostgreSQL not found at $pgSrc" }

$pgDst = Join-Path $BundleDir 'pgsql'
New-Item -ItemType Directory -Path $pgDst -Force | Out-Null

# Only these three directories are needed to run a server and restore a dump.
# 'pgAdmin 4' alone is ~654 MB of the ~829 MB distribution.
$keep = @('bin', 'lib', 'share')
foreach ($dir in $keep) {
    Copy-Tree -Source (Join-Path $pgSrc $dir) -Destination (Join-Path $pgDst $dir)
}

$before = Get-DirSizeMB (Join-Path $StagingDir 'pgsql')
$after  = Get-DirSizeMB $pgDst
Write-Ok "trimmed $before MB -> $after MB (kept: $($keep -join ', '))"

# --- 6. Licences ----------------------------------------------------------

Write-Step 'Licences'

$licDir = Join-Path $BundleDir 'LICENSES'
New-Item -ItemType Directory -Path $licDir -Force | Out-Null
foreach ($c in $manifest.components) {
    "$($c.name) $($c.version) - $($c.license)`n$($c.url)`n" |
        Add-Content -Path (Join-Path $licDir 'COMPONENTS.txt') -Encoding utf8
}
Write-Ok 'COMPONENTS.txt written'

# --- Summary --------------------------------------------------------------

Write-Step 'Bundle summary'
Get-ChildItem -Path $BundleDir -Directory | ForEach-Object {
    Write-Host ("    {0,-12} {1,8} MB" -f $_.Name, (Get-DirSizeMB $_.FullName))
}
Write-Host ("    {0,-12} {1,8} MB" -f 'TOTAL', (Get-DirSizeMB $BundleDir))
Write-Ok "Bundle ready at dist\bundle"
