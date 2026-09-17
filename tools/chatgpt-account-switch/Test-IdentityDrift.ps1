[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$root=Join-Path $parent ('identity-drift-test-'+[guid]::NewGuid().ToString('N'))
function Check($Value,$Message) { if (-not $Value) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action,$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Message }
function New-OAuthBytes([string]$AccountId) {
    return [Text.Encoding]::UTF8.GetBytes((@{auth_mode='chatgpt';tokens=@{access_token='FAKE_ACCESS_LOCAL_TEST_ONLY';refresh_token='FAKE_REFRESH_LOCAL_TEST_ONLY';account_id=$AccountId}}|ConvertTo-Json -Compress))
}
try {
    . (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
    $s=[pscustomobject]@{CanonicalHome=(Join-Path $root 'shared');VaultRoot=(Join-Path $root 'vault');LabHome=(Join-Path $root 'lab');ShareHome=(Join-Path $root 'old');BackupRoot=(Join-Path $root 'backup');TestRoot=$root;TestMode=$true;SkipProcessCheck=$true;SimulateBusy=$false;SkipCodexStatus=$true;SkipLaunch=$true}
    foreach($path in @($s.CanonicalHome,$s.VaultRoot)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    Write-ProfileRegistry $s (New-ProfileRegistry $s.CanonicalHome)
    Write-ProfileState $s 'personal' 1
    $bytesA=New-OAuthBytes 'FAKE_ACCOUNT_ONE_LOCAL_TEST_ONLY'
    $bytesB=New-OAuthBytes 'FAKE_ACCOUNT_TWO_LOCAL_TEST_ONLY'
    $bytesUnknown=New-OAuthBytes 'FAKE_ACCOUNT_THREE_LOCAL_TEST_ONLY'
    # Two ChatGPT profiles; state names the second while auth.json already holds
    # the first, exactly as after a re-login that did not update the state file.
    $profileB=Import-ChatGPTCredential $s 'Account Two' $bytesB
    $profileA=Import-ChatGPTCredential $s 'Account One' $bytesA
    Write-ProfileState $s $profileB.id 7
    Write-AtomicBytes (Join-Path $s.CanonicalHome 'auth.json') $bytesA
    Write-AtomicText (Join-Path $s.CanonicalHome 'config.toml') "model_provider = `"openai`"`r`ncli_auth_credentials_store = `"file`"`r`n"
    try {
        $drift=Get-ProfileStatus $s
        Check ($drift.activeIdentityMismatch -eq $true) 'Drifted state is reported instead of breaking the profile list.'
        Check ($drift.profiles.Count -eq 2) 'Every profile is still listed while the active profile drifted.'
        $listed=@($drift.profiles|Where-Object id -eq $profileB.id)[0]
        Check ($listed.status -eq 'NeedsRepair') 'The drifted active profile is marked for repair.'
        $other=@($drift.profiles|Where-Object id -eq $profileA.id)[0]
        Check ($other.status -eq 'Ready') 'Matching profiles stay usable while the active profile drifted.'
        $storedB=Read-ProfileAuth $s (Get-ProfileById (Read-ProfileRegistry $s) $profileB.id)
        [Array]::Clear($storedB,0,$storedB.Length)
        # Switching to the account that is actually signed in must succeed and
        # realign state.json instead of failing with an identity mismatch.
        Invoke-ProfileSwitch $s $profileA.id -DoNotLaunch
        Check ((Read-ProfileState $s).activeProfileId -eq $profileA.id) 'Switching to the signed-in account realigns the recorded active profile.'
        Check ((Read-ProfileState $s).generation -eq 8) 'State realignment advances the generation.'
        $fingerA=Get-ChatGPTIdentityFingerprint ([IO.File]::ReadAllBytes((Join-Path $s.CanonicalHome 'auth.json')))
        $storedA=Read-ProfileAuth $s (Get-ProfileById (Read-ProfileRegistry $s) $profileA.id)
        try { Check ((Get-ChatGPTIdentityFingerprint $storedA) -eq $fingerA) 'Realignment keeps the shared credential identical.' }
        finally { [Array]::Clear($storedA,0,$storedA.Length) }
        $storedB=Read-ProfileAuth $s (Get-ProfileById (Read-ProfileRegistry $s) $profileB.id)
        try { Check ((Get-ChatGPTIdentityFingerprint $storedB) -eq (Get-ChatGPTIdentityFingerprint $bytesB)) 'Realignment never overwrites another stored profile.' }
        finally { [Array]::Clear($storedB,0,$storedB.Length) }
        $drift=Get-ProfileStatus $s
        Check (-not $drift.activeIdentityMismatch) 'Status clears the mismatch flag after realignment.'
        # Repair has to clear the same drift rather than aborting.
        Write-ProfileState $s $profileB.id 9
        $null=Initialize-MultiProfileSwitcher $s
        Check ((Read-ProfileState $s).activeProfileId -eq $profileA.id) 'Repair realigns a drifted active profile.'
        Check (-not (Test-Path (Join-Path $s.VaultRoot 'pending-management.dpapi'))) 'Repair leaves no pending transaction behind.'
        # Credentials that belong to no profile must still be rejected.
        Write-ProfileState $s $profileB.id 10
        Write-AtomicBytes (Join-Path $s.CanonicalHome 'auth.json') $bytesUnknown
        Reject { Invoke-ProfileSwitch $s $profileB.id -DoNotLaunch } 'Unknown signed-in credentials are refused instead of being adopted.'
        Check ((Read-ProfileState $s).activeProfileId -eq $profileB.id) 'A refused switch leaves the recorded active profile untouched.'
        $drift=Get-ProfileStatus $s
        Check ($drift.activeIdentityMismatch -eq $true) 'A refused switch keeps reporting the drift for repair.'
        Write-Host 'Identity drift tests passed.'
    } finally {
        [Array]::Clear($bytesA,0,$bytesA.Length)
        [Array]::Clear($bytesB,0,$bytesB.Length)
        [Array]::Clear($bytesUnknown,0,$bytesUnknown.Length)
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith($parent+'\identity-drift-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup.' }
    if(Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
