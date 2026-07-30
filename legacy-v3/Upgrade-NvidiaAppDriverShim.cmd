@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Upgrade-NvidiaAppDriverShim.ps1"
if errorlevel 1 (
  echo.
  echo Upgrade did not complete. Press any key to close.
  pause >nul
  exit /b 1
)
echo.
echo Upgrade completed. Press any key to close.
pause >nul
