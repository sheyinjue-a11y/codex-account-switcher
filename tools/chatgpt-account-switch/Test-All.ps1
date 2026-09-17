[CmdletBinding()]
param([switch]$SkipSharedSessions)
$ErrorActionPreference='Stop'
$tests=@('Test-ProfileRegistry.ps1','Test-FreshInstall.ps1','Test-MultiProfileMigration.ps1','Test-ProfileManagement.ps1','Test-IdentityDrift.ps1','Test-ChatGPTEnrollment.ps1','Test-PickerRunner.ps1','Test-AccountPicker.ps1','Test-AccountSwitcher.ps1','Test-ProviderSwitcher.ps1','Test-Recovery.ps1','Test-MultiProfileRecovery.ps1')
foreach($test in $tests) {
    & powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
    if($LASTEXITCODE -ne 0) { throw "Test failed: $test (exit $LASTEXITCODE)." }
}
if(-not $SkipSharedSessions) {
    & python (Join-Path $PSScriptRoot 'Test-SharedSessions.py')
    if($LASTEXITCODE -ne 0) { throw 'Shared session backend test failed.' }
}
Write-Host 'All requested offline test suites passed.'
