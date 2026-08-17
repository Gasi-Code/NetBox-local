@echo off
REM Double-click entry point for importing a NetBox export.
REM
REM Usage:
REM   Import-NetBoxExport.cmd                      pick the newest export found
REM   Import-NetBoxExport.cmd "D:\path\to\Monday"  import a specific one
REM
REM Drag-and-drop works too: dropping an export folder onto this file passes it
REM as the first argument.

setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "BUNDLE=%~dp0..\..\dist\bundle"
set "NETBOXDIR=%BUNDLE%\netbox\netbox"
set "PYTHON=%BUNDLE%\python\python.exe"
set "DOTNET_ROOT=%BUNDLE%\dotnet"

if not exist "%PYTHON%" (
    echo The NetBox Local bundle was not found at:
    echo   %BUNDLE%
    echo Run build\fetch-components.ps1 and build\build-bundle.ps1 first.
    echo.
    pause
    exit /b 1
)

set "EXPORTDIR=%~1"

REM Without an argument, take the most recently written export directory.
if "%EXPORTDIR%"=="" (
    set "SYNCROOT=C:\Sync-Daten\NetBoxLocal"
    if not exist "!SYNCROOT!" (
        echo No export directory given and !SYNCROOT! does not exist.
        echo.
        echo Usage:
        echo   %~nx0 "D:\path\to\export"
        echo.
        echo Alternatively drag the folder containing manifest.json onto this file.
        echo.
        pause
        exit /b 1
    )
    for /f "delims=" %%D in ('dir /b /ad /o-d "!SYNCROOT!" 2^>nul') do (
        if "!EXPORTDIR!"=="" set "EXPORTDIR=!SYNCROOT!\%%D"
    )
)

if "%EXPORTDIR%"=="" (
    echo No extracted export found in C:\Sync-Daten\NetBoxLocal.
    echo Extract the desired weekday archive first.
    echo.
    pause
    exit /b 1
)

echo Importing from: %EXPORTDIR%
echo.
echo Note: the entire local dataset will be replaced.
echo.

REM The import needs PostgreSQL and Garnet running.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$c = New-Object Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1', 55432); exit 0 } catch { exit 1 } finally { $c.Dispose() }"

if errorlevel 1 (
    echo ERROR: the local database is not reachable.
    echo Start NetBox Local first:
    echo   ..\launcher\NetBoxLocal.cmd
    echo.
    pause
    exit /b 1
)

pushd "%NETBOXDIR%"
"%PYTHON%" "%~dp0Import-NetBoxExport.py" "%EXPORTDIR%"
set "EXITCODE=%ERRORLEVEL%"
popd

echo.
if "%EXITCODE%"=="0" (
    echo Import complete. NetBox Local now shows the new dataset.
) else (
    echo Import failed ^(Code %EXITCODE%^). Read the message above.
)
echo.
pause
endlocal
