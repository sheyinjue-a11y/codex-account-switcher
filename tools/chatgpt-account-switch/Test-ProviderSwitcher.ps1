[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$switcher = Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1'
$testParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $testParent ('provider-switch-test-' + [guid]::NewGuid().ToString('N'))
$oldTestMode = $env:CODEX_SWITCHER_TEST_MODE
$failures = New-Object 'Collections.Generic.List[string]'

function Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { $script:failures.Add($Message); Write-Host "FAIL: $Message" }
    else { Write-Host "PASS: $Message" }
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $settings = [pscustomobject]@{
        TestRoot = $testRoot
        CanonicalHome = Join-Path $testRoot 'shared'
        LabHome = Join-Path $testRoot 'lab'
        ShareHome = Join-Path $testRoot 'legacy-share'
        VaultRoot = Join-Path $testRoot 'vault'
        BackupRoot = Join-Path $testRoot 'backups'
        SkipProcessCheck = $true
        SimulateBusy = $false
        SkipCodexStatus = $false
    }
    foreach ($path in @($settings.CanonicalHome, $settings.LabHome, $settings.ShareHome)) {
        $null = New-Item -ItemType Directory -Path $path
    }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $settingsPath = Join-Path $testRoot 'settings.json'
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json), $utf8)
    $personalConfig = @'
# shared comment must survive
model = "gpt-personal-test"
model_reasoning_effort = "high"
service_tier = "default"
personality = "pragmatic"

[features]
example = true
[projects.'C:\shared-project']
trust_level = "trusted"
[model_providers.unrelated]
name = "Do not replace"
base_url = "http://127.0.0.1:9/unrelated"
[model_providers.OPENAI]
name = "Case-sensitive unrelated provider"
base_url = "http://127.0.0.1:9/uppercase"
'@
    $labConfig = @'
