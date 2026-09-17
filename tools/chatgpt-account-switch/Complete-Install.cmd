@echo off
setlocal
echo Close ChatGPT, Codex CLI, and VS Code Codex before continuing.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-ChatGPTAccount.ps1" -Initialize
if errorlevel 1 (
  pause
  exit /b 1
)
echo Installation / migration verified. Shared sessions are preserved.
echo Use the unified ChatGPT icon to select or manage profiles.
pause
exit /b 0
