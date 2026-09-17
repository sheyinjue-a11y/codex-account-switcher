[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Switch','Personal','Lab','Repair','Manage','List')][string]$Action,
    [string]$ProfileId,
    [Parameter(Mandatory = $true)][string]$SwitcherPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(DontShow = $true)][string]$TestSettings
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
function Get-SafeFailure([string]$Detail) {
    switch -Regex ($Detail) {
        'cancel' { return '登录已取消。可以重新添加或登录。' }
        'Running:|requires all ChatGPT|processes to exit|Close all ChatGPT' { return '请退出 ChatGPT、Codex CLI 和 VS Code 中的 Codex，然后重试。' }
        'Profile switched|launch|executable' { return '配置档可能已切换，但应用未能启动。请修复后重试同一配置档。' }
        'duplicate|already exists|unique' { return '名称或 ChatGPT 账号已存在。请更换名称，或重新登录已有配置档。' }
        'display.?name|name must|name is' { return '显示名称无效：请使用 1–40 个字符，且不要与现有名称重复。' }
        'base.?url|https|uri|url' { return 'Base URL 无效：请使用完整 HTTPS 地址；本机测试可使用 HTTP。' }
        'model' { return '模型名称无效或当前服务不支持，请检查模型字段。' }
        'api.?key|credential|authentication|unauthorized|401|403' { return '认证检查失败。请检查 API Key，或重新登录 ChatGPT。' }
        'current|active.*delet|last.*profile|at least one' { return '不能删除当前配置档或最后一个有效配置档。请先切换到其他配置档。' }
        'identity|fingerprint|mismatch|recorded active profile' { return '登录账号与配置档不匹配。切换时会自动校正状态；也可以重新登录原账号或执行“重置 / 修复”。' }
        'recover|pending|registry|schema' { return '配置或恢复记录需要处理。请执行“重置 / 修复”，保留现有恢复文件。' }
        'cost|confirm' { return '连接测试需要确认可能产生少量费用。离线保存无需连接测试。' }
        'timeout|connect|network|test.*fail' { return '连接测试未通过。请检查服务地址和网络；仍可离线保存有效配置。' }
        default { return '操作未完成。请检查配置字段或执行“重置 / 修复”后重试。为保护凭据，未显示原始异常。' }
    }
}
$code = 0
try {
    if (-not (Test-Path -LiteralPath $SwitcherPath -PathType Leaf)) { throw 'Switcher executable is missing.' }
    $arguments = @{}
    if ($TestSettings) { $arguments.TestSettings = $TestSettings }
    $response = @{ success = $true; message = '操作已完成。' }
    if ($Action -eq 'List') {
        $raw = & $SwitcherPath -StatusJson @arguments 3>$null 4>$null 5>$null 6>$null
        $status = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
        $profiles = @($status.profiles | ForEach-Object {
            $item = @{}
            foreach ($field in @('id','displayName','kind','sortOrder','status','host','model','baseUrl')) {
                if ($null -ne $_.PSObject.Properties[$field]) { $item[$field] = $_.$field }
            }
            $item
        })
        $identityMismatch = $false
        if ($null -ne $status.PSObject.Properties['activeIdentityMismatch']) { $identityMismatch = [bool]$status.activeIdentityMismatch }
        $response.data = @{ registrySchema = $status.registrySchema; activeProfileId = $status.activeProfileId; activeIdentityMismatch = $identityMismatch; profiles = $profiles }
    } elseif ($Action -eq 'Manage') {
        # The core reads Console.In once. Never copy secrets to argv/files/logs.
        $raw = & $SwitcherPath -ManageStdin @arguments 3>$null 4>$null 5>$null 6>$null
        # Online checks may return a controlled negative result without throwing.
        $managementResult = $null
        try { $managementResult = ($raw -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop } catch { }
        if ($null -ne $managementResult -and $null -ne $managementResult.PSObject.Properties['success'] -and $managementResult.success -eq $false) {
            $code = 1
            $response = @{ success = $false; message = '连接测试未通过。请检查服务地址、模型、Key 和额度；仍可离线保存。' }
        }
        $raw = $null; $managementResult = $null
    } elseif ($Action -eq 'Repair') {
        $null = & $SwitcherPath -Initialize @arguments 3>$null 4>$null 5>$null 6>$null
        $response.message = '配置已修复。请选择配置档启动应用。'
    } else {
        if ($Action -in @('Personal','Lab')) { $ProfileId = $Action.ToLowerInvariant() }
        if ($ProfileId -notmatch '^(personal|lab|[a-f0-9]{32})$') { throw 'Invalid profile id.' }
        $null = & $SwitcherPath -ProfileId $ProfileId @arguments 3>$null 4>$null 5>$null 6>$null
    }
} catch {
    if ($TestSettings -and $env:CODEX_SWITCHER_TEST_MODE -eq '1') {
        [Console]::Error.WriteLine('Runner test failure location: '+$_.ScriptStackTrace)
    }
    $code = 1
    $response = @{ success = $false; message = (Get-SafeFailure -Detail $_.Exception.Message) }
}
try {
    [IO.File]::WriteAllText($OutputPath, ($response | ConvertTo-Json -Depth 12 -Compress), (New-Object Text.UTF8Encoding($false)))
} catch { $code = 1 }
exit $code
