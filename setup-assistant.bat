@echo off
setlocal
title GYM MANAGER Setup Assistant
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup-assistant.ps1"
if errorlevel 1 (
  echo.
  echo Setup did not finish. Read the message above, fix the issue, then run this file again.
)
echo.
pause
