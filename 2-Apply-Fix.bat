@echo off
setlocal
cd /d "%~dp0"
title Samsung Odyssey G7 - HDMI 2.1 Blackout Fix (Administrator)

:: Self-elevate to Administrator privileges if running as standard user
fltmc >nul 2>&1 || (
    echo Requesting Administrator privileges to apply EDID_OVERRIDE and reload GPU...
    powershell.exe -NoProfile -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

echo ==============================================================================
echo  Samsung Odyssey G7 (S32DG700 / G70D) HDMI 2.1 Blackout Fix
echo  Privileges: Administrator
echo ==============================================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts\Fix-HDMI21-Blackout.ps1"

echo.
echo ==============================================================================
echo  Execution finished. Press any key to close this window...
echo ==============================================================================
pause >nul
