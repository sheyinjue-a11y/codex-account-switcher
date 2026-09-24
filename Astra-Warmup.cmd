@echo off
setlocal
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0tools\chatgpt-account-switch\Configure-AstraWarmup.ps1"
if errorlevel 1 pause
