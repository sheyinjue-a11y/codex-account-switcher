Set-StrictMode -Version Latest

function Get-LocalApiFastRoot {
    # AppData writes made inside the Store app are redirected into LocalCache.
    # The Explorer-launched switcher must see exactly the same installation.
    return (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex-api-fast-client')
}

function Get-LocalApiFastInstallation {
    $root = Get-LocalApiFastRoot
    $file = Join-Path $root 'installation.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $item = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if ($item.schemaVersion -ne 1) { throw 'Unsupported local Fast installation.' }
    $expected = [IO.Path]::GetFullPath((Join-Path $root ('versions\' + $item.version)))
    if ([IO.Path]::GetFullPath($item.directory) -ine $expected) { throw 'Unexpected local Fast directory.' }
    $package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
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
    foreach ($name in @('CODEX_HOME','CODEX_SQLITE_HOME','CODEX_ELECTRON_USER_DATA_PATH','OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CODEX_APP_SERVER_OPENAI_BASE_URL','CODEX_APP_SERVER_CHATGPT_BASE_URL')) { $psi.EnvironmentVariables.Remove($name) }
    # Preserve the Store app's existing desktop/browser preferences when launched
    # without package virtualization. Credentials and chats remain in .codex.
    $package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
    if ($package) {
        $storeData = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('AppData\Local\Packages\' + $package.PackageFamilyName + '\LocalCache\Roaming\Codex')
        $browserData = Join-Path $storeData 'web\Codex'
        if (Test-Path -LiteralPath (Join-Path $browserData 'Default') -PathType Container) {
            $psi.EnvironmentVariables['CODEX_ELECTRON_USER_DATA_PATH'] = $storeData
            $psi.Arguments = '--user-data-dir="' + $browserData + '"'
        }
    }
    return $psi
}

function Start-LocalApiFastClient {
    $item = Get-LocalApiFastInstallation
    if ($null -eq $item) { return $false }
    $psi = New-LocalApiFastProcessStartInfo $item.directory
    $process = [Diagnostics.Process]::Start($psi)
    try {
        if ($process.WaitForExit(3000)) {
            $existing = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {
                try { $_.Path -eq $psi.FileName -and $_.MainWindowHandle -ne [IntPtr]::Zero } catch { $false }
            })
            if (-not $existing.Count) { throw 'Local Fast client exited during startup.' }
        }
        $report = [ordered]@{ checkedAtUtc=[DateTime]::UtcNow.ToString('o'); status='started'; executable=$psi.FileName; processId=$process.Id; package=$item.packageFullName }
        try {
            [IO.File]::WriteAllText((Join-Path (Get-LocalApiFastRoot) 'last-launch.json'), ($report | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        } catch { Write-Warning 'Local Fast client started, but its launch record could not be saved.' }
    } finally { $process.Dispose() }
    return $true
}