model = "gpt-6-astra"
model_provider = "OpenAI"
model_reasoning_effort = "ultra"
service_tier = "fast"
[model_providers.OpenAI]
name = "Laboratory"
base_url = "http://127.0.0.1:9/lab"
wire_api = "responses"
requires_openai_auth = true
'@
    $configPath = Join-Path $settings.CanonicalHome 'config.toml'
    $authPath = Join-Path $settings.CanonicalHome 'auth.json'
    [IO.File]::WriteAllText($configPath, $personalConfig, $utf8)
    [IO.File]::WriteAllText((Join-Path $settings.LabHome 'config.toml'), $labConfig, $utf8)
    $claims = '{"sub":"fake-user","email":"fixture@example.invalid","https://api.openai.com/auth":{"chatgpt_account_id":"fake-account","chatgpt_plan_type":"plus"}}'
    $payload = [Convert]::ToBase64String($utf8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_')
    $personalAuth = @{ auth_mode = 'chatgpt'; OPENAI_API_KEY = $null; tokens = @{
        id_token = ('eyJhbGciOiJub25lIn0.' + $payload + '.fake'); access_token = 'FAKE_ACCESS'; refresh_token = 'FAKE_REFRESH'; account_id = 'fake-account'
    }; last_refresh = '2026-09-05T00:00:00Z' } | ConvertTo-Json -Depth 5
    $labAuth = '{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_LAB_SECRET_FOR_LOCAL_TEST_ONLY"}'
    [IO.File]::WriteAllText($authPath, $labAuth, $utf8)
    [IO.File]::WriteAllText((Join-Path $settings.LabHome 'auth.json'), $labAuth, $utf8)
    $env:CODEX_SWITCHER_TEST_MODE = '1'
    . $switcher -Status -TestSettings $settingsPath | Out-Null
    # Real codex.exe, real Windows PowerShell stderr handling, fake credentials.
    $statusPassed = $false
    try { $statusPassed = Test-CodexLoginStatus -Settings $settings -ExpectedProfile Lab } catch { }
    Check $statusPassed 'A successful native login status on stderr is accepted.'
    Check (-not (Test-CodexLoginStatus -Settings $settings -ExpectedProfile Personal)) 'Status rejects the wrong authentication type.'
    [IO.File]::WriteAllText($authPath, $personalAuth, $utf8)

    # Ensure unchanged workspace data, including a binary database stand-in.
    $sharedFiles = @('session_index.jsonl', '.codex-global-state.json', 'state_5.sqlite')
    $sharedHashes = @{}
    foreach ($name in $sharedFiles) {
        $path = Join-Path $settings.CanonicalHome $name
        [IO.File]::WriteAllText($path, ('shared fixture ' + $name), $utf8)
        $sharedHashes[$name] = (Get-FileHash -LiteralPath $path).Hash
    }
    # The CLI would parse the fake database on broader operations; login status only reads auth/config.
    $beforeFailedInit = (Get-FileHash -LiteralPath $configPath).Hash
    [IO.File]::WriteAllText($authPath, '{"auth_mode":"chatgpt","tokens":{"access_token":"FAKE_INCOMPLETE_AUTH"}}', $utf8)
    $failedAsExpected = $false
    try { Invoke-InitializeSwitcher -Settings $settings } catch { $failedAsExpected = $true }
    Check $failedAsExpected 'Invalid CLI credentials fail initialization.'
    Check (-not (Test-Path -LiteralPath (Join-Path $settings.VaultRoot 'state.json'))) 'Failed initialization leaves no initialized marker.'
    Check ((Get-FileHash -LiteralPath $configPath).Hash -eq $beforeFailedInit) 'Failed initialization restores configuration.'
    Check (-not (Test-Path -LiteralPath (Join-Path $settings.VaultRoot 'lab.route.dpapi'))) 'Failed initialization leaves no stale provider snapshot.'
    $labConfig = $labConfig.Replace('http://127.0.0.1:9/lab', 'http://127.0.0.1:9/lab-corrected')
    [IO.File]::WriteAllText((Join-Path $settings.LabHome 'config.toml'), $labConfig, $utf8)
    [IO.File]::WriteAllText($authPath, $personalAuth, $utf8)
    # Backups use wall-clock seconds; keep the retry in a different second.
    Start-Sleep -Milliseconds 1100
    $initialized = $false
    try { Invoke-InitializeSwitcher -Settings $settings; $initialized = $true } catch { Write-Host ('Fixture initialization error: ' + $_.Exception.Message); Write-Host $_.ScriptStackTrace }
    Check $initialized 'Initialization succeeds with real CLI authentication checks.'
    if ($initialized) {
        $repeatWorked = $false
        try { Invoke-InitializeSwitcher -Settings $settings; $repeatWorked = $true } catch { }
        Check $repeatWorked 'Repeating initialization validates existing state without failing.'
        $initializedLabRoute = Load-ProviderRoute -Settings $settings -ProfileName Lab
        $initializedLabRoots = @($initializedLabRoute.Entries | Where-Object IsRoot | ForEach-Object Line)
        Check (@($initializedLabRoots | Where-Object { $_ -match '^model = "gpt-5\.6-sol"$' }).Count -eq 1) 'Fresh initialization stores the Sol bootstrap model.'
        Check (@($initializedLabRoots | Where-Object { $_ -match '^service_tier\s*=' }).Count -eq 0) 'Fresh initialization does not opt into Fast.'
        # Simulate an initialized installation saved before the bootstrap migration.
        $legacyLabRoute = Convert-LabRouteToSharedProvider -Route (Get-ProviderRoute -ConfigText $labConfig)
        Save-ProviderRoute -Settings $settings -ProfileName Lab -Route $legacyLabRoute
        $configBefore = [IO.File]::ReadAllText($configPath)
        $labSwitched = $false
        try { Invoke-AccountSwitch -Settings $settings -TargetProfile Lab -DoNotLaunch; $labSwitched = $true } catch { }
        Check $labSwitched 'Switch to Lab succeeds.'
        $labActive = [IO.File]::ReadAllText($configPath)
        Check ($labActive -cmatch '(?m)^model_provider = "openai"') 'Stable provider identity is retained for existing sessions.'
        Check ($labActive -match '(?m)^openai_base_url = "http://127.0.0.1:9/lab-corrected"') 'Lab endpoint uses the corrected legacy configuration.'
        Check ($labActive -match '(?m)^model = "gpt-5\.6-sol"') 'Lab starts with the Sol bootstrap model.'
        Check ($labActive -notmatch '(?m)^service_tier\s*=') 'Lab does not explicitly enable Fast.'
        $savedLabRoute = Load-ProviderRoute -Settings $settings -ProfileName Lab
        $savedLabRoots = @($savedLabRoute.Entries | Where-Object IsRoot | ForEach-Object Line)
        Check (@($savedLabRoots | Where-Object { $_ -match '^model = "gpt-5\.6-sol"$' }).Count -eq 1) 'An initialized legacy Lab route is migrated to Sol.'
        Check (@($savedLabRoots | Where-Object { $_ -match '^service_tier\s*=' }).Count -eq 0) 'An initialized legacy Lab route drops explicit Fast.'
        Check ($labActive.Contains('[projects.') -and $labActive.Contains('unrelated') -and $labActive.Contains('# shared comment')) 'Unrelated shared configuration is preserved.'
        Check ($labActive.Contains('[model_providers.OPENAI]') -and $labActive.Contains('http://127.0.0.1:9/uppercase')) 'Case-sensitive provider tables remain untouched.'
        $personalSwitched = $false
        try { Invoke-AccountSwitch -Settings $settings -TargetProfile Personal -DoNotLaunch; $personalSwitched = $true } catch { }
        Check $personalSwitched 'Switch back to Personal succeeds.'
        Check ([IO.File]::ReadAllText($configPath) -eq $configBefore) 'A provider round trip restores the original shared configuration exactly.'
        $edited = [IO.File]::ReadAllText($configPath).Replace('gpt-personal-test', 'gpt-personal-edited')
        [IO.File]::WriteAllText($configPath, $edited, $utf8)
        Invoke-InitializeSwitcher -Settings $settings
        Check ([IO.File]::ReadAllText($configPath).Contains('gpt-personal-edited')) 'Repeated initialization preserves current personal model choices.'
        Invoke-AccountSwitch -Settings $settings -TargetProfile Lab -DoNotLaunch
        Invoke-AccountSwitch -Settings $settings -TargetProfile Personal -DoNotLaunch
        Check ([IO.File]::ReadAllText($configPath).Contains('gpt-personal-edited')) 'Provider switching remembers personal model changes.'
        Save-ProviderRoute -Settings $settings -ProfileName Lab -Route $legacyLabRoute
        $labRoutePath = Get-RouteVaultPath -Settings $settings -ProfileName Lab
        $authHash = (Get-FileHash -LiteralPath $authPath).Hash
        $configHash = (Get-FileHash -LiteralPath $configPath).Hash
        $labRouteHash = (Get-FileHash -LiteralPath $labRoutePath).Hash
        $failureMessage = $null
        try { Invoke-AccountSwitch -Settings $settings -TargetProfile Lab -DoNotLaunch -FailurePoint AfterCredentialWrite } catch { $failureMessage = $_.Exception.Message }
        Check ($failureMessage -eq 'Injected failure after credential write.') 'Failure injection reaches the post-write rollback point.'
        Check ((Get-FileHash -LiteralPath $authPath).Hash -eq $authHash) 'Failure restores authentication.'
        Check ((Get-FileHash -LiteralPath $configPath).Hash -eq $configHash) 'Failure restores provider configuration.'
        Check ((Get-FileHash -LiteralPath $labRoutePath).Hash -eq $labRouteHash) 'Failure restores the pre-migration Lab route.'
        Check (-not (Test-Path -LiteralPath (Get-SwitchRecoveryPath -Settings $settings))) 'Successful rollback removes the pending recovery record.'
        foreach ($name in $sharedFiles) {
            Check ((Get-FileHash -LiteralPath (Join-Path $settings.CanonicalHome $name)).Hash -eq $sharedHashes[$name]) "Shared $name remains unchanged."
        }
    }
    # Catalog generation is local and must preserve official metadata verbatim.
    $models = @(
        @{ slug = 'gpt-5.6-sol'; visibility = 'list'; supported_in_api = $true; base_instructions = 'Sol fixture' },
        @{ slug = 'gpt-6-astra'; visibility = 'list'; supported_in_api = $true; base_instructions = 'Astra fixture' },
        @{ slug = 'hidden-fixture'; visibility = 'hide'; supported_in_api = $true }
    )
    $cachePath = Join-Path $settings.CanonicalHome 'models_cache.json'
    [IO.File]::WriteAllText($cachePath, (@{ models = $models } | ConvertTo-Json -Depth 10), $utf8)
    $catalogRoute = ConvertTo-LabBootstrapRoute -Route $legacyLabRoute -Settings $settings
    $catalogLines = @($catalogRoute.Entries | Where-Object { $_.Line -match '^model_catalog_json\s*=' })
    Check ($catalogLines.Count -eq 1) 'Lab gets exactly one explicit model catalog.'
    $catalogPath = Join-Path $settings.VaultRoot 'lab-models.json'
    $catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
    Check (@($catalog.models).Count -eq 3) 'Catalog retains all official model records.'
    Check ($catalog.models[1].base_instructions -eq 'Astra fixture') 'Catalog preserves model instructions.'
    Check ($catalog.models[2].visibility -eq 'hide') 'Hidden model visibility is not changed.'
    $catalogHash = (Get-FileHash -LiteralPath $catalogPath).Hash
    [IO.File]::WriteAllText($cachePath, '{broken', $utf8)
    $fallbackRoute = ConvertTo-LabBootstrapRoute -Route $catalogRoute -Settings $settings
    Check ((Get-FileHash -LiteralPath $catalogPath).Hash -eq $catalogHash) 'Malformed cache retains the last valid catalog.'
    Check (@($fallbackRoute.Entries | Where-Object { $_.Line -match '^model_catalog_json\s*=' }).Count -eq 1) 'Catalog refresh is idempotent.'
    $customRoute = Get-ProviderRoute -ConfigText ((Set-ProviderRoute -ConfigText '# fixture' -Route $legacyLabRoute) + "`nmodel_catalog_json = 'C:\custom-models.json'")
    $customResult = ConvertTo-LabBootstrapRoute -Route $customRoute -Settings $settings
    Check (@($customResult.Entries | Where-Object { $_.Line -eq "model_catalog_json = 'C:\custom-models.json'" }).Count -eq 1) 'User-managed model catalogs are preserved.'
    Remove-Item -LiteralPath $catalogPath
    $missingRoute = ConvertTo-LabBootstrapRoute -Route $catalogRoute -Settings $settings -WarningAction SilentlyContinue
    Check (@($missingRoute.Entries | Where-Object { $_.Line -match '^model_catalog_json\s*=' }).Count -eq 0) 'Missing catalog falls back without leaving a broken path.'
    $personalResult = Set-ProviderRoute -ConfigText (Set-ProviderRoute -ConfigText $personalConfig -Route $catalogRoute) -Route (Get-ProviderRoute -ConfigText $personalConfig)
    Check ($personalResult -notmatch '(?m)^model_catalog_json\s*=') 'Returning to Personal removes the managed Lab catalog setting.'
    if ($failures.Count) { throw ('Provider tests failed: ' + $failures.Count) }
    Write-Host 'Provider switcher regression tests passed.'
} finally {
    if ($null -eq $oldTestMode) { Remove-Item Env:CODEX_SWITCHER_TEST_MODE -ErrorAction SilentlyContinue }
    else { $env:CODEX_SWITCHER_TEST_MODE = $oldTestMode }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    if (-not $resolvedTestRoot.StartsWith($testParent + '\provider-switch-test-', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside the test directory.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
}
