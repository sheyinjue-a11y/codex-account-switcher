[CmdletBinding(DefaultParameterSetName = 'Switch')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Switch')]
    [Alias('Profile')][string]$ProfileId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Initialize')]
    [switch]$Initialize,

    [Parameter(Mandatory = $true, ParameterSetName = 'Status')]
    [switch]$Status,

    [Parameter(Mandatory = $true, ParameterSetName = 'StatusJson')][switch]$StatusJson,
    [Parameter(Mandatory = $true, ParameterSetName = 'Manage')][switch]$ManageStdin,
    [Parameter(Mandatory = $true, ParameterSetName = 'Load')][switch]$LoadOnly,

    [switch]$DryRun,

    [Parameter(ParameterSetName = 'Switch')]
    [switch]$NoLaunch,

    [Parameter(DontShow = $true)]
    [string]$TestSettings,

    [Parameter(DontShow = $true)]
    [ValidateSet('None', 'AfterCredentialWrite')]
    [string]$InjectFailure = 'None'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = Get-NormalizedPath -Path $Path
    $fullRoot = Get-NormalizedPath -Path $Root
    return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-SwitcherSettings {
    param([string]$TestSettingsPath)

    if ($TestSettingsPath) {
        if ($env:CODEX_SWITCHER_TEST_MODE -ne '1') {
            throw 'Test settings are accepted only when CODEX_SWITCHER_TEST_MODE=1.'
        }

        $testConfig = Get-Content -LiteralPath $TestSettingsPath -Raw | ConvertFrom-Json
        $required = @('TestRoot', 'CanonicalHome', 'LabHome', 'ShareHome', 'VaultRoot', 'BackupRoot')
        foreach ($name in $required) {
            if (-not ($testConfig.PSObject.Properties.Name -contains $name) -or
                [string]::IsNullOrWhiteSpace([string]$testConfig.$name)) {
                throw "Test setting '$name' is required."
            }
        }

        $testRoot = Get-NormalizedPath -Path ([string]$testConfig.TestRoot)
        foreach ($name in $required | Where-Object { $_ -ne 'TestRoot' }) {
            if (-not (Test-PathWithinRoot -Path ([string]$testConfig.$name) -Root $testRoot)) {
                throw "Test setting '$name' must stay inside TestRoot."
            }
        }

        return [pscustomobject]@{
            CanonicalHome = Get-NormalizedPath -Path ([string]$testConfig.CanonicalHome)
            LabHome = Get-NormalizedPath -Path ([string]$testConfig.LabHome)
            ShareHome = Get-NormalizedPath -Path ([string]$testConfig.ShareHome)
            VaultRoot = Get-NormalizedPath -Path ([string]$testConfig.VaultRoot)
            BackupRoot = Get-NormalizedPath -Path ([string]$testConfig.BackupRoot)
            TestRoot = $testRoot
            TestMode = $true
            SkipProcessCheck = [bool]$testConfig.SkipProcessCheck
            SimulateBusy = [bool]$testConfig.SimulateBusy
            SkipCodexStatus = [bool]$testConfig.SkipCodexStatus
            SkipLaunch = $true
        }
    }

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $documents = [Environment]::GetFolderPath('MyDocuments')
    return [pscustomobject]@{
        CanonicalHome = Join-Path $userProfile '.codex'
        LabHome = Join-Path $userProfile '.codex-lab'
        ShareHome = Join-Path $userProfile '.codex-share'
        VaultRoot = Join-Path $localAppData 'CodexAccountSwitcher'
        BackupRoot = Join-Path $documents 'Codex\backups'
        TestRoot = $null
        TestMode = $false
        SkipProcessCheck = $false
        SimulateBusy = $false
        SkipCodexStatus = $false
        SkipLaunch = $false
    }
}

function Get-AuthKindFromBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    try {
        $json = [Text.Encoding]::UTF8.GetString($Bytes)
        $auth = $json | ConvertFrom-Json
    } catch {
        return 'Unknown'
    } finally {
        $json = $null
    }

    $propertyNames = @($auth.PSObject.Properties.Name)
    $authMode = if ($propertyNames -contains 'auth_mode') { [string]$auth.auth_mode } else { '' }
    $hasTokens = ($propertyNames -contains 'tokens') -and ($null -ne $auth.tokens)
    $hasApiKey = ($propertyNames -contains 'OPENAI_API_KEY') -and
        (-not [string]::IsNullOrWhiteSpace([string]$auth.OPENAI_API_KEY))

    if ($authMode -match '^(?i:chatgpt)$' -or $hasTokens) {
        return 'Personal'
    }
    if ($authMode -match '^(?i:api|api_key|apikey)$' -or $hasApiKey) {
        return 'Lab'
    }
    return 'Unknown'
}

function Read-AuthBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Authentication cache is missing: $Path"
    }
    return [IO.File]::ReadAllBytes($Path)
}

function Protect-CredentialBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return [Security.Cryptography.ProtectedData]::Protect(
        $Bytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
}

function Unprotect-CredentialBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    return [Security.Cryptography.ProtectedData]::Unprotect(
        $Bytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
}

function Write-AtomicBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    $leaf = Split-Path -Leaf $Path
    $temporary = Join-Path $directory ('.' + $leaf + '.tmp-' + [guid]::NewGuid().ToString('N'))
    $replaceBackup = Join-Path $directory ('.' + $leaf + '.replace-' + [guid]::NewGuid().ToString('N'))
    try {
        $stream = New-Object IO.FileStream(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporary, $Path, $replaceBackup, $true)
            Remove-Item -LiteralPath $replaceBackup -Force
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Text)
    try {
        Write-AtomicBytes -Path $Path -Bytes $bytes
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $null = New-Item -ItemType Directory -Path $Path -Force
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $identity.User
    $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $adminSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    # Start with the existing descriptor so reapplying permissions does not
    # attempt to replace audit metadata (which requires SeSecurityPrivilege).
    $directory = New-Object IO.DirectoryInfo($Path)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($directory, [Security.AccessControl.AccessControlSections]::Access)
    } else {
        $acl = $directory.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
    }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($acl.Access)) { $null = $acl.RemoveAccessRuleSpecific($existingRule) }
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    foreach ($sid in @($userSid, $systemSid, $adminSid)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $null = $acl.AddAccessRule($rule)
    }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl)
    } else {
        $directory.SetAccessControl($acl)
    }
}

function Get-ProfileVaultPath {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Settings,
        [Parameter(Mandatory = $true)][ValidateSet('Personal', 'Lab')][string]$ProfileName
    )

    return Join-Path $Settings.VaultRoot ($ProfileName.ToLowerInvariant() + '.auth.dpapi')
}

