[CmdletBinding()]
param([string]$NodePath = (Get-Command node -ErrorAction Stop).Source)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-LocalApiFastClient.ps1')
$package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
if (-not $package) { throw 'Official Codex package is required.' }
$source = Join-Path $package.InstallLocation 'app'
$root = Get-LocalApiFastRoot
$destination = Join-Path $root ('versions\' + $package.Version.ToString())
$manifestPath = Join-Path $root 'installation.json'
if (Test-Path -LiteralPath $destination) { throw 'Version directory already exists; inspect it before rebuilding.' }
$signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $source 'ChatGPT.exe')
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'OpenAI') { throw 'Official source signature was not verified.' }
$original = & $NodePath (Join-Path $PSScriptRoot 'patch-core.cjs') inspect (Join-Path $source 'resources\app.asar')
if ($LASTEXITCODE -ne 0) { throw 'Source archive inspection failed.' }
$original = $original | ConvertFrom-Json
if ($original.status -ne 'patchable') { throw 'An unmodified official source is required.' }
New-Item -ItemType Directory -Path $destination -Force | Out-Null
& robocopy.exe $source $destination /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Copying official application failed.' }
$builtPath = Join-Path $destination 'resources\app-fast.asar'
$built = & $NodePath (Join-Path $PSScriptRoot 'patch-core.cjs') build (Join-Path $source 'resources\app.asar') $builtPath
if ($LASTEXITCODE -ne 0) { throw 'Archive patch failed.' }
$built = $built | ConvertFrom-Json
$exePath = Join-Path $destination 'ChatGPT-fast.exe'
$launcher = & $NodePath (Join-Path $PSScriptRoot 'local-client-core.cjs') (Join-Path $source 'ChatGPT.exe') $exePath $original.headerSha256 $built.headerSha256
if ($LASTEXITCODE -ne 0) { throw 'Launcher patch failed.' }
$launcher = $launcher | ConvertFrom-Json
Move-Item -LiteralPath $builtPath -Destination (Join-Path $destination 'resources\app.asar') -Force
Move-Item -LiteralPath $exePath -Destination (Join-Path $destination 'ChatGPT.exe') -Force
$runtimeHash = (Get-FileHash -LiteralPath (Join-Path $source 'chrome.dll') -Algorithm SHA256).Hash
if ((Get-FileHash -LiteralPath (Join-Path $destination 'chrome.dll') -Algorithm SHA256).Hash -ne $runtimeHash) { throw 'Runtime copy mismatch.' }
$installation = [ordered]@{
    schemaVersion = 1
    packageFullName = $package.PackageFullName
    version = $package.Version.ToString()
    directory = $destination
    installedAtUtc = [DateTime]::UtcNow.ToString('o')
    sourceArchiveSha256 = $original.archiveSha256
    archiveSha256 = $built.archiveSha256
    sourceExeSha256 = $launcher.sourceSha256
    exeSha256 = $launcher.sha256
    headerSha256 = $built.headerSha256
    runtimeSha256 = $runtimeHash
    localModification = 'API Fast auth gates, matching ASAR integrity resource, unpackaged private assembly resolution'
}
$text = $installation | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText(($manifestPath + '.new'), $text, (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath ($manifestPath + '.new') -Destination $manifestPath -Force
$text
