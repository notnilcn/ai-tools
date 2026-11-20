# SPDX-License-Identifier: GPL-3.0-only
#
# resource-monitor.ps1 - wave guard for CPU, RAM and disk pressure (Windows).
#
# Run this before a wave of parallel subagents. It samples the machine, prints
# one line per sample with a `parallel=` recommendation, and exits 3 with an
# alert JSON when a limit stays exceeded for --streak consecutive samples.
#
# How to use it (orchestrating agent):
#   1. Define the wave limits once for this repository:
#        .\resource-monitor.ps1 --init --cpu-percent 85 --ram-percent 80 `
#          --disk-percent 90 --streak 3
#   2. Start the monitor before the first wave, for example as a background job:
#        Start-Job -FilePath .\resource-monitor.ps1 -ArgumentList '--json','--log','.tmp\resource-monitor\monitor.log'
#   3. Spawn at most `parallel=` subagents, from the latest sample.
#   4. On exit code 3, stop spawning, read the alert JSON and follow its
#      `required_action`. Restart the monitor only after two clean samples.
#
# The recommendation only counts processes that are not part of the resource
# queue (see run-resource-intensive-task.ps1), so queued heavy work cannot make
# the monitor blame the wave. Override the per-subagent assumptions with
# RESOURCE_MONITOR_AGENT_CPU_PERCENT / RESOURCE_MONITOR_AGENT_RAM_MB.
#
# Usage:
#   resource-monitor.ps1 [options]
#
# Options:
#   --interval SECS        sample period (default 6, saved)
#   --cpu-percent N        unqueued CPU ceiling, % of all cores (saved)
#   --ram-percent N        unqueued RAM ceiling, % of total RAM (saved)
#   --disk-percent N       used-space ceiling for watched drives (saved)
#   --disk-write-mb N      unqueued writes per sample that count as pressure (saved)
#   --streak N             consecutive samples over a limit before alerting (saved)
#   --init                 save the supplied limits and exit
#   --path PATH            file/directory whose drive to watch; repeatable
#   --state-dir DIR        lock, limits, alert and scratch state
#                          (default <repo>\.tmp\resource-monitor)
#   --alert-file FILE      alert JSON path (default <state-dir>\alert.json)
#   --log FILE             append every sample and alert line to FILE
#   --once                 sample once, print it, exit 0
#   --max-samples N        stop cleanly after N samples
#   --json                 print one JSON object per sample
#   --quiet                suppress per-sample lines
#   --no-lock              do not refuse to start when another monitor is running
#   -h, --help             this help
#
# Exit codes:
#   0  clean stop (signal, --once, --init, --max-samples)
#   2  usage or undefined limits
#   3  resource pressure
#   4  another monitor already holds this state directory's lock
#
# Environment:
#   RESOURCE_GATE_REPO_ROOT          repository to watch (default: the git top
#                                    level that contains this checkout)
#   RESOURCE_QUEUE_DIR               queue state directory shared with
#                                    run-resource-intensive-task.ps1 (default:
#                                    <git-common-dir>\resource-queue)
#   RESOURCE_MONITOR_DIR             default for --state-dir
#   RESOURCE_MONITOR_LIMITS_FILE     default for the saved limits file
#                                    (default <state-dir>\limits.json)
#   RESOURCE_MONITOR_INTERVAL        default for --interval
#   RESOURCE_MONITOR_CPU_PERCENT     default for --cpu-percent
#   RESOURCE_MONITOR_RAM_PERCENT     default for --ram-percent
#   RESOURCE_MONITOR_DISK_PERCENT    default for --disk-percent
#   RESOURCE_MONITOR_DISK_WRITE_MB   default for --disk-write-mb
#   RESOURCE_MONITOR_STREAK          default for --streak
#   RESOURCE_MONITOR_MAX_PARALLEL    hard cap on the recommendation (default 6)
#   RESOURCE_MONITOR_AGENT_CPU_PERCENT  CPU one subagent is assumed to use (100)
#   RESOURCE_MONITOR_AGENT_RAM_MB    RAM one subagent is assumed to use (2048)

$ErrorActionPreference = 'Stop'
$RawArgs = @($args)
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Fail([string]$Message) {
    [Console]::Error.WriteLine("resource-monitor: $Message")
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

# --- localization ----------------------------------------------------------

$ScriptDir = $PSScriptRoot
$ToolsDir = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..'))

function Get-GitTop([string]$Path) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
    $top = & git -C $Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { return ([string]$top).Trim() }
    return ''
}

# The repository this checkout was cloned into is the one to watch and queue
# for. The checkout may itself be a git repository (a nested clone), so start
# above it and take the first git top level instead of the checkout's own root.
function Get-RepoRoot {
    if ($env:RESOURCE_GATE_REPO_ROOT) {
        return [System.IO.Path]::GetFullPath($env:RESOURCE_GATE_REPO_ROOT)
    }
    $start = [System.IO.Path]::GetFullPath((Join-Path $ToolsDir '..'))
    $dir = $start
    while ($dir) {
        $top = Get-GitTop $dir
        if ($top) { return $top }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $top = Get-GitTop (Get-Location).Path
    if ($top) { return $top }
    return $start
}

$RepoRoot = Get-RepoRoot

function Get-QueueDir {
    $override = $env:RESOURCE_QUEUE_DIR
    if ($override) {
        if (-not [System.IO.Path]::IsPathRooted($override)) { $override = Join-Path $RepoRoot $override }
        return [System.IO.Path]::GetFullPath($override)
    }
    $common = $null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $common = & git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $common) {
            $common = & git -C $RepoRoot rev-parse --git-common-dir 2>$null
        }
        if ($LASTEXITCODE -ne 0) { $common = $null }
    }
    if (-not $common) { return (Join-Path $RepoRoot '.resource-queue') }
    $common = ([string]$common).Trim()
    if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $RepoRoot $common }
    $common = [System.IO.Path]::GetFullPath($common)
    return (Join-Path $common 'resource-queue')
}

