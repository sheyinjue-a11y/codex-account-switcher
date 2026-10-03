$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-LocalApiFastClient.ps1')
$root = Get-LocalApiFastRoot
$manifest = Join-Path $root 'installation.json'
if (Test-Path -LiteralPath $manifest) {
    $backup = Join-Path $root ('installation.disabled-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    Move-Item -LiteralPath $manifest -Destination $backup
}
Write-Host 'Local Fast client disabled. Close Codex and reopen through the account switcher.'
