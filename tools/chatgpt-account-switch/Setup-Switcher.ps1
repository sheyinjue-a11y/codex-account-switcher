[CmdletBinding()]
param([switch]$NoShortcut)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try {
    if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run Setup.cmd with Windows PowerShell 5.1.' }
    if (-not (Get-Command codex.exe -ErrorAction SilentlyContinue)) {
        throw 'Codex CLI (codex.exe) is not on PATH. Install the official Windows CLI, reopen the terminal and retry. See README.md.'
    }
    . (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -LoadOnly
    $settings=Get-SwitcherSettings
    if ($env:CODEX_HOME -and (Get-NormalizedPath $env:CODEX_HOME) -ine $settings.CanonicalHome) {
        throw 'Custom CODEX_HOME is not supported by this installer. It manages only the current user .codex home. No files were changed.'
    }
    $null=Get-ChatGPTExecutable
    Write-Host 'Close Codex desktop, CLI and editor integrations before setup.'
    & (Join-Path $PSScriptRoot 'Switch-ChatGPTAccount.ps1') -Initialize | Out-Null
    if (-not $NoShortcut) {
        $desktop=[Environment]::GetFolderPath('DesktopDirectory')
        $linkPath=Join-Path $desktop 'Codex Account Switcher.lnk'
        if (Test-Path -LiteralPath $linkPath) {
            Write-Host 'Existing desktop shortcut preserved. Use Start.cmd if you moved the folder.'
        } else {
            $shell=New-Object -ComObject WScript.Shell
            $link=$shell.CreateShortcut($linkPath)
            $link.TargetPath=Join-Path ([Environment]::GetFolderPath('System')) 'wscript.exe'
            $link.Arguments='"'+(Join-Path $PSScriptRoot 'Start-ChatGPT.vbs')+'"'
            $link.WorkingDirectory=$PSScriptRoot
            $link.Description='Codex Account Switcher - local multi-profile launcher'
            $link.Save()
        }
    }
    Write-Host 'Setup complete. Open Start.cmd or the desktop shortcut to add and switch profiles.'
} catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
