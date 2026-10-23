# Do not import Start-LocalApiFastClient.ps1 here. These wrappers are also the
# filesystem-only test seams; production uses the real official package and tools.
function Get-LocalApiFastInstallPackage {
    return (Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1)
}

function Get-LocalApiFastInstallSignature([string]$Path) {
    return (Get-AuthenticodeSignature -LiteralPath $Path)
}

function Invoke-LocalApiFastInstallArchive([string]$NodePath, [string]$Action, [string]$Source, [string]$Output) {
    $arguments = @((Join-Path $PSScriptRoot 'patch-core.cjs'), $Action, $Source)
    if ($Output) { $arguments += $Output }
    $result = & $NodePath @arguments
    if ($LASTEXITCODE -ne 0) { throw ('Archive ' + $Action + ' failed.') }
    return (($result -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Invoke-LocalApiFastInstallLauncher([string]$NodePath, [string]$Source, [string]$Output, [string]$Before, [string]$After) {
    $result = & $NodePath (Join-Path $PSScriptRoot 'local-client-core.cjs') $Source $Output $Before $After
    if ($LASTEXITCODE -ne 0) { throw 'Launcher patch failed.' }
    return (($result -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Copy-LocalApiFastInstallApplication([string]$Source, [string]$Destination) {
    & robocopy.exe $Source $Destination /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw 'Copying official application failed.' }
}

function Assert-LocalApiFastInstallPath([string]$Root, [string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full -ine $Root -and -not $full.StartsWith(($Root + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Local Fast write would escape the installation root.'
    }
    # A junction in any existing ancestor must not redirect a write elsewhere.
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Local Fast paths must not contain reparse points.' }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $full
}

function Get-LocalApiFastInstallHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-LocalApiFastInstallGates($Report, [string]$Status) {
    if ($null -eq $Report -or $Report.status -ne $Status -or $Report.archiveSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $Report.headerSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw ('Invalid archive verification report; expected ' + $Status + '.')
    }
    $gates = @($Report.targetEntries | ForEach-Object { $_.gates })
    if ($gates.Count -ne 2 -or @($gates | Where-Object { $_.role -eq 'ui' }).Count -ne 1 -or @($gates | Where-Object { $_.role -eq 'request' }).Count -ne 1) {
        throw 'Expected exactly one UI and one request Fast gate.'
    }
    $patched = $Status -ne 'patchable'
    if (@($gates | Where-Object { $_.alreadyPatched -isnot [bool] -or $_.alreadyPatched -ne $patched }).Count) { throw 'Unexpected Fast gate patch state.' }
}

function Assert-LocalApiFastInstallPackage($Package) {
    if (-not $Package -or -not $Package.PackageFullName -or -not $Package.InstallLocation -or $Package.Version.ToString() -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw 'Official Codex package is required with a valid identity.'
    }
}

function Assert-LocalApiFastInstallSource($Package, [string]$Source, $Original, [string]$SourceExeHash, [string]$RuntimeHash) {
    $current = Get-LocalApiFastInstallPackage
    Assert-LocalApiFastInstallPackage $current
    if ($current.PackageFullName -cne $Package.PackageFullName -or $current.Version.ToString() -cne $Package.Version.ToString() -or [IO.Path]::GetFullPath($current.InstallLocation) -ine [IO.Path]::GetFullPath($Package.InstallLocation)) {
        throw 'Official Codex changed during the build; retry with the new package.'
    }
    if ((Get-LocalApiFastInstallHash (Join-Path $Source 'resources\app.asar')) -ine $Original.archiveSha256 -or
        (Get-LocalApiFastInstallHash (Join-Path $Source 'ChatGPT.exe')) -ine $SourceExeHash -or
        (Get-LocalApiFastInstallHash (Join-Path $Source 'chrome.dll')) -ine $RuntimeHash) { throw 'Official source changed during the build.' }
}

function Write-LocalApiFastInstallManifest([string]$Root, [string]$Path, $Installation) {
    $target = Assert-LocalApiFastInstallPath $Root $Path
    $token = [guid]::NewGuid().ToString('N')
    $temporary = Assert-LocalApiFastInstallPath $Root ($target + '.new-' + $token)
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Installation | ConvertTo-Json -Depth 8))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            # Windows PowerShell 5.1 marshals a null backup path as an invalid empty
            # string. Keep an explicitly named previous manifest for recovery.
            $backup = Assert-LocalApiFastInstallPath $Root ($target + '.previous-' + $token)
            [IO.File]::Replace($temporary, $target, $backup)
        } else { [IO.File]::Move($temporary, $target) }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Assert-LocalApiFastInstallPath $Root $temporary | Out-Null
            [IO.File]::Delete($temporary)
        }
    }
}

function Test-LocalApiFastInstallReusable([string]$Root, [string]$Directory, $Package, $Original, [string]$SourceExeHash, [string]$RuntimeHash, [string]$NodePath) {
    $metadata = Join-Path $Directory 'installation.json'
    if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) { return $null }
    try {
        foreach ($relative in @('installation.json','ChatGPT.exe','resources\app.asar','chrome.dll')) {
            Assert-LocalApiFastInstallPath $Root (Join-Path $Directory $relative) | Out-Null
        }
        $item = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
        if ($item.schemaVersion -ne 1 -or $item.packageFullName -cne $Package.PackageFullName -or $item.version -cne $Package.Version.ToString() -or
            [IO.Path]::GetFullPath($item.directory).TrimEnd('\','/') -ine $Directory -or $item.sourceArchiveSha256 -ine $Original.archiveSha256 -or
            $item.sourceExeSha256 -ine $SourceExeHash -or $item.runtimeSha256 -ine $RuntimeHash) { return $null }
        foreach ($pair in @(@('ChatGPT.exe','exeSha256'), @('resources\app.asar','archiveSha256'), @('chrome.dll','runtimeSha256'))) {
            if ($item.($pair[1]) -notmatch '^[a-fA-F0-9]{64}$' -or (Get-LocalApiFastInstallHash (Join-Path $Directory $pair[0])) -ine $item.($pair[1])) { return $null }
        }
        $report = Invoke-LocalApiFastInstallArchive -NodePath $NodePath -Action inspect -Source (Join-Path $Directory 'resources\app.asar')
        Assert-LocalApiFastInstallGates $report patched
        if ($report.archiveSha256 -ine $item.archiveSha256 -or $report.headerSha256 -ine $item.headerSha256) { return $null }
        return $item
    } catch { return $null }
}

function Invoke-LocalApiFastInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$NodePath,
        [string]$RootPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex-api-fast-client'),
        [switch]$LockHeld
    )
    $ErrorActionPreference = 'Stop'
    $root = [IO.Path]::GetFullPath($RootPath).TrimEnd('\','/')
    if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\','/')) { throw 'A dedicated local Fast installation directory is required.' }
    Assert-LocalApiFastInstallPath $root $root | Out-Null
    $package = Get-LocalApiFastInstallPackage
    Assert-LocalApiFastInstallPackage $package
    $source = [IO.Path]::GetFullPath((Join-Path $package.InstallLocation 'app')).TrimEnd('\','/')
    $officialRoot = [IO.Path]::GetFullPath($package.InstallLocation).TrimEnd('\','/')
    if ($root -ieq $officialRoot -or $root.StartsWith(($officialRoot + '\'), [StringComparison]::OrdinalIgnoreCase) -or $officialRoot.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Local Fast installation must be separate from the official package.'
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $lock = $null
    $quarantined = $null
    $published = $false
    $committed = $false
    $destination = $null
    $stage = $null
    try {
        if (-not $LockHeld) {
            $lockPath = Assert-LocalApiFastInstallPath $root (Join-Path $root 'update.lock')
            try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch { throw 'Another local Fast update is already running.' }
        }
        $manifestPath = Assert-LocalApiFastInstallPath $root (Join-Path $root 'installation.json')
        $signature = Get-LocalApiFastInstallSignature (Join-Path $source 'ChatGPT.exe')
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=(?:OpenAI|"OpenAI OpCo, LLC")(?:,|$)') { throw 'Official source signature was not verified.' }
        $original = Invoke-LocalApiFastInstallArchive -NodePath $NodePath -Action inspect -Source (Join-Path $source 'resources\app.asar')
        Assert-LocalApiFastInstallGates $original patchable
        if ((Get-LocalApiFastInstallHash (Join-Path $source 'resources\app.asar')) -ine $original.archiveSha256) { throw 'Source archive inspection hash mismatch.' }
        $sourceExeHash = Get-LocalApiFastInstallHash (Join-Path $source 'ChatGPT.exe')
        $runtimeHash = Get-LocalApiFastInstallHash (Join-Path $source 'chrome.dll')
        $version = $package.Version.ToString()
        $destination = Assert-LocalApiFastInstallPath $root (Join-Path $root ('versions\' + $version))
        if (Test-Path -LiteralPath $destination) {
            if (-not (Test-Path -LiteralPath $destination -PathType Container)) { throw 'Version path is not a directory; manual inspection is required.' }
            $recovered = Test-LocalApiFastInstallReusable -Root $root -Directory $destination -Package $package -Original $original -SourceExeHash $sourceExeHash -RuntimeHash $runtimeHash -NodePath $NodePath
            if ($null -ne $recovered) {
                Assert-LocalApiFastInstallSource $package $source $original $sourceExeHash $runtimeHash
                Write-LocalApiFastInstallManifest $root $manifestPath $recovered
                return $recovered
            }
        }
        $stage = Assert-LocalApiFastInstallPath $root (Join-Path $root ('.staging\' + $version + '-' + [guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Copy-LocalApiFastInstallApplication $source $stage
        foreach ($relative in @('ChatGPT.exe','resources\app.asar','chrome.dll')) { Assert-LocalApiFastInstallPath $root (Join-Path $stage $relative) | Out-Null }
        if ((Get-LocalApiFastInstallHash (Join-Path $stage 'ChatGPT.exe')) -ine $sourceExeHash -or
            (Get-LocalApiFastInstallHash (Join-Path $stage 'resources\app.asar')) -ine $original.archiveSha256 -or
            (Get-LocalApiFastInstallHash (Join-Path $stage 'chrome.dll')) -ine $runtimeHash) { throw 'Official application copy mismatch.' }
        $builtPath = Assert-LocalApiFastInstallPath $root (Join-Path $stage 'resources\app-fast.asar')
        $built = Invoke-LocalApiFastInstallArchive -NodePath $NodePath -Action build -Source (Join-Path $stage 'resources\app.asar') -Output $builtPath
        Assert-LocalApiFastInstallGates $built built
        if ($built.sourceSha256 -ine $original.archiveSha256 -or (Get-LocalApiFastInstallHash $builtPath) -ine $built.archiveSha256) { throw 'Built archive hash mismatch.' }
        $exePath = Assert-LocalApiFastInstallPath $root (Join-Path $stage 'ChatGPT-fast.exe')
        $launcher = Invoke-LocalApiFastInstallLauncher -NodePath $NodePath -Source (Join-Path $stage 'ChatGPT.exe') -Output $exePath -Before $original.headerSha256 -After $built.headerSha256
        if ($launcher.sourceSha256 -ine $sourceExeHash -or (Get-LocalApiFastInstallHash $exePath) -ine $launcher.sha256 -or $launcher.oldHeaderHash -ine $original.headerSha256 -or $launcher.newHeaderHash -ine $built.headerSha256) { throw 'Launcher verification failed.' }
        Move-Item -LiteralPath $builtPath -Destination (Join-Path $stage 'resources\app.asar') -Force
        Move-Item -LiteralPath $exePath -Destination (Join-Path $stage 'ChatGPT.exe') -Force
        $verified = Invoke-LocalApiFastInstallArchive -NodePath $NodePath -Action inspect -Source (Join-Path $stage 'resources\app.asar')
        Assert-LocalApiFastInstallGates $verified patched
        if ($verified.archiveSha256 -ine $built.archiveSha256 -or $verified.headerSha256 -ine $built.headerSha256 -or
            (Get-LocalApiFastInstallHash (Join-Path $stage 'chrome.dll')) -ine $runtimeHash) { throw 'Final application verification failed.' }
        $installation = [pscustomobject][ordered]@{
            schemaVersion = 1
            packageFullName = $package.PackageFullName
            version = $version
            directory = $destination
            installedAtUtc = [DateTime]::UtcNow.ToString('o')
            sourceArchiveSha256 = $original.archiveSha256
            archiveSha256 = $built.archiveSha256
            sourceExeSha256 = $sourceExeHash
            exeSha256 = $launcher.sha256
            headerSha256 = $built.headerSha256
            runtimeSha256 = $runtimeHash
            localModification = 'API Fast auth gates, matching ASAR integrity resource, unpackaged private assembly resolution'
        }
        Write-LocalApiFastInstallManifest $root (Join-Path $stage 'installation.json') $installation
        Assert-LocalApiFastInstallSource $package $source $original $sourceExeHash $runtimeHash
        # Retain every pre-existing directory whole, including unknown user files.
        if (Test-Path -LiteralPath $destination) {
            Assert-LocalApiFastInstallPath $root $destination | Out-Null
            $quarantined = Assert-LocalApiFastInstallPath $root (Join-Path $root ('quarantine\' + $version + '-' + [guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($quarantined)) -Force | Out-Null
            [IO.Directory]::Move($destination, $quarantined)
        }
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
        [IO.Directory]::Move($stage, $destination)
        $published = $true
        Assert-LocalApiFastInstallSource $package $source $original $sourceExeHash $runtimeHash
        Write-LocalApiFastInstallManifest $root $manifestPath $installation
        $committed = $true
        return $installation
    } finally {
        try {
            if (-not $committed -and $quarantined -and (Test-Path -LiteralPath $quarantined -PathType Container)) {
                Assert-LocalApiFastInstallPath $root $quarantined | Out-Null
                Assert-LocalApiFastInstallPath $root $destination | Out-Null
                if ($published) {
                    Assert-LocalApiFastInstallPath $root $stage | Out-Null
                    [IO.Directory]::Move($destination, $stage)
                }
                if (-not (Test-Path -LiteralPath $destination)) { [IO.Directory]::Move($quarantined, $destination) }
            }
        } finally { if ($lock) { $lock.Dispose() } }
    }
}
