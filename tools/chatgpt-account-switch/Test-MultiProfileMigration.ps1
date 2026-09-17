[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$root = Join-Path $parent ('multi-profile-test-' + [guid]::NewGuid().ToString('N'))
function Check($Condition, $Message) { if (-not $Condition) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action, $Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Message }
function Auth($Id) { [Text.Encoding]::UTF8.GetBytes((@{auth_mode='chatgpt'; tokens=@{account_id=$Id; access_token='FAKE_ACCESS_LOCAL_TEST_ONLY'; refresh_token='FAKE_REFRESH_LOCAL_TEST_ONLY'; id_token='FAKE_ID_LOCAL_TEST_ONLY'}} | ConvertTo-Json -Depth 5)) }
try {
    New-Item -ItemType Directory $root | Out-Null
    . (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
    $s=[pscustomobject]@{CanonicalHome=(Join-Path $root 'shared'); VaultRoot=(Join-Path $root 'vault'); LabHome=(Join-Path $root 'lab'); ShareHome=(Join-Path $root 'old'); BackupRoot=(Join-Path $root 'backup'); TestRoot=$root; TestMode=$true; SkipProcessCheck=$true; SimulateBusy=$false; SkipCodexStatus=$true; SkipLaunch=$true}
    foreach($p in @($s.CanonicalHome,$s.VaultRoot,$s.LabHome,$s.ShareHome)) { New-Item -ItemType Directory $p | Out-Null }
    $a=Auth 'FAKE_ACCOUNT_ONE_LOCAL_TEST_ONLY'
    $b=[Text.Encoding]::UTF8.GetBytes('{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_API_LOCAL_TEST_ONLY"}')
    Save-ProfileCredential $s Personal $a
    Save-ProfileCredential $s Lab $b
    Save-ProviderRoute $s personal (Get-ProviderRoute "model = `"gpt-test`"`r`n")
    Save-ProviderRoute $s lab (Get-ProviderRoute "model = `"gpt-test`"`r`nopenai_base_url = `"https://api.example.test/v1`"`r`n")
    Write-AtomicBytes (Join-Path $s.CanonicalHome 'auth.json') $a
    Write-AtomicText (Join-Path $s.CanonicalHome 'config.toml') "model = `"gpt-test`"`r`ncli_auth_credentials_store = `"file`"`r`n[features]`r`nexample = true`r`n"
    Write-SwitcherState $s Personal 7
    $hashes=@{}; Get-ChildItem $s.VaultRoot -Filter '*.dpapi' | ForEach-Object { $hashes[$_.Name]=(Get-FileHash $_.FullName).Hash }
    $labRoutePath=Get-ProfileSecretPath $s lab route
    $labRouteBytes=[IO.File]::ReadAllBytes($labRoutePath)
    Remove-Item -LiteralPath $labRoutePath -Force
    Reject { Convert-LegacyProfiles $s } 'Migration refuses missing legacy route.'
    Check ((Read-SwitcherState $s).schemaVersion -eq 1 -and -not (Test-Path (Get-ProfileRegistryPath $s))) 'Failed migration preserves schema 1 without a partial registry.'
    Write-AtomicBytes $labRoutePath $labRouteBytes
    $labAuthPath=Get-ProfileSecretPath $s lab auth; $labAuthBytes=[IO.File]::ReadAllBytes($labAuthPath)
    Write-AtomicText $labAuthPath 'FAKE_DAMAGED_LOCAL_TEST_ONLY'
    Reject { Convert-LegacyProfiles $s } 'Migration refuses damaged legacy credentials.'
    Check ((Read-SwitcherState $s).schemaVersion -eq 1 -and -not (Test-Path (Get-ProfileRegistryPath $s))) 'Credential failure preserves legacy state.'
    Write-AtomicBytes $labAuthPath $labAuthBytes
    $null=Convert-LegacyProfiles $s
    $r=Read-ProfileRegistry $s; $state=Read-ProfileState $s
    Check ($r.profiles.Count -eq 2 -and $state.activeProfileId -eq 'personal' -and $state.generation -eq 7) 'Migration preserves two stable IDs and active generation.'
    foreach($name in $hashes.Keys) { Check ((Get-FileHash (Join-Path $s.VaultRoot $name)).Hash -eq $hashes[$name]) "Migration preserves encrypted $name bytes." }
    $registryHash=(Get-FileHash (Get-ProfileRegistryPath $s)).Hash; $stateHash=(Get-FileHash (Get-StatePath $s)).Hash
    $null=Convert-LegacyProfiles $s
    Check (((Get-FileHash (Get-ProfileRegistryPath $s)).Hash -eq $registryHash) -and ((Get-FileHash (Get-StatePath $s)).Hash -eq $stateHash)) 'Migration is idempotent.'
    $two=Import-ChatGPTCredential $s 'Account two' (Auth 'FAKE_ACCOUNT_TWO_LOCAL_TEST_ONLY')
    Invoke-ProfileSwitch $s $two.id -DoNotLaunch
    Check ((Read-ProfileState $s).activeProfileId -eq $two.id) 'Arbitrary OAuth profile switches.'
    Invoke-ProfileSwitch $s lab -DoNotLaunch
    Check ((Get-ProviderRoute ([IO.File]::ReadAllText((Join-Path $s.CanonicalHome 'config.toml')))).Endpoint -eq 'https://api.example.test/v1') 'API endpoint selected.'
    Invoke-ProfileSwitch $s personal -DoNotLaunch
    Check ([string]::IsNullOrEmpty((Get-ProviderRoute ([IO.File]::ReadAllText((Join-Path $s.CanonicalHome 'config.toml')))).Endpoint)) 'OAuth has no API endpoint.'
    Write-AtomicBytes (Join-Path $s.CanonicalHome 'auth.json') (Auth 'FAKE_WRONG_ACCOUNT_LOCAL_TEST_ONLY')
    Reject { Invoke-ProfileSwitch $s $two.id -DoNotLaunch } 'Mismatched live identity cannot overwrite profile.'
    Write-AtomicBytes (Join-Path $s.CanonicalHome 'auth.json') $a
    $before=@{}; foreach($name in @('auth.json','config.toml')) { $before[$name]=(Get-FileHash (Join-Path $s.CanonicalHome $name)).Hash }
    Reject { Invoke-ProfileSwitch $s $two.id -DoNotLaunch -FailurePoint AfterCredentialWrite } 'Injected switch failure rolls back.'
    foreach($name in $before.Keys) { Check ((Get-FileHash (Join-Path $s.CanonicalHome $name)).Hash -eq $before[$name]) "Recovery restores $name." }
    Check ((Read-ProfileState $s).activeProfileId -eq 'personal') 'Recovery restores active state.'
    Reject { Import-ChatGPTCredential $s 'Duplicate' $a } 'Duplicate OAuth account is rejected.'
    $null=Invoke-ProfileManagement $s ([pscustomobject]@{action='update_api';profileId='lab';displayName='Edited Lab';baseUrl='https://replacement.example.test/v1';apiKey='';model='user-selected-model'})
    Invoke-ProfileSwitch $s lab -DoNotLaunch
    Check ([IO.File]::ReadAllText((Join-Path $s.CanonicalHome 'config.toml')).Contains('model = "user-selected-model"')) 'Explicit Lab edit preserves chosen model on switch.'
    Invoke-ProfileSwitch $s personal -DoNotLaunch
    Invoke-ProfileSwitch $s lab -DoNotLaunch
    Check ([IO.File]::ReadAllText((Join-Path $s.CanonicalHome 'config.toml')).Contains('model = "user-selected-model"')) 'Edited Lab model survives subsequent round trips.'
    Write-Host 'Multi-profile migration and switching tests passed.'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith($parent+'\multi-profile-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
