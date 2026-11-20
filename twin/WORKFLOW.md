<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Twin-verification workflow

A twin walk proves that one item of a port behaves like its reference. It is
deliberately small: one item at a time, one comparison gate, one durable status.

## 1. Vocabulary

| Term | Meaning |
|---|---|
| **Reference** | The read-only non-Godot counterpart (see `../../TWIN_COUNTERPART.md`). The reference leg is the source of truth. |
| **Port** | The implementation being verified. The port leg is what a run drives. |
| **Item** | One verifiable behaviour, keyed in the registry (`TWIN-0001`, `PAR-0042`, …). |
| **Fork** | The recorded tool calls that put both legs into the item's starting state. |
| **Action** | The recorded tool calls that exercise the behaviour and capture the verdict. |
| **Evidence** | Fresh frames/logs written under `runs/<item>/` for this run. |
| **Gap** | A behavioural difference between the reference and the port. A gap is either fixed (`twin-verified`) or accepted and documented (`reference-verified`). |
| **Terminal** | `reference-verified` or `twin-verified`. Every other status is still open. |

The reference and port leg names are deployment details. `twin_verify.py`
reads them from the registry; `TWIN_COUNTERPART.md` names them for humans. The
defaults are `reference` and `port`. Registries that use concrete names (for
example `java`/`godot`) declare them in the `legs` object.

## 2. Inputs

| Input | Default | Notes |
|---|---|---|
| Counterpart contract | `../../TWIN_COUNTERPART.md` | Required. Names the reference checkout and the leg-specific commands. |
| Registry | `./TWIN-VERIFICATION.json` | One file in the repo root; override with `--registry` or `TWIN_REGISTRY`. |
| Evidence root | `./runs` | Override with `--runs` or `TWIN_RUNS`. |

Adopt the workflow by copying
[`templates/TWIN-VERIFICATION.json`](templates/TWIN-VERIFICATION.json) to the
repo root and replacing its example item and legs.

## 3. Registry schema

```json
{
  "schema": "ai-tools/twin-verification@1",
  "updated": "2026-11-18T00:00:00Z",
  "legs": { "reference": "reference", "port": "port" },
  "terminal_statuses": ["reference-verified", "twin-verified"],
  "items": {
    "TWIN-0001": {
      "title": "Main menu identity",
      "status": "seeded",
      "similarity": 99.2,
      "fork": {
        "reference": [{ "tool": "shell", "params": { "cmd": "…" } }],
        "port": [{ "tool": "ui", "params": { "action": "open" } }]
      },
      "action": {
        "reference": [{ "tool": "shell", "params": { "cmd": "…" } }],
        "port": [{ "tool": "ui", "params": { "action": "click" } }]
      },
      "images": {
        "reference": ["runs/TWIN-0001/reference/20261118-120000-01-action.png"],
        "port": ["runs/TWIN-0001/port/20261118-120000-01-action.png"]
      },
      "acceptance": ["the title bar shows the same label and position"],
      "notes": "Any accepted difference goes here."
    }
  },
  "recipes": {},
  "gaps": []
}
```

- `fork` and `action` are optional; when present, each declared leg must have a
  non-empty call list.
- `images` is optional; when present, every leg list must be non-empty and
  index-aligned.
- `recipes` may carry reusable named sequences. `paired_with` and
  `also_covers` must resolve to another recipe.
- `gaps` is the global accepted-difference list; entries must be non-empty
  strings.
- Keep prose short. The registry is a ledger, not a report.

Validate it with:

```bash
python3 twin_verify.py check
python3 twin_verify.py check --evidence   # also require per-item run folders
```

## 4. Statuses

| Status | Meaning | Required evidence |
|---|---|---|
| `seeded` | Recorded, not yet walked. | none |
| `in-progress` | A checker is walking it. | none |
| `mismatch` | Walked; a gap is confirmed and not yet fixed. | port frames + run report |
| `fixing` | One fixer owns the item. | none |
| `blocked` | The item cannot be reached yet (environment/profile dependency). | run report |
| `wontfix` | Accepted but not closed as a twin match. | run report |
| `reference-verified` | The port matched the recorded reference; no code change. | port frames + run report |
| `twin-verified` | A gap was fixed and fresh reference + port legs match. | frames in both legs + run report + fix evidence |

`reference-verified` and `twin-verified` are the only terminal statuses. An
accepted difference is still `reference-verified` when the reference itself is
the accepted outcome; record the difference in `notes`/`gaps` and in the run
report.

## 5. Evidence layout

```
runs/
  TWIN-0001/
    reference/                     # reference frames for this item (may stay empty)
      20261118-120000-01-action.png
    port/                          # port frames for this item
      20261118-120000-01-action.png
    20261118-120000-run.md         # what ran, what was compared, verdict
    20261118-120000-run.json       # optional structured evidence
    20261118-120000-reference.log  # optional captured log
```

