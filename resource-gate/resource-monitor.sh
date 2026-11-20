#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# resource-monitor.sh — wave guard for CPU, RAM and disk pressure.
#
# Run this before a wave of parallel subagents. It samples the machine, prints
# one line per sample with a `parallel=N` recommendation, and exits 3 with an
# alert JSON when a limit stays exceeded for --streak consecutive samples.
#
# How to use it (orchestrating agent):
#   1. Define the wave limits once for this repository:
#        ./resource-monitor.sh --init --cpu-percent 85 --ram-percent 80 \
#          --disk-percent 90 --streak 3
#   2. Start the monitor in the background before the first wave:
#        ./resource-monitor.sh --json --log .tmp/resource-monitor/monitor.log &
#   3. Spawn at most `parallel=` subagents, from the latest sample.
#   4. On exit code 3, stop spawning, read the alert JSON and follow its
#      `required_action`. Restart the monitor only after two clean samples.
#
# The recommendation only counts processes that are not part of the resource
# queue (see run-resource-intensive-task.sh), so queued heavy work cannot make
# the monitor blame the wave. Override the per-subagent assumptions with
# RESOURCE_MONITOR_AGENT_CPU_PERCENT / RESOURCE_MONITOR_AGENT_RAM_MB.
#
# Linux only: it reads /proc and needs flock and df. On Windows use the
# PowerShell port in this folder.
#
# Usage:
#   resource-monitor.sh [options]
#
# Options:
#   --interval SECS        sample period (default 6, saved)
#   --cpu-percent N        unqueued CPU ceiling, % of all cores (saved)
#   --ram-percent N        unqueued RAM ceiling, % of MemTotal (saved)
#   --disk-percent N       used-space ceiling for watched filesystems (saved)
#   --disk-write-mb N      unqueued writes per sample that count as pressure (saved)
#   --streak N             consecutive samples over a limit before alerting (saved)
#   --init                 save the supplied limits and exit
#   --path PATH            filesystem to watch; repeatable
#   --state-dir DIR        lock, limits, alert and scratch state
#                          (default <repo>/.tmp/resource-monitor)
#   --alert-file FILE      alert JSON path (default <state-dir>/alert.json)
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
#                                    run-resource-intensive-task.sh (default:
#                                    <git-common-dir>/resource-queue)
#   RESOURCE_MONITOR_DIR             default for --state-dir
#   RESOURCE_MONITOR_LIMITS_FILE     default for the saved limits file
#                                    (default <state-dir>/limits)
#   RESOURCE_MONITOR_INTERVAL        default for --interval
#   RESOURCE_MONITOR_CPU_PERCENT     default for --cpu-percent
#   RESOURCE_MONITOR_RAM_PERCENT     default for --ram-percent
#   RESOURCE_MONITOR_DISK_PERCENT    default for --disk-percent
#   RESOURCE_MONITOR_DISK_WRITE_MB   default for --disk-write-mb
#   RESOURCE_MONITOR_STREAK          default for --streak
#   RESOURCE_MONITOR_MAX_PARALLEL    hard cap on the recommendation (default 6)
#   RESOURCE_MONITOR_AGENT_CPU_PERCENT  CPU one subagent is assumed to use (100)
#   RESOURCE_MONITOR_AGENT_RAM_MB    RAM one subagent is assumed to use (2048)

set -euo pipefail

usage() {
  awk '/^# Usage:/{show=1} show && !/^#/{exit} show{print}' "$0" \
    | sed -e 's/^# \{0,1\}//' -e '/^$/d'
}

die() {
  printf 'resource-monitor.sh: %s\n' "$*" >&2
  exit 2
}

# --- localization ----------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# The repository this checkout was cloned into is the one to watch and queue
# for. The checkout may itself be a git repository (a nested clone), so start
# above it and take the first git top level instead of the checkout's own root.
resolve_repo_root() {
  if [[ -n "${RESOURCE_GATE_REPO_ROOT:-}" ]]; then
    printf '%s\n' "$RESOURCE_GATE_REPO_ROOT"
    return 0
  fi
  local dir
  dir="$(cd -- "$TOOLS_DIR/.." && pwd)"
  while :; do
    if git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
      git -C "$dir" rev-parse --show-toplevel
      return 0
    fi
    [[ "$dir" == "/" ]] && break
    dir="$(dirname -- "$dir")"
  done
  if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$PWD" rev-parse --show-toplevel
    return 0
  fi
  printf '%s\n' "$(cd -- "$TOOLS_DIR/.." && pwd)"
}

REPO_ROOT="$(resolve_repo_root)"

