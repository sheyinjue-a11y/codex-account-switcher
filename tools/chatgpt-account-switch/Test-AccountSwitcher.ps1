[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$switcher = Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-switcher-test-' + [guid]::NewGuid().ToString('N'))
$canonicalHome = Join-Path $testRoot '.codex'
$labHome = Join-Path $testRoot '.codex-lab'
$shareHome = Join-Path $testRoot '.codex-share'
$vaultRoot = Join-Path $testRoot 'vault'
$backupRoot = Join-Path $testRoot 'backups'
$settingsPath = Join-Path $testRoot 'settings.json'
$failures = New-Object 'Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:failures.Add($Message) }
}

function Get-TestAuthKind {
    param([string]$Path)
    $auth = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($auth.PSObject.Properties.Name -contains 'tokens' -and $null -ne $auth.tokens) { return 'Personal' }
    if ($auth.PSObject.Properties.Name -contains 'OPENAI_API_KEY' -and -not [string]::IsNullOrWhiteSpace([string]$auth.OPENAI_API_KEY)) { return 'Lab' }
    return 'Unknown'
}

function Invoke-SwitcherTestProcess {
    param([string[]]$Arguments)
    $oldMode = $env:CODEX_SWITCHER_TEST_MODE
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $env:CODEX_SWITCHER_TEST_MODE = '1'
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $switcher @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
        if ($null -eq $oldMode) { Remove-Item Env:CODEX_SWITCHER_TEST_MODE -ErrorAction SilentlyContinue }
        else { $env:CODEX_SWITCHER_TEST_MODE = $oldMode }
    }
}

