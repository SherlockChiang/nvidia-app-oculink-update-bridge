@echo off
setlocal DisableDelayedExpansion
title NVIDIA App OCuLink Update Bridge Status
set "bridge_powershell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%bridge_powershell%" (
  echo Required System32 Windows PowerShell executable was not found.
  exit /b 3
)
set "bridge_script=%~dp0Status.ps1"
if not exist "%bridge_script%" set "bridge_script=%~dp0..\Status.ps1"
if not exist "%bridge_script%" (
  echo Required installer script Status.ps1 was not found.
  echo Press any key to close.
  pause >nul
  exit /b 2
)
"%bridge_powershell%" -NoProfile -ExecutionPolicy Bypass -File "%bridge_script%"
set "bridge_exit=%ERRORLEVEL%"
echo.
if "%bridge_exit%"=="0" (
  echo Status check completed.
) else (
  echo The bridge needs attention. Run Setup.cmd in this folder to repair it.
)
echo Press any key to close.
pause >nul
exit /b %bridge_exit%