# Queue state lives beside the git common dir, not inside the checkout, so
# every worktree of the repository shares one lock. RESOURCE_QUEUE_DIR
# overrides it (absolute, or relative to the repository root).
resolve_queue_dir() {
  local override="${RESOURCE_QUEUE_DIR:-}"
  if [[ -n "$override" ]]; then
    [[ "$override" = /* ]] || override="$REPO_ROOT/$override"
    printf '%s\n' "$override"
    return 0
  fi
  local common
  common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)" || common=""
  if [[ -n "$common" ]]; then
    [[ "$common" = /* ]] || common="$REPO_ROOT/$common"
    if common="$(cd -- "$common" 2>/dev/null && pwd)"; then
      printf '%s/resource-queue\n' "$common"
      return 0
    fi
  fi
  printf '%s/.resource-queue\n' "$REPO_ROOT"
}

QUEUE_DIR="$(resolve_queue_dir)"
LOCK_FILE="$QUEUE_DIR/lock"
HOLDER_FILE="$QUEUE_DIR/holder"
LAST_HOLDER_FILE="$QUEUE_DIR/last-holder"

# --- inputs ----------------------------------------------------------------

STATE_DIR="${RESOURCE_MONITOR_DIR:-$REPO_ROOT/.tmp/resource-monitor}"
ALERT_FILE=""
LOG_FILE=""
WATCH_PATHS=()
ONCE=0
MAX_SAMPLES=0
JSON=0
QUIET=0
USE_LOCK=1
INIT_LIMITS=0

ARG_INTERVAL=""
ARG_CPU_LIMIT=""
ARG_RAM_LIMIT=""
ARG_DISK_LIMIT=""
ARG_DISK_WRITE_MB=""
ARG_STREAK=""

ENV_INTERVAL="${RESOURCE_MONITOR_INTERVAL:-}"
ENV_CPU_LIMIT="${RESOURCE_MONITOR_CPU_PERCENT:-}"
ENV_RAM_LIMIT="${RESOURCE_MONITOR_RAM_PERCENT:-}"
ENV_DISK_LIMIT="${RESOURCE_MONITOR_DISK_PERCENT:-}"
ENV_DISK_WRITE_MB="${RESOURCE_MONITOR_DISK_WRITE_MB:-}"
ENV_STREAK="${RESOURCE_MONITOR_STREAK:-}"

FILE_INTERVAL=""
FILE_CPU_LIMIT=""
FILE_RAM_LIMIT=""
FILE_DISK_LIMIT=""
FILE_DISK_WRITE_MB=""
FILE_STREAK=""

while (( $# > 0 )); do
  case "$1" in
    --interval) (( $# >= 2 )) || die "--interval needs a value"; ARG_INTERVAL="$2"; shift 2 ;;
    --cpu-percent) (( $# >= 2 )) || die "--cpu-percent needs a value"; ARG_CPU_LIMIT="$2"; shift 2 ;;
    --ram-percent) (( $# >= 2 )) || die "--ram-percent needs a value"; ARG_RAM_LIMIT="$2"; shift 2 ;;
    --disk-percent) (( $# >= 2 )) || die "--disk-percent needs a value"; ARG_DISK_LIMIT="$2"; shift 2 ;;
    --disk-write-mb) (( $# >= 2 )) || die "--disk-write-mb needs a value"; ARG_DISK_WRITE_MB="$2"; shift 2 ;;
    --streak) (( $# >= 2 )) || die "--streak needs a value"; ARG_STREAK="$2"; shift 2 ;;
    --path) (( $# >= 2 )) || die "--path needs a value"; WATCH_PATHS+=("$2"); shift 2 ;;
    --state-dir) (( $# >= 2 )) || die "--state-dir needs a value"; STATE_DIR="$2"; shift 2 ;;
    --alert-file) (( $# >= 2 )) || die "--alert-file needs a value"; ALERT_FILE="$2"; shift 2 ;;
    --log) (( $# >= 2 )) || die "--log needs a value"; LOG_FILE="$2"; shift 2 ;;
    --init) INIT_LIMITS=1; shift ;;
    --once) ONCE=1; shift ;;
    --max-samples) (( $# >= 2 )) || die "--max-samples needs a value"; MAX_SAMPLES="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    --quiet|-q) QUIET=1; shift ;;
    --no-lock) USE_LOCK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

# Resolve the state paths against the repository root so a monitor started from
# any working directory reads and writes the same state.
resolve_path() {
  local p="$1"
  if [[ "$p" == /* ]]; then
    printf '%s\n' "$p"
  else
    printf '%s\n' "$REPO_ROOT/$p"
  fi
}

STATE_DIR="$(resolve_path "$STATE_DIR")"
if [[ -n "$ALERT_FILE" ]]; then
  ALERT_FILE="$(resolve_path "$ALERT_FILE")"
fi
if [[ -n "$LOG_FILE" ]]; then
  LOG_FILE="$(resolve_path "$LOG_FILE")"
fi
LIMITS_FILE="${RESOURCE_MONITOR_LIMITS_FILE:-$STATE_DIR/limits}"
LIMITS_FILE="$(resolve_path "$LIMITS_FILE")"

load_limits_file() {
  [[ -f "$LIMITS_FILE" ]] || return 1
  local key value
  while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
    key="${key//[[:space:]]/}"
    value="${value//[[:space:]]/}"
    [[ -z "$key" || "$key" == \#* ]] && continue
    case "$key" in
      interval) FILE_INTERVAL="$value" ;;
      cpu_percent) FILE_CPU_LIMIT="$value" ;;
      ram_percent) FILE_RAM_LIMIT="$value" ;;
      disk_percent) FILE_DISK_LIMIT="$value" ;;
      disk_write_mb) FILE_DISK_WRITE_MB="$value" ;;
      streak) FILE_STREAK="$value" ;;
    esac
  done <"$LIMITS_FILE"
  return 0
}

HAS_LIMITS_FILE=0
if load_limits_file; then
  HAS_LIMITS_FILE=1
fi

pick() {
  local arg="${1:-}" env="${2:-}" file="${3:-}" fallback="${4:-}"
  if [[ -n "$arg" ]]; then
    printf '%s' "$arg"
  elif [[ -n "$env" ]]; then
    printf '%s' "$env"
  elif [[ -n "$file" ]]; then
    printf '%s' "$file"
  else
    printf '%s' "$fallback"
  fi
}

INTERVAL="$(pick "$ARG_INTERVAL" "$ENV_INTERVAL" "$FILE_INTERVAL" 6)"
CPU_LIMIT="$(pick "$ARG_CPU_LIMIT" "$ENV_CPU_LIMIT" "$FILE_CPU_LIMIT" "")"
RAM_LIMIT="$(pick "$ARG_RAM_LIMIT" "$ENV_RAM_LIMIT" "$FILE_RAM_LIMIT" "")"
DISK_LIMIT="$(pick "$ARG_DISK_LIMIT" "$ENV_DISK_LIMIT" "$FILE_DISK_LIMIT" "")"
DISK_WRITE_MB="$(pick "$ARG_DISK_WRITE_MB" "$ENV_DISK_WRITE_MB" "$FILE_DISK_WRITE_MB" 512)"
STREAK="$(pick "$ARG_STREAK" "$ENV_STREAK" "$FILE_STREAK" "")"

if [[ -z "$CPU_LIMIT" || -z "$RAM_LIMIT" || -z "$DISK_LIMIT" || -z "$STREAK" ]]; then
  cat >&2 <<EOF
resource-monitor.sh: resource-monitor warning limits are not defined.
The orchestrator needs to define the limits for the resource monitor warnings before starting a wave.
Define them once with:
  $0 --cpu-percent N --ram-percent N --disk-percent N --streak N [--disk-write-mb N]
The limits are saved to $LIMITS_FILE.
EOF
  exit 2
fi

for pair in "interval:$INTERVAL" "cpu-percent:$CPU_LIMIT" "ram-percent:$RAM_LIMIT" \
            "disk-percent:$DISK_LIMIT" "disk-write-mb:$DISK_WRITE_MB" "streak:$STREAK" \
            "max-samples:$MAX_SAMPLES"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name needs a whole number"
done
(( INTERVAL >= 1 )) || die "--interval must be at least 1"
(( STREAK >= 1 )) || die "--streak must be at least 1"
(( CPU_LIMIT >= 1 && CPU_LIMIT <= 100 )) || die "--cpu-percent must be 1..100"
(( RAM_LIMIT >= 1 && RAM_LIMIT <= 100 )) || die "--ram-percent must be 1..100"
(( DISK_LIMIT >= 1 && DISK_LIMIT <= 100 )) || die "--disk-percent must be 1..100"

save_limits() {
  mkdir -p "$(dirname -- "$LIMITS_FILE")"
  local tmp="$LIMITS_FILE.tmp.$$"
  {
    printf '# resource-monitor limits (untracked)\n'
    printf 'interval=%s\n' "$INTERVAL"
    printf 'cpu_percent=%s\n' "$CPU_LIMIT"
    printf 'ram_percent=%s\n' "$RAM_LIMIT"
    printf 'disk_percent=%s\n' "$DISK_LIMIT"
    printf 'disk_write_mb=%s\n' "$DISK_WRITE_MB"
    printf 'streak=%s\n' "$STREAK"
  } >"$tmp"
  mv -f "$tmp" "$LIMITS_FILE"
}

# The first configured run defines the wave limits. Later runs read them; only
# an explicit --init rewrites the file, so a one-off spot check cannot silently
# change the limits a wave is using.
if (( HAS_LIMITS_FILE == 0 || INIT_LIMITS == 1 )); then
  save_limits
fi

if (( INIT_LIMITS == 1 )); then
  printf 'resource-monitor: saved limits to %s\n' "$LIMITS_FILE"
  exit 0
fi

# Recommendation assumptions (not warning limits).
MAX_PARALLEL="${RESOURCE_MONITOR_MAX_PARALLEL:-6}"
AGENT_CPU_PERCENT="${RESOURCE_MONITOR_AGENT_CPU_PERCENT:-100}"
AGENT_RAM_MB="${RESOURCE_MONITOR_AGENT_RAM_MB:-2048}"

# A one-shot check is not a monitor; it may run while the wave monitor is alive.
if (( ONCE == 1 )); then
  USE_LOCK=0
fi

cd "$REPO_ROOT"

if (( ${#WATCH_PATHS[@]} == 0 )); then
  WATCH_PATHS=("$REPO_ROOT" "${TMPDIR:-/tmp}")
fi

if [[ -z "$ALERT_FILE" ]]; then
  ALERT_FILE="$STATE_DIR/alert.json"
fi

mkdir -p "$STATE_DIR" "$(dirname -- "$ALERT_FILE")"
TMP_DIR="$STATE_DIR/tmp"
mkdir -p "$TMP_DIR"
if [[ -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname -- "$LOG_FILE")"
  : >>"$LOG_FILE"
fi

# --- platform and identity -------------------------------------------------

command -v flock >/dev/null 2>&1 || {
  echo "resource-monitor.sh: 'flock' is required (util-linux; Linux/WSL has it)." >&2
  exit 1
}
command -v df >/dev/null 2>&1 || {
  echo "resource-monitor.sh: 'df' is required." >&2
  exit 1
}

HZ="$(getconf CLK_TCK 2>/dev/null || echo 100)"
PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo 4096)"
NCPU="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
[[ "$HZ" =~ ^[0-9]+$ ]] && (( HZ > 0 )) || HZ=100
[[ "$PAGE_SIZE" =~ ^[0-9]+$ ]] && (( PAGE_SIZE > 0 )) || PAGE_SIZE=4096
[[ "$NCPU" =~ ^[0-9]+$ ]] && (( NCPU > 0 )) || NCPU=1

P_PPID=0
P_PGRP=0
P_TICKS=0
P_RSS=0

parse_stat() {
  local pid="$1" line rest
  P_PPID=0
  P_PGRP=0
  P_TICKS=0
  P_RSS=0
  IFS= read -r line 2>/dev/null <"/proc/$pid/stat" || return 1
  rest="${line##*) }"
  local -a fields=()
  read -r -a fields <<<"$rest"
  (( ${#fields[@]} >= 22 )) || return 1
  P_PPID="${fields[1]}"
  P_PGRP="${fields[2]}"
  P_TICKS=$(( fields[11] + fields[12] ))
  P_RSS=$(( fields[21] * PAGE_SIZE ))
  return 0
}

MEM_TOTAL_BYTES=0
MEM_AVAILABLE_BYTES=0

read_meminfo() {
  local key val
  MEM_TOTAL_BYTES=0
  MEM_AVAILABLE_BYTES=0
  while IFS=: read -r key val; do
    case "$key" in
      MemTotal|MemAvailable)
        val="${val//[!0-9]/}"
        [[ -n "$val" ]] || continue
        if [[ "$key" == "MemTotal" ]]; then
          MEM_TOTAL_BYTES=$(( val * 1024 ))
        else
          MEM_AVAILABLE_BYTES=$(( val * 1024 ))
        fi
        ;;
    esac
  done < /proc/meminfo
}

# The monitor, its parent shell, and the orchestrator ancestors above it are
# never kill candidates and their own I/O is not counted. Linux adds a
# child's I/O to the parent when the child exits, so this also keeps a queued
# task's writes from being blamed on the shell that launched the monitor.
SAFE_PGIDS=()

collect_safe_pids() {
  local pid=$$ depth=0
  while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 && depth < 32 )); do
    if parse_stat "$pid" 2>/dev/null; then
      if [[ "$P_PGRP" =~ ^[0-9]+$ ]]; then
        SAFE_PGIDS+=("$P_PGRP")
      fi
      pid="$P_PPID"
    else
      break
    fi
    depth=$((depth + 1))
  done
}
collect_safe_pids

if (( USE_LOCK == 1 )); then
  exec 7>>"$STATE_DIR/monitor.lock"
  if ! flock -n 7; then
    printf 'resource-monitor: another monitor is already running for %s\n' "$STATE_DIR" >&2
    exit 4
  fi
  # Do not let a stale alert from the previous wave look like a new one.
  rm -f "$ALERT_FILE"
fi

# --- logging ---------------------------------------------------------------

log_line() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  if (( JSON == 1 )); then
    # Keep stdout valid JSONL; human progress goes to the log/stderr.
    printf '%s\n' "$line" >&2
  elif (( QUIET == 0 )); then
    printf '%s\n' "$line"
  fi
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

alert_line() {
  local line="$*"
  if (( JSON == 1 )); then
    printf '%s\n' "$line" >&2
  else
    printf '%s\n' "$line"
  fi
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>"$LOG_FILE"
  fi
}

SLEEP_PID=""

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$SLEEP_PID" ]]; then
    kill "$SLEEP_PID" 2>/dev/null || true
  fi
  rm -f "$TMP_DIR"/top.* 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT
trap 'log_line "resource-monitor: stopping (signal)"; exit 0' INT TERM

# --- /proc readers ---------------------------------------------------------

is_queue_marked() {
  local pid="$1" entry
  local -a envs=()
  mapfile -d '' -t envs 2>/dev/null <"/proc/$pid/environ" || true
  for entry in "${envs[@]}"; do
    case "$entry" in
      RESOURCE_QUEUE_HELD=1) return 0 ;;
    esac
  done
  return 1
}

# --- queue state -----------------------------------------------------------

QUEUE_ACTIVE=0
QUEUE_TASK=""
QUEUE_PID=""
QUEUE_PPID=""
QUEUE_ANCESTORS=""

queue_state() {
  QUEUE_ACTIVE=0
  QUEUE_TASK=""
  QUEUE_PID=""
  QUEUE_PPID=""
  QUEUE_ANCESTORS=""
  if [[ -f "$HOLDER_FILE" ]]; then
    QUEUE_TASK="$(sed -n 's/^task=//p' "$HOLDER_FILE" 2>/dev/null || true)"
    QUEUE_PID="$(sed -n 's/^pid=//p' "$HOLDER_FILE" 2>/dev/null || true)"
    QUEUE_PPID="$(sed -n 's/^ppid=//p' "$HOLDER_FILE" 2>/dev/null || true)"
    QUEUE_ANCESTORS="$(sed -n 's/^ancestors=//p' "$HOLDER_FILE" 2>/dev/null || true)"
  fi
  if [[ -e "$LOCK_FILE" ]]; then
    exec 8>>"$LOCK_FILE"
    if ! flock -n 8; then
      QUEUE_ACTIVE=1
    fi
    exec 8>&-
  elif [[ "$QUEUE_PID" =~ ^[0-9]+$ ]] && kill -0 "$QUEUE_PID" 2>/dev/null; then
    QUEUE_ACTIVE=1
  fi
}

# --- sampling --------------------------------------------------------------

declare -A CUR_PPID=() CUR_PGRP=() CUR_TICKS=() CUR_RSS=() CUR_MEM=()
declare -A CUR_IO=() CUR_CMD=() CUR_EXEMPT=() CUR_CPU_DELTA=()
CUR_PIDS=()
declare -A PREV_TICKS=() PREV_IO=() PREV_EXEMPT=()
PREV_NS=0

# PIDs of shells above a queue holder are exempt for this many samples. Linux
# charges a child's I/O to its parent when the child is reaped, so the parent's
# next cumulative-I/O delta can contain the queue task's writes even though the
# queue is already idle. The queue script leaves last-holder (with ppid) behind
# so short tasks that start and finish between samples are covered too.
QUEUE_GRACE_SAMPLES=3
declare -A QUEUE_ANCESTOR_TTL=()
LAST_HOLDER_SEEN=""

mark_ancestor_list() {
  local list="${1:-}" entry
  local -a entries=()
  [[ -n "$list" ]] || return 0
  IFS=',' read -r -a entries <<<"$list"
  for entry in "${entries[@]}"; do
    [[ "$entry" =~ ^[0-9]+$ ]] || continue
    QUEUE_ANCESTOR_TTL[$entry]=$QUEUE_GRACE_SAMPLES
  done
}

mark_queue_ancestors() {
  local pid="" depth=0 parent ppid mtime ttl list
  if [[ "$QUEUE_PID" =~ ^[0-9]+$ ]] && kill -0 "$QUEUE_PID" 2>/dev/null; then
    # The holder records the chain at start; walking it again also catches a
    # parent that changed after the task began.
    mark_ancestor_list "$QUEUE_ANCESTORS"
    pid="$QUEUE_PID"
  elif [[ -f "$LAST_HOLDER_FILE" ]]; then
    mtime="$(stat -c '%i:%Y' "$LAST_HOLDER_FILE" 2>/dev/null || echo "")"
    if [[ -n "$mtime" && "$mtime" != "$LAST_HOLDER_SEEN" ]]; then
      LAST_HOLDER_SEEN="$mtime"
      list="$(sed -n 's/^ancestors=//p' "$LAST_HOLDER_FILE" 2>/dev/null || true)"
      mark_ancestor_list "$list"
      ppid="$(sed -n 's/^ppid=//p' "$LAST_HOLDER_FILE" 2>/dev/null || true)"
      if [[ "$ppid" =~ ^[0-9]+$ ]]; then
        pid="$ppid"
      fi
    fi
  fi

  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    while (( depth < 64 )); do
      parent="${CUR_PPID[$pid]:-0}"
      [[ -z "$parent" || "$parent" == "0" ]] && break
      QUEUE_ANCESTOR_TTL[$parent]=$QUEUE_GRACE_SAMPLES
      pid="$parent"
      depth=$((depth + 1))
    done
  fi

  for pid in "${!QUEUE_ANCESTOR_TTL[@]}"; do
    if [[ -n "${CUR_PPID[$pid]:-}" ]]; then
      CUR_EXEMPT[$pid]=1
    fi
    ttl=$(( QUEUE_ANCESTOR_TTL[$pid] - 1 ))
    if (( ttl > 0 )); then
      QUEUE_ANCESTOR_TTL[$pid]=$ttl
    else
      unset "QUEUE_ANCESTOR_TTL[$pid]"
    fi
  done
}

sample_processes() {
  local d pid mem key val cmd
  CUR_PIDS=()
  CUR_PPID=()
  CUR_PGRP=()
  CUR_TICKS=()
  CUR_RSS=()
  CUR_MEM=()
  CUR_IO=()
  CUR_CMD=()
  CUR_EXEMPT=()

  for d in /proc/[0-9]*; do
    pid="${d##*/}"
    parse_stat "$pid" || continue
    CUR_PIDS+=("$pid")
    CUR_PPID[$pid]="$P_PPID"
    CUR_PGRP[$pid]="$P_PGRP"
    CUR_TICKS[$pid]="$P_TICKS"
    CUR_RSS[$pid]="$P_RSS"

    # PSS is proportional and does not double-count shared pages, but reading
    # smaps_rollup for every process is expensive. Use it only for processes
    # large enough to matter; small processes use RSS from /proc/pid/stat.
    mem="$P_RSS"
    if (( P_RSS >= 16777216 )) && [[ -r "/proc/$pid/smaps_rollup" ]]; then
      while IFS=: read -r key val; do
        if [[ "$key" == "Pss" ]]; then
          val="${val//[!0-9]/}"
          [[ -n "$val" ]] && mem=$(( val * 1024 ))
          break
        fi
      done 2>/dev/null <"/proc/$pid/smaps_rollup" || true
    fi
    CUR_MEM[$pid]="$mem"

    CUR_IO[$pid]=0
    if [[ -r "/proc/$pid/io" ]]; then
      while IFS=: read -r key val; do
        if [[ "$key" == "write_bytes" ]]; then
          val="${val//[!0-9]/}"
          [[ -n "$val" ]] && CUR_IO[$pid]="$val"
          break
        fi
      done 2>/dev/null <"/proc/$pid/io" || true
    fi

    if is_queue_marked "$pid"; then
      CUR_EXEMPT[$pid]=1
    else
      CUR_EXEMPT[$pid]=0
    fi

    cmd=""
    if [[ -r "/proc/$pid/cmdline" ]]; then
      cmd="$(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" || true)"
      cmd="${cmd% }"
    fi
    if [[ -z "$cmd" ]]; then
      cmd="[$(cat "/proc/$pid/comm" 2>/dev/null || echo "pid $pid")]"
    fi
    CUR_CMD[$pid]="${cmd:0:240}"
  done

  # The monitor's own sampling work must not count against the machine.
  for pid in "${CUR_PIDS[@]}"; do
    if [[ "$pid" == "$$" ]] || is_descendant "$pid" "$$"; then
      CUR_EXEMPT[$pid]=1
    fi
  done
  mark_queue_ancestors

  # A process that lost the marker (or a child that cleared it) is still part of
  # the queue holder's tree.
  if [[ "$QUEUE_PID" =~ ^[0-9]+$ ]] && kill -0 "$QUEUE_PID" 2>/dev/null; then
    for pid in "${CUR_PIDS[@]}"; do
      if [[ "$pid" == "$QUEUE_PID" ]] || is_descendant "$pid" "$QUEUE_PID"; then
        CUR_EXEMPT[$pid]=1
      fi
    done
  fi
}

