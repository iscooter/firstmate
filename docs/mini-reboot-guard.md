# Mini self-reboot guard

`bin/fm-mini-reboot-guard.sh` and `bin/fm-mini-reboot-lib.sh` detect a genuine memory/kernel-zone leak on a mini host and reboot it, but only when the fleet on that mini is robustly idle.
This replaces an earlier drain/admission-lock design (captain 2026-08-24): there is no drain, no admission lock, no blocking of new work, and no captain-approval-per-reboot step.
If both conditions do not hold, the guard does nothing and the machine handles load best-effort.
This is mini-only by construction; a MacBook (or any unconfigured host) never reboots through this code.

## What it does

A resource sampler records zone bytes, wired memory, free memory, swap use, pressure, and their deltas.
It raises the resource condition only when the maintenance threshold is crossed in three consecutive samples, a recent-window slope forecasts the hard ceiling before the forecast horizon, or pressure is no longer normal with swapouts rising.
It never triggers from a single sample.
An idle check reuses `fm-crew-state.sh`, `tasks-axi`, and the documented `state/` layout to require every child task's reconciled current state to be done, no in-flight backlog item, no open captain decision, no unhandled steering inbox message, no pending remote reply, no promised public reply owed, and no registered process-event source, for every home in the registry.
Any read failure, or a missing backlog file, blocks (fails closed) rather than reading as empty.
Idleness is only confirmed after two consecutive idle reads at least 5 and at most 30 minutes apart, so a single lucky snapshot is never enough.
Only when the resource condition and the confirmed idle window both hold does the guard attempt to execute a reboot.

## Configuration

All of the following are LOCAL and gitignored, read from the coordinating home's `config/` directory (`FM_HOME`, matching every other `bin/fm-*.sh` convention).

- `config/host-role` - must contain exactly `mini`; there is no other way to arm the mini-only gate.
  Absent or any other content refuses every reboot attempt.
- `config/mini-reboot-homes` - one `FM_HOME` path per line, the coordinating home's authoritative list of local homes to idle-check.
  This is a deliberate explicit registry, not a directory glob.
  Absent or empty means no home is registered, so `idle-check-all` always reports busy and the guard never reboots.
- `config/mini-reboot-helper` - the path to an executable, root-authorized reboot helper (for example a signed launchd-privileged-helper, or a narrowly-scoped sudoers `NOPASSWD` entry wrapped in a script that calls `/sbin/shutdown -r now`).
  Provisioning that helper is a separate, deliberate operational step outside this change's scope.
  Absent, unreadable, or non-executable BLOCKS the reboot attempt with a clear diagnostic; this library never fakes or stubs privileged execution.

## Running it

`fm-mini-reboot-guard.sh check` runs one full detect-idle-reboot cycle and is meant to be invoked on a recurring schedule, about every 5 minutes, by an operator-installed `launchd` job or cron entry.
This script does not install its own schedule.
`fm-mini-reboot-guard.sh status` prints a human-readable summary: the mini-only gate state, the current sampler evaluation, a single idle-check-all read, the registered homes, and whether a reboot attempt is currently in flight.
`fm-mini-reboot-guard.sh sample`, `evaluate`, `idle-check`, and `idle-confirm` run one piece of the pipeline in isolation for troubleshooting.

## Safety mechanics

`check` runs under a single-instance lock (`state/mini-reboot/check.lock`) so an overlapping invocation never races; a lock left behind by a dead owner process is reclaimed, never left wedged.
A successful reboot attempt writes a marker (`state/mini-reboot/reboot-in-progress`) before invoking the helper, so a hung or slow helper cannot cause an immediate re-fire on the next scheduled tick.
The marker self-clears once the live boot-session id (`kern.bootsessionuuid`) differs from the recorded one - the reboot actually happened - or once it is older than 20 minutes and the machine evidently did not reboot.
Nothing in this guard uses `--force`, kills a process, aborts a running validation, or discards a worktree to make a check pass; a blocking condition is meant to block.
