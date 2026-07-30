@echo off
setlocal
title NVIDIA App OCuLink Update Bridge Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1"
set "bridge_exit=%ERRORLEVEL%"
if not "%bridge_exit%"=="0" (
  echo.
  echo Setup did not complete. Press any key to close.
  pause >nul
)
exit /b %bridge_exit%

