[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$root=Join-Path $parent ('fresh-install-test-'+[guid]::NewGuid().ToString('N'))
function Check($Value,$Message) { if (-not $Value) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action,$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Message }
function Settings([string]$Name) {
    $base=Join-Path $root $Name
    return [pscustomobject]@{CanonicalHome=(Join-Path $base 'shared');VaultRoot=(Join-Path $base 'vault');LabHome=(Join-Path $base 'lab');ShareHome=(Join-Path $base 'old');BackupRoot=(Join-Path $base 'backup');TestRoot=$root;TestMode=$true;SkipProcessCheck=$true;SimulateBusy=$false;SkipCodexStatus=$true;SkipLaunch=$true}
}
try {
    . (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
    foreach($kind in @('chatgpt','responses_api')) {
        $s=Settings $kind
        $auth=if($kind -eq 'chatgpt') {'{"auth_mode":"chatgpt","tokens":{"account_id":"FAKE_ACCOUNT_LOCAL_TEST_ONLY","access_token":"FAKE_ACCESS_LOCAL_TEST_ONLY","refresh_token":"FAKE_REFRESH_LOCAL_TEST_ONLY"}}'} else {'{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_KEY_LOCAL_TEST_ONLY"}'}
        Write-AtomicText (Join-Path $s.CanonicalHome 'auth.json') $auth
        Write-AtomicText (Join-Path $s.CanonicalHome 'config.toml') "model = `"test-model`"`r`n[features]`r`nexample = true`r`n"
        Write-AtomicText (Join-Path $s.CanonicalHome 'session-marker.txt') 'KEEP_LOCAL_HISTORY'
        $before=(Get-FileHash (Join-Path $s.CanonicalHome 'auth.json')).Hash
        $null=Initialize-MultiProfileSwitcher $s
        $r=Read-ProfileRegistry $s; $state=Read-ProfileState $s
        Check ($r.profiles.Count -eq 1 -and $r.profiles[0].kind -eq $kind -and $state.activeProfileId -eq $r.profiles[0].id) "Fresh $kind install imports one active profile without legacy homes."
        Check ((Get-FileHash (Join-Path $s.CanonicalHome 'auth.json')).Hash -eq $before) 'Existing credential bytes stay unchanged.'
        Check ((Get-Content (Join-Path $s.CanonicalHome 'session-marker.txt') -Raw).Trim() -eq 'KEEP_LOCAL_HISTORY') 'Local history remains untouched.'
        Check ([IO.File]::ReadAllText((Join-Path $s.CanonicalHome 'config.toml')).Contains('[features]')) 'Unrelated configuration is preserved.'
        $hash=(Get-FileHash (Get-ProfileRegistryPath $s)).Hash
        $null=Initialize-MultiProfileSwitcher $s
        Check ((Get-FileHash (Get-ProfileRegistryPath $s)).Hash -eq $hash) 'Repeated initialization is idempotent.'
        Invoke-ProfileSwitch $s $state.activeProfileId -DoNotLaunch
        Check ((Read-ProfileState $s).generation -ge 1) 'Imported account is switchable.'
    }
    $noConfig=Settings 'no-config'
    Write-AtomicText (Join-Path $noConfig.CanonicalHome 'auth.json') '{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_KEY_LOCAL_TEST_ONLY"}'
    $null=Initialize-MultiProfileSwitcher $noConfig
    Check ((Read-ProfileRegistry $noConfig).profiles.Count -eq 1) 'Missing optional config is created safely.'
    $missing=Settings 'missing'
    Reject { Initialize-MultiProfileSwitcher $missing } 'Missing login fails with no invented credentials.'
    Check (-not (Test-Path (Get-ProfileRegistryPath $missing))) 'Failed setup leaves no registry.'
    $partial=Settings 'partial'
    Write-AtomicText (Get-ProfileSecretPath $partial personal auth) 'FAKE_PARTIAL_LOCAL_TEST_ONLY'
    Reject { Initialize-MultiProfileSwitcher $partial } 'Partial vault is not overwritten.'
    $bad=Settings 'unsupported'
    Write-AtomicText (Join-Path $bad.CanonicalHome 'auth.json') '{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_KEY_LOCAL_TEST_ONLY"}'
    Write-AtomicText (Join-Path $bad.CanonicalHome 'config.toml') 'model_provider = "custom"'
    $before=(Get-FileHash (Join-Path $bad.CanonicalHome 'config.toml')).Hash
    Reject { Initialize-MultiProfileSwitcher $bad } 'Unsupported custom provider fails closed.'
    Check ((Get-FileHash (Join-Path $bad.CanonicalHome 'config.toml')).Hash -eq $before) 'Rejected setup preserves config.'
    $rollback=Settings 'rollback'
    Write-AtomicText (Join-Path $rollback.CanonicalHome 'auth.json') '{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_KEY_LOCAL_TEST_ONLY"}'
    Write-AtomicText (Join-Path $rollback.CanonicalHome 'config.toml') 'model = "test-model"'
    $before=(Get-FileHash (Join-Path $rollback.CanonicalHome 'config.toml')).Hash
    $originalBackend=${function:Test-ProfileBackend}
    function Test-ProfileBackend($Settings,$Profile) { return $false }
    try { Reject { Initialize-MultiProfileSwitcher $rollback } 'Backend failure rolls back fresh setup.' }
    finally { Set-Item Function:Test-ProfileBackend $originalBackend }
    Check ((Get-FileHash (Join-Path $rollback.CanonicalHome 'config.toml')).Hash -eq $before) 'Rollback restores original config bytes.'
    Check (-not (Test-Path (Get-ProfileRegistryPath $rollback)) -and -not (Test-Path (Get-StatePath $rollback))) 'Rollback removes partial registry and state.'
    Check (@(Get-ChildItem -LiteralPath $rollback.VaultRoot -Filter '*.dpapi').Count -eq 0) 'Rollback removes partial encrypted profiles and journal.'
    $null=Initialize-MultiProfileSwitcher $rollback
    Check ((Read-ProfileRegistry $rollback).profiles.Count -eq 1) 'Setup can retry after rollback.'
    Write-Host 'Fresh installation tests passed.'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith($parent+'\fresh-install-test-',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup.' }
    if(Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
