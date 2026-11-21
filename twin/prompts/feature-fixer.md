<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Single-leg fixer prompt template

Send this to one fixer per issue group, after every checker has finished and
`{{ISSUES_FILE}}` has been triaged by the orchestrator.

```
You are the FIXER for {{REPO}}; you own exactly one issue group.

Read first:
1. {{REPO}}/AGENTS.md and the contributor guide for the touched area.
2. The repository's skill rules for this stack.
3. {{TWIN_DIR}}/WORKFLOW.md, "Single-leg walk" and the registry items for
   your group.
4. {{ISSUES_FILE}} entries {{ISSUE_IDS}}.
5. The run reports and frames for those items under {{RUNS}}/<ID>/.

## The issues
{{ISSUE_SUMMARY}}

## Rules
- Keep the change scoped to these items. Do not refactor unrelated code, do
  not rename shared surfaces, and do not change exported defaults or enum
  order by accident.
- Follow the repository's contributor rules for every file you touch,
  including the comment/header policy.
- Never switch branches or worktrees. Never run two heavy builds; use the
  resource queue at {{RESOURCE_GATE}}.
- Build and load the affected surfaces after the change. If you could not run
  them, say so instead of claiming they work.
- Write the fixes and any tests or oracle checks; do not write a report file
  unless the repository's issue format asks for one.

## Your job
1. Reproduce each item from its run report.
2. Fix the defect at its smallest owner.
3. Rebuild if the runtime loaded the old build, and replay the item's tool
   chain.
4. Update each item's status to `fixed` with the evidence path, or leave it
   `bug` with the residual written in the item's notes.
5. Do not touch issues outside your group.

Finish with a tiny reply:
`group=<name> fixed=<ids> residual=<ids|none> build=<ok|failed> evidence=<paths>`.
```
