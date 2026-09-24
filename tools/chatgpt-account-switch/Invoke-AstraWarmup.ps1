[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'AstraWarmup.ps1')
try {
    $inputText=[Console]::In.ReadToEnd()
    if ($inputText.Length -gt 1048576) { throw 'Hook input is too large.' }
    $event=$inputText | ConvertFrom-Json -ErrorAction Stop
    $homePath=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    $vaultPath=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexAccountSwitcher'
    $result=Invoke-AstraWarmup -HomePath $homePath -VaultPath $vaultPath -Event $event
    if ($null -ne $result) { [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress)) }
} catch {
    [Console]::Out.WriteLine('{"decision":"block","reason":"Astra warmup failed; original message was not sent. Retry or disable warmup."}')
}
