[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-ChatGPT.ps1') -LoadOnly
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('FAIL: ' + $Message) }; Write-Host ('PASS: ' + $Message) }
function Complete($Job) {
    if (-not $Job.Process.WaitForExit(10000)) { throw 'Fake runner timed out.' }
    $text = [IO.File]::ReadAllText($Job.OutputPath)
    Check (-not $text.Contains('fake-secret-key')) 'Result file never includes the API key.'
    $result = $text | ConvertFrom-Json
    Remove-Item -LiteralPath $Job.OutputPath -Force
    $Job.Process.Dispose()
    return $result
}
$parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$root = Join-Path $parent ('picker-runner-test-' + [guid]::NewGuid().ToString('N'))
$originalInputEncoding = [Console]::InputEncoding
try {
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($true)
    $null = New-Item -ItemType Directory -Path $root
    $fake = Join-Path $root 'fake switcher.ps1'
    [IO.File]::WriteAllText($fake, @'
param([string]$ProfileId, [switch]$Initialize, [switch]$StatusJson, [switch]$ManageStdin)
if ($StatusJson) {
    @{registrySchema=2;activeProfileId='personal';apiKey='fake-secret-key';profiles=@(@{id='personal';displayName='Personal';kind='chatgpt';sortOrder=0;status='ready';host='';model='';apiKey='fake-secret-key'})} | ConvertTo-Json -Depth 6
    return
}
if ($ManageStdin) {
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if ($request.action -eq 'test_api') { @{success=$false;message='fake-secret-key'} | ConvertTo-Json; return }
    if ($request.action -eq 'busy') { throw 'Close all ChatGPT and Codex processes before managing profiles.' }
    if ($request.action -eq 'add_api') {
        if ($request.apiKey -ne 'fake-secret-key') { throw 'Key missing.' }
        if ($request.displayName -ne ([string][char]0x6d4b + [char]0x8bd5)) { throw 'Name encoding failed.' }
        Write-Host 'fake-secret-key'; Write-Warning 'fake-secret-key'; Write-Output 'fake-secret-key'
        return
    }
    throw ('Invalid Base URL contains ' + $request.apiKey)
}
if ($Initialize) { return }
if ($ProfileId -ne 'personal') { throw 'Wrong profile.' }
'@, (New-Object Text.UTF8Encoding($false)))
    $request = @{action='add_api';displayName=([string][char]0x6d4b + [char]0x8bd5);baseUrl='https://example.test/v1';apiKey='fake-secret-key';model='test'}
    $job = Start-PickerSwitch -Action Manage -ScriptPath $fake -Request $request
    Check (-not $job.Process.StartInfo.Arguments.Contains('fake-secret-key')) 'API key is not in process arguments.'
    $result = Complete $job
    Check $result.success 'Manage reads stdin once and preserves Unicode names.'
    $request.action = 'invalid'
    $result = Complete (Start-PickerSwitch -Action Manage -ScriptPath $fake -Request $request)
    Check (-not $result.success) 'Management exception produces a failure result.'
    Check ($result.message.Contains('Base URL')) 'Known field errors have a safe actionable message.'
    $request.action = 'busy'
    $result = Complete (Start-PickerSwitch -Action Manage -ScriptPath $fake -Request $request)
    Check (-not $result.success -and $result.message.Contains('Codex CLI')) 'Safe core busy errors tell the user which apps to close.'
    $request.action = 'test_api'
    $result = Complete (Start-PickerSwitch -Action Manage -ScriptPath $fake -Request $request)
    Check (-not $result.success) 'A negative connection result is not reported as a successful test.'
    $result = Complete (Start-PickerSwitch -Action List -ScriptPath $fake)
    Check ($result.success -and $result.data.profiles.Count -eq 1) 'List returns the public profile schema.'
    Check ($null -eq $result.data.profiles[0].PSObject.Properties['apiKey']) 'Unexpected secret fields are stripped from List.'
    Check (Complete (Start-PickerSwitch -Action Switch -ProfileId personal -ScriptPath $fake)).success 'Switch forwards the profile ID.'
    Check (Complete (Start-PickerSwitch -Action Repair -ScriptPath $fake)).success 'Repair forwards Initialize.'
    Write-Host 'Runner tests passed with TEMP-only fake credentials.'
} finally {
    [Console]::InputEncoding = $originalInputEncoding
    $resolved = [IO.Path]::GetFullPath($root).TrimEnd('\')
    if (-not $resolved.StartsWith($parent + '\picker-runner-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
