@echo off
setlocal DisableDelayedExpansion
title NVIDIA App OCuLink Update Bridge Installer
set "bridge_powershell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%bridge_powershell%" (
  echo Required System32 Windows PowerShell executable was not found.
  exit /b 3
)
set "bridge_script=%~dp0Install-NvidiaAppOculinkShim.ps1"
if not exist "%bridge_script%" set "bridge_script=%~dp0..\Install-NvidiaAppOculinkShim.ps1"
if not exist "%bridge_script%" (
  echo Required installer script Install-NvidiaAppOculinkShim.ps1 was not found.
  echo Press any key to close.
  pause >nul
  exit /b 2
)
"%bridge_powershell%" -NoProfile -ExecutionPolicy Bypass -File "%bridge_script%"
set "shim_exit=%ERRORLEVEL%"
if not "%shim_exit%"=="0" (
  echo.
  echo Installation did not complete. Press any key to close.
  pause >nul
)
exit /b %shim_exit%
