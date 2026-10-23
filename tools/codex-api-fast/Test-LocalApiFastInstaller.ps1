$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'LocalApiFastInstaller.ps1')
function Check($Condition, $Message) { if (-not $Condition) { throw ('FAIL: ' + $Message) }; Write-Host ('PASS: ' + $Message) }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('codex-fast-install-test-' + [guid]::NewGuid().ToString('N'))
$script:source = Join-Path $fixture 'official\app'
New-Item -ItemType Directory -Path (Join-Path $script:source 'resources') -Force | Out-Null
foreach ($name in @('ChatGPT.exe','resources\app.asar','chrome.dll')) { [IO.File]::WriteAllText((Join-Path $script:source $name), 'original-' + $name) }
$script:version = '1.2.3.4'
$script:copyCalls = 0
$script:failure = ''
function Get-LocalApiFastInstallPackage { return [pscustomobject]@{PackageFullName=('fixture-' + $script:version);Version=$script:version;InstallLocation=(Join-Path $fixture 'official')} }
function Get-LocalApiFastInstallSignature([string]$Path) {
    $subject = 'CN="OpenAI OpCo, LLC", O="OpenAI OpCo, LLC", C=US'
    if ($script:failure -eq 'signer') { $subject = 'CN=NotOpenAI, O=NotOpenAI' }
    return [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject=$subject}}
}
function Copy-LocalApiFastInstallApplication([string]$Source, [string]$Destination) {
    $script:copyCalls++
    Get-ChildItem -LiteralPath $Source | Copy-Item -Destination $Destination -Recurse
    if ($script:failure -eq 'copy') { throw 'Fixture copy failure' }
    if ($script:failure -eq 'runtime') { [IO.File]::WriteAllText((Join-Path $Destination 'chrome.dll'),'corrupted') }
}
function Invoke-LocalApiFastInstallArchive([string]$NodePath, [string]$Action, [string]$Source, [string]$Output) {
    $before = Get-LocalApiFastInstallHash $Source
    $patched = [IO.File]::ReadAllText($Source).StartsWith('patched-')
    $status = $(if ($patched) { 'patched' } else { 'patchable' })
    if ($Action -eq 'build') {
        if ($script:failure -eq 'build') { throw 'Fixture unsupported gates' }
        [IO.File]::WriteAllText($Output, 'patched-' + [IO.File]::ReadAllText($Source))
        $Source = $Output; $patched = $true; $status = 'built'
        if ($script:failure -eq 'package-change') { $script:version = '1.2.3.5' }
    }
    $roles = @('ui','request')
    if ($script:failure -eq 'gates') { $roles = @('ui') }
    return [pscustomobject]@{status=$status;archiveSha256=(Get-LocalApiFastInstallHash $Source);sourceSha256=$before;headerSha256=($(if($patched){'b'}else{'a'}) * 64);targetEntries=@([pscustomobject]@{gates=@($roles | ForEach-Object { [pscustomobject]@{role=$_;alreadyPatched=$patched} })})}
}
function Invoke-LocalApiFastInstallLauncher([string]$NodePath, [string]$Source, [string]$Output, [string]$Before, [string]$After) {
    if ($script:failure -eq 'launcher') { throw 'Fixture launcher failure' }
    [IO.File]::WriteAllText($Output,'patched-' + [IO.File]::ReadAllText($Source))
    return [pscustomobject]@{sourceSha256=(Get-LocalApiFastInstallHash $Source);sha256=(Get-LocalApiFastInstallHash $Output);oldHeaderHash=$Before;newHeaderHash=$After}
}
$writeManifest = ${function:Write-LocalApiFastInstallManifest}
function Write-LocalApiFastInstallManifest([string]$Root, [string]$Path, $Installation) {
    if ($script:failure -eq 'publish' -and $Path -eq (Join-Path $Root 'installation.json')) { throw 'Fixture publication failure' }
    & $writeManifest $Root $Path $Installation
}
try {
    $root = Join-Path $fixture 'client'
    $item = Invoke-LocalApiFastInstall -NodePath 'fixture-node' -RootPath $root
    Check ($item.version -eq '1.2.3.4' -and $script:copyCalls -eq 1) 'Build validates and publishes the current official version.'
    Check ((Test-Path -LiteralPath (Join-Path $item.directory 'installation.json')) -and (Get-Content (Join-Path $root 'installation.json') -Raw | ConvertFrom-Json).archiveSha256 -eq $item.archiveSha256) 'Version metadata and the active manifest describe the verified build.'
    $again = Invoke-LocalApiFastInstall -NodePath 'fixture-node' -RootPath $root
    Check ($script:copyCalls -eq 1 -and $again.exeSha256 -eq $item.exeSha256) 'A complete existing build is verified and reused without copying.'
    [IO.File]::WriteAllText((Join-Path $root 'installation.json'), '{"interrupted":true}')
    $again = Invoke-LocalApiFastInstall -NodePath 'fixture-node' -RootPath $root
    Check ($script:copyCalls -eq 1 -and (Get-Content (Join-Path $root 'installation.json') -Raw | ConvertFrom-Json).version -eq '1.2.3.4') 'Per-version metadata recovers an interrupted manifest publication.'
    $lock = [IO.File]::Open((Join-Path $root 'update.lock'),'OpenOrCreate','ReadWrite','None')
    try {
        $failed = $false
        try { Invoke-LocalApiFastInstall -NodePath 'fixture-node' -RootPath $root | Out-Null } catch { $failed = $_.Exception.Message -match 'already running' }
        Check $failed 'Manual and automatic installations share the exclusive lock.'
    } finally { $lock.Dispose() }
    $oldManifest = [IO.File]::ReadAllText((Join-Path $root 'installation.json'))
    foreach ($kind in @('signer','gates','copy','runtime','build','launcher','package-change','publish')) {
        $script:failure = $kind; $script:version = '2.3.4.5'
        $failed = $false
        try { Invoke-LocalApiFastInstall -NodePath 'fixture-node' -RootPath $root | Out-Null } catch { $failed = $true }
        Check ($failed -and [IO.File]::ReadAllText((Join-Path $root 'installation.json')) -ceq $oldManifest) ('Failure preserves the active manifest: ' + $kind)
    }
    $script:failure = ''; $script:version = '3.4.5.6'
    $unknown = Join-Path $root 'versions\3.4.5.6'
    New-Item -ItemType Directory -Path $unknown -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $unknown 'keep.txt'), 'user-content')
    $script:failure = 'publish'
    $failed = $false
    try { Invoke-LocalApiFastInstall -NodePath 'fixture-node' -RootPath $root | Out-Null } catch { $failed = $true }
    Check ($failed -and [IO.File]::ReadAllText((Join-Path $unknown 'keep.txt')) -eq 'user-content') 'Failed publication restores the previous directory, including unknown files.'
    $script:failure = ''
    $item = Invoke-LocalApiFastInstall -NodePath 'fixture-node' -RootPath $root
    $retained = @(Get-ChildItem -LiteralPath (Join-Path $root 'quarantine') -Filter keep.txt -Recurse)
    Check ($item.version -eq '3.4.5.6' -and $retained.Count -eq 1 -and [IO.File]::ReadAllText($retained[0].FullName) -eq 'user-content') 'Successful replacement retains the entire unknown directory in quarantine.'
    $failed = $false
    try { Assert-LocalApiFastInstallPath $root (Join-Path $root '..\outside') | Out-Null } catch { $failed = $true }
    Check $failed 'Write and move paths cannot escape the dedicated installation root.'
    Check ([IO.File]::ReadAllText((Join-Path $script:source 'ChatGPT.exe')) -eq 'original-ChatGPT.exe') 'All simulated builds leave the official source untouched.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-fast-install-test-*') { throw 'Unsafe fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
