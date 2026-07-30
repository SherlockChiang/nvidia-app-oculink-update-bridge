@echo off
setlocal
title NVIDIA App OCuLink Update Bridge Uninstaller
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-NvidiaAppOculinkShim.ps1"
set "shim_exit=%ERRORLEVEL%"
if not "%shim_exit%"=="0" (
  echo.
  echo Uninstallation did not complete. Press any key to close.
  pause >nul
)
exit /b %shim_exit%
