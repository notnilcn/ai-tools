#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# run-resource-intensive-task.sh — one-at-a-time queue for resource-heavy work.
#
# Every build, test, code generator, asset pipeline, export, benchmark and
# headless run in this repository goes through this script instead of running
# directly. One exclusive lock serializes them: a second invocation waits in
# line and then runs with the whole machine available. resource-monitor.sh
# reads the same queue state and does not count queued work as pressure.
#
# Usage:
#   run-resource-intensive-task.sh [queue-options] --cmd -- CMD [ARG...]
#   run-resource-intensive-task.sh [queue-options] --name LABEL -- CMD [ARG...]
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
#                            <git-common-dir>/resource-queue, shared by every
#                            worktree of the repository)
#   RESOURCE_QUEUE_CATALOGUE file printed by --list (default:
#                            <repo>/RESOURCE_INTENSIVE_TASKS_CATALOGUE.md)
#   RESOURCE_QUEUE_TIMEOUT   default for --timeout
#   RESOURCE_QUEUE_QUIET     default for --quiet
#   RESOURCE_QUEUE_DISABLE=1 run the command without the queue (debug only)
#   RESOURCE_QUEUE_HELD      internal marker set for commands run under the lock
#
# Examples:
#   ./run-resource-intensive-task.sh --cmd -- make test
#   ./run-resource-intensive-task.sh --name export -- ./scripts/export.sh --release
#   ./run-resource-intensive-task.sh --status
#
# Exit codes: the task's own status; 75 when busy or timed out (EX_TEMPFAIL);
# 2 for usage errors.
#
# The task catalogue lives in <repo>/RESOURCE_INTENSIVE_TASKS_CATALOGUE.md. Copy
# templates/RESOURCE_INTENSIVE_TASKS_CATALOGUE.md from this folder to start one.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# The repository this checkout was cloned into is the one to queue for. The
# checkout may itself be a git repository (a nested clone), so start above it
# and take the first git top level instead of the checkout's own root.
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

