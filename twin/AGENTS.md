<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Twin verification (generic workflow)

This directory packages the twin-verification workflow as a repo-agnostic
submodule. It verifies a **port** (the code under test) item-by-item against a
read-only **reference** (the non-Godot counterpart it is meant to match).

## Counterpart contract

The concrete counterpart is not part of this submodule. Read
[`../../TWIN_COUNTERPART.md`](../../TWIN_COUNTERPART.md) first: it names the
reference checkout, the reference/port legs, how to inspect the reference, and
the repo-specific commands and paths. Nothing in this directory may hardcode
those details.

## Files

| Path | Purpose |
|---|---|
| [`WORKFLOW.md`](WORKFLOW.md) | The generic workflow: registry, statuses, evidence layout, checker/fixer loop and comparison gate. |
| [`twin_verify.py`](twin_verify.py) | Registry validator and queue helper: `check`, `next`, `stats`, `list`, `set-status`. |
| [`twin_item.sh`](twin_item.sh) | Per-item evidence helper: `dir`, `stamp`, `capture`, `note`, `log`. |
| [`prompts/checker.md`](prompts/checker.md) | Prompt template for one sequential checker. |
| [`prompts/fixer.md`](prompts/fixer.md) | Prompt template for the single nested fixer a checker may spawn. |
| [`templates/TWIN-VERIFICATION.json`](templates/TWIN-VERIFICATION.json) | Starter registry; copy it to the repo root and replace the legs/items. |

## Hard rules

- **The reference is read-only.** Never edit, build into, commit or clean the
  counterpart. Capture fresh reference evidence only when the workflow says so.
- **One checker at a time.** Never run two checkers, two reference clients or
  two port clients concurrently.
- **At most one nested fixer per gap.** The checker stops the walk, spawns one
  fixer, waits for it, verifies the result, then stops.
- **Two terminal statuses only:** `reference-verified` (the port matched the
  recorded reference without a code change) and `twin-verified` (a gap was
  fixed and fresh reference + port legs match).
- **The registry is the durable verdict.** Frames and run reports live under
  the git-ignored `runs/` tree; only the registry is committed.
- **No repo-specific facts here.** Paths, ports, window titles, JVM flags,
  scene names and capture commands belong in `../../TWIN_COUNTERPART.md` (or the
  repo's own docs), not in this submodule.

Start with [`WORKFLOW.md`](WORKFLOW.md).
