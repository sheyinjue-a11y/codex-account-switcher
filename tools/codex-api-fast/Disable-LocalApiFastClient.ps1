$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-LocalApiFastClient.ps1')
$root = Get-LocalApiFastRoot
$manifest = Join-Path $root 'installation.json'
New-Item -ItemType Directory -Path $root -Force | Out-Null
$lock = Enter-LocalFastUpdateLock $root
try {
    Write-LocalFastJson (Join-Path $root 'auto-update.json') @{schemaVersion=1;enabled=$false}
    if (Test-Path -LiteralPath $manifest) {
        $backup = Join-Path $root ('installation.disabled-' + [guid]::NewGuid().ToString('N') + '.json')
        Move-Item -LiteralPath $manifest -Destination $backup
    }
} finally { $lock.Dispose() }
Write-Host 'Local Fast client disabled. Close Codex and reopen through the account switcher.'
