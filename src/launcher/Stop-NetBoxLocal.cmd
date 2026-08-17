@echo off
REM Double-click entry point for shutting NetBoxLocal down.
REM
REM Needed when a previous run was closed without releasing its ports - closing
REM the console window instead of pressing Ctrl+C leaves PostgreSQL and Garnet
REM running, and the next start then refuses to continue.

setlocal
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-NetBoxServices.ps1" -Stop
set EXITCODE=%ERRORLEVEL%

echo.
if not "%EXITCODE%"=="0" (
    echo Shutdown reported code %EXITCODE%.
)
pause
endlocal
