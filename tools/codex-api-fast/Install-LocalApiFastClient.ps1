[CmdletBinding()]
param(
    [string]$NodePath = (Get-Command node -ErrorAction Stop).Source,
    [string]$RootPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex-api-fast-client'),
    [switch]$LockHeld
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LocalApiFastInstaller.ps1')
Invoke-LocalApiFastInstall -NodePath $NodePath -RootPath $RootPath -LockHeld:$LockHeld | ConvertTo-Json -Depth 8
