@echo off
setlocal
title NVIDIA App OCuLink Update Bridge Repair
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-NvidiaAppOculinkShim.ps1"
set "bridge_exit=%ERRORLEVEL%"
if not "%bridge_exit%"=="0" (
  echo.
  echo Repair did not complete. Press any key to close.
  pause >nul
)
exit /b %bridge_exit%

