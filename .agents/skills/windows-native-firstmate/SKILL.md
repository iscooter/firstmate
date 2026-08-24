---
name: windows-native-firstmate
description: >-
  Firstmate on native Windows: the measured Herdr-on-windows-latest findings, why a Bash->Node rewrite is not the fix, the remaining custody-primitive punch-list, and WSL2 as today's answer.
  Load only before evaluating, planning, spiking, or discussing running Firstmate natively on Windows (not WSL2).
user-invocable: false
metadata:
  internal: true
---

# windows-native-firstmate

Firstmate on native Windows: the measured Herdr-on-windows-latest findings, why a Bash->Node rewrite is not the fix, the remaining custody-primitive punch-list, and WSL2 as today's answer. Load only before evaluating, planning, spiking, or discussing running Firstmate natively on Windows (not WSL2).

## What is known

- Firstmate's Bash tooling does not run on native Windows as-is, but a Bash->Node rewrite is NOT the fix: the binding constraints are OS primitives (PTY/terminal, process custody, signals, symlinks, SSH), not the language. Git Bash runs the script logic + coreutils, but not those primitives.
- MEASURED 2026-08-10 on a real windows-latest GitHub runner: Herdr's automation CORE works (bounded spawn->steer->capture->teardown, no hard boundary). Native Windows via Herdr is a measured, bounded punch-list, not a dead end. Remaining FAIL/DEGRADED custody primitives to close before an unattended Windows fleet: symlink lock, lsof, ANSI/cwd/events. WSL2 is today's Windows answer; headless CI proves automation primitives, not the interactive desktop UX.
- Re-runnable via the merged windows-smoke workflow (`workflow_dispatch` on windows-latest, PR #2100).

## Where the detail lives

- Reports `fm-windows-herdr-ci-spike-r1` and `fm-herdr-windows-native-path-followup-s1` in the fmdev-f1 secondmate home, plus the #2100 PR body.
- Open punch-list tracked as backlog item `fm-windows-native-herdr-punchlist-r1`.
