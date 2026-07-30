@echo off
setlocal
title NVIDIA App OCuLink Update Bridge Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Status.ps1"
set "bridge_exit=%ERRORLEVEL%"
echo.
if "%bridge_exit%"=="0" (
  echo Status check completed.
) else (
  echo The bridge needs attention. Run Setup.cmd to repair it.
)
echo Press any key to close.
pause >nul
exit /b %bridge_exit%

