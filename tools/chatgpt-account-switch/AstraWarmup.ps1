Set-StrictMode -Version Latest
$script:AstraBlockReason='Astra warmup failed; original message was not sent. Retry or disable warmup.'
$script:AstraStatus='Codex Account Switcher: Astra warmup'
if (-not ('CodexAstraDeadline' -as [type])) {
    Add-Type -TypeDefinition 'public static class CodexAstraDeadline { public static void Abort(object state) { ((System.Net.WebRequest)state).Abort(); } }'
}

function Get-AstraProperty($Object,[string]$Name) {
    if ($null -eq $Object) { return $null }
    $property=$Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Assert-AstraPath([string]$Path,[switch]$AllowMissingLeaf) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw 'An absolute local path is required.' }
    $full=[IO.Path]::GetFullPath($Path)
    $cursor=$full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item=Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked paths are unsupported.' }
        } elseif (-not $AllowMissingLeaf -or $cursor -ne $full) { throw 'A required path is missing.' }
        $parent=Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor=$parent
    }
    return $full
}

function New-AstraPrivateDirectory([string]$Path) {
    $null=New-Item -ItemType Directory -Path $Path
    $directory=[IO.DirectoryInfo]::new($Path)
    $acl=$directory.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($rule in @($acl.Access)) { $null=$acl.RemoveAccessRuleSpecific($rule) }
    $inheritance=[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $null=$acl.AddAccessRule($rule)
    }
    $directory.SetAccessControl($acl)
}

function Get-AstraHash([string]$Value) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes($Value)
        try { return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
        finally { [Array]::Clear($bytes,0,$bytes.Length) }
    } finally { $sha.Dispose() }
}

function Get-AstraEndpoint([string]$ConfigText) {
    if ($ConfigText -match '(?im)^\s*\[\s*model_providers\.openai\s*\]') { throw 'Built-in provider is shadowed.' }
    $root=($ConfigText -split '\r?\n' | Where-Object { $_ -match '^\s*\[' } | Select-Object -First 1)
    $before=if ($null -eq $root) { $ConfigText } else { $ConfigText.Substring(0,$ConfigText.IndexOf($root)) }
    $values=@{}
    foreach ($line in ($before -split '\r?\n')) {
        if ($line -match '^\s*(model_provider|openai_base_url|cli_auth_credentials_store)\s*=') {
            $name=$Matches[1]
            if ($values.ContainsKey($name) -or $line -cnotmatch '^\s*[A-Za-z_]+\s*=\s*["'']([^"'']+)["'']\s*(?:#.*)?$') { throw 'Unsupported route configuration.' }
            $values[$name]=$Matches[1]
        }
    }
    if ($values['model_provider'] -and $values['model_provider'] -cne 'openai') { throw 'Unsupported provider.' }
    if ($values['cli_auth_credentials_store'] -cne 'file') { throw 'File credentials are required.' }
    $url=if ($values['openai_base_url']) { [string]$values['openai_base_url'] } else { 'https://api.openai.com/v1' }
    $uri=$null
    if (-not [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri) -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -match '(?i)(?:^|/)\.\.?(/|$)' -or $uri.AbsolutePath -match '%') { throw 'Invalid API endpoint.' }
    if ($uri.Scheme -cne 'https' -and -not ($uri.Scheme -ceq 'http' -and $uri.Host -in @('127.0.0.1','::1'))) { throw 'API endpoint must use HTTPS or loopback HTTP.' }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Get-AstraCurrentAccount([string]$HomePath) {
    $canonicalHome=Assert-AstraPath $HomePath
    $authPath=Assert-AstraPath (Join-Path $canonicalHome 'auth.json')
    $configPath=Assert-AstraPath (Join-Path $canonicalHome 'config.toml')
    if ((Get-Item -LiteralPath $authPath).Length -gt 65536 -or (Get-Item -LiteralPath $configPath).Length -gt 1048576) { throw 'Account files are too large.' }
    $auth=[IO.File]::ReadAllText($authPath) | ConvertFrom-Json -ErrorAction Stop
    if ((Get-AstraProperty $auth 'auth_mode') -ceq 'chatgpt') { return $null }
    if ((Get-AstraProperty $auth 'auth_mode') -cnotin @($null,'','apikey','api_key') -or $null -ne (Get-AstraProperty $auth 'tokens')) { throw 'Unsupported authentication.' }
    $key=Get-AstraProperty $auth 'OPENAI_API_KEY'
    if ($key -isnot [string] -or [string]::IsNullOrWhiteSpace($key) -or $key -match '\s') { throw 'Invalid API authentication.' }
    $endpoint=Get-AstraEndpoint ([IO.File]::ReadAllText($configPath))
    return [pscustomobject]@{ Endpoint=$endpoint; Key=$key; Fingerprint=(Get-AstraHash ($endpoint+"`n"+$key)) }
}

function Get-AstraConsent([string]$VaultPath) {
    $vault=Assert-AstraPath $VaultPath -AllowMissingLeaf
    $path=Join-Path $vault 'astra-warmup.json'
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{version=1;profiles=@()} }
    $null=Assert-AstraPath $path
    if ((Get-Item -LiteralPath $path).Length -gt 131072) { throw 'Warmup settings are too large.' }
    $value=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    if ((Get-AstraProperty $value 'version') -isnot [int] -or $value.version -ne 1 -or (Get-AstraProperty $value 'profiles') -isnot [array]) { throw 'Invalid warmup settings.' }
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($fingerprint in $value.profiles) {
        if ($fingerprint -isnot [string] -or $fingerprint -cnotmatch '^[0-9a-f]{64}$' -or -not $seen.Add($fingerprint)) { throw 'Invalid warmup settings.' }
    }
    return $value
}

