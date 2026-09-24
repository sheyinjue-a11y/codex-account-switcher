# Schema 2 operations. Legacy helpers remain in the entry script for migration.
Set-StrictMode -Version Latest

function Get-RequestValue($Request, [string]$Name, $Default = $null) {
    if ($null -ne $Request -and $null -ne $Request.PSObject.Properties[$Name]) { return $Request.$Name }
    return $Default
}

function Get-SafeManagementError([string]$Message) {
    # Return literal messages only: parser/native exceptions can include secrets.
    switch -Regex ($Message) {
        'Running:|processes to exit' { return 'Close all ChatGPT and Codex processes before managing profiles.' }
        'already exists' { return 'This account already exists. Re-login to the existing profile.' }
        'cancelled|timed out' { return 'Browser login was cancelled or timed out. No profile was added.' }
        'different account|identity mismatch' { return 'Account identity mismatch. Re-login with the original account or add a new profile.' }
        'Base URL' { return 'Base URL must be HTTPS (or loopback HTTP), without credentials, query or fragment.' }
        'Default model' { return 'Default model is invalid. Use letters, digits, dot, slash, colon, dash or underscore.' }
        'API key' { return 'API key is required for new profiles and must not contain whitespace. Leave it blank only to keep an existing key.' }
        'Profile name|names must|Name.*unique' { return 'Profile name must be unique and contain 1-40 characters.' }
        'Current profile|active profile|last valid|last profile' { return 'The current or last valid profile cannot be deleted.' }
        'recovery|Pending operation' { return 'Profile recovery could not be completed. Preserve recovery files and run Repair.' }
        'cost confirmation' { return 'Connection test requires explicit confirmation of possible usage charges.' }
        default { return 'Profile management failed. Check the selected profile and input fields, then retry.' }
    }
}

