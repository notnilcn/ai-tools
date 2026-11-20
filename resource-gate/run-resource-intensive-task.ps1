# SPDX-License-Identifier: GPL-3.0-only
#
# run-resource-intensive-task.ps1 - one-at-a-time queue for resource-heavy work.
#
# Every build, test, code generator, asset pipeline, export, benchmark and
# headless run in this repository goes through this script instead of running
# directly. One exclusive file lock serializes them: a second invocation waits
# in line and then runs with the whole machine available. resource-monitor.ps1
# reads the same queue state and does not count queued work as pressure.
#
# Usage:
#   .\run-resource-intensive-task.ps1 [queue-options] --cmd -- CMD [ARG...]
#   .\run-resource-intensive-task.ps1 [queue-options] --name LABEL -- CMD [ARG...]
#
# Options:
#   --cmd -- CMD...        run CMD (and its arguments) under the exclusive lock
#   --name LABEL -- CMD...  same, but record LABEL in the queue state/history
#   --status               show the holder, waiters and last history event
#   --list                 print this repository's task catalogue
#   --history [N]          last N queue events (default 10)
#   --no-wait              do not queue: exit 75 when the lock is busy
#   --timeout SECS         stop waiting after SECS (0 = forever, default)
#   --quiet                suppress the queue start/finish lines
#   --dry-run              print the resolved command and exit without locking
#   -h, --help             this help
#
# Environment:
#   RESOURCE_GATE_REPO_ROOT  repository to queue for (default: the git top
#                            level that contains this checkout)
#   RESOURCE_QUEUE_DIR       queue state directory (default:
#                            <git-common-dir>\resource-queue, shared by every
#                            worktree of the repository)
#   RESOURCE_QUEUE_CATALOGUE file printed by --list (default:
#                            <repo>\RESOURCE_INTENSIVE_TASKS_CATALOGUE.md)
#   RESOURCE_QUEUE_TIMEOUT   default for --timeout
#   RESOURCE_QUEUE_QUIET     default for --quiet
#   RESOURCE_QUEUE_DISABLE=1 run the command without the queue (debug only)
#   RESOURCE_QUEUE_HELD      internal marker set for commands run under the lock
#
# Examples:
#   .\run-resource-intensive-task.ps1 --cmd -- dotnet build
#   .\run-resource-intensive-task.ps1 --name export -- .\scripts\export.ps1 -Release
#   .\run-resource-intensive-task.ps1 --status
#
# Exit codes: the task's own status; 75 when busy or timed out (EX_TEMPFAIL);
# 2 for usage errors.
#
# The task catalogue lives in <repo>\RESOURCE_INTENSIVE_TASKS_CATALOGUE.md. Copy
# templates\RESOURCE_INTENSIVE_TASKS_CATALOGUE.md from this folder to start one.

$ErrorActionPreference = 'Stop'
$RawArgs = @($args)
$script:Lock = $null
$script:TaskName = ''

