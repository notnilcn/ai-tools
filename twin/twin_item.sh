#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# twin_item.sh — per-item evidence folders for the generic twin workflow.
#
#   ./twin_item.sh dir ITEM
#   ./twin_item.sh stamp
#   ./twin_item.sh capture LEG ITEM LABEL -- CMD...
#   ./twin_item.sh note ITEM LABEL [TEXT]
#   ./twin_item.sh log ITEM LABEL [CMD...]
#
# Environment:
#   TWIN_ROOT            repository root (default: git toplevel of $PWD)
#   TWIN_RUNS            evidence root (default: $TWIN_ROOT/runs)
#   TWIN_REFERENCE_LEG   reference leg folder name (default: reference)
#   TWIN_PORT_LEG        port leg folder name (default: port)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

resolve_root() {
  if [[ -n "${TWIN_ROOT:-}" ]]; then
    printf '%s\n' "$TWIN_ROOT"
    return 0
  fi
  # The submodule lives at <repo>/tools/ai-tools, so three levels up is the
  # repository the workflow runs against.
  local candidate
  candidate="$(cd -- "$SCRIPT_DIR/../../.." 2>/dev/null && pwd || true)"
  if [[ -n "$candidate" ]] && git -C "$candidate" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf '%s\n' "$candidate"
    return 0
  fi
  local root
  if root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$root" ]]; then
    printf '%s\n' "$root"
    return 0
  fi
  (cd -- "$SCRIPT_DIR/../../.." && pwd)
}

ROOT="$(resolve_root)"
RUNS="${TWIN_RUNS:-$ROOT/runs}"
REFERENCE_LEG="${TWIN_REFERENCE_LEG:-reference}"
PORT_LEG="${TWIN_PORT_LEG:-port}"

die() {
  printf 'twin_item: %s\n' "$*" >&2
  exit 2
}

usage() {
  sed -n '4,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

stamp() {
  date +%Y%m%d-%H%M%S
}

slug() {
  printf '%s' "$1" | tr ' /' '--' | tr -cd 'A-Za-z0-9._-'
}

item_id() {
  local id="${1:-}"
  [[ "$id" =~ ^[A-Z][A-Z0-9]*-[0-9]{3,}$ ]] || die "item id must look like TWIN-0001 (got '$id')"
  printf '%s\n' "$id"
}

leg_dir() {
  local leg="${1:-}"
  case "$leg" in
    reference) printf '%s\n' "$REFERENCE_LEG" ;;
    port) printf '%s\n' "$PORT_LEG" ;;
    *) die "leg must be 'reference' or 'port' (got '$leg')" ;;
  esac
}

ensure_dir() {
  local id
  id="$(item_id "${1:-}")"
  mkdir -p "$RUNS/$id/$REFERENCE_LEG" "$RUNS/$id/$PORT_LEG"
  printf '%s\n' "$RUNS/$id"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  dir|ensure)
    ensure_dir "$@"
    ;;
  stamp)
    stamp
    ;;
  capture)
    leg="${1:-}"; id="${2:-}"; label="${3:-action}"
    (( $# >= 3 )) || die "capture needs LEG ITEM LABEL -- CMD..."
    shift 3
    [[ "${1:-}" == "--" ]] && shift
    (( $# >= 1 )) || die "capture needs a command after --"
    root="$(ensure_dir "$id")"
    leg_name="$(leg_dir "$leg")"
    out="$root/$leg_name/$(stamp)-$(slug "$label").png"
    TWIN_SHOT_PATH="$out" "$@"
    printf '%s\n' "$out"
    ;;
  note)
    id="${1:-}"; label="${2:-run}"
    (( $# >= 2 )) || die "note needs ITEM LABEL [TEXT]"
    shift 2
    root="$(ensure_dir "$id")"
    out="$root/$(stamp)-$(slug "$label").md"
    if (( $# > 0 )); then
      printf '%s\n' "$*" >"$out"
    else
      : >"$out"
    fi
    printf '%s\n' "$out"
    ;;
  log)
    id="${1:-}"; label="${2:-log}"
    (( $# >= 2 )) || die "log needs ITEM LABEL [CMD...]"
    shift 2
    root="$(ensure_dir "$id")"
    out="$root/$(stamp)-$(slug "$label").log"
    if (( $# > 0 )); then
      "$@" >"$out" 2>&1 || true
    else
      cat >"$out"
    fi
    printf '%s\n' "$out"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    die "unknown action '$cmd' (see --help)"
    ;;
esac
