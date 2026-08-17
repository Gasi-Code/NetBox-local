@echo off
REM Target of the desktop shortcut.
REM
REM Starts NetBox Local, then stays open as a small console. Closing the window
REM would leave PostgreSQL and Garnet running, so instead of "press any key"
REM this offers a /stop command that shuts the instance down properly.

setlocal EnableDelayedExpansion
cd /d "%~dp0"
title NetBox Local

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-NetBoxLocal.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
    echo.
    echo NetBox Local failed to start ^(exit code %EXITCODE%^).
    echo Read the message above, then type /exit to close this window.
    echo.
    goto :prompt
)

echo ------------------------------------------------------------------
echo   NetBox Local is running.
echo.
echo     /stop     shut NetBox Local down and close this window
echo     /open     open the web interface in a browser
echo     /status   show which services are running
echo     /exit     close this window, leave NetBox Local running
echo ------------------------------------------------------------------
echo.

:prompt
set "CMDLINE="
set /p "CMDLINE=NetBox Local^> "

if /i "!CMDLINE!"=="/stop" goto :stop
if /i "!CMDLINE!"=="/open" goto :open
if /i "!CMDLINE!"=="/status" goto :status
if /i "!CMDLINE!"=="/exit" goto :leave
if /i "!CMDLINE!"=="/quit" goto :leave
if /i "!CMDLINE!"=="/help" goto :help
if "!CMDLINE!"=="" goto :prompt

echo Unknown command "!CMDLINE!". Type /help for the list.
goto :prompt

:help
echo.
echo     /stop     shut NetBox Local down and close this window
echo     /open     open the web interface in a browser
echo     /status   show which services are running
echo     /exit     close this window, leave NetBox Local running
echo.
goto :prompt

:open
for /f "delims=" %%P in ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$c = Get-Content '%~dp0..\..\config\NetBoxLocal.json' -Raw ^| ConvertFrom-Json; $c.ports.web" 2^>nul') do set "WEBPORT=%%P"
if "!WEBPORT!"=="" set "WEBPORT=8001"
start "" "http://127.0.0.1:!WEBPORT!/"
goto :prompt

:status
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "foreach ($n in 'postgres','GarnetServer','python') { $p = Get-Process $n -ErrorAction SilentlyContinue; if ($p) { Write-Host ('  {0,-14} running ({1})' -f $n, $p.Count) -ForegroundColor Green } else { Write-Host ('  {0,-14} stopped' -f $n) -ForegroundColor Yellow } }"
echo.
goto :prompt

:stop
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-NetBoxServices.ps1" -Stop
echo.
echo NetBox Local has been shut down.
timeout /t 3 /nobreak >nul
goto :leave

:leave
endlocal
exit /b 0