$QueueDir = Get-QueueDir
$LockFile = Join-Path $QueueDir 'lock'
$HolderFile = Join-Path $QueueDir 'holder'
$LastHolderFile = Join-Path $QueueDir 'last-holder'

# --- inputs ----------------------------------------------------------------

$Options = [ordered]@{
    Interval = $null
    Cpu = $null
    Ram = $null
    Disk = $null
    DiskWrite = $null
    Streak = $null
    Paths = @()
    StateDir = $null
    AlertFile = $null
    LogFile = $null
    Init = $false
    Once = $false
    MaxSamples = 0
    Json = $false
    Quiet = $false
    NoLock = $false
    Help = $false
}

$i = 0
while ($i -lt $RawArgs.Count) {
    $arg = [string]$RawArgs[$i]
    if ($arg -eq '--interval') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--interval needs a value' }
        $Options.Interval = [string]$RawArgs[$i + 1]; $i += 2; continue
    }
    if ($arg -eq '--cpu-percent') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--cpu-percent needs a value' }
        $Options.Cpu = [string]$RawArgs[$i + 1]; $i += 2; continue
    }
    if ($arg -eq '--ram-percent') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--ram-percent needs a value' }
        $Options.Ram = [string]$RawArgs[$i + 1]; $i += 2; continue
    }
    if ($arg -eq '--disk-percent') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--disk-percent needs a value' }
        $Options.Disk = [string]$RawArgs[$i + 1]; $i += 2; continue
    }
    if ($arg -eq '--disk-write-mb') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--disk-write-mb needs a value' }
        $Options.DiskWrite = [string]$RawArgs[$i + 1]; $i += 2; continue
    }
    if ($arg -eq '--streak') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--streak needs a value' }
        $Options.Streak = [string]$RawArgs[$i + 1]; $i += 2; continue
    }
    if ($arg -eq '--path') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--path needs a value' }
        $Options.Paths = @($Options.Paths) + [string]$RawArgs[$i + 1]
        $i += 2; continue
    }
    if ($arg -eq '--state-dir') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--state-dir needs a value' }
        $Options.StateDir = [string]$RawArgs[$i + 1]; $i += 2; continue
    }
    if ($arg -eq '--alert-file') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--alert-file needs a value' }
        $Options.AlertFile = [string]$RawArgs[$i + 1]; $i += 2; continue
    }
    if ($arg -eq '--log') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--log needs a value' }
        $Options.LogFile = [string]$RawArgs[$i + 1]; $i += 2; continue
    }
    if ($arg -eq '--init') { $Options.Init = $true; $i++; continue }
    if ($arg -eq '--once') { $Options.Once = $true; $i++; continue }
    if ($arg -eq '--max-samples') {
        if ($i + 1 -ge $RawArgs.Count) { Fail '--max-samples needs a value' }
        $Options.MaxSamples = [string]$RawArgs[$i + 1]; $i += 2; continue
    }
    if ($arg -eq '--json') { $Options.Json = $true; $i++; continue }
    if ($arg -eq '--quiet' -or $arg -eq '-q') { $Options.Quiet = $true; $i++; continue }
    if ($arg -eq '--no-lock') { $Options.NoLock = $true; $i++; continue }
    if ($arg -eq '-h' -or $arg -eq '--help') { $Options.Help = $true; $i++; continue }
    Fail "unknown argument '$arg' (see --help)"
}

if ($Options.Help) {
    Write-Output (Get-Usage)
    exit 0
}

# The state directory and the saved limits are resolved before the limits are
# read, so a monitor started from any directory uses the same state.
function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

$stateDirArg = $Options.StateDir
if (-not $stateDirArg) { $stateDirArg = $env:RESOURCE_MONITOR_DIR }
$StateDir = if ($stateDirArg) {
    Resolve-RepoPath $stateDirArg
} else {
    Join-Path $RepoRoot '.tmp\resource-monitor'
}

$LimitsFile = if ($env:RESOURCE_MONITOR_LIMITS_FILE) {
    Resolve-RepoPath $env:RESOURCE_MONITOR_LIMITS_FILE
} else {
    Join-Path $StateDir 'limits.json'
}

$FileLimits = $null
$HasLimitsFile = Test-Path $LimitsFile
if ($HasLimitsFile) {
    try {
        $FileLimits = Get-Content -Raw -Path $LimitsFile | ConvertFrom-Json
    } catch {
        Fail "cannot parse $LimitsFile : $($_.Exception.Message)"
    }
}

function Get-ConfigValue($CliValue, [string]$EnvName, $FileObject, [string]$FileProperty, $Fallback) {
    if ($null -ne $CliValue -and [string]$CliValue -ne '') { return [string]$CliValue }
    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if ($envValue) { return $envValue }
    if ($FileObject) {
        $property = $FileObject.PSObject.Properties[$FileProperty]
        if ($property -and $null -ne $property.Value) {
            return [string]$property.Value
        }
    }
    return $Fallback
}

