[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$switcher = Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1'
$testParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $testParent ('switch-recovery-test-' + [guid]::NewGuid().ToString('N'))
$oldTestMode = $env:CODEX_SWITCHER_TEST_MODE
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $settings = [pscustomobject]@{
        TestRoot = $testRoot; CanonicalHome = Join-Path $testRoot 'shared'
        LabHome = Join-Path $testRoot 'lab'; ShareHome = Join-Path $testRoot 'legacy'
        VaultRoot = Join-Path $testRoot 'vault'; BackupRoot = Join-Path $testRoot 'backups'
        SkipProcessCheck = $true; SimulateBusy = $false; SkipCodexStatus = $true
    }
    foreach ($folder in @($settings.CanonicalHome, $settings.LabHome)) { $null = New-Item -ItemType Directory -Path $folder }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $settingsPath = Join-Path $testRoot 'settings.json'
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json), $utf8)
    $authPath = Join-Path $settings.CanonicalHome 'auth.json'
    $configPath = Join-Path $settings.CanonicalHome 'config.toml'
    [IO.File]::WriteAllText($authPath, '{"auth_mode":"chatgpt","tokens":{"access_token":"FAKE_OLD","refresh_token":"FAKE_REFRESH"}}', $utf8)
    [IO.File]::WriteAllText($configPath, "model = `"gpt-personal`"`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $settings.LabHome 'auth.json'), '{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_LAB"}', $utf8)
    [IO.File]::WriteAllText((Join-Path $settings.LabHome 'config.toml'), @'
model = "gpt-lab"
model_provider = "OpenAI"
[model_providers.OpenAI]
base_url = "http://127.0.0.1:9/lab"
wire_api = "responses"
requires_openai_auth = true
'@, $utf8)
    $env:CODEX_SWITCHER_TEST_MODE = '1'
    . $switcher -Status -TestSettings $settingsPath | Out-Null
    Invoke-InitializeSwitcher -Settings $settings
    $refreshed = '{"auth_mode":"chatgpt","tokens":{"access_token":"FAKE_REFRESHED","refresh_token":"FAKE_REFRESHED_REFRESH"}}'
    [IO.File]::WriteAllText($authPath, $refreshed, $utf8)
    Invoke-AccountSwitch -Settings $settings -TargetProfile Lab -DoNotLaunch
    Invoke-AccountSwitch -Settings $settings -TargetProfile Personal -DoNotLaunch
    Check ([IO.File]::ReadAllText($authPath) -eq $refreshed) 'Refreshed personal credentials survive a round trip.'
    $baselineConfig = [IO.File]::ReadAllText($configPath)
    $childPath = Join-Path $testRoot 'interrupt.ps1'
    [IO.File]::WriteAllText($childPath, @'
param($Switcher, $SettingsPath, $Boundary)
$env:CODEX_SWITCHER_TEST_MODE = '1'
. $Switcher -Status -TestSettings $SettingsPath | Out-Null
$script:realWrite = ${function:Write-AtomicBytes}
function Write-AtomicBytes {
    param([string]$Path, [byte[]]$Bytes)
    & $script:realWrite -Path $Path -Bytes $Bytes
    $leaf = Split-Path -Leaf $Path
    $hit = ($Boundary -eq 'config' -and $leaf -eq 'config.toml' -and [Text.Encoding]::UTF8.GetString($Bytes).Contains('openai_base_url')) -or
           ($Boundary -eq 'auth' -and $leaf -eq 'auth.json') -or
           ($Boundary -eq 'state' -and $leaf -eq 'state.json')
    if ($hit) { [Environment]::Exit(91) } # Abrupt exit deliberately bypasses catch/finally.
}
Invoke-AccountSwitch -Settings $settings -TargetProfile Lab -DoNotLaunch
exit 92
'@, $utf8)
    $journalPath = Join-Path $settings.VaultRoot 'pending-switch.dpapi'
    Remove-Item -LiteralPath $configPath
    $missingRejected = $false
    try { Invoke-AccountSwitch -Settings $settings -TargetProfile Lab -DoNotLaunch } catch { $missingRejected = $true }
    Check $missingRejected 'Missing configuration is rejected before switching.'
    Check (-not (Test-Path -LiteralPath $journalPath)) 'Missing configuration cannot create an unusable journal.'
    [IO.File]::WriteAllText($configPath, $baselineConfig, $utf8)
    foreach ($boundary in @('config', 'auth', 'state')) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $childPath $switcher $settingsPath $boundary | Out-Null
        Check ($LASTEXITCODE -eq 91) "Child interrupted after $boundary write."
        Check (Test-Path -LiteralPath $journalPath) 'Encrypted recovery record survives process exit.'
        $journalHash = (Get-FileHash -LiteralPath $journalPath).Hash
        Invoke-AccountSwitch -Settings $settings -TargetProfile Personal -WhatIfOnly | Out-Null
        Check ((Get-FileHash -LiteralPath $journalPath).Hash -eq $journalHash) 'Dry run leaves pending recovery untouched.'
        $partialHash = (Get-FileHash -LiteralPath $configPath).Hash
        $settings.SimulateBusy = $true
        $blocked = $false
        try { Invoke-AccountSwitch -Settings $settings -TargetProfile Personal -DoNotLaunch } catch { $blocked = $true }
        $settings.SimulateBusy = $false
        Check $blocked 'Recovery refuses an active Codex process.'
        Check ((Get-FileHash -LiteralPath $configPath).Hash -eq $partialHash) 'Blocked recovery changes no configuration.'
        Invoke-AccountSwitch -Settings $settings -TargetProfile Personal -DoNotLaunch
        Check ([IO.File]::ReadAllText($authPath) -eq $refreshed) "Recovery preserves the latest credential ($boundary)."
        Check ([IO.File]::ReadAllText($configPath) -eq $baselineConfig) "Recovery restores the personal configuration ($boundary)."
        Check (-not (Test-Path -LiteralPath $journalPath)) 'Successful recovery removes its journal.'
    }
    # Launch is outside the transaction: a launch failure must not undo a committed switch.
    $realLaunch = ${function:Start-SharedChatGPT}
    function Start-SharedChatGPT { param($Settings) throw 'Fixture launch failed.' }
    $launchReported = $false
    try { Invoke-AccountSwitch -Settings $settings -TargetProfile Lab }
    catch { $launchReported = $_.Exception.Message.Contains('Profile switched to Lab') }
    Set-Item -Path function:Start-SharedChatGPT -Value $realLaunch
    Check $launchReported 'Launch failure reports that the profile was already switched.'
    Check ((Get-ActiveProfileFromHome -Settings $settings) -eq 'Lab') 'Launch failure does not roll back committed credentials.'
    Check (-not (Test-Path -LiteralPath $journalPath)) 'Committed profile has no pending recovery.'
    Invoke-AccountSwitch -Settings $settings -TargetProfile Personal -DoNotLaunch
    # A damaged journal must fail closed, without overwriting the active profile.
    [IO.File]::WriteAllText($journalPath, 'INVALID_ENCRYPTED_DATA', $utf8)
    $rejected = $false
    try { Invoke-AccountSwitch -Settings $settings -TargetProfile Lab -DoNotLaunch } catch { $rejected = $true }
    Check $rejected 'Unreadable recovery data blocks switching.'
    Check ([IO.File]::ReadAllText($authPath) -eq $refreshed) 'Unreadable journal leaves credentials unchanged.'
    Check ([IO.File]::ReadAllText($configPath) -eq $baselineConfig) 'Unreadable journal leaves configuration unchanged.'
    Write-Host 'Recovery tests passed.'
} finally {
    if ($null -eq $oldTestMode) { Remove-Item Env:CODEX_SWITCHER_TEST_MODE -ErrorAction SilentlyContinue }
    else { $env:CODEX_SWITCHER_TEST_MODE = $oldTestMode }
    $resolved = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    if (-not $resolved.StartsWith($testParent + '\switch-recovery-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
