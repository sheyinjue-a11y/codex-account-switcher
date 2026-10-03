[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
$script:localFastCalls = 0
function Start-LocalApiFastClient { $script:localFastCalls++; return $false }
function Show-ApiFastDegradedNotice { param($Detail) $script:notice = $Detail }
function Check($Condition, $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
# No real app, account, environment, or registry is changed by this test.
function Get-ChatGPTExecutable { throw 'Direct EXE launch loses the MSIX package identity.' }
function Get-ChatGPTAppUserModelId { 'OpenAI.Codex_fixture!App' }
function Get-ActivationEnvironmentValue { param($Name, $Target) return $null }
function Test-ChatGPTDesktopWindow { param($AppUserModelId) return $false }
$script:activated = ''
function Invoke-ChatGPTPackageActivation {
    param($AppUserModelId)
    $script:activated = $AppUserModelId
    return $PID
}
$settings = [pscustomobject]@{
    TestMode = $false; SkipLaunch = $false
    CanonicalHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
}
Start-SharedChatGPT $settings
Check ($script:activated -eq 'OpenAI.Codex_fixture!App') 'Launch uses the registered package identity, not the raw EXE.'
$settings.SkipLaunch = $true; $script:activated = ''
Start-SharedChatGPT $settings
Check ($script:activated -eq '') 'SkipLaunch does not activate an app.'
Check ($script:localFastCalls -eq 1) 'SkipLaunch does not start a local Fast client.'
$settings.SkipLaunch = $false
function Get-ActivationEnvironmentValue {
    param($Name, $Target)
    if ($Name -eq 'OPENAI_BASE_URL' -and $Target -eq 'User') { return 'https://fixture.invalid/v1' }
}
$failed = $false
try { Start-SharedChatGPT $settings } catch { $failed = $_.Exception.Message -match 'environment override' }
Check ($failed -and $script:activated -eq '') 'Persistent routing overrides fail closed before activation.'
Check ($script:localFastCalls -eq 1) 'Environment guards run before local Fast launch.'
function Get-ActivationEnvironmentValue { param($Name, $Target) return $null }
function Invoke-ChatGPTPackageActivation { param($AppUserModelId) return 0 }
$failed = $false
try { Start-SharedChatGPT $settings } catch { $failed = $_.Exception.Message -match 'started process' }
Check $failed 'A missing activated process is not reported as success.'
function Invoke-ChatGPTPackageActivation { param($AppUserModelId) return [int]::MaxValue }
$failed = $false
try { Start-SharedChatGPT $settings } catch { $failed = $_.Exception.Message -match 'launch ended' }
Check $failed 'A disappeared process without a desktop window is an error.'
function Test-ChatGPTDesktopWindow { param($AppUserModelId) return $true }
Start-SharedChatGPT $settings
Write-Host 'PASS: Activation can hand off to an existing desktop window.'
function Start-LocalApiFastClient { return $true }
$script:activated = ''
Start-SharedChatGPT $settings
Check ($script:activated -eq '') 'A verified local client replaces package activation.'
function Start-LocalApiFastClient { throw 'Fixture: stale local Fast build.' }
function Invoke-ChatGPTPackageActivation { param($AppUserModelId) $script:activated = $AppUserModelId; return $PID }
$script:notice = ''
Start-SharedChatGPT $settings
Check ($script:activated -eq 'OpenAI.Codex_fixture!App' -and $script:notice -match 'stale local Fast') 'An incompatible local client falls back to the official app with a notice.'
function Invoke-ChatGPTPackageActivation { param($AppUserModelId) return [int]::MaxValue }
$script:notice = ''
Start-SharedChatGPT $settings
Check ($script:notice -match 'stale local Fast') 'Fallback handoff to an existing window still reports Fast unavailability.'
Write-Host 'Package launch regression tests passed.'
