Set-StrictMode -Version Latest
$script:localFastTools = $PSScriptRoot

function Read-LocalFastJson([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    return $null
}

function Write-LocalFastJson([string]$Path, $Value) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, ($Path + '.previous')) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Get-LocalFastAutoSettings {
    return (Read-LocalFastJson (Join-Path (Get-LocalApiFastRoot) 'auto-update.json'))
}

function Test-LocalFastApiLogin {
    $auth = Read-LocalFastJson (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\auth.json')
    return ($null -ne $auth -and $auth.PSObject.Properties['auth_mode'] -and $auth.auth_mode -eq 'apikey')
}

function Enter-LocalFastUpdateLock([string]$Root, [int]$TimeoutSeconds = 120) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return [IO.File]::Open((Join-Path $Root 'update.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Another Fast update is still running. Try again when it finishes.' }
            Start-Sleep -Milliseconds 250
        }
    } while ($true)
}

function Get-LocalFastBuildKey($Package, $Settings) {
    $parts = @($Package.PackageFullName, $Settings.nodePath, $Settings.modulePath)
    foreach ($name in @('patch-core.cjs','local-client-core.cjs','Install-LocalApiFastClient.ps1','LocalApiFastInstaller.ps1','Auto-LocalApiFastClient.ps1')) {
        $parts += (Get-FileHash -LiteralPath (Join-Path $script:localFastTools $name) -Algorithm SHA256).Hash
    }
    foreach ($file in @($Settings.nodePath, (Join-Path $Settings.modulePath 'acorn\dist\acorn.js'))) {
        $parts += $(if (Test-Path -LiteralPath $file -PathType Leaf) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash } else { 'missing' })
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))))).Replace('-','').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Invoke-LocalFastAutoBuild($Settings) {
    if (-not (Test-Path -LiteralPath $Settings.nodePath -PathType Leaf)) { throw 'Fast update Node.js is missing. Re-enable automatic Fast with an installed Node.js.' }
    $previousNodePath = $env:NODE_PATH
    try {
        $env:NODE_PATH = $Settings.modulePath
        'require("acorn"); if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1)' | & $Settings.nodePath - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Fast update needs Node.js 22+ and its Acorn dependency. Re-enable automatic Fast after restoring them.' }
        & (Join-Path $script:localFastTools 'Install-LocalApiFastClient.ps1') -NodePath $Settings.nodePath -RootPath (Get-LocalApiFastRoot) -LockHeld | Out-Null
    } finally { $env:NODE_PATH = $previousNodePath }
}

function Resolve-LocalApiFastInstallation {
    $settings = Get-LocalFastAutoSettings
    if ($null -eq $settings -or -not $settings.enabled) { return (Get-LocalApiFastInstallation) }
    if ($settings.schemaVersion -ne 1) { throw 'Unsupported Fast automatic update settings.' }
    if (-not (Test-LocalFastApiLogin)) { return $null }
    try { $item = Get-LocalApiFastInstallation; if ($null -ne $item) { return $item } } catch { }
    $root = Get-LocalApiFastRoot
    $lock = Enter-LocalFastUpdateLock $root
    try {
        # Another launcher may have finished while we waited for the lock.
        $settings = Get-LocalFastAutoSettings
        if ($null -eq $settings -or -not $settings.enabled) { return (Get-LocalApiFastInstallation) }
        try { $item = Get-LocalApiFastInstallation; if ($null -ne $item) { return $item } } catch { }
        $package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $package) { throw 'Official Codex package is required for automatic Fast.' }
        $key = Get-LocalFastBuildKey $package $settings
        $statusPath = Join-Path $root 'auto-update-status.json'
        $previous = Read-LocalFastJson $statusPath
        if ($null -ne $previous -and $previous.key -eq $key -and $previous.status -eq 'failed') {
            throw ('Fast automatic adaptation previously failed for this version. Re-enable to retry, or update the patch tools. ' + $previous.detail)
        }
        Write-Host ('Preparing Fast for Codex ' + $package.Version + '. The first launch after an update may take a minute...')
        try {
            Invoke-LocalFastAutoBuild $settings
            $item = Get-LocalApiFastInstallation
            if ($null -eq $item) { throw 'Automatic Fast build did not publish a valid installation.' }
        } catch {
            $detail = $_.Exception.Message
            Write-LocalFastJson $statusPath @{key=$key;status='failed';package=$package.PackageFullName;checkedAtUtc=[DateTime]::UtcNow.ToString('o');detail=$detail}
            throw ('Fast automatic adaptation failed: ' + $detail)
        }
        Write-LocalFastJson $statusPath @{key=$key;status='ready';package=$package.PackageFullName;checkedAtUtc=[DateTime]::UtcNow.ToString('o');detail='Validated local Fast installation.'}
        return $item
    } finally { $lock.Dispose() }
}
