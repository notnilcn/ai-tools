<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Twin verification

Instructions for the orchestrating agent. These helpers are POSIX; the
`windows` branch ships the PowerShell ports of the same workflow.

A twin walk proves that one item of a **port** (the code under test) behaves
like its **reference** (the read-only implementation it is meant to match).
One item at a time, one comparison gate, one durable status.

## Counterpart contract

The concrete counterpart is not part of this folder. Read the repository's
`TWIN_COUNTERPART.md`, at the repository root, before starting: it names the
reference checkout, the reference/port legs, how to inspect the reference, and
the repository-specific commands. Copy
[`templates/TWIN-COUNTERPART.md`](templates/TWIN-COUNTERPART.md) to the
repository root to create it.

Nothing in this folder may hardcode those details: no paths, ports, window
titles, runtime flags, scene names or capture commands.

## Files

| Path | Purpose |
|---|---|
| [`WORKFLOW.md`](WORKFLOW.md) | The workflow: vocabulary, registry, statuses, evidence layout, checker/fixer loop and comparison gate. |
| [`twin_verify.py`](twin_verify.py) | Registry validator and queue helper: `check`, `next`, `stats`, `list`, `set-status`. |
| [`twin_item.sh`](twin_item.sh) | Per-item evidence helper: `dir`, `stamp`, `capture`, `note`, `log`. |
| [`prompts/checker.md`](prompts/checker.md) | Prompt template for one sequential checker. |
| [`prompts/fixer.md`](prompts/fixer.md) | Prompt template for the single nested fixer a checker may spawn. |
| [`templates/TWIN-VERIFICATION.json`](templates/TWIN-VERIFICATION.json) | Starter registry; copy it to the repository root and replace the legs/items. |
| [`templates/TWIN-COUNTERPART.md`](templates/TWIN-COUNTERPART.md) | Starter counterpart contract; copy it to the repository root. |

Both helpers find the repository by looking for `TWIN-VERIFICATION.json` in the
working directory and above (then the git top level), so they can be run from
any directory. Override with `TWIN_ROOT`, `--root`, `--registry`, `--runs` or
`TWIN_RUNS`.

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
- **No repository-specific facts here.** They belong in the repository's
  `TWIN_COUNTERPART.md` or its own docs.

Start with [`WORKFLOW.md`](WORKFLOW.md).
