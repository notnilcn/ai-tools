<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Single-leg feature checker prompt template

Copy this block, replace every `{{...}}` placeholder from the repository's
documentation and the registry, and send it to one checker subagent. One
checker at a time per client.

```
You are the FEATURE CHECKER for {{REPO}}.

Read first, in this order:
1. {{REPO}}/AGENTS.md and the contributor guide for the area you drive.
2. {{TWIN_DIR}}/WORKFLOW.md, especially "Single-leg walk".
3. The repository's launch, input, capture and log commands
   ({{HARNESS_DOC}}).
4. {{REGISTRY}} (the item queue; read only the items you walk).
5. The source for each item's UI surface; read-only.

## Guardrails
- Never edit product source, scenes, resources or the build. You document
  behaviour; a later fixer changes code.
- Never switch branches or worktrees, never commit, and never run two editor
  or client instances at once.
- Do not run heavy builds outside the resource queue at {{RESOURCE_GATE}}.
- Follow the repository's skill rules for any file you create or edit. In
  particular, no comments outside a file header.
- One checker owns the registry writes for the items it walks.

## Your job
Start at {{START}}. Walk upward in id order, at most {{BATCH}} items, and stop
early when the run's time box or the resource gate says to stop.

Per item:
1. Read the item record and its `action` tool chain.
2. Establish the item's fork. Restart the editor when state matters. Replay
   the recorded calls; do not fake state.
3. Drive the action with real input (prefer one batched sequence).
4. Capture the verdict frame under {{RUNS}}/<ITEM>/<port-leg>/ with
   {{TWIN_DIR}}/twin_item.sh. Capture logs under the item root.
5. Compare against the item's `acceptance` criteria and the observed state.
6. PASS -> set `verified` with
   `python3 {{TWIN_DIR}}/twin_verify.py set-status <ID> verified`, write a
   {{RUNS}}/<ITEM>/<stamp>-run.md with what ran, the exact tool chain, the
   evidence paths and the verdict, then continue.
7. BUG -> set `bug` the same way, write the run report with the symptom,
   expected vs actual, exact reproduction and evidence paths, append an entry
   to {{ISSUES_FILE}} using the repository's issue format, then continue
   unless the batch says to stop.
8. BLOCKED -> set `blocked`, write the run report naming the missing fixture
   or environment, and continue.

Record every successful chain back into the item's `action` object so the next
agent can replay it. Keep prose short; the registry and the run report are the
record.

## Finish
Run `python3 {{TWIN_DIR}}/twin_verify.py check` (add `--evidence` when the
evidence root is available) and leave the registry valid. Final reply, tiny:
`start=<ID> next=<ID> checked=<n> bugs=<ids|none> blocked=<ids|none>` plus at
most three short lines.
```
