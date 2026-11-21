#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Inspect and validate a twin-verification registry.

This is the repository-agnostic companion to the workflow in ``WORKFLOW.md``. It
knows nothing about a particular reference or port: the leg names, statuses and
evidence root all come from the registry or from command-line flags. A
single-leg registry (``"mode": "single"`` or a ``legs`` object with only
``port``) records one implementation and needs no reference leg.

Run it from anywhere:

    python3 twin_verify.py check
    python3 twin_verify.py check --evidence
    python3 twin_verify.py next
    python3 twin_verify.py stats
    python3 twin_verify.py list --status mismatch
    python3 twin_verify.py set-status TWIN-0001 reference-verified --note "matched"

The registry defaults to ``TWIN-VERIFICATION.json`` at the repository root: the
nearest ancestor of the working directory (then of this script) that holds one,
otherwise the git top level. ``--root`` or ``TWIN_ROOT`` names the repository
explicitly; ``--registry``/``TWIN_REGISTRY`` and ``--runs``/``TWIN_RUNS``
override the paths. Leg names come from the registry's ``legs`` object; without
one, set ``TWIN_REFERENCE_LEG``/``TWIN_PORT_LEG`` (default
``reference``/``port``).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:  # pragma: no cover - Windows has no fcntl
    import fcntl
except ImportError:  # pragma: no cover
    fcntl = None  # type: ignore[assignment]

REGISTRY_NAME = "TWIN-VERIFICATION.json"
DEFAULT_SCHEMA = "ai-tools/twin-verification@1"
DEFAULT_LEGS = {"reference": "reference", "port": "port"}
SINGLE_LEGS = {"port": "port"}
DEFAULT_TERMINAL = ("reference-verified", "twin-verified")
SINGLE_TERMINAL = ("verified", "bug", "fixed", "blocked", "wontfix")
DEFAULT_STATUSES = (
    "seeded",
    "in-progress",
    "mismatch",
    "fixing",
    "blocked",
    "wontfix",
    "reference-verified",
    "twin-verified",
)
SINGLE_STATUSES = (
    "seeded",
    "in-progress",
    "bug",
    "fixing",
    "fixed",
    "verified",
    "blocked",
    "wontfix",
)
ITEM_ID_RE = re.compile(r"^[A-Z][A-Z0-9]*-\d{3,}$")
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".avif", ".gif"}


def _git_top(path: Path) -> Path | None:
    """Return the git top level that contains ``path``, if git can name one."""
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    value = result.stdout.strip()
    return Path(value) if result.returncode == 0 and value else None


def _default_root() -> Path:
    """Find the repository the twin workflow runs against."""
    env = os.environ.get("TWIN_ROOT")
    if env:
        return Path(env).expanduser().resolve()
    script_dir = Path(__file__).resolve().parent
    bases = [Path.cwd().resolve(), script_dir]
    for base in bases:
        for candidate in (base, *base.parents):
            if (candidate / REGISTRY_NAME).is_file():
                return candidate
    for base in bases:
        top = _git_top(base)
        if top is not None:
            return top
    return Path.cwd().resolve()


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _resolve(path: str | os.PathLike[str], base: Path) -> Path:
    candidate = Path(path).expanduser()
    return candidate if candidate.is_absolute() else base / candidate


