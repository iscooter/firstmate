# Secondmate parent channel

This is the design note and the authoritative contract for how a captain-facing outcome inside a secondmate home reaches the parent firstmate, and through it the captain.
`bin/fm-parent-channel-lib.sh` owns where the channel lives and how a line is appended to it.
`bin/fm-parent-mirror.sh` owns the deterministic mirror of child ledgers onto that channel.
[`remote-secondmates.md`](remote-secondmates.md) owns the transport that carries the remote form of the channel back to the parent.

## The channel

A secondmate home has exactly one parent channel, named by the durable `.fm-secondmate-parent` binding written at seeding.
For a local route it is the parent home's `state/<mate-id>.status`.
For a remote route it is the mate home's own `state/parent-replies.status`, which the parent's remote reply adapter mirrors line for line into that same parent file.
The parent watcher classifies new lines there exactly as it classifies any crewmate's status stream, so a captain-relevant line appended to the channel becomes a parent wake, and a parent wake becomes a captain-facing message.
Nothing else reaches the parent: a secondmate's chat is read by nobody, and the parent never scrapes it.

## The defect this design removes

Four instances on 2026-09-02 across two mate homes showed the same failure.
The watcher delivered the parent's request within a minute every time, the mate did the work, and then the mate addressed "captain" in its own chat instead of appending to the channel.
The cause is structural, not a one-off lapse: `AGENTS.md` tells every firstmate to reach the captain and to address the captain in every response, while the charter's return-channel rule is a smaller, later instruction.
A PR-ready report was the observed symptom, but a finding, a decision, a blocker, and a failure all fail the same way, because every one of them depended on the mate model remembering to write one line.

The design goal is therefore: the parent channel must not depend on the model remembering to write to it.

## Candidate mechanisms

Four mechanisms were evaluated together against coverage across all outcome kinds, harness independence, false-positive noise, and failure direction.

### A. Turn-end text mirror

At the mate's turn end, if the assistant turn contained captain-facing text and no parent append happened, mirror a bounded note of that text to the channel.

- Coverage looks total but the predicate is empty: every firstmate turn contains captain-facing text by mandate, so the hook would fire on every idle turn, and deciding which captain-facing sentence is an outcome is itself a model-behavior judgement.
- Harness dependence is maximal: Claude exposes a transcript path in its Stop payload, Codex and Grok differ, Cursor's stop hook carries no message text and cannot block, Pi needs an extension reading session messages, OpenCode a plugin, and Kimi has no project hooks at all; every one is a harness-dependent check that needs live proof per harness per upgrade.
- Noise is unbounded, and a mirrored sentence that happens to contain a decision verb would open a decision in the parent's fold.
- Failure direction is wrong: an absent or broken hook drops outcomes silently, which is exactly the current failure.

Rejected as a delivery mechanism.

### B. Charter and persona carve-out

Redefine "the captain" inside a secondmate home as the parent channel: no captain in chat, every captain sentence is an append, with a one-line carve-out at each `AGENTS.md` risk point.

- Coverage is total in principle and zero in guarantee; it is the instruction that already failed four times.
- It is still necessary, because it is the only mechanism that can carry an outcome that exists nowhere but in the model's own reasoning, and because it fixes the persona confusion at its source.

Adopted as the belt.

### C. Deterministic ledger mirror

On every supervision poll in a secondmate home, sweep each child's append-only status ledger and mirror every captain-relevant event that has no parent line yet onto the channel.

- Coverage is every outcome that leaves durable evidence in the mate home: a child's terminal done or failed line, a PR ready line, a scout report, and a decision or blocker that stays open.
- Harness independence is complete: the sweep reads files and calls no harness, no forge, and no current-state reader.
- Noise is controlled by a per-child cursor and per-event receipts, so each event is mirrored once, and by an age threshold on decisions, blockers, and failures, so the mate keeps first responder authority and only an event it neither answered nor escalated is raised.
- Failure direction is at-least-once: a missed sweep is retried on the next poll, and a duplicate line is harmless while a missed one is not.
- It runs on the mate side, because only the mate's watcher can read the mate's state, and the existing parent binding and remote transport already carry the result; the parent cannot read a remote mate's ledger at all.

Adopted as the guarantee.

### D. At-source typed lines

Make the scripts that record an outcome in a secondmate home publish the typed parent line themselves at record time.

- Coverage is exactly the recorded outcomes: `bin/fm-pr-check.sh` for a registered PR, `bin/fm-captain-hold.sh` for a task held for the captain and for its answer, `bin/fm-teardown.sh` for a child leaving the home, and the merge outcome path that already existed.
- It is immediate and precise where the mirror is bounded by a poll, and it carries the richest context, such as the canonical PR URL and the hold reason.
- Its gap is every outcome that never passes through a script, which is precisely what C covers.

Adopted, layered under C.

## The adopted design

The delivery rule has one sentence: the machinery reports facts, the mate reports judgement.