function To-Int([string]$Value, [string]$Name) {
    $number = 0
    if (-not [int]::TryParse($Value, [ref]$number)) { Fail "$Name needs a whole number" }
    return $number
}

$Interval = To-Int (Get-ConfigValue $Options.Interval 'RESOURCE_MONITOR_INTERVAL' $FileLimits 'interval' '6') '--interval'
$CpuLimitRaw = Get-ConfigValue $Options.Cpu 'RESOURCE_MONITOR_CPU_PERCENT' $FileLimits 'cpu_percent' ''
$RamLimitRaw = Get-ConfigValue $Options.Ram 'RESOURCE_MONITOR_RAM_PERCENT' $FileLimits 'ram_percent' ''
$DiskLimitRaw = Get-ConfigValue $Options.Disk 'RESOURCE_MONITOR_DISK_PERCENT' $FileLimits 'disk_percent' ''
$DiskWriteRaw = Get-ConfigValue $Options.DiskWrite 'RESOURCE_MONITOR_DISK_WRITE_MB' $FileLimits 'disk_write_mb' '512'
$StreakRaw = Get-ConfigValue $Options.Streak 'RESOURCE_MONITOR_STREAK' $FileLimits 'streak' ''

if (-not $CpuLimitRaw -or -not $RamLimitRaw -or -not $DiskLimitRaw -or -not $StreakRaw) {
    [Console]::Error.WriteLine('resource-monitor: warning limits are not defined.')
    [Console]::Error.WriteLine('The orchestrator needs to define the limits for the resource monitor warnings before starting a wave.')
    [Console]::Error.WriteLine('Define them once with:')
    [Console]::Error.WriteLine("  $PSCommandPath --cpu-percent N --ram-percent N --disk-percent N --streak N [--disk-write-mb N]")
    [Console]::Error.WriteLine("The limits are saved to $LimitsFile.")
    exit 2
}

$CpuLimit = To-Int $CpuLimitRaw '--cpu-percent'
$RamLimit = To-Int $RamLimitRaw '--ram-percent'
$DiskLimit = To-Int $DiskLimitRaw '--disk-percent'
$DiskWriteMb = To-Int $DiskWriteRaw '--disk-write-mb'
$Streak = To-Int $StreakRaw '--streak'
$MaxSamples = To-Int ([string]$Options.MaxSamples) '--max-samples'

if ($Interval -lt 1) { Fail '--interval must be at least 1' }
if ($MaxSamples -lt 0) { Fail '--max-samples must be 0 or more' }
if ($Streak -lt 1) { Fail '--streak must be at least 1' }
if ($CpuLimit -lt 1 -or $CpuLimit -gt 100) { Fail '--cpu-percent must be 1..100' }
if ($RamLimit -lt 1 -or $RamLimit -gt 100) { Fail '--ram-percent must be 1..100' }
if ($DiskLimit -lt 1 -or $DiskLimit -gt 100) { Fail '--disk-percent must be 1..100' }

function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Save-Limits {
    $obj = [ordered]@{
        interval = $Interval
        cpu_percent = $CpuLimit
        ram_percent = $RamLimit
        disk_percent = $DiskLimit
        disk_write_mb = $DiskWriteMb
        streak = $Streak
    }
    $parent = [System.IO.Path]::GetDirectoryName($LimitsFile)
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $tmp = "$LimitsFile.tmp"
    Write-Utf8 $tmp ($obj | ConvertTo-Json)
    Move-Item -Path $tmp -Destination $LimitsFile -Force
}

if ((-not $HasLimitsFile) -or $Options.Init) {
    Save-Limits
}
if ($Options.Init) {
    Write-Output "resource-monitor: saved limits to $LimitsFile"
    exit 0
}

$MaxParallel = 6
$AgentCpuPercent = 100
$AgentRamMb = 2048
if ($env:RESOURCE_MONITOR_MAX_PARALLEL) { $MaxParallel = To-Int $env:RESOURCE_MONITOR_MAX_PARALLEL 'RESOURCE_MONITOR_MAX_PARALLEL' }
if ($env:RESOURCE_MONITOR_AGENT_CPU_PERCENT) { $AgentCpuPercent = To-Int $env:RESOURCE_MONITOR_AGENT_CPU_PERCENT 'RESOURCE_MONITOR_AGENT_CPU_PERCENT' }
if ($env:RESOURCE_MONITOR_AGENT_RAM_MB) { $AgentRamMb = To-Int $env:RESOURCE_MONITOR_AGENT_RAM_MB 'RESOURCE_MONITOR_AGENT_RAM_MB' }
if ($MaxParallel -lt 0) { $MaxParallel = 0 }
if ($AgentCpuPercent -lt 1) { $AgentCpuPercent = 1 }
if ($AgentRamMb -lt 1) { $AgentRamMb = 1 }

$UseLock = -not $Options.NoLock
if ($Options.Once) { $UseLock = $false }

Push-Location $RepoRoot

