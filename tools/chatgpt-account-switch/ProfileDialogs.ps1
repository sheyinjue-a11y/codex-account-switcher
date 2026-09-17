function New-ProfileDialog {
    param([ValidateSet('add_api','update_api','rename','add_chatgpt')][string]$Action, $Profile)
    [xml]$markup = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="配置档" Width="490" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FAFBFC" FontFamily="Microsoft YaHei UI">
 <StackPanel Margin="24">
  <TextBlock x:Name="Heading" FontSize="21" FontWeight="SemiBold" Margin="0,0,0,18"/>
  <StackPanel x:Name="Fields">
   <TextBlock Text="显示名称"/><TextBox x:Name="NameInput" MaxLength="40" Padding="7" Margin="0,5,0,13"/>
   <StackPanel x:Name="ApiFields">
    <TextBlock Text="Base URL（Responses API）"/><TextBox x:Name="BaseUrlInput" Padding="7" Margin="0,5,0,13"/>
    <TextBlock x:Name="KeyLabel" Text="API Key"/><PasswordBox x:Name="KeyInput" Padding="7" Margin="0,5,0,13"/>
    <TextBlock Text="默认模型"/><TextBox x:Name="ModelInput" Padding="7" Margin="0,5,0,13"/>
    <TextBlock Text="保存只做本地检查；测试连接可能消耗少量 API 额度。" TextWrapping="Wrap" FontSize="12" Foreground="#63717C"/>
   </StackPanel>
   <TextBlock x:Name="LoginNote" Text="接下来会打开浏览器。请确认登录的是目标账号；返回主窗口后可取消登录。" TextWrapping="Wrap" FontSize="12" Foreground="#63717C" Visibility="Collapsed"/>
  </StackPanel>
  <TextBox x:Name="DialogStatus" IsReadOnly="True" TextWrapping="Wrap" BorderThickness="0" Background="Transparent" Foreground="#A33B32" Margin="0,12,0,0" MaxHeight="80" VerticalScrollBarVisibility="Auto"/>
  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
   <Button x:Name="TestButton" Content="测试连接" Padding="12,7" Margin="0,0,8,0"/>
   <Button x:Name="CloseButton" Content="取消" IsCancel="True" Padding="12,7" Margin="0,0,8,0"/>
   <Button x:Name="SaveButton" Content="保存" IsDefault="True" Padding="16,7"/>
  </StackPanel>
 </StackPanel>
</Window>
'@
    $reader = New-Object Xml.XmlNodeReader($markup)
    try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $isApi = $Action -in @('add_api','update_api')
    $window.FindName('Heading').Text = switch ($Action) { 'add_api' {'添加 Responses API'} 'update_api' {'编辑 Responses API'} 'rename' {'重命名配置档'} 'add_chatgpt' {'添加 ChatGPT 账号'} }
    if (-not $isApi) { $window.FindName('ApiFields').Visibility = 'Collapsed'; $window.FindName('TestButton').Visibility = 'Collapsed' }
    if ($Action -eq 'add_chatgpt') { $window.FindName('LoginNote').Visibility = 'Visible'; $window.FindName('SaveButton').Content = '打开浏览器登录' }
    if ($null -ne $Profile) {
        $window.FindName('NameInput').Text = [string]$Profile.displayName
        foreach ($pair in @(@('baseUrl','BaseUrlInput'),@('model','ModelInput'))) {
            if ($null -ne $Profile.PSObject.Properties[$pair[0]]) { $window.FindName($pair[1]).Text = [string]$Profile.($pair[0]) }
        }
    }
    if ($Action -eq 'update_api') { $window.FindName('KeyLabel').Text = 'API Key（留空保留现有 Key）' }
    $window.Tag = @{ Action = $Action; Profile = $Profile; Request = $null; Busy = $false; Job = $null }
    return $window
}