is_descendant() {
  local pid="$1" root="$2" depth=0 parent
  while (( depth < 64 )); do
    parent="${CUR_PPID[$pid]:-0}"
    [[ -z "$parent" || "$parent" == "0" ]] && return 1
    [[ "$parent" == "$root" ]] && return 0
    pid="$parent"
    depth=$((depth + 1))
  done
  return 1
}

CAPACITY_TICKS=0
M_CPU_TICKS=0
M_CPU_TENTHS=0
M_RAM_BYTES=0
M_RAM_TENTHS=0
M_WRITE_BYTES=0
M_WRITE_MB_TENTHS=0

compute_metrics() {
  local pid dticks dio elapsed_ns
  M_CPU_TICKS=0
  M_RAM_BYTES=0
  M_WRITE_BYTES=0
  CUR_CPU_DELTA=()

  for pid in "${CUR_PIDS[@]}"; do
    [[ "${CUR_EXEMPT[$pid]:-0}" == "1" ]] && continue
    M_RAM_BYTES=$(( M_RAM_BYTES + ${CUR_MEM[$pid]:-0} ))

    if [[ -n "${PREV_TICKS[$pid]:-}" && "${PREV_EXEMPT[$pid]:-0}" != "1" ]]; then
      dticks=$(( ${CUR_TICKS[$pid]:-0} - PREV_TICKS[$pid] ))
      if (( dticks > 0 )); then
        M_CPU_TICKS=$(( M_CPU_TICKS + dticks ))
        CUR_CPU_DELTA[$pid]="$dticks"
      fi
    fi
    if [[ -n "${PREV_IO[$pid]:-}" && "${PREV_EXEMPT[$pid]:-0}" != "1" ]]; then
      dio=$(( ${CUR_IO[$pid]:-0} - PREV_IO[$pid] ))
      if (( dio > 0 )); then
        M_WRITE_BYTES=$(( M_WRITE_BYTES + dio ))
      fi
    fi
  done

  elapsed_ns=0
  if (( PREV_NS > 0 )); then
    elapsed_ns=$(( NOW_NS - PREV_NS ))
  fi
  CAPACITY_TICKS=0
  M_CPU_TENTHS=0
  if (( elapsed_ns > 0 && NCPU > 0 && HZ > 0 )); then
    CAPACITY_TICKS=$(( HZ * NCPU * elapsed_ns / 1000000000 ))
    if (( CAPACITY_TICKS > 0 )); then
      M_CPU_TENTHS=$(( (M_CPU_TICKS * 1000 + CAPACITY_TICKS / 2) / CAPACITY_TICKS ))
    fi
  fi
  if (( M_CPU_TENTHS > 1000 )); then M_CPU_TENTHS=1000; fi

  if (( MEM_TOTAL_BYTES > 0 )); then
    M_RAM_TENTHS=$(( (M_RAM_BYTES * 1000 + MEM_TOTAL_BYTES / 2) / MEM_TOTAL_BYTES ))
  else
    M_RAM_TENTHS=0
  fi
  if (( M_RAM_TENTHS > 1000 )); then M_RAM_TENTHS=1000; fi

  M_WRITE_MB_TENTHS=$(( (M_WRITE_BYTES * 10 + 524288) / 1048576 ))
}

