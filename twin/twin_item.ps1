# SPDX-License-Identifier: GPL-3.0-only
#
# twin_item.ps1 - per-item evidence folders for the twin workflow (Windows).
#
# Every frame, log and run report goes through this helper so the timestamps and
# the layout stay consistent with WORKFLOW.md section 5.
#
# Usage:
#   .\twin_item.ps1 dir ITEM
#   .\twin_item.ps1 stamp
#   .\twin_item.ps1 capture LEG ITEM LABEL -- CMD...
#   .\twin_item.ps1 note ITEM LABEL [TEXT]
#   .\twin_item.ps1 log ITEM LABEL [CMD...]
#
# Environment:
#   TWIN_ROOT            repository root (default: the nearest ancestor of the
#                        working directory, then of this folder, that holds
#                        TWIN-VERIFICATION.json; otherwise the git top level)
#   TWIN_RUNS            evidence root (default: <root>\runs)
#   TWIN_REFERENCE_LEG   reference leg folder name (default: reference)
#   TWIN_PORT_LEG        port leg folder name (default: port)
#   TWIN_SINGLE          set to 1 to record one leg only (no reference folder)
#
# The leg names must match the registry's "legs" object and
# TWIN_COUNTERPART.md. A registry with "mode": "single" (or a "legs" object
# without a reference role) is recorded as a single-leg walk automatically:
# only the port folder is created and `capture reference` is rejected.

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    [Console]::Error.WriteLine("twin_item: $Message")
    exit 2
}

function Get-Usage {
    # Print the comment block above, so --help and the file never disagree.
    $output = New-Object System.Collections.Generic.List[string]
    $show = $false
    foreach ($line in (Get-Content -LiteralPath $PSCommandPath)) {
        if ($line -match '^# Usage:') { $show = $true }
        if ($show -and $line -notmatch '^#') { break }
        if ($show) { $output.Add(($line -replace '^# ?', '')) }
    }
    return ($output -join [Environment]::NewLine)
}

$Command = ''
$Rest = @()
if ($args.Count -ge 1) { $Command = [string]$args[0] }
if ($args.Count -gt 1) { $Rest = @($args[1..($args.Count - 1)]) }

function Get-GitTop([string]$Path) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
    $top = & git -C $Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { return ([string]$top).Trim() }
    return ''
}

