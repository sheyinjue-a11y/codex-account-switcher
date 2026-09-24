[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $PSScriptRoot 'AstraWarmup.ps1')

$homePath=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
$vaultPath=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexAccountSwitcher'
$hookScriptPath=Join-Path $PSScriptRoot 'Invoke-AstraWarmup.ps1'
$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Astra warmup" Width="530" Height="390" MinWidth="480" MinHeight="360" WindowStartupLocation="CenterScreen" ResizeMode="CanResize">
  <Grid Margin="24">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="First-message Astra warmup" FontSize="22" FontWeight="SemiBold" Margin="0,0,0,12"/>
    <TextBlock Grid.Row="1" Name="CurrentStatus" TextWrapping="Wrap" Margin="0,0,0,16"/>
    <TextBlock Grid.Row="2" TextWrapping="Wrap" Margin="0,0,0,14">When enabled for this API key and endpoint, the first gpt-6-astra message in each session waits for one gpt-5.6-sol request. The request sends only “Reply only OK.” and may incur API charges. A failed warmup blocks the original message.</TextBlock>
    <CheckBox Grid.Row="3" Name="CostConsent" Content="I understand the extra API request may incur charges." Margin="0,0,0,16"/>
    <TextBlock Grid.Row="4" TextWrapping="Wrap" Foreground="#444444">Codex will ask you to review and trust this user-level hook. This tool cannot approve trust for you. Close and restart Codex after a change. To stop warmup for the current API account, choose Disable. Other API accounts keep their own settings.</TextBlock>
    <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button Name="EnableButton" Content="Enable for current API account" Padding="13,7" Margin="0,0,8,0"/>
      <Button Name="DisableButton" Content="Disable" Padding="13,7" Margin="0,0,8,0"/>
      <Button Name="CloseButton" Content="Close" Padding="13,7"/>
    </StackPanel>
  </Grid>
</Window>
'@
$reader=[Xml.XmlNodeReader]::new([xml]$xaml)
$window=[Windows.Markup.XamlReader]::Load($reader)
$status=$window.FindName('CurrentStatus')
$consent=$window.FindName('CostConsent')
$enable=$window.FindName('EnableButton')
$disable=$window.FindName('DisableButton')
$close=$window.FindName('CloseButton')

function Update-AstraStatus {
    try {
        if (Get-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath) {
            $status.Text='Status: enabled for the current API account.'
        } else { $status.Text='Status: disabled for the current API account.' }
    } catch {
        $status.Text='Status: unavailable. Select a file-based API login in Codex Account Switcher first.'
    }
}
$enable.Add_Click({
    if ($consent.IsChecked -ne $true) {
        [Windows.MessageBox]::Show('Check the cost confirmation before enabling warmup.','Astra warmup') | Out-Null
        return
    }
    try {
        Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $hookScriptPath -Enabled $true -ConfirmCost $true
        Update-AstraStatus
        [Windows.MessageBox]::Show('Enabled. Restart Codex, then review and trust the hook when Codex asks. No warmup request was sent by this window.','Astra warmup') | Out-Null
    } catch {
        [Windows.MessageBox]::Show('Warmup could not be enabled. Check the current file API login, endpoint and hook configuration. No API request was sent.','Astra warmup') | Out-Null
    }
})
$disable.Add_Click({
    try {
        Set-AstraWarmupEnabled -HomePath $homePath -VaultPath $vaultPath -HookScriptPath $hookScriptPath -Enabled $false -ConfirmCost $false
        Update-AstraStatus
        [Windows.MessageBox]::Show('Disabled for the current API account. Restart Codex to apply the hook change.','Astra warmup') | Out-Null
    } catch {
        [Windows.MessageBox]::Show('Warmup could not be disabled. Check the current file API login and hook configuration.','Astra warmup') | Out-Null
    }
})
$close.Add_Click({ $window.Close() })
Update-AstraStatus
$null=$window.ShowDialog()
