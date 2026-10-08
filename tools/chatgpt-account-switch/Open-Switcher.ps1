[CmdletBinding()]
param([switch]$LoadOnly, [string]$PreviewPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$bootstrapLoadOnly = $LoadOnly
$bootstrapPreviewPath = $PreviewPath
. (Join-Path $PSScriptRoot 'Start-ChatGPT.ps1') -LoadOnly

function Get-FirstRunStep {
    param([bool]$HasApp, [bool]$HasCli, [bool]$HasRegistry, [bool]$HasAuth, [bool]$CustomHome)
    if ($CustomHome) { return 'CustomHome' }
    if (-not $HasApp) { return 'InstallApp' }
    if (-not $HasCli) { return 'InstallCli' }
    if ($HasRegistry) { return 'Ready' }
    if ($HasAuth) { return 'Import' }
    return 'Login'
}

function Get-FirstRunEnvironment {
    $canonical = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    $vault = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexAccountSwitcher'
    $package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
    $cli = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    # Reuse the CLI shipped with the desktop client. No separate Node/npm install.
    if (-not $cli -and $package) {
        $bundled = Join-Path $package.InstallLocation 'app\resources\codex.exe'
        if (Test-Path -LiteralPath $bundled -PathType Leaf) {
            $env:PATH = (Split-Path $bundled -Parent) + ';' + $env:PATH
            $cli = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }
    $custom = $false
    foreach ($target in @('Process','User','Machine')) {
        $override = [Environment]::GetEnvironmentVariable('CODEX_HOME', $target)
        if ($override -and [IO.Path]::GetFullPath($override).TrimEnd('\') -ine $canonical.TrimEnd('\')) { $custom = $true }
    }
    return [pscustomobject]@{
        Step = Get-FirstRunStep -HasApp ($null -ne $package) -HasCli ($null -ne $cli) -HasRegistry (Test-Path -LiteralPath (Join-Path $vault 'profiles.json')) -HasAuth (Test-Path -LiteralPath (Join-Path $canonical 'auth.json')) -CustomHome $custom
        Cli = $(if ($cli) { $cli.Source } else { '' })
        CanonicalHome = $canonical
    }
}

function New-FirstRunWindow {
    [xml]$markup = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Codex Account Switcher" Width="570" Height="420" MinWidth="520" MinHeight="390" WindowStartupLocation="CenterScreen" Background="#FAFBFC" FontFamily="Microsoft YaHei UI" Foreground="#1F2933">
 <Grid Margin="30"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Text="Codex Account Switcher" FontFamily="Segoe UI Semibold" FontSize="16" Foreground="#536773"/>
  <TextBlock Name="Heading" Grid.Row="1" Text="准备好，就开始切换。" FontSize="26" FontWeight="SemiBold" Margin="0,18,0,16"/>
  <TextBlock Name="Detail" Grid.Row="2" TextWrapping="Wrap" FontSize="14" LineHeight="24"/>
  <ProgressBar Name="Progress" Grid.Row="3" Height="3" IsIndeterminate="True" Visibility="Collapsed" Margin="0,12,0,18"/>
  <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
   <Button Name="Refresh" Content="重新检查" Padding="16,9" Margin="0,0,10,0"/>
   <Button Name="Continue" Content="开始使用" Padding="20,9" Background="#287CA0" Foreground="White" BorderThickness="0"/>
  </StackPanel>
 </Grid>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new($markup)
    try { return [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
}

function Show-FirstRun {
    $environment = Get-FirstRunEnvironment
    if ($environment.Step -eq 'Ready') { return $true }
    $window = New-FirstRunWindow
    $state = @{ Environment = $environment; Job = $null; Login = $null; LoginDeadline = $null; Ready = $false }
    $detail = $window.FindName('Detail'); $heading = $window.FindName('Heading')
    $next = $window.FindName('Continue'); $refresh = $window.FindName('Refresh'); $progress = $window.FindName('Progress')
    $timer = [Windows.Threading.DispatcherTimer]::new(); $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $render = {
        $state.Environment = Get-FirstRunEnvironment
        $next.IsEnabled = $true
        switch ($state.Environment.Step) {
            'Ready' { $state.Ready = $true; $window.Close() }
            'Import' { $heading.Text = '已有登录，马上接着用。'; $detail.Text = '将当前 Codex 登录导入账号列表。本地会话与项目继续共用。请先退出 Codex、CLI 和编辑器中的 Codex，再点击下方按钮。'; $next.Content = '导入并打开' }
            'Login' { $heading.Text = '先连接你的第一个账号。'; $detail.Text = '点击下方按钮，在浏览器完成官方 Codex 登录。成功后会自动导入并打开账号列表，以后双击此应用即可使用。请先退出正在运行的 Codex。'; $next.Content = '登录并开始' }
            'InstallApp' { $heading.Text = '先安装官方 Codex。'; $detail.Text = '切换器需要官方 Codex 桌面应用。安装完成后回到这里，点击“重新检查”，继续在同一个窗口设置。'; $next.Content = '打开官方下载页' }
            'InstallCli' { $heading.Text = '请更新官方 Codex。'; $detail.Text = '未找到 Codex 登录组件。请安装或更新官方桌面应用，随后点击“重新检查”。也可使用已安装且在 PATH 中的官方 codex.exe。'; $next.Content = '打开官方下载页' }
            'CustomHome' { $heading.Text = '当前使用了自定义数据目录。'; $detail.Text = '切换器目前管理默认 .codex 目录。请清除自定义 CODEX_HOME 环境变量并重新打开切换器，或继续使用原来的 Codex 配置。'; $next.IsEnabled = $false }
        }
    }.GetNewClosure()
    $busy = { param($value) $next.IsEnabled = -not $value; $refresh.IsEnabled = -not $value; $progress.Visibility = $(if ($value) { 'Visible' } else { 'Collapsed' }) }.GetNewClosure()
    $import = {
        & $busy $true
        $detail.Text = '正在导入当前登录并准备账号列表…'
        $state.Job = Start-PickerSwitch -Action Repair -ScriptPath (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1')
        $timer.Start()
    }.GetNewClosure()
    $next.Add_Click(({
        try {
            switch ($state.Environment.Step) {
                { $_ -in @('InstallApp','InstallCli') } { Start-Process 'https://chatgpt.com/codex' }
                'Import' { & $import }
                'Login' {
                    # Recheck immediately: never replace a login that appeared meanwhile.
                    & $render
                    if ($state.Environment.Step -ne 'Login') { return }
                    . (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
                    $settings = Get-SwitcherSettings
                    Assert-CodexQuiescent $settings
                    $null = New-Item -ItemType Directory -Path $state.Environment.CanonicalHome -Force
                    $info = New-IsolatedCodexStartInfo $state.Environment.Cli $state.Environment.CanonicalHome '-c cli_auth_credentials_store=\"file\" login'
                    $info.CreateNoWindow = $true; $info.UseShellExecute = $false
                    $state.Login = [Diagnostics.Process]::Start($info)
                    $state.LoginDeadline = [DateTime]::UtcNow.AddMinutes(10)
                    & $busy $true; $detail.Text = '请在浏览器完成登录。登录成功后，这里会自动继续。'; $timer.Start()
                }
            }
        } catch { & $busy $false; $detail.Text = '操作未能开始。请完全退出 Codex 后点击“重新检查”再试。' }
    }.GetNewClosure()))
    $refresh.Add_Click(({ & $render }.GetNewClosure()))
    $timer.Add_Tick(({
        if ($state.Login -and -not $state.Login.HasExited -and [DateTime]::UtcNow -gt $state.LoginDeadline) {
            try { $state.Login.Kill(); $state.Login.WaitForExit(3000) | Out-Null } catch { }
        }
        if ($state.Login -and $state.Login.HasExited) {
            $timer.Stop(); $code = $state.Login.ExitCode; $state.Login.Dispose(); $state.Login = $null
            & $busy $false
            if ($code -eq 0) { & $render; if ($state.Environment.Step -eq 'Import') { & $import } }
            else { $detail.Text = '登录未完成。可以点击“登录并开始”重试。' }
        }
        if ($state.Job -and $state.Job.Process.HasExited) {
            $timer.Stop(); $job = $state.Job; $state.Job = $null; & $busy $false
            try {
                $result = [IO.File]::ReadAllText($job.OutputPath) | ConvertFrom-Json
                if ($job.Process.ExitCode -eq 0 -and $result.success) { & $render }
                else { $detail.Text = [string]$result.message }
            } catch { $detail.Text = '初始化未完成。请重新检查后重试。' }
            finally { $job.Process.Dispose(); Remove-Item -LiteralPath $job.OutputPath -ErrorAction SilentlyContinue }
        }
    }.GetNewClosure()))
    $window.Add_Closing(({
        param($sender,$eventArgs)
        if ($state.Job) { $eventArgs.Cancel = $true }
        if ($state.Login) { try { $state.Login.Kill(); $state.Login.WaitForExit(3000) | Out-Null } catch { }; $state.Login.Dispose(); $state.Login = $null }
    }.GetNewClosure()))
    $window.Add_Closed(({ $timer.Stop() }.GetNewClosure()))
    & $render
    $null = $window.ShowDialog()
    return $state.Ready
}

if ($bootstrapLoadOnly) { return }
if ($bootstrapPreviewPath) {
    $window = New-FirstRunWindow
    $window.FindName('Detail').Text = '登录一次，之后直接打开账号列表。在同一个窗口添加 ChatGPT 账号或 API，继续使用已有会话与项目。'
    Export-PickerPreview $window $bootstrapPreviewPath
    return
}
$uiMutex = [Threading.Mutex]::new($false, ('Local\CodexAccountSwitcher.UI.' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
$ownsUiMutex = $false
try {
    try { $ownsUiMutex = $uiMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsUiMutex = $true }
    if (-not $ownsUiMutex) { [Windows.MessageBox]::Show('切换器已经打开，请切回已有窗口。', 'Codex Account Switcher') | Out-Null; return }
    if (Show-FirstRun) { & (Join-Path $PSScriptRoot 'Start-ChatGPT.ps1') }
} catch { [Windows.MessageBox]::Show('切换器未能打开。请完整解压下载包，并确认官方 Codex 已安装。', 'Codex Account Switcher') | Out-Null }
finally { if ($ownsUiMutex) { $uiMutex.ReleaseMutex() }; $uiMutex.Dispose() }