function Find-RootWithRegistry([string]$Start) {
    $dir = $Start
    while ($dir) {
        if (Test-Path (Join-Path $dir 'TWIN-VERIFICATION.json')) { return $dir }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return ''
}

function Get-RepoRoot {
    if ($env:TWIN_ROOT) { return [System.IO.Path]::GetFullPath($env:TWIN_ROOT) }
    $candidates = @((Get-Location).Path, $PSScriptRoot)
    foreach ($start in $candidates) {
        $found = Find-RootWithRegistry $start
        if ($found) { return $found }
    }
    foreach ($start in $candidates) {
        $top = Get-GitTop $start
        if ($top) { return $top }
    }
    return (Get-Location).Path
}

function Read-Registry {
    $registry = Join-Path $Root 'TWIN-VERIFICATION.json'
    if (-not (Test-Path -LiteralPath $registry)) { return $null }
    try {
        return (Get-Content -Raw -LiteralPath $registry | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-SingleRegistry([object]$Doc) {
    if ($null -eq $Doc) { return $false }
    if ($Doc.mode -in @('single', 'feature-walk', 'single-leg')) { return $true }
    $legs = $Doc.legs
    if ($null -ne $legs -and $legs -is [System.Management.Automation.PSCustomObject]) {
        $hasPort = $null -ne $legs.PSObject.Properties['port']
        $hasReference = $null -ne $legs.PSObject.Properties['reference']
        if ($hasPort -and -not $hasReference) { return $true }
    }
    return $false
}

function Get-RegistryLeg([object]$Doc, [string]$Role) {
    if ($null -eq $Doc) { return '' }
    $legs = $Doc.legs
    if ($null -eq $legs -or $legs -isnot [System.Management.Automation.PSCustomObject]) { return '' }
    $property = $legs.PSObject.Properties[$Role]
    if (-not $property) { return '' }
    $value = $property.Value
    if ($value -is [string] -and $value.Trim()) { return $value }
    return ''
}

$Root = Get-RepoRoot
if ($env:TWIN_RUNS) {
    $Runs = [System.IO.Path]::GetFullPath($env:TWIN_RUNS)
} else {
    $Runs = Join-Path $Root 'runs'
}
$ReferenceLeg = if ($env:TWIN_REFERENCE_LEG) { $env:TWIN_REFERENCE_LEG } else { 'reference' }
$PortLeg = if ($env:TWIN_PORT_LEG) { $env:TWIN_PORT_LEG } else { 'port' }

$Registry = Read-Registry
$Single = ($env:TWIN_SINGLE -eq '1') -or (Test-SingleRegistry $Registry)
$registryReference = Get-RegistryLeg $Registry 'reference'
$registryPort = Get-RegistryLeg $Registry 'port'
if (-not $Single -and $registryReference) { $ReferenceLeg = $registryReference }
if ($registryPort) { $PortLeg = $registryPort }
if ($env:TWIN_REFERENCE_LEG) { $ReferenceLeg = $env:TWIN_REFERENCE_LEG }
if ($env:TWIN_PORT_LEG) { $PortLeg = $env:TWIN_PORT_LEG }

function Get-Stamp {
    return (Get-Date).ToString('yyyyMMdd-HHmmss')
}

function Get-Slug([string]$Text) {
    $slug = $Text -replace '[ /]', '-'
    $slug = $slug -replace '[^A-Za-z0-9._-]', ''
    if (-not $slug) { $slug = 'evidence' }
    return $slug
}

function Assert-ItemId([string]$Id) {
    if ($Id -notmatch '^[A-Z][A-Z0-9]*-[0-9]{3,}$') {
        Fail "item id must look like TWIN-0001 (got '$Id')"
    }
    return $Id
}

function Get-LegName([string]$Leg) {
    switch ($Leg) {
        'reference' {
            if ($Single) { Fail 'this registry is single-leg; there is no reference folder' }
            return $ReferenceLeg
        }
        'port' { return $PortLeg }
        default { Fail "leg must be 'reference' or 'port' (got '$Leg')" }
    }
}

function Ensure-ItemDir([string]$Id) {
    $valid = Assert-ItemId $Id
    $itemRoot = Join-Path $Runs $valid
    New-Item -ItemType Directory -Force -Path (Join-Path $itemRoot $PortLeg) | Out-Null
    if (-not $Single) {
        New-Item -ItemType Directory -Force -Path (Join-Path $itemRoot $ReferenceLeg) | Out-Null
    }
    return $itemRoot
}

function Write-TextFile([string]$Path, [string]$Text) {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Get-CommandParts([object[]]$Parts) {
    if ($Parts.Count -gt 0 -and [string]$Parts[0] -eq '--') {
        if ($Parts.Count -gt 1) { return @($Parts[1..($Parts.Count - 1)]) }
        return @()
    }
    return @($Parts)
}

switch ($Command) {
    'dir' {
        if ($Rest.Count -lt 1) { Fail 'dir needs ITEM' }
        Write-Output (Ensure-ItemDir ([string]$Rest[0]))
    }
    'ensure' {
        if ($Rest.Count -lt 1) { Fail 'ensure needs ITEM' }
        Write-Output (Ensure-ItemDir ([string]$Rest[0]))
    }
    'stamp' {
        Write-Output (Get-Stamp)
    }
    'capture' {
        if ($Rest.Count -lt 3) { Fail 'capture needs LEG ITEM LABEL -- CMD...' }
        $leg = [string]$Rest[0]
        $id = [string]$Rest[1]
        $label = [string]$Rest[2]
        $parts = @()
        if ($Rest.Count -gt 3) { $parts = @($Rest[3..($Rest.Count - 1)]) }
        $commandParts = Get-CommandParts $parts
        if ($commandParts.Count -eq 0) { Fail 'capture needs a command after --' }
        $itemRoot = Ensure-ItemDir $id
        $legName = Get-LegName $leg
        $out = Join-Path (Join-Path $itemRoot $legName) ("$(Get-Stamp)-$(Get-Slug $label).png")
        $env:TWIN_SHOT_PATH = $out
        $exe = [string]$commandParts[0]
        $exeArgs = @()
        if ($commandParts.Count -gt 1) { $exeArgs = @($commandParts[1..($commandParts.Count - 1)]) }
        & $exe @exeArgs
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Output $out
    }
    'note' {
        if ($Rest.Count -lt 2) { Fail 'note needs ITEM LABEL [TEXT]' }
        $id = [string]$Rest[0]
        $label = [string]$Rest[1]
        $text = ''
        if ($Rest.Count -gt 2) { $text = (@($Rest[2..($Rest.Count - 1)]) -join ' ') }
        $itemRoot = Ensure-ItemDir $id
        $out = Join-Path $itemRoot ("$(Get-Stamp)-$(Get-Slug $label).md")
        Write-TextFile $out ($text + "`n")
        Write-Output $out
    }
    'log' {
        if ($Rest.Count -lt 2) { Fail 'log needs ITEM LABEL [CMD...]' }
        $id = [string]$Rest[0]
        $label = [string]$Rest[1]
        $parts = @()
        if ($Rest.Count -gt 2) { $parts = @($Rest[2..($Rest.Count - 1)]) }
        $itemRoot = Ensure-ItemDir $id
        $out = Join-Path $itemRoot ("$(Get-Stamp)-$(Get-Slug $label).log")
        if ($parts.Count -gt 0) {
            $exe = [string]$parts[0]
            $exeArgs = @()
            if ($parts.Count -gt 1) { $exeArgs = @($parts[1..($parts.Count - 1)]) }
            & $exe @exeArgs 2>&1 | Tee-Object -FilePath $out | Out-Null
        } else {
            $input | Out-File -FilePath $out -Encoding utf8
        }
        Write-Output $out
    }
    { $_ -in @('-h', '--help', 'help', '') } {
        Write-Output (Get-Usage)
    }
    default {
        Fail "unknown action '$Command' (see --help)"
    }
}