RECOMMENDED_PARALLEL=0

compute_recommendation() {
  local cpu_room_tenths by_cpu ram_room_bytes by_ram cap
  cpu_room_tenths=$(( CPU_LIMIT * 10 - M_CPU_TENTHS ))
  (( cpu_room_tenths < 0 )) && cpu_room_tenths=0
  if (( AGENT_CPU_PERCENT > 0 )); then
    by_cpu=$(( cpu_room_tenths * NCPU / (10 * AGENT_CPU_PERCENT) ))
  else
    by_cpu=$MAX_PARALLEL
  fi

  if (( MEM_TOTAL_BYTES > 0 && AGENT_RAM_MB > 0 )); then
    ram_room_bytes=$(( RAM_LIMIT * MEM_TOTAL_BYTES / 100 - M_RAM_BYTES ))
    (( ram_room_bytes < 0 )) && ram_room_bytes=0
    by_ram=$(( ram_room_bytes / (AGENT_RAM_MB * 1024 * 1024) ))
  else
    by_ram=$MAX_PARALLEL
  fi

  cap=$MAX_PARALLEL
  (( cap < 0 )) && cap=0
  RECOMMENDED_PARALLEL=$by_cpu
  (( by_ram < RECOMMENDED_PARALLEL )) && RECOMMENDED_PARALLEL=$by_ram
  (( RECOMMENDED_PARALLEL > cap )) && RECOMMENDED_PARALLEL=$cap
  (( RECOMMENDED_PARALLEL < 0 )) && RECOMMENDED_PARALLEL=0
  return 0
}

