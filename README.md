<!-- SPDX-License-Identifier: GPL-3.0-only -->
# ai-tools

Two agent workflows that can be dropped into an existing repository. Nothing
here is specific to one project: the repository-specific facts live in files at
the root of the repository that adopts the workflows.

| Folder | Purpose |
|---|---|
| [`resource-gate/`](resource-gate/AGENTS.md) | Serializes resource-heavy commands and gates waves of parallel subagents on CPU, RAM and disk pressure (Linux/POSIX; PowerShell ports in the `windows` branch). |
| [`twin/`](twin/AGENTS.md) | Proves one behaviour at a time of a port against a read-only reference, with a durable registry and per-item evidence. |

Start with the folder's `AGENTS.md`; it is written to be read and followed by an
agent. `WORKFLOW.md` in `twin/` holds the full procedure.

## Adopt

1. Clone this repository into the target repository, for example at
   `tools/ai-tools` (any depth works; the scripts find the hosting repository
   themselves).
2. Copy the templates to the target repository's root and fill them in:
   - `resource-gate/templates/RESOURCE_INTENSIVE_TASKS_CATALOGUE.md` →
     `RESOURCE_INTENSIVE_TASKS_CATALOGUE.md`
   - `twin/templates/TWIN-COUNTERPART.md` → `TWIN_COUNTERPART.md` (twin only)
   - `twin/templates/TWIN-VERIFICATION.json` → `TWIN-VERIFICATION.json` (twin
     only; or let `twin_verify.py` report that it is missing)
3. Define the resource limits once:
   `resource-gate/resource-monitor.sh --init --cpu-percent 85 --ram-percent 80 --disk-percent 90 --streak 3`

Nothing is installed and nothing is generated: the folders are the tool.

## Requirements

- `resource-gate`: bash, coreutils, `flock` (util-linux), `df`, `git`; Linux or
  WSL.
- `twin`: bash (POSIX helpers) plus Python 3 (registry tool). The twin helpers
  work on any repository whose evidence is captured by shell commands.

## Windows

The `windows` branch carries the same workflows with PowerShell ports
(`resource-monitor.ps1`, `run-resource-intensive-task.ps1`, `twin_item.ps1`,
`twin_verify.ps1`). Use that branch on Windows machines; use this one on Linux
(including WSL).