function Get-ProfileAuthKind([byte[]]$Bytes) {
    try { $auth = [Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Unsupported authentication format.' }
    $mode = Get-RequestValue $auth 'auth_mode' ''
    $tokens = Get-RequestValue $auth 'tokens'
    $key = Get-RequestValue $auth 'OPENAI_API_KEY'
    if ($mode -ceq 'chatgpt' -and $null -ne $tokens -and [string]::IsNullOrEmpty($key)) {
        foreach ($name in @('access_token','refresh_token','account_id')) {
            $value=Get-RequestValue $tokens $name
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { throw 'ChatGPT authentication has no stable identity or tokens.' }
        }
        return 'chatgpt'
    }
    if ($mode -cin @('','apikey','api_key') -and $null -eq $tokens -and $key -is [string] -and -not [string]::IsNullOrWhiteSpace($key)) { return 'responses_api' }
    throw 'Unsupported authentication format.'
}

function Get-ChatGPTIdentityFingerprint([byte[]]$AuthBytes) {
    if ((Get-ProfileAuthKind $AuthBytes) -ne 'chatgpt') { throw 'ChatGPT authentication is required.' }
    $auth=[Text.Encoding]::UTF8.GetString($AuthBytes) | ConvertFrom-Json
    $inputBytes=[Text.Encoding]::UTF8.GetBytes('codex-switcher-account-v1:'+[string]$auth.tokens.account_id)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash($inputBytes) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose(); [Array]::Clear($inputBytes,0,$inputBytes.Length); $auth=$null }
}

function Get-ProfileSecretPath($Settings,[string]$ProfileId,[ValidateSet('auth','route')][string]$Type) {
    Assert-ProfileId $ProfileId
    return Join-Path $Settings.VaultRoot ($ProfileId+'.'+$Type+'.dpapi')
}

function Write-ProtectedJson([string]$Path,$Value) {
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 30 -Compress))
    try { $encrypted=Protect-CredentialBytes $bytes; Write-AtomicBytes $Path $encrypted }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Read-ProtectedJson([string]$Path) {
    $bytes=Unprotect-CredentialBytes ([IO.File]::ReadAllBytes($Path))
    try { return [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Read-ProfileAuth($Settings,$Profile) {
    $value=Read-ProtectedJson (Get-ProfileSecretPath $Settings $Profile.id auth)
    if ($null -ne $value.PSObject.Properties['schemaVersion']) {
        if ($value.schemaVersion -isnot [int] -or $value.schemaVersion -ne 2 -or $value.kind -cne $Profile.kind) { throw 'Unsupported credential schema.' }
        $bytes=[Convert]::FromBase64String([string]$value.auth)
        if ($Profile.kind -eq 'chatgpt' -and (Get-ChatGPTIdentityFingerprint $bytes) -cne $value.identityFingerprint) { throw 'Credential identity verification failed.' }
    } else { $bytes=[Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Depth 20 -Compress)) }
    if ((Get-ProfileAuthKind $bytes) -cne $Profile.kind) { throw 'Credential type does not match profile.' }
    return ,$bytes
}

function Write-ProfileAuth($Settings,$Profile,[byte[]]$AuthBytes) {
    if ((Get-ProfileAuthKind $AuthBytes) -cne $Profile.kind) { throw 'Credential type does not match profile.' }
    $fingerprint=if ($Profile.kind -eq 'chatgpt') { Get-ChatGPTIdentityFingerprint $AuthBytes } else { $null }
    Write-ProtectedJson (Get-ProfileSecretPath $Settings $Profile.id auth) ([ordered]@{schemaVersion=2; kind=$Profile.kind; identityFingerprint=$fingerprint; auth=[Convert]::ToBase64String($AuthBytes)})
}

function Assert-ProfileRoute($Profile,$Route) {
    if ($null -ne $Route.PSObject.Properties['schemaVersion'] -and ($Route.schemaVersion -isnot [int] -or $Route.schemaVersion -ne 2)) { throw 'Unsupported route schema.' }
    if ($null -ne $Route.PSObject.Properties['legacyLabBootstrap'] -and $Route.legacyLabBootstrap -isnot [bool]) { throw 'Unsupported bootstrap flag.' }
    if ($Route.Provider -cne 'openai' -or $null -eq $Route.Entries) { throw 'Unsupported provider route.' }
    # Built-in provider must never be shadowed by a custom table.
    foreach ($entry in @($Route.Entries)) {
        if ($entry.IsRoot -isnot [bool] -or -not $entry.IsRoot -or $entry.Line -isnot [string] -or $entry.Line -match '[\r\n]') { throw 'Unsupported route entries.' }
        if ($entry.Line -notmatch '^\s*(model|model_provider|openai_base_url|model_reasoning_effort|service_tier|review_model|model_context_window|model_auto_compact_token_limit|model_catalog_json|forced_login_method)\s*=') { throw 'Unknown route setting.' }
    }
    $parsed=Get-ProviderRoute ((@($Route.Entries | Sort-Object Index | ForEach-Object { $_.Line })) -join "`r`n")
    if ($parsed.Provider -cne $Route.Provider -or [string]$parsed.Endpoint -cne [string]$Route.Endpoint) { throw 'Route metadata disagrees with configuration.' }
    if ($Profile.kind -eq 'chatgpt') {
        if (-not [string]::IsNullOrWhiteSpace($Route.Endpoint)) { throw 'ChatGPT profiles require the official route.' }
    } else { $null=Assert-ApiUrl $Route.Endpoint }
}

function Read-ProfileRoute($Settings,$Profile) {
    $route=Read-ProtectedJson (Get-ProfileSecretPath $Settings $Profile.id route)
    Assert-ProfileRoute $Profile $route
    return $route
}

function Write-ProfileRoute($Settings,$Profile,$Route) {
    Assert-ProfileRoute $Profile $Route
    $value=[ordered]@{schemaVersion=2; Provider=$Route.Provider; Endpoint=$Route.Endpoint; Entries=@($Route.Entries);legacyLabBootstrap=(Get-RequestValue $Route legacyLabBootstrap ($Profile.id -eq 'lab'))}
    Write-ProtectedJson (Get-ProfileSecretPath $Settings $Profile.id route) $value
}

function Read-ProfileState($Settings) {
    $state=Read-SwitcherState $Settings
    if ($null -eq $state -or $state.schemaVersion -isnot [int] -or $state.schemaVersion -ne 2) { throw 'Initialize or migrate the profile registry first.' }
    Assert-ProfileId $state.activeProfileId
    if ($state.generation -isnot [int] -or $state.generation -lt 0) { throw 'Invalid state generation.' }
    if ($state.sharedCodexHome -cne $Settings.CanonicalHome) { throw 'State belongs to a different shared home.' }
    return $state
}

function Write-ProfileState($Settings,[string]$ProfileId,[int]$Generation) {
    Assert-ProfileId $ProfileId
    Write-AtomicText (Get-StatePath $Settings) (([ordered]@{schemaVersion=2;activeProfileId=$ProfileId;generation=$Generation;sharedCodexHome=$Settings.CanonicalHome} | ConvertTo-Json)+"`r`n")
}

function Get-TransactionPath($Settings,[ValidateSet('switch','management')][string]$Type) { Join-Path $Settings.VaultRoot ('pending-'+$Type+'.dpapi') }

function Get-TransactionFile($Settings,[string]$Key) {
    switch -Exact ($Key) {
        'registry' { return Get-ProfileRegistryPath $Settings }
        'state' { return Get-StatePath $Settings }
        'auth' { return Join-Path $Settings.CanonicalHome 'auth.json' }
        'config' { return Join-Path $Settings.CanonicalHome 'config.toml' }
        'labCatalog' { return Join-Path $Settings.VaultRoot 'lab-models.json' }
        'apiCatalog' { return Join-Path $Settings.VaultRoot 'api-models.json' }
    }
    if ($Key -cmatch '^(auth|route):(.+)$') { return Get-ProfileSecretPath $Settings $Matches[2] $Matches[1] }
    throw 'Invalid transaction file key.'
}

function Start-ProfileTransaction($Settings,[string]$Type,[string]$Operation,[string[]]$Keys) {
    $path=Get-TransactionPath $Settings $Type
    if (Test-Path -LiteralPath $path) { throw 'Pending operation must be recovered first.' }
    $files=[ordered]@{}
    foreach ($key in $Keys) {
        $target=Get-TransactionFile $Settings $key
        $files[$key]=if (Test-Path -LiteralPath $target -PathType Leaf) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) } else { $null }
    }
    $record=[pscustomobject]@{schemaVersion=2;home=$Settings.CanonicalHome;operation=$Operation;operationId=[guid]::NewGuid().ToString('N');committed=$false;files=[pscustomobject]$files}
    Write-ProtectedJson $path $record
    return $record
}

function Complete-ProfileTransaction($Settings,[string]$Type,$Record) {
    $Record.committed=$true
    Write-ProtectedJson (Get-TransactionPath $Settings $Type) $Record
    Invoke-ProfileFailurePoint $Settings AfterCommitWrite
    Restore-ProfileTransaction $Settings $Type
}

