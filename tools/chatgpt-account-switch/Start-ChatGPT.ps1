[CmdletBinding()]
param(
    [Parameter(DontShow = $true)][switch]$LoadOnly,
    [Parameter(DontShow = $true)][string]$PreviewPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[Windows.Media.RenderOptions]::ProcessRenderMode = [Windows.Interop.RenderMode]::SoftwareOnly
. (Join-Path $PSScriptRoot 'ProfileDialogs.ps1')

function Get-PickerPreviewStatus {
    return [pscustomobject]@{ registrySchema = 2; activeProfileId = 'personal'; profiles = @(
        [pscustomobject]@{ id = 'personal'; displayName = '个人'; kind = 'chatgpt'; sortOrder = 0; status = 'ready'; host = ''; model = '' },
        [pscustomobject]@{ id = 'lab'; displayName = '实验室'; kind = 'responses_api'; sortOrder = 1; status = 'ready'; host = 'api.example.com'; baseUrl = 'https://api.example.com/v1'; model = 'gpt-5' }
    ) }
}
function New-AccountPicker {
    param($Status = (Get-PickerPreviewStatus))
    [xml]$markup = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'AccountPicker.xaml'), [Text.Encoding]::UTF8)
    $reader = New-Object Xml.XmlNodeReader($markup)
    try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $window.Tag = @{ Status = $Status; Cards = @{}; Names = @() }
    Set-PickerProfiles -Window $window -Status $Status
    try {
        $iconPath = Join-Path $PSScriptRoot 'ChatGPT-Official.ico'
        if (Test-Path -LiteralPath $iconPath) {
            $decoder = [Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$iconPath, [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $window.Icon = $decoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
        }
    } catch { }
    return $window
}
function Set-PickerProfiles {
    param($Window, $Status, [scriptblock]$OnSwitch, [scriptblock]$OnManage)
    $panel = $Window.FindName('ProfileCards')
    $panel.Children.Clear()
    foreach ($name in $Window.Tag.Names) { $Window.UnregisterName($name) }
    $Window.Tag.Names = @(); $Window.Tag.Cards = @{}; $Window.Tag.Status = $Status
    foreach ($profile in @($Status.profiles | Sort-Object sortOrder, id)) {
        $row = New-Object Windows.Controls.Grid
        $row.Margin = '0,0,0,8'
        $column = New-Object Windows.Controls.ColumnDefinition; $column.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star); $row.ColumnDefinitions.Add($column)
        $column = New-Object Windows.Controls.ColumnDefinition; $column.Width = New-Object Windows.GridLength(48); $row.ColumnDefinitions.Add($column)
        $button = New-Object Windows.Controls.Button
        $button.Style = $Window.FindResource('AccountCard'); $button.Tag = $profile.id
        [Windows.Automation.AutomationProperties]::SetName($button, ('使用配置档 ' + $profile.displayName))
        $stack = New-Object Windows.Controls.StackPanel
        $title = New-Object Windows.Controls.TextBlock
        $isCurrent = $profile.id -eq $Status.activeProfileId
        $title.Text = [string]$profile.displayName + $(if ($isCurrent) { '   · 当前' } else { '' })
        $title.FontSize = 18; $title.FontWeight = 'SemiBold'; $title.TextWrapping = 'Wrap'
        $stack.Children.Add($title) | Out-Null
        $detail = New-Object Windows.Controls.TextBlock
        $kind = if ($profile.kind -eq 'chatgpt') { 'ChatGPT 登录' } else { 'Responses API' }
        $description = $kind
        foreach ($field in @('host','model')) { if ($profile.kind -eq 'responses_api' -and $null -ne $profile.PSObject.Properties[$field] -and $profile.$field) { $description += ' · ' + $profile.$field } }
        $detail.Text = $description; $detail.FontSize = 12; $detail.Foreground = [Windows.Media.Brushes]::SlateGray; $detail.Margin = '0,6,0,0'; $detail.TextWrapping = 'Wrap'
        $stack.Children.Add($detail) | Out-Null
        $statusLine = New-Object Windows.Controls.TextBlock
        $ready = $profile.status -in @('ready','valid','ok')
        $statusLine.Text = if ($ready) { '可用' } else { '需要修复 · 请编辑、重新登录或修复' }
        $statusLine.FontSize = 11; $statusLine.Margin = '0,7,0,0'
        $statusLine.Foreground = if ($ready) { [Windows.Media.Brushes]::SeaGreen } else { [Windows.Media.Brushes]::Firebrick }
        $stack.Children.Add($statusLine) | Out-Null
        $button.Content = $stack
        if ($isCurrent) { $button.BorderBrush = [Windows.Media.Brushes]::SeaGreen }
        $row.Children.Add($button) | Out-Null
        $menuButton = New-Object Windows.Controls.Button
        $menuButton.Content = '⋯'; $menuButton.FontSize = 23; $menuButton.Padding = '5'; $menuButton.Margin = '7,0,0,0'; $menuButton.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($menuButton, 1)
        [Windows.Automation.AutomationProperties]::SetName($menuButton, ('管理配置档 ' + $profile.displayName))
        $menu = New-Object Windows.Controls.ContextMenu
        $entries = @(@('rename','重命名'), $(if ($profile.kind -eq 'chatgpt') { @('relogin','重新登录') } else { @('update_api','编辑 API') }), @('delete','删除'))
        $items = @{}
        foreach ($entry in $entries) {
            $item = New-Object Windows.Controls.MenuItem; $item.Header = $entry[1]; $operation = $entry[0]
            if ($operation -eq 'delete') { $item.IsEnabled = -not $isCurrent }
            if ($null -ne $OnManage) { $item.Add_Click(({ & $OnManage $operation $profile }.GetNewClosure())) }
            $menu.Items.Add($item) | Out-Null; $items[$operation] = $item
        }
        $menuButton.ContextMenu = $menu
        $menuButton.Add_Click(({ $menu.PlacementTarget = $menuButton; $menu.IsOpen = $true }.GetNewClosure()))
        if ($null -ne $OnSwitch) { $button.Add_Click(({ & $OnSwitch $profile.id }.GetNewClosure())) }
        $row.Children.Add($menuButton) | Out-Null; $panel.Children.Add($row) | Out-Null
        $Window.Tag.Cards[$profile.id] = @{ Switch = $button; Menu = $menuButton; Items = $items }
        # Preserve the existing descendant regression's public lookup names.
        $legacyName = if ($profile.id -eq 'personal') { 'PersonalButton' } elseif ($profile.id -eq 'lab') { 'LabButton' } else { $null }
        if ($legacyName) { $Window.RegisterName($legacyName, $button); $Window.Tag.Names += $legacyName }
    }
    $Window.FindName('LastProfile').Text = '共 ' + @($Status.profiles).Count + ' 个配置档'
}
function Start-PickerSwitch {
    param([string]$Action = 'Switch', [string]$ProfileId, [string]$Profile, [string]$ScriptPath, $Request)
    if ($Profile) { if ($Profile -eq 'Repair') { $Action = 'Repair' } else { $ProfileId = $Profile.ToLowerInvariant() } }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw 'Switcher is missing.' }
    $runnerPath = Join-Path $PSScriptRoot 'Invoke-ChatGPTSwitch.ps1'
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-account-picker-' + [guid]::NewGuid().ToString('N') + '.json')
    if ($Action -notin @('Switch','Repair','Manage','List')) { throw 'Invalid action.' }
    if ($Action -eq 'Switch' -and $ProfileId -notmatch '^(personal|lab|[a-f0-9]{32})$') { throw 'Invalid profile id.' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $runnerPath + '" -Action ' + $Action + ' -SwitcherPath "' + $ScriptPath + '" -OutputPath "' + $outputPath + '"'
    if ($ProfileId) { $info.Arguments += ' -ProfileId ' + $ProfileId }
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $Action -eq 'Manage'
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'Could not start the switcher.' }
    if ($Action -eq 'Manage') {
        try {
            $payload = [Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Depth 8 -Compress))
            $process.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        finally {
            if ($null -ne $payload) { [Array]::Clear($payload, 0, $payload.Length) }
            $process.StandardInput.Close()
        }
    }
    # No redirected stdout/stderr: descendants cannot hold a UI read open.
    return @{ Process = $process; OutputPath = $outputPath }
}
function Connect-AccountPicker {
    param($Window, [string]$SwitcherPath, [scriptblock]$Runner = ${function:Start-PickerSwitch}, [switch]$LoadProfiles)
    $controls = @{}
    foreach ($name in @('ProfileCards','AddButton','CancelButton','RepairButton','RetryButton','CancelLoginButton','CopyErrorButton','StatusText','Progress','ErrorDetails','ErrorText')) { $controls[$name] = $Window.FindName($name) }
    $state = @{ Busy = $false; Job = $null; Controls = $controls; Window = $Window; Runner = $Runner; SwitcherPath = $SwitcherPath; LastOperation = $null; CancelPath = $null; Action = ''; CompletionMessage = '' }
    $timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(150); $state.Timer = $timer
    $setBusy = {
        param([bool]$Busy)
        $state.Busy = $Busy
        foreach ($name in @('ProfileCards','AddButton','CancelButton','RepairButton','RetryButton','CopyErrorButton')) { $controls[$name].IsEnabled = -not $Busy }
        foreach ($card in $Window.Tag.Cards.Values) { $card.Switch.IsEnabled = -not $Busy; $card.Menu.IsEnabled = -not $Busy; $card.Menu.ContextMenu.IsOpen = $false }
        $controls.Progress.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
        $controls.CancelLoginButton.Visibility = if ($Busy -and $state.CancelPath) { 'Visible' } else { 'Collapsed' }
        $controls.CancelLoginButton.IsEnabled = $true
    }.GetNewClosure()
    $showError = {
        param([string]$Detail)
        & $setBusy $false
        $controls.StatusText.Text = $Detail; $controls.StatusText.Foreground = [Windows.Media.Brushes]::Firebrick
        $controls.ErrorText.Text = $Detail; $controls.ErrorDetails.Visibility = 'Visible'
        $controls.RetryButton.Visibility = if ($null -ne $state.LastOperation -and $state.LastOperation.Action -ne 'Manage') { 'Visible' } else { 'Collapsed' }
    }.GetNewClosure()
    $begin = {
        param([string]$Action, [string]$ProfileId, $Request)
        if ($state.Busy) { return }
        $state.Action = $Action
        # Requests containing keys live only until stdin has been written. Retry management through its form.
        $state.LastOperation = @{ Action = $Action; ProfileId = $ProfileId }
        if ($Action -eq 'Manage' -and $Request.action -in @('add_chatgpt','relogin')) {
            $state.CancelPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-enrollment-cancel-' + [guid]::NewGuid().ToString('N') + '.flag')
            $Request.cancelPath = $state.CancelPath
        }
        & $setBusy $true
        $controls.ErrorDetails.Visibility = 'Collapsed'; $controls.RetryButton.Visibility = 'Collapsed'; $controls.ErrorText.Clear()
        $controls.StatusText.Foreground = [Windows.Media.Brushes]::SlateGray
        $controls.StatusText.Text = if ($state.CancelPath) { '请在浏览器完成目标 ChatGPT 账号登录。可点“取消登录”安全取消。' } elseif ($Action -eq 'List') { '正在读取配置档…' } elseif ($Action -eq 'Repair') { '正在校验并修复配置…' } elseif ($Action -eq 'Manage') { '正在保存配置档…' } else { '正在切换配置档并启动应用…' }
        try { $state.Job = & $state.Runner -Action $Action -ProfileId $ProfileId -ScriptPath $state.SwitcherPath -Request $Request; $state.Timer.Start() }
        catch { $state.CancelPath = $null; & $showError '无法启动后台操作。请检查切换器文件后重试。' }
    }.GetNewClosure()
    $onSwitch = { param($Id) & $begin 'Switch' $Id $null }.GetNewClosure()
    $testRunner = { param($Request) & $state.Runner -Action 'Manage' -ScriptPath $state.SwitcherPath -Request $Request }.GetNewClosure()
    $onManage = {
        param([string]$Action, $Profile)
        if ($state.Busy) { return }
        $request = $null
        if ($Action -eq 'delete') {
            if ($Profile.id -eq $Window.Tag.Status.activeProfileId) { return }
            $kind = if ($Profile.kind -eq 'chatgpt') { 'ChatGPT 登录' } else { 'Responses API' }
            if ([Windows.MessageBox]::Show($Window, ('删除“' + $Profile.displayName + '”（' + $kind + '）？将移除此配置档及其加密凭据。共享会话、项目和工作区会保留。'), '确认删除配置档', 'YesNo', 'Warning') -ne 'Yes') { return }
            $request = @{ action = 'delete'; profileId = $Profile.id }
        } elseif ($Action -eq 'relogin') {
            if ([Windows.MessageBox]::Show($Window, ('将在浏览器重新登录“' + $Profile.displayName + '”。请使用原账号；主窗口可以取消登录。'), '重新登录', 'OKCancel', 'Information') -ne 'OK') { return }
            $request = @{ action = 'relogin'; profileId = $Profile.id }
        } else { $request = Show-ProfileDialog -Owner $Window -Action $Action -Profile $Profile -TestRunner $testRunner }
        if ($null -ne $request) { & $begin 'Manage' '' $request; $request = $null }
    }.GetNewClosure()
    $refresh = { param($Status) Set-PickerProfiles -Window $Window -Status $Status -OnSwitch $onSwitch -OnManage $onManage }.GetNewClosure()
    & $refresh $Window.Tag.Status
    $state.Begin = $begin; $state.Refresh = $refresh
    $addMenu = New-Object Windows.Controls.ContextMenu
    foreach ($entry in @(@('add_chatgpt','ChatGPT 账号'),@('add_api','Responses API'))) {
        $item = New-Object Windows.Controls.MenuItem; $item.Header = $entry[1]; $action = $entry[0]
        $item.Add_Click(({ & $onManage $action $null }.GetNewClosure())); $addMenu.Items.Add($item) | Out-Null
    }
    $controls.AddButton.ContextMenu = $addMenu
    $controls.AddButton.Add_Click(({ $addMenu.PlacementTarget = $controls.AddButton; $addMenu.IsOpen = $true }.GetNewClosure()))
    $controls.RepairButton.Add_Click(({ & $begin 'Repair' '' $null }.GetNewClosure()))
    $controls.RetryButton.Add_Click(({ & $begin $state.LastOperation.Action $state.LastOperation.ProfileId $null }.GetNewClosure()))
    $controls.CopyErrorButton.Add_Click(({ try { [Windows.Clipboard]::SetText($controls.ErrorText.Text) } catch { $controls.StatusText.Text = '复制失败，请在错误详情中选中文字复制。' } }.GetNewClosure()))
    $controls.CancelLoginButton.Add_Click(({
        if ($state.CancelPath) {
            try { [IO.File]::WriteAllText($state.CancelPath, 'cancel'); $controls.CancelLoginButton.IsEnabled = $false; $controls.StatusText.Text = '正在取消登录并清理临时数据…' }
            catch { $controls.StatusText.Text = '无法提交取消请求。请在浏览器结束登录并等待后台返回。' }
        }
    }.GetNewClosure()))
    $controls.CancelButton.Add_Click(({ $Window.Close() }.GetNewClosure()))
    $Window.Add_Closing(({ param($sender,$eventArgs) if ($state.Busy) { $eventArgs.Cancel = $true } }.GetNewClosure()))
    $Window.Add_Closed(({ $timer.Stop() }.GetNewClosure()))
    $timer.Add_Tick(({
        if ($null -eq $state.Job -or -not $state.Job.Process.HasExited) { return }
        $state.Timer.Stop(); $job = $state.Job; $state.Job = $null; $completedAction = $state.Action
        $refreshNeeded = $false
        try {
            if (-not (Test-Path -LiteralPath $job.OutputPath)) { throw 'Missing result.' }
            $result = [IO.File]::ReadAllText($job.OutputPath) | ConvertFrom-Json
            & $setBusy $false
            if ($job.Process.ExitCode -ne 0 -or -not $result.success) { & $showError ([string]$result.message) }
            elseif ($completedAction -eq 'Switch') { $Window.Close() }
            elseif ($completedAction -eq 'List') {
                & $refresh $result.data
                # Name the drifted state explicitly; otherwise the marked card
                # looks like an unexplained failure and the window appears stuck.
                $drifted = $null
                if ($null -ne $result.data.PSObject.Properties['activeIdentityMismatch'] -and $result.data.activeIdentityMismatch) {
                    $drifted = @($result.data.profiles | Where-Object { $_.id -eq $result.data.activeProfileId } | Select-Object -First 1)
                }
                $driftName = if ($drifted -and $drifted.Count -gt 0) { [string]$drifted[0].displayName } else { '' }
                $controls.StatusText.Text = if ($result.data.registrySchema -eq 1) { '首次使用请先登录 Codex，再退出相关程序并点击“重置 / 修复”，导入当前账号；旧版安装会自动迁移。' }
                    elseif ($null -ne $drifted) { '当前登录的 ChatGPT 账号与“' + $driftName + '”记录不一致。直接选择该账号即可校正状态，“重置 / 修复”也会处理。' }
                    elseif ($state.CompletionMessage) { $state.CompletionMessage }
                    else { '请选择配置档启动应用。' }
                $controls.StatusText.Foreground = if ($state.CompletionMessage -and $null -eq $drifted) { [Windows.Media.Brushes]::SeaGreen }
                    elseif ($null -ne $drifted) { [Windows.Media.Brushes]::DarkOrange }
                    else { [Windows.Media.Brushes]::SlateGray }
                $state.CompletionMessage = ''
            }
            else { $state.CompletionMessage = [string]$result.message; $refreshNeeded = $true }
        } catch { & $showError '未能读取操作结果。请重试或执行“重置 / 修复”。' }
        finally {
            Remove-Item -LiteralPath $job.OutputPath -Force -ErrorAction SilentlyContinue; $job.Process.Dispose()
            if ($state.CancelPath) { Remove-Item -LiteralPath $state.CancelPath -Force -ErrorAction SilentlyContinue; $state.CancelPath = $null }
        }
        if ($refreshNeeded) { & $begin 'List' '' $null }
    }.GetNewClosure()))
    if ($LoadProfiles) { & $begin 'List' '' $null }
    return $state
}
function Export-PickerPreview {
    param($Window, [string]$Path)
    $content = New-Object Windows.Controls.Border; $content.Background = $Window.Background
    $grid = $Window.Content; $Window.Content = $null; $content.Child = $grid; $Window.Content = $content
    $Window.WindowStartupLocation = 'Manual'; $Window.Left = -20000; $Window.Top = -20000
    $Window.ShowInTaskbar = $false; $Window.ShowActivated = $false; $Window.Show()
    $width = 640; $height = 650
    $content.Measure((New-Object Windows.Size($width,$height))); $content.Arrange((New-Object Windows.Rect(0,0,$width,$height))); $content.UpdateLayout()
    $null = $Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ContextIdle)
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($width,$height,96,96,([Windows.Media.PixelFormats]::Pbgra32)); $bitmap.Render($content)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder; $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose(); $Window.Close() }
}
if ($LoadOnly) { return }
if ($PreviewPath) { $picker = New-AccountPicker; Export-PickerPreview -Window $picker -Path $PreviewPath; return }
$empty = [pscustomobject]@{ registrySchema = 2; activeProfileId = ''; profiles = @() }
$picker = New-AccountPicker -Status $empty
$null = Connect-AccountPicker -Window $picker -SwitcherPath (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadProfiles
$null = $picker.ShowDialog()
