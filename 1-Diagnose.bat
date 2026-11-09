@echo off
setlocal
cd /d "%~dp0"
title Samsung Odyssey G7 - HDMI 2.1 Link Diagnostic

echo ==============================================================================
echo  Samsung Odyssey G7 (S32DG700 / G70D) HDMI 2.1 Link Diagnostic
echo  Mode: Read-Only System Inspection
echo ==============================================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts\Diagnose-MonitorLink.ps1"

echo.
echo Press any key to exit...
pause >nul
