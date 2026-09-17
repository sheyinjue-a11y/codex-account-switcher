Set-StrictMode -Version Latest

if ($null -eq (Get-Command -Name Write-AtomicText -CommandType Function -ErrorAction SilentlyContinue)) {
    function Write-AtomicText {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Text
        )

        $directory = Split-Path -Parent $Path
        if ([string]::IsNullOrWhiteSpace($directory)) {
            throw 'Atomic write requires a parent directory.'
        }
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }

        $leaf = Split-Path -Leaf $Path
        $temporary = Join-Path $directory ('.' + $leaf + '.tmp-' + [guid]::NewGuid().ToString('N'))
        $replaceBackup = Join-Path $directory ('.' + $leaf + '.replace-' + [guid]::NewGuid().ToString('N'))
        $encoding = New-Object Text.UTF8Encoding($false)
        $bytes = $encoding.GetBytes($Text)
        try {
            $stream = New-Object IO.FileStream(
                $temporary,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None,
                4096,
                [IO.FileOptions]::WriteThrough
            )
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
            } finally {
                $stream.Dispose()
            }

            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                [IO.File]::Replace($temporary, $Path, $replaceBackup, $true)
                Remove-Item -LiteralPath $replaceBackup -Force
            } else {
                [IO.File]::Move($temporary, $Path)
            }
        } finally {
            [Array]::Clear($bytes, 0, $bytes.Length)
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $replaceBackup) {
                Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-ProfileRegistryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    if ($null -eq $Settings.PSObject.Properties['VaultRoot'] -or
        [string]::IsNullOrWhiteSpace([string]$Settings.VaultRoot)) {
        throw 'Settings must define VaultRoot.'
    }
    return Join-Path $Settings.VaultRoot 'profiles.json'
}

function Assert-ProfileId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProfileId)

    if ($ProfileId -cnotmatch '^(?:personal|lab|[a-f0-9]{32})$') {
        throw 'Invalid profile ID.'
    }
}

function Normalize-ProfileDisplayName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$DisplayName)

    $value = $DisplayName.Trim()
    if ($value.Length -lt 1 -or $value.Length -gt 40) {
        throw 'Profile name must contain 1-40 characters.'
    }
    if ($value -match '[\x00-\x1f\x7f]') { throw 'Profile name must not contain control characters.' }
    return $value
}

function New-ProfileRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][ValidateSet('chatgpt', 'responses_api')][string]$Kind,
        [Parameter(Mandatory = $true)][int]$SortOrder
    )

    if ($SortOrder -lt 0) { throw 'Profile sort order must be non-negative.' }
    return [pscustomobject][ordered]@{
        id = [guid]::NewGuid().ToString('N')
        displayName = Normalize-ProfileDisplayName -DisplayName $DisplayName
        kind = $Kind
        sortOrder = $SortOrder
        createdAt = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
}

function New-FixedProfileRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('personal', 'lab')][string]$Id,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][ValidateSet('chatgpt', 'responses_api')][string]$Kind,
        [Parameter(Mandatory = $true)][int]$SortOrder
    )

    Assert-ProfileId -ProfileId $Id
    if ($SortOrder -lt 0) { throw 'Profile sort order must be non-negative.' }
    return [pscustomobject][ordered]@{
        id = $Id
        displayName = Normalize-ProfileDisplayName -DisplayName $DisplayName
        kind = $Kind
        sortOrder = $SortOrder
        createdAt = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
}

function New-ProfileRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CanonicalHome)

    if ([string]::IsNullOrWhiteSpace($CanonicalHome)) {
        throw 'Canonical home is required.'
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        profiles = @()
    }
}