1. `bin/fm-parent-channel-lib.sh` is the single owner of channel resolution and idempotent append; it serializes exact-line checks under a bounded destination-specific lock in the writing home's state directory, repairs an unterminated destination tail before deduplication or append, and is used by the merge outcome path, the inactive-outcome scan, the mirror, and every at-source publisher.
2. `bin/fm-parent-mirror.sh sweep` runs on every mate watcher poll and is a silent no-op in a main home.
   For each direct ordinary child it reads only the captured newline-terminated ledger prefix from a durable per-child cursor under `state/parent-mirror/`, mirrors a terminal done line immediately, and mirrors a failed line or a still-open decision or blocker once it has stayed unanswered for `FM_PARENT_MIRROR_OPEN_SECS`.
   Retired and orphaned records remain while an unterminated tail exists, so completion of an in-progress append remains discoverable.
   A mirrored open decision is closed on the channel with a keyed `resolved` line when the child's own decision folds closed, so the parent's open-decision view tracks the mate's.
   The mirrored line names the child, carries the child's own note, and adds the recorded PR URL, the scout report pointer, the delivery mode, and the merge posture when those are recorded, so the parent has what the captain needs without reading the mate home.
3. `bin/fm-pr-check.sh` sweeps the registered child after arming its merge poll, so a PR-ready registration reaches the parent at registration time with the canonical URL, and lock contention is reported as an actionable deferral.
4. `bin/fm-captain-hold.sh` publishes `needs-decision [key=captain-hold-<task>-<occurrence>]` when it holds a task for the captain in a secondmate home and the matching occurrence-keyed `resolved` line when the answer is recorded, including batch answers and idempotent retries.
   The occurrence is derived from the task's durable resolution history, so a re-held task opens a distinct parent decision while an exact retry remains one delivery.
5. `bin/fm-teardown.sh` performs the child's final sweep before it removes the child's record, then retires the child's mirror state; an undelivered final sweep keeps an orphan record that later sweeps retry.
6. `bin/fm-inactive-reconcile.sh` keeps its current-state role and yields to the mirror: in a secondmate home it no longer reports a child whose ledger already ends in a terminal verb, because that evidence is the mirror's, and it still reports a child whose ledger is silent while `bin/fm-crew-state.sh` says done or failed.
7. The charter scaffold in `bin/fm-brief.sh` opens with the channel rule, states that the mirror carries child facts, and confines the mate's own appends to judgement, marked-request answers, and its own blockers; `AGENTS.md` carries a one-line carve-out at the persona address rule and at the escalation list.

## Outcome coverage

| Outcome | Durable evidence in the mate home | Delivered by |
|---|---|---|
| Ship child PR ready | child `done: PR <url> ...` line, then `pr=` in the child's record | D at `fm-pr-check`, C on the next poll |
| PR merged | merge poll or self merge | the existing merge outcome path |
| Scout child findings | child `done:` line plus `data/<child>/report.md` | C on the next poll, D at teardown |
| Child decision escalated | task held for the captain in the mate backlog | D at `fm-captain-hold hold` |
| Child decision or blocker left open | open keyed line in the child ledger | C after the open threshold |
| Child failed | child `failed:` line | C after the open threshold |
| Child ended silently | terminal current state with a silent ledger | the inactive-outcome scan |
| Answer to a marked request | correlated line, guarded by the pending-reply record | the existing pending-reply recovery and escalation |
| An outcome that exists only in the mate's reasoning | none | B only |

## Noise and failure direction

A mate that also appends its own line about a mirrored child produces a second line, never a missed one; the parent reads the mirror line as the fact and the mate's line as commentary.
Every mirrored line uses the injective key `mirror-<child-length>-<child>-<offset-or-key>` and is appended at most once, so distinct child and decision pairs cannot collide and a restart, a replayed sweep, or a relaunched child cannot duplicate a delivered event.
Standing failures retain their ledger offset as event identity, so an identical failure recurring after recovery is delivered as a new event.
An unreadable parent binding is reported once through an atomic bounded append-if-key-absent wake operation in the mate home, so concurrent diagnostics cannot duplicate the episode and wake-queue contention degrades to stderr rather than wedging the watcher.
The mirror needs a live mate watcher, which is already required whenever the mate has work in flight; a mate with no work has no ledger to mirror.

## Regression coverage

`tests/fm-parent-mirror.test.sh` covers the sweep against real ledgers with no harness: immediate done delivery with recorded context and the scout report pointer, whole-line delivery, thresholded decision and failure delivery with keyed close, silence for anything handled inside the threshold, untrackable decision lines, the remote route, the PR registration hook, the retire path with orphan retry, bounded lock waits, main-home inertness, the once-per-episode unreadable-binding diagnostic, and the real watcher poll driving the sweep.
`tests/fm-captain-hold-lifecycle.test.sh` covers a mate home publishing a captain hold and its answer, and the real teardown delivering a scout's final line before retiring its record.
`tests/fm-inactive-reconcile.test.sh` covers the inactive scan yielding terminal-verb ledgers to the mirror while keeping the silent-ledger cases that remain its own.
`tests/fm-pr-merge.test.sh` keeps the merge outcome path's upward reporting and its loud refusal without a binding.
`tests/fm-brief.test.sh` pins the charter's channel rule.