function Get-TestMutexName {
    param([string]$Path)
    $inputBytes = [Text.Encoding]::UTF8.GetBytes($Path.ToUpperInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($inputBytes)
        $identifier = -join ($hash[0..11] | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
        [Array]::Clear($inputBytes, 0, $inputBytes.Length)
    }
    return 'Local\CodexAccountSwitcher_' + $identifier
}

try {
    foreach ($path in @($canonicalHome, $labHome, $shareHome)) {
        $null = New-Item -ItemType Directory -Path $path -Force
    }

    $personalSecret = 'FAKE_PERSONAL_ACCESS_TOKEN_42'
    $labSecret = 'FAKE_LAB_API_KEY_73'
    $personalAuth = [ordered]@{
        auth_mode = 'chatgpt'
        OPENAI_API_KEY = $null
        tokens = [ordered]@{ access_token = $personalSecret; refresh_token = 'FAKE_REFRESH_TOKEN_99'; account_id = 'FAKE_ACCOUNT_LOCAL_TEST_ONLY' }
    } | ConvertTo-Json -Depth 5
    $labAuth = [ordered]@{ OPENAI_API_KEY = $labSecret } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $canonicalHome 'auth.json'), $personalAuth)
    [IO.File]::WriteAllText((Join-Path $labHome 'auth.json'), $labAuth)
    [IO.File]::WriteAllText((Join-Path $canonicalHome 'config.toml'), "model = `"gpt-test`"`r`nsqlite_home = `"wrong`"`r`n[features]`r`nexample = true`r`n")
    [IO.File]::WriteAllText((Join-Path $labHome 'config.toml'), "model = `"gpt-lab-test`"`r`nmodel_provider = `"OpenAI`"`r`n[model_providers.OpenAI]`r`nname = `"Lab`"`r`nbase_url = `"http://127.0.0.1:9`"`r`nwire_api = `"responses`"`r`nrequires_openai_auth = true`r`n")
    [IO.File]::WriteAllText((Join-Path $canonicalHome 'session_index.jsonl'), "{}`r`n")
    $sandboxSecrets = Join-Path $canonicalHome '.sandbox-secrets'
    $null = New-Item -ItemType Directory -Path $sandboxSecrets -Force
    [IO.File]::WriteAllText((Join-Path $sandboxSecrets 'secret.txt'), 'FAKE_SANDBOX_SECRET_51')
    [IO.File]::WriteAllText((Join-Path $labHome 'legacy.txt'), 'lab-history')
    [IO.File]::WriteAllText((Join-Path $shareHome 'legacy.txt'), 'share-history')

    $settings = [ordered]@{
        TestRoot = $testRoot
        CanonicalHome = $canonicalHome
        LabHome = $labHome
        ShareHome = $shareHome
        VaultRoot = $vaultRoot
        BackupRoot = $backupRoot
        SkipProcessCheck = $true
        SimulateBusy = $false
        SkipCodexStatus = $true
    }
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 4))

    $legacyLabHash = (Get-FileHash -LiteralPath (Join-Path $labHome 'legacy.txt')).Hash
    $legacyShareHash = (Get-FileHash -LiteralPath (Join-Path $shareHome 'legacy.txt')).Hash

    $result = Invoke-SwitcherTestProcess -Arguments @('-Initialize', '-TestSettings', $settingsPath)
    Assert-True ($result.ExitCode -eq 0) ('Initialization failed: ' + $result.Output)
    Assert-True (Test-Path -LiteralPath (Join-Path $vaultRoot 'personal.auth.dpapi')) 'Personal DPAPI credential was not created.'
    Assert-True (Test-Path -LiteralPath (Join-Path $vaultRoot 'lab.auth.dpapi')) 'Lab DPAPI credential was not created.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $canonicalHome 'config.toml') -Raw) -match '(?m)^cli_auth_credentials_store\s*=\s*"file"\s*$') 'File credential storage was not configured.'
    Assert-True (-not ((Get-Content -LiteralPath (Join-Path $canonicalHome 'config.toml') -Raw) -match '(?m)^\s*sqlite_home\s*=')) 'sqlite_home override was not removed.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $labHome 'legacy.txt')).Hash -eq $legacyLabHash) 'Lab legacy history changed during initialization.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $shareHome 'legacy.txt')).Hash -eq $legacyShareHash) 'Shared legacy history changed during initialization.'
    $backupSet = Get-ChildItem -LiteralPath $backupRoot -Directory | Select-Object -First 1
    Assert-True ($null -ne $backupSet) 'Verified backup set was not created.'
    if ($null -ne $backupSet) {
        Assert-True (Test-Path -LiteralPath (Join-Path $backupSet.FullName 'manifest.json')) 'Backup manifest was not created.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $backupSet.FullName 'personal\auth.json'))) 'Plaintext auth.json was copied into the backup.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $backupSet.FullName 'personal\.sandbox-secrets'))) 'Sandbox secrets were copied into the backup.'
        Assert-True (Test-Path -LiteralPath (Join-Path $backupSet.FullName 'lab\legacy.txt')) 'Lab legacy state was not backed up.'
        Assert-True (Test-Path -LiteralPath (Join-Path $backupSet.FullName 'legacy-share\legacy.txt')) 'Shared legacy state was not backed up.'
    }

    $vaultBytes = [IO.File]::ReadAllBytes((Join-Path $vaultRoot 'lab.auth.dpapi'))
    $vaultText = [Text.Encoding]::UTF8.GetString($vaultBytes)
    Assert-True (-not $vaultText.Contains($labSecret)) 'Lab secret appeared in plaintext inside the vault.'

    $configHash = (Get-FileHash -LiteralPath (Join-Path $canonicalHome 'config.toml')).Hash
    $result = Invoke-SwitcherTestProcess -Arguments @('-Profile', 'Lab', '-NoLaunch', '-TestSettings', $settingsPath)
    Assert-True ($result.ExitCode -eq 0) ('Lab switch failed: ' + $result.Output)
    Assert-True ((Get-TestAuthKind -Path (Join-Path $canonicalHome 'auth.json')) -eq 'Lab') 'Lab credential did not become active.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $canonicalHome 'config.toml') -Raw) -match '(?m)^openai_base_url = "http://127.0.0.1:9"') 'Lab endpoint was not selected.'

    $result = Invoke-SwitcherTestProcess -Arguments @('-Profile', 'Personal', '-NoLaunch', '-TestSettings', $settingsPath)
    Assert-True ($result.ExitCode -eq 0) ('Personal switch failed: ' + $result.Output)
    Assert-True ((Get-TestAuthKind -Path (Join-Path $canonicalHome 'auth.json')) -eq 'Personal') 'Personal credential did not become active.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $canonicalHome 'config.toml')).Hash -eq $configHash) 'Personal config was not restored after the round trip.'

    $beforeRollbackHash = (Get-FileHash -LiteralPath (Join-Path $canonicalHome 'auth.json')).Hash
    $result = Invoke-SwitcherTestProcess -Arguments @('-Profile', 'Lab', '-NoLaunch', '-InjectFailure', 'AfterCredentialWrite', '-TestSettings', $settingsPath)
    Assert-True ($result.ExitCode -ne 0) 'Injected failure unexpectedly succeeded.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $canonicalHome 'auth.json')).Hash -eq $beforeRollbackHash) 'Credential rollback did not restore the original file.'
    Assert-True ((Get-TestAuthKind -Path (Join-Path $canonicalHome 'auth.json')) -eq 'Personal') 'Credential rollback restored the wrong profile.'

    $settings.SimulateBusy = $true
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 4))
    $beforeBusyHash = (Get-FileHash -LiteralPath (Join-Path $canonicalHome 'auth.json')).Hash
    $result = Invoke-SwitcherTestProcess -Arguments @('-Profile', 'Lab', '-NoLaunch', '-TestSettings', $settingsPath)
    Assert-True ($result.ExitCode -ne 0) 'Busy-process simulation unexpectedly switched accounts.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $canonicalHome 'auth.json')).Hash -eq $beforeBusyHash) 'Busy-process rejection changed the active credential.'

    $settings.SimulateBusy = $false
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 4))
    $mutex = New-Object Threading.Mutex($false, (Get-TestMutexName -Path $vaultRoot))
    try {
        Assert-True ($mutex.WaitOne(0)) 'Test process could not acquire the switcher mutex.'
        $beforeMutexHash = (Get-FileHash -LiteralPath (Join-Path $canonicalHome 'auth.json')).Hash
        $result = Invoke-SwitcherTestProcess -Arguments @('-Profile', 'Lab', '-NoLaunch', '-TestSettings', $settingsPath)
        Assert-True ($result.ExitCode -ne 0) 'Concurrent switch simulation unexpectedly succeeded.'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $canonicalHome 'auth.json')).Hash -eq $beforeMutexHash) 'Mutex rejection changed the active credential.'
    } finally {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }

    $status = Invoke-SwitcherTestProcess -Arguments @('-Status', '-TestSettings', $settingsPath)
    Assert-True ($status.ExitCode -eq 0) ('Status command failed: ' + $status.Output)
    Assert-True ($status.Output -match 'activeProfileId\s*:\s*personal') 'Status output did not report sanitized active profile ID.'
    Assert-True (-not $status.Output.Contains($personalSecret)) 'Personal secret leaked in status output.'
    Assert-True (-not $status.Output.Contains($labSecret)) 'Lab secret leaked in status output.'

    $audit = Get-Content -LiteralPath (Join-Path $vaultRoot 'switcher-audit.jsonl') -Raw
    Assert-True (-not $audit.Contains($personalSecret)) 'Personal secret leaked in the audit log.'
    Assert-True (-not $audit.Contains($labSecret)) 'Lab secret leaked in the audit log.'
    $sourceText = [IO.File]::ReadAllText($switcher)
    Assert-True (-not $sourceText.Contains($personalSecret)) 'Personal secret leaked into switcher source.'
    Assert-True (-not $sourceText.Contains($labSecret)) 'Lab secret leaked into switcher source.'

    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Error $_ }
        exit 1
    }

    Write-Host 'Account switcher isolated tests passed.' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $allowedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if (-not $resolvedTestRoot.StartsWith($allowedParent + '\codex-switcher-test-', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing cleanup outside the test directory.'
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
