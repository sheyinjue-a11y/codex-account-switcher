[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-ChatGPT.ps1') -LoadOnly
function Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
function Click($Control) { $Control.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) }
function Pump-UntilIdle($State) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($State.Busy -and [DateTime]::UtcNow -lt $deadline) {
        $frame = New-Object Windows.Threading.DispatcherFrame
        $stop = New-Object Windows.Threading.DispatcherTimer; $stop.Interval = [TimeSpan]::FromMilliseconds(30)
        $stop.Add_Tick(({ $frame.Continue = $false }.GetNewClosure())); $stop.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame); $stop.Stop()
    }
    Check (-not $State.Busy) 'The window responds when the child process finishes.'
}
$testParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $testParent ('account-picker-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)
try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $fake = Join-Path $testRoot 'fake switcher.ps1'
    [IO.File]::WriteAllText($fake, @'
param([string]$ProfileId, [switch]$Initialize, [switch]$StatusJson, [switch]$ManageStdin)
if ($StatusJson) {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'legacy.flag')) { @{registrySchema=1;activeProfileId='';profiles=@()} | ConvertTo-Json; return }
    $profiles = @(
        @{id='personal';displayName='Personal';kind='chatgpt';sortOrder=0;status='ready';host='';model=''},
        @{id='lab';displayName='Lab';kind='responses_api';sortOrder=1;status='ready';host='example.test';baseUrl='https://example.test/v1';model='test-model'}
    )
    1..9 | ForEach-Object { $profiles += @{id=('{0:x32}' -f $_);displayName=('Profile ' + $_);kind='chatgpt';sortOrder=($_ + 1);status='ready';host='';model=''} }
    @{registrySchema=2;activeProfileId='personal';profiles=$profiles} | ConvertTo-Json -Depth 8
    return
}
if ($ManageStdin) {
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if ($request.action -eq 'add_chatgpt') {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $request.cancelPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 30 }
        throw 'Enrollment cancelled.'
    }
    return
}
if ($Initialize) { [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'selection.txt'), 'Initialize'); return }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'selection.txt'), $ProfileId)
Start-Sleep -Milliseconds 200
if ($ProfileId -eq 'lab') { throw 'Account switching requires all ChatGPT and Codex processes to exit. Running: codex.exe(123)' }
'@, $utf8)
    $picker = New-AccountPicker
    $state = Connect-AccountPicker -Window $picker -SwitcherPath $fake
    Click $picker.FindName('CancelButton')
    Check (-not (Test-Path -LiteralPath (Join-Path $testRoot 'selection.txt'))) 'Cancel does not run a switcher.'
    $picker = New-AccountPicker
    $state = Connect-AccountPicker -Window $picker -SwitcherPath $fake -LoadProfiles
    Pump-UntilIdle $state
    Check ($picker.Tag.Cards.Count -eq 11) 'List renders every profile dynamically.'
    Check ($picker.FindName('ProfileScroll').VerticalScrollBarVisibility -eq 'Auto') 'Long profile lists scroll.'
    Check (-not $picker.Tag.Cards.personal.Items.delete.IsEnabled) 'Current profile cannot be deleted.'
    Check ($picker.Tag.Cards.lab.Items.delete.IsEnabled) 'A noncurrent profile exposes Delete.'
    Check ($picker.Tag.Cards.lab.Items.ContainsKey('update_api')) 'API card exposes Edit.'
    Check ($picker.Tag.Cards.personal.Items.ContainsKey('relogin')) 'ChatGPT card exposes Relogin.'
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'ChatGPT-Official.ico')) {
        Check ($null -ne $picker.Icon) 'Existing local icon is retained.'
    } else {
        Check ($null -eq $picker.Icon) 'Public package works without proprietary artwork.'
    }
    [IO.File]::WriteAllText((Join-Path $testRoot 'legacy.flag'), 'legacy')
    $migrationPicker = New-AccountPicker
    $migrationState = Connect-AccountPicker -Window $migrationPicker -SwitcherPath $fake -LoadProfiles
    Pump-UntilIdle $migrationState
    Check ($migrationPicker.Tag.Cards.Count -eq 0) 'An unmigrated installation does not fabricate profiles.'
    Check ($migrationPicker.FindName('StatusText').Text.Contains([char]0x8fc1)) 'Schema 1 list gives an explicit migration instruction.'
    Check ($migrationPicker.FindName('RepairButton').IsEnabled) 'Repair remains available to migrate the legacy installation.'
    $migrationPicker.Close()
    Remove-Item -LiteralPath (Join-Path $testRoot 'legacy.flag') -Force
    Click $picker.FindName('LabButton')
    Check $state.Busy 'Selection starts work without blocking the UI.'
    Check (-not $picker.FindName('PersonalButton').IsEnabled) 'Other selections are disabled during switching.'
    Check (-not $picker.FindName('AddButton').IsEnabled) 'Add is disabled during switching.'
    Check (-not $picker.Tag.Cards.lab.Menu.IsEnabled) 'Card management is disabled during switching.'
    Check (-not $picker.FindName('RepairButton').IsEnabled) 'Repair cannot run concurrently with switching.'
    Pump-UntilIdle $state
    Check ([IO.File]::ReadAllText((Join-Path $testRoot 'selection.txt')) -eq 'lab') 'Card passes its stable ID through the child process.'
    Check ($picker.FindName('ErrorDetails').Visibility -eq 'Visible') 'Failure stays visible with copyable error details.'
    Check ($picker.FindName('PersonalButton').IsEnabled) 'Failure re-enables the account choices.'
    Check ($picker.FindName('StatusText').Text.Contains('Codex CLI')) 'Active-app error gives a specific exit-and-retry instruction.'
    Check ($picker.FindName('RetryButton').Visibility -eq 'Visible') 'Failed switch exposes Retry.'
    Click $picker.FindName('RepairButton'); Pump-UntilIdle $state
    Check ([IO.File]::ReadAllText((Join-Path $testRoot 'selection.txt')) -eq 'Initialize') 'Repair invokes Initialize without selecting an account.'
    Check ($picker.Tag.Cards.Count -eq 11) 'Repair reloads the profile list.'
    & $state.Begin 'Manage' '' @{action='add_chatgpt';displayName='Cancelled account'}
    $cancelPath = $state.CancelPath
    Check ($picker.FindName('CancelLoginButton').Visibility -eq 'Visible') 'OAuth exposes a cooperative cancel action.'
    Click $picker.FindName('CancelLoginButton'); Pump-UntilIdle $state
    Check (-not (Test-Path -LiteralPath $cancelPath)) 'Cancellation flag is cleaned after enrollment exits.'
    Check ($picker.FindName('AddButton').IsEnabled) 'Cancelled login re-enables management.'
    $api = $picker.Tag.Status.profiles | Where-Object id -eq 'lab'
    $dialog = New-ProfileDialog -Action update_api -Profile $api
    Check ($dialog.FindName('KeyInput') -is [Windows.Controls.PasswordBox]) 'API key uses PasswordBox.'
    Check ($dialog.FindName('BaseUrlInput').Text -eq 'https://example.test/v1') 'Edit prefills the nonsecret Base URL.'
    Check ($dialog.FindName('ModelInput').Text -eq 'test-model') 'Edit prefills the model.'
    $request = Get-ProfileDialogRequest -Window $dialog
    Check ($request.apiKey -eq '') 'Blank edit key preserves the existing key through the management contract.'
    Check ($request.action -eq 'update_api') 'Saving does not force a network test.'
    $testRequest = Get-ProfileDialogRequest -Window $dialog -TestConnection
    Check ($testRequest.action -eq 'test_api' -and $testRequest.confirmCost) 'Explicit connection test carries cost confirmation.'
    $dialog.Close()
    Click $picker.FindName('PersonalButton'); Pump-UntilIdle $state
    Check ([IO.File]::ReadAllText((Join-Path $testRoot 'selection.txt')) -eq 'personal') 'A subsequent selection succeeds after failure and cancellation.'
    $handleFake = Join-Path $testRoot 'handle switcher.ps1'
    [IO.File]::WriteAllText($handleFake, @'
param([string]$ProfileId)
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = (Join-Path $PSHOME 'powershell.exe')
$info.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 8"'
$info.UseShellExecute = $false
$sleeper = [Diagnostics.Process]::Start($info)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'sleeper.pid'), [string]$sleeper.Id)
'@, $utf8)
    $workerInfo = New-Object Diagnostics.ProcessStartInfo
    $workerInfo.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $workerInfo.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'Test-AccountPickerDescendant.ps1') + '" -Launcher "' + (Join-Path $PSScriptRoot 'Start-ChatGPT.ps1') + '" -FakeSwitcher "' + $handleFake + '"'
    $workerInfo.UseShellExecute = $false; $workerInfo.CreateNoWindow = $true
    $worker = [Diagnostics.Process]::Start($workerInfo)
    $completed = $worker.WaitForExit(4500)
    if (-not $completed) { $worker.Kill(); $worker.WaitForExit() }
    $sleeperPath = Join-Path $testRoot 'sleeper.pid'
    if (Test-Path -LiteralPath $sleeperPath) { Stop-Process -Id ([int][IO.File]::ReadAllText($sleeperPath)) -Force -ErrorAction SilentlyContinue }
    Check $completed 'Picker finishes even when a launched descendant keeps standard handles open.'
    Check ($worker.ExitCode -eq 0) 'Descendant-handle case returns success.'
    $worker.Dispose()
    Write-Host 'Account picker tests passed. Real credentials and switcher were not used.'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    if (-not $resolved.StartsWith($testParent + '\account-picker-test-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
