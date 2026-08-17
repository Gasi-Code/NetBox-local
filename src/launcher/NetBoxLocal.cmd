@echo off
REM Target of the desktop shortcut.
REM
REM Starts the local NetBox instance, imports the most recent export and opens
REM the browser. The console window stays open so the dataset date, the login
REM details and any warning about a stale dataset remain readable.

setlocal
cd /d "%~dp0"
title NetBox Local

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-NetBoxLocal.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
    echo.
    echo NetBox Local failed to start ^(exit code %EXITCODE%^).
    echo Read the message above before closing this window.
    echo.
    pause
    exit /b %EXITCODE%
)

echo You can close this window. NetBox Local keeps running.
echo To shut it down, run Stop-NetBoxLocal.cmd
echo.
pause
endlocal
