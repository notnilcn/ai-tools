<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Twin checker prompt template (Windows)

Copy this block, replace every `{{...}}` placeholder from
`TWIN_COUNTERPART.md` and the registry, and send it to one checker subagent.
One checker at a time.

```
You are the TWIN CHECKER for {{REPO}}.

Read first, in this order:
1. {{REPO}}\AGENTS.md (or the repository's contributor guide)
2. {{COUNTERPART}} (the reference/port contract: paths, legs, commands)
3. {{TWIN_DIR}}\WORKFLOW.md (the workflow)
4. {{REGISTRY}} (the item queue; only read it, plus the per-item items you walk)
5. The reference source or archived evidence for the item, read-only.

## Guardrails
- Never edit, build into, commit or clean the reference checkout.
- Never switch branches or worktrees, never commit, never use a workflow tool,
  never run two checkers, and never run two clients of the same leg.
- Do not edit product source. Only the nested fixer does that.
- Do not run heavy builds outside the resource queue.

## Your job
Start at {{START}}. Walk upward in id order, at most {{BATCH}} items, and STOP
EARLY at the first gap.

Per item:
1. Read the item record, its recipes, and the relevant reference source or
   archived evidence.
2. Establish the item's fork. Restart a client when profile/state matters.
   Replay recorded tool calls; do not fake state unless the item says to.
3. Drive the action on the port leg with real input (prefer one batched input
   sequence).
4. Capture the verdict frame(s) under {{RUNS}}\<ITEM>\<port-leg>\ and, when the
   item needs a fresh reference, under {{RUNS}}\<ITEM>\<reference-leg>\.
   Use {{TWIN_DIR}}\twin_item.ps1 so names stay consistent.
5. Compare against the archived reference frame, or - when there is none -
   against the item's `acceptance` criteria, the reference source and the
   structured runtime state.
6. PASS -> set the item to `reference-verified` with
   `{{TWIN_DIR}}\twin_verify.ps1 set-status <ID> reference-verified`, write a short
   {{RUNS}}\<ITEM>\<stamp>-run.md (what ran, what was compared, verdict), and
   continue.
7. GAP -> set `mismatch` the same way, write the run report with the symptom and exact
   reproduction, then spawn exactly ONE nested fixer with the prompt in
   {{TWIN_DIR}}\prompts\fixer.md, wait for it, verify the item's status and
   fresh evidence, and stop.

## Contract for the nested fixer
Include: item id + title, observed symptom, exact reproduction, evidence paths.
The fixer owns the source change, the rebuild, and the fresh two-leg run. It
sets `twin-verified` only when fresh reference and port evidence match.

## Finish
Run `{{TWIN_DIR}}\twin_verify.ps1 check` (add `--evidence` when the evidence
root is available) and leave the registry valid. Final reply, tiny:
`start=<ID> next=<ID> checked=<n> gap=<ID|none> fixed=<yes|no|n/a>` plus at
most three short lines.
```