DISK_PATHS=()
DISK_TOTAL_BYTES=()
DISK_AVAIL_BYTES=()
DISK_USED_TENTHS=()
DISK_MAX_USED_TENTHS=0
DISK_MIN_AVAIL_BYTES=-1

sample_disks() {
  local p out fs total used avail pct mount key used_tenths i
  DISK_PATHS=()
  DISK_TOTAL_BYTES=()
  DISK_AVAIL_BYTES=()
  DISK_USED_TENTHS=()
  local -A seen=()

  for p in "${WATCH_PATHS[@]}"; do
    [[ -e "$p" ]] || continue
    out="$(df -P -B1 -- "$p" 2>/dev/null | tail -n 1 || true)"
    [[ -n "$out" ]] || continue
    read -r fs total used avail pct mount <<<"$out"
    [[ "$total" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]] || continue
    (( total > 0 )) || continue
    key="$fs|$total"
    [[ -n "${seen[$key]:-}" ]] && continue
    seen[$key]=1
    used_tenths=$(( ((total - avail) * 1000 + total / 2) / total ))
    DISK_PATHS+=("$p")
    DISK_TOTAL_BYTES+=("$total")
    DISK_AVAIL_BYTES+=("$avail")
    DISK_USED_TENTHS+=("$used_tenths")
  done

  DISK_MAX_USED_TENTHS=0
  DISK_MIN_AVAIL_BYTES=-1
  for i in "${!DISK_USED_TENTHS[@]}"; do
    if (( DISK_USED_TENTHS[i] > DISK_MAX_USED_TENTHS )); then
      DISK_MAX_USED_TENTHS="${DISK_USED_TENTHS[i]}"
    fi
    if (( DISK_MIN_AVAIL_BYTES < 0 || DISK_AVAIL_BYTES[i] < DISK_MIN_AVAIL_BYTES )); then
      DISK_MIN_AVAIL_BYTES="${DISK_AVAIL_BYTES[i]}"
    fi
  done
}

