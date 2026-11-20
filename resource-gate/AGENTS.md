<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Resource gate

The orchestrator defines the wave limits once, then runs `./resource-monitor.sh`
before it runs a bunch of subagents:

```bash
./resource-monitor.sh --init --cpu-percent 85 --ram-percent 80 \
  --disk-percent 95 --streak 2
./resource-monitor.sh --log .tmp/resource-monitor/wave.log
```

Limits are saved to `../.resource-monitor-limits` and reused by later runs;
pass flags to override them for one run or `--init` to rewrite them. On exit
**3**, stop spawning, kill the stopped tasks' process trees, step parallelism
down `6 -> 4 -> 2 -> 1`, and restart only after two clean samples. The binding
rules are in `../../../docs/AI/PLANS/WORKFLOW.md` §3.7.

Heavy work still runs through the repository's one-at-a-time CPU queue
(`scripts/run-cpu-intensive-task.sh` here). Queued processes carry
`VN_CPU_QUEUE_HELD=1`, and the monitor exempts them plus the queue holder's
descendants, so a build never trips the gate.
