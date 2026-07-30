@echo off
setlocal
title NVIDIA App OCuLink Update Bridge Migration
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Migrate-V3ToV4.ps1"
set "bridge_exit=%ERRORLEVEL%"
if not "%bridge_exit%"=="0" (
  echo.
  echo Migration did not complete. The v3 helper should have been restored.
  echo Press any key to close.
  pause >nul
)
exit /b %bridge_exit%

