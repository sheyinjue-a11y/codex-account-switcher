[CmdletBinding()]
param([string]$Name = 'codex-account-switcher-windows')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Name -cnotmatch '^[a-z0-9][a-z0-9-]{0,79}$') { throw 'Invalid distribution name.' }
$repo = Split-Path $PSScriptRoot -Parent
$destination = Join-Path $repo ('dist\' + $Name)
$zip = $destination + '.zip'
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $zip)) { throw 'Output already exists. Choose a new name.' }
$files = @('AccountPicker.xaml','ProfileRegistry.ps1','ProfileManagement.ps1','ProfileDialogs.ps1',
    'AstraWarmup.ps1','Invoke-AstraWarmup.ps1','Configure-AstraWarmup.ps1',
    'Switch-ChatGPTAccount.ps1','Invoke-ChatGPTSwitch.ps1','Start-ChatGPT.ps1','Open-Switcher.ps1')
$relativeFiles = @($files | ForEach-Object { 'tools/chatgpt-account-switch/' + $_ })
$relativeFiles += @('README.md','LICENSE','SECURITY.md','assets/readme-banner.svg','assets/account-picker.png','assets/macos-picker.png',
    'macos/README.md','docs/superpowers/plans/2026-10-01-model-catalog-refresh.md',
    'tools/codex-api-fast/README.md','tools/codex-api-fast/Start-LocalApiFastClient.ps1','tools/codex-api-fast/Disable-LocalApiFastClient.ps1')
$relativeFiles += @('package.json','package-lock.json','patch-core.cjs','local-client-core.cjs','Install-LocalApiFastClient.ps1' | ForEach-Object { 'tools/codex-api-fast/' + $_ })
foreach ($relative in $relativeFiles) {
    $source = Join-Path $repo $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing runtime file: $relative" }
    if ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Runtime file is a link: $relative" }
    if ([IO.Path]::GetExtension($source) -ne '.png') {
        $content = [IO.File]::ReadAllText($source)
        if ($content -match '(?i)\bsk-[a-z0-9_-]{20,}|\bgh[pousr]_[a-z0-9]{30,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----') { throw "Possible secret: $relative" }
        foreach ($privatePath in @($repo,[Environment]::GetFolderPath('UserProfile'))) {
            if ($content.IndexOf($privatePath,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Machine-specific path: $relative" }
        }
    }
}
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The .NET Framework C# compiler is required to build the launcher.' }
foreach ($relative in $relativeFiles) {
    $target = Join-Path $destination ('app\' + $relative)
    $null = New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
    Copy-Item -LiteralPath (Join-Path $repo $relative) -Destination $target
}
$launcher = Join-Path $destination 'Codex Account Switcher.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /reference:System.Windows.Forms.dll ('/out:' + $launcher) (Join-Path $PSScriptRoot 'WindowsLauncher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher build failed.' }
$process = Start-Process -FilePath $launcher -ArgumentList '--verify-layout' -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0) { throw 'The packaged launcher cannot locate its runtime.' }
$instructions = @'
Codex Account Switcher

完整解压后，双击 Codex Account Switcher.exe。
首次使用会自动打开设置向导；已有账号时直接进入账号列表。
官方 Codex 已安装时，自动使用其登录组件，无需另装 Node.js 或 Python。
日常只需这一个入口。登录、导入、修复和 Astra 预热都可以在窗口中操作。

请保留旁边的 app 文件夹。可右键应用 → 发送到 → 桌面快捷方式。
此社区应用暂未购买 Windows 代码签名；系统可能显示未知发布者提示。
核实下载来源后再决定运行，不要关闭系统安全功能。

首次使用前建议备份 .codex；聊天数据继续共用，API 请求按服务商规则计费。
详细说明与 MIT 许可证位于 app 文件夹。
'@
[IO.File]::WriteAllText((Join-Path $destination '使用说明.txt'), $instructions, [Text.UTF8Encoding]::new($true))
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($destination, $zip)
Write-Host "Windows app package: $zip"
Write-Host ('SHA256: ' + (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash)
