@echo off
setlocal DisableDelayedExpansion
title NVIDIA App OCuLink Update Bridge Repair
set "bridge_powershell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%bridge_powershell%" (
  echo Required System32 Windows PowerShell executable was not found.
  exit /b 3
)
set "bridge_script=%~dp0Repair-NvidiaAppOculinkShim.ps1"
if not exist "%bridge_script%" set "bridge_script=%~dp0..\Repair-NvidiaAppOculinkShim.ps1"
if not exist "%bridge_script%" (
  echo Required installer script Repair-NvidiaAppOculinkShim.ps1 was not found.
  echo Press any key to close.
  pause >nul
  exit /b 2
)
"%bridge_powershell%" -NoProfile -ExecutionPolicy Bypass -File "%bridge_script%"
set "bridge_exit=%ERRORLEVEL%"
if not "%bridge_exit%"=="0" (
  echo.
  echo Repair did not complete. Press any key to close.
  pause >nul
)
exit /b %bridge_exit%