# --- streaks and output ----------------------------------------------------

CPU_STREAK=0
RAM_STREAK=0
DISK_STREAK=0
WRITE_STREAK=0
DISK_DEFERRED=0
OVER_CPU=0
OVER_RAM=0
OVER_DISK=0
OVER_WRITE=0

fmt_tenths() {
  local v="$1"
  printf '%d.%d' "$((v / 10))" "$((v % 10))"
}

fmt_mib() {
  local bytes="$1"
  printf '%d.%d' "$(( bytes / 1048576 ))" "$(( (bytes % 1048576) * 10 / 1048576 ))"
}

update_streaks() {
  OVER_CPU=0
  OVER_RAM=0
  OVER_DISK=0
  OVER_WRITE=0
  DISK_DEFERRED=0

  (( M_CPU_TENTHS >= CPU_LIMIT * 10 )) && OVER_CPU=1
  (( M_RAM_TENTHS >= RAM_LIMIT * 10 )) && OVER_RAM=1
  (( M_WRITE_MB_TENTHS >= DISK_WRITE_MB * 10 )) && OVER_WRITE=1

  if (( QUEUE_ACTIVE == 1 )); then
    # A queued build/test/export writes its output directories by design and
    # must not trip the disk check. Defer the used-space check while the queue
    # is busy; unmanaged writes are still counted.
    DISK_DEFERRED=1
    DISK_STREAK=0
  else
    (( DISK_MAX_USED_TENTHS >= DISK_LIMIT * 10 )) && OVER_DISK=1
    if (( OVER_DISK == 1 )); then DISK_STREAK=$((DISK_STREAK + 1)); else DISK_STREAK=0; fi
  fi

  if (( OVER_CPU == 1 )); then CPU_STREAK=$((CPU_STREAK + 1)); else CPU_STREAK=0; fi
  if (( OVER_RAM == 1 )); then RAM_STREAK=$((RAM_STREAK + 1)); else RAM_STREAK=0; fi
  if (( OVER_WRITE == 1 )); then WRITE_STREAK=$((WRITE_STREAK + 1)); else WRITE_STREAK=0; fi
}

queue_label() {
  if (( QUEUE_ACTIVE == 1 )); then
    printf 'busy(%s)' "${QUEUE_TASK:-?}"
  else
    printf 'idle'
  fi
}

emit_sample() {
  local at queue_at cpu ram write disk_text sample parallel
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  queue_at="$(queue_label)"
  cpu="$(fmt_tenths "$M_CPU_TENTHS")"
  ram="$(fmt_tenths "$M_RAM_TENTHS")"
  write="$(fmt_tenths "$M_WRITE_MB_TENTHS")"

  if (( DISK_MAX_USED_TENTHS > 0 )); then
    disk_text="$(fmt_tenths "$DISK_MAX_USED_TENTHS")%"
  else
    disk_text="n/a"
  fi
  if (( DISK_DEFERRED == 1 )); then
    disk_text="$disk_text deferred"
  fi

  if (( JSON == 1 )); then
    printf -v sample '{"at":"%s","event":"sample","cpu_percent":%s,"ram_percent":%s,"ram_bytes":%s,"mem_available_bytes":%s,"write_mb":%s,"disk_used_percent":%s,"disk_min_avail_bytes":%s,"disk_deferred":%s,"queue_active":%s,"queue_task":"%s","recommended_parallel_subagents":%s,"streaks":{"cpu":%s,"ram":%s,"disk":%s,"write":%s}}' \
      "$at" "$cpu" "$ram" "$M_RAM_BYTES" "$MEM_AVAILABLE_BYTES" "$write" \
      "$(fmt_tenths "$DISK_MAX_USED_TENTHS")" "$DISK_MIN_AVAIL_BYTES" \
      "$( (( DISK_DEFERRED == 1 )) && echo true || echo false )" \
      "$( (( QUEUE_ACTIVE == 1 )) && echo true || echo false )" \
      "$(json_escape "$QUEUE_TASK")" \
      "$RECOMMENDED_PARALLEL" \
      "$CPU_STREAK" "$RAM_STREAK" "$DISK_STREAK" "$WRITE_STREAK"
    printf '%s\n' "$sample"
    if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$sample" >>"$LOG_FILE"; fi
  else
    log_line "cpu=${cpu}% ram=${ram}% disk=${disk_text} write=${write}MB queue=${queue_at} parallel=${RECOMMENDED_PARALLEL}"
  fi
}

json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  s="${s//[[:cntrl:]]/ }"
  printf '%s' "$s"
}

