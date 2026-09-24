[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Check($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
function Reject([scriptblock]$Action,[string]$Message) {
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true }
    Check $failed $Message
}
function Start-LocalResponder([string]$Root,[string[]]$Responses) {
    $socket=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $socket.Start(); $fixturePort=($socket.LocalEndpoint).Port; $socket.Stop()
    $prefix='fixture-'+[guid]::NewGuid().ToString('N')
    $readyPath=Join-Path $Root ($prefix+'-ready')
    $capturePath=Join-Path $Root ($prefix+'-capture')
    $fixtureJob=Start-Job -ArgumentList $fixturePort,$readyPath,$capturePath,$Responses -ScriptBlock {
        param($port,$ready,$capture,$responses)
        $http=[Net.HttpListener]::new()
        $http.Prefixes.Add("http://127.0.0.1:$port/")
        $http.Start()
        try {
            [IO.File]::WriteAllText($ready,'ready')
            foreach ($kind in $responses) {
                $pending=$http.GetContextAsync()
                if (-not $pending.Wait(10000)) { return }
                $context=$pending.Result
                $reader=[IO.StreamReader]::new($context.Request.InputStream,[Text.Encoding]::UTF8)
                $body=$reader.ReadToEnd()
                [IO.File]::AppendAllText($capture,($context.Request.RawUrl+"`n"+$body+"`n---`n"))
                if ($kind -eq 'redirect') {
                    $context.Response.StatusCode=302
                    $context.Response.RedirectLocation='https://example.test/never-follow'
                    $bytes=[byte[]]@()
                } elseif ($kind -eq 'error') {
                    $context.Response.StatusCode=200
                    $bytes=[Text.Encoding]::UTF8.GetBytes("event: response.failed`ndata: {`"type`":`"response.failed`",`"response`":{`"status`":`"failed`"}}`n`n")
                } else {
                    $context.Response.StatusCode=200
                    $bytes=[Text.Encoding]::UTF8.GetBytes("event: response.completed`ndata: {`"type`":`"response.completed`",`"response`":{`"status`":`"completed`"}}`n`n")
                }
                $context.Response.ContentType='text/event-stream'
                $context.Response.ContentLength64=$bytes.Length
                $context.Response.KeepAlive=$false
                if ($bytes.Length -gt 0) { $context.Response.OutputStream.Write($bytes,0,$bytes.Length) }
                $context.Response.Close()
            }
        } finally { $http.Stop() }
    }
    $start=[DateTime]::UtcNow
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if (([DateTime]::UtcNow-$start).TotalSeconds -gt 5) { throw 'Loopback fixture did not start.' }
        Start-Sleep -Milliseconds 50
    }
    return [pscustomobject]@{Port=$fixturePort;Job=$fixtureJob;Capture=$capturePath}
}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('astra-warmup-test-'+[guid]::NewGuid().ToString('N'))
$homePath=Join-Path $testRoot 'home'
$vaultPath=Join-Path $testRoot 'vault'
$scriptPath=Join-Path $PSScriptRoot 'Invoke-AstraWarmup.ps1'
$listener=$null
$server=$null
$savedEnvironment=@{}
foreach ($name in @('CODEX_HOME','OPENAI_BASE_URL','OPENAI_API_KEY','CODEX_API_KEY','CODEX_APP_SERVER_OPENAI_BASE_URL')) {
    $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
    [Environment]::SetEnvironmentVariable($name,$null,'Process')
}
try {
    New-Item -ItemType Directory -Path $homePath,$vaultPath -Force | Out-Null
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    $port=($listener.LocalEndpoint).Port
    $listener.Stop()
    $listener=$null
    [IO.File]::WriteAllText((Join-Path $homePath 'auth.json'),'{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_WARMUP_KEY_LOCAL_TEST_ONLY"}')
    [IO.File]::WriteAllText((Join-Path $homePath 'config.toml'),"model_provider = `"openai`"`nopenai_base_url = `"http://127.0.0.1:$port/v1`"`ncli_auth_credentials_store = `"file`"`n")
    [IO.File]::WriteAllText((Join-Path $homePath 'hooks.json'),'{"keep":"unrelated","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"unrelated.exe"}]}],"UserPromptSubmit":[{"matcher":"keep","hooks":[{"type":"command","command":"other.exe"}]}]}}')
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'AstraWarmup.ps1')) { . (Join-Path $PSScriptRoot 'AstraWarmup.ps1') }
    Reject { Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $false } 'False cost consent refuses enable.'
    Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true
    $capture=Join-Path $testRoot 'requests.txt'
    Check (-not (Test-Path -LiteralPath $capture)) 'Enable made no network request.'
    $ready=Join-Path $testRoot 'ready'
    $server=Start-Job -ArgumentList $port,$capture,$ready -ScriptBlock {
        param($port,$capture,$ready)
        $http=[Net.HttpListener]::new()
        $http.Prefixes.Add("http://127.0.0.1:$port/")
        $http.Start()
        try {
            [IO.File]::WriteAllText($ready,'ready')
            $pending=$http.GetContextAsync()
            if (-not $pending.Wait(10000)) { return }
            $context=$pending.Result
            $reader=[IO.StreamReader]::new($context.Request.InputStream,[Text.Encoding]::UTF8)
            $body=$reader.ReadToEnd()
            [IO.File]::WriteAllText($capture,($context.Request.RawUrl+"`n"+$body))
            $response=[Text.Encoding]::UTF8.GetBytes("event: response.completed`ndata: {`"type`":`"response.completed`",`"response`":{`"status`":`"completed`"}}`n`n")
            $context.Response.StatusCode=200
            $context.Response.ContentType='text/event-stream'
            $context.Response.ContentLength64=$response.Length
            $context.Response.KeepAlive=$false
            $context.Response.OutputStream.Write($response,0,$response.Length)
            $context.Response.Close()
        } finally { $http.Stop() }
    }
    $start=[DateTime]::UtcNow
    while (-not (Test-Path -LiteralPath $ready)) {
        if (([DateTime]::UtcNow-$start).TotalSeconds -gt 5) { throw 'Loopback fixture did not start.' }
        Start-Sleep -Milliseconds 50
    }
    $event=[pscustomobject]@{hook_event_name='UserPromptSubmit';session_id='session-one';model='gpt-6-astra';prompt='PRIVATE_ORIGINAL_SENTINEL'}
    $result=Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $event
    Check ($null -eq $result) 'A completed Sol response releases the original turn.'
    Check (Test-Path -LiteralPath $capture) 'Warmup request reached the loopback server.'
    $requestText=[IO.File]::ReadAllText($capture)
    $requestBody=($requestText -split "`n",2)[1] | ConvertFrom-Json
    Check ($requestText.StartsWith('/v1/responses'+"`n")) 'Warmup posts to the current API endpoint Responses route.'
    Check ($requestBody.model -ceq 'gpt-5.6-sol' -and $requestBody.input -ceq 'Reply only OK.' -and $requestBody.reasoning.effort -ceq 'low') 'Warmup sends the fixed Sol low-effort request.'
    Check ($requestBody.stream -eq $true -and $requestBody.store -eq $false -and $requestBody.max_output_tokens -eq 256 -and $requestBody.tools.Count -eq 0) 'Warmup request keeps streaming, storage, output and tools constrained.'
    Check (-not $requestText.Contains('PRIVATE_ORIGINAL_SENTINEL')) 'Warmup excludes original user prompt.'
    Check ($null -eq (Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $event)) 'Second prompt in the same session does not warm again.'
    $markers=@(Get-ChildItem -LiteralPath (Join-Path $vaultPath 'astra-warmup-sessions') -File)
    Check ($markers.Count -eq 1 -and [IO.File]::ReadAllText($markers[0].FullName) -ceq 'completed') 'Successful session has one completion marker.'
    $vaultText=([IO.File]::ReadAllText((Join-Path $vaultPath 'astra-warmup.json'))+[IO.File]::ReadAllText($markers[0].FullName))
    Check (-not $vaultText.Contains('FAKE_WARMUP_KEY') -and -not $vaultText.Contains('PRIVATE_ORIGINAL_SENTINEL')) 'State contains neither credential nor prompt.'
    Check ($null -eq (Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event ([pscustomobject]@{hook_event_name='UserPromptSubmit';session_id='other';model='gpt-6-sol'}))) 'Non-Astra prompt causes no warmup.'
    Check ($null -eq (Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event ([pscustomobject]@{hook_event_name='OtherEvent';session_id='other';model='gpt-6-astra'}))) 'Other hook event causes no warmup.'
    Check ((Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event ([pscustomobject]@{hook_event_name='UserPromptSubmit';session_id='../bad';model='gpt-6-astra'})).decision -ceq 'block') 'Malformed session metadata blocks the original turn.'
    $env:CODEX_APP_SERVER_OPENAI_BASE_URL='https://elsewhere.example.test/v1'
    $differentRoute=[pscustomobject]@{hook_event_name='UserPromptSubmit';session_id='different-route';model='gpt-6-astra'}
    Check ((Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $differentRoute).decision -ceq 'block') 'Different app-server route override blocks before warmup.'
    $env:CODEX_APP_SERVER_OPENAI_BASE_URL="http://127.0.0.1:$port/v1/"
    Check ($null -eq (Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $event)) 'Matching app-server route override permits the configured endpoint.'
    Remove-Item Env:CODEX_APP_SERVER_OPENAI_BASE_URL
    Check (-not (Test-AstraResponse ([Text.Encoding]::UTF8.GetBytes('event: response.incomplete'+"`n"+'data: {"type":"response.incomplete"}'+"`n`n")) 'text/event-stream')) 'Incomplete SSE never marks success.'
    Check (-not (Test-AstraResponse ([Text.Encoding]::UTF8.GetBytes('event: error'+"`n"+'data: {"message":"PRIVATE_ORIGINAL_SENTINEL"}'+"`n`n")) 'text/event-stream')) 'Error SSE never marks success.'
    Check (-not (Test-AstraResponse ([Text.Encoding]::UTF8.GetBytes('{"status":"incomplete"}')) 'application/json')) 'Incomplete JSON never marks success.'
    Reject { Test-AstraResponse ([Text.Encoding]::UTF8.GetBytes('{bad')) 'application/json' } 'Invalid JSON is refused.'
    $failureFixture=Start-LocalResponder $testRoot @('error','success')
    [IO.File]::WriteAllText((Join-Path $homePath 'config.toml'),"model_provider = `"openai`"`nopenai_base_url = `"http://127.0.0.1:$($failureFixture.Port)/v1`"`ncli_auth_credentials_store = `"file`"`n")
    Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true
    $retryEvent=[pscustomobject]@{hook_event_name='UserPromptSubmit';session_id='retry-session';model='gpt-6-astra';prompt='PRIVATE_ORIGINAL_SENTINEL'}
    $failure=Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $retryEvent
    Check ($failure.decision -ceq 'block' -and $failure.reason -ceq 'Astra warmup failed; original message was not sent. Retry or disable warmup.') 'Failed Sol response blocks with sanitized reason.'
    Check ($null -eq (Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $retryEvent)) 'Failed warmup is not marked and can be retried once.'
    Check (([regex]::Matches([IO.File]::ReadAllText($failureFixture.Capture),'(?m)^/v1/responses$')).Count -eq 2) 'Failure and manual retry each made one request.'
    Wait-Job $failureFixture.Job -Timeout 10 | Out-Null
    Remove-Job $failureFixture.Job -Force
    $redirectFixture=Start-LocalResponder $testRoot @('redirect')
    [IO.File]::WriteAllText((Join-Path $homePath 'config.toml'),"model_provider = `"openai`"`nopenai_base_url = `"http://127.0.0.1:$($redirectFixture.Port)/v1`"`ncli_auth_credentials_store = `"file`"`n")
    Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true
    Check ((Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event ([pscustomobject]@{hook_event_name='UserPromptSubmit';session_id='redirect-session';model='gpt-6-astra'})).decision -ceq 'block') 'Redirect blocks without forwarding bearer credentials.'
    Wait-Job $redirectFixture.Job -Timeout 10 | Out-Null
    Remove-Job $redirectFixture.Job -Force
    $parallelFixture=Start-LocalResponder $testRoot @('success')
    [IO.File]::WriteAllText((Join-Path $homePath 'config.toml'),"model_provider = `"openai`"`nopenai_base_url = `"http://127.0.0.1:$($parallelFixture.Port)/v1`"`ncli_auth_credentials_store = `"file`"`n")
    Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true
    $parallelEvent=[pscustomobject]@{hook_event_name='UserPromptSubmit';session_id='shared-session';model='gpt-6-astra'}
    $parallelJobs=@(1,2 | ForEach-Object {
        Start-Job -ArgumentList (Join-Path $PSScriptRoot 'AstraWarmup.ps1'),$homePath,$vaultPath,$parallelEvent -ScriptBlock {
            param($source,$homePath,$vaultPath,$event)
            . $source
            $outcome=Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $event
            if ($null -eq $outcome) { 'pass' } else { 'block' }
        }
    })
    $parallelJobs | Wait-Job -Timeout 15 | Out-Null
    $outcomes=@($parallelJobs | Receive-Job)
    Check ($outcomes.Count -eq 2 -and @($outcomes | Where-Object { $_ -ceq 'pass' }).Count -eq 2) 'Concurrent same-session hooks both release after one success.'
    Check (([regex]::Matches([IO.File]::ReadAllText($parallelFixture.Capture),'(?m)^/v1/responses$')).Count -eq 1) 'Concurrent same-session hooks made exactly one warmup request.'
    $parallelJobs | Remove-Job -Force
    Wait-Job $parallelFixture.Job -Timeout 10 | Out-Null
    Remove-Job $parallelFixture.Job -Force
    $hookBefore=(Get-FileHash -LiteralPath (Join-Path $homePath 'hooks.json')).Hash
    Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true
    Check ((Get-FileHash -LiteralPath (Join-Path $homePath 'hooks.json')).Hash -eq $hookBefore) 'Repeated enable leaves the owned hook unchanged.'
    $hooks=[IO.File]::ReadAllText((Join-Path $homePath 'hooks.json')) | ConvertFrom-Json
    Check ($hooks.keep -ceq 'unrelated' -and $hooks.hooks.SessionStart.Count -eq 1 -and $hooks.hooks.UserPromptSubmit.Count -eq 2) 'Enable preserves unrelated hook data and adds one handler.'
    [IO.File]::WriteAllText((Join-Path $homePath 'auth.json'),'{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_SECOND_KEY_LOCAL_TEST_ONLY"}')
    Check (-not (Get-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath)) 'Changing API key does not inherit first key consent.'
    Check ($null -eq (Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $event)) 'Unconsented API key causes no request.'
    $priorCount=(Get-AstraConsent $vaultPath).profiles.Count
    Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true
    Check ((Get-AstraConsent $vaultPath).profiles.Count -eq ($priorCount+1)) 'Enabling a second key preserves first key consent.'
    Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $false -ConfirmCost $false
    Check ((Get-AstraConsent $vaultPath).profiles.Count -eq $priorCount) 'Disable removes only the current key consent.'
    [IO.File]::WriteAllText((Join-Path $homePath 'auth.json'),'{"auth_mode":"chatgpt","tokens":{"account_id":"FAKE","access_token":"FAKE","refresh_token":"FAKE"}}')
    Check ($null -eq (Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $event)) 'ChatGPT login causes no warmup.'
    [IO.File]::WriteAllText((Join-Path $homePath 'auth.json'),'{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_WARMUP_KEY_LOCAL_TEST_ONLY"}')
    foreach ($enabledPort in @($port,$failureFixture.Port,$redirectFixture.Port,$parallelFixture.Port)) {
        [IO.File]::WriteAllText((Join-Path $homePath 'config.toml'),"model_provider = `"openai`"`nopenai_base_url = `"http://127.0.0.1:$enabledPort/v1`"`ncli_auth_credentials_store = `"file`"`n")
        Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $false -ConfirmCost $false
    }
    $hooks=[IO.File]::ReadAllText((Join-Path $homePath 'hooks.json')) | ConvertFrom-Json
    Check ((Get-AstraConsent $vaultPath).profiles.Count -eq 0 -and $hooks.hooks.SessionStart.Count -eq 1 -and $hooks.hooks.UserPromptSubmit.Count -eq 1) 'Last disable removes only owned handler.'
    $configPath=Join-Path $homePath 'config.toml'
    [IO.File]::WriteAllText($configPath,"model_provider = `"openai`"`nopenai_base_url = `"http://public.example.test/v1`"`ncli_auth_credentials_store = `"file`"`n")
    Reject { Get-AstraCurrentAccount $homePath } 'Public HTTP route is rejected.'
    [IO.File]::WriteAllText($configPath,"model_provider = `"openai`"`ncli_auth_credentials_store = `"file`"`n[model_providers.openai]`nbase_url = `"https://other.example.test`"`n")
    Reject { Get-AstraCurrentAccount $homePath } 'Shadowed built-in provider route is rejected.'
    [IO.File]::WriteAllText($configPath,"model_provider = `"openai`"`ncli_auth_credentials_store = `"file`"`n")
    Check ((Get-AstraCurrentAccount $homePath).Endpoint -ceq 'https://api.openai.com/v1') 'Built-in API route resolves to official endpoint.'
    [IO.File]::WriteAllText((Join-Path $homePath 'hooks.json'),'{bad')
    Reject { Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true } 'Malformed hook file is refused.'
    Check ([IO.File]::ReadAllText((Join-Path $homePath 'hooks.json')) -ceq '{bad') 'Malformed hook file is never overwritten.'
    $freshHome=Join-Path $testRoot 'fresh-home'
    $freshVault=Join-Path $testRoot 'fresh-vault'
    New-Item -ItemType Directory -Path $freshHome | Out-Null
    [IO.File]::WriteAllText((Join-Path $freshHome 'auth.json'),'{"auth_mode":"apikey","OPENAI_API_KEY":"FAKE_FRESH_KEY_LOCAL_TEST_ONLY"}')
    [IO.File]::WriteAllText((Join-Path $freshHome 'config.toml'),"model_provider = `"openai`"`ncli_auth_credentials_store = `"file`"`n")
    Set-AstraWarmupEnabled -HomePath $freshHome -VaultPath $freshVault -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true
    Check ((Get-Acl -LiteralPath $freshVault).AreAccessRulesProtected) 'New warmup vault has private, non-inherited access rules.'
    $freshHooksPath=Join-Path $freshHome 'hooks.json'
    $freshHooks=[IO.File]::ReadAllText($freshHooksPath) | ConvertFrom-Json
    $emptyGroup=[pscustomobject]@{matcher='keep-empty';note='unrelated group';hooks=@()}
    $freshHooks.hooks.UserPromptSubmit=@($emptyGroup)+@($freshHooks.hooks.UserPromptSubmit)
    [IO.File]::WriteAllText($freshHooksPath,($freshHooks | ConvertTo-Json -Depth 20))
    Set-AstraWarmupEnabled -HomePath $freshHome -VaultPath $freshVault -HookScriptPath $scriptPath -Enabled $false -ConfirmCost $false
    $freshHooks=[IO.File]::ReadAllText($freshHooksPath) | ConvertFrom-Json
    Check ($freshHooks.hooks.UserPromptSubmit.Count -eq 1 -and $freshHooks.hooks.UserPromptSubmit[0].matcher -ceq 'keep-empty' -and $freshHooks.hooks.UserPromptSubmit[0].hooks.Count -eq 0) 'Disable preserves an unrelated empty UserPromptSubmit group.'
    Set-AstraWarmupEnabled -HomePath $freshHome -VaultPath $freshVault -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true
    $freshHooks=[IO.File]::ReadAllText($freshHooksPath) | ConvertFrom-Json
    $oldHookPath=Join-Path $testRoot 'old-release\tools\chatgpt-account-switch\Invoke-AstraWarmup.ps1'
    $oldCommand='powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$oldHookPath+'"'
    $freshHooks.hooks.UserPromptSubmit[1].hooks[0].command=$oldCommand
    [IO.File]::WriteAllText($freshHooksPath,($freshHooks | ConvertTo-Json -Depth 20))
    Set-AstraWarmupEnabled -HomePath $freshHome -VaultPath $freshVault -HookScriptPath $scriptPath -Enabled $true -ConfirmCost $true
    $freshHooks=[IO.File]::ReadAllText($freshHooksPath) | ConvertFrom-Json
    Check ($freshHooks.hooks.UserPromptSubmit.Count -eq 2 -and $freshHooks.hooks.UserPromptSubmit[0].matcher -ceq 'keep-empty' -and $freshHooks.hooks.UserPromptSubmit[1].hooks[0].command -cne $oldCommand) 'Re-enable replaces a moved release command without duplicating the handler.'
    $freshHooks.hooks.UserPromptSubmit[1].hooks[0].command=$oldCommand
    [IO.File]::WriteAllText($freshHooksPath,($freshHooks | ConvertTo-Json -Depth 20))
    Set-AstraWarmupEnabled -HomePath $freshHome -VaultPath $freshVault -HookScriptPath $scriptPath -Enabled $false -ConfirmCost $false
    $freshHooks=[IO.File]::ReadAllText($freshHooksPath) | ConvertFrom-Json
    Check ($freshHooks.hooks.UserPromptSubmit.Count -eq 1 -and $freshHooks.hooks.UserPromptSubmit[0].matcher -ceq 'keep-empty') 'Disable removes a moved release handler and preserves unrelated group.'
} finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process') }
    if ($null -ne $server) { Stop-Job $server -ErrorAction SilentlyContinue; Remove-Job $server -Force -ErrorAction SilentlyContinue }
    if ($null -ne $listener) { $listener.Stop() }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
