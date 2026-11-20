<!-- SPDX-License-Identifier: GPL-3.0-only -->
# ai-tools (Windows)

Two agent workflows that can be dropped into an existing repository. Nothing
here is specific to one project: the repository-specific facts live in files at
the root of the repository that adopts the workflows.

| Folder | Purpose |
|---|---|
| [`resource-gate/`](resource-gate/AGENTS.md) | Serializes resource-heavy commands and gates waves of parallel subagents on CPU, RAM and disk pressure (PowerShell; the `linux` branch has the bash ports). |
| [`twin/`](twin/AGENTS.md) | Proves one behaviour at a time of a port against a read-only reference, with a durable registry and per-item evidence. |

Start with the folder's `AGENTS.md`; it is written to be read and followed by an
agent. `WORKFLOW.md` in `twin/` holds the full procedure.

## Adopt

1. Clone this repository into the target repository, for example at
   `tools\ai-tools` (any depth works; the scripts find the hosting repository
   themselves).
2. Copy the templates to the target repository's root and fill them in:
   - `resource-gate\templates\RESOURCE_INTENSIVE_TASKS_CATALOGUE.md` ->
     `RESOURCE_INTENSIVE_TASKS_CATALOGUE.md`
   - `twin\templates\TWIN-COUNTERPART.md` -> `TWIN_COUNTERPART.md` (twin only)
   - `twin\templates\TWIN-VERIFICATION.json` -> `TWIN-VERIFICATION.json` (twin
     only)
3. Define the resource limits once:
   `resource-gate\resource-monitor.ps1 --init --cpu-percent 85 --ram-percent 80 --disk-percent 90 --streak 3`

Nothing is installed and nothing is generated: the folders are the tool.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 (the `pwsh` tool is not required).
- `git` on `PATH` (used to find the hosting repository and its shared queue
  state).
- Python 3 (`python` or `py -3`) for the twin registry tool.
- If execution policy blocks the scripts, run them with
  `powershell -ExecutionPolicy Bypass -File <script> <args>` or set the process
  scope.

## Linux

The `linux` branch carries the same workflows as POSIX shell (`resource-monitor.sh`,
`run-resource-intensive-task.sh`, `twin_item.sh`, `twin_verify.py`). Use that
branch on Linux (including WSL); use this one on Windows.
