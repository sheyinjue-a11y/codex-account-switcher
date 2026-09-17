@echo off
setlocal
echo This opens the official Codex browser login and saves the current login locally.
echo Close running Codex apps first. Existing login may be replaced.
echo Press Ctrl+C to cancel, or any key to continue.
pause >nul
codex.exe -c cli_auth_credentials_store=\"file\" login
if errorlevel 1 (
  pause
  exit /b 1
)
echo Login complete. Close Codex and run Setup.cmd.
pause