$AlertFile = if ($Options.AlertFile) {
    Resolve-RepoPath $Options.AlertFile
} else {
    Join-Path $StateDir 'alert.json'
}
$LogFile = if ($Options.LogFile) {
    Resolve-RepoPath $Options.LogFile
} else {
    ''
}
$WatchPaths = @($Options.Paths)
if ($WatchPaths.Count -eq 0) {
    $WatchPaths = @($RepoRoot, [System.IO.Path]::GetTempPath())
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($AlertFile)) | Out-Null
$TmpDir = Join-Path $StateDir 'tmp'
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
if ($LogFile) {
    New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($LogFile)) | Out-Null
    if (-not (Test-Path $LogFile)) { [System.IO.File]::WriteAllText($LogFile, '', $script:Utf8NoBom) }
}

if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("resource-monitor: Get-CimInstance is required (Windows PowerShell 3+).")
    exit 1
}
if (-not (Get-Command Get-Process -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("resource-monitor: Get-Process is required.")
    exit 1
}

$NCPU = [Environment]::ProcessorCount
if ($NCPU -lt 1) { $NCPU = 1 }

$OsInfo = Get-CimInstance Win32_OperatingSystem
$MemTotalBytes = [double]$OsInfo.TotalVisibleMemorySize * 1024
$MemAvailableBytes = [double]$OsInfo.FreePhysicalMemory * 1024

$script:QueueActive = $false
$script:QueueTask = ''
$script:QueuePid = 0
$script:QueueAncestors = ''
$script:QueueAncestorTtl = @{}
$script:LastHolderStamp = ''

$script:ProcIds = @()
$script:ProcPpid = @{}
$script:ProcCpu = @{}
$script:ProcMem = @{}
$script:ProcWrite = @{}
$script:ProcCmd = @{}
$script:ProcPath = @{}
$script:Exempt = @{}
$script:PrevExempt = @{}
$script:PrevCpu = @{}
$script:PrevWrite = @{}
$script:PrevTime = $null
$script:Now = Get-Date

$script:CpuTenths = 0
$script:RamBytes = 0.0
$script:RamTenths = 0
$script:WriteBytes = 0.0
$script:WriteMbTenths = 0
$script:DiskMaxUsedTenths = 0
$script:DiskMinAvailBytes = -1
$script:DiskDeferred = $false
$script:DiskList = @()

$script:CpuStreak = 0
$script:RamStreak = 0
$script:DiskStreak = 0
$script:WriteStreak = 0
$script:RecommendedParallel = 0

$MonitorLock = $null

if ($UseLock) {
    try {
        $MonitorLock = [System.IO.FileStream]::new(
            (Join-Path $StateDir 'monitor.lock'),
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        Remove-Item $AlertFile -Force -ErrorAction SilentlyContinue
    } catch {
        [Console]::Error.WriteLine("resource-monitor: another monitor is already running for $StateDir")
        exit 4
    }
}

function Format-Tenths([int]$Value) {
    return ([double]$Value / 10.0).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Mib([double]$Bytes) {
    return ($Bytes / 1048576.0).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Write-LogLine([string]$Text) {
    $line = "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) $Text"
    if ($Options.Json) {
        [Console]::Error.WriteLine($line)
    } elseif (-not $Options.Quiet) {
        Write-Output $line
    }
    if ($LogFile) {
        [System.IO.File]::AppendAllText($LogFile, $line + "`n", $script:Utf8NoBom)
    }
}

function Write-AlertLine([string]$Text) {
    if ($Options.Json) {
        [Console]::Error.WriteLine($Text)
    } else {
        Write-Output $Text
    }
    if ($LogFile) {
        $line = "$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) $Text"
        [System.IO.File]::AppendAllText($LogFile, $line + "`n", $script:Utf8NoBom)
    }
}

function Get-ParentProcessId([int]$ProcessId) {
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($proc) { return [int]$proc.ParentProcessId }
    } catch {
    }
    return 0
}

function Get-SafePids {
    $safe = @{}
    $safe[$PID] = $true
    $current = Get-ParentProcessId $PID
    $depth = 0
    while ($current -gt 1 -and $depth -lt 32) {
        $safe[$current] = $true
        $current = Get-ParentProcessId $current
        $depth++
    }
    return $safe
}

$script:SafePids = Get-SafePids

function Get-QueueState {
    $script:QueueActive = $false
    $script:QueueTask = ''
    $script:QueuePid = 0
    $script:QueueAncestors = ''
    if (Test-Path $HolderFile) {
        foreach ($line in Get-Content $HolderFile -ErrorAction SilentlyContinue) {
            if ($line -like 'task=*') { $script:QueueTask = $line.Substring(5) }
            elseif ($line -like 'pid=*') { $script:QueuePid = [int]$line.Substring(4) }
            elseif ($line -like 'ancestors=*') { $script:QueueAncestors = $line.Substring(10) }
        }
    }
    if (Test-Path $LockFile) {
        try {
            $stream = [System.IO.FileStream]::new(
                $LockFile,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            $stream.Dispose()
        } catch {
            $script:QueueActive = $true
        }
    }
    if (-not $script:QueueActive -and $script:QueuePid -gt 0 -and (Get-Process -Id $script:QueuePid -ErrorAction SilentlyContinue)) {
        $script:QueueActive = $true
    }
}

function Get-ProcessSnapshot {
    $script:ProcIds = @()
    $script:ProcPpid = @{}
    $script:ProcCpu = @{}
    $script:ProcMem = @{}
    $script:ProcWrite = @{}
    $script:ProcCmd = @{}
    $script:ProcPath = @{}

    $byId = @{}
    foreach ($gp in @(Get-Process -ErrorAction SilentlyContinue)) {
        $gpId = [int]$gp.Id
        $byId[$gpId] = $gp
    }
    foreach ($p in @(Get-CimInstance Win32_Process)) {
        $procId = [int]$p.ProcessId
        if ($procId -le 0) { continue }
        $script:ProcIds += $procId
        $script:ProcPpid[$procId] = [int]$p.ParentProcessId
        $script:ProcCmd[$procId] = [string]$p.CommandLine
        $script:ProcPath[$procId] = [string]$p.ExecutablePath
        $writeCount = 0L
        if ($null -ne $p.WriteTransferCount) {
            try { $writeCount = [uint64]$p.WriteTransferCount } catch { $writeCount = 0L }
        }
        $script:ProcWrite[$procId] = $writeCount
        $gp = $byId[$procId]
        if ($gp) {
            try { $script:ProcCpu[$procId] = [double]$gp.CPU } catch { $script:ProcCpu[$procId] = 0.0 }
            try { $script:ProcMem[$procId] = [double]$gp.PrivateMemorySize64 } catch { $script:ProcMem[$procId] = 0.0 }
        } else {
            $script:ProcCpu[$procId] = 0.0
            $script:ProcMem[$procId] = 0.0
        }
    }
}

function Test-Descendant([int]$ProcessId, [int]$Root) {
    $current = $ProcessId
    $depth = 0
    while ($depth -lt 64 -and $script:ProcPpid.ContainsKey($current)) {
        $parent = [int]$script:ProcPpid[$current]
        if ($parent -le 0) { return $false }
        if ($parent -eq $Root) { return $true }
        $current = $parent
        $depth++
    }
    return $false
}

function Add-ExemptTree([int]$Root) {
    foreach ($processId in $script:ProcIds) {
        if ($processId -eq $Root -or (Test-Descendant $processId $Root)) {
            $script:Exempt[$processId] = $true
        }
    }
}

function Add-AncestorTtl([string]$List) {
    foreach ($entry in ([string]$List).Split(',')) {
        if ($entry -match '^\d+$') {
            $ancestorKey = [int]$entry
            $script:QueueAncestorTtl[$ancestorKey] = 3
        }
    }
}

function Update-Exemptions {
    $script:Exempt = @{}
    foreach ($safePid in $script:SafePids.Keys) {
        $script:Exempt[$safePid] = $true
    }
    Add-ExemptTree $PID

    if ($script:QueueActive -and $script:QueuePid -gt 0) {
        Add-AncestorTtl $script:QueueAncestors
        if (Get-Process -Id $script:QueuePid -ErrorAction SilentlyContinue) {
            Add-ExemptTree $script:QueuePid
        }
    } elseif (-not $script:QueueActive -and (Test-Path $LastHolderFile)) {
        $item = Get-Item $LastHolderFile
        $stamp = "$($item.LastWriteTimeUtc.Ticks):$($item.Length)"
        if ($stamp -ne $script:LastHolderStamp) {
            $script:LastHolderStamp = $stamp
            $lastAncestors = ''
            $lastPpid = 0
            foreach ($line in Get-Content $LastHolderFile -ErrorAction SilentlyContinue) {
                if ($line -like 'ancestors=*') { $lastAncestors = $line.Substring(10) }
                elseif ($line -like 'ppid=*') { $lastPpid = [int]$line.Substring(5) }
            }
            Add-AncestorTtl $lastAncestors
            if ($lastPpid -gt 1) { $script:QueueAncestorTtl[$lastPpid] = 3 }
        }
    }

    foreach ($ancestorPid in @($script:QueueAncestorTtl.Keys)) {
        if ($script:ProcPpid.ContainsKey($ancestorPid)) {
            $script:Exempt[$ancestorPid] = $true
        }
        $ttl = [int]$script:QueueAncestorTtl[$ancestorPid] - 1
        if ($ttl -gt 0) {
            $script:QueueAncestorTtl[$ancestorPid] = $ttl
        } else {
            $script:QueueAncestorTtl.Remove($ancestorPid)
        }
    }
}

function Update-Metrics {
    $script:CpuTicks = 0.0
    $script:RamBytes = 0.0
    $script:WriteBytes = 0.0
    $script:DiskDeferred = $false
    $script:Now = Get-Date
    $elapsed = 0.0
    if ($null -ne $script:PrevTime) {
        $elapsed = ($script:Now - $script:PrevTime).TotalSeconds
    }

    foreach ($processId in $script:ProcIds) {
        if ($script:Exempt.ContainsKey($processId)) { continue }
        $script:RamBytes += [double]$script:ProcMem[$processId]

        if ($elapsed -gt 0 -and $script:PrevCpu.ContainsKey($processId) -and -not $script:PrevExempt.ContainsKey($processId)) {
            $cpuDelta = [double]$script:ProcCpu[$processId] - [double]$script:PrevCpu[$processId]
            if ($cpuDelta -gt 0) { $script:CpuTicks += $cpuDelta }
            if ($script:PrevWrite.ContainsKey($processId)) {
                $writeDelta = [double]$script:ProcWrite[$processId] - [double]$script:PrevWrite[$processId]
                if ($writeDelta -gt 0) { $script:WriteBytes += $writeDelta }
            }
        }
    }

    $script:CpuTenths = 0
    if ($elapsed -gt 0 -and $NCPU -gt 0) {
        $script:CpuTenths = [int][Math]::Round(($script:CpuTicks / ($elapsed * $NCPU)) * 1000.0)
    }
    if ($script:CpuTenths -gt 1000) { $script:CpuTenths = 1000 }
    if ($script:CpuTenths -lt 0) { $script:CpuTenths = 0 }

    if ($MemTotalBytes -gt 0) {
        $script:RamTenths = [int][Math]::Round(($script:RamBytes / $MemTotalBytes) * 1000.0)
    } else {
        $script:RamTenths = 0
    }
    if ($script:RamTenths -gt 1000) { $script:RamTenths = 1000 }

    $script:WriteMbTenths = [int][Math]::Round(($script:WriteBytes / 1048576.0) * 10.0)
}

function Update-DiskUsage {
    $script:DiskMaxUsedTenths = 0
    $script:DiskMinAvailBytes = -1
    $script:DiskList = @()
    $seen = @{}

    foreach ($watched in $WatchPaths) {
        $resolved = $watched
        try {
            $resolved = (Resolve-Path -Path $watched -ErrorAction Stop).Path
        } catch {
            continue
        }
        $root = [System.IO.Path]::GetPathRoot($resolved)
        if (-not $root -or $root -notmatch '^[A-Za-z]:\\?$') { continue }
        $deviceId = $root.TrimEnd([char]92)
        if ($seen.ContainsKey($deviceId)) { continue }
        $seen[$deviceId] = $true
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$deviceId'" -ErrorAction SilentlyContinue
        if (-not $disk) { continue }
        $size = [double]$disk.Size
        $free = [double]$disk.FreeSpace
        if ($size -le 0) { continue }
        $usedTenths = [int][Math]::Round((($size - $free) / $size) * 1000.0)
        if ($usedTenths -gt $script:DiskMaxUsedTenths) { $script:DiskMaxUsedTenths = $usedTenths }
        if ($script:DiskMinAvailBytes -lt 0 -or $free -lt $script:DiskMinAvailBytes) { $script:DiskMinAvailBytes = [long]$free }
        $script:DiskList += [ordered]@{
            path = $resolved
            used_percent = [double]($usedTenths / 10.0)
            avail_bytes = [long]$free
            total_bytes = [long]$size
        }
    }
}

function Update-Streaks {
    $overCpu = ($script:CpuTenths -ge ($CpuLimit * 10))
    $overRam = ($script:RamTenths -ge ($RamLimit * 10))
    $overWrite = ($script:WriteMbTenths -ge ($DiskWriteMb * 10))
    $script:DiskDeferred = $false

    if ($script:QueueActive) {
        $script:DiskDeferred = $true
        $script:DiskStreak = 0
    } else {
        $overDisk = ($script:DiskMaxUsedTenths -ge ($DiskLimit * 10))
        if ($overDisk) { $script:DiskStreak++ } else { $script:DiskStreak = 0 }
    }

    if ($overCpu) { $script:CpuStreak++ } else { $script:CpuStreak = 0 }
    if ($overRam) { $script:RamStreak++ } else { $script:RamStreak = 0 }
    if ($overWrite) { $script:WriteStreak++ } else { $script:WriteStreak = 0 }
}

function Update-Recommendation {
    $cpuRoom = ($CpuLimit * 10) - $script:CpuTenths
    if ($cpuRoom -lt 0) { $cpuRoom = 0 }
    $byCpu = [Math]::Floor(($cpuRoom * $NCPU) / (10.0 * $AgentCpuPercent))

    $byRam = $MaxParallel
    if ($MemTotalBytes -gt 0) {
        $ramRoom = (($RamLimit / 100.0) * $MemTotalBytes) - $script:RamBytes
        if ($ramRoom -lt 0) { $ramRoom = 0 }
        $byRam = [Math]::Floor($ramRoom / ($AgentRamMb * 1048576.0))
    }

    $recommended = [Math]::Min([double]$byCpu, [double]$byRam)
    $recommended = [Math]::Min($recommended, [double]$MaxParallel)
    if ($recommended -lt 0) { $recommended = 0 }
    $script:RecommendedParallel = [int]$recommended
}

function Emit-Sample {
    $at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $cpuText = Format-Tenths $script:CpuTenths
    $ramText = Format-Tenths $script:RamTenths
    $writeText = Format-Tenths $script:WriteMbTenths
    $diskText = 'n/a'
    if ($script:DiskMaxUsedTenths -gt 0) {
        $diskText = "$(Format-Tenths $script:DiskMaxUsedTenths)%"
    }
    if ($script:DiskDeferred) { $diskText = "$diskText deferred" }
    $queueText = if ($script:QueueActive) { "busy($script:QueueTask)" } else { 'idle' }

    if ($Options.Json) {
        $sample = [ordered]@{
            at = $at
            event = 'sample'
            cpu_percent = [double]($script:CpuTenths / 10.0)
            ram_percent = [double]($script:RamTenths / 10.0)
            ram_bytes = [long]$script:RamBytes
            mem_available_bytes = [long]$MemAvailableBytes
            write_mb = [double]($script:WriteMbTenths / 10.0)
            disk_used_percent = [double]($script:DiskMaxUsedTenths / 10.0)
            disk_min_avail_bytes = [long]$script:DiskMinAvailBytes
            disk_deferred = [bool]$script:DiskDeferred
            queue_active = [bool]$script:QueueActive
            queue_task = $script:QueueTask
            recommended_parallel_subagents = $script:RecommendedParallel
            streaks = [ordered]@{
                cpu = $script:CpuStreak
                ram = $script:RamStreak
                disk = $script:DiskStreak
                write = $script:WriteStreak
            }
        }
        $line = $sample | ConvertTo-Json -Compress
        Write-Output $line
        if ($LogFile) { [System.IO.File]::AppendAllText($LogFile, $line + "`n", $script:Utf8NoBom) }
    } else {
        Write-LogLine "cpu=${cpuText}% ram=${ramText}% disk=${diskText} write=${writeText}MB queue=${queueText} parallel=$($script:RecommendedParallel)"
    }
}

function Get-TopProcesses {
    $candidates = @()
    $elapsed = 0.0
    if ($null -ne $script:PrevTime) { $elapsed = ($script:Now - $script:PrevTime).TotalSeconds }
    foreach ($processId in $script:ProcIds) {
        if ($script:Exempt.ContainsKey($processId)) { continue }
        $cpuDelta = 0.0
        if ($script:PrevCpu.ContainsKey($processId) -and -not $script:PrevExempt.ContainsKey($processId)) {
            $cpuDelta = [double]$script:ProcCpu[$processId] - [double]$script:PrevCpu[$processId]
            if ($cpuDelta -lt 0) { $cpuDelta = 0 }
        }
        $cpuPercent = 0.0
        if ($elapsed -gt 0) { $cpuPercent = ($cpuDelta / ($elapsed * $NCPU)) * 100.0 }
        $candidates += [pscustomobject]@{
            Pid = $processId
            Ppid = [int]$script:ProcPpid[$processId]
            Mem = [double]$script:ProcMem[$processId]
            Cpu = $cpuPercent
            Path = [string]$script:ProcPath[$processId]
            Cmd = [string]$script:ProcCmd[$processId]
        }
    }
    $ordered = @()
    $ordered += @($candidates | Sort-Object Mem -Descending | Select-Object -First 8)
    $ordered += @($candidates | Sort-Object Cpu -Descending | Select-Object -First 8)
    $seen = @{}
    $top = @()
    foreach ($candidate in $ordered) {
        if (-not $seen.ContainsKey($candidate.Pid)) {
            $seen[$candidate.Pid] = $true
            $top += $candidate
        }
    }
    return $top
}

function Get-Reasons {
    $reasons = @()
    if ($script:CpuStreak -ge $Streak) { $reasons += "cpu $(Format-Tenths $script:CpuTenths)% >= ${CpuLimit}% for $($script:CpuStreak) samples" }
    if ($script:RamStreak -ge $Streak) { $reasons += "ram $(Format-Tenths $script:RamTenths)% >= ${RamLimit}% for $($script:RamStreak) samples" }
    if ($script:DiskStreak -ge $Streak) { $reasons += "disk $(Format-Tenths $script:DiskMaxUsedTenths)% >= ${DiskLimit}% for $($script:DiskStreak) samples" }
    if ($script:WriteStreak -ge $Streak) { $reasons += "unmanaged writes $(Format-Tenths $script:WriteMbTenths)MB/sample >= ${DiskWriteMb}MB for $($script:WriteStreak) samples" }
    return $reasons
}

function Write-Alert {
    $reasons = @(Get-Reasons)
    $top = @(Get-TopProcesses)
    $protected = @()
    foreach ($safePid in $script:SafePids.Keys) { $protected += [int]$safePid }
    if ($script:QueuePid -gt 0) { $protected += [int]$script:QueuePid }
    $protected = @($protected | Sort-Object -Unique)
    $queuePidJson = if ($script:QueuePid -gt 0) { [int]$script:QueuePid } else { $null }
    $queueText = if ($script:QueueActive) { "busy($script:QueueTask)" } else { 'idle' }

    $processes = @()
    foreach ($candidate in $top) {
        $processes += [ordered]@{
            pid = [int]$candidate.Pid
            ppid = [int]$candidate.Ppid
            rss_bytes = [long]$candidate.Mem
            cpu_percent = [double][Math]::Round($candidate.Cpu, 1)
            path = [string]$candidate.Path
            cmd = [string]$candidate.Cmd
        }
    }

    $alert = [ordered]@{
        at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        event = 'resource-pressure'
        root = $RepoRoot
        limits = [ordered]@{
            cpu_percent = $CpuLimit
            ram_percent = $RamLimit
            disk_percent = $DiskLimit
            disk_write_mb = $DiskWriteMb
            streak = $Streak
            interval_s = $Interval
        }
        metrics = [ordered]@{
            cpu_percent = [double]($script:CpuTenths / 10.0)
            ram_percent = [double]($script:RamTenths / 10.0)
            ram_bytes = [long]$script:RamBytes
            mem_total_bytes = [long]$MemTotalBytes
            mem_available_bytes = [long]$MemAvailableBytes
            write_mb = [double]($script:WriteMbTenths / 10.0)
            disk_used_percent = [double]($script:DiskMaxUsedTenths / 10.0)
            disk_min_avail_bytes = [long]$script:DiskMinAvailBytes
        }
        queue = [ordered]@{
            active = [bool]$script:QueueActive
            task = $script:QueueTask
            pid = $queuePidJson
        }
        recommendation = [ordered]@{
            parallel_subagents = 0
            note = '0 means stop spawning; restart only after two clean samples.'
        }
        protected_pids = $protected
        reasons = $reasons
        disk = $script:DiskList
        processes = $processes
        kill_note = 'Kill only PID trees that belong to the tasks you stop; verify path/cmd first. Never kill the monitor, its ancestors, the orchestrator, or the queue holder.'
        required_action = 'Stop spawning subagents. Kill the process trees of the tasks you stop (see processes above; verify path/cmd first). Reduce parallelism 6->4->2->1. Restart the monitor only after two clean samples.'
    }

    $alertTmp = "$AlertFile.tmp"
    Write-Utf8 $alertTmp ($alert | ConvertTo-Json -Depth 8)
    Move-Item -Path $alertTmp -Destination $AlertFile -Force

    Write-AlertLine ''
    Write-AlertLine 'RESOURCE MONITOR: PRESSURE DETECTED'
    foreach ($reason in $reasons) { Write-AlertLine "  reason: $reason" }
    Write-AlertLine "  cpu: $(Format-Tenths $script:CpuTenths)% (limit ${CpuLimit}%)"
    Write-AlertLine "  ram: $(Format-Tenths $script:RamTenths)% (limit ${RamLimit}%), $(Format-Mib $script:RamBytes) MiB unqueued"
    if ($script:DiskDeferred) {
        Write-AlertLine "  disk: $(Format-Tenths $script:DiskMaxUsedTenths)% used (limit ${DiskLimit}%, deferred while queue is active)"
    } else {
        Write-AlertLine "  disk: $(Format-Tenths $script:DiskMaxUsedTenths)% used (limit ${DiskLimit}%)"
    }
    Write-AlertLine "  unmanaged writes: $(Format-Tenths $script:WriteMbTenths)MB/sample (limit ${DiskWriteMb}MB)"
    Write-AlertLine "  queue: $queueText"
    Write-AlertLine '  recommended parallel subagents: 0'
    if ($top.Count -eq 0) {
        Write-AlertLine '  top unqueued processes: (none sampled)'
    } else {
        Write-AlertLine '  top unqueued processes (pid ppid rss cpu path cmd):'
        foreach ($candidate in $top) {
            $cpuText = ([double]$candidate.Cpu).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
            Write-AlertLine "    $($candidate.Pid) $($candidate.Ppid) $(Format-Mib $candidate.Mem)MiB ${cpuText}% $($candidate.Path) $($candidate.Cmd)"
        }
    }
    Write-AlertLine '  kill only PID trees whose path/cmd belong to the tasks you stopped.'
    Write-AlertLine '  never kill the monitor, its ancestors, the orchestrator, or the queue holder.'
    Write-AlertLine "  protected pids: $($protected -join ' ')"
    Write-AlertLine "  alert json: $AlertFile"
    Write-AlertLine '  ACTION: stop spawning; kill the stopped tasks process trees; reduce parallelism; restart after two clean samples.'
}

# --- main loop -------------------------------------------------------------

Write-LogLine "resource-monitor: watching $($WatchPaths -join ', ') every ${Interval}s (cpu<=${CpuLimit}%, ram<=${RamLimit}%, disk<${DiskLimit}%, writes<=${DiskWriteMb}MB, streak=${Streak})"
Write-LogLine 'resource-monitor: queue-exempt = the monitor, its ancestors, the queue holder and its process tree, and the holder trees that finished recently'
Write-LogLine "resource-monitor: alert json: $AlertFile"

$sampleCount = 0
try {
    while ($true) {
        $cycleStart = Get-Date
        Get-QueueState
        Get-ProcessSnapshot
        Update-DiskUsage
        Update-Exemptions
        Update-Metrics
        Update-Streaks
        Update-Recommendation
        Emit-Sample
        if ($sampleCount -eq 0) {
            Write-LogLine "resource-monitor: recommended parallel subagents: $($script:RecommendedParallel)"
        }

        if ($script:CpuStreak -ge $Streak -or $script:RamStreak -ge $Streak -or $script:DiskStreak -ge $Streak -or $script:WriteStreak -ge $Streak) {
            Write-Alert
            exit 3
        }

        $sampleCount++
        if ($Options.Once -or ($MaxSamples -gt 0 -and $sampleCount -ge $MaxSamples)) {
            Write-LogLine "resource-monitor: clean stop after $sampleCount sample(s)"
            exit 0
        }

        $script:PrevExempt = @{}
        $script:PrevCpu = @{}
        $script:PrevWrite = @{}
        foreach ($processId in $script:ProcIds) {
            $script:PrevCpu[$processId] = [double]$script:ProcCpu[$processId]
            $script:PrevWrite[$processId] = [double]$script:ProcWrite[$processId]
            if ($script:Exempt.ContainsKey($processId)) { $script:PrevExempt[$processId] = $true }
        }
        $script:PrevTime = $script:Now

        $remaining = ($Interval * 1000) - ((Get-Date) - $cycleStart).TotalMilliseconds
        if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]$remaining) }
    }
} finally {
    if ($MonitorLock) {
        $MonitorLock.Dispose()
        $MonitorLock = $null
    }
    if (Test-Path $TmpDir) {
        Remove-Item (Join-Path $TmpDir 'top.*') -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
