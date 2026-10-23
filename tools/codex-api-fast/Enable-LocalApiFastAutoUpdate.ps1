[CmdletBinding()]
param([string]$NodePath = (Get-Command node -ErrorAction Stop).Source, [string]$ModulePath = (Join-Path $PSScriptRoot 'node_modules'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-LocalApiFastClient.ps1')
$NodePath = (Resolve-Path -LiteralPath $NodePath).Path
$ModulePath = (Resolve-Path -LiteralPath $ModulePath).Path
$previousNodePath = $env:NODE_PATH
try {
    $env:NODE_PATH = $ModulePath
    'require("acorn"); if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)' | & $NodePath -
    if ($LASTEXITCODE -ne 0) { throw 'Node.js 22+ and Acorn are required. Run npm ci in this tools directory first.' }
} finally { $env:NODE_PATH = $previousNodePath }
$root = Get-LocalApiFastRoot
New-Item -ItemType Directory -Path $root -Force | Out-Null
$lock = Enter-LocalFastUpdateLock $root
try {
    Write-LocalFastJson (Join-Path $root 'auto-update.json') @{schemaVersion=1;enabled=$true;nodePath=$NodePath;modulePath=$ModulePath}
    # Explicit enabling is also the user's retry action after fixing a dependency.
    Write-LocalFastJson (Join-Path $root 'auto-update-status.json') @{key='';status='pending';detail='Automatic Fast enabled.'}
} finally { $lock.Dispose() }
Write-Host 'Automatic API Fast enabled. Open the API account through the desktop switcher; official updates will be checked and adapted before launch.'
