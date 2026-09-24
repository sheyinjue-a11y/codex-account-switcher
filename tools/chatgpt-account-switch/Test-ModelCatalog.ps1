[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$root=Join-Path $parent ('model-catalog-test-'+[guid]::NewGuid().ToString('N'))
function Check($Value,$Message) { if (-not $Value) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
try {
    . (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
    $s=[pscustomobject]@{CanonicalHome=(Join-Path $root 'shared');VaultRoot=(Join-Path $root 'vault');LabHome=(Join-Path $root 'lab');ShareHome=(Join-Path $root 'old');BackupRoot=(Join-Path $root 'backup');TestRoot=$root;TestMode=$true;SkipProcessCheck=$true;SimulateBusy=$false;SkipCodexStatus=$true;SkipLaunch=$true}
    foreach($path in @($s.CanonicalHome,$s.VaultRoot)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $r=Add-ProfileRecord (New-ProfileRegistry $s.CanonicalHome) 'API' responses_api
    $api=$r.profiles[0]
    $auth=[Text.Encoding]::UTF8.GetBytes('{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_CATALOG_TEST_ONLY"}')
    $route=New-ResponsesRoute 'https://example.test/v1' 'gpt-6-luna'
    Write-ProfileAuth $s $api $auth; Write-ProfileRoute $s $api $route
    Write-ProfileRegistry $s $r; Write-ProfileState $s $api.id 1
    $configPath=Join-Path $s.CanonicalHome 'config.toml'
    Write-AtomicBytes (Join-Path $s.CanonicalHome 'auth.json') $auth
    Write-AtomicText $configPath ((Set-ProviderRoute "# shared`n[features]`nplugins = true`n" $route))
    $cachePath=Join-Path $s.CanonicalHome 'models_cache.json'
    $catalogPath=Join-Path $s.VaultRoot 'api-models.json'
    $models=@(foreach($slug in @('gpt-6-astra','gpt-6-sol','gpt-6-luna','hidden-model')) {
        @{slug=$slug;visibility=$(if($slug -eq 'hidden-model'){'hide'}else{'list'});supported_in_api=$true;base_instructions='FAKE instructions';context_window=100000;extra=@{nested=@('keep',42)}}
    })
    Write-AtomicText $cachePath (@{models=$models;client_version='fixture'}|ConvertTo-Json -Depth 10)
    $cacheHash=(Get-FileHash $cachePath).Hash
    Invoke-ProfileSwitch $s $api.id -DoNotLaunch
    Check ([IO.File]::ReadAllText($configPath).Contains('model_catalog_json = ')) 'Ordinary API activation attaches a model catalog.'
    $snapshot=[IO.File]::ReadAllText($catalogPath)|ConvertFrom-Json
    Check (($snapshot.models.slug -join ',') -ceq 'gpt-6-astra,gpt-6-sol,gpt-6-luna,hidden-model') 'Astra, Sol and Luna are retained without requiring old 5.6 models.'
    Check ($snapshot.models[3].visibility -ceq 'hide' -and $snapshot.models[1].extra.nested[1] -eq 42 -and $snapshot.models[2].base_instructions -ceq 'FAKE instructions') 'Visibility, instructions and unknown metadata are preserved.'
    Check ([IO.File]::ReadAllText($configPath).Contains('model = "gpt-6-luna"')) 'Activation keeps the selected model.'
    $activeConfig=[IO.File]::ReadAllText($configPath)
    Check ($activeConfig.Contains('# shared') -and $activeConfig.Contains("[features]`r`nplugins = true")) 'Shared settings are untouched.'
    Check ((Get-FileHash $cachePath).Hash -eq $cacheHash) 'The official cache is read-only.'
    $snapshotHash=(Get-FileHash $catalogPath).Hash
    foreach($invalid in @('{broken','{"models":[]}','{"models":[{"slug":"duplicate","visibility":"list","supported_in_api":true},{"slug":"duplicate","visibility":"list","supported_in_api":true}]}')) {
        Write-AtomicText $cachePath $invalid
        Invoke-ProfileSwitch $s $api.id -DoNotLaunch
        Check ((Get-FileHash $catalogPath).Hash -eq $snapshotHash) 'Bad cache falls back to the last valid snapshot.'
    }
    $configBefore=[IO.File]::ReadAllText($configPath)
    $models[1].base_instructions='Updated fixture'
    Write-AtomicText $cachePath (@{models=$models}|ConvertTo-Json -Depth 10)
    $failed=$false
    try { Invoke-ProfileSwitch $s $api.id -DoNotLaunch -FailurePoint AfterCredentialWrite } catch { $failed=$true }
    Check $failed 'Catalog refresh reaches the injected switch failure.'
    Check ((Get-FileHash $catalogPath).Hash -eq $snapshotHash -and [IO.File]::ReadAllText($configPath) -ceq $configBefore) 'Failed switches restore both catalog and configuration.'
    $null=Update-ResponsesApiProfile $s ([pscustomobject]@{displayName='API';baseUrl='https://example.test/v1';model='gpt-6-sol';apiKey=''}) $api.id
    Check ([IO.File]::ReadAllText($configPath).Contains('model_catalog_json = ') -and [IO.File]::ReadAllText($configPath).Contains('model = "gpt-6-sol"')) 'Editing the active API retains catalog support and the requested model.'
    $future=@{slug='future-model';visibility='list';supported_in_api=$true;new_metadata=@{preserve='yes'}}
    Write-AtomicText $cachePath (@{models=@($future)}|ConvertTo-Json -Depth 10)
    Invoke-ProfileSwitch $s $api.id -DoNotLaunch
    $snapshot=[IO.File]::ReadAllText($catalogPath)|ConvertFrom-Json
    Check ($snapshot.models.Count -eq 1 -and $snapshot.models[0].slug -ceq 'future-model' -and $snapshot.models[0].new_metadata.preserve -ceq 'yes') 'Later official cache updates add new names and remove retired names without a switcher update.'
    $legacyLine='model_catalog_json = '+((Join-Path $s.VaultRoot 'lab-models.json')|ConvertTo-Json -Compress)
    $legacy=Get-ProviderRoute ((@($route.Entries|ForEach-Object Line)+$legacyLine)-join "`n")
    $null=Add-ApiModelCatalogRoute $legacy $s
    Check (([IO.File]::ReadAllText((Join-Path $s.VaultRoot 'lab-models.json'))|ConvertFrom-Json).models[0].slug -ceq 'future-model') 'Migrated legacy managed catalogs still refresh after an API edit.'
    $customRoute=Get-ProviderRoute ('model_provider = "openai"'+"`n"+'openai_base_url = "https://example.test/v1"'+"`n"+'model = "gpt-6-sol"'+"`n"+"model_catalog_json = 'C:/custom/models.json'")
    Write-AtomicText $configPath (Set-ProviderRoute ([IO.File]::ReadAllText($configPath)) $customRoute)
    Invoke-ProfileSwitch $s $api.id -DoNotLaunch
    $null=Update-ResponsesApiProfile $s ([pscustomobject]@{displayName='API';baseUrl='https://example.test/v2';model='gpt-6-luna';apiKey=''}) $api.id
    Check ([IO.File]::ReadAllText($configPath).Contains("model_catalog_json = 'C:/custom/models.json'")) 'Activation and API edits preserve an explicit custom catalog.'
    $plain=New-ResponsesRoute 'https://example.test/v1' 'gpt-6-sol'
    $s.VaultRoot=Join-Path $root 'empty-vault'
    New-Item -ItemType Directory -Path $s.VaultRoot | Out-Null
    Write-AtomicText $cachePath '{broken'
    $result=Add-ApiModelCatalogRoute $plain $s
    Check (@($result.Entries|Where-Object Line -match 'model_catalog_json').Count -eq 0) 'No valid cache means no fabricated model catalog.'
    $managedLine='model_catalog_json = '+((Join-Path $s.VaultRoot 'api-models.json')|ConvertTo-Json -Compress)
    $broken=Get-ProviderRoute ((@($plain.Entries|ForEach-Object Line)+$managedLine)-join "`n")
    $result=Add-ApiModelCatalogRoute $broken $s
    Check (@($result.Entries|Where-Object Line -match 'model_catalog_json').Count -eq 0) 'Missing managed catalogs do not leave broken configuration paths.'
    $personal=Set-ProviderRoute ([IO.File]::ReadAllText($configPath)) (Get-ProviderRoute 'model_provider = "openai"')
    Check (-not $personal.Contains('model_catalog_json')) 'Returning to a route without a catalog removes the API override.'
} finally {
    if ($root.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $root -Leaf) -like 'model-catalog-test-*' -and (Test-Path -LiteralPath $root)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
