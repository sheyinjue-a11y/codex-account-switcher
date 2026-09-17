[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$root=Join-Path $parent ('enrollment-test-'+[guid]::NewGuid().ToString('N'))
function Check($Value,$Message) { if(-not $Value){throw "FAIL: $Message"}; Write-Host "PASS: $Message" }
function Reject([scriptblock]$Action,$Message) { $failed=$false; try{ & $Action | Out-Null }catch{$failed=$true}; Check $failed $Message }
try {
    . (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
    $s=[pscustomobject]@{CanonicalHome=(Join-Path $root 'shared');VaultRoot=(Join-Path $root 'vault');TestMode=$true;SkipProcessCheck=$true;SimulateBusy=$false;SkipCodexStatus=$true;SkipLaunch=$true}
    foreach($p in @($s.CanonicalHome,$s.VaultRoot)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    $r=Add-ProfileRecord (New-ProfileRegistry $s.CanonicalHome) 'Original API' responses_api
    Write-ProfileRegistry $s $r; Write-ProfileState $s $r.profiles[0].id 1
    $exe=Join-Path $root 'fake-codex.exe'
    Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public class FakeLogin {
 public static int Main(string[] args) {
  if(args.Length != 1 || args[0] != "login") return 31;
  foreach(var name in new[]{"OPENAI_API_KEY","CODEX_API_KEY","CODEX_ACCESS_TOKEN","OPENAI_BASE_URL","CODEX_SQLITE_HOME","CODEX_APP_SERVER_CHATGPT_BASE_URL"})
   if(!String.IsNullOrEmpty(Environment.GetEnvironmentVariable(name))) return 32;
  string home=Environment.GetEnvironmentVariable("CODEX_HOME");
  string fixture=Environment.GetEnvironmentVariable("CODEX_LOGIN_FIXTURE");
  if(fixture=="cancel") { Thread.Sleep(30000); return 33; }
  if(fixture=="fail") { Console.Error.WriteLine("FAKE_SECRET_LOCAL_TEST_ONLY"); return 34; }
  if(fixture=="missing") return 0;
  File.Copy(fixture,Path.Combine(home,"auth.json")); return 0;
 }
}
'@
    $fixture=Join-Path $root 'fixture.json'
    Write-AtomicText $fixture '{"auth_mode":"chatgpt","tokens":{"account_id":"FAKE_OAUTH_ONE_LOCAL_TEST_ONLY","access_token":"FAKE_ACCESS_LOCAL_TEST_ONLY","refresh_token":"FAKE_REFRESH_LOCAL_TEST_ONLY"}}'
    $oldFixture=$env:CODEX_LOGIN_FIXTURE; $env:CODEX_LOGIN_FIXTURE=$fixture
    $oldKey=$env:OPENAI_API_KEY; $env:OPENAI_API_KEY='FAKE_INHERITED_LOCAL_TEST_ONLY'
    $p=Add-ChatGPTProfile $s 'OAuth One' $exe
    Check ($p.kind -eq 'chatgpt') 'Browser login imports isolated OAuth credentials and clears overrides.'
    Check (-not (Test-Path (Join-Path $s.VaultRoot 'staging'))) 'Successful login removes staging.'
    Check ((Read-ProfileState $s).activeProfileId -eq $r.profiles[0].id) 'Enrollment does not change active profile.'
    Reject { Add-ChatGPTProfile $s 'Duplicate' $exe } 'Duplicate account cannot be enrolled twice.'
    $null=Update-ChatGPTLogin $s $p.id $exe
    $hash=(Get-FileHash (Get-ProfileSecretPath $s $p.id auth)).Hash
    Write-AtomicText $fixture '{"auth_mode":"chatgpt","tokens":{"account_id":"FAKE_OTHER_LOCAL_TEST_ONLY","access_token":"FAKE_ACCESS_LOCAL_TEST_ONLY","refresh_token":"FAKE_REFRESH_LOCAL_TEST_ONLY"}}'
    Reject { Update-ChatGPTLogin $s $p.id $exe } 'Re-login rejects a different account.'
    Check ((Get-FileHash (Get-ProfileSecretPath $s $p.id auth)).Hash -eq $hash) 'Failed re-login preserves encrypted credentials.'
    Write-AtomicText $fixture '{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_API_LOCAL_TEST_ONLY"}'
    Reject { Add-ChatGPTProfile $s 'Wrong kind' $exe } 'API auth cannot masquerade as OAuth.'
    foreach($mode in @('fail','missing')) {
        $env:CODEX_LOGIN_FIXTURE=$mode
        Reject { Add-ChatGPTProfile $s 'Failure' $exe } "Login $mode is rejected."
        Check (-not(Test-Path(Join-Path $s.VaultRoot 'staging'))) 'Failure removes staging.'
    }
    $env:CODEX_LOGIN_FIXTURE='cancel'
    $marker=Join-Path $parent ('codex-enrollment-cancel-'+[guid]::NewGuid().ToString('N')+'.flag')
    Write-AtomicText $marker 'cancel'
    try { Reject { Add-ChatGPTProfile $s 'Cancel' $exe -CancelPath $marker } 'Cancellation stops only the isolated login.' }
    finally { Remove-Item -LiteralPath $marker -Force }
    Check (-not(Test-Path(Join-Path $s.VaultRoot 'staging'))) 'Cancellation removes staging.'
    Write-Host 'ChatGPT enrollment tests passed.'
} finally {
    if (Get-Variable oldFixture -ErrorAction SilentlyContinue) { $env:CODEX_LOGIN_FIXTURE=$oldFixture }
    if (Get-Variable oldKey -ErrorAction SilentlyContinue) { $env:OPENAI_API_KEY=$oldKey }
    if (-not [IO.Path]::GetFullPath($root).StartsWith($parent+'\enrollment-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup.' }
    if(Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
