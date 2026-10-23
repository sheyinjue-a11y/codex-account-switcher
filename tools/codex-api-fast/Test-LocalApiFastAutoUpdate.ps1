$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-LocalApiFastClient.ps1')
function Check($Condition, $Message) { if (-not $Condition) { throw ('FAIL: ' + $Message) }; Write-Host ('PASS: ' + $Message) }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-fast-auto-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$script:builds = 0
$script:valid = $false
$script:api = $true
$script:fail = $false
$script:packageName = 'version-one'
$script:engine = 'engine-one'
function Get-LocalApiFastRoot { return $fixture }
function Test-LocalFastApiLogin { return $script:api }
function Get-AppxPackage { param($Name) return [pscustomobject]@{PackageFullName=$script:packageName;Version='1.2.3.4'} }
function Get-LocalFastBuildKey($Package, $Settings) { return ($Package.PackageFullName + $script:engine) }
function Get-LocalApiFastInstallation { if ($script:valid) { return [pscustomobject]@{directory='fixture'} }; return $null }
function Invoke-LocalFastAutoBuild($Settings) {
    $script:builds++
    if ($script:fail) { throw 'Unsupported fixture structure' }
    $script:valid = $true
}
try {
    Check ($null -eq (Resolve-LocalApiFastInstallation) -and $script:builds -eq 0) 'Without opt-in there is no automatic installation.'
    $settings = @{schemaVersion=1;enabled=$true;nodePath='fixture-node';modulePath='fixture-modules'}
    Write-LocalFastJson (Join-Path $fixture 'auto-update.json') $settings
    $script:api = $false
    Check ($null -eq (Resolve-LocalApiFastInstallation) -and $script:builds -eq 0) 'Personal authentication does not build or use the automatic API client.'
    $script:api = $true
    Check ((Resolve-LocalApiFastInstallation).directory -eq 'fixture' -and $script:builds -eq 1) 'A missing API installation is built and verified before use.'
    Check ((Resolve-LocalApiFastInstallation).directory -eq 'fixture' -and $script:builds -eq 1) 'A valid installation is reused without invoking the builder.'
    $script:valid = $false
    $script:packageName = 'version-two'
    Check ((Resolve-LocalApiFastInstallation).directory -eq 'fixture' -and $script:builds -eq 2) 'A changed official package is automatically rebuilt.'
    $script:valid = $false; $script:fail = $true
    $failed = $false
    try { Resolve-LocalApiFastInstallation | Out-Null } catch { $failed = $_.Exception.Message -match 'Unsupported fixture structure' }
    Check ($failed -and $script:builds -eq 3 -and (Read-LocalFastJson (Join-Path $fixture 'auto-update-status.json')).status -eq 'failed') 'Unknown structure is recorded and never reported as a successful build.'
    $failed = $false
    try { Resolve-LocalApiFastInstallation | Out-Null } catch { $failed = $_.Exception.Message -match 'previously failed' }
    Check ($failed -and $script:builds -eq 3) 'The same failure does not repeatedly rebuild at every launch.'
    $script:engine = 'engine-two'; $script:fail = $false
    Check ((Resolve-LocalApiFastInstallation).directory -eq 'fixture' -and $script:builds -eq 4) 'Updated patch tools automatically retry a previously failed package.'
    $held = Enter-LocalFastUpdateLock $fixture
    try {
        $failed = $false
        try { Enter-LocalFastUpdateLock $fixture 0 | Out-Null } catch { $failed = $_.Exception.Message -match 'still running' }
        Check $failed 'A second updater cannot acquire the exclusive file lock.'
    } finally { $held.Dispose() }
    $script:valid = $false
    $settings.enabled = $false
    Write-LocalFastJson (Join-Path $fixture 'auto-update.json') $settings
    Check ($null -eq (Resolve-LocalApiFastInstallation) -and $script:builds -eq 4) 'Disabling automatic adaptation prevents rebuilding.'
    $settings.enabled = $true
    Write-LocalFastJson (Join-Path $fixture 'auto-update.json') $settings
    function Get-LocalApiFastInstallation { if ($script:valid) { return [pscustomobject]@{directory='fixture'} }; throw 'Local Fast integrity mismatch' }
    Check ((Resolve-LocalApiFastInstallation).directory -eq 'fixture' -and $script:builds -eq 5) 'A rejected installation is repaired before use.'
    # Reload only the implementation under test, retaining fixture root/auth mocks.
    . (Join-Path $PSScriptRoot 'Auto-LocalApiFastClient.ps1')
    $failed = $false
    try { Invoke-LocalFastAutoBuild ([pscustomobject]@{nodePath=(Join-Path $fixture 'missing-node.exe');modulePath=$fixture}) } catch { $failed = $_.Exception.Message -match 'Node.js is missing' }
    Check $failed 'A missing dependency produces an actionable error without attempting installation.'
    $first = Get-LocalFastBuildKey ([pscustomobject]@{PackageFullName='test'}) ([pscustomobject]@{nodePath=(Join-Path $fixture 'node');modulePath=$fixture})
    [IO.File]::WriteAllText((Join-Path $fixture 'node'), 'restored-runtime')
    $second = Get-LocalFastBuildKey ([pscustomobject]@{PackageFullName='test'}) ([pscustomobject]@{nodePath=(Join-Path $fixture 'node');modulePath=$fixture})
    Check ($first -ne $second) 'Restoring a dependency invalidates a cached failed attempt.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-fast-auto-test-*') { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
