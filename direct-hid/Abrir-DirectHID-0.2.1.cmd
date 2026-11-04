@echo off
setlocal
cd /d "%~dp0"
title K552-M Direct HID Lab 0.2.1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0K552M-DirectHID-0.2.1.ps1"
if errorlevel 1 (
  echo.
  echo O programa terminou com erro.
  echo Envie K552M-DirectHID-0.2.1.log.
  echo.
  pause
)
