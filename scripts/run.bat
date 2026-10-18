@echo off
rem ==============================================================================
rem Script Name:   run.bat
rem Description:   Windows batch launcher for NetMonitor
rem Usage:         run.bat [options] [arguments]
rem ==============================================================================
setlocal EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%..\"

cd /d "%ROOT_DIR%"

where powershell >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo Error: PowerShell is required to run the launcher on Windows. >&2
    exit /b 1
)

if exist "%SCRIPT_DIR%run.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%run.ps1" %*
    exit /b !ERRORLEVEL!
) else (
    echo Error: run.ps1 not found in "%SCRIPT_DIR%". >&2
    exit /b 1
)