function Fail([string]$Message) {
    [Console]::Error.WriteLine("run-resource-intensive-task: $Message")
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

# The repository this checkout was cloned into is the one to queue for. The
# checkout may itself be a git repository (a nested clone), so start above it
# and take the first git top level instead of the checkout's own root.
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

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

# Queue state lives beside the git common dir, not under the checkout, so
# subagents in separate worktrees contend for the same lock. RESOURCE_QUEUE_DIR
# overrides it (absolute, or relative to the repository root).
function Get-QueueDir {
    $override = $env:RESOURCE_QUEUE_DIR
    if ($override) { return (Resolve-RepoPath $override) }
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
$WaiterDir = Join-Path $QueueDir 'waiters'
$HistoryFile = Join-Path $QueueDir 'history.jsonl'
$LastHolderFile = Join-Path $QueueDir 'last-holder'

$Catalogue = if ($env:RESOURCE_QUEUE_CATALOGUE) {
    Resolve-RepoPath $env:RESOURCE_QUEUE_CATALOGUE
} else {
    Join-Path $RepoRoot 'RESOURCE_INTENSIVE_TASKS_CATALOGUE.md'
}

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Get-TaskList {
    if (Test-Path $Catalogue) {
        return (Get-Content -Raw -Path $Catalogue)
    }
    return @"
No task catalogue yet: $Catalogue

Copy templates\RESOURCE_INTENSIVE_TASKS_CATALOGUE.md from this folder to the
repository root and list the commands that are too heavy to run in parallel.
Any of them can then be queued with:
  .\run-resource-intensive-task.ps1 --cmd -- <command>
"@
}

function Get-ParentProcessId([int]$ProcessId) {
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($proc) { return [int]$proc.ParentProcessId }
    } catch {
        # Best effort: a process may exit between the snapshot and this lookup.
    }
    return 0
}

function Get-AncestorChain {
    $ids = New-Object System.Collections.Generic.List[string]
    $current = Get-ParentProcessId $PID
    $depth = 0
    while ($current -gt 1 -and $depth -lt 32) {
        $ids.Add([string]$current)
        $current = Get-ParentProcessId $current
        $depth++
    }
    return ($ids -join ',')
}

function Get-RestArgs([int]$Start) {
    if ($Start -ge $RawArgs.Count) { return @() }
    return @($RawArgs[$Start..($RawArgs.Count - 1)])
}

$defaultTimeout = 0
if ($env:RESOURCE_QUEUE_TIMEOUT) { $defaultTimeout = [int]$env:RESOURCE_QUEUE_TIMEOUT }
$defaultQuiet = ($env:RESOURCE_QUEUE_QUIET -eq '1')

function Parse-Arguments {
    $state = [ordered]@{
        Action = 'run'
        Task = ''
        TaskName = ''
        TaskArgs = @()
        Wait = $true
        Timeout = $defaultTimeout
        Quiet = $defaultQuiet
        DryRun = $false
        HistoryN = 10
    }
    $i = 0
    while ($i -lt $RawArgs.Count) {
        $arg = [string]$RawArgs[$i]
        if ($arg -eq '--status') { $state.Action = 'status'; $i++; continue }
        if ($arg -eq '--list') { $state.Action = 'list'; $i++; continue }
        if ($arg -eq '--history') {
            $state.Action = 'history'
            $i++
            if ($i -lt $RawArgs.Count -and [string]$RawArgs[$i] -match '^\d+$') {
                $state.HistoryN = [int]$RawArgs[$i]
                $i++
            }
            continue
        }
        if ($arg -eq '-h' -or $arg -eq '--help') { $state.Action = 'help'; $i++; continue }
        if ($arg -eq '--no-wait') { $state.Wait = $false; $i++; continue }
        if ($arg -eq '--quiet' -or $arg -eq '-q') { $state.Quiet = $true; $i++; continue }
        if ($arg -eq '--dry-run') { $state.DryRun = $true; $i++; continue }
        if ($arg -eq '--timeout') {
            if ($i + 1 -ge $RawArgs.Count) { Fail '--timeout needs a value' }
            $state.Timeout = [int]$RawArgs[$i + 1]
            $i += 2
            continue
        }
        if ($arg -eq '--cmd') {
            $state.Task = 'raw'
            $i++
            if ($i -lt $RawArgs.Count -and [string]$RawArgs[$i] -eq '--') { $i++ }
            $state.TaskArgs = Get-RestArgs $i
            return $state
        }
        if ($arg -eq '--name') {
            if ($i + 1 -ge $RawArgs.Count) { Fail '--name needs a value' }
            $state.Task = 'raw'
            $state.TaskName = [string]$RawArgs[$i + 1]
            $i += 2
            if ($i -lt $RawArgs.Count -and [string]$RawArgs[$i] -eq '--') { $i++ }
            $state.TaskArgs = Get-RestArgs $i
            return $state
        }
        if ($arg -eq '--') { Fail 'missing task before -- (see --help)' }
        Fail "unknown argument '$arg'"
    }
    return $state
}

function Build-TaskCommand($State) {
    $extra = @($State.TaskArgs)
    if ($extra.Count -eq 0) { Fail '--cmd/--name needs a command (use --cmd -- CMD...)' }
    return $extra
}

function Format-Command([string[]]$Parts) {
    $quoted = foreach ($part in $Parts) {
        if ($part -match '\s') { '"' + $part + '"' } else { $part }
    }
    return ($quoted -join ' ')
}

function Try-AcquireLock {
    try {
        return [System.IO.FileStream]::new(
            $LockFile,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        return $null
    }
}

function Write-Holder([string]$TaskName, [string[]]$TaskCmd) {
    $parent = Get-ParentProcessId $PID
    $chain = Get-AncestorChain
    $lines = @(
        "task=$TaskName",
        "pid=$PID",
        "ppid=$parent",
        "ancestors=$chain",
        "started=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        "cwd=$((Get-Location).Path)",
        "host=$([Environment]::MachineName)",
        "command=$((Format-Command $TaskCmd))"
    )
    $tmp = "$HolderFile.tmp"
    Write-Utf8 $tmp (($lines -join "`n") + "`n")
    Move-Item -Path $tmp -Destination $HolderFile -Force
}

function Write-Waiter([string]$TaskName) {
    $path = Join-Path $WaiterDir "$PID.waiter"
    $lines = @(
        "task=$TaskName",
        "pid=$PID",
        "since=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        "cwd=$((Get-Location).Path)"
    )
    Write-Utf8 $path (($lines -join "`n") + "`n")
    return $path
}

function Write-History([string]$Event, $Rc, [hashtable]$Extra) {
    $obj = [ordered]@{
        at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        event = $Event
        task = $script:TaskName
        pid = $PID
        rc = $Rc
    }
    if ($Extra) {
        foreach ($key in $Extra.Keys) { $obj[$key] = $Extra[$key] }
    }
    $line = $obj | ConvertTo-Json -Compress
    [System.IO.File]::AppendAllText($HistoryFile, $line + "`n", $Utf8NoBom)
}

function Prune-Waiters {
    if (-not (Test-Path $WaiterDir)) { return }
    Get-ChildItem -Path $WaiterDir -Filter '*.waiter' -ErrorAction SilentlyContinue | ForEach-Object {
        $pidText = $_.BaseName
        if ($pidText -notmatch '^\d+$') { return }
        $proc = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
        if (-not $proc) { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Print-Status {
    New-Item -ItemType Directory -Force -Path $QueueDir | Out-Null
    New-Item -ItemType Directory -Force -Path $WaiterDir | Out-Null
    Prune-Waiters
    $script:Lock = Try-AcquireLock
    if ($null -eq $script:Lock) {
        Write-Host 'resource-queue: busy'
        if (Test-Path $HolderFile) { Get-Content $HolderFile | ForEach-Object { Write-Host "  $_" } }
        $waiters = @(Get-ChildItem -Path $WaiterDir -Filter '*.waiter' -ErrorAction SilentlyContinue)
        foreach ($waiter in $waiters) {
            Write-Host "  waiting: pid $($waiter.BaseName): $((Get-Content $waiter.FullName) -join ' ')"
        }
        if ($waiters.Count -gt 0) { Write-Host "  queued behind: $($waiters.Count) task(s)" }
    } else {
        Write-Host 'resource-queue: idle'
        $script:Lock.Dispose()
        $script:Lock = $null
        if (Test-Path $HolderFile) { Write-Host '  (stale holder state; the lock is free, so it is ignored)' }
    }
    if (Test-Path $HistoryFile) {
        $last = Get-Content -Tail 1 $HistoryFile -ErrorAction SilentlyContinue
        if ($last) { Write-Host "  last: $last" }
    }
    Write-Host "  state: $QueueDir"
}

function Print-History([int]$Count) {
    if (-not (Test-Path $HistoryFile)) {
        Write-Host "resource-queue: no history yet ($HistoryFile)"
        return
    }
    Get-Content -Tail $Count $HistoryFile
}

function Invoke-TaskCommand([string[]]$TaskCmd) {
    $exe = [string]$TaskCmd[0]
    $exeArgs = @()
    if ($TaskCmd.Count -gt 1) { $exeArgs = @($TaskCmd[1..($TaskCmd.Count - 1)]) }
    $global:LASTEXITCODE = 0
    & $exe @exeArgs
    $ok = $?
    if (-not $ok) {
        if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { return [int]$LASTEXITCODE }
        return 1
    }
    if ($null -ne $LASTEXITCODE) { return [int]$LASTEXITCODE }
    return 0
}

# --- parse and dispatch -----------------------------------------------------

$State = Parse-Arguments
switch ($State.Action) {
    'status' { Print-Status; exit 0 }
    'list' { Write-Output (Get-TaskList); exit 0 }
    'history' { Print-History ([int]$State.HistoryN); exit 0 }
    'help' { Write-Output (Get-Usage); exit 0 }
}

if (-not $State.Task) {
    [Console]::Error.WriteLine('run-resource-intensive-task: no task given')
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('Queue any resource-heavy command with:')
    [Console]::Error.WriteLine('  .\run-resource-intensive-task.ps1 --cmd -- CMD [ARG...]')
    [Console]::Error.WriteLine('The repository task catalogue is listed by --list.')
    exit 2
}

$script:TaskName = [string]$State.TaskName
$TaskCmd = @(Build-TaskCommand $State)
if (-not $script:TaskName) {
    $script:TaskName = [System.IO.Path]::GetFileNameWithoutExtension([string]$TaskCmd[0])
}
if (-not $script:TaskName) { $script:TaskName = 'raw' }

if ($State.DryRun) {
    Write-Host ("resource-queue: would run: " + (Format-Command $TaskCmd))
    exit 0
}

if ($env:RESOURCE_QUEUE_DISABLE -eq '1') {
    [Console]::Error.WriteLine("resource-queue: WARNING: queue disabled, running '$script:TaskName' WITHOUT the lock")
    $directRc = Invoke-TaskCommand $TaskCmd
    exit $directRc
}

New-Item -ItemType Directory -Force -Path $QueueDir | Out-Null
New-Item -ItemType Directory -Force -Path $WaiterDir | Out-Null

$waitStart = Get-Date
$script:Lock = Try-AcquireLock
$waiterPath = $null
if ($null -eq $script:Lock) {
    if (-not $State.Wait) {
        [Console]::Error.WriteLine("resource-queue: busy, '$script:TaskName' not started (--no-wait)")
        if (Test-Path $HolderFile) { Get-Content $HolderFile | ForEach-Object { [Console]::Error.WriteLine("  $_") } }
        exit 75
    }
    $waiterPath = Write-Waiter $script:TaskName
    $holderTask = ''
    $holderPid = ''
    if (Test-Path $HolderFile) {
        foreach ($line in Get-Content $HolderFile) {
            if ($line -like 'task=*') { $holderTask = $line.Substring(5) }
            if ($line -like 'pid=*') { $holderPid = $line.Substring(4) }
        }
    }
    if ($holderTask) {
        Write-Host "resource-queue: waiting for $holderTask (pid $holderPid); queued as pid $PID"
    } else {
        Write-Host "resource-queue: waiting for the resource queue lock; queued as pid $PID"
    }
    while ($null -eq $script:Lock) {
        if ($State.Timeout -gt 0 -and ((Get-Date) - $waitStart).TotalSeconds -ge $State.Timeout) {
            Remove-Item $waiterPath -Force -ErrorAction SilentlyContinue
            [Console]::Error.WriteLine("resource-queue: timed out after $($State.Timeout)s waiting for the lock")
            exit 75
        }
        Start-Sleep -Seconds 1
        $script:Lock = Try-AcquireLock
    }
    if ($waiterPath) { Remove-Item $waiterPath -Force -ErrorAction SilentlyContinue }
}

$waited = [int]((Get-Date) - $waitStart).TotalSeconds
$start = Get-Date
Write-Holder $script:TaskName $TaskCmd
Write-History 'start' $null @{ waited_s = $waited }
if (-not $State.Quiet) {
    Write-Host "resource-queue: $script:TaskName running (pid $PID, waited ${waited}s)"
}

# The marker is what a POSIX monitor looks for; on Windows the monitor follows
# the holder tree instead. Both make queued work invisible to the gate.
$env:RESOURCE_QUEUE_HELD = '1'
$env:RESOURCE_QUEUE_TASK = $script:TaskName
$env:RESOURCE_QUEUE_PID = [string]$PID

$rc = 0
try {
    $rc = Invoke-TaskCommand $TaskCmd
} catch {
    [Console]::Error.WriteLine("resource-queue: task failed: $($_.Exception.Message)")
    $rc = 1
} finally {
    $duration = [int]((Get-Date) - $start).TotalSeconds
    Write-History 'finish' $rc @{ duration_s = $duration; waited_s = $waited }
    if (Test-Path $HolderFile) {
        Copy-Item -Path $HolderFile -Destination $LastHolderFile -Force -ErrorAction SilentlyContinue
        Remove-Item $HolderFile -Force -ErrorAction SilentlyContinue
    }
    if ($script:Lock) {
        $script:Lock.Dispose()
        $script:Lock = $null
    }
    if (-not $State.Quiet) {
        Write-Host "resource-queue: $script:TaskName exit $rc (${duration}s)"
    }
}

exit $rc
