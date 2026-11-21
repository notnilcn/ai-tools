#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# twin_item.sh — per-item evidence folders for the twin workflow.
#
# Every frame, log and run report goes through this helper so the timestamps and
# the layout stay consistent with WORKFLOW.md §5.
#
# Usage:
#   ./twin_item.sh dir ITEM
#   ./twin_item.sh stamp
#   ./twin_item.sh capture LEG ITEM LABEL -- CMD...
#   ./twin_item.sh note ITEM LABEL [TEXT]
#   ./twin_item.sh log ITEM LABEL [CMD...]
#
# Environment:
#   TWIN_ROOT            repository root (default: the nearest ancestor of the
#                        working directory, then of this folder, that holds
#                        TWIN-VERIFICATION.json; otherwise the git top level)
#   TWIN_RUNS            evidence root (default: <root>/runs)
#   TWIN_REFERENCE_LEG   reference leg folder name (default: reference)
#   TWIN_PORT_LEG        port leg folder name (default: port)
#   TWIN_SINGLE          set to 1 to record one leg only (no reference folder)
#
# The leg names must match the registry's "legs" object and
# TWIN_COUNTERPART.md. A registry with "mode": "single" (or a "legs" object
# without a reference role) is recorded as a single-leg walk automatically:
# only the port folder is created and `capture reference` is rejected.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_NAME="TWIN-VERIFICATION.json"

die() {
  printf 'twin_item: %s\n' "$*" >&2
  exit 2
}

usage() {
  awk '/^# Usage:/{show=1} show{print} /^# The two leg names/{exit}' "${BASH_SOURCE[0]}" \
    | sed 's/^# \{0,1\}//'
}

find_root_with_registry() {
  local dir="$1"
  while :; do
    if [[ -f "$dir/$REGISTRY_NAME" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    [[ "$dir" == "/" ]] && return 1
    dir="$(dirname -- "$dir")"
  done
}

git_top() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || return 1
}

resolve_root() {
  if [[ -n "${TWIN_ROOT:-}" ]]; then
    printf '%s\n' "$TWIN_ROOT"
    return 0
  fi
  local base root
  for base in "$PWD" "$SCRIPT_DIR"; do
    base="$(cd -- "$base" 2>/dev/null && pwd)" || continue
    if root="$(find_root_with_registry "$base")"; then
      printf '%s\n' "$root"
      return 0
    fi
  done
  for base in "$PWD" "$SCRIPT_DIR"; do
    base="$(cd -- "$base" 2>/dev/null && pwd)" || continue
    if root="$(git_top "$base")" && [[ -n "$root" ]]; then
      printf '%s\n' "$root"
      return 0
    fi
  done
  printf '%s\n' "$PWD"
}

ROOT="$(resolve_root)"
RUNS="${TWIN_RUNS:-$ROOT/runs}"
REFERENCE_LEG="${TWIN_REFERENCE_LEG:-reference}"
PORT_LEG="${TWIN_PORT_LEG:-port}"

registry_leg() {
  local role="$1"
  local registry="$ROOT/$REGISTRY_NAME"
  [[ -f "$registry" ]] || return 1
  python3 - "$registry" "$role" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
legs = doc.get("legs")
if not isinstance(legs, dict):
    raise SystemExit(1)
value = legs.get(sys.argv[2])
if not isinstance(value, str) or not value.strip():
    raise SystemExit(1)
print(value)
PY
}

is_single_registry() {
  local registry="$ROOT/$REGISTRY_NAME"
  [[ -f "$registry" ]] || return 1
  python3 - "$registry" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
mode = doc.get("mode")
legs = doc.get("legs")
single = mode in ("single", "feature-walk", "single-leg")
if isinstance(legs, dict) and legs and "reference" not in legs and "port" in legs:
    single = True
raise SystemExit(0 if single else 1)
PY
}

SINGLE=0
if [[ "${TWIN_SINGLE:-}" == "1" ]] || is_single_registry; then
  SINGLE=1
fi

if [[ -z "${TWIN_PORT_LEG:-}" ]]; then
  if value="$(registry_leg port 2>/dev/null)" && [[ -n "$value" ]]; then
    PORT_LEG="$value"
  fi
fi
if [[ -z "${TWIN_REFERENCE_LEG:-}" ]] && (( SINGLE == 0 )); then
  if value="$(registry_leg reference 2>/dev/null)" && [[ -n "$value" ]]; then
    REFERENCE_LEG="$value"
  fi
fi

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
    reference)
      (( SINGLE == 1 )) && die "this registry is single-leg; there is no reference folder"
      printf '%s\n' "$REFERENCE_LEG"
      ;;
    port) printf '%s\n' "$PORT_LEG" ;;
    *) die "leg must be 'reference' or 'port' (got '$leg')" ;;
  esac
}

ensure_dir() {
  local id
  id="$(item_id "${1:-}")"
  mkdir -p "$RUNS/$id/$PORT_LEG"
  if (( SINGLE == 0 )); then
    mkdir -p "$RUNS/$id/$REFERENCE_LEG"
  fi
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
