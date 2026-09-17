[CmdletBinding()]
param([string]$Name='codex-account-switcher')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,79}$') { throw 'Use a simple lowercase distribution name.' }
$repo=Split-Path -Parent $PSScriptRoot
$destination=Join-Path (Join-Path $repo 'dist') $Name
$zip=$destination+'.zip'
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $zip)) { throw 'Distribution already exists; choose a new -Name. Nothing overwritten.' }
$rootFiles=@('README.md','LICENSE','SECURITY.md','CONTRIBUTING.md','requirements-test.txt','Setup.cmd','Start.cmd','Login.cmd','.gitignore','.github/workflows/windows-tests.yml','scripts/Export-PublicRelease.ps1')
$rootFiles+=@('assets/readme-banner.svg','assets/account-picker.png')
$toolFiles=@(
    'AccountPicker.xaml','ProfileRegistry.ps1','ProfileManagement.ps1','ProfileDialogs.ps1',
    'Switch-ChatGPTAccount.ps1','Invoke-ChatGPTSwitch.ps1','Start-ChatGPT.ps1','Start-ChatGPT.vbs','Setup-Switcher.ps1','Complete-Install.cmd',
    'Test-All.ps1','Test-FreshInstall.ps1','Test-ProfileRegistry.ps1','Test-MultiProfileMigration.ps1','Test-ProfileManagement.ps1',
    'Test-IdentityDrift.ps1','Test-ChatGPTEnrollment.ps1','Test-PickerRunner.ps1','Test-AccountPicker.ps1','Test-AccountPickerDescendant.ps1',
    'Test-AccountSwitcher.ps1','Test-ProviderSwitcher.ps1','Test-Recovery.ps1','Test-MultiProfileRecovery.ps1','Test-SharedSessions.py'
)
$files=@($rootFiles)+@($toolFiles | ForEach-Object { 'tools/chatgpt-account-switch/'+$_ })
# Scan only explicitly selected project files, never the user's auth or history.
foreach($relative in $files) {
    $path=Join-Path $repo $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing release file: $relative" }
    if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Release file is a link: $relative" }
    # PNG is a reviewed, synthetic UI preview, not a text source file.
    if ([IO.Path]::GetExtension($path) -eq '.png') { continue }
    $content=[IO.File]::ReadAllText($path)
    foreach($privatePath in @([Environment]::GetFolderPath('UserProfile'),$repo)) {
        if ($privatePath -and $content.IndexOf($privatePath,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Machine-specific path found in $relative" }
    }
    if ($content -match '(?i)\bsk-[a-z0-9_-]{20,}|\bgh[pousr]_[a-z0-9]{30,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----') { throw "Possible credential in $relative; publication stopped." }
}
foreach($relative in $files) {
    $target=Join-Path $destination $relative
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
    Copy-Item -LiteralPath (Join-Path $repo $relative) -Destination $target
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($destination,$zip)
Write-Host "Sanitized release: $destination"
Write-Host "ZIP: $zip"
Write-Host ("Files: {0}; SHA256: {1}" -f $files.Count,(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash)
