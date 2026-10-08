[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Open-Switcher.ps1') -LoadOnly
function Check($Value, $Message) { if (-not $Value) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
Check ((Get-FirstRunStep $true $true $true $true $false) -eq 'Ready') 'Existing users open the account list directly.'
Check ((Get-FirstRunStep $true $true $false $true $false) -eq 'Import') 'First launch with an existing login enters import.'
Check ((Get-FirstRunStep $true $true $false $false $false) -eq 'Login') 'A fresh computer enters browser login guidance.'
Check ((Get-FirstRunStep $false $false $false $false $false) -eq 'InstallApp') 'Missing official application has an actionable first step.'
Check ((Get-FirstRunStep $true $false $false $false $false) -eq 'InstallCli') 'A missing login component never reports ready.'
Check ((Get-FirstRunStep $true $true $true $true $true) -eq 'CustomHome') 'Custom homes do not silently enter the default vault.'
$window = New-FirstRunWindow
foreach ($name in @('Heading','Detail','Continue','Refresh','Progress')) { Check ($null -ne $window.FindName($name)) "First-run window contains $name." }
$window.Close()
$picker = New-AccountPicker
Check ($null -ne $picker.FindName('SettingsButton')) 'Optional features have an in-app entry.'
$null = Connect-AccountPicker -Window $picker -SwitcherPath (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1')
Check ($picker.FindName('SettingsButton').ContextMenu.Items.Count -eq 2) 'Settings exposes warmup and help without separate command files.'
$picker.Close()
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('one-click-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
try {
    $preview = Join-Path $testRoot 'welcome.png'
    & powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Open-Switcher.ps1') -PreviewPath $preview
    Check ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $preview)) 'The actual startup entry executes instead of inheriting its library LoadOnly flag.'
    $script:firstRunStep = 'Import'
    $script:originalWindowFactory = ${function:New-FirstRunWindow}
    function Get-FirstRunEnvironment { return [pscustomobject]@{ Step = $script:firstRunStep; Cli = ''; CanonicalHome = $testRoot } }
    function New-FirstRunWindow {
        $window = & $script:originalWindowFactory
        $window.ShowInTaskbar = $false; $window.WindowStartupLocation = 'Manual'; $window.Left = -20000
        $window.Add_ContentRendered(({ $window.FindName('Continue').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }.GetNewClosure()))
        return $window
    }
    function Start-PickerSwitch {
        param($Action, $ScriptPath)
        Check ($Action -eq 'Repair') 'First-run import uses the existing transactional initialization path.'
        $outputPath = Join-Path $testRoot 'result.json'
        [IO.File]::WriteAllText($outputPath, '{"success":true,"message":"fixture"}')
        $process = [pscustomobject]@{ HasExited = $true; ExitCode = 0 }
        $process | Add-Member ScriptMethod Dispose { }
        $script:firstRunStep = 'Ready'
        return @{ Process = $process; OutputPath = $outputPath }
    }
    Check (Show-FirstRun) 'Clicking import completes asynchronously and opens the account list.'
    Check (-not (Test-Path -LiteralPath (Join-Path $testRoot 'result.json'))) 'First-run result files are removed after completion.'
} finally {
    if ([IO.Path]::GetFileName($testRoot) -notlike 'one-click-test-*') { throw 'Unexpected fixture directory.' }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
Write-Host 'One-click UI checks passed without reading or changing real account data.'