def _load(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        raise SystemExit(f"twin_verify: registry not found: {path}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"twin_verify: invalid JSON in {path}: {exc}")
    if not isinstance(doc, dict):
        raise SystemExit(f"twin_verify: {path} must contain a JSON object")
    return doc


def _single_mode(doc: dict[str, Any]) -> bool:
    """A single-leg registry records one implementation, with no counterpart."""
    mode = doc.get("mode")
    if mode in ("single", "feature-walk", "single-leg"):
        return True
    raw = doc.get("legs")
    if isinstance(raw, dict) and raw and "reference" not in raw and "port" in raw:
        return True
    return False


def _legs(doc: dict[str, Any]) -> dict[str, str]:
    raw = doc.get("legs")
    if raw is None:
        if _single_mode(doc):
            return {"port": os.environ.get("TWIN_PORT_LEG", SINGLE_LEGS["port"])}
        # Generic default, or the leg names the evidence helper uses.
        return {
            "reference": os.environ.get("TWIN_REFERENCE_LEG", DEFAULT_LEGS["reference"]),
            "port": os.environ.get("TWIN_PORT_LEG", DEFAULT_LEGS["port"]),
        }
    if not isinstance(raw, dict):
        raise SystemExit("twin_verify: legs must be an object")
    if _single_mode(doc):
        value = raw.get("port", SINGLE_LEGS["port"])
        if not isinstance(value, str) or not value.strip():
            raise SystemExit("twin_verify: legs.port must be a non-empty string")
        return {"port": value}
    legs: dict[str, str] = {}
    for role in ("reference", "port"):
        value = raw.get(role, role)
        if not isinstance(value, str) or not value.strip():
            raise SystemExit(f"twin_verify: legs.{role} must be a non-empty string")
        legs[role] = value
    return legs


def _terminal(doc: dict[str, Any]) -> tuple[str, ...]:
    raw = doc.get("terminal_statuses")
    if raw is None:
        return SINGLE_TERMINAL if _single_mode(doc) else DEFAULT_TERMINAL
    if not isinstance(raw, list) or not raw or not all(isinstance(s, str) for s in raw):
        raise SystemExit("twin_verify: terminal_statuses must be a non-empty string list")
    return tuple(raw)


def _statuses(doc: dict[str, Any]) -> tuple[str, ...]:
    raw = doc.get("statuses")
    if raw is None:
        return SINGLE_STATUSES if _single_mode(doc) else DEFAULT_STATUSES
    if not isinstance(raw, list) or not all(isinstance(s, str) for s in raw):
        raise SystemExit("twin_verify: statuses must be a string list")
    return tuple(raw)


def _call_chain(value: Any, where: str, errors: list[str]) -> None:
    if not isinstance(value, list) or not value:
        errors.append(f"{where} is not a non-empty list")
        return
    for index, call in enumerate(value):
        if isinstance(call, str):
            if not call.strip():
                errors.append(f"{where}[{index}] is an empty reference")
        elif not isinstance(call, dict):
            errors.append(f"{where}[{index}] is not an object or reference")
        elif not isinstance(call.get("tool"), str) or not call["tool"].strip():
            errors.append(f"{where}[{index}] has no tool name")


def check(doc: dict[str, Any], registry: Path, runs: Path, evidence: bool) -> list[str]:
    errors: list[str] = []
    legs = _legs(doc)
    leg_names = set(legs.values())
    terminal = set(_terminal(doc))
    statuses = set(_statuses(doc)) | terminal | set(DEFAULT_STATUSES)

    schema = doc.get("schema")
    if not isinstance(schema, str) or not schema.strip():
        errors.append("missing schema string")

    items = doc.get("items")
    if not isinstance(items, dict) or not items:
        errors.append("items is missing or empty")
        items = {}

    recipes = doc.get("recipes") or {}
    if not isinstance(recipes, dict):
        errors.append("recipes is not an object")
        recipes = {}

    for item_id in sorted(items):
        item = items[item_id]
        if not ITEM_ID_RE.fullmatch(item_id):
            errors.append(f"bad item id {item_id!r}")
        if not isinstance(item, dict):
            errors.append(f"{item_id}: item is not an object")
            continue
        if not isinstance(item.get("title"), str) or not item["title"].strip():
            errors.append(f"{item_id}: missing title")
        status = item.get("status")
        if status not in statuses:
            errors.append(f"{item_id}: bad status {status!r}")
        similarity = item.get("similarity")
        if similarity is not None:
            if not isinstance(similarity, (int, float)) or not 0 <= similarity <= 100:
                errors.append(f"{item_id}: similarity {similarity!r} outside 0-100")
        acceptance = item.get("acceptance")
        if acceptance is not None:
            if isinstance(acceptance, str):
                if not acceptance.strip():
                    errors.append(f"{item_id}: acceptance is empty")
            elif not isinstance(acceptance, list) or not all(
                isinstance(entry, str) and entry.strip() for entry in acceptance
            ):
                errors.append(f"{item_id}: acceptance must be a string or a non-empty string list")

        for phase in ("fork", "action"):
            chains = item.get(phase)
            if chains is None:
                continue
            if not isinstance(chains, dict):
                errors.append(f"{item_id}: {phase} is not an object")
                continue
            for leg, chain in chains.items():
                if leg not in leg_names:
                    errors.append(f"{item_id}: {phase} has unknown leg {leg!r}")
                _call_chain(chain, f"{item_id}: {phase}.{leg}", errors)

        images = item.get("images")
        if images is not None:
            if not isinstance(images, dict):
                errors.append(f"{item_id}: images is not an object")
            else:
                lists: list[list[str]] = []
                for leg in legs.values():
                    paths = images.get(leg)
                    if not isinstance(paths, list) or not paths:
                        errors.append(f"{item_id}: images.{leg} is not a non-empty list")
                        continue
                    lists.append(paths)
                    for path in paths:
                        if not isinstance(path, str) or not path.strip():
                            errors.append(f"{item_id}: images.{leg} has an empty path")
                            continue
                        resolved = _resolve(path, registry.parent)
                        if not resolved.exists():
                            errors.append(f"{item_id}: missing image {path}")
                        elif resolved.suffix.lower() not in IMAGE_SUFFIXES:
                            errors.append(f"{item_id}: image is not a recognised frame: {path}")
                for paths in lists[1:]:
                    if len(paths) != len(lists[0]):
                        errors.append(f"{item_id}: image lists are not index-aligned")
                        break

        if evidence and status in terminal:
            item_root = runs / item_id
            port_dir = item_root / legs["port"]
            if "reference" in legs:
                if status not in ("blocked", "wontfix"):
                    if not port_dir.is_dir() or not any(port_dir.iterdir()):
                        errors.append(
                            f"{item_id}: terminal status needs a non-empty {legs['port']}/ folder"
                        )
                if status == "twin-verified":
                    reference_dir = item_root / legs["reference"]
                    if not reference_dir.is_dir() or not any(reference_dir.iterdir()):
                        errors.append(
                            f"{item_id}: twin-verified needs a non-empty {legs['reference']}/ folder"
                        )
            reports = list(item_root.glob("*-run.md")) if item_root.is_dir() else []
            if not reports:
                errors.append(f"{item_id}: terminal status needs a *-run.md report")

    for recipe_id in sorted(recipes):
        recipe = recipes[recipe_id]
        if not isinstance(recipe, dict):
            errors.append(f"{recipe_id}: recipe is not an object")
            continue
        if not isinstance(recipe.get("title"), str) or not recipe["title"].strip():
            errors.append(f"{recipe_id}: missing title")
        paired = recipe.get("paired_with")
        if paired is not None and paired not in recipes:
            errors.append(f"{recipe_id}: paired_with {paired!r} does not resolve")
        covered = recipe.get("also_covers") or []
        if not isinstance(covered, list):
            errors.append(f"{recipe_id}: also_covers is not a list")
        else:
            for entry in covered:
                if entry not in recipes:
                    errors.append(f"{recipe_id}: also_covers {entry!r} does not resolve")
        gap = recipe.get("gap")
        if gap is not None and (not isinstance(gap, str) or not gap.strip()):
            errors.append(f"{recipe_id}: empty gap")

    gaps = doc.get("gaps")
    if gaps is not None:
        if not isinstance(gaps, list):
            errors.append("gaps is not a list")
        else:
            for entry in gaps:
                if not isinstance(entry, str) or not entry.strip():
                    errors.append("empty gap entry")

    return errors


def _registry_root(args: argparse.Namespace) -> Path:
    if args.root:
        return Path(args.root).expanduser().resolve()
    return _default_root()


def _registry_path(args: argparse.Namespace, root: Path) -> Path:
    value = args.registry or os.environ.get("TWIN_REGISTRY")
    return _resolve(value, root) if value else root / REGISTRY_NAME


def _runs_path(args: argparse.Namespace, root: Path) -> Path | None:
    value = args.runs or os.environ.get("TWIN_RUNS")
    return _resolve(value, root) if value else None


def cmd_check(args: argparse.Namespace) -> int:
    root = _registry_root(args)
    registry = _registry_path(args, root)
    doc = _load(registry)
    runs = _runs_path(args, root) or (root / "runs")
    errors = check(doc, registry, runs, args.evidence)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    items = doc.get("items") or {}
    recipes = doc.get("recipes") or {}
    terminal = set(_terminal(doc))
    done = sum(1 for item in items.values() if item.get("status") in terminal)
    print(
        f"ok: {len(items)} items ({done} terminal), {len(recipes)} recipes, "
        f"{len(doc.get('gaps') or [])} gaps"
    )
    return 0


def cmd_next(args: argparse.Namespace) -> int:
    root = _registry_root(args)
    doc = _load(_registry_path(args, root))
    terminal = set(_terminal(doc))
    items = doc.get("items") or {}
    for item_id in sorted(items):
        if items[item_id].get("status") not in terminal:
            print(f"{item_id}\t{items[item_id].get('status', '?')}\t{items[item_id].get('title', '')}")
            return 0
    print("all items terminal")
    return 0


def cmd_stats(args: argparse.Namespace) -> int:
    root = _registry_root(args)
    doc = _load(_registry_path(args, root))
    items = doc.get("items") or {}
    counts: dict[str, int] = {}
    for item in items.values():
        status = str(item.get("status", "?"))
        counts[status] = counts.get(status, 0) + 1
    if args.json:
        print(
            json.dumps(
                {
                    "items": len(items),
                    "terminal": sum(counts.get(s, 0) for s in _terminal(doc)),
                    "by_status": dict(sorted(counts.items())),
                },
                indent=2,
            )
        )
        return 0
    print(f"items: {len(items)}")
    for status, count in sorted(counts.items()):
        print(f"  {status:>20}  {count}")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    root = _registry_root(args)
    doc = _load(_registry_path(args, root))
    wanted = set(args.status or [])
    for item_id in sorted(doc.get("items") or {}):
        item = doc["items"][item_id]
        status = item.get("status")
        if wanted and status not in wanted:
            continue
        print(f"{item_id}\t{status}\t{item.get('title', '')}")
    return 0


def _write_locked(path: Path, doc: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        if fcntl is not None:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
        tmp.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(tmp, path)


def _update_locked(path: Path, mutate: Any) -> dict[str, Any]:
    """Read, mutate and write under one lock so parallel agents do not clobber."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        if fcntl is not None:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        doc = _load(path)
        mutate(doc)
        doc["updated"] = _now()
        tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
        tmp.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(tmp, path)
    return doc


def cmd_set_status(args: argparse.Namespace) -> int:
    root = _registry_root(args)
    registry = _registry_path(args, root)
    doc_preview = _load(registry)
    allowed = set(_statuses(doc_preview)) | set(_terminal(doc_preview)) | set(DEFAULT_STATUSES)
    if args.status not in allowed:
        raise SystemExit(f"twin_verify: unknown status {args.status!r}")
    if args.similarity is not None and not 0 <= args.similarity <= 100:
        raise SystemExit("twin_verify: --similarity must be 0..100")
    if args.item_id not in (doc_preview.get("items") or {}):
        raise SystemExit(f"twin_verify: unknown item {args.item_id}")

    def mutate(doc: dict[str, Any]) -> None:
        item = doc["items"][args.item_id]
        item["status"] = args.status
        if args.note:
            item["notes"] = args.note
        if args.similarity is not None:
            item["similarity"] = args.similarity

    _update_locked(registry, mutate)
    print(f"{args.item_id}: {args.status}")
    return 0


def cmd_set_action(args: argparse.Namespace) -> int:
    root = _registry_root(args)
    registry = _registry_path(args, root)
    doc = _load(registry)
    item = (doc.get("items") or {}).get(args.item_id)
    if item is None:
        raise SystemExit(f"twin_verify: unknown item {args.item_id}")
    legs = _legs(doc)
    role = args.leg
    if role not in legs:
        raise SystemExit(f"twin_verify: unknown leg role {role!r} (have {', '.join(legs)})")
    chain_text = Path(args.file).read_text(encoding="utf-8") if args.file else args.json
    if chain_text is None:
        raise SystemExit("twin_verify: set-action needs --json or --file")
    try:
        chain = json.loads(chain_text)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"twin_verify: invalid JSON chain: {exc}")
    errors: list[str] = []
    _call_chain(chain, f"{args.item_id}: {args.phase}.{role}", errors)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    def mutate(doc: dict[str, Any]) -> None:
        item = doc["items"][args.item_id]
        phase = item.get(args.phase)
        if not isinstance(phase, dict):
            phase = {}
            item[args.phase] = phase
        phase[legs[role]] = chain

    _update_locked(registry, mutate)
    print(f"{args.item_id}: {args.phase}.{legs[role]} <- {len(chain)} call(s)")
    return 0


def _common(parser: argparse.ArgumentParser) -> argparse.ArgumentParser:
    parser.add_argument(
        "--root",
        help=(
            "repository root (default: nearest ancestor holding "
            f"{REGISTRY_NAME}, else the git top level)"
        ),
    )
    parser.add_argument("--registry", help=f"registry path (default: <root>/{REGISTRY_NAME})")
    parser.add_argument("--runs", help="evidence root (default: <root>/runs)")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    check_parser = _common(sub.add_parser("check", help="validate the registry"))
    check_parser.add_argument(
        "--evidence",
        action="store_true",
        help="also require per-item evidence for terminal statuses",
    )
    check_parser.set_defaults(func=cmd_check)

    next_parser = _common(sub.add_parser("next", help="print the first non-terminal item"))
    next_parser.set_defaults(func=cmd_next)

    stats_parser = _common(sub.add_parser("stats", help="count items by status"))
    stats_parser.add_argument("--json", action="store_true", help="emit JSON")
    stats_parser.set_defaults(func=cmd_stats)

    list_parser = _common(sub.add_parser("list", help="list items, optionally by status"))
    list_parser.add_argument("--status", action="append", help="status to include (repeatable)")
    list_parser.set_defaults(func=cmd_list)

    set_parser = _common(sub.add_parser("set-status", help="update one item's status atomically"))
    set_parser.add_argument("item_id")
    set_parser.add_argument("status")
    set_parser.add_argument("--note")
    set_parser.add_argument("--similarity", type=float)
    set_parser.set_defaults(func=cmd_set_status)

    action_parser = _common(
        sub.add_parser("set-action", help="replace one item's recorded fork/action chain")
    )
    action_parser.add_argument("item_id")
    action_parser.add_argument("--leg", default="port", choices=("port", "reference"))
    action_parser.add_argument("--phase", default="action", choices=("fork", "action"))
    action_parser.add_argument("--json", help="JSON list of tool calls")
    action_parser.add_argument("--file", help="file holding the JSON list of tool calls")
    action_parser.set_defaults(func=cmd_set_action)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
