[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$root=Join-Path $parent ('profile-management-test-'+[guid]::NewGuid().ToString('N'))
function Check($Value,$Message) { if (-not $Value) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action,$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Message }
try {
    . (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
    $s=[pscustomobject]@{CanonicalHome=(Join-Path $root 'shared');VaultRoot=(Join-Path $root 'vault');LabHome=(Join-Path $root 'lab');ShareHome=(Join-Path $root 'old');BackupRoot=(Join-Path $root 'backup');TestRoot=$root;TestMode=$true;SkipProcessCheck=$true;SimulateBusy=$false;SkipCodexStatus=$true;SkipLaunch=$true}
    foreach($path in @($s.CanonicalHome,$s.VaultRoot)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $r=New-ProfileRegistry $s.CanonicalHome
    $r=Add-ProfileRecord $r 'First API' responses_api
    $first=$r.profiles[0]
    $auth=[Text.Encoding]::UTF8.GetBytes('{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_FIRST_LOCAL_TEST_ONLY"}')
    Write-ProfileAuth $s $first $auth; Write-ProfileRoute $s $first (New-ResponsesRoute 'https://first.example.test/v1' 'gpt-test')
    Write-ProfileRegistry $s $r; Write-ProfileState $s $first.id 1
    Write-AtomicBytes (Join-Path $s.CanonicalHome 'auth.json') $auth
    Write-AtomicText (Join-Path $s.CanonicalHome 'config.toml') "model_provider = `"openai`"`r`nopenai_base_url = `"https://first.example.test/v1`"`r`nmodel = `"gpt-test`"`r`ncli_auth_credentials_store = `"file`"`r`n"
    $request=[pscustomobject]@{action='add_api';displayName='Second API';baseUrl='https://second.example.test/v1';apiKey='FAKE_SECOND_SECRET_LOCAL_TEST_ONLY';model='gpt-two'}
    $second=Invoke-ProfileManagement $s $request
    Check ((Read-ProfileRegistry $s).profiles.Count -eq 2) 'Add API creates a profile.'
    Check ((Read-ProfileState $s).activeProfileId -eq $first.id) 'Add does not switch active profile.'
    $null=Invoke-ProfileManagement $s ([pscustomobject]@{action='update_api';profileId=$second.id;displayName='Second API';baseUrl='https://changed.example.test/v1';apiKey='';model='gpt-new'})
    $bytes=Read-ProfileAuth $s $second
    Check (([Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json).OPENAI_API_KEY -eq $request.apiKey) 'Blank API edit preserves the key.'
    Check ((Read-ProfileRoute $s $second).Endpoint -eq 'https://changed.example.test/v1') 'Edit changes only selected endpoint.'
    Reject { Invoke-ProfileManagement $s ([pscustomobject]@{action='delete';profileId=$first.id}) } 'Active profile cannot be deleted.'
    Reject { New-ResponsesRoute 'http://public.example.test/v1' 'gpt-test' } 'Public HTTP is rejected.'
    Reject { New-ResponsesRoute 'https://user:password@example.test/v1' 'gpt-test' } 'URL credentials are rejected.'
    Reject { New-ResponsesRoute 'https://example.test/v1?key=FAKE_LOCAL_TEST_ONLY' 'gpt-test' } 'URL query secrets are rejected.'
    Reject { New-ResponsesRoute 'file:///C:/test' 'gpt-test' } 'Non-HTTP scheme is rejected.'
    Reject { New-ResponsesRoute 'https://example.test/v1' "gpt`"`r`ninjected=true" } 'Model injection is rejected.'
    $null=Invoke-ProfileManagement $s ([pscustomobject]@{action='rename';profileId=$second.id;displayName='Renamed'})
    Check ((Get-ProfileById (Read-ProfileRegistry $s) $second.id).displayName -eq 'Renamed') 'Rename changes display name.'
    $statusText=Get-ProfileStatus $s | ConvertTo-Json -Depth 8
    Check (-not $statusText.Contains($request.apiKey)) 'Status contains no key.'
    foreach($f in Get-ChildItem $s.VaultRoot -File | Where-Object Extension -ne '.dpapi') { Check (-not [IO.File]::ReadAllText($f.FullName).Contains($request.apiKey)) 'Plain metadata contains no key.' }
    $null=Invoke-ProfileManagement $s ([pscustomobject]@{action='delete';profileId=$second.id})
    Check ((Read-ProfileRegistry $s).profiles.Count -eq 1 -and -not (Test-Path (Get-ProfileSecretPath $s $second.id auth))) 'Delete removes only inactive encrypted profile.'
    Check (Test-Path (Join-Path $s.CanonicalHome 'auth.json')) 'Delete preserves shared home.'
    $s.SkipCodexStatus=$false
    $null=Invoke-ProfileManagement $s ([pscustomobject]@{action='update_api';profileId=$first.id;displayName='First API';baseUrl='https://first.example.test/v2';apiKey='FAKE_UPDATED_LOCAL_TEST_ONLY';model='gpt-test'})
    Check (([IO.File]::ReadAllText((Join-Path $s.CanonicalHome 'auth.json'))|ConvertFrom-Json).OPENAI_API_KEY -eq 'FAKE_UPDATED_LOCAL_TEST_ONLY') 'Active API edit updates shared credentials after real local Codex validation.'
    Check ([IO.File]::ReadAllText((Join-Path $s.CanonicalHome 'config.toml')).Contains('https://first.example.test/v2')) 'Active API edit updates shared routing.'
    Check (-not (Test-Path (Join-Path $s.VaultRoot 'staging'))) 'Local syntax validation leaves no staging files.'
    $settingsFile=Join-Path $root 'settings.json'; Write-AtomicText $settingsFile ($s|ConvertTo-Json)
    $resultFile=Join-Path $root 'runner-result.json'
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='powershell.exe'; $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardInput=$true
    $info.EnvironmentVariables['CODEX_SWITCHER_TEST_MODE']='1'
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Invoke-ChatGPTSwitch.ps1')+'" -Action Manage -SwitcherPath "'+(Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1')+'" -OutputPath "'+$resultFile+'" -TestSettings "'+$settingsFile+'"'
    $process=[Diagnostics.Process]::Start($info)
    try {
        $name=-join([char[]]@(0x6d4b,0x8bd5))
        $payload=[Text.Encoding]::UTF8.GetBytes((@{action='add_api';displayName=$name;baseUrl='https://runner.example.test/v1';apiKey='FAKE_RUNNER_SECRET_LOCAL_TEST_ONLY';model='gpt-test'}|ConvertTo-Json -Compress))
        $process.StandardInput.BaseStream.Write($payload,0,$payload.Length); $process.StandardInput.Close()
        Check ($process.WaitForExit(15000)) 'Actual management runner terminates.'
        $resultText=[IO.File]::ReadAllText($resultFile)
        if ($process.ExitCode -ne 0 -or -not ($resultText|ConvertFrom-Json).success) {
            Write-Host ('Runner diagnostic (sanitized): '+[string]($resultText|ConvertFrom-Json).message)
        }
        Check ($process.ExitCode -eq 0 -and ($resultText|ConvertFrom-Json).success) 'UI runner and real core management protocol integrate.'
        Check (-not $resultText.Contains('FAKE_RUNNER_SECRET_LOCAL_TEST_ONLY')) 'Actual core runner result contains no secret.'
        Check (@((Read-ProfileRegistry $s).profiles|Where-Object displayName -eq $name).Count -eq 1) 'Actual core stdin preserves Unicode profile names.'
    } finally { $process.Dispose() }
    Write-Host 'Profile management tests passed.'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith($parent+'\profile-management-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup.' }
    if(Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