TOP_PID=()
TOP_PPID=()
TOP_PGID=()
TOP_MEM=()
TOP_TICKS=()
TOP_CMD=()
TOP_CWD=()

collect_top_processes() {
  local tmp="$TMP_DIR/top.$$" pid ppid pgid mem ticks cmd cwd
  local -A seen_pid=()
  TOP_PID=()
  TOP_PPID=()
  TOP_PGID=()
  TOP_MEM=()
  TOP_TICKS=()
  TOP_CMD=()
  TOP_CWD=()

  : >"$tmp"
  for pid in "${CUR_PIDS[@]}"; do
    [[ "${CUR_EXEMPT[$pid]:-0}" == "1" ]] && continue
    ppid="${CUR_PPID[$pid]:-0}"
    pgid="${CUR_PGRP[$pid]:-0}"
    mem="${CUR_MEM[$pid]:-0}"
    ticks="${CUR_CPU_DELTA[$pid]:-0}"
    cmd="${CUR_CMD[$pid]:-}"
    cmd="${cmd//$'\t'/ }"
    cmd="${cmd//$'\n'/ }"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$pgid" "$mem" "$ticks" "$cmd" >>"$tmp"
  done

  while IFS=$'\t' read -r pid ppid pgid mem ticks cmd; do
    [[ -n "$pid" ]] || continue
    [[ -n "${seen_pid[$pid]:-}" ]] && continue
    seen_pid[$pid]=1
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo '?')"
    TOP_PID+=("$pid")
    TOP_PPID+=("$ppid")
    TOP_PGID+=("$pgid")
    TOP_MEM+=("$mem")
    TOP_TICKS+=("$ticks")
    TOP_CMD+=("$cmd")
    TOP_CWD+=("$cwd")
  done < <(
    sort -t $'\t' -k4,4nr "$tmp" 2>/dev/null | awk 'NR <= 8'
    sort -t $'\t' -k5,5nr "$tmp" 2>/dev/null | awk 'NR <= 8'
  )
  rm -f "$tmp"
}

REASONS=()

build_reasons() {
  REASONS=()
  if (( CPU_STREAK >= STREAK )); then
    REASONS+=("cpu $(fmt_tenths "$M_CPU_TENTHS")% >= ${CPU_LIMIT}% for ${CPU_STREAK} samples")
  fi
  if (( RAM_STREAK >= STREAK )); then
    REASONS+=("ram $(fmt_tenths "$M_RAM_TENTHS")% >= ${RAM_LIMIT}% for ${RAM_STREAK} samples")
  fi
  if (( DISK_STREAK >= STREAK )); then
    REASONS+=("disk $(fmt_tenths "$DISK_MAX_USED_TENTHS")% >= ${DISK_LIMIT}% for ${DISK_STREAK} samples")
  fi
  if (( WRITE_STREAK >= STREAK )); then
    REASONS+=("unmanaged writes $(fmt_tenths "$M_WRITE_MB_TENTHS")MB/sample >= ${DISK_WRITE_MB}MB for ${WRITE_STREAK} samples")
  fi
}

write_alert_json() {
  local at processes_json="" disk_json="" reasons_json="" protected_json="" sep i reason p
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # The monitor and its ancestors must never be kill targets. Add the queue
  # holder's group too when it is still alive.
  local -A seen_safe=()
  for p in "${SAFE_PGIDS[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    [[ -n "${seen_safe[$p]:-}" ]] && continue
    seen_safe[$p]=1
    protected_json+="${protected_json:+,}$p"
  done
  if [[ "$QUEUE_PID" =~ ^[0-9]+$ ]] && kill -0 "$QUEUE_PID" 2>/dev/null; then
    if parse_stat "$QUEUE_PID"; then
      p="$P_PGRP"
      if [[ "$p" =~ ^[0-9]+$ && -z "${seen_safe[$p]:-}" ]]; then
        seen_safe[$p]=1
        protected_json+="${protected_json:+,}$p"
      fi
    fi
  fi

  sep=""
  for i in "${!TOP_PID[@]}"; do
    local cpu_pct="0.0"
    if (( CAPACITY_TICKS > 0 )); then
      cpu_pct="$(fmt_tenths "$(( (TOP_TICKS[i] * 1000 + CAPACITY_TICKS / 2) / CAPACITY_TICKS ))")"
    fi
    processes_json+="${sep}{\"pid\":${TOP_PID[i]},\"ppid\":${TOP_PPID[i]},\"pgid\":${TOP_PGID[i]},\"rss_bytes\":${TOP_MEM[i]},\"cpu_percent\":${cpu_pct},\"cwd\":\"$(json_escape "${TOP_CWD[i]}")\",\"cmd\":\"$(json_escape "${TOP_CMD[i]}")\"}"
    sep=","
  done

  sep=""
  for i in "${!DISK_PATHS[@]}"; do
    disk_json+="${sep}{\"path\":\"$(json_escape "${DISK_PATHS[i]}")\",\"used_percent\":$(fmt_tenths "${DISK_USED_TENTHS[i]}"),\"avail_bytes\":${DISK_AVAIL_BYTES[i]},\"total_bytes\":${DISK_TOTAL_BYTES[i]}}"
    sep=","
  done

  sep=""
  for reason in "${REASONS[@]}"; do
    reasons_json+="${sep}\"$(json_escape "$reason")\""
    sep=","
  done

  cat >"$ALERT_FILE.tmp.$$" <<EOF
{
  "at": "$at",
  "event": "resource-pressure",
  "root": "$(json_escape "$REPO_ROOT")",
  "limits": {
    "cpu_percent": $CPU_LIMIT,
    "ram_percent": $RAM_LIMIT,
    "disk_percent": $DISK_LIMIT,
    "disk_write_mb": $DISK_WRITE_MB,
    "streak": $STREAK,
    "interval_s": $INTERVAL
  },
  "metrics": {
    "cpu_percent": $(fmt_tenths "$M_CPU_TENTHS"),
    "ram_percent": $(fmt_tenths "$M_RAM_TENTHS"),
    "ram_bytes": $M_RAM_BYTES,
    "mem_total_bytes": $MEM_TOTAL_BYTES,
    "mem_available_bytes": $MEM_AVAILABLE_BYTES,
    "write_mb": $(fmt_tenths "$M_WRITE_MB_TENTHS"),
    "disk_used_percent": $(fmt_tenths "$DISK_MAX_USED_TENTHS"),
    "disk_min_avail_bytes": $DISK_MIN_AVAIL_BYTES
  },
  "queue": {
    "active": $( (( QUEUE_ACTIVE == 1 )) && echo true || echo false ),
    "task": "$(json_escape "$QUEUE_TASK")",
    "pid": $([[ "$QUEUE_PID" =~ ^[0-9]+$ ]] && echo "$QUEUE_PID" || echo null)
  },
  "recommendation": {
    "parallel_subagents": $RECOMMENDED_PARALLEL,
    "note": "0 means stop spawning; restart only after two clean samples."
  },
  "protected_pgids": [$protected_json],
  "reasons": [$reasons_json],
  "disk": [$disk_json],
  "processes": [$processes_json],
  "kill_note": "Kill only PID trees that belong to the tasks you stop; process groups may be shared with the orchestrator. Never kill the monitor, its ancestors, the orchestrator, or the queue holder.",
  "required_action": "Stop spawning subagents. Kill the process trees of the tasks you stop (see processes above; verify cwd/cmd first). Reduce parallelism 6->4->2->1. Restart the monitor only after two clean samples."
}
EOF
  mv -f "$ALERT_FILE.tmp.$$" "$ALERT_FILE"
}