function Write-AstraAtomic([string]$Path,[string]$Text) {
    $directory=Split-Path -Parent $Path
    $null=Assert-AstraPath $directory
    if (Test-Path -LiteralPath $Path) { $null=Assert-AstraPath $Path }
    $temporary=Join-Path $directory ('.astra-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $replaceBackup=Join-Path $directory ('.astra-'+[guid]::NewGuid().ToString('N')+'.replace')
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    try {
        $stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary,$Path,$replaceBackup,$true) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally {
        [Array]::Clear($bytes,0,$bytes.Length)
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        if (Test-Path -LiteralPath $replaceBackup) { Remove-Item -LiteralPath $replaceBackup -Force }
    }
}

function Enter-AstraLock([string]$Name) {
    $mutex=[Threading.Mutex]::new($false,('Local\CodexAstraWarmup-'+(Get-AstraHash $Name)))
    try {
        try { $acquired=$mutex.WaitOne([TimeSpan]::FromSeconds(5)) }
        catch [Threading.AbandonedMutexException] { $acquired=$true }
        if (-not $acquired) { throw 'Warmup lock timed out.' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Exit-AstraLock($Mutex) {
    if ($null -ne $Mutex) { $Mutex.ReleaseMutex(); $Mutex.Dispose() }
}

function Get-AstraHookState([string]$HomePath) {
    $path=Join-Path $HomePath 'hooks.json'
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{Path=$path;Document=[pscustomobject]@{hooks=[pscustomobject]@{}};Exists=$false} }
    $null=Assert-AstraPath $path
    if ((Get-Item -LiteralPath $path).Length -gt 1048576) { throw 'Hook configuration is too large.' }
    $document=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $document -or $document -is [array] -or $document -isnot [pscustomobject]) { throw 'Malformed hook configuration.' }
    $hooks=Get-AstraProperty $document 'hooks'
    if ($null -eq $hooks) { $document | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    elseif ($hooks -isnot [pscustomobject]) { throw 'Malformed hook configuration.' }
    foreach ($eventProperty in $document.hooks.PSObject.Properties) {
        if ($eventProperty.Value -isnot [array]) { throw 'Malformed hook configuration.' }
        foreach ($group in $eventProperty.Value) {
            if ($null -eq $group -or $group -isnot [pscustomobject] -or (Get-AstraProperty $group 'hooks') -isnot [array]) { throw 'Malformed hook configuration.' }
            foreach ($handler in $group.hooks) { if ($null -eq $handler -or $handler -isnot [pscustomobject]) { throw 'Malformed hook configuration.' } }
        }
    }
    return [pscustomobject]@{Path=$path;Document=$document;Exists=$true}
}

function Test-AstraOwnedHandler($Handler,[string]$HookScriptPath) {
    if ((Get-AstraProperty $Handler 'statusMessage') -cne $script:AstraStatus) { return $false }
    $command=Get-AstraProperty $Handler 'command'
    $prefix='powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'
    if ((Get-AstraProperty $Handler 'type') -cne 'command' -or $command -isnot [string] -or
        -not $command.StartsWith($prefix,[StringComparison]::Ordinal) -or -not $command.EndsWith('"',[StringComparison]::Ordinal)) { throw 'A conflicting Astra warmup handler exists.' }
    $target=$command.Substring($prefix.Length,$command.Length-$prefix.Length-1)
    if ($target.Contains('"') -or $target -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+\\)') { throw 'A conflicting Astra warmup handler exists.' }
    try {
        $full=[IO.Path]::GetFullPath($target)
        $folder=[IO.Path]::GetDirectoryName($full)
        if ([IO.Path]::GetFileName($full) -cne 'Invoke-AstraWarmup.ps1' -or
            [IO.Path]::GetFileName($folder) -cne 'chatgpt-account-switch' -or
            [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($folder)) -cne 'tools') { throw 'A conflicting Astra warmup handler exists.' }
    } catch { throw 'A conflicting Astra warmup handler exists.' }
    return $true
}

function Set-AstraHook([string]$HomePath,[string]$HookScriptPath,[bool]$Install) {
    $state=Get-AstraHookState $HomePath
    $document=$state.Document
    $existingGroups=Get-AstraProperty $document.hooks 'UserPromptSubmit'
    $groups=if ($null -eq $existingGroups) { @() } else { @($existingGroups) }
    $found=0
    $updatedOwned=$false
    $expectedCommand='powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$HookScriptPath+'"'
    $updated=New-Object 'Collections.Generic.List[object]'
    foreach ($group in $groups) {
        $handlers=New-Object 'Collections.Generic.List[object]'
        $removedOwned=$false
        foreach ($handler in $group.hooks) {
            if (Test-AstraOwnedHandler $handler $HookScriptPath) {
                $found++
                if ($Install) {
                    if ($handler.command -cne $expectedCommand) { $handler.command=$expectedCommand; $updatedOwned=$true }
                    $handlers.Add($handler)
                } else { $removedOwned=$true }
            }
            else { $handlers.Add($handler) }
        }
        if ($handlers.Count -gt 0 -or -not $removedOwned) { $group.hooks=@($handlers.ToArray()); $updated.Add($group) }
    }
    if ($found -gt 1) { throw 'Duplicate Astra warmup handlers exist.' }
    if ($Install -and $found -eq 1 -and -not $updatedOwned) { return }
    if ($Install -and $found -eq 0) {
        $command='powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$HookScriptPath+'"'
        $updated.Add([pscustomobject]@{hooks=@([pscustomobject]@{type='command';command=$command;timeout=40;statusMessage=$script:AstraStatus})})
    }
    if ($found -eq 0 -and -not $Install) { return }
    if ($null -eq (Get-AstraProperty $document.hooks 'UserPromptSubmit')) { $document.hooks | Add-Member -NotePropertyName UserPromptSubmit -NotePropertyValue @($updated.ToArray()) }
    else { $document.hooks.UserPromptSubmit=@($updated.ToArray()) }
    if ($state.Exists) {
        $backup=Join-Path $HomePath ('hooks.astra-warmup-backup-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')+'-'+[guid]::NewGuid().ToString('N')+'.json')
        [IO.File]::Copy($state.Path,$backup)
    }
    Write-AstraAtomic $state.Path (($document | ConvertTo-Json -Depth 100)+"`n")
}

function Get-AstraWarmupEnabled {
    param([Parameter(Mandatory)][string]$HomePath,[Parameter(Mandatory)][string]$VaultPath)
    $account=Get-AstraCurrentAccount $HomePath
    if ($null -eq $account) { return $false }
    $consent=Get-AstraConsent $VaultPath
    return @($consent.profiles | Where-Object { $_ -ceq $account.Fingerprint }).Count -eq 1
}

function Set-AstraWarmupEnabled {
    param([Parameter(Mandatory)][string]$HomePath,[Parameter(Mandatory)][string]$VaultPath,[Parameter(Mandatory)][string]$HookScriptPath,[Parameter(Mandatory)][bool]$Enabled,[Parameter(Mandatory)][bool]$ConfirmCost)
    $canonicalHome=Assert-AstraPath $HomePath
    $vault=Assert-AstraPath $VaultPath -AllowMissingLeaf
    $scriptPath=Assert-AstraPath $HookScriptPath
    if ([IO.Path]::GetExtension($scriptPath) -cne '.ps1' -or (Split-Path -Leaf $scriptPath) -cne 'Invoke-AstraWarmup.ps1') { throw 'Invalid warmup hook path.' }
    if ($Enabled -and -not $ConfirmCost) { throw 'Explicit warmup cost confirmation is required.' }
    $account=Get-AstraCurrentAccount $canonicalHome
    if ($null -eq $account) { throw 'Select a file API login before configuring warmup.' }
    if (-not (Test-Path -LiteralPath $vault)) { New-AstraPrivateDirectory $vault }
    $lock=Enter-AstraLock ($vault+'|config')
    try {
        $consent=Get-AstraConsent $vault
        $profiles=@($consent.profiles | Where-Object { $_ -cne $account.Fingerprint })
        if ($Enabled) { $profiles+= $account.Fingerprint }
        $state=Get-AstraHookState $canonicalHome
        $oldHooks=if ($state.Exists) { [IO.File]::ReadAllBytes($state.Path) } else { $null }
        $consentPath=Join-Path $vault 'astra-warmup.json'
        $oldConsent=if (Test-Path -LiteralPath $consentPath) { [IO.File]::ReadAllBytes($consentPath) } else { $null }
        try {
            Set-AstraHook $canonicalHome $scriptPath ($profiles.Count -gt 0)
            Write-AstraAtomic $consentPath (([ordered]@{version=1;profiles=@($profiles)} | ConvertTo-Json -Depth 3)+"`n")
        } catch {
            if ($null -ne $oldHooks) { Write-AstraAtomic $state.Path ([Text.Encoding]::UTF8.GetString($oldHooks)) }
            elseif (Test-Path -LiteralPath $state.Path) { Remove-Item -LiteralPath $state.Path -Force }
            if ($null -ne $oldConsent) { Write-AstraAtomic $consentPath ([Text.Encoding]::UTF8.GetString($oldConsent)) }
            elseif (Test-Path -LiteralPath $consentPath) { Remove-Item -LiteralPath $consentPath -Force }
            throw
        }
    } finally { Exit-AstraLock $lock }
}

function Test-AstraResponse([byte[]]$Bytes,[string]$ContentType) {
    $text=(New-Object Text.UTF8Encoding($false,$true)).GetString($Bytes)
    if ($ContentType -match '(?i)text/event-stream') {
        $complete=$false
        foreach ($block in ([regex]::Split($text,'\r?\n\r?\n'))) {
            $eventName=$null; $data=New-Object 'Collections.Generic.List[string]'
            foreach ($line in ($block -split '\r?\n')) {
                if ($line.StartsWith('event:')) { $eventName=$line.Substring(6).Trim() }
                elseif ($line.StartsWith('data:')) { $data.Add($line.Substring(5).TrimStart()) }
            }
            if ($eventName -in @('error','response.failed','response.incomplete')) { return $false }
            if ($eventName -ceq 'response.completed') {
                $obj=($data -join "`n") | ConvertFrom-Json -ErrorAction Stop
                if ((Get-AstraProperty $obj 'type') -cne 'response.completed' -or (Get-AstraProperty (Get-AstraProperty $obj 'response') 'status') -cne 'completed') { return $false }
                $complete=$true
            }
        }
        return $complete
    }
    if ($ContentType -match '(?i)application/json') {
        $obj=$text | ConvertFrom-Json -ErrorAction Stop
        return (Get-AstraProperty $obj 'status') -ceq 'completed'
    }
    return $false
}

function Send-AstraRequest([string]$Endpoint,[string]$Key) {
    $uri=$Endpoint.TrimEnd('/')+'/responses'
    $request=[Net.HttpWebRequest][Net.WebRequest]::Create($uri)
    $request.Method='POST'
    $request.ContentType='application/json'
    $request.Accept='text/event-stream, application/json'
    $request.Headers['Authorization']='Bearer '+$Key
    $request.AllowAutoRedirect=$false
    $request.Timeout=20000
    $request.ReadWriteTimeout=20000
    $body=[Text.Encoding]::UTF8.GetBytes((@{model='gpt-5.6-sol';input='Reply only OK.';reasoning=@{effort='low'};tools=@();stream=$true;store=$false;max_output_tokens=256} | ConvertTo-Json -Depth 5 -Compress))
    $request.ContentLength=$body.Length
    $callback=[Delegate]::CreateDelegate([type][Threading.TimerCallback],[type][CodexAstraDeadline],'Abort')
    $timer=[Threading.Timer]::new($callback,$request,20000,[Threading.Timeout]::Infinite)
    try {
        $stream=$request.GetRequestStream()
        try { $stream.Write($body,0,$body.Length) } finally { $stream.Dispose() }
        $response=[Net.HttpWebResponse]$request.GetResponse()
        try {
            if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) { return $false }
            if ($response.ContentLength -gt 131072) { return $false }
            $buffer=New-Object byte[] 8192
            $memory=[IO.MemoryStream]::new()
            $responseStream=$response.GetResponseStream()
            try {
                while (($read=$responseStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    if ($memory.Length+$read -gt 131072) { return $false }
                    $memory.Write($buffer,0,$read)
                }
                return Test-AstraResponse $memory.ToArray() $response.ContentType
            } finally { $responseStream.Dispose(); $memory.Dispose() }
        } finally { $response.Dispose() }
    } finally { $timer.Dispose(); [Array]::Clear($body,0,$body.Length); $request.Abort() }
}

function Invoke-AstraWarmup {
    param([Parameter(Mandatory)][string]$HomePath,[Parameter(Mandatory)][string]$VaultPath,[Parameter(Mandatory)]$Event)
    $name=Get-AstraProperty $Event 'hook_event_name'
    $model=Get-AstraProperty $Event 'model'
    if ($name -cne 'UserPromptSubmit' -or $model -cne 'gpt-6-astra') { return $null }
    $block=[pscustomobject]@{decision='block';reason=$script:AstraBlockReason}
    try {
        $consent=Get-AstraConsent $VaultPath
        if ($consent.profiles.Count -eq 0) { return $null }
        $account=Get-AstraCurrentAccount $HomePath
        if ($null -eq $account -or @($consent.profiles | Where-Object { $_ -ceq $account.Fingerprint }).Count -eq 0) { return $null }
        if ($env:OPENAI_BASE_URL -or $env:OPENAI_API_KEY -or $env:CODEX_API_KEY) { return $block }
        if ($env:CODEX_HOME -and [IO.Path]::GetFullPath($env:CODEX_HOME) -ine [IO.Path]::GetFullPath($HomePath)) { return $block }
        $session=Get-AstraProperty $Event 'session_id'
        if ($session -isnot [string] -or $session -cnotmatch '^[A-Za-z0-9_-]{1,128}$') { return $block }
        $vault=Assert-AstraPath $VaultPath
        $directory=Join-Path $vault 'astra-warmup-sessions'
        if (-not (Test-Path -LiteralPath $directory)) { New-AstraPrivateDirectory $directory }
        $null=Assert-AstraPath $directory
        $marker=Join-Path $directory (Get-AstraHash ($account.Fingerprint+"`n"+$session))
        $lock=Enter-AstraLock ($vault+'|session|'+$account.Fingerprint+'|'+$session)
        try {
            if (Test-Path -LiteralPath $marker) {
                $null=Assert-AstraPath $marker
                if ([IO.File]::ReadAllText($marker) -cne 'completed') { return $block }
                return $null
            }
            if (-not (Send-AstraRequest $account.Endpoint $account.Key)) { return $block }
            Write-AstraAtomic $marker 'completed'
            return $null
        } finally { Exit-AstraLock $lock }
    } catch { throw }
}