Rules:

- One folder per item; never `runs/<stamp>-<item>/`.
- Frames only under the two leg folders; logs and reports at the item root.
- Every filename starts with `YYYYmmdd-HHMMSS-` (local time), then a short label.
- The reference folder may stay empty for a `reference-verified` item; a
  `twin-verified` item must have fresh frames in both legs.
- `runs/` is transient and git-ignored. The registry is the durable verdict.
- Use `twin_item.sh` so timestamps and paths stay consistent:

```bash
./twin_item.sh dir TWIN-0001
./twin_item.sh stamp
./twin_item.sh capture port TWIN-0001 01-action -- <capture-command-from-TWIN_COUNTERPART>
./twin_item.sh note TWIN-0001 run "compared title bar; matches"
```

## 6. The loop

The orchestrator owns the queue and the sequential width. It never walks items
itself.

1. **Pick.** `python3 twin_verify.py next` prints the first non-terminal item.
2. **Check.** Spawn exactly one checker at that item, using
   [`prompts/checker.md`](prompts/checker.md), capped at a small batch (10–12
   items) and told to stop at the first gap.
3. **Fix.** If the checker finds a gap, it records `mismatch`, writes the run
   report, spawns exactly one nested fixer with
   [`prompts/fixer.md`](prompts/fixer.md), waits, verifies the fresh evidence,
   then stops. The fixer may set `twin-verified` only when both legs match.
4. **Repeat.** Start the next checker at the new first non-terminal item.
5. **Close.** When `twin_verify.py check --evidence` is clean and every item is
   terminal, the walk is complete.

Before the first wave, the orchestrator runs the resource monitor from
`../resource-gate/resource-monitor.sh` (see that folder's `AGENTS.md`). Queued
heavy work is exempt from the monitor; checkers should still avoid running
heavy builds outside the queue.

## 7. Checker procedure

For each item, in order:

1. Read the item record, the recipes it references, the counterpart contract,
   and the relevant reference source or archived evidence. Read-only.
2. Establish the fork. Restart a client when profile state matters; replay the
   recorded `fork` calls rather than faking state, unless the item explicitly
   says otherwise.
3. Drive the action on the port leg with real input. Prefer one batched input
   sequence over many tiny calls.
4. Capture the verdict frame(s) under `runs/<item>/port/`. Capture the
   reference only when the item needs a fresh reference or the contract says
   to; never write into the counterpart checkout.
5. Compare:
   - frame vs. frame when a reference frame exists;
   - otherwise the recorded `acceptance` assertions plus the reference source
     and structured runtime state.
6. PASS → set `reference-verified` with
   `python3 twin_verify.py set-status <ID> reference-verified`, write
   `runs/<item>/<stamp>-run.md`, continue.
7. GAP → set `mismatch` the same way, write the run report with the symptom and
   the exact reproduction, spawn one fixer, wait, verify, then stop.

A checker does not edit product source and does not run the heavy build. The
fixer owns the source change and the fresh two-leg verification.

## 8. Fixer procedure

1. Read the item, the run report, the counterpart contract and the port's
   contributor rules.
2. Reproduce both legs at the same fork.
3. Fix the port. Keep the change minimal, cite the upstream/reference source in
   the touched files, and add a test or oracle check when the behaviour is
   testable.
4. Rebuild and restart the port client if the runtime loaded the old build.
5. Replay both legs, capture fresh frames in both leg folders, and write the
   run report (gap, fix, evidence).
6. Set `twin-verified` only when the fresh reference and port evidence match
   (`python3 twin_verify.py set-status <ID> twin-verified`). Otherwise leave it
   `fixing`/`mismatch` with the residual written down.

## 9. Comparison gate

- **Frames:** compare the same viewport/size. Use a diff helper when one is
  available; record `similarity = 100 * (1 - changed_fraction)` when a numeric
  diff is used.
- **Assertions:** when no frame exists, assert the recorded acceptance criteria
  and the reference-source behaviour. Include the structured state in the run
  report.
- **Tolerance:** differences that are accepted (font rendering, platform
  chrome, profile-dependent state) belong in `notes`/`gaps`; they are not a
  reason to loosen the gate silently.
- **Determinism:** restart from the same fork; do not reuse a state produced by
  a different item's action.

## 10. Guardrails

- One checker, one client instance per leg, one nested fixer.
- Never switch the repo's branch or worktree from inside a checker.
- Never edit the registry outside the item you are walking, except for the
  single `set-status` call.
- Never edit `runs/archive/**` or frozen reference evidence.
- Never run two heavy builds; use the resource gate's queue.
- Finish a checker run with a clean registry check and a short final reply:
  `start=<id> next=<id> checked=<n> gap=<id|none> fixed=<yes|no|n/a>`.
