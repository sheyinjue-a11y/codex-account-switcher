Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Auto-LocalApiFastClient.ps1')

function Get-LocalApiFastRoot {
    # AppData writes made inside the Store app are redirected into LocalCache.
    # The Explorer-launched switcher must see exactly the same installation.
    return (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex-api-fast-client')
}

function Get-LocalFastOfficialPackage {
    # Both the integrity check and the launch need the same installed package;
    # resolving it once keeps the two call sites from disagreeing.
    return (Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1)
}

function Get-LocalApiFastInstallation {
    $root = Get-LocalApiFastRoot
    $file = Join-Path $root 'installation.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $item = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if ($item.schemaVersion -ne 1) { throw 'Unsupported local Fast installation.' }
    $expected = [IO.Path]::GetFullPath((Join-Path $root ('versions\' + $item.version)))
    if ([IO.Path]::GetFullPath($item.directory) -ine $expected) { throw 'Unexpected local Fast directory.' }
    $package = Get-LocalFastOfficialPackage
    if (-not $package -or $package.PackageFullName -ne $item.packageFullName -or $package.Version.ToString() -ne $item.version) { throw 'Official Codex updated. Rebuild the local Fast client for this version.' }
    foreach ($pair in @(@('ChatGPT.exe','exeSha256'), @('resources\app.asar','archiveSha256'), @('chrome.dll','runtimeSha256'))) {
        if ((Get-FileHash -LiteralPath (Join-Path $expected $pair[0]) -Algorithm SHA256).Hash -ine $item.($pair[1])) { throw ('Local Fast integrity mismatch: ' + $pair[0]) }
    }
    return $item
}

function New-LocalApiFastProcessStartInfo([string]$Directory) {
    # The account switcher already checks the shared home and persistent routing
    # environment. Keep the same user data and authentication as the official app.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Directory 'ChatGPT.exe'
    $psi.WorkingDirectory = $Directory
    $psi.UseShellExecute = $false
    $psi.WindowStyle = 'Normal'
    # Never touch ProcessStartInfo.EnvironmentVariables here: under Windows
    # PowerShell 5.1 that dictionary reads back as an empty shell, its Remove()
    # throws, and writing any entry replaces the inherited block with just the
    # written names (the child then loses PATH/TEMP/USERPROFILE). The launch
    # adjusts this process' environment instead and restores it afterwards.
    return $psi
}

function Get-LocalApiFastEnvironmentNames {
    return @(
        'CODEX_HOME', 'CODEX_SQLITE_HOME', 'CODEX_ELECTRON_USER_DATA_PATH',
        'OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'OPENAI_BASE_URL',
        'CODEX_APP_SERVER_OPENAI_BASE_URL', 'CODEX_APP_SERVER_CHATGPT_BASE_URL'
    )
}

function Set-LocalApiFastEnvironment {
    # Returns the saved values plus the extra arguments the client needs. Callers
    # must restore in a finally block so a failed launch cannot leak overrides
    # into the rest of the session.
    $saved = @{}
    foreach ($name in Get-LocalApiFastEnvironmentNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $arguments = ''
    # Preserve the Store app's existing desktop/browser preferences when launched
    # without package virtualization. Credentials and chats remain in .codex.
    $package = Get-LocalFastOfficialPackage
    if ($package) {
        $storeData = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('AppData\Local\Packages\' + $package.PackageFamilyName + '\LocalCache\Roaming\Codex')
        $browserData = Join-Path $storeData 'web\Codex'
        if (Test-Path -LiteralPath (Join-Path $browserData 'Default') -PathType Container) {
            [Environment]::SetEnvironmentVariable('CODEX_ELECTRON_USER_DATA_PATH', $storeData)
            $arguments = '--user-data-dir="' + $browserData + '"'
        }
    }
    return [pscustomobject]@{ Saved = $saved; Arguments = $arguments }
}

function Restore-LocalApiFastEnvironment($State) {
    if ($null -eq $State) { return }
    foreach ($name in @($State.Saved.Keys)) { [Environment]::SetEnvironmentVariable($name, $State.Saved[$name]) }
}

function Start-LocalApiFastClient {
    $item = Resolve-LocalApiFastInstallation
    if ($null -eq $item) { return $false }
    $psi = New-LocalApiFastProcessStartInfo $item.directory
    $environment = $null
    try {
        $environment = Set-LocalApiFastEnvironment
        $psi.Arguments = $environment.Arguments
        $process = [Diagnostics.Process]::Start($psi)
    } finally { Restore-LocalApiFastEnvironment $environment }
    try {
        if ($process.WaitForExit(3000)) {
            $existing = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {
                try { $_.Path -eq $psi.FileName -and $_.MainWindowHandle -ne [IntPtr]::Zero } catch { $false }
            })
            if (-not $existing.Count) {
                # The private copy shares the Store app's user data, so a running
                # official client wins the profile lock and the new process exits
                # immediately. Say so instead of reporting an anonymous failure.
                $packaged = @(Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1)
                if ($packaged) {
                    $prefix = [IO.Path]::GetFullPath($packaged[0].InstallLocation).TrimEnd('\') + '\'
                    $official = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {
                        try { $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
                    })
                    if ($official.Count) { throw 'Local Fast client exited because the official Codex client is already running. Close Codex completely, then launch it through the switcher.' }
                }
                throw 'Local Fast client exited during startup.'
            }
        }
        $report = [ordered]@{ checkedAtUtc=[DateTime]::UtcNow.ToString('o'); status='started'; executable=$psi.FileName; processId=$process.Id; package=$item.packageFullName }
        try {
            [IO.File]::WriteAllText((Join-Path (Get-LocalApiFastRoot) 'last-launch.json'), ($report | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        } catch { Write-Warning 'Local Fast client started, but its launch record could not be saved.' }
    } finally { $process.Dispose() }
    return $true
}