function Save-ProfileCredential {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Settings,
        [Parameter(Mandatory = $true)][ValidateSet('Personal', 'Lab')][string]$ProfileName,
        [Parameter(Mandatory = $true)][byte[]]$AuthBytes
    )

    $kind = Get-AuthKindFromBytes -Bytes $AuthBytes
    if ($kind -ne $ProfileName) {
        throw "Authentication cache type '$kind' does not match profile '$ProfileName'."
    }
    $protected = Protect-CredentialBytes -Bytes $AuthBytes
    try {
        Write-AtomicBytes -Path (Get-ProfileVaultPath -Settings $Settings -ProfileName $ProfileName) -Bytes $protected
    } finally {
        [Array]::Clear($protected, 0, $protected.Length)
    }
}

function Load-ProfileCredential {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Settings,
        [Parameter(Mandatory = $true)][ValidateSet('Personal', 'Lab')][string]$ProfileName
    )

    $path = Get-ProfileVaultPath -Settings $Settings -ProfileName $ProfileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Encrypted credential is missing for profile '$ProfileName'."
    }
    $protected = [IO.File]::ReadAllBytes($path)
    try {
        $plain = Unprotect-CredentialBytes -Bytes $protected
    } finally {
        [Array]::Clear($protected, 0, $protected.Length)
    }
    if ((Get-AuthKindFromBytes -Bytes $plain) -ne $ProfileName) {
        [Array]::Clear($plain, 0, $plain.Length)
        throw "Encrypted credential failed validation for profile '$ProfileName'."
    }
    return $plain
}

function Get-StatePath {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)
    return Join-Path $Settings.VaultRoot 'state.json'
}

function Read-SwitcherState {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    $path = Get-StatePath -Settings $Settings
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Get-SwitchRecoveryPath {
    param([pscustomobject]$Settings)
    return Join-Path $Settings.VaultRoot 'pending-switch.dpapi'
}

function Get-SwitchRecoveryFiles {
    param([pscustomobject]$Settings)
    # Fixed destinations: never accept writable paths from the journal.
    return [ordered]@{
        auth = Join-Path $Settings.CanonicalHome 'auth.json'
        config = Join-Path $Settings.CanonicalHome 'config.toml'
        state = Get-StatePath -Settings $Settings
        personalRoute = Get-RouteVaultPath -Settings $Settings -ProfileName Personal
        labRoute = Get-RouteVaultPath -Settings $Settings -ProfileName Lab
    }
}

function Save-SwitchRecovery {
    param([pscustomobject]$Settings, [string]$ActiveProfile)
    $path = Get-SwitchRecoveryPath -Settings $Settings
    if (Test-Path -LiteralPath $path) { throw 'A previous switch still needs recovery.' }
    $files = Get-SwitchRecoveryFiles -Settings $Settings
    $contents = [ordered]@{}
    $plain = $null
    $protected = $null
    try {
        foreach ($key in $files.Keys) {
            if (Test-Path -LiteralPath $files[$key] -PathType Leaf) {
                $bytes = [IO.File]::ReadAllBytes($files[$key])
                try { $contents[$key] = [Convert]::ToBase64String($bytes) }
                finally { [Array]::Clear($bytes, 0, $bytes.Length) }
            } else {
                if ($key -in @('auth', 'config', 'state')) { throw "Required $key file is missing; no recovery record was written." }
                $contents[$key] = $null
            }
        }
        $record = [ordered]@{ version = 1; home = $Settings.CanonicalHome; profile = $ActiveProfile; files = $contents }
        $plain = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 5))
        $protected = Protect-CredentialBytes -Bytes $plain
        Write-AtomicBytes -Path $path -Bytes $protected
    } finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
        if ($null -ne $protected) { [Array]::Clear($protected, 0, $protected.Length) }
    }
}

function Restore-PendingSwitch {
    param([pscustomobject]$Settings)
    $path = Get-SwitchRecoveryPath -Settings $Settings
    if (-not (Test-Path -LiteralPath $path)) { return }
    Assert-CodexQuiescent -Settings $Settings
    $plain = $null
    $decoded = @{}
    try {
        $plain = Unprotect-CredentialBytes -Bytes ([IO.File]::ReadAllBytes($path))
        $record = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
        if ($record.version -ne 1 -or $record.home -ne $Settings.CanonicalHome -or $record.profile -notin @('Personal', 'Lab')) {
            throw 'Recovery record does not match this installation.'
        }
        $files = Get-SwitchRecoveryFiles -Settings $Settings
        # Decode and validate every entry before changing any file.
        foreach ($key in $files.Keys) {
            $value = $record.files.$key
            if ($null -eq $value) {
                if ($key -in @('auth', 'config', 'state')) { throw 'Incomplete recovery record.' }
                $decoded[$key] = $null
            } else { $decoded[$key] = [Convert]::FromBase64String([string]$value) }
        }
        if ((Get-AuthKindFromBytes -Bytes $decoded.auth) -ne $record.profile) { throw 'Invalid recovery credentials.' }
        foreach ($key in $files.Keys) {
            if ($null -ne $decoded[$key]) { Write-AtomicBytes -Path $files[$key] -Bytes $decoded[$key] }
            elseif (Test-Path -LiteralPath $files[$key]) { Remove-Item -LiteralPath $files[$key] -Force }
        }
        if (-not (Test-CodexLoginStatus -Settings $Settings -ExpectedProfile $record.profile)) { throw 'Recovered authentication could not be verified.' }
        Write-SwitchAudit -Settings $Settings -Event 'RecoverInterruptedSwitch' -ToProfile $record.profile
        Remove-Item -LiteralPath $path -Force
        Write-Host 'Recovered the complete profile saved before the interrupted switch.' -ForegroundColor Yellow
    } catch {
        throw 'Switch recovery could not be completed. Keep pending-switch.dpapi and do not launch Codex; retry after resolving the error or restore from the encrypted vault.'
    } finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
        foreach ($bytes in $decoded.Values) { if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) } }
    }
}

function Write-SwitcherState {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Settings,
        [Parameter(Mandatory = $true)][ValidateSet('Personal', 'Lab')][string]$ActiveProfile,
        [int]$Generation = 1
    )

    $state = [ordered]@{
        schemaVersion = 1
        activeProfile = $ActiveProfile
        generation = $Generation
        updatedAt = [DateTimeOffset]::Now.ToString('o')
        sharedCodexHome = $Settings.CanonicalHome
    }
    Write-AtomicText -Path (Get-StatePath -Settings $Settings) -Text (($state | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
}

function Write-SwitchAudit {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Settings,
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$FromProfile = '',
        [string]$ToProfile = '',
        [string]$Result = 'Success'
    )

    $record = [ordered]@{
        timestamp = [DateTimeOffset]::Now.ToString('o')
        event = $Event
        from = $FromProfile
        to = $ToProfile
        result = $Result
    }
    $line = ($record | ConvertTo-Json -Compress) + [Environment]::NewLine
    $logPath = Join-Path $Settings.VaultRoot 'switcher-audit.jsonl'
    [IO.File]::AppendAllText($logPath, $line, (New-Object Text.UTF8Encoding($false)))
}