function Restore-ProfileTransaction($Settings,[string]$Type) {
    $path=Get-TransactionPath $Settings $Type
    if (-not (Test-Path -LiteralPath $path)) { return }
    Assert-CodexQuiescent $Settings
    try {
        $record=Read-ProtectedJson $path
        if ($Type -eq 'switch' -and $null -eq $record.PSObject.Properties['schemaVersion']) { Restore-PendingSwitch $Settings; return }
        if ($record.schemaVersion -isnot [int] -or $record.schemaVersion -ne 2 -or $record.home -cne $Settings.CanonicalHome -or $record.operationId -cnotmatch '^[a-f0-9]{32}$' -or $record.committed -isnot [bool]) { throw 'Invalid transaction header.' }
        if ($record.operation -cnotin @('migrate','switch','add','update','rename','delete')) { throw 'Unknown transaction operation.' }
        $decoded=@{}; $paths=@{}
        foreach ($property in $record.files.PSObject.Properties) {
            $paths[$property.Name]=Get-TransactionFile $Settings $property.Name
            $decoded[$property.Name]=if ($null -eq $property.Value) { $null } else { [Convert]::FromBase64String([string]$property.Value) }
        }
        if ($paths.Count -eq 0) { throw 'Empty transaction.' }
        if (-not $record.committed) {
            foreach ($key in $paths.Keys) {
                if ($null -ne $decoded[$key]) { Write-AtomicBytes $paths[$key] $decoded[$key] }
                elseif (Test-Path -LiteralPath $paths[$key]) { Remove-Item -LiteralPath $paths[$key] -Force }
            }
        }
        $trash=Join-Path $Settings.VaultRoot ('trash\'+$record.operationId)
        Remove-ProfileOperationDirectory $Settings $trash 'trash'
        Remove-Item -LiteralPath $path -Force
    } catch { throw 'Profile recovery could not be completed. Preserve pending recovery files and repair the installation.' }
}

function Remove-ProfileOperationDirectory($Settings,[string]$Path,[ValidateSet('staging','trash')][string]$Area) {
    $parent=[IO.Path]::GetFullPath((Join-Path $Settings.VaultRoot $Area)).TrimEnd('\')
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($full) -ine $parent -or [IO.Path]::GetFileName($full) -cnotmatch '^[a-f0-9]{32}$') { throw 'Unsafe operation directory.' }
    if (Test-Path -LiteralPath $full) {
        $items=@(Get-Item -LiteralPath $full -Force)+@(Get-ChildItem -LiteralPath $full -Recurse -Force)
        if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Operation directory contains a reparse point.' }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
    if ((Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) { Remove-Item -LiteralPath $parent -Force }
}

function Restore-AllPendingOperations($Settings) {
    Assert-CodexQuiescent $Settings
    Restore-ProfileTransaction $Settings switch
    Restore-ProfileTransaction $Settings management
    $staging=Join-Path $Settings.VaultRoot 'staging'
    if (Test-Path -LiteralPath $staging) {
        foreach ($item in @(Get-ChildItem -LiteralPath $staging -Directory -Force)) { Remove-ProfileOperationDirectory $Settings $item.FullName staging }
    }
}

function Assert-ActiveProfileIdentity($Settings,$Profile) {
    $saved=Read-ProfileAuth $Settings $Profile
    $current=Read-AuthBytes (Join-Path $Settings.CanonicalHome 'auth.json')
    try {
        if ((Get-ProfileAuthKind $current) -cne $Profile.kind) { throw 'Active authentication type mismatch.' }
        if ($Profile.kind -eq 'chatgpt') {
            if ((Get-ChatGPTIdentityFingerprint $current) -cne (Get-ChatGPTIdentityFingerprint $saved)) { throw 'Active account identity mismatch. No credentials were saved.' }
        } else {
            $a=[Text.Encoding]::UTF8.GetString($current)|ConvertFrom-Json; $b=[Text.Encoding]::UTF8.GetString($saved)|ConvertFrom-Json
            if ($a.OPENAI_API_KEY -cne $b.OPENAI_API_KEY) { throw 'Active API key mismatch. No credentials were saved.' }
        }
    } finally { [Array]::Clear($saved,0,$saved.Length); [Array]::Clear($current,0,$current.Length) }
}

function Get-CurrentCredentialsPath($Settings) { Join-Path $Settings.CanonicalHome 'auth.json' }

function Get-ProfileAuthFingerprint($Settings,$Profile) {
    # Read the raw stored credential without the identity check so a drifted
    # active profile can still be compared with the live authentication.
    $value=Read-ProtectedJson (Get-ProfileSecretPath $Settings $Profile.id auth)
    if ($null -ne $value.PSObject.Properties['schemaVersion']) {
        if ($value.schemaVersion -isnot [int] -or $value.schemaVersion -ne 2 -or $value.kind -cne $Profile.kind) { throw 'Unsupported credential schema.' }
        $bytes=[Convert]::FromBase64String([string]$value.auth)
    } else { $bytes=[Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Depth 20 -Compress)) }
    try {
        if ((Get-ProfileAuthKind $bytes) -cne $Profile.kind) { throw 'Credential type does not match profile.' }
        if ($Profile.kind -cne 'chatgpt') { return $null }
        return Get-ChatGPTIdentityFingerprint $bytes
    } finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Get-CurrentAuthFingerprint($Settings) {
    $bytes=Read-AuthBytes (Get-CurrentCredentialsPath $Settings)
    try { return Get-ChatGPTIdentityFingerprint $bytes }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Get-MatchingProfileByCurrentAuth($Settings,$Registry,$ActiveProfile) {
    # Case 1: the live authentication already belongs to another registered
    # ChatGPT profile, so state alone drifted and no credential needs a rewrite.
    if ($ActiveProfile.kind -cne 'chatgpt') { return $null }
    $current=Get-CurrentAuthFingerprint $Settings
    $matches=@()
    foreach ($p in @($Registry.profiles | Where-Object { $_.kind -eq 'chatgpt' })) {
        $stored=Get-ProfileAuthFingerprint $Settings $p
        if ($null -ne $stored -and $stored -ceq $current) { $matches+=@($p) }
    }
    if ($matches.Count -ne 1) { return $null }
    return $matches[0]
}

function Sync-ActiveProfileIdentity($Settings,$Registry,$ActiveProfile) {
    # Returns the profile the live authentication actually belongs to. The
    # active profile itself always wins when it already matches.
    try { Assert-ActiveProfileIdentity $Settings $ActiveProfile; return $ActiveProfile } catch { }
    $restored=Get-MatchingProfileByCurrentAuth $Settings $Registry $ActiveProfile
    if ($null -eq $restored) {
        throw "The signed-in account does not match the recorded active profile '$($ActiveProfile.displayName)'. Run Repair, or re-login with the original account for that profile."
    }
    $state=Read-ProfileState $Settings
    $tx=Start-ProfileTransaction $Settings management switch @('state')
    try {
        Write-ProfileState $Settings $restored.id $state.generation
        Complete-ProfileTransaction $Settings management $tx
    } catch { Restore-ProfileTransaction $Settings management; throw }
    Write-SwitchAudit $Settings 'Repair' $ActiveProfile.id $restored.id
    return $restored
}

function Test-ProfileBackend($Settings,$Profile) {
    if ($Settings.SkipCodexStatus) { return $true }
    $info=New-IsolatedCodexStartInfo (Get-Command codex.exe -ErrorAction Stop).Source $Settings.CanonicalHome 'login status'
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
    try {
        if (-not $process.WaitForExit(20000)) { $process.Kill(); $process.WaitForExit(); return $false }
        $text=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
        $expected=if($Profile.kind -eq 'chatgpt'){'(?i)logged in using ChatGPT'}else{'(?i)logged in using an API key'}
        return $process.ExitCode -eq 0 -and $text -match $expected
    } finally { $text=$null; $stdout=$null; $stderr=$null; $process.Dispose() }
}

function Convert-LegacyProfiles($Settings) {
    Restore-AllPendingOperations $Settings
    if (Test-Path -LiteralPath (Get-ProfileRegistryPath $Settings)) {
        $r=Read-ProfileRegistry $Settings; $s=Read-ProfileState $Settings
        $null=Get-ProfileById $r $s.activeProfileId
        return $r
    }
    $state=Read-SwitcherState $Settings
    if ($null -eq $state -or $state.schemaVersion -isnot [int] -or $state.schemaVersion -ne 1 -or $state.activeProfile -notin @('Personal','Lab') -or $state.generation -isnot [int]) { throw 'Unsupported legacy state. Initialize the existing installation first.' }
    $r=New-ProfileRegistry $Settings.CanonicalHome
    $r.profiles=@((New-FixedProfileRecord personal (-join ([char[]]@(0x4e2a,0x4eba))) chatgpt 0),(New-FixedProfileRecord lab (-join ([char[]]@(0x5b9e,0x9a8c,0x5ba4))) responses_api 1))
    foreach ($p in $r.profiles) { $bytes=Read-ProfileAuth $Settings $p; [Array]::Clear($bytes,0,$bytes.Length); $null=Read-ProfileRoute $Settings $p }
    $active=Get-ProfileById $r $state.activeProfile.ToLowerInvariant()
    Assert-ActiveProfileIdentity $Settings $active
    Assert-ProfileRoute $active (Get-ProviderRoute ([IO.File]::ReadAllText((Join-Path $Settings.CanonicalHome 'config.toml'))))
    if (-not (Test-ProfileBackend $Settings $active)) { throw 'Legacy authentication could not be verified.' }
    $tx=Start-ProfileTransaction $Settings management migrate @('registry','state')
    try {
        Write-ProfileRegistry $Settings $r
        Invoke-ProfileFailurePoint $Settings MigrateAfterRegistry
        Write-ProfileState $Settings $active.id $state.generation
        Invoke-ProfileFailurePoint $Settings MigrateAfterState
        Complete-ProfileTransaction $Settings management $tx
    } catch { Restore-ProfileTransaction $Settings management; throw }
    return $r
}

function Initialize-CurrentProfile($Settings) {
    # A clean installation needs one existing login, not the author's legacy homes.
    if ((Test-Path (Get-ProfileRegistryPath $Settings)) -or
        @((Get-ChildItem -LiteralPath $Settings.VaultRoot -Filter '*.dpapi' -ErrorAction SilentlyContinue)).Count) {
        throw 'Partial profile vault found. Restore its state from backup before initializing.'
    }
    $authPath=Join-Path $Settings.CanonicalHome 'auth.json'
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) {
        throw 'No file-based Codex login found. Run: codex -c cli_auth_credentials_store="file" login. Then close Codex and retry Setup.'
    }
    $bytes=Read-AuthBytes $authPath
    try {
        $kind=Get-ProfileAuthKind $bytes
        $configPath=Join-Path $Settings.CanonicalHome 'config.toml'
        $config=if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { '' }
        if ([string]::IsNullOrWhiteSpace($config)) { $config='model_provider = "openai"' }
        $route=Get-ProviderRoute $config
        if ($route.Provider -cne 'openai') { throw 'Import supports the built-in openai provider only. Keep a backup and use a standard Codex login before Setup; add custom Responses API profiles in the picker afterward.' }
        if ($kind -eq 'responses_api' -and [string]::IsNullOrWhiteSpace($route.Endpoint)) {
            # An official API key without an override uses the official Responses endpoint.
            $rootLines=@($route.Entries | Sort-Object Index | ForEach-Object { $_.Line })
            $route=Get-ProviderRoute ((@('openai_base_url = "https://api.openai.com/v1"')+$rootLines) -join "`r`n")
        }
        $registry=Add-ProfileRecord (New-ProfileRegistry $Settings.CanonicalHome) 'My account' $kind
        $profile=@($registry.profiles)[0]
        Assert-ProfileRoute $profile $route
        Set-PrivateDirectoryAcl $Settings.VaultRoot
        $tx=Start-ProfileTransaction $Settings management migrate @('registry','state','config',('auth:'+$profile.id),('route:'+$profile.id))
        try {
            Write-ProfileAuth $Settings $profile $bytes
            Write-ProfileRoute $Settings $profile $route
            Write-AtomicText $configPath (Set-ProviderRoute $config $route)
            Update-SharedConfig $Settings
            if (-not (Test-ProfileBackend $Settings $profile)) { throw 'Current authentication/configuration could not be verified.' }
            Write-ProfileRegistry $Settings $registry
            Invoke-ProfileFailurePoint $Settings MigrateAfterRegistry
            Write-ProfileState $Settings $profile.id 0
            Complete-ProfileTransaction $Settings management $tx
        } catch { Restore-ProfileTransaction $Settings management; throw }
    } finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Initialize-MultiProfileSwitcher($Settings,[switch]$WhatIfOnly) {
    if ($WhatIfOnly) { Get-ProfileStatus $Settings; return }
    Restore-AllPendingOperations $Settings
    if ($null -eq (Read-SwitcherState $Settings)) {
        if (Test-Path -LiteralPath (Join-Path $Settings.LabHome 'auth.json')) { Invoke-InitializeSwitcher $Settings }
        else { Initialize-CurrentProfile $Settings }
    }
    $r=Convert-LegacyProfiles $Settings
    $s=Read-ProfileState $Settings
    $p=Get-ProfileById $r $s.activeProfileId
    # Repair must be able to clear a drifted active profile instead of failing.
    $p=Sync-ActiveProfileIdentity $Settings $r $p
    $null=Read-ProfileRoute $Settings $p
    if (-not (Test-ProfileBackend $Settings $p)) { throw 'Active authentication could not be verified.' }
    Get-ProfileStatus $Settings
}

function Invoke-ProfileSwitch($Settings,[string]$TargetProfileId,[switch]$WhatIfOnly,[switch]$DoNotLaunch,[string]$FailurePoint='None') {
    Assert-ProfileId $TargetProfileId
    if ($WhatIfOnly) { Get-ProfileStatus $Settings; return }
    $mutex=Enter-SwitcherMutex $Settings
    try {
        $registry=Convert-LegacyProfiles $Settings; $state=Read-ProfileState $Settings
        $active=Get-ProfileById $registry $state.activeProfileId; $target=Get-ProfileById $registry $TargetProfileId
        # A re-login can leave auth.json holding another registered account while
        # state.json still names the previous active profile. Realign state to the
        # profile the live credentials already belong to instead of failing: the
        # earlier failure left the picker stuck and could not be repaired.
        $active=Sync-ActiveProfileIdentity $Settings $registry $active
        $currentRoute=Get-ProviderRoute ([IO.File]::ReadAllText((Join-Path $Settings.CanonicalHome 'config.toml')))
        Assert-ProfileRoute $active $currentRoute
        $activeSavedRoute=Read-ProfileRoute $Settings $active
        if ($active.id -eq 'lab') { $currentRoute | Add-Member -NotePropertyName legacyLabBootstrap -NotePropertyValue (Get-RequestValue $activeSavedRoute legacyLabBootstrap $true) }
        $targetRoute=Read-ProfileRoute $Settings $target
        $targetBytes=Read-ProfileAuth $Settings $target
        if ($target.id -eq $active.id) { $targetBytes=Read-AuthBytes (Join-Path $Settings.CanonicalHome 'auth.json'); $targetRoute=Read-ProfileRoute $Settings $active }
        if (-not (Test-ProfileBackend $Settings $active)) { throw 'Active authentication/configuration is invalid.' }
        $keys=@('auth','config','state',('auth:'+$active.id),('route:'+$active.id))
        if ($target.id -eq 'lab') { $keys+=@('route:lab','labCatalog') }
        if ($target.kind -eq 'responses_api') { $keys+=@('apiCatalog','labCatalog') }
        $tx=Start-ProfileTransaction $Settings switch switch ($keys | Select-Object -Unique)
        try {
            Write-ProfileAuth $Settings $active (Read-AuthBytes (Join-Path $Settings.CanonicalHome 'auth.json'))
            Write-ProfileRoute $Settings $active $currentRoute
            if ($target.id -eq $active.id) { $targetBytes=Read-ProfileAuth $Settings $active; $targetRoute=$currentRoute }
            if ($target.id -eq 'lab' -and (Get-RequestValue $targetRoute legacyLabBootstrap $true)) { $targetRoute=ConvertTo-LabBootstrapRoute $targetRoute $Settings; Write-ProfileRoute $Settings $target $targetRoute }
            elseif ($target.kind -eq 'responses_api') { $targetRoute=Add-ApiModelCatalogRoute $targetRoute $Settings }
            $config=[IO.File]::ReadAllText((Join-Path $Settings.CanonicalHome 'config.toml'))
            Write-AtomicText (Join-Path $Settings.CanonicalHome 'config.toml') (Set-ProviderRoute $config $targetRoute)
            Invoke-ProfileFailurePoint $Settings 'AfterConfigWrite'
            Write-AtomicBytes (Join-Path $Settings.CanonicalHome 'auth.json') $targetBytes
            if ($FailurePoint -eq 'AfterCredentialWrite' -and $Settings.TestMode) { throw 'Injected failure after credential write.' }
            Invoke-ProfileFailurePoint $Settings 'AfterAuthWrite'
            Assert-ActiveProfileIdentity $Settings $target
            if (-not (Test-ProfileBackend $Settings $target)) { throw 'Target authentication/configuration could not be verified.' }
            Write-ProfileState $Settings $target.id ($state.generation+1)
            Invoke-ProfileFailurePoint $Settings 'AfterStateWrite'
            Complete-ProfileTransaction $Settings switch $tx
        } catch { Restore-ProfileTransaction $Settings switch; throw }
        finally { [Array]::Clear($targetBytes,0,$targetBytes.Length) }
        Write-SwitchAudit $Settings Switch $active.id $target.id
        if (-not $DoNotLaunch) {
            try { Start-SharedChatGPT $Settings }
            catch { throw 'Profile switched to the selected profile, but the desktop app could not be launched. Retry the same profile.' }
        }
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

function Invoke-ProfileFailurePoint($Settings,[string]$Name) {
    if ($Settings.TestMode -and $env:CODEX_SWITCHER_CRASH_POINT -ceq $Name) { Stop-Process -Id $PID -Force }
}

function Assert-ApiUrl([string]$BaseUrl) {
    $uri=$null
    if (-not [Uri]::TryCreate($BaseUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('https','http') -or ($uri.Scheme -eq 'http' -and -not $uri.IsLoopback) -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $BaseUrl -match '[\s"''\\]') { throw 'Base URL must be HTTPS (or loopback HTTP), without credentials, query or fragment.' }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Assert-ModelName([string]$Model) {
    if ($Model -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$') { throw 'Default model must be nonempty safe text (letters, digits, dot, slash, colon, dash or underscore).' }
    return $Model
}

function New-ResponsesRoute([string]$BaseUrl,[string]$Model) {
    $url=Assert-ApiUrl $BaseUrl; $modelName=Assert-ModelName $Model
    $route=Get-ProviderRoute ("model_provider = `"openai`"`r`nopenai_base_url = `"$url`"`r`nmodel = `"$modelName`"`r`n")
    $route | Add-Member -NotePropertyName legacyLabBootstrap -NotePropertyValue $false
    return $route
}

function Get-ProfileStatus($Settings) {
    $pending=Test-Path -LiteralPath (Get-TransactionPath $Settings switch)
    $managementPending=Test-Path -LiteralPath (Get-TransactionPath $Settings management)
    $state=Read-SwitcherState $Settings
    if (-not (Test-Path -LiteralPath (Get-ProfileRegistryPath $Settings))) {
        if ($null -ne $state -and $state.schemaVersion -ne 1) { throw 'Registry is missing for the current state schema.' }
        return [pscustomobject]@{registrySchema=1;activeProfileId='';profiles=@();recoveryPending=$pending;managementRecoveryPending=$managementPending;message='Run Repair to migrate the existing installation.'}
    }
    $r=Read-ProfileRegistry $Settings; $s=Read-ProfileState $Settings
    $active=Get-ProfileById $r $s.activeProfileId
    $list=@(foreach ($p in ($r.profiles | Sort-Object sortOrder)) {
        $status='Ready'; $hostName=''; $baseUrl=''; $model=''
        try {
            $bytes=Read-ProfileAuth $Settings $p; [Array]::Clear($bytes,0,$bytes.Length)
            $route=Read-ProfileRoute $Settings $p
            if ($p.kind -eq 'responses_api') { $baseUrl=$route.Endpoint; $hostName=([Uri]$baseUrl).Host }
            foreach($entry in @($route.Entries)) { if ($entry.Line -match '^\s*model\s*=\s*"([^"]+)"') { $model=$Matches[1] } }
        } catch { $status='NeedsRepair'; $baseUrl=''; $hostName=''; $model='' }
        [pscustomobject]@{id=$p.id;displayName=$p.displayName;kind=$p.kind;sortOrder=$p.sortOrder;status=$status;host=$hostName;baseUrl=$baseUrl;model=$model}
    })
    # A drifted active profile must stay visible: raising here broke the whole
    # status list, so the picker could neither switch nor repair and stayed on
    # the switching screen forever.
    $identityMismatch=$false
    try { Assert-ActiveProfileIdentity $Settings $active } catch { $identityMismatch=$true }
    if ($identityMismatch) {
        $list=@($list | ForEach-Object {
            if ($_.id -ceq $active.id) {
                [pscustomobject]@{id=$_.id;displayName=$_.displayName;kind=$_.kind;sortOrder=$_.sortOrder;status='NeedsRepair';host=$_.host;baseUrl=$_.baseUrl;model=$_.model}
            } else { $_ }
        })
    }
    return [pscustomobject]@{registrySchema=2;profileCount=$list.Count;activeProfileId=$active.id;activeDisplayName=$active.displayName;activeKind=$active.kind;profiles=$list;recoveryPending=$pending;managementRecoveryPending=$managementPending;activeIdentityMismatch=$identityMismatch}
}

function Import-ChatGPTCredential($Settings,[string]$DisplayName,[byte[]]$AuthBytes,[string]$ProfileId='') {
    $fingerprint=Get-ChatGPTIdentityFingerprint $AuthBytes
    $registry=Read-ProfileRegistry $Settings
    if ($ProfileId) {
        $profile=Get-ProfileById $registry $ProfileId
        if ($profile.kind -ne 'chatgpt') { throw 'ChatGPT profile required.' }
        $old=Read-ProfileAuth $Settings $profile
        try { if ((Get-ChatGPTIdentityFingerprint $old) -cne $fingerprint) { throw 'Login belongs to a different account. Add it as a new profile.' } }
        finally { [Array]::Clear($old,0,$old.Length) }
        $updated=$registry; $operation='update'
    } else {
        foreach ($p in $registry.profiles | Where-Object kind -eq 'chatgpt') {
            $old=Read-ProfileAuth $Settings $p
            try { if ((Get-ChatGPTIdentityFingerprint $old) -ceq $fingerprint) { throw 'This account already exists. Re-login to the existing profile.' } }
            finally { [Array]::Clear($old,0,$old.Length) }
        }
        $updated=Add-ProfileRecord $registry $DisplayName chatgpt
        $profile=@($updated.profiles)[-1]; $operation='add'
    }
    $keys=@('registry',('auth:'+$profile.id),('route:'+$profile.id))
    $state=Read-ProfileState $Settings
    if ($ProfileId -and $state.activeProfileId -eq $ProfileId) { $keys+=@('auth','config') }
    $tx=Start-ProfileTransaction $Settings management $operation $keys
    try {
        Write-ProfileAuth $Settings $profile $AuthBytes
        if (-not $ProfileId) { Write-ProfileRoute $Settings $profile (Get-ProviderRoute 'model_provider = "openai"') }
        if ($ProfileId -and $state.activeProfileId -eq $ProfileId) { Write-AtomicBytes (Join-Path $Settings.CanonicalHome 'auth.json') $AuthBytes }
        Write-ProfileRegistry $Settings $updated
        Complete-ProfileTransaction $Settings management $tx
    } catch { Restore-ProfileTransaction $Settings management; throw }
    return $profile
}

function Add-ResponsesApiProfile($Settings,$Request) { Invoke-ApiProfileWrite $Settings $Request '' }
function Update-ResponsesApiProfile($Settings,$Request,[string]$ProfileId) { Invoke-ApiProfileWrite $Settings $Request $ProfileId }

function Invoke-ApiProfileWrite($Settings,$Request,[string]$ProfileId) {
    $registry=Read-ProfileRegistry $Settings; $state=Read-ProfileState $Settings
    $route=New-ResponsesRoute (Get-RequestValue $Request baseUrl '') (Get-RequestValue $Request model '')
    Assert-RouteConfigLoads $Settings $route
    $key=Get-RequestValue $Request apiKey ''
    if ($key -isnot [string] -or $key -match '[\x00-\x20\x7f]') { throw 'API key must not contain whitespace or control characters.' }
    if ($ProfileId) {
        $profile=Get-ProfileById $registry $ProfileId
        if ($profile.kind -ne 'responses_api') { throw 'An API profile is required.' }
        # Editing the endpoint/model must not discard an explicit catalog.
        $previousRoute=Read-ProfileRoute $Settings $profile
        if ($state.activeProfileId -eq $ProfileId) { $previousRoute=Get-ProviderRoute ([IO.File]::ReadAllText((Join-Path $Settings.CanonicalHome 'config.toml'))) }
        $route.Entries=@($route.Entries)+@($previousRoute.Entries | Where-Object { $_.IsRoot -and $_.Line -match '^\s*model_catalog_json\s*=' })
        if (-not $key) {
            $oldBytes=Read-ProfileAuth $Settings $profile
            try { $key=([Text.Encoding]::UTF8.GetString($oldBytes)|ConvertFrom-Json).OPENAI_API_KEY }
            finally { [Array]::Clear($oldBytes,0,$oldBytes.Length) }
        }
        $updated=Rename-ProfileRecord $registry $ProfileId (Get-RequestValue $Request displayName $profile.displayName)
        $profile=Get-ProfileById $updated $ProfileId; $operation='update'
    } else {
        $updated=Add-ProfileRecord $registry (Get-RequestValue $Request displayName '') responses_api
        $profile=@($updated.profiles)[-1]; $operation='add'
    }
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'API key is required.' }
    $bytes=[Text.Encoding]::UTF8.GetBytes((@{auth_mode='apikey';OPENAI_API_KEY=$key}|ConvertTo-Json -Compress))
    $keys=@('registry',('auth:'+$profile.id),('route:'+$profile.id))
    $activeEdit=$ProfileId -and $state.activeProfileId -eq $ProfileId
    if ($activeEdit) { $keys+=@('auth','config','apiCatalog','labCatalog') }
    $tx=Start-ProfileTransaction $Settings management $operation $keys
    try {
        if ($activeEdit) { $route=Add-ApiModelCatalogRoute $route $Settings }
        Write-ProfileAuth $Settings $profile $bytes
        Write-ProfileRoute $Settings $profile $route
        Invoke-ProfileFailurePoint $Settings AfterSecretWrite
        if ($activeEdit) {
            Write-AtomicBytes (Join-Path $Settings.CanonicalHome 'auth.json') $bytes
            $config=[IO.File]::ReadAllText((Join-Path $Settings.CanonicalHome 'config.toml'))
            Write-AtomicText (Join-Path $Settings.CanonicalHome 'config.toml') (Set-ProviderRoute $config $route)
            if (-not (Test-ProfileBackend $Settings $profile)) { throw 'API configuration could not be loaded by Codex.' }
        }
        Write-ProfileRegistry $Settings $updated
        Invoke-ProfileFailurePoint $Settings AfterRegistryWrite
        Complete-ProfileTransaction $Settings management $tx
    } catch { Restore-ProfileTransaction $Settings management; throw }
    finally { [Array]::Clear($bytes,0,$bytes.Length); $key=$null }
    return $profile
}

function Assert-RouteConfigLoads($Settings,$Route) {
    if ($Settings.SkipCodexStatus) { return }
    $staging=Join-Path $Settings.VaultRoot ('staging\'+[guid]::NewGuid().ToString('N'))
    Set-PrivateDirectoryAcl $staging
    try {
        Write-AtomicText (Join-Path $staging 'config.toml') (Set-ProviderRoute "cli_auth_credentials_store = `"file`"`r`n" $Route)
        # Only a fixed fake key is needed for local syntax/auth-mode validation.
        Write-AtomicText (Join-Path $staging 'auth.json') '{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_CONFIG_CHECK_LOCAL_TEST_ONLY"}'
        $checkSettings=[pscustomobject]@{CanonicalHome=$staging;SkipCodexStatus=$false}
        if (-not (Test-ProfileBackend $checkSettings ([pscustomobject]@{kind='responses_api'}))) { throw 'Codex could not load the profile configuration.' }
    } finally { Remove-ProfileOperationDirectory $Settings $staging staging }
}

function Rename-Profile($Settings,[string]$ProfileId,[string]$DisplayName) {
    $updated=Rename-ProfileRecord (Read-ProfileRegistry $Settings) $ProfileId $DisplayName
    $tx=Start-ProfileTransaction $Settings management rename @('registry')
    try {
        Write-ProfileRegistry $Settings $updated
        Invoke-ProfileFailurePoint $Settings AfterRegistryWrite
        Complete-ProfileTransaction $Settings management $tx
    } catch { Restore-ProfileTransaction $Settings management; throw }
    return Get-ProfileById $updated $ProfileId
}

function Remove-Profile($Settings,[string]$ProfileId) {
    $registry=Read-ProfileRegistry $Settings; $state=Read-ProfileState $Settings
    $updated=Remove-ProfileRecord $registry $ProfileId $state.activeProfileId
    $valid=0
    foreach ($p in $updated.profiles) {
        try { $bytes=Read-ProfileAuth $Settings $p; [Array]::Clear($bytes,0,$bytes.Length); $null=Read-ProfileRoute $Settings $p; $valid++ } catch { }
    }
    if ($valid -eq 0) { throw 'The last valid profile cannot be deleted.' }
    $tx=Start-ProfileTransaction $Settings management delete @('registry',('auth:'+$ProfileId),('route:'+$ProfileId))
    try {
        $trash=Join-Path $Settings.VaultRoot ('trash\'+$tx.operationId)
        New-Item -ItemType Directory -Path $trash -Force | Out-Null
        foreach ($kind in @('auth','route')) {
            $source=Get-ProfileSecretPath $Settings $ProfileId $kind
            if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination (Join-Path $trash ($ProfileId+'.'+$kind+'.dpapi')) }
        }
        Invoke-ProfileFailurePoint $Settings AfterTrashMove
        Write-ProfileRegistry $Settings $updated
        Invoke-ProfileFailurePoint $Settings AfterRegistryWrite
        Complete-ProfileTransaction $Settings management $tx
    } catch { Restore-ProfileTransaction $Settings management; throw }
    return [pscustomobject]@{id=$ProfileId;deleted=$true}
}

function New-IsolatedCodexStartInfo([string]$CodexPath,[string]$CodexHome,[string]$Arguments) {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$CodexPath; $info.Arguments=$Arguments
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.WorkingDirectory=$CodexHome
    $info.EnvironmentVariables['CODEX_HOME']=$CodexHome
    foreach ($name in @('OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN','OPENAI_BASE_URL','CODEX_SQLITE_HOME','CODEX_APP_SERVER_OPENAI_BASE_URL','CODEX_APP_SERVER_CHATGPT_BASE_URL')) { $null=$info.EnvironmentVariables.Remove($name) }
    return $info
}

function Invoke-CodexBrowserLogin([string]$CodexPath,[string]$CodexHome,[string]$CancelPath='', [int]$TimeoutSeconds=600) {
    if ($CancelPath) {
        $full=[IO.Path]::GetFullPath($CancelPath)
        if ([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($full) -cnotmatch '^codex-enrollment-cancel-[a-f0-9]{32}\.flag$') { throw 'Invalid cancellation marker.' }
    }
    $info=New-IsolatedCodexStartInfo $CodexPath $CodexHome 'login'
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    # Only the short OAuth CLI owns these pipes; desktop launches never use this path.
    $outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync()
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        while (-not $process.WaitForExit(200)) {
            if (($CancelPath -and (Test-Path -LiteralPath $CancelPath)) -or [DateTime]::UtcNow -gt $deadline) {
                $process.Kill(); $process.WaitForExit(); throw 'Browser login was cancelled or timed out.'
            }
        }
        if ($process.ExitCode -ne 0) { throw 'Browser login failed or was cancelled.' }
        if ($CancelPath -and (Test-Path -LiteralPath $CancelPath)) { throw 'Browser login was cancelled.' }
    } finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose(); $outTask=$null; $errTask=$null
    }
}

function Add-ChatGPTProfile($Settings,[string]$DisplayName,[string]$CodexPath='', [string]$ProfileId='', [string]$CancelPath='') {
    $name=Normalize-ProfileDisplayName $DisplayName
    if (-not $CodexPath) { $CodexPath=(Get-Command codex.exe -ErrorAction Stop).Source }
    Assert-CodexQuiescent $Settings
    $operationId=[guid]::NewGuid().ToString('N')
    $staging=Join-Path $Settings.VaultRoot ('staging\'+$operationId)
    Set-PrivateDirectoryAcl $staging
    try {
        Write-AtomicText (Join-Path $staging 'config.toml') "cli_auth_credentials_store = `"file`"`r`n"
        Invoke-CodexBrowserLogin $CodexPath $staging $CancelPath
        $bytes=Read-AuthBytes (Join-Path $staging 'auth.json')
        try { return Import-ChatGPTCredential $Settings $name $bytes $ProfileId }
        finally { [Array]::Clear($bytes,0,$bytes.Length) }
    } finally { Remove-ProfileOperationDirectory $Settings $staging staging }
}

function Update-ChatGPTLogin($Settings,[string]$ProfileId,[string]$CodexPath='', [string]$CancelPath='') {
    $profile=Get-ProfileById (Read-ProfileRegistry $Settings) $ProfileId
    return Add-ChatGPTProfile $Settings $profile.displayName $CodexPath $ProfileId $CancelPath
}

function Test-ResponsesApiConnection($Settings,$Request) {
    if ((Get-RequestValue $Request confirmCost $false) -ne $true) { throw 'Connection test requires explicit cost confirmation.' }
    $route=New-ResponsesRoute (Get-RequestValue $Request baseUrl '') (Get-RequestValue $Request model '')
    $key=Get-RequestValue $Request apiKey ''
    $id=Get-RequestValue $Request profileId ''
    if (-not $key -and $id) {
        $p=Get-ProfileById (Read-ProfileRegistry $Settings) $id
        if ($p.kind -ne 'responses_api') { throw 'API profile required.' }
        $bytes=Read-ProfileAuth $Settings $p
        try { $key=([Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json).OPENAI_API_KEY } finally { [Array]::Clear($bytes,0,$bytes.Length) }
    }
    if ([string]::IsNullOrWhiteSpace($key)) { throw 'API key is required.' }
    $staging=Join-Path $Settings.VaultRoot ('staging\'+[guid]::NewGuid().ToString('N'))
    Set-PrivateDirectoryAcl $staging
    try {
        Write-AtomicText (Join-Path $staging 'config.toml') ((Set-ProviderRoute "cli_auth_credentials_store = `"file`"`r`n" $route)+"`r`n[features]`r`nplugins = false`r`n[analytics]`r`nenabled = false`r`n")
        $info=New-IsolatedCodexStartInfo (Get-Command codex.exe).Source $staging 'exec --ephemeral --skip-git-repo-check --sandbox read-only --color never "Reply OK only. Do not use tools."'
        $info.EnvironmentVariables['OPENAI_API_KEY']=$key
        $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $process=[Diagnostics.Process]::Start($info)
        $outTask=$process.StandardOutput.ReadToEndAsync(); $errTask=$process.StandardError.ReadToEndAsync()
        try {
            if (-not $process.WaitForExit(60000)) { $process.Kill(); $process.WaitForExit(); return [pscustomobject]@{success=$false;message='Connection test timed out. You can still save this profile.'} }
            $ok=$process.ExitCode -eq 0
            return [pscustomobject]@{success=$ok;message=$(if($ok){'Connection test succeeded.'}else{'Connection test failed. Check endpoint, model, key and quota; offline saving remains available.'})}
        } finally { $process.Dispose(); $outTask=$null; $errTask=$null }
    } finally { $key=$null; Remove-ProfileOperationDirectory $Settings $staging staging }
}

function Invoke-ProfileManagement($Settings,$Request) {
    $action=Get-RequestValue $Request action ''
    if ($action -cnotin @('add_api','update_api','rename','delete','add_chatgpt','relogin','test_api')) { throw 'Unsupported management action.' }
    $mutex=Enter-SwitcherMutex $Settings
    try {
        $registry=Convert-LegacyProfiles $Settings
        $id=Get-RequestValue $Request profileId ''
        if ($id) { Assert-ProfileId $id }
        $result=switch -Exact ($action) {
            'add_api' { Add-ResponsesApiProfile $Settings $Request }
            'update_api' { if (-not $id) { throw 'Profile ID is required.' }; Update-ResponsesApiProfile $Settings $Request $id }
            'rename' { Rename-Profile $Settings $id (Get-RequestValue $Request displayName '') }
            'delete' { Remove-Profile $Settings $id }
            'add_chatgpt' { Add-ChatGPTProfile $Settings (Get-RequestValue $Request displayName '') -CancelPath (Get-RequestValue $Request cancelPath '') }
            'relogin' { Update-ChatGPTLogin $Settings $id -CancelPath (Get-RequestValue $Request cancelPath '') }
            'test_api' { Test-ResponsesApiConnection $Settings $Request }
        }
        Write-SwitchAudit $Settings $action '' $id
        return $result
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
