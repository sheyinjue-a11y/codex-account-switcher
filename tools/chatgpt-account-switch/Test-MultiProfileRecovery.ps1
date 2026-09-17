[CmdletBinding()]
param([string]$WorkerSettings,[string]$Boundary,[string]$Operation,[string]$Target)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
if ($WorkerSettings) {
    $env:CODEX_SWITCHER_TEST_MODE='1'
    $worker=Get-SwitcherSettings $WorkerSettings
    $env:CODEX_SWITCHER_CRASH_POINT=$Boundary
    if ($Operation -eq 'switch') { Invoke-ProfileSwitch $worker $Target -DoNotLaunch }
    elseif($Operation -eq 'migrate') { $null=Convert-LegacyProfiles $worker }
    else { $null=Invoke-ProfileManagement $worker ([pscustomobject]@{action=$Operation;profileId=$Target;displayName='Crash API';baseUrl='https://crash.example.test/v1';model='gpt-test';apiKey='FAKE_CRASH_LOCAL_TEST_ONLY'}) }
    exit 92
}
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$root=Join-Path $parent ('multi-recovery-test-'+[guid]::NewGuid().ToString('N'))
function Check($Value,$Message) { if(-not $Value){throw "FAIL: $Message"}; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action,$Message) { $failed=$false; try{& $Action | Out-Null}catch{$failed=$true}; Check $failed $Message }
function Snapshot($Settings) {
    $map=@{}
    foreach($dir in @($Settings.CanonicalHome,$Settings.VaultRoot)) {
        foreach($file in Get-ChildItem $dir -File) {
            if($file.Name -notmatch 'audit|pending-') { $map[$file.FullName]=(Get-FileHash $file.FullName).Hash }
        }
    }
    return $map
}
try {
    $s=[pscustomobject]@{CanonicalHome=(Join-Path $root 'shared');VaultRoot=(Join-Path $root 'vault');LabHome=(Join-Path $root 'lab');ShareHome=(Join-Path $root 'old');BackupRoot=(Join-Path $root 'backup');TestRoot=$root;TestMode=$true;SkipProcessCheck=$true;SimulateBusy=$false;SkipCodexStatus=$true;SkipLaunch=$true}
    foreach($p in @($s.CanonicalHome,$s.VaultRoot)) { New-Item -ItemType Directory -Path $p -Force|Out-Null }
    $settingsPath=Join-Path $root 'settings.json'; Write-AtomicText $settingsPath ($s|ConvertTo-Json)
    $r=New-ProfileRegistry $s.CanonicalHome
    $r.profiles=@((New-FixedProfileRecord personal 'Personal' chatgpt 0),(New-FixedProfileRecord lab 'Lab' responses_api 1))
    $a=[Text.Encoding]::UTF8.GetBytes('{"auth_mode":"chatgpt","tokens":{"account_id":"FAKE_ONE_LOCAL_TEST_ONLY","access_token":"FAKE_ACCESS_LOCAL_TEST_ONLY","refresh_token":"FAKE_REFRESH_LOCAL_TEST_ONLY"}}')
    $b=[Text.Encoding]::UTF8.GetBytes('{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_API_LOCAL_TEST_ONLY"}')
    Save-ProfileCredential $s Personal $a; Save-ProfileCredential $s Lab $b
    Save-ProviderRoute $s Personal (Get-ProviderRoute 'model = "gpt-test"')
    Save-ProviderRoute $s Lab (New-ResponsesRoute 'https://lab.example.test/v1' 'gpt-test')
    Write-AtomicBytes (Join-Path $s.CanonicalHome 'auth.json') $a
    Write-AtomicText (Join-Path $s.CanonicalHome 'config.toml') "model = `"gpt-test`"`r`ncli_auth_credentials_store = `"file`"`r`n"
    Write-SwitcherState $s Personal 1
    foreach($point in @('MigrateAfterRegistry','MigrateAfterState')) {
        $before=Snapshot $s
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -WorkerSettings $settingsPath -Boundary $point -Operation migrate | Out-Null
        Check ($LASTEXITCODE -ne 0) "Migration process stopped at $point."
        Restore-AllPendingOperations $s
        foreach($path in $before.Keys) { Check ((Get-FileHash $path).Hash -eq $before[$path]) ('Restored '+[IO.Path]::GetFileName($path)) }
        Check (-not(Test-Path (Get-ProfileRegistryPath $s))) 'Interrupted migration leaves no partial registry.'
    }
    # Legacy recovery must run before migration.
    Save-SwitchRecovery $s Personal
    Write-AtomicBytes (Join-Path $s.CanonicalHome 'auth.json') $b
    $null=Convert-LegacyProfiles $s
    Check ((Read-ProfileState $s).activeProfileId -eq 'personal') 'Legacy pending switch recovered before migration.'
    foreach($point in @('AfterConfigWrite','AfterAuthWrite','AfterStateWrite')) {
        $before=Snapshot $s
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -WorkerSettings $settingsPath -Boundary $point -Operation switch -Target lab | Out-Null
        Check ($LASTEXITCODE -ne 0 -and (Test-Path (Get-TransactionPath $s switch))) "Process interrupted at $point with journal."
        $s.SimulateBusy=$true; Reject { Restore-AllPendingOperations $s } 'Busy recovery is refused.'; $s.SimulateBusy=$false
        Restore-AllPendingOperations $s
        $after=Snapshot $s
        Check ($after.Count -eq $before.Count) 'Recovery restores exact file set.'
        foreach($path in $before.Keys) { Check ($after[$path] -eq $before[$path]) ('Restored '+[IO.Path]::GetFileName($path)) }
    }
    foreach($case in @(@('add_api','AfterSecretWrite'),@('add_api','AfterRegistryWrite'),@('delete','AfterTrashMove'),@('delete','AfterRegistryWrite'))) {
        $before=Snapshot $s
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -WorkerSettings $settingsPath -Boundary $case[1] -Operation $case[0] -Target lab | Out-Null
        Check ($LASTEXITCODE -ne 0 -and (Test-Path (Get-TransactionPath $s management))) ('Management interrupted: '+($case -join '/'))
        Restore-AllPendingOperations $s
        $after=Snapshot $s
        Check ($after.Count -eq $before.Count) 'Management recovery restores exact file set.'
        foreach($path in $before.Keys) { Check ($after[$path] -eq $before[$path]) ('Restored '+[IO.Path]::GetFileName($path)) }
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -WorkerSettings $settingsPath -Boundary AfterCommitWrite -Operation rename -Target lab | Out-Null
    Restore-AllPendingOperations $s
    Check ((Get-ProfileById (Read-ProfileRegistry $s) lab).displayName -eq 'Crash API') 'Recovery preserves committed management change.'
    $registryPath=Get-ProfileRegistryPath $s; $original=[IO.File]::ReadAllBytes($registryPath)
    Write-AtomicText $registryPath '{"schemaVersion":3,"profiles":[]}'
    $before=Snapshot $s
    Reject { Invoke-ProfileSwitch $s lab -DoNotLaunch } 'Unknown schema blocks switch.'
    $after=Snapshot $s; foreach($path in $before.Keys) { Check ($before[$path] -eq $after[$path]) 'Unknown schema produces no writes.' }
    Write-AtomicBytes $registryPath $original
    # Journal keys cannot supply arbitrary paths, and validation precedes all writes.
    $journal=Get-TransactionPath $s management
    Write-ProtectedJson $journal ([pscustomobject]@{schemaVersion=2;home=$s.CanonicalHome;operationId=[guid]::NewGuid().ToString('N');operation='update';committed=$false;files=@{auth=[Convert]::ToBase64String($b);'auth:..\escape'='AA=='}})
    $before=Snapshot $s
    Reject { Restore-AllPendingOperations $s } 'Journal path injection is rejected.'
    $after=Snapshot $s; foreach($path in $before.Keys) { Check ($before[$path] -eq $after[$path]) 'Bad journal performs no partial writes.' }
    Remove-Item -LiteralPath $journal -Force
    $labPath=Get-ProfileSecretPath $s lab auth; $labBackup=[IO.File]::ReadAllBytes($labPath)
    Write-AtomicText $labPath 'FAKE_BROKEN_LOCAL_TEST_ONLY'
    Check (@((Get-ProfileStatus $s).profiles | Where-Object { $_.id -eq 'lab' -and $_.status -eq 'NeedsRepair' }).Count -eq 1) 'Damaged inactive profile is isolated.'
    Invoke-ProfileSwitch $s personal -DoNotLaunch
    Write-AtomicBytes $labPath $labBackup
    $activePath=Get-ProfileSecretPath $s personal auth; Write-AtomicText $activePath 'FAKE_BROKEN_LOCAL_TEST_ONLY'
    Reject { Invoke-ProfileSwitch $s lab -DoNotLaunch } 'Damaged active profile blocks launch and switch.'
    Write-Host 'Multi-profile crash recovery tests passed.'
} finally {
    if(-not [IO.Path]::GetFullPath($root).StartsWith($parent+'\multi-recovery-test-', [StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup.'}
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