emit_alert() {
  local i reason
  collect_top_processes
  build_reasons
  write_alert_json

  alert_line ""
  alert_line "RESOURCE MONITOR: PRESSURE DETECTED"
  for reason in "${REASONS[@]}"; do
    alert_line "  reason: $reason"
  done
  alert_line "  cpu: $(fmt_tenths "$M_CPU_TENTHS")% (limit ${CPU_LIMIT}%)"
  alert_line "  ram: $(fmt_tenths "$M_RAM_TENTHS")% (limit ${RAM_LIMIT}%), $(( M_RAM_BYTES / 1048576 )) MiB unqueued"
  if (( DISK_DEFERRED == 1 )); then
    alert_line "  disk: $(fmt_tenths "$DISK_MAX_USED_TENTHS")% used (limit ${DISK_LIMIT}%, deferred while queue is active)"
  else
    alert_line "  disk: $(fmt_tenths "$DISK_MAX_USED_TENTHS")% used (limit ${DISK_LIMIT}%)"
  fi
  alert_line "  unmanaged writes: $(fmt_tenths "$M_WRITE_MB_TENTHS")MB/sample (limit ${DISK_WRITE_MB}MB)"
  alert_line "  queue: $(queue_label)"
  alert_line "  recommended parallel subagents: ${RECOMMENDED_PARALLEL}"
  if (( ${#TOP_PID[@]} == 0 )); then
    alert_line "  top unqueued processes: (none sampled)"
  else
    alert_line "  top unqueued processes (pid pgid rss cpu cwd cmd):"
    for i in "${!TOP_PID[@]}"; do
      local cpu_pct="0.0"
      if (( CAPACITY_TICKS > 0 )); then
        cpu_pct="$(fmt_tenths "$(( (TOP_TICKS[i] * 1000 + CAPACITY_TICKS / 2) / CAPACITY_TICKS ))")"
      fi
      alert_line "    ${TOP_PID[i]} ${TOP_PGID[i]} $(fmt_mib "${TOP_MEM[i]}")MiB ${cpu_pct}% ${TOP_CWD[i]} ${TOP_CMD[i]}"
    done
  fi
  alert_line "  kill only PID trees whose cwd/cmd belong to the tasks you stopped; process groups may be shared."
  alert_line "  never kill the monitor, its ancestors, the orchestrator, or the queue holder."
  alert_line "  protected pgids: ${SAFE_PGIDS[*]:-none}"
  alert_line "  alert json: $ALERT_FILE"
  alert_line "  ACTION: stop spawning; kill the stopped tasks' process trees; reduce parallelism; restart after two clean samples."
}

# --- main loop -------------------------------------------------------------

read_meminfo
log_line "resource-monitor: watching ${WATCH_PATHS[*]} every ${INTERVAL}s (cpu<=${CPU_LIMIT}%, ram<=${RAM_LIMIT}%, disk<${DISK_LIMIT}%, writes<=${DISK_WRITE_MB}MB, streak=${STREAK})"
log_line "resource-monitor: queue-exempt = processes with RESOURCE_QUEUE_HELD=1 or descendants of the queue holder"
log_line "resource-monitor: alert json: $ALERT_FILE"

SAMPLE_COUNT=0
while :; do
  NOW_NS="$(date +%s%N)"
  CYCLE_START_NS="$NOW_NS"
  queue_state
  read_meminfo
  sample_processes
  compute_metrics
  sample_disks
  update_streaks
  compute_recommendation
  emit_sample
  if (( SAMPLE_COUNT == 0 )); then
    log_line "resource-monitor: recommended parallel subagents: ${RECOMMENDED_PARALLEL}"
  fi

  if (( CPU_STREAK >= STREAK || RAM_STREAK >= STREAK || DISK_STREAK >= STREAK || WRITE_STREAK >= STREAK )); then
    # Pressure means stop spawning: the alert recommendation is always zero.
    RECOMMENDED_PARALLEL=0
    emit_alert
    exit 3
  fi

  SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
  if (( ONCE == 1 )) || (( MAX_SAMPLES > 0 && SAMPLE_COUNT >= MAX_SAMPLES )); then
    log_line "resource-monitor: clean stop after ${SAMPLE_COUNT} sample(s)"
    exit 0
  fi

  PREV_TICKS=()
  PREV_IO=()
  PREV_EXEMPT=()
  for pid in "${CUR_PIDS[@]}"; do
    PREV_TICKS[$pid]="${CUR_TICKS[$pid]:-0}"
    PREV_IO[$pid]="${CUR_IO[$pid]:-0}"
    PREV_EXEMPT[$pid]="${CUR_EXEMPT[$pid]:-0}"
  done
  PREV_NS="$NOW_NS"

  # Keep the cadence at one sample per --interval, not interval + scan time.
  remaining_ns=$(( INTERVAL * 1000000000 - ( $(date +%s%N) - CYCLE_START_NS ) ))
  if (( remaining_ns > 0 )); then
    printf -v sleep_for '%d.%09d' \
      "$(( remaining_ns / 1000000000 ))" "$(( remaining_ns % 1000000000 ))"
    # Background + wait, so TERM/INT interrupts the sleep and runs the trap
    # immediately. The sleep child must not keep the monitor's flock open.
    if (( USE_LOCK == 1 )); then
      sleep "$sleep_for" 7>&- &
    else
      sleep "$sleep_for" &
    fi
    SLEEP_PID=$!
    wait "$SLEEP_PID" || true
    SLEEP_PID=""
  fi
done
