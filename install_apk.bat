@echo off
title MuMu Player 12 - High-Speed ADB Installer
setlocal
set APK_PATH=%~1

where pwsh >nul 2>nul
if %ERRORLEVEL% equ 0 (
    set PS_CMD=pwsh.exe
) else (
    set PS_CMD=powershell.exe
)

"%PS_CMD%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_apk.ps1" "%APK_PATH%"
if %ERRORLEVEL% neq 0 (
    echo.
    echo An error occurred during installation.
)
echo.
pause