function Assert-ProfileRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Registry)

    if ($null -eq $Registry.PSObject.Properties['schemaVersion'] -or
        $Registry.schemaVersion -isnot [int] -or
        $Registry.schemaVersion -ne 2) {
        throw 'Unsupported profile registry schema.'
    }
    if ($null -eq $Registry.PSObject.Properties['profiles'] -or $null -eq $Registry.profiles) {
        throw 'Profile registry must contain a profiles array.'
    }
    if ($Registry.profiles -isnot [array]) {
        throw 'Profile registry profiles value must be an array.'
    }

    $seenIds = @{}
    $seenNames = @{}
    $seenSortOrders = @{}
    foreach ($profile in @($Registry.profiles)) {
        if ($null -eq $profile) { throw 'Profile registry contains an empty profile.' }
        foreach ($propertyName in @('id', 'displayName', 'kind', 'sortOrder', 'createdAt')) {
            if ($null -eq $profile.PSObject.Properties[$propertyName]) {
                throw "Profile is missing '$propertyName'."
            }
        }

        $profileId = [string]$profile.id
        Assert-ProfileId -ProfileId $profileId
        if ($seenIds.ContainsKey($profileId)) { throw 'Profile IDs must be unique.' }
        $seenIds[$profileId] = $true

        if ($profile.displayName -isnot [string]) {
            throw 'Profile display name must be a string.'
        }
        $displayName = Normalize-ProfileDisplayName -DisplayName $profile.displayName
        if ($displayName -cne $profile.displayName) {
            throw 'Stored profile names must already be normalized.'
        }
        if ($seenNames.ContainsKey($displayName)) { throw 'Profile names must be unique without case sensitivity.' }
        $seenNames[$displayName] = $true

        if ([string]$profile.kind -notin @('chatgpt', 'responses_api')) {
            throw 'Invalid profile kind.'
        }

        $sortOrderValue = $profile.sortOrder
        $sortOrderType = [Type]::GetTypeCode($sortOrderValue.GetType()).ToString()
        if ($sortOrderType -notin @('Byte', 'SByte', 'Int16', 'UInt16', 'Int32', 'UInt32', 'Int64', 'UInt64')) {
            throw 'Profile sort order must be an integer.'
        }
        if ([decimal]$sortOrderValue -lt 0 -or [decimal]$sortOrderValue -gt [int]::MaxValue) {
            throw 'Profile sort order must be non-negative.'
        }
        $sortOrder = [int]$sortOrderValue
        if ($seenSortOrders.ContainsKey($sortOrder)) { throw 'Profile sort orders must be unique.' }
        $seenSortOrders[$sortOrder] = $true

        $createdAtText = [string]$profile.createdAt
        if ($createdAtText -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|\+00:00)$') {
            throw 'Profile creation time must be a UTC ISO timestamp.'
        }
        try {
            $createdAt = [DateTimeOffset]::Parse(
                $createdAtText,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            )
        } catch {
            throw 'Profile creation time must be a UTC ISO timestamp.'
        }
        if ($createdAt.Offset -ne [TimeSpan]::Zero) {
            throw 'Profile creation time must be UTC.'
        }
    }
}

function Copy-ProfileRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Registry)

    Assert-ProfileRegistry -Registry $Registry
    $profiles = @()
    foreach ($profile in @($Registry.profiles)) {
        $profiles += ,[pscustomobject][ordered]@{
            id = [string]$profile.id
            displayName = [string]$profile.displayName
            kind = [string]$profile.kind
            sortOrder = [int]$profile.sortOrder
            createdAt = [string]$profile.createdAt
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        profiles = @($profiles)
    }
}

function Get-ProfileById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Registry,
        [Parameter(Mandatory = $true)][string]$ProfileId
    )

    Assert-ProfileRegistry -Registry $Registry
    Assert-ProfileId -ProfileId $ProfileId
    $matches = @($Registry.profiles | Where-Object { [string]$_.id -ceq $ProfileId })
    if ($matches.Count -ne 1) { throw "Profile '$ProfileId' was not found." }
    return [pscustomobject][ordered]@{
        id = [string]$matches[0].id
        displayName = [string]$matches[0].displayName
        kind = [string]$matches[0].kind
        sortOrder = [int]$matches[0].sortOrder
        createdAt = [string]$matches[0].createdAt
    }
}