# Queue state lives beside the git common dir, not under the checkout, so
# subagents in separate worktrees contend for the same lock. RESOURCE_QUEUE_DIR
# overrides it (absolute, or relative to the repository root).
resolve_queue_dir() {
  local override="${RESOURCE_QUEUE_DIR:-}"
  if [[ -n "$override" ]]; then
    [[ "$override" = /* ]] || override="$REPO_ROOT/$override"
    printf '%s\n' "$override"
    return 0
  fi
  local common
  if common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)" && [[ -n "$common" ]]; then
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
WAITER_DIR="$QUEUE_DIR/waiters"
HISTORY_FILE="$QUEUE_DIR/history.jsonl"
LAST_HOLDER_FILE="$QUEUE_DIR/last-holder"

CATALOGUE="${RESOURCE_QUEUE_CATALOGUE:-$REPO_ROOT/RESOURCE_INTENSIVE_TASKS_CATALOGUE.md}"

TASK=""
TASK_NAME=""
TASK_ARGS=()
TASK_CMD=()
ACTION="run"
WAIT_MODE=1
TIMEOUT="${RESOURCE_QUEUE_TIMEOUT:-0}"
QUIET="${RESOURCE_QUEUE_QUIET:-0}"
DRY_RUN=0
HISTORY_N=10
WAITER_FILE=""
HELD=0
WAITED=0
START_EPOCH=0

die() {
  printf 'run-resource-intensive-task.sh: %s\n' "$*" >&2
  exit 2
}

usage() {
  awk '/^# Usage:/{show=1} show{print} /^# The task catalogue/{exit}' "${BASH_SOURCE[0]}" \
    | sed 's/^# \{0,1\}//'
}

list_tasks() {
  if [[ -f "$CATALOGUE" ]]; then
    cat -- "$CATALOGUE"
    return 0
  fi
  cat <<EOF
No task catalogue yet: $CATALOGUE

Copy templates/RESOURCE_INTENSIVE_TASKS_CATALOGUE.md from this folder to the
repository root and list the commands that are too heavy to run in parallel.
Any of them can then be queued with:
  ./run-resource-intensive-task.sh --cmd -- <command>
EOF
}

# --- queue state helpers ----------------------------------------------------

queue_dir_prepare() {
  mkdir -p "$QUEUE_DIR" "$WAITER_DIR"
}

history_append() {
  # $1=event $2=rc(or "null") $3=extra json members (leading comma)
  local event="$1" rc="${2:-null}" extra="${3:-}"
  local task
  task="$(printf '%s' "$TASK_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"at":"%s","event":"%s","task":"%s","pid":%s,"rc":%s%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$task" "$$" "$rc" "$extra" \
    >>"$HISTORY_FILE"
}

ancestor_chain() {
  local pid="$PPID" out="" depth=0 ppid
  while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 && depth < 32 )); do
    out+="${out:+,}$pid"
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [[ "$ppid" =~ ^[0-9]+$ ]] || break
    pid="$ppid"
    depth=$((depth + 1))
  done
  printf '%s' "$out"
}

write_holder() {
  local command
  command="$(printf '%s ' "${TASK_CMD[@]}" | tr '\n' ' ')"
  {
    printf 'task=%s\n' "$TASK_NAME"
    printf 'pid=%s\n' "$$"
    printf 'ppid=%s\n' "$PPID"
    printf 'ancestors=%s\n' "$(ancestor_chain)"
    printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'cwd=%s\n' "$PWD"
    printf 'host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'command=%s\n' "$command"
  } >"$HOLDER_FILE.tmp"
  mv -f "$HOLDER_FILE.tmp" "$HOLDER_FILE"
}

write_waiter() {
  WAITER_FILE="$WAITER_DIR/$$.waiter"
  {
    printf 'task=%s\n' "$TASK_NAME"
    printf 'pid=%s\n' "$$"
    printf 'since=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'cwd=%s\n' "$PWD"
  } >"$WAITER_FILE"
}

holder_field() {
  local key="$1"
  [[ -f "$HOLDER_FILE" ]] || return 0
  sed -n "s/^${key}=//p" "$HOLDER_FILE" 2>/dev/null | head -n 1 || true
}

prune_waiters() {
  local f pid
  [[ -d "$WAITER_DIR" ]] || return 0
  for f in "$WAITER_DIR"/*.waiter; do
    [[ -e "$f" ]] || continue
    pid="${f##*/}"
    pid="${pid%.waiter}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$f"
    fi
  done
}

print_status() {
  prune_waiters
  local busy=0
  if [[ -e "$LOCK_FILE" ]] && command -v flock >/dev/null 2>&1; then
    exec 8>"$LOCK_FILE"
    if ! flock -n 8; then
      busy=1
    fi
    exec 8>&-
  fi

  if (( busy == 0 )); then
    echo "resource-queue: idle"
    if [[ -f "$HOLDER_FILE" ]]; then
      echo "  (stale holder state; the lock is free, so it is ignored)"
    fi
  else
    echo "resource-queue: busy"
    if [[ -f "$HOLDER_FILE" ]]; then
      sed 's/^/  /' "$HOLDER_FILE"
    else
      echo "  holder state not written yet"
    fi
    local count=0 pid f
    for f in "$WAITER_DIR"/*.waiter; do
      [[ -e "$f" ]] || continue
      pid="${f##*/}"
      pid="${pid%.waiter}"
      count=$((count + 1))
      printf '  waiting: pid %s: %s\n' "$pid" "$(tr '\n' ' ' <"$f")"
    done
    if (( count > 0 )); then
      echo "  queued behind: $count task(s)"
    fi
  fi

  if [[ -s "$HISTORY_FILE" ]]; then
    echo "  last: $(tail -n 1 "$HISTORY_FILE")"
  fi
  printf '  state: %s\n' "$QUEUE_DIR"
}

print_history() {
  if [[ ! -s "$HISTORY_FILE" ]]; then
    echo "resource-queue: no history yet ($HISTORY_FILE)"
    return 0
  fi
  tail -n "$HISTORY_N" "$HISTORY_FILE"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -n "$WAITER_FILE" ]]; then
    rm -f "$WAITER_FILE"
  fi
  if (( HELD == 1 )); then
    local duration=$(( $(date +%s) - START_EPOCH ))
    history_append "finish" "$rc" ",\"duration_s\":$duration,\"waited_s\":$WAITED"
    if [[ -f "$HOLDER_FILE" ]]; then
      cp -f "$HOLDER_FILE" "$LAST_HOLDER_FILE" 2>/dev/null || true
    fi
    rm -f "$HOLDER_FILE"
    if (( QUIET == 0 )); then
      printf 'resource-queue: %s exit %d (%ss)\n' "$TASK_NAME" "$rc" "$duration"
    fi
    exec 9>&- 2>/dev/null || true
  fi
  exit "$rc"
}

# --- argument parsing -------------------------------------------------------

