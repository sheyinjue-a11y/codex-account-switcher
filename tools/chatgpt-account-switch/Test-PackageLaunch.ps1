[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
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
$settings.SkipLaunch = $false
function Get-ActivationEnvironmentValue {
    param($Name, $Target)
    if ($Name -eq 'OPENAI_BASE_URL' -and $Target -eq 'User') { return 'https://fixture.invalid/v1' }
}
$failed = $false
try { Start-SharedChatGPT $settings } catch { $failed = $_.Exception.Message -match 'environment override' }
Check ($failed -and $script:activated -eq '') 'Persistent routing overrides fail closed before activation.'
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
Write-Host 'Package launch regression tests passed.'
