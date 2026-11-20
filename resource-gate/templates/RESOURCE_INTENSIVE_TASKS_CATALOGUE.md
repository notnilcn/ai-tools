<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Resource-intensive task catalogue

Copy this file to the root of the repository that adopted the resource gate,
name it `RESOURCE_INTENSIVE_TASKS_CATALOGUE.md`, and replace the examples with
that repository's own commands. `run-resource-intensive-task.sh --list` prints
this file.

Rules for an agent reading this file:

- Run every command here through the queue, never directly:
  `resource-gate/run-resource-intensive-task.sh --cmd -- <command>`
- One queued task at a time. Check `--status`, or let the queue make you wait.
- `--name <label>` records a readable label in the queue holder and history; use
  it so `--status` explains what is running.
- Queued work is exempt from the resource monitor. Anything you run outside the
  queue still counts as unmanaged pressure.

| Task | Command | Why it is queued |
|---|---|---|
| build | `<build command>` | compiles every target |
| test | `<test command>` | saturates all cores |
| lint | `<lint/typecheck command>` | scans the whole tree |
| export | `<export/package command>` | writes large artifacts |
| benchmark | `<benchmark command>` | needs an idle machine for stable numbers |

## Notes

- Commands must be non-interactive and must run to completion on their own.
- Prefer the project's own wrapper scripts over raw tool invocations.
- If a command writes to a shared output directory, say so here so nobody runs
  something else that reads it at the same time.