function Get-MutexName {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    $inputBytes = [Text.Encoding]::UTF8.GetBytes($Settings.VaultRoot.ToUpperInvariant())
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

function Enter-SwitcherMutex {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    $mutex = New-Object Threading.Mutex($false, (Get-MutexName -Settings $Settings))
    try {
        $acquired = $mutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        throw 'Another account switch operation is already running.'
    }
    return $mutex
}

function Get-RelevantCodexProcesses {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    if ($Settings.SimulateBusy) {
        return @([pscustomobject]@{ Name = 'codex.exe'; ProcessId = 4242 })
    }
    if ($Settings.SkipProcessCheck) {
        return @()
    }

    return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -ieq 'ChatGPT.exe' -or $_.Name -ieq 'codex.exe'
    } | Select-Object Name, ProcessId)
}

function Assert-CodexQuiescent {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    $running = @(Get-RelevantCodexProcesses -Settings $Settings)
    if ($running.Count -gt 0) {
        $summary = ($running | ForEach-Object { '{0}({1})' -f $_.Name, $_.ProcessId }) -join ', '
        throw "Account switching requires all ChatGPT and Codex processes to exit. Running: $summary"
    }
}

function Get-ActiveProfileFromHome {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    $authPath = Join-Path $Settings.CanonicalHome 'auth.json'
    $bytes = Read-AuthBytes -Path $authPath
    try {
        $kind = Get-AuthKindFromBytes -Bytes $bytes
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    if ($kind -eq 'Unknown') {
        throw 'The active authentication cache has an unsupported format.'
    }
    return $kind
}

function Test-CodexLoginStatus {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Settings,
        [Parameter(Mandatory = $true)][ValidateSet('Personal', 'Lab')][string]$ExpectedProfile
    )

    if ($Settings.SkipCodexStatus) {
        return (Get-ActiveProfileFromHome -Settings $Settings) -eq $ExpectedProfile
    }

    $codex = Get-Command codex -ErrorAction Stop
    $oldHome = $env:CODEX_HOME
    $oldSqlHome = $env:CODEX_SQLITE_HOME
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $env:CODEX_HOME = $Settings.CanonicalHome
        Remove-Item Env:CODEX_SQLITE_HOME -ErrorAction SilentlyContinue
        # Windows PowerShell wraps native stderr as ErrorRecord even on exit 0.
        # Capture it privately and decide success from the exit code and status.
        $ErrorActionPreference = 'Continue'
        $output = (& $codex.Source login status 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
        if ($null -eq $oldHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $oldHome }
        if ($null -eq $oldSqlHome) { Remove-Item Env:CODEX_SQLITE_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_SQLITE_HOME = $oldSqlHome }
    }

    if ($exitCode -ne 0) {
        $output = $null
        return $false
    }
    $matches = if ($ExpectedProfile -eq 'Personal') {
        $output -match '(?i)logged in using ChatGPT'
    } else {
        $output -match '(?i)logged in using an API key'
    }
    $output = $null
    return $matches
}

function Get-ChatGPTExecutable {
    $package = Get-AppxPackage -Name 'OpenAI.Codex' |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        throw 'OpenAI.Codex (ChatGPT desktop app) is not installed.'
    }
    $executable = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        $executable = Join-Path $package.InstallLocation 'app\Codex.exe'
    }
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "ChatGPT.exe was not found: $executable"
    }
    return $executable
}

function Start-SharedChatGPT {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    if ($Settings.TestMode -or $Settings.SkipLaunch) {
        return
    }
    $executable = Get-ChatGPTExecutable
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.WorkingDirectory = Split-Path -Parent $executable
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $Settings.CanonicalHome
    $null = $startInfo.EnvironmentVariables.Remove('CODEX_SQLITE_HOME')
    # These overrides have higher precedence than config.toml. The selected
    # profile supplies auth and routing for this launched app process.
    foreach ($name in @('OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'OPENAI_BASE_URL', 'CODEX_APP_SERVER_OPENAI_BASE_URL', 'CODEX_APP_SERVER_CHATGPT_BASE_URL')) {
        $null = $startInfo.EnvironmentVariables.Remove($name)
    }
    $started = [Diagnostics.Process]::Start($startInfo)
    if (-not $started) {
        throw 'ChatGPT failed to start.'
    }
}

function Update-SharedConfig {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    $path = Join-Path $Settings.CanonicalHome 'config.toml'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Shared config is missing: $path"
    }
    $text = [IO.File]::ReadAllText($path)
    $lines = [regex]::Split($text, '\r?\n')
    $filtered = New-Object 'Collections.Generic.List[string]'
    $inRoot = $true
    foreach ($line in $lines) {
        if ($line -match '^\s*\[') { $inRoot = $false }
        if ($inRoot -and $line -match '^\s*cli_auth_credentials_store\s*=') { continue }
        if ($inRoot -and $line -match '^\s*sqlite_home\s*=') { continue }
        $filtered.Add($line)
    }
    while ($filtered.Count -gt 0 -and $filtered[$filtered.Count - 1] -eq '') {
        $filtered.RemoveAt($filtered.Count - 1)
    }

    $insertAt = $filtered.Count
    for ($index = 0; $index -lt $filtered.Count; $index++) {
        if ($filtered[$index] -match '^\s*\[') {
            $insertAt = $index
            break
        }
    }
    $filtered.Insert($insertAt, 'cli_auth_credentials_store = "file"')
    $newText = ($filtered -join [Environment]::NewLine).TrimEnd("`r", "`n") + [Environment]::NewLine
    Write-AtomicText -Path $path -Text $newText
}

