# composer-delta fixtures

Real terminal captures driving the portable regression for the pre-Enter
delivery proof (`fm_composer_delivery_delta_verdict`, `bin/fm-composer-lib.sh`)
in [`tests/fm-composer-lib.test.sh`](../../fm-composer-lib.test.sh).

They are captures rather than hand-drawn boxes on purpose.
A hand-drawn fixture can only confirm the shape assumption its author already
wrote into it, and the proof under test exists precisely because no such
assumption survives contact with a real vendor renderer.

## Provenance

Captured 2026-08-22 on macOS Darwin 25.5.0 (arm64) with tmux 3.6a, each harness
launched in its own isolated tmux server (`tmux -L fmdelta<n>`, all torn down)
in a fresh empty workspace, at 100x40.
Each `<name>.before.*` / `<name>.after.*` pair is one real send: capture, type
the 152-character payload once with `tmux send-keys -l`, capture again.
Enter was never pressed, so the `after` screen is the pane exactly as the
pre-Enter proof sees it.
The payload is the `PAYLOAD` constant in the test.

`.plain` is `tmux capture-pane -p`; `.ansi` is `tmux capture-pane -p -e`.
Both fidelities of one scenario must produce the same verdict, which is the
regression that keeps the deleted styled/plain fork from returning.

| fixture | harness | scenario |
|---|---|---|
| `claude-healthy` | Claude Code 2.1.239 | healthy send into a bare-rule composer |
| `claude-trust` | Claude Code 2.1.239 | workspace-trust dialog; the payload was swallowed whole |
| `codex-healthy` | codex-cli 0.147.0 | healthy send into a boxed composer |
| `codex-launch` | codex-cli 0.147.0 | directory-trust dialog; typing exited the pane |
| `opencode-healthy` | opencode 1.14.46 | healthy send into a left-bar composer that hard-wraps mid-word and is not bottom-anchored |
| `opencode-launch` | opencode 1.14.46 | vendor update modal; the payload was swallowed whole and the modal scores as NOT gated |
| `cursor-healthy` | Cursor Agent 2026.08.11-e8db854 | healthy send |
| `grok-healthy` | grok 1.0.5 | healthy send |
| `muse-healthy` | Muse Code 0.2.1 | healthy send into a separated composer |
| `pi-healthy` | pi 0.84.1 | healthy send into a separated composer |
| `pisigned-healthy` | pi-signed 0.84.1 | healthy send |

## Sanitization

Applied identically to both sides of every pair, so each remains a faithful
before/after of one real send: the account e-mail was replaced with
`agent@example.invalid`, a personal greeting was blanked, and absolute
workspace and socket paths were replaced with `/tmp/fixture-workspace` and
`/tmp/tmux`. Nothing else was edited; no fixture was hand-drawn or repaired.

## Refreshing

These pin vendor renderings at the versions above and will drift.
The tier that catches drift is the env-gated live guard, not these bytes: run
`FM_LIVE_HARNESS=1 bin/fm-test-run.sh tests/fm-composer-delta-live-e2e.test.sh`
after any harness upgrade, and record the dated result in
[`docs/verification/runtime-backends.md`](../../../docs/verification/runtime-backends.md).
Re-capture a fixture only from a real harness, never by editing one of these
files to make a test pass.