function Read-ProfileRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][pscustomobject]$Settings)

    $path = Get-ProfileRegistryPath -Settings $Settings
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Profile registry does not exist.'
    }
    $text = [IO.File]::ReadAllText($path)
    try {
        $registry = $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'Profile registry contains invalid JSON.'
    }
    Assert-ProfileRegistry -Registry $registry
    return Copy-ProfileRegistry -Registry $registry
}

function Write-ProfileRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Settings,
        [Parameter(Mandatory = $true)][psobject]$Registry
    )

    $validated = Copy-ProfileRegistry -Registry $Registry
    $text = ($validated | ConvertTo-Json -Depth 6) + [Environment]::NewLine
    Write-AtomicText -Path (Get-ProfileRegistryPath -Settings $Settings) -Text $text
}

function Add-ProfileRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Registry,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][ValidateSet('chatgpt', 'responses_api')][string]$Kind
    )

    Assert-ProfileRegistry -Registry $Registry
    $normalizedName = Normalize-ProfileDisplayName -DisplayName $DisplayName
    foreach ($profile in @($Registry.profiles)) {
        if ([string]::Equals([string]$profile.displayName, $normalizedName, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Profile names must be unique without case sensitivity.'
        }
    }

    $sortOrder = 0
    if (@($Registry.profiles).Count -gt 0) {
        $sortOrder = [int](($Registry.profiles | Measure-Object -Property sortOrder -Maximum).Maximum) + 1
    }
    $record = New-ProfileRecord -DisplayName $normalizedName -Kind $Kind -SortOrder $sortOrder
    $copy = Copy-ProfileRegistry -Registry $Registry
    $copy.profiles = @($copy.profiles) + @($record)
    Assert-ProfileRegistry -Registry $copy
    return $copy
}

function Rename-ProfileRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Registry,
        [Parameter(Mandatory = $true)][string]$ProfileId,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    Assert-ProfileRegistry -Registry $Registry
    Assert-ProfileId -ProfileId $ProfileId
    $normalizedName = Normalize-ProfileDisplayName -DisplayName $DisplayName
    $null = Get-ProfileById -Registry $Registry -ProfileId $ProfileId
    foreach ($profile in @($Registry.profiles)) {
        if ([string]$profile.id -cne $ProfileId -and
            [string]::Equals([string]$profile.displayName, $normalizedName, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Profile names must be unique without case sensitivity.'
        }
    }

    $copy = Copy-ProfileRegistry -Registry $Registry
    foreach ($profile in @($copy.profiles)) {
        if ([string]$profile.id -ceq $ProfileId) {
            $profile.displayName = $normalizedName
            break
        }
    }
    Assert-ProfileRegistry -Registry $copy
    return $copy
}

function Remove-ProfileRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Registry,
        [Parameter(Mandatory = $true)][string]$ProfileId,
        [Parameter(Mandatory = $true)][string]$ActiveProfileId
    )

    Assert-ProfileRegistry -Registry $Registry
    Assert-ProfileId -ProfileId $ProfileId
    Assert-ProfileId -ProfileId $ActiveProfileId
    $null = Get-ProfileById -Registry $Registry -ProfileId $ProfileId
    if ($ProfileId -ceq $ActiveProfileId) { throw 'The active profile cannot be removed.' }
    if (@($Registry.profiles).Count -le 1) { throw 'The last valid profile cannot be removed.' }

    $copy = Copy-ProfileRegistry -Registry $Registry
    $remaining = @($copy.profiles | Where-Object { [string]$_.id -cne $ProfileId } | Sort-Object -Property sortOrder)
    for ($index = 0; $index -lt $remaining.Count; $index++) {
        $remaining[$index].sortOrder = $index
    }
    $copy.profiles = @($remaining)
    Assert-ProfileRegistry -Registry $copy
    return $copy
}