function Get-ProfileDialogRequest {
    param($Window, [switch]$TestConnection)
    $name = $Window.FindName('NameInput').Text.Trim()
    if (-not $name -or $name.Length -gt 40 -or $name -match '[\x00-\x1f\x7f]') { throw '请填写有效的显示名称（1–40 个字符）。' }
    $request = @{ action = $Window.Tag.Action; displayName = $name }
    if ($null -ne $Window.Tag.Profile) { $request.profileId = $Window.Tag.Profile.id }
    if ($Window.Tag.Action -in @('add_api','update_api')) {
        $url = $Window.FindName('BaseUrlInput').Text.Trim()
        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
            ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback)) -or
            $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Base URL 需要完整 HTTPS 地址，不可包含账号、查询参数或片段。本机测试可用 HTTP。' }
        $model = $Window.FindName('ModelInput').Text.Trim()
        if ($model -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$') { throw '模型名称需为 1–200 个字符，仅支持字母、数字、点、斜杠、冒号、横线和下划线。' }
        $key = $Window.FindName('KeyInput').Password
        if (-not $key -and $Window.Tag.Action -eq 'add_api') { throw '请填写 API Key。' }
        if ($key -match '[\x00-\x20\x7f]') { throw 'API Key 不应包含空格或控制字符。' }
        $request.baseUrl = $url; $request.model = $model; $request.apiKey = $key
    }
    if ($TestConnection) { $request.action = 'test_api'; $request.confirmCost = $true }
    return $request
}

function Show-ProfileDialog {
    param($Owner, [string]$Action, $Profile, [scriptblock]$TestRunner)
    $window = New-ProfileDialog -Action $Action -Profile $Profile
    $window.Owner = $Owner
    $dialog = $window.Tag
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $setBusy = {
        param([bool]$Value)
        $dialog.Busy = $Value
        foreach ($name in @('Fields','SaveButton','CloseButton','TestButton')) { $window.FindName($name).IsEnabled = -not $Value }
    }.GetNewClosure()
    $window.FindName('SaveButton').Add_Click(({
        try { $dialog.Request = Get-ProfileDialogRequest -Window $window; $window.DialogResult = $true }
        catch { $window.FindName('DialogStatus').Text = $_.Exception.Message }
    }.GetNewClosure()))
    $window.FindName('CloseButton').Add_Click(({ $window.Close() }.GetNewClosure()))
    $window.Add_Closing(({ param($sender,$eventArgs) if ($dialog.Busy) { $eventArgs.Cancel = $true } }.GetNewClosure()))
    $window.FindName('TestButton').Add_Click(({
        try { $request = Get-ProfileDialogRequest -Window $window -TestConnection }
        catch { $window.FindName('DialogStatus').Text = $_.Exception.Message; return }
        $answer = [Windows.MessageBox]::Show($window, '测试会向所填服务发送最小请求，可能消耗少量 API 额度。是否继续？', '确认连接测试', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
        & $setBusy $true
        $window.FindName('DialogStatus').Text = '正在测试连接…测试失败后仍可离线保存。'
        try { $dialog.Job = & $TestRunner $request; $timer.Start() }
        catch { & $setBusy $false; $window.FindName('DialogStatus').Text = '无法启动测试。仍可保存配置并稍后重试。' }
        finally { $request = $null }
    }.GetNewClosure()))
    $timer.Add_Tick(({
        if ($null -eq $dialog.Job -or -not $dialog.Job.Process.HasExited) { return }
        $timer.Stop(); $job = $dialog.Job; $dialog.Job = $null
        try {
            $result = [IO.File]::ReadAllText($job.OutputPath) | ConvertFrom-Json
            $window.FindName('DialogStatus').Text = if ($result.success -and $job.Process.ExitCode -eq 0) { '连接测试通过。可以保存配置。' } else { [string]$result.message + ' 仍可离线保存。' }
        } catch { $window.FindName('DialogStatus').Text = '无法读取测试结果。仍可离线保存。' }
        finally { Remove-Item -LiteralPath $job.OutputPath -Force -ErrorAction SilentlyContinue; $job.Process.Dispose(); & $setBusy $false }
    }.GetNewClosure()))
    try { $null = $window.ShowDialog(); return $dialog.Request }
    finally { $timer.Stop(); $window.FindName('KeyInput').Clear(); $dialog.Request = $null }
}
