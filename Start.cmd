@echo off
setlocal
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tools\chatgpt-account-switch\Open-Switcher.ps1"
if errorlevel 1 pause