function Get-ProviderSectionIndices {
    param([string[]]$Lines, [string]$Provider)

    $escaped = [regex]::Escape($Provider)
    $pattern = '^\s*\[model_providers\.(?:"' + $escaped + '"|''' + $escaped + '''|' + $escaped + ')(?:\.[^\]]+)?\]\s*(?:#.*)?$'
    $indices = New-Object 'Collections.Generic.List[int]'
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -cnotmatch $pattern) { continue }
        $last = $index
        while ($last + 1 -lt $Lines.Count -and $Lines[$last + 1] -notmatch '^\s*\[') { $last++ }
        while ($last -gt $index -and [string]::IsNullOrWhiteSpace($Lines[$last])) { $last-- }
        for ($entry = $index; $entry -le $last; $entry++) { $indices.Add($entry) }
    }
    return $indices.ToArray()
}

function Get-ProviderRoute {
    param([Parameter(Mandatory = $true)][string]$ConfigText)

    $lines = [regex]::Split($ConfigText, '\r?\n')
    $provider = 'openai'
    $endpoint = $null
    $entries = New-Object 'Collections.Generic.List[object]'
    # Only these root scalars and the selected provider table belong to a route.
    $managed = 'model|model_provider|openai_base_url|model_reasoning_effort|service_tier|review_model|model_context_window|model_auto_compact_token_limit|model_catalog_json|forced_login_method'
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -match '^\s*\[') { break }
        if ($line -notmatch ('^\s*(?:' + $managed + ')\s*=')) { continue }
        if ($line -match '^\s*model_provider\s*=') {
            if ($line -notmatch '^\s*model_provider\s*=\s*["'']([A-Za-z0-9_-]+)["'']\s*(?:#.*)?$') {
                throw 'Unsupported model_provider syntax; use a quoted provider ID.'
            }
            $provider = $Matches[1]
        }
        if ($line -match '^\s*openai_base_url\s*=') {
            if ($line -notmatch '^\s*openai_base_url\s*=\s*["'']([^"'']+)["'']\s*(?:#.*)?$') {
                throw 'Unsupported openai_base_url syntax; use a quoted URL.'
            }
            $endpoint = $Matches[1]
        }
        if ($line -match '"""|''''''') { throw 'Multiline routing values are not supported.' }
        $entries.Add([pscustomobject]@{ Index = $index; Line = $line; IsRoot = $true })
    }
    $sectionIndices = @(Get-ProviderSectionIndices -Lines $lines -Provider $provider)
    foreach ($index in $sectionIndices) { $entries.Add([pscustomobject]@{ Index = $index; Line = $lines[$index]; IsRoot = $false }) }
    if ($provider -cne 'openai' -and $sectionIndices.Count -eq 0) {
        throw "The selected provider '$provider' has no local definition."
    }
    return [pscustomobject]@{ Provider = $provider; Endpoint = $endpoint; Entries = $entries.ToArray() }
}

function Test-RouteMatchesProfile {
    param([pscustomobject]$Route, [string]$ProfileName)
    if ($Route.Provider -cne 'openai') { return $false }
    if ($ProfileName -eq 'Personal') { return [string]::IsNullOrWhiteSpace([string]$Route.Endpoint) }
    return -not [string]::IsNullOrWhiteSpace([string]$Route.Endpoint)
}

function Convert-LabRouteToSharedProvider {
    param([pscustomobject]$Route)
    $section = @($Route.Entries | Where-Object { -not $_.IsRoot } | ForEach-Object { $_.Line })
    $urlLines = @($section | Where-Object { $_ -cmatch '^\s*base_url\s*=' })
    if ($urlLines.Count -ne 1 -or ($section -join "`n") -notmatch '(?m)^\s*requires_openai_auth\s*=\s*true\s*(?:#.*)?$') {
        throw 'Lab provider must define one base_url and use OpenAI authentication.'
    }
    foreach ($line in $section) {
        if ($line -match '^\s*(?:$|#|\[model_providers\.[A-Za-z0-9_-]+\]\s*$|(?:name|base_url|wire_api|requires_openai_auth)\s*=)') { continue }
        throw 'Lab provider has additional settings that cannot be mapped to the shared provider automatically.'
    }
    if (($section -join "`n") -notmatch '(?m)^\s*wire_api\s*=\s*["'']responses["'']\s*(?:#.*)?$') {
        throw 'Lab provider must support the Responses API.'
    }
    $root = @($Route.Entries | Where-Object { $_.IsRoot -and $_.Line -notmatch '^\s*(model_provider|openai_base_url)\s*=' } | ForEach-Object { $_.Line })
    # Resumed threads keep their provider ID. Retain the built-in ID and change
    # its API endpoint so both existing and new threads use the selected service.
    $text = (@($root) + 'model_provider = "openai"' + ($urlLines[0] -creplace '^\s*base_url', 'openai_base_url')) -join [Environment]::NewLine
    return Get-ProviderRoute -ConfigText $text
}

function Get-LabModelCatalogPath {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    $catalogPath = Join-Path $Settings.VaultRoot 'lab-models.json'
    $cachePath = Join-Path $Settings.CanonicalHome 'models_cache.json'
    # Keep the official metadata intact, including visibility and model instructions.
    # An explicit catalog makes the desktop picker honor visible backend models
    # instead of its account-specific recommended-model allowlist.
    foreach ($source in @($cachePath, $catalogPath)) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
        try {
            $catalog = [IO.File]::ReadAllText($source) | ConvertFrom-Json
            $models = @($catalog.models)
            foreach ($slug in @('gpt-5.6-sol', 'gpt-6-astra')) {
                $matches = @($models | Where-Object { $_.slug -ceq $slug -and $_.visibility -ceq 'list' -and $_.supported_in_api -eq $true })
                if ($matches.Count -ne 1) { throw 'Required visible API model is missing.' }
            }
            if ($source -eq $cachePath) {
                $text = @{ models = $models } | ConvertTo-Json -Depth 100
                Write-AtomicText -Path $catalogPath -Text $text
            }
            return $catalogPath
        } catch {
            # A stale/malformed cache must not prevent switching accounts.
            continue
        }
    }
    Write-Warning 'Lab model catalog is unavailable. Sign in with Personal once to refresh models_cache.json, then switch to Lab again.'
    return $null
}

function ConvertTo-LabBootstrapRoute {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Route,
        [pscustomobject]$Settings
    )

    if (-not (Test-RouteMatchesProfile -Route $Route -ProfileName Lab)) {
        throw 'Lab bootstrap settings require a laboratory route.'
    }
    $entries = New-Object 'Collections.Generic.List[object]'
    $modelFound = $false
    foreach ($entry in @($Route.Entries)) {
        if ($entry.IsRoot -and $entry.Line -match '^\s*service_tier\s*=') { continue }
        $line = [string]$entry.Line
        if ($entry.IsRoot -and $line -match '^\s*model\s*=') {
            $line = 'model = "gpt-5.6-sol"'
            $modelFound = $true
        }
        $entries.Add([pscustomobject]@{ Index = [int]$entry.Index; Line = $line; IsRoot = [bool]$entry.IsRoot })
    }
    if (-not $modelFound) {
        $entries.Add([pscustomobject]@{ Index = 0; Line = 'model = "gpt-5.6-sol"'; IsRoot = $true })
    }
    if ($null -ne $Settings) {
        $managedCatalogPath = Join-Path $Settings.VaultRoot 'lab-models.json'
        $catalogEntry = @($entries | Where-Object { $_.IsRoot -and $_.Line -match '^\s*model_catalog_json\s*=' })
        $managedLine = 'model_catalog_json = ' + ($managedCatalogPath | ConvertTo-Json -Compress)
        # Preserve an explicitly configured user catalog. Refresh only ours.
        if ($catalogEntry.Count -eq 0 -or $catalogEntry[0].Line -ceq $managedLine) {
            $catalogPath = Get-LabModelCatalogPath -Settings $Settings
            if ($catalogPath -and $catalogEntry.Count -eq 0) {
                $entries.Add([pscustomobject]@{ Index = $entries.Count; Line = $managedLine; IsRoot = $true })
            } elseif (-not $catalogPath -and $catalogEntry.Count -gt 0) {
                $null = $entries.Remove($catalogEntry[0])
            }
        }
    }
    return [pscustomobject]@{ Provider = $Route.Provider; Endpoint = $Route.Endpoint; Entries = $entries.ToArray() }
}

function Get-RouteVaultPath {
    param([pscustomobject]$Settings, [string]$ProfileName)
    return Join-Path $Settings.VaultRoot ($ProfileName.ToLowerInvariant() + '.route.dpapi')
}

function Save-ProviderRoute {
    param([pscustomobject]$Settings, [string]$ProfileName, [pscustomobject]$Route)
    $plain = [Text.Encoding]::UTF8.GetBytes(($Route | ConvertTo-Json -Depth 6))
    $encrypted = $null
    try {
        $encrypted = Protect-CredentialBytes -Bytes $plain
        Write-AtomicBytes -Path (Get-RouteVaultPath -Settings $Settings -ProfileName $ProfileName) -Bytes $encrypted
    } finally {
        [Array]::Clear($plain, 0, $plain.Length)
        if ($null -ne $encrypted) { [Array]::Clear($encrypted, 0, $encrypted.Length) }
    }
}

function Load-ProviderRoute {
    param([pscustomobject]$Settings, [string]$ProfileName)
    $encrypted = [IO.File]::ReadAllBytes((Get-RouteVaultPath -Settings $Settings -ProfileName $ProfileName))
    $plain = $null
    try {
        $plain = Unprotect-CredentialBytes -Bytes $encrypted
        return ([Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json)
    } finally {
        [Array]::Clear($encrypted, 0, $encrypted.Length)
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
    }
}

function Initialize-ProviderRoutes {
    param([pscustomobject]$Settings)
    $personalPath = Get-RouteVaultPath -Settings $Settings -ProfileName Personal
    $labPath = Get-RouteVaultPath -Settings $Settings -ProfileName Lab
    if ((Test-Path -LiteralPath $personalPath) -and (Test-Path -LiteralPath $labPath)) { return }
    $current = Get-ProviderRoute -ConfigText ([IO.File]::ReadAllText((Join-Path $Settings.CanonicalHome 'config.toml')))
    if (-not (Test-Path -LiteralPath $personalPath)) {
        if (-not (Test-RouteMatchesProfile -Route $current -ProfileName Personal)) {
            throw 'Personal provider settings have not been saved. Restore your personal config before initializing.'
        }
        Save-ProviderRoute -Settings $Settings -ProfileName Personal -Route $current
    }
    if (-not (Test-Path -LiteralPath $labPath)) {
        $candidates = @(
            (Join-Path $Settings.ShareHome 'config-openai.toml'),
            (Join-Path $Settings.LabHome 'config.toml'),
            (Join-Path $Settings.ShareHome 'config.toml')
        )
        $source = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $source) { throw 'Lab provider config is missing from the legacy homes.' }
        $labRoute = Get-ProviderRoute -ConfigText ([IO.File]::ReadAllText($source))
        if ($labRoute.Provider -ceq 'openai') { throw 'Lab config must select its custom API provider.' }
        $sharedLabRoute = Convert-LabRouteToSharedProvider -Route $labRoute
        Save-ProviderRoute -Settings $Settings -ProfileName Lab -Route (ConvertTo-LabBootstrapRoute -Route $sharedLabRoute -Settings $Settings)
    }
}

function Get-RouteFileBackup {
    param([pscustomobject]$Settings)
    $backup = @{}
    foreach ($profileName in @('Personal', 'Lab')) {
        $path = Get-RouteVaultPath -Settings $Settings -ProfileName $profileName
        $backup[$path] = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllBytes($path) } else { $null }
    }
    return $backup
}

function Restore-RouteFileBackup {
    param([hashtable]$Backup)
    foreach ($path in $Backup.Keys) {
        if ($null -ne $Backup[$path]) { Write-AtomicBytes -Path $path -Bytes $Backup[$path] }
        elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}

function Set-ProviderRoute {
    param([string]$ConfigText, [pscustomobject]$Route)
    $current = Get-ProviderRoute -ConfigText $ConfigText
    $lines = [regex]::Split($ConfigText, '\r?\n')
    $remove = New-Object 'Collections.Generic.HashSet[int]'
    foreach ($entry in $current.Entries) { $null = $remove.Add([int]$entry.Index) }
    # Avoid duplicate definitions if the incoming provider already exists inactive.
    foreach ($index in @(Get-ProviderSectionIndices -Lines $lines -Provider $Route.Provider)) { $null = $remove.Add($index) }
    $kept = New-Object 'Collections.Generic.List[string]'
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if (-not $remove.Contains($index)) { $kept.Add($lines[$index]) }
    }
    $rootEntries = @($Route.Entries | Where-Object { $_.IsRoot })
    $sectionEntries = @($Route.Entries | Where-Object { -not $_.IsRoot })
    foreach ($entry in $rootEntries | Sort-Object Index) {
        $firstSection = $kept.Count
        for ($index = 0; $index -lt $kept.Count; $index++) {
            if ($kept[$index] -match '^\s*\[') { $firstSection = $index; break }
        }
        $kept.Insert([Math]::Min([int]$entry.Index, $firstSection), [string]$entry.Line)
    }
    # Keep a provider block contiguous and outside all other tables.
    if ($sectionEntries.Count -gt 0) {
        $insertAt = $kept.Count
        if ($insertAt -gt 0 -and $kept[$insertAt - 1] -eq '') { $insertAt-- }
        foreach ($entry in $sectionEntries | Sort-Object Index) {
            $kept.Insert($insertAt, [string]$entry.Line)
            $insertAt++
        }
    }
    return ($kept -join [Environment]::NewLine)
}

function Get-TreeStats {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ FileCount = 0; TotalBytes = 0L }
    }
    $count = 0L
    $bytes = 0L
    Get-ChildItem -LiteralPath $Path -Force -File -Recurse -ErrorAction Stop | Where-Object {
        $_.Name -ne 'auth.json' -and $_.FullName -notmatch '[\\/]\.sandbox-secrets([\\/]|$)'
    } | ForEach-Object {
        $count++
        $bytes += $_.Length
    }
    return [pscustomobject]@{ FileCount = $count; TotalBytes = $bytes }
}

function Get-CriticalHashes {
    param([Parameter(Mandatory = $true)][string]$Path)

    $hashes = [ordered]@{}
    foreach ($name in @('config.toml', '.codex-global-state.json', 'session_index.jsonl', 'state_5.sqlite', 'thread_history_1.sqlite')) {
        $file = Join-Path $Path $name
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $hashes[$name] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        }
    }
    return $hashes
}

function Copy-StateBackup {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $null = New-Item -ItemType Directory -Path $Destination -Force
    $null = & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /XF auth.json /XD .sandbox-secrets /NFL /NDL /NJH /NJS /NP
    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8) {
        throw "State backup failed for '$Source' with robocopy exit code $exitCode."
    }
}

function New-StateBackups {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    $sources = @(
        [pscustomobject]@{ Name = 'personal'; Path = $Settings.CanonicalHome },
        [pscustomobject]@{ Name = 'lab'; Path = $Settings.LabHome },
        [pscustomobject]@{ Name = 'legacy-share'; Path = $Settings.ShareHome }
    )
    $existing = @($sources | Where-Object { Test-Path -LiteralPath $_.Path -PathType Container })
    $sourceStats = @{}
    $requiredBytes = 0L
    foreach ($source in $existing) {
        $stats = Get-TreeStats -Path $source.Path
        $sourceStats[$source.Name] = $stats
        $requiredBytes += $stats.TotalBytes
    }

    $backupDriveRoot = [IO.Path]::GetPathRoot((Get-NormalizedPath -Path $Settings.BackupRoot))
    $driveName = $backupDriveRoot.TrimEnd('\').TrimEnd(':')
    $freeBytes = (Get-PSDrive -Name $driveName -ErrorAction Stop).Free
    if ($freeBytes -lt ($requiredBytes + 1GB)) {
        throw 'Insufficient free space for verified state backups.'
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupSet = Join-Path $Settings.BackupRoot ('codex-account-switch-' + $timestamp)
    if (Test-Path -LiteralPath $backupSet) {
        throw "Backup destination already exists: $backupSet"
    }
    $null = New-Item -ItemType Directory -Path $backupSet -Force

    $manifestEntries = New-Object 'Collections.Generic.List[object]'
    foreach ($source in $existing) {
        $destination = Join-Path $backupSet $source.Name
        Copy-StateBackup -Source $source.Path -Destination $destination
        $destinationStats = Get-TreeStats -Path $destination
        $originalStats = $sourceStats[$source.Name]
        if ($destinationStats.FileCount -ne $originalStats.FileCount -or
            $destinationStats.TotalBytes -ne $originalStats.TotalBytes) {
            throw "Backup verification failed for '$($source.Name)'."
        }
        $manifestEntries.Add([ordered]@{
            name = $source.Name
            source = $source.Path
            destination = $destination
            fileCount = $destinationStats.FileCount
            totalBytes = $destinationStats.TotalBytes
            criticalHashes = Get-CriticalHashes -Path $destination
        })
    }

    $manifest = [ordered]@{
        createdAt = [DateTimeOffset]::Now.ToString('o')
        exclusions = @('auth.json (stored only in the DPAPI vault)', '.sandbox-secrets (original left untouched)')
        entries = $manifestEntries
    }
    Write-AtomicText -Path (Join-Path $backupSet 'manifest.json') -Text (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    return $backupSet
}

function Invoke-InitializeSwitcher {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Settings,
        [switch]$WhatIfOnly
    )

    if (Test-Path -LiteralPath (Get-SwitchRecoveryPath -Settings $Settings)) {
        if ($WhatIfOnly) { Write-Host 'Would recover the interrupted switch before validating the installation.'; return }
        Restore-PendingSwitch -Settings $Settings
    }
    $existingState = Read-SwitcherState -Settings $Settings
    if ($null -ne $existingState) {
        if ($WhatIfOnly) {
            Write-Host 'Existing installation: would validate credentials and prepare provider settings.'
            return
        }
        Assert-CodexQuiescent -Settings $Settings
        foreach ($profileName in @('Personal', 'Lab')) {
            $credential = Load-ProfileCredential -Settings $Settings -ProfileName $profileName
            [Array]::Clear($credential, 0, $credential.Length)
        }
        $active = Get-ActiveProfileFromHome -Settings $Settings
        $configPath = Join-Path $Settings.CanonicalHome 'config.toml'
        $originalConfig = [IO.File]::ReadAllBytes($configPath)
        $routeBackup = Get-RouteFileBackup -Settings $Settings
        $oldUserHome = if ($Settings.TestMode) { $null } else { [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User') }
        $oldUserSqlHome = if ($Settings.TestMode) { $null } else { [Environment]::GetEnvironmentVariable('CODEX_SQLITE_HOME', 'User') }
        try {
            Update-SharedConfig -Settings $Settings
            Initialize-ProviderRoutes -Settings $Settings
            $route = Load-ProviderRoute -Settings $Settings -ProfileName $active
            $currentRoute = Get-ProviderRoute -ConfigText ([IO.File]::ReadAllText($configPath))
            if (Test-RouteMatchesProfile -Route $currentRoute -ProfileName $active) {
                Save-ProviderRoute -Settings $Settings -ProfileName $active -Route $currentRoute
                $route = $currentRoute
            }
            Write-AtomicText -Path $configPath -Text (Set-ProviderRoute -ConfigText ([IO.File]::ReadAllText($configPath)) -Route $route)
            if (-not (Test-CodexLoginStatus -Settings $Settings -ExpectedProfile $active)) {
                throw 'Existing authentication could not be verified.'
            }
            if (-not $Settings.TestMode) {
                [Environment]::SetEnvironmentVariable('CODEX_HOME', $Settings.CanonicalHome, 'User')
                [Environment]::SetEnvironmentVariable('CODEX_SQLITE_HOME', $null, 'User')
            }
            Write-SwitchAudit -Settings $Settings -Event 'ValidateInstallation' -ToProfile $active
        } catch {
            Write-AtomicBytes -Path $configPath -Bytes $originalConfig
            Restore-RouteFileBackup -Backup $routeBackup
            if (-not $Settings.TestMode) {
                [Environment]::SetEnvironmentVariable('CODEX_HOME', $oldUserHome, 'User')
                [Environment]::SetEnvironmentVariable('CODEX_SQLITE_HOME', $oldUserSqlHome, 'User')
            }
            throw
        } finally {
            [Array]::Clear($originalConfig, 0, $originalConfig.Length)
        }
        Write-Host 'Existing installation verified. Use the Personal or Lab shortcut to switch providers.' -ForegroundColor Green
        return
    }

    $personalAuthPath = Join-Path $Settings.CanonicalHome 'auth.json'
    $labAuthPath = Join-Path $Settings.LabHome 'auth.json'
    $personalBytes = Read-AuthBytes -Path $personalAuthPath
    $labBytes = Read-AuthBytes -Path $labAuthPath
    try {
        if ((Get-AuthKindFromBytes -Bytes $personalBytes) -ne 'Personal') {
            throw 'The canonical .codex authentication is not a ChatGPT login.'
        }
        if ((Get-AuthKindFromBytes -Bytes $labBytes) -ne 'Lab') {
            throw 'The .codex-lab authentication is not an API key login.'
        }

        if ($WhatIfOnly) {
            [pscustomobject]@{
                Action = 'Initialize'
                SharedCodexHome = $Settings.CanonicalHome
                PersonalCredential = 'Ready'
                LabCredential = 'Ready'
                RunningProcessCount = @(Get-RelevantCodexProcesses -Settings $Settings).Count
                LegacyHomes = @($Settings.LabHome, $Settings.ShareHome)
            } | Format-List
            return
        }

        Assert-CodexQuiescent -Settings $Settings
        $backupSet = New-StateBackups -Settings $Settings
        $originalConfig = [IO.File]::ReadAllBytes((Join-Path $Settings.CanonicalHome 'config.toml'))
        $routeBackup = Get-RouteFileBackup -Settings $Settings
        $oldUserHome = if ($Settings.TestMode) { $null } else { [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User') }
        $oldUserSqlHome = if ($Settings.TestMode) { $null } else { [Environment]::GetEnvironmentVariable('CODEX_SQLITE_HOME', 'User') }
        try {
            Set-PrivateDirectoryAcl -Path $Settings.VaultRoot
            Save-ProfileCredential -Settings $Settings -ProfileName Personal -AuthBytes $personalBytes
            Save-ProfileCredential -Settings $Settings -ProfileName Lab -AuthBytes $labBytes
            Update-SharedConfig -Settings $Settings
            Initialize-ProviderRoutes -Settings $Settings
            if (-not $Settings.TestMode) {
                [Environment]::SetEnvironmentVariable('CODEX_HOME', $Settings.CanonicalHome, 'User')
                [Environment]::SetEnvironmentVariable('CODEX_SQLITE_HOME', $null, 'User')
            }
            if (-not (Test-CodexLoginStatus -Settings $Settings -ExpectedProfile Personal)) {
                throw 'Personal authentication verification failed after initialization.'
            }
            Write-SwitcherState -Settings $Settings -ActiveProfile Personal -Generation 1
            Write-SwitchAudit -Settings $Settings -Event 'Initialize' -ToProfile Personal
        } catch {
            Write-AtomicBytes -Path (Join-Path $Settings.CanonicalHome 'config.toml') -Bytes $originalConfig
            Restore-RouteFileBackup -Backup $routeBackup
            $statePath = Get-StatePath -Settings $Settings
            if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }
            if (-not $Settings.TestMode) {
                [Environment]::SetEnvironmentVariable('CODEX_HOME', $oldUserHome, 'User')
                [Environment]::SetEnvironmentVariable('CODEX_SQLITE_HOME', $oldUserSqlHome, 'User')
            }
            throw
        } finally {
            [Array]::Clear($originalConfig, 0, $originalConfig.Length)
        }

        Write-Host 'Account switcher initialized.' -ForegroundColor Green
        Write-Host ("Shared CODEX_HOME: {0}" -f $Settings.CanonicalHome)
        Write-Host ("Verified backup: {0}" -f $backupSet)
        Write-Host 'Active authentication: Personal (ChatGPT)'
    } finally {
        [Array]::Clear($personalBytes, 0, $personalBytes.Length)
        [Array]::Clear($labBytes, 0, $labBytes.Length)
    }
}

function Invoke-AccountSwitch {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Settings,
        [Parameter(Mandatory = $true)][ValidateSet('Personal', 'Lab')][string]$TargetProfile,
        [switch]$WhatIfOnly,
        [switch]$DoNotLaunch,
        [ValidateSet('None', 'AfterCredentialWrite')][string]$FailurePoint = 'None'
    )

    if (Test-Path -LiteralPath (Get-SwitchRecoveryPath -Settings $Settings)) {
        if ($WhatIfOnly) { Write-Host 'Would recover the interrupted switch before selecting the requested profile.'; return }
        Restore-PendingSwitch -Settings $Settings
    }
    $state = Read-SwitcherState -Settings $Settings
    if ($null -eq $state) {
        throw 'The account switcher is not initialized. Run with -Initialize after closing Codex.'
    }
    foreach ($profileName in @('Personal', 'Lab')) {
        if (-not (Test-Path -LiteralPath (Get-ProfileVaultPath -Settings $Settings -ProfileName $profileName) -PathType Leaf)) {
            throw "Encrypted credential is missing for profile '$profileName'."
        }
    }

    $activeProfile = Get-ActiveProfileFromHome -Settings $Settings
    $running = @(Get-RelevantCodexProcesses -Settings $Settings)
    if ($WhatIfOnly) {
        [pscustomobject]@{
            Action = 'Switch'
            From = $activeProfile
            To = $TargetProfile
            SharedCodexHome = $Settings.CanonicalHome
            RunningProcessCount = $running.Count
            WouldLaunch = -not ($DoNotLaunch -or $Settings.SkipLaunch)
        } | Format-List
        return
    }
    if ($running.Count -gt 0) {
        $summary = ($running | ForEach-Object { '{0}({1})' -f $_.Name, $_.ProcessId }) -join ', '
        throw "Account switching requires all ChatGPT and Codex processes to exit. Running: $summary"
    }

    $authPath = Join-Path $Settings.CanonicalHome 'auth.json'
    $configPath = Join-Path $Settings.CanonicalHome 'config.toml'
    $originalBytes = Read-AuthBytes -Path $authPath
    $targetBytes = $null
    try {
        if (-not (Test-CodexLoginStatus -Settings $Settings -ExpectedProfile $activeProfile)) {
            throw 'Current authentication/configuration is invalid. Repair it before switching; no recovery record was written.'
        }
        Save-SwitchRecovery -Settings $Settings -ActiveProfile $activeProfile
        Initialize-ProviderRoutes -Settings $Settings
        $currentRoute = Get-ProviderRoute -ConfigText ([IO.File]::ReadAllText($configPath))
        if (-not (Test-RouteMatchesProfile -Route $currentRoute -ProfileName $activeProfile)) {
            throw 'Authentication and provider settings disagree. Close Codex and run -Initialize to repair the installation.'
        }
        Save-ProviderRoute -Settings $Settings -ProfileName $activeProfile -Route $currentRoute
        Save-ProfileCredential -Settings $Settings -ProfileName $activeProfile -AuthBytes $originalBytes
        $targetBytes = Load-ProfileCredential -Settings $Settings -ProfileName $TargetProfile
        $targetRoute = Load-ProviderRoute -Settings $Settings -ProfileName $TargetProfile
        if ($TargetProfile -eq 'Lab') {
            $targetRoute = ConvertTo-LabBootstrapRoute -Route $targetRoute -Settings $Settings
            Save-ProviderRoute -Settings $Settings -ProfileName Lab -Route $targetRoute
        }
        Update-SharedConfig -Settings $Settings
        Write-AtomicText -Path $configPath -Text (Set-ProviderRoute -ConfigText ([IO.File]::ReadAllText($configPath)) -Route $targetRoute)
        Write-AtomicBytes -Path $authPath -Bytes $targetBytes

        if ($FailurePoint -eq 'AfterCredentialWrite') {
            if (-not $Settings.TestMode) {
                throw 'Failure injection is allowed only in test mode.'
            }
            throw 'Injected failure after credential write.'
        }
        if (-not (Test-CodexLoginStatus -Settings $Settings -ExpectedProfile $TargetProfile)) {
            throw 'Authentication verification failed for the requested profile.'
        }

        $generation = 1
        if ($state.PSObject.Properties.Name -contains 'generation') {
            $generation = [int]$state.generation + 1
        }
        Write-SwitcherState -Settings $Settings -ActiveProfile $TargetProfile -Generation $generation
        Write-SwitchAudit -Settings $Settings -Event 'Switch' -FromProfile $activeProfile -ToProfile $TargetProfile
        # Commit before starting any app process; never roll back under a running app.
        Remove-Item -LiteralPath (Get-SwitchRecoveryPath -Settings $Settings) -Force
    } catch {
        Restore-PendingSwitch -Settings $Settings
        Write-SwitchAudit -Settings $Settings -Event 'Switch' -FromProfile $activeProfile -ToProfile $TargetProfile -Result 'RolledBack'
        throw
    } finally {
        [Array]::Clear($originalBytes, 0, $originalBytes.Length)
        if ($null -ne $targetBytes) {
            [Array]::Clear($targetBytes, 0, $targetBytes.Length)
        }
    }
    if (-not $DoNotLaunch) {
        try { Start-SharedChatGPT -Settings $Settings }
        catch { throw "Profile switched to $TargetProfile, but the desktop app could not be launched. Retry the same shortcut. $($_.Exception.Message)" }
    }
    Write-Host ("Active authentication: {0}" -f $(if ($TargetProfile -eq 'Personal') { 'Personal (ChatGPT)' } else { 'Lab (API key)' })) -ForegroundColor Green
    Write-Host ("Shared CODEX_HOME: {0}" -f $Settings.CanonicalHome)
    Write-Host ("Active provider: {0}" -f $targetRoute.Provider)
}

function Show-SwitcherStatus {
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    $state = Read-SwitcherState -Settings $Settings
    $active = try { Get-ActiveProfileFromHome -Settings $Settings } catch { 'Unknown' }
    $provider = try { (Get-ProviderRoute -ConfigText ([IO.File]::ReadAllText((Join-Path $Settings.CanonicalHome 'config.toml')))).Provider } catch { 'Unknown' }
    [pscustomobject]@{
        Initialized = $null -ne $state
        RecoveryPending = Test-Path -LiteralPath (Get-SwitchRecoveryPath -Settings $Settings)
        ActiveAuthentication = if ($active -eq 'Personal') { 'Personal (ChatGPT)' } elseif ($active -eq 'Lab') { 'Lab (API key)' } else { 'Unknown' }
        ActiveProvider = $provider
        ProviderProfilesReady = (Test-Path -LiteralPath (Get-RouteVaultPath -Settings $Settings -ProfileName Personal)) -and (Test-Path -LiteralPath (Get-RouteVaultPath -Settings $Settings -ProfileName Lab))
        SharedCodexHome = $Settings.CanonicalHome
        UserCodexHome = if ($Settings.TestMode) { '(test mode)' } else { [Environment]::GetEnvironmentVariable('CODEX_HOME', 'User') }
        UserCodexSqliteHome = if ($Settings.TestMode) { '(test mode)' } else { [Environment]::GetEnvironmentVariable('CODEX_SQLITE_HOME', 'User') }
        RunningProcessCount = @(Get-RelevantCodexProcesses -Settings $Settings).Count
        LegacyLabPreserved = Test-Path -LiteralPath $Settings.LabHome
        LegacySharePreserved = Test-Path -LiteralPath $Settings.ShareHome
    } | Format-List
}

. (Join-Path $PSScriptRoot 'ProfileRegistry.ps1')
. (Join-Path $PSScriptRoot 'ProfileManagement.ps1')
if ($LoadOnly) { return }
$settings = Get-SwitcherSettings -TestSettingsPath $TestSettings
$mutex = $null
try {
    if ($Status -or $StatusJson) {
        if ($StatusJson) { Get-ProfileStatus -Settings $settings | ConvertTo-Json -Depth 8 }
        else { Get-ProfileStatus -Settings $settings | Format-List }
        return
    }

    $mutex = Enter-SwitcherMutex -Settings $settings
    if ($Initialize) {
        Initialize-MultiProfileSwitcher -Settings $settings -WhatIfOnly:$DryRun
    } elseif ($ManageStdin) {
        try {
            [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
            $requestText = [Console]::In.ReadToEnd()
            $request = $requestText | ConvertFrom-Json -ErrorAction Stop
            Invoke-ProfileManagement -Settings $settings -Request $request | ConvertTo-Json -Depth 8
        } catch {
            if ($settings.TestMode) {
                [Console]::Error.WriteLine('Management test failure location: '+$_.ScriptStackTrace)
            }
            throw (Get-SafeManagementError $_.Exception.Message)
        } finally { $requestText = $null; $request = $null }
    } else {
        Invoke-ProfileSwitch -Settings $settings -TargetProfileId $ProfileId.ToLowerInvariant() -WhatIfOnly:$DryRun -DoNotLaunch:$NoLaunch -FailurePoint $InjectFailure
    }
} finally {
    if ($null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}
