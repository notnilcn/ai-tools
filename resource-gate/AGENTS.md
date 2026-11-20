<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Resource gate (Windows)

Instructions for the orchestrating agent. The commands below are PowerShell;
use Windows PowerShell 5.1 or PowerShell 7. If execution policy blocks the
scripts, run them through `powershell -ExecutionPolicy Bypass -File <script>
<args>` or set the process scope first.

## 1. Before a wave of subagents

1. Define the limits once per repository (they are saved, so later waves reuse
   them):

   ```powershell
   .\resource-monitor.ps1 --init --cpu-percent 85 --ram-percent 80 `
     --disk-percent 90 --streak 3
   ```

2. Start the monitor before the first subagent, logging the samples so you can
   read them:

   ```powershell
   Start-Job -FilePath .\resource-monitor.ps1 `
     -ArgumentList '--json', '--log', '.tmp\resource-monitor\monitor.log'
   ```

3. Read the newest sample (`Get-Content -Tail 1 .tmp\resource-monitor\monitor.log`).
   Spawn no more than its `parallel=` value (JSON:
   `recommended_parallel_subagents`) of subagents at a time, and check the
   newest sample again before every further wave.

4. On exit code 3 (pressure) or when the alert JSON appears:

   - stop spawning immediately;
   - read the alert JSON (default `.tmp\resource-monitor\alert.json`); it lists
     the offending processes, the limits, the queue state and the exact
     `required_action`;
   - kill only the process trees of the tasks you are stopping, after checking
     their path/command in the alert;
   - never kill the monitor, the monitor's ancestors, the orchestrator, or the
     queue holder (the alert lists them as protected);
   - resume only after two clean samples, halving the wave width.

The recommendation counts only unqueued work: the monitor follows the queue
holder's process tree, so a queued build cannot make it blame the wave. Exit
code 4 means another monitor already owns the state directory; reuse that one
instead of starting a second.

## 2. Resource-intensive commands

Every command that is heavy enough to disturb other agents (builds, tests,
codegen, asset packing, exports, benchmarks, emulators, headless runs) must run
through the queue, never directly:

```powershell
.\run-resource-intensive-task.ps1 --cmd -- <command> [args...]
.\run-resource-intensive-task.ps1 --name <label> -- <command> [args...]
```

The queue is one-at-a-time across every worktree of the repository. Do not try
to run two of them: the second invocation waits, and `--status` shows who holds
the lock.

The repository's own list of such commands lives in
`RESOURCE_INTENSIVE_TASKS_CATALOGUE.md` at the repository root; `--list` prints
it. Copy [`templates\RESOURCE_INTENSIVE_TASKS_CATALOGUE.md`](templates/RESOURCE_INTENSIVE_TASKS_CATALOGUE.md)
to the repository root to start one.
