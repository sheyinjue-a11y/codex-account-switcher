$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-LocalApiFastClient.ps1')
function Check($Condition, $Message) {
    if (-not $Condition) { throw ('FAIL: ' + $Message) }
    Write-Host ('PASS: ' + $Message)
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-local-fast-test-' + [guid]::NewGuid().ToString('N'))
Check ((Get-LocalApiFastRoot) -eq (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex-api-fast-client')) 'Installations live outside virtualized AppData.'
function Get-LocalApiFastRoot { return (Join-Path $fixtureRoot '.codex-api-fast-client') }
try {
    Check ($null -eq (Get-LocalApiFastInstallation)) 'Absent installation leaves official launch available.'
    $app = Join-Path (Get-LocalApiFastRoot) 'versions\1.2.3.4'
    New-Item -ItemType Directory -Path (Join-Path $app 'resources') -Force | Out-Null
    foreach ($file in @('ChatGPT.exe','resources\app.asar','chrome.dll')) { [IO.File]::WriteAllText((Join-Path $app $file), 'fixture') }
    $hash = (Get-FileHash -LiteralPath (Join-Path $app 'ChatGPT.exe')).Hash
    $manifest = Join-Path (Get-LocalApiFastRoot) 'installation.json'
    $data = @{schemaVersion=1;version='1.2.3.4';directory=$app;packageFullName='fixture';exeSha256=$hash;archiveSha256=$hash;runtimeSha256=$hash}
    $data | ConvertTo-Json | Set-Content -LiteralPath $manifest
    function Get-AppxPackage { param($Name) [pscustomobject]@{PackageFullName='fixture';Version='1.2.3.4'} }
    Check ((Get-LocalApiFastInstallation).directory -eq $app) 'Matching version and all file hashes are accepted.'
    $data.version = '0.0.0.0'
    $data.directory = Join-Path (Get-LocalApiFastRoot) 'versions\0.0.0.0'
    $data | ConvertTo-Json | Set-Content -LiteralPath $manifest
    $failed = $false
    try { Get-LocalApiFastInstallation | Out-Null } catch { $failed = $_.Exception.Message -match 'updated' }
    Check $failed 'A matching package name cannot authorize a different version directory.'
    $data.version = '1.2.3.4'
    $data.directory = $app
    $data | ConvertTo-Json | Set-Content -LiteralPath $manifest
    [IO.File]::WriteAllText((Join-Path $app 'resources\app.asar'), 'changed')
    $failed = $false
    try { Get-LocalApiFastInstallation | Out-Null } catch { $failed = $_.Exception.Message -match 'integrity mismatch' }
    Check $failed 'Changed archive is rejected before launch.'
    [IO.File]::WriteAllText((Join-Path $app 'resources\app.asar'), 'fixture')
    function Get-AppxPackage { param($Name) [pscustomobject]@{PackageFullName='new-version';Version='1.2.3.5'} }
    $failed = $false
    try { Get-LocalApiFastInstallation | Out-Null } catch { $failed = $_.Exception.Message -match 'updated' }
    Check $failed 'Official updates reject the stale local build.'
    $data.directory = Join-Path $fixtureRoot 'elsewhere'
    $data | ConvertTo-Json | Set-Content -LiteralPath $manifest
    $failed = $false
    try { Get-LocalApiFastInstallation | Out-Null } catch { $failed = $_.Exception.Message -match 'Unexpected local Fast directory' }
    Check $failed 'A manifest cannot redirect launch outside the version directory.'

    # Regression: the launch used to adjust the child environment through
    # ProcessStartInfo.EnvironmentVariables, which throws under Windows
    # PowerShell 5.1, so every Fast launch failed and silently fell back to the
    # official client. Building the start info must not touch that dictionary,
    # and the process environment must be restored even when launching fails.
    $data.directory = $app
    $data | ConvertTo-Json | Set-Content -LiteralPath $manifest
    function Get-AppxPackage { param($Name) [pscustomobject]@{PackageFullName='fixture';Version='1.2.3.4';PackageFamilyName='OpenAI.Codex_fixture'} }
    $probeName = 'CODEX_SWITCHER_ENV_PROBE'
    [Environment]::SetEnvironmentVariable($probeName, 'probe-value')
    $saved = Set-LocalApiFastEnvironment
    try {
        Check ($null -eq [Environment]::GetEnvironmentVariable('CODEX_HOME')) 'The private client launches without an inherited Codex home.'
        Check ([Environment]::GetEnvironmentVariable($probeName) -eq 'probe-value') 'Unrelated variables are left alone for the child process.'
    } finally { Restore-LocalApiFastEnvironment $saved }
    Check ([Environment]::GetEnvironmentVariable($probeName) -eq 'probe-value') 'The launch restores the environment it borrowed.'
    [Environment]::SetEnvironmentVariable($probeName, $null)
    $startInfo = New-LocalApiFastProcessStartInfo $app
    Check ($startInfo.FileName -eq (Join-Path $app 'ChatGPT.exe')) 'A start info can be built without ProcessStartInfo.EnvironmentVariables.'
    Check ($startInfo.UseShellExecute -eq $false) 'The client is started directly so the switcher can watch its startup.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-local-fast-test-*') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
