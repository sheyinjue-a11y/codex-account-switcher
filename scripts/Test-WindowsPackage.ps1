[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Directory)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Directory).Path
$expected = @('Codex Account Switcher.exe','app','使用说明.txt')
$actual = @(Get-ChildItem -LiteralPath $root | ForEach-Object Name)
if (@(Compare-Object $expected $actual).Count) { throw 'The user package must have exactly one application, app folder, and usage note.' }
if (@(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.cmd','.command','.bat') -or $_.Name -like 'Test-*' -or $_.Name -like 'test-*' }).Count) { throw 'Developer/test launch scripts leaked into the app package.' }
$runtime = Join-Path $root 'app\tools\chatgpt-account-switch\Open-Switcher.ps1'
$preview = Join-Path ([IO.Path]::GetTempPath()) ('packaged-preview-' + [Guid]::NewGuid().ToString('N') + '.png')
try {
    & powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File $runtime -PreviewPath $preview
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $preview)) { throw 'Packaged bootstrap did not render its first-run window.' }
} finally { if (Test-Path -LiteralPath $preview) { Remove-Item -LiteralPath $preview } }
$process = Start-Process -FilePath (Join-Path $root 'Codex Account Switcher.exe') -ArgumentList '--verify-layout' -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0) { throw 'Packaged executable did not find its runtime.' }
Write-Host 'PASS: One app entry, no command/test launchers, executable layout and packaged WPF startup.'