while (( $# > 0 )); do
  case "$1" in
    --cmd)
      TASK=raw
      shift
      if (( $# > 0 )) && [[ "$1" == "--" ]]; then
        shift
      fi
      TASK_ARGS=("$@")
      break
      ;;
    --name)
      (( $# >= 2 )) || die "--name needs a value"
      TASK_NAME="$2"
      TASK=raw
      shift 2
      if (( $# > 0 )) && [[ "$1" == "--" ]]; then
        shift
      fi
      TASK_ARGS=("$@")
      break
      ;;
    --status) ACTION=status; shift ;;
    --list) ACTION=list; shift ;;
    --history)
      ACTION=history
      shift
      if (( $# > 0 )) && [[ "$1" =~ ^[0-9]+$ ]]; then
        HISTORY_N="$1"
        shift
      fi
      ;;
    --no-wait) WAIT_MODE=0; shift ;;
    --timeout)
      (( $# >= 2 )) || die "--timeout needs a value"
      TIMEOUT="$2"
      shift 2
      ;;
    --quiet|-q) QUIET=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) die "missing task before -- (see --help)" ;;
    *)
      printf 'run-resource-intensive-task.sh: unknown argument %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout needs a whole number of seconds"

case "$ACTION" in
  status)
    print_status
    exit 0
    ;;
  list)
    list_tasks
    exit 0
    ;;
  history)
    print_history
    exit 0
    ;;
esac

[[ -n "$TASK" ]] || {
  printf 'run-resource-intensive-task.sh: no task given\n\n' >&2
  usage >&2
  exit 2
}

(( ${#TASK_ARGS[@]} > 0 )) || die '--cmd/--name needs a command (use --cmd -- CMD...)'

# The command is forwarded verbatim: `--cmd -- mytool check -- -W error` reaches
# mytool with its own `--` separator intact.
TASK_CMD=("${TASK_ARGS[@]}")
if [[ -z "$TASK_NAME" ]]; then
  TASK_NAME="$(basename -- "${TASK_CMD[0]:-raw}")"
fi

if (( DRY_RUN == 1 )); then
  printf 'resource-queue: would run: %s\n' "$(printf '%q ' "${TASK_CMD[@]}")"
  exit 0
fi

if [[ "${RESOURCE_QUEUE_DISABLE:-0}" == "1" ]]; then
  echo "resource-queue: WARNING: queue disabled, running '$TASK_NAME' WITHOUT the lock" >&2
  exec "${TASK_CMD[@]}"
fi

command -v flock >/dev/null 2>&1 || {
  echo "run-resource-intensive-task.sh: 'flock' is required (util-linux; Linux/WSL has it)." >&2
  echo "  Use RESOURCE_QUEUE_DISABLE=1 only to debug on a host without flock." >&2
  exit 1
}

# --- queue + run ------------------------------------------------------------

queue_dir_prepare
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WAIT_START=$(date +%s)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  if (( WAIT_MODE == 0 )); then
    echo "resource-queue: busy, '$TASK_NAME' not started (--no-wait)" >&2
    [[ -f "$HOLDER_FILE" ]] && sed 's/^/  /' "$HOLDER_FILE" >&2
    exit 75
  fi

  write_waiter
  holder_task="$(holder_field task)"
  holder_pid="$(holder_field pid)"
  if [[ -n "$holder_task" ]]; then
    printf 'resource-queue: waiting for %s (pid %s); queued as pid %s\n' \
      "$holder_task" "${holder_pid:-?}" "$$"
  else
    printf 'resource-queue: waiting for the resource queue lock; queued as pid %s\n' "$$"
  fi

  if (( TIMEOUT > 0 )); then
    if ! flock -w "$TIMEOUT" 9; then
      echo "resource-queue: timed out after ${TIMEOUT}s waiting for the lock" >&2
      exit 75
    fi
  else
    flock 9
  fi
  rm -f "$WAITER_FILE"
  WAITER_FILE=""
fi

WAITED=$(( $(date +%s) - WAIT_START ))
HELD=1
START_EPOCH=$(date +%s)
write_holder
history_append "start" "null" ",\"waited_s\":$WAITED"
if (( QUIET == 0 )); then
  printf 'resource-queue: %s running (pid %s, waited %ss)\n' "$TASK_NAME" "$$" "$WAITED"
fi

# The marker is what resource-monitor.sh looks for: every process of a queued
# task carries it, so queued work is never reported as unmanaged pressure.
export RESOURCE_QUEUE_HELD=1
export RESOURCE_QUEUE_TASK="$TASK_NAME"
export RESOURCE_QUEUE_PID="$$"

set +e
"${TASK_CMD[@]}"
rc=$?
set -e

exit "$rc"
