[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Launcher,
    [Parameter(Mandatory = $true)][string]$FakeSwitcher
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Launcher -LoadOnly
$picker = New-AccountPicker
$state = Connect-AccountPicker -Window $picker -SwitcherPath $FakeSwitcher
$picker.FindName('PersonalButton').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
$deadline = [DateTime]::UtcNow.AddSeconds(3)
while ($state.Busy -and [DateTime]::UtcNow -lt $deadline) {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $stop = New-Object Windows.Threading.DispatcherTimer
    $stop.Interval = [TimeSpan]::FromMilliseconds(30)
    $stop.Add_Tick(({ $frame.Continue = $false }.GetNewClosure()))
    $stop.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
    $stop.Stop()
}
if ($state.Busy) { [Console]::Error.WriteLine('Picker stayed busy after switcher exited.'); exit 3 }
exit 0
