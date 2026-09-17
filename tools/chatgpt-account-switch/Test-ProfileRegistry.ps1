[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testPrefix = 'profile-registry-test-'
$testRoot = Join-Path $testParent ($testPrefix + [guid]::NewGuid().ToString('N'))

function Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

function Check-Throws {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    Check $rejected $Message
}

function New-TestRegistry {
    param([object[]]$Profiles)
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        profiles = @($Profiles)
    }
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    . (Join-Path $PSScriptRoot 'ProfileRegistry.ps1')

    $canonicalHome = Join-Path $testRoot '.codex'
    $settings = [pscustomobject]@{ VaultRoot = Join-Path $testRoot 'vault' }
    Check ((Get-ProfileRegistryPath -Settings $settings) -eq (Join-Path $settings.VaultRoot 'profiles.json')) 'Registry path is rooted in the vault.'

    $registry = New-ProfileRegistry -CanonicalHome $canonicalHome
    Check ($registry.schemaVersion -eq 2) 'Registry uses schema 2.'
    Check (@($registry.profiles).Count -eq 0) 'New registry starts empty.'

    $personal = New-FixedProfileRecord -Id personal -DisplayName 'Personal' -Kind chatgpt -SortOrder 0
    $lab = New-FixedProfileRecord -Id lab -DisplayName 'Lab' -Kind responses_api -SortOrder 1
    Check ($personal.id -eq 'personal' -and $personal.kind -eq 'chatgpt') 'Fixed Personal profile can be constructed.'
    Check ($lab.id -eq 'lab' -and $lab.kind -eq 'responses_api') 'Fixed Lab profile can be constructed.'

    $registry = Add-ProfileRecord -Registry $registry -DisplayName '  Contest Account 2  ' -Kind chatgpt
    $added = @($registry.profiles)[0]
    Check ($added.displayName -eq 'Contest Account 2') 'Display name is trimmed.'
    Check ($added.id -match '^[a-f0-9]{32}$') 'Generated profile ID is path-safe.'
    Check ($added.sortOrder -eq 0) 'First dynamic profile receives sort order zero.'

    $caseRegistry = Add-ProfileRecord -Registry (New-ProfileRegistry -CanonicalHome $canonicalHome) -DisplayName 'Team Alpha' -Kind chatgpt
    Check-Throws { $null = Add-ProfileRecord -Registry $caseRegistry -DisplayName 'team alpha' -Kind responses_api } 'Names are unique without case sensitivity.'
    Check (@($caseRegistry.profiles).Count -eq 1) 'Rejected add leaves input registry unchanged.'

    Check-Throws { Assert-ProfileId -ProfileId 'Personal' } 'Profile IDs reject unsupported casing.'
    Check-Throws { $null = New-FixedProfileRecord -Id '..\escape' -DisplayName 'Bad' -Kind chatgpt -SortOrder 0 } 'Fixed profiles reject unsafe IDs.'
    Check-Throws { $null = Normalize-ProfileDisplayName -DisplayName '   ' } 'Blank profile names are rejected.'
    Check-Throws { $null = Normalize-ProfileDisplayName -DisplayName ('x' * 41) } 'Profile names longer than 40 characters are rejected.'
    Check-Throws { $null = Normalize-ProfileDisplayName -DisplayName "Name`nInjected" } 'Control characters in profile names are rejected.'

    $fixedRegistry = New-TestRegistry -Profiles @($personal, $lab)
    $selected = Get-ProfileById -Registry $fixedRegistry -ProfileId lab
    Check ($selected.displayName -eq 'Lab') 'Profiles can be retrieved by ID.'
    $selected.displayName = 'Changed outside the registry'
    Check (@($fixedRegistry.profiles)[1].displayName -eq 'Lab') 'Retrieved profiles cannot mutate the source registry.'
    Check-Throws { $null = Get-ProfileById -Registry $fixedRegistry -ProfileId ('f' * 32) } 'Missing profile IDs are rejected.'

    $renamed = Rename-ProfileRecord -Registry $fixedRegistry -ProfileId lab -DisplayName '  Lab API  '
    Check ((Get-ProfileById -Registry $renamed -ProfileId lab).displayName -eq 'Lab API') 'Rename trims the new display name.'
    Check ((Get-ProfileById -Registry $fixedRegistry -ProfileId lab).displayName -eq 'Lab') 'Rename does not mutate its input registry.'
    Check-Throws { $null = Rename-ProfileRecord -Registry $fixedRegistry -ProfileId lab -DisplayName 'personal' } 'Rename rejects a case-insensitive name conflict.'

    Check-Throws { $null = Remove-ProfileRecord -Registry $fixedRegistry -ProfileId personal -ActiveProfileId personal } 'Current profile cannot be removed.'
    Check (@($fixedRegistry.profiles).Count -eq 2) 'Rejected removal leaves input registry unchanged.'
    $singleRegistry = New-TestRegistry -Profiles @($personal)
    Check-Throws { $null = Remove-ProfileRecord -Registry $singleRegistry -ProfileId personal -ActiveProfileId lab } 'Last valid profile cannot be removed.'
    $afterRemoval = Remove-ProfileRecord -Registry $fixedRegistry -ProfileId personal -ActiveProfileId lab
    Check (@($afterRemoval.profiles).Count -eq 1 -and @($afterRemoval.profiles)[0].sortOrder -eq 0) 'Removal compacts sort order.'
    Check (@($fixedRegistry.profiles).Count -eq 2 -and @($fixedRegistry.profiles)[1].sortOrder -eq 1) 'Successful removal does not mutate its input registry.'

    Write-ProfileRegistry -Settings $settings -Registry $fixedRegistry
    $registryPath = Get-ProfileRegistryPath -Settings $settings
    Check (Test-Path -LiteralPath $registryPath -PathType Leaf) 'Registry is written to profiles.json.'
    $readBack = Read-ProfileRegistry -Settings $settings
    Check (@($readBack.profiles).Count -eq 2) 'Written registry can be read back.'
    $updatedRegistry = Rename-ProfileRecord -Registry $fixedRegistry -ProfileId lab -DisplayName 'Lab API'
    Write-ProfileRegistry -Settings $settings -Registry $updatedRegistry
    $readUpdated = Read-ProfileRegistry -Settings $settings
    Check ((Get-ProfileById -Registry $readUpdated -ProfileId lab).displayName -eq 'Lab API') 'Atomic replacement publishes the complete updated registry.'
    $temporaryFiles = @(Get-ChildItem -LiteralPath $settings.VaultRoot -Force | Where-Object { $_.Name -like '.profiles.json.tmp-*' -or $_.Name -like '.profiles.json.replace-*' })
    Check ($temporaryFiles.Count -eq 0) 'Atomic write leaves no temporary files.'

    $readError = $null
    $readLock = New-Object IO.FileStream($registryPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        try { $null = Read-ProfileRegistry -Settings $settings } catch { $readError = $_.Exception.Message }
    } finally {
        $readLock.Dispose()
    }
    Check ($null -ne $readError) 'Exclusive file access causes registry read to fail.'
    Check (-not $readError.Contains('invalid JSON')) 'Registry I/O errors are not misreported as invalid JSON.'

    $beforeLockedWriteBytes = [IO.File]::ReadAllBytes($registryPath)
    $beforeLockedWriteText = [IO.File]::ReadAllText($registryPath)
    $lockedWriteRegistry = Rename-ProfileRecord -Registry $updatedRegistry -ProfileId personal -DisplayName 'Personal Locked Update'
    $lockedWriteError = $null
    $writeLock = New-Object IO.FileStream($registryPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        try { Write-ProfileRegistry -Settings $settings -Registry $lockedWriteRegistry } catch { $lockedWriteError = $_.Exception.Message }
    } finally {
        $writeLock.Dispose()
    }
    Check ($null -ne $lockedWriteError) 'Exclusive target lock makes atomic replacement fail.'
    $afterLockedWriteBytes = [IO.File]::ReadAllBytes($registryPath)
    Check ([Convert]::ToBase64String($afterLockedWriteBytes) -ceq [Convert]::ToBase64String($beforeLockedWriteBytes)) 'Failed atomic replacement preserves every target byte.'
    Check ([IO.File]::ReadAllText($registryPath) -ceq $beforeLockedWriteText) 'Failed atomic replacement preserves target text.'
    $failedWriteArtifacts = @(Get-ChildItem -LiteralPath $settings.VaultRoot -Force | Where-Object { $_.Name -like '.profiles.json.tmp-*' -or $_.Name -like '.profiles.json.replace-*' })
    Check ($failedWriteArtifacts.Count -eq 0) 'Failed atomic replacement leaves no temporary or backup files.'

    $beforeInvalidWrite = [IO.File]::ReadAllText($registryPath)
    $invalidForWrite = New-TestRegistry -Profiles @(
        (New-FixedProfileRecord -Id personal -DisplayName 'One' -Kind chatgpt -SortOrder 0),
        (New-FixedProfileRecord -Id lab -DisplayName 'Two' -Kind responses_api -SortOrder 0)
    )
    Check-Throws { Write-ProfileRegistry -Settings $settings -Registry $invalidForWrite } 'Write rejects duplicate sort orders before touching disk.'
    Check ([IO.File]::ReadAllText($registryPath) -eq $beforeInvalidWrite) 'Failed validation preserves the existing registry file.'

    $utf8 = New-Object Text.UTF8Encoding($false)
    $invalidJsonCases = @(
        [pscustomobject]@{ Name = 'unknown schema'; Text = '{"schemaVersion":99,"profiles":[]}' },
        [pscustomobject]@{ Name = 'a string schema'; Text = '{"schemaVersion":"2","profiles":[]}' },
        [pscustomobject]@{ Name = 'damaged JSON'; Text = '{"schemaVersion":2,"profiles":[' }
    )
    foreach ($case in $invalidJsonCases) {
        [IO.File]::WriteAllText($registryPath, $case.Text, $utf8)
        Check-Throws { $null = Read-ProfileRegistry -Settings $settings } ("Read rejects " + $case.Name + '.')
        Check ([IO.File]::ReadAllText($registryPath) -eq $case.Text) ("Rejected " + $case.Name + ' is not overwritten.')
    }

    $invalidRegistries = @(
        [pscustomobject]@{
            Name = 'a scalar profiles value'
            Value = [pscustomobject][ordered]@{ schemaVersion = 2; profiles = $personal }
        },
        [pscustomobject]@{
            Name = 'duplicate IDs'
            Value = New-TestRegistry -Profiles @($personal, (New-FixedProfileRecord -Id personal -DisplayName 'Other' -Kind chatgpt -SortOrder 1))
        },
        [pscustomobject]@{
            Name = 'case-insensitive duplicate names'
            Value = New-TestRegistry -Profiles @($personal, (New-FixedProfileRecord -Id lab -DisplayName 'PERSONAL' -Kind responses_api -SortOrder 1))
        },
        [pscustomobject]@{
            Name = 'illegal kind'
            Value = New-TestRegistry -Profiles @([pscustomobject][ordered]@{ id = 'personal'; displayName = 'One'; kind = 'legacy'; sortOrder = 0; createdAt = '2026-09-09T00:00:00Z' })
        },
        [pscustomobject]@{
            Name = 'a numeric display name'
            Value = New-TestRegistry -Profiles @([pscustomobject][ordered]@{ id = 'personal'; displayName = 123; kind = 'chatgpt'; sortOrder = 0; createdAt = '2026-09-09T00:00:00Z' })
        },
        [pscustomobject]@{
            Name = 'a Boolean display name'
            Value = New-TestRegistry -Profiles @([pscustomobject][ordered]@{ id = 'personal'; displayName = $true; kind = 'chatgpt'; sortOrder = 0; createdAt = '2026-09-09T00:00:00Z' })
        },
        [pscustomobject]@{
            Name = 'negative sort order'
            Value = New-TestRegistry -Profiles @([pscustomobject][ordered]@{ id = 'personal'; displayName = 'One'; kind = 'chatgpt'; sortOrder = -1; createdAt = '2026-09-09T00:00:00Z' })
        }
    )
    foreach ($invalid in $invalidRegistries) {
        [IO.File]::WriteAllText($registryPath, (($invalid.Value | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8)
        Check-Throws { $null = Read-ProfileRegistry -Settings $settings } ('Read rejects ' + $invalid.Name + '.')
    }

    Write-Host 'Profile registry tests passed.' -ForegroundColor Green
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    $allowedPrefix = $testParent + '\' + $testPrefix
    if (-not $resolvedTestRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside the isolated profile registry test directory.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
