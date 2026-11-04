@echo off
setlocal
cd /d "%~dp0"
title K552-M Studio 0.4

set "PS32=%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS32%" (
  echo PowerShell 32-bit nao encontrado.
  echo.
  pause
  exit /b 1
)

"%PS32%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0K552M-Studio.ps1"
if errorlevel 1 (
  echo.
  echo O programa terminou com erro.
  echo Consulte K552M-MusicPalette.log.
  echo.
  pause
)
