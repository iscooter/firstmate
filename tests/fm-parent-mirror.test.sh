#!/usr/bin/env bash
# Behavioral coverage for the secondmate parent-channel mirror
# (bin/fm-parent-mirror.sh, bin/fm-parent-mirror-lib.sh,
# bin/fm-parent-channel-lib.sh): every child ledger event a parent is owed
# reaches the parent channel without the mate model appending anything.
# docs/secondmate-parent-channel.md owns the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MIRROR="$ROOT/bin/fm-parent-mirror.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-parent-mirror)
PR_URL=https://github.com/owner/repo/pull/7

make_tools() { # <world>
  local world=$1 fake tool
  fake="$world/fakebin"
  mkdir -p "$fake" "$world/root/bin"
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
SH
  for tool in gh gh-axi curl glab; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_FORGE_LOG:?}"
exit 97
SH
  done
  cat > "$world/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake"/* "$world/root/bin/fm-guard.sh"
}

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  MATE="$WORLD/mate"
  mkdir -p "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects,bin}
  : > "$MATE/AGENTS.md"
  make_tools "$WORLD"
  : > "$WORLD/forge.log"
}

bind_secondmate() { # <local|remote>
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  if [ "$1" = local ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
  else
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$MATE/.fm-secondmate-parent"
  fi
}

write_child() { # <home> <id> [kind] [spawn-gen]
  local home=$1 id=$2 kind=${3:-ship} spawn_gen=${4:-gen-one}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" "project=alpha" \
    'harness=codex' "kind=$kind" 'mode=no-mistakes' 'yolo=off' "spawn_gen=$spawn_gen"
}

ledger() { # <home> <id> <line>...
  local home=$1 id=$2
  shift 2
  printf '%s\n' "$@" >> "$home/state/$id.status"
}

sweep() { # <home> <now> [args...]
  local home=$1 now=$2
  shift 2
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PARENT_MIRROR_NOW="$now" FM_PARENT_MIRROR_OPEN_SECS=60 FM_FORGE_LOG="$WORLD/forge.log" \
    "$MIRROR" sweep "$@"
}

parent_channel() { printf '%s/state/mate.status\n' "$MAIN"; }

channel_count() { # <pattern>
  grep -c -F -- "$1" "$(parent_channel)" 2>/dev/null || true
}

channel_lines() { wc -l < "$(parent_channel)" 2>/dev/null | tr -d ' ' || printf '0'; }

parent_open_decisions() {
  bash -c '. "$1"; status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$(parent_channel)"
}

record_field() { # <child> <key>
  grep "^$2=" "$MATE/state/parent-mirror/$1.record" 2>/dev/null | cut -d= -f2- || true
}

wake_count() { # <home> <key>
  grep -c -F -- "$2" "$1/state/.wake-queue" 2>/dev/null || true
}

prime_seen() { # <state> <status>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# A child's done line reaches the parent on the next sweep, carrying the
# recorded PR, the delivery mode, and the merge posture; a repeat sweep
# appends nothing, so the delivery is exactly once.
test_done_line_delivered_once() {
  local out size
  make_world 'done'; bind_secondmate local
  write_child "$MATE" child
  printf 'pr=%s\n' "$PR_URL" >> "$MATE/state/child.meta"
  ledger "$MATE" child 'working: setup complete' "done: PR $PR_URL checks green"
  out=$(sweep "$MATE" 1000) || fail "sweep failed: $out"
  [ -z "$out" ] || fail "a clean sweep printed output: $out"
  [ "$(channel_count "done [key=mirror-5-child-l")" = 1 ] || fail "done line was not delivered once"
  grep -F "mirror: child=child PR $PR_URL checks green pr=$PR_URL mode=no-mistakes yolo=off" "$(parent_channel)" >/dev/null \
    || fail "delivered line lacks the child's note or its recorded context: $(cat "$(parent_channel)")"
  sweep "$MATE" 1001 >/dev/null || fail "second sweep failed"
  [ "$(channel_lines)" = 1 ] || fail "second sweep duplicated the delivered line"
  size=$(wc -c < "$MATE/state/child.status" | tr -d ' ')
  [ "$(record_field child offset)" = "$size" ] || fail "record cursor did not advance to the ledger end"
  pass "a child's done line is delivered once with its recorded context"
}

# A scout's done line carries the report pointer so the parent can read the
# findings without entering the mate home.
test_scout_report_pointer() {
  make_world scout; bind_secondmate local
  write_child "$MATE" scout scout
  mkdir -p "$MATE/data/scout"
  printf '# findings\n' > "$MATE/data/scout/report.md"
  ledger "$MATE" scout 'done: investigation complete, three findings'
  sweep "$MATE" 1000 >/dev/null || fail "sweep failed"
  grep -F "mirror: child=scout investigation complete, three findings report=data/scout/report.md" "$(parent_channel)" >/dev/null \
    || fail "scout delivery lacks the report pointer: $(cat "$(parent_channel)")"
  pass "a scout's done line carries its report pointer"
}

test_scratch_paths_refuse_symlink_redirection() {
  local target rc
  make_world scratch-symlink; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'done: safe scratch test'
  mkdir -p "$MATE/state/parent-mirror"
  target="$WORLD/external-target"
  printf 'sentinel\n' > "$target"
  rc=0
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" bash -c '
    . "$1"
    ln -s "$2" "$STATE/parent-mirror/child.record.capture.$$"
    fm_parent_mirror_sweep_child_locked child
  ' _ "$ROOT/bin/fm-parent-mirror-lib.sh" "$target" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "safe scratch allocation refused a harmless stale predictable symlink"
  [ "$(cat "$target")" = sentinel ] || fail "predictable scratch symlink changed its target"

  make_world scratch-dir-symlink; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'done: unsafe directory test'
  mkdir -p "$WORLD/external-dir"
  printf 'sentinel\n' > "$WORLD/external-dir/target"
  ln -s "$WORLD/external-dir" "$MATE/state/parent-mirror"
  rc=0
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" bash -c '
    . "$1"; fm_parent_mirror_sweep_child_locked child
  ' _ "$ROOT/bin/fm-parent-mirror-lib.sh" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "mirror accepted a symlinked scratch directory"
  [ "$(cat "$WORLD/external-dir/target")" = sentinel ] || fail "symlinked mirror directory changed external data"
  [ ! -e "$WORLD/external-dir/child.record" ] || fail "symlinked mirror directory received a record"
  pass "mirror scratch allocation refuses symlink redirection"
}

# Only whole lines are delivered: a line still being appended waits for its
# newline, then is delivered on the next sweep.
test_partial_line_waits_for_newline() {
  make_world partial; bind_secondmate local
  write_child "$MATE" child
  printf 'done: PR %s checks green' "$PR_URL" > "$MATE/state/child.status"
  sweep "$MATE" 1000 >/dev/null || fail "sweep failed"
  [ ! -e "$(parent_channel)" ] || fail "an unterminated line was delivered: $(cat "$(parent_channel)")"
  printf '\n' >> "$MATE/state/child.status"
  sweep "$MATE" 1001 >/dev/null || fail "second sweep failed"
  [ "$(channel_count "done [key=mirror-5-child-l0]")" = 1 ] || fail "the completed line was not delivered"
  pass "an unterminated ledger line waits for its newline"
}

# Unterminated thresholded outcomes do not become standing state and do not
# begin aging until their terminating newline is captured.
test_orphan_retains_unterminated_tail() {
  make_world orphan-tail; bind_secondmate local
  write_child "$MATE" child
  printf 'done: still being written' > "$MATE/state/child.status"
  sweep "$MATE" 1000 >/dev/null || fail "tail priming sweep failed"
  rm -f "$MATE/state/child.meta"
  sweep "$MATE" 1001 >/dev/null || fail "partial orphan sweep failed"
  [ "$(record_field child tail)" = 1 ] || fail "orphan record did not retain its incomplete tail"
  [ ! -e "$(parent_channel)" ] || fail "partial orphan tail was delivered"
  printf '\n' >> "$MATE/state/child.status"
  sweep "$MATE" 1002 >/dev/null || fail "completed orphan sweep failed"
  grep -F 'done [key=mirror-5-child-l0]: mirror: child=child still being written' "$(parent_channel)" >/dev/null \
    || fail "completed orphan tail was not delivered"
  [ ! -e "$MATE/state/parent-mirror/child.record" ] || fail "completed orphan record was not retired"
  pass "an orphan retains an unterminated tail until it completes"
}

test_partial_thresholded_outcomes_do_not_age() {
  make_world partial-failed; bind_secondmate local
  write_child "$MATE" child
  printf 'failed: build still writing' > "$MATE/state/child.status"
  sweep "$MATE" 1000 >/dev/null || fail "partial failure first sweep failed"
  sweep "$MATE" 1060 >/dev/null || fail "partial failure second sweep failed"
  [ -z "$(record_field child terminal_line)" ] || fail "an unterminated failure became standing state"
  [ ! -e "$(parent_channel)" ] || fail "an unterminated failure was delivered"
  printf '\n' >> "$MATE/state/child.status"
  sweep "$MATE" 1061 >/dev/null || fail "completed failure first sweep failed"
  [ "$(record_field child terminal_first_seen)" = 1061 ] || fail "failure aged before its newline"
  [ ! -e "$(parent_channel)" ] || fail "a newly completed failure skipped the threshold"
  sweep "$MATE" 1121 >/dev/null || fail "completed failure threshold sweep failed"
  grep -F 'failed [key=mirror-5-child-l0]: mirror: child=child build still writing (unhandled past 60s)' "$(parent_channel)" >/dev/null \
    || fail "the completed failure was not delivered after its full threshold"

  make_world partial-decision; bind_secondmate local
  write_child "$MATE" child
  printf 'needs-decision [key=api]: choose one' > "$MATE/state/child.status"
  sweep "$MATE" 2000 >/dev/null || fail "partial decision first sweep failed"
  sweep "$MATE" 2060 >/dev/null || fail "partial decision second sweep failed"
  [ -z "$(record_field child open)" ] || fail "an unterminated decision became open state"
  [ ! -e "$(parent_channel)" ] || fail "an unterminated decision was delivered"
  printf '\n' >> "$MATE/state/child.status"
  sweep "$MATE" 2061 >/dev/null || fail "completed decision first sweep failed"
  [ ! -e "$(parent_channel)" ] || fail "a newly completed decision skipped the threshold"
  sweep "$MATE" 2121 >/dev/null || fail "completed decision threshold sweep failed"
  grep -F 'needs-decision [key=mirror-5-child-api]' "$(parent_channel)" >/dev/null \
    || fail "the completed decision was not delivered after its full threshold"
  pass "unterminated failures and decisions neither stand nor age"
}

# An open decision is raised only after it stands past the threshold, is
# keyed so the parent's own fold opens it, and is closed on the parent when
# the child's fold closes it.
test_open_decision_thresholded_then_closed() {
  make_world decision; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'needs-decision [key=api]: choose A or B'
  sweep "$MATE" 1000 >/dev/null || fail "first sweep failed"
  [ ! -e "$(parent_channel)" ] || fail "a fresh decision was raised before the threshold: $(cat "$(parent_channel)")"
  sweep "$MATE" 1030 >/dev/null || fail "second sweep failed"
  [ ! -e "$(parent_channel)" ] || fail "a decision inside the threshold was raised"
  sweep "$MATE" 1060 >/dev/null || fail "third sweep failed"
  grep -F 'needs-decision [key=mirror-5-child-api]: mirror: child=child decision api (opened at line 1) open past 60s without an answer or a captain hold: choose A or B' "$(parent_channel)" >/dev/null \
    || fail "the standing decision was not raised: $(cat "$(parent_channel)")"
  parent_open_decisions | grep -q "^mirror-5-child-api	needs-decision	" \
    || fail "the parent's fold did not open the mirrored decision"
  sweep "$MATE" 1200 >/dev/null || fail "fourth sweep failed"
  [ "$(channel_lines)" = 1 ] || fail "a standing decision was raised twice"
  ledger "$MATE" child 'resolved [key=api]: chose A'
  sweep "$MATE" 1300 >/dev/null || fail "closing sweep failed"
  grep -F 'resolved [key=mirror-5-child-api]: mirror: child=child decision api (opened at line 1) closed' "$(parent_channel)" >/dev/null \
    || fail "the closed decision was not closed on the parent: $(cat "$(parent_channel)")"
  [ -z "$(parent_open_decisions)" ] || fail "the parent's fold still holds the closed decision: $(parent_open_decisions)"
  pass "an open decision is raised past the threshold and closed with the child's own close"
}

test_failed_decision_close_retries_without_child_change() {
  local rc=0
  make_world close-retry; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'needs-decision [key=api]: choose A or B'
  sweep "$MATE" 1000 >/dev/null || fail "first sweep failed"
  sweep "$MATE" 1060 >/dev/null || fail "opening sweep failed"
  ledger "$MATE" child 'resolved [key=api]: chose A'
  chmod 0400 "$(parent_channel)"
  sweep "$MATE" 1100 >/dev/null 2>&1 || rc=$?
  chmod 0600 "$(parent_channel)"
  [ "$rc" -ne 0 ] || fail "an unwritable parent close reported success"
  [ "$(channel_count 'resolved [key=mirror-5-child-api]')" = 0 ] || fail "the failed close was unexpectedly delivered"
  sweep "$MATE" 1101 >/dev/null || fail "unchanged retry sweep failed"
  [ "$(channel_count 'resolved [key=mirror-5-child-api]')" = 1 ] || fail "the failed close was not retried"
  [ -z "$(parent_open_decisions)" ] || fail "the retried close left the parent decision open"
  pass "a failed decision close retries without another child append"
}

# The same key re-opened after a close, even with the same note, is a new
# opening: it is raised and closed again rather than lost to deduplication.
test_reopened_decision_is_raised_again() {
  make_world reopen; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'needs-decision [key=api]: choose A or B'
  sweep "$MATE" 1000 >/dev/null || fail "first sweep failed"
  sweep "$MATE" 1060 >/dev/null || fail "second sweep failed"
  ledger "$MATE" child 'resolved [key=api]: chose A'
  sweep "$MATE" 1100 >/dev/null || fail "closing sweep failed"
  ledger "$MATE" child 'needs-decision [key=api]: choose A or B'
  sweep "$MATE" 1200 >/dev/null || fail "re-open sweep failed"
  sweep "$MATE" 1260 >/dev/null || fail "re-open threshold sweep failed"
  grep -F 'decision api (opened at line 3) open past 60s' "$(parent_channel)" >/dev/null \
    || fail "the re-opened decision was not raised: $(cat "$(parent_channel)")"
  parent_open_decisions | grep -q "^mirror-5-child-api	needs-decision	" \
    || fail "the parent's fold did not re-open the decision"
  ledger "$MATE" child 'resolved [key=api]: chose B after all'
  sweep "$MATE" 1300 >/dev/null || fail "second closing sweep failed"
  grep -F 'decision api (opened at line 3) closed' "$(parent_channel)" >/dev/null \
    || fail "the re-opened decision was not closed again: $(cat "$(parent_channel)")"
  [ "$(channel_lines)" = 4 ] || fail "expected two openings and two closes, got: $(cat "$(parent_channel)")"
  [ -z "$(parent_open_decisions)" ] || fail "the parent's fold still holds the re-closed decision"
  pass "a decision re-opened under the same key is raised and closed again"
}

# A decision the mate answers, or transfers to a captain hold, inside the
# threshold is never raised: the mate stays the first responder.
test_decision_handled_inside_threshold_is_silent() {
  make_world handled; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'blocked [key=creds]: need the deploy token'
  sweep "$MATE" 1000 >/dev/null || fail "first sweep failed"
  ledger "$MATE" child 'resolved [key=creds]: token provided'
  sweep "$MATE" 1030 >/dev/null || fail "second sweep failed"
  sweep "$MATE" 2000 >/dev/null || fail "third sweep failed"
  [ ! -e "$(parent_channel)" ] || fail "an answered blocker was raised: $(cat "$(parent_channel)")"
  ledger "$MATE" child 'needs-decision [key=scope]: widen the migration?'
  sweep "$MATE" 2001 >/dev/null || fail "fourth sweep failed"
  ledger "$MATE" child 'captain-held [key=scope]: transferred to task scope-call'
  sweep "$MATE" 3000 >/dev/null || fail "fifth sweep failed"
  [ ! -e "$(parent_channel)" ] || fail "a captain-held transfer inside the threshold was raised: $(cat "$(parent_channel)")"
  pass "decisions and blockers handled inside the threshold stay silent"
}

# A failed line that keeps standing as the last line is raised past the
# threshold with deterministic text; one superseded by a relaunch is not.
test_failed_line_thresholded_and_superseded() {
  make_world 'failed'; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'failed: build broke on main'
  sweep "$MATE" 1000 >/dev/null || fail "first sweep failed"
  [ ! -e "$(parent_channel)" ] || fail "a fresh failure was raised before the threshold"
  sweep "$MATE" 1060 >/dev/null || fail "second sweep failed"
  grep -F 'failed [key=mirror-5-child-l0]: mirror: child=child build broke on main (unhandled past 60s) mode=no-mistakes yolo=off' "$(parent_channel)" >/dev/null \
    || fail "the standing failure was not raised: $(cat "$(parent_channel)")"
  sweep "$MATE" 1200 >/dev/null || fail "third sweep failed"
  [ "$(channel_lines)" = 1 ] || fail "a standing failure was raised twice"

  make_world relaunched; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'failed: build broke on main'
  sweep "$MATE" 1000 >/dev/null || fail "relaunch first sweep failed"
  ledger "$MATE" child 'working: relaunched on a clean base'
  sweep "$MATE" 1060 >/dev/null || fail "relaunch second sweep failed"
  sweep "$MATE" 2000 >/dev/null || fail "relaunch third sweep failed"
  [ ! -e "$(parent_channel)" ] || fail "a superseded failure was raised: $(cat "$(parent_channel)")"

  make_world recurring; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'failed: same failure'
  sweep "$MATE" 3000 >/dev/null || fail "recurring first observation failed"
  sweep "$MATE" 3060 >/dev/null || fail "recurring first delivery failed"
  ledger "$MATE" child 'working: retrying' 'failed: same failure'
  sweep "$MATE" 3070 >/dev/null || fail "recurring second observation failed"
  sweep "$MATE" 3130 >/dev/null || fail "recurring second delivery failed"
  [ "$(channel_count 'failed [key=mirror-5-child-l')" = 2 ] \
    || fail "an identical recurring failure was not delivered as a new event"
  pass "standing failures are offset-identified and superseded failures stay silent"
}

# A decision line the fold cannot track is delivered at once under the done
# verb, so it surfaces without opening a parent decision nothing can close.
test_untracked_decision_line_is_delivered_as_done() {
  make_world untracked; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'needs-decision [key=bad key]: which one'
  sweep "$MATE" 1000 >/dev/null || fail "sweep failed"
  grep -F 'done [key=mirror-5-child-l0]: mirror: child=child untracked needs-decision line: which one' "$(parent_channel)" >/dev/null \
    || fail "the untracked decision line was not delivered: $(cat "$(parent_channel)")"
  [ -z "$(parent_open_decisions)" ] || fail "an untracked decision opened a parent decision"
  pass "an untrackable decision line is delivered without opening a parent decision"
}

# A remote route writes the mate's own parent-replies log, the input the
# parent's remote reply adapter already mirrors.
test_injective_keys_and_concurrent_append() {
  local i pid pids='' failures=0
  make_world injective; bind_secondmate local
  write_child "$MATE" a-b
  write_child "$MATE" a
  ledger "$MATE" a-b 'needs-decision [key=c]: first choice'
  ledger "$MATE" a 'needs-decision [key=b-c]: second choice'
  sweep "$MATE" 1000 >/dev/null || fail "injective first sweep failed"
  sweep "$MATE" 1060 >/dev/null || fail "injective threshold sweep failed"
  parent_open_decisions | grep -q '^mirror-3-a-b-c' || fail "first child decision key was not preserved"
  parent_open_decisions | grep -q '^mirror-1-a-b-c' || fail "second child decision key was not preserved"
  ledger "$MATE" a-b 'resolved [key=c]: first chosen'
  sweep "$MATE" 1070 >/dev/null || fail "injective close sweep failed"
  parent_open_decisions | grep -q '^mirror-1-a-b-c' || fail "closing one child closed the colliding sibling"

  make_world concurrent; bind_secondmate local
  i=0
  while [ "$i" -lt 12 ]; do
    FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
      . "$1"; fm_parent_channel_report "$2" "$3" "done [key=concurrent]: one outcome"
    ' _ "$ROOT/bin/fm-parent-channel-lib.sh" "$MATE" "$MATE/state" &
    pid=$!
    pids="${pids:-} $pid"
    i=$((i + 1))
  done
  for pid in $pids; do wait "$pid" || failures=$((failures + 1)); done
  [ "$failures" -eq 0 ] || fail "a concurrent parent publication failed"
  [ "$(channel_count 'done [key=concurrent]: one outcome')" = 1 ] \
    || fail "concurrent exact-line publications duplicated the outcome"
  [ -z "$(find "$MAIN/state" -name '.parent-channel-*' -print -quit)" ] \
    || fail "a destination lock artifact landed in the parent home"
  pass "mirrored keys are injective and concurrent appends stay idempotent"
}

test_parent_channel_repairs_unterminated_tail() {
  make_world channel-tail; bind_secondmate local
  printf 'done [key=tail]: intended outcome' > "$(parent_channel)"
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1"; fm_parent_channel_report "$2" "$3" "done [key=tail]: intended outcome"
  ' _ "$ROOT/bin/fm-parent-channel-lib.sh" "$MATE" "$MATE/state" \
    || fail "retrying an unterminated intended line failed"
  [ "$(channel_lines)" = 1 ] || fail "unterminated intended text was duplicated"
  grep -Fx 'done [key=tail]: intended outcome' "$(parent_channel)" >/dev/null \
    || fail "unterminated intended text was not repaired as a complete record"

  printf 'partial fragment' > "$(parent_channel)"
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1"; fm_parent_channel_report "$2" "$3" "done [key=next]: next outcome"
  ' _ "$ROOT/bin/fm-parent-channel-lib.sh" "$MATE" "$MATE/state" \
    || fail "appending after an unterminated fragment failed"
  [ "$(channel_lines)" = 2 ] || fail "the repaired fragment and next outcome were concatenated"
  grep -Fx 'partial fragment' "$(parent_channel)" >/dev/null \
    || fail "the unterminated fragment was not delimited"
  grep -Fx 'done [key=next]: next outcome' "$(parent_channel)" >/dev/null \
    || fail "the next outcome was malformed after tail repair"
  pass "parent appends repair and delimit unterminated tails"
}

test_remote_route_writes_parent_replies() {
  make_world remote; bind_secondmate remote
  write_child "$MATE" child
  ledger "$MATE" child "done: PR $PR_URL checks green"
  sweep "$MATE" 1000 >/dev/null || fail "sweep failed"
  grep -F "done [key=mirror-5-child-l0]: mirror: child=child PR $PR_URL checks green" "$MATE/state/parent-replies.status" >/dev/null \
    || fail "remote route did not write parent-replies.status"
  [ ! -e "$MAIN/state/mate.status" ] || fail "remote route wrote a local parent file"
  pass "a remote route delivers into the mate's parent-replies log"
}

# A PR registration delivers the child's ready line at registration time, with
# the canonical pr= just recorded, and leaves nothing for the next sweep.
test_pr_check_registration_delivers_now() {
  local out size holder i lock
  make_world pr-check; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child "done: PR $PR_URL checks green"
  out=$(PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MATE" \
    FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" FM_FORGE_LOG="$WORLD/forge.log" \
    "$PR_CHECK" child "$PR_URL" 2>&1) || fail "fm-pr-check failed: $out"
  case "$out" in *"armed: state/child.check.sh"*) ;; *) fail "fm-pr-check did not arm: $out" ;; esac
  case "$out" in *actionable:*) fail "fm-pr-check reported a delivery problem: $out" ;; esac
  grep -F "done [key=mirror-5-child-l0]: mirror: child=child PR $PR_URL checks green pr=$PR_URL" "$(parent_channel)" >/dev/null \
    || fail "registration did not deliver the ready line with pr=: $(cat "$(parent_channel)" 2>/dev/null)"
  size=$(wc -c < "$MATE/state/child.status" | tr -d ' ')
  [ "$(record_field child offset)" = "$size" ] || fail "registration left the ledger for the next sweep"
  sweep "$MATE" 1000 >/dev/null || fail "sweep after registration failed"
  [ "$(channel_lines)" = 1 ] || fail "the next sweep duplicated the registration delivery"

  make_world pr-check-contention; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child "done: PR $PR_URL checks green"
  lock="$MATE/state/.parent-mirror.lock"
  FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2"
    : > "$3"
    sleep 30
  ' _ "$ROOT" "$lock" "$WORLD/sweep-held" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -e "$WORLD/sweep-held" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/sweep-held" ] || fail "registration sweep lock holder did not start"
  out=$(PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MATE" \
    FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" FM_FORGE_LOG="$WORLD/forge.log" \
    FM_PARENT_MIRROR_LOCK_WAIT_SECS=1 "$PR_CHECK" child "$PR_URL" 2>&1) \
    || fail "contended fm-pr-check failed: $out"
  reap "$holder"
  case "$out" in *"armed: state/child.check.sh"*) ;; *) fail "contended registration did not arm: $out" ;; esac
  case "$out" in *"actionable:"*"rc=5"*) ;; *) fail "contended registration was not actionable: $out" ;; esac
  [ ! -e "$(parent_channel)" ] || fail "contended registration unexpectedly delivered"
  pass "a PR registration delivers now or reports contention as actionable"
}

# The retire path a teardown runs: the child's final line is delivered before
# its record goes, its mirror state is retired, and when delivery fails the
# record is kept as an orphan that a later sweep still delivers.
test_retire_delivers_then_orphan_retries() {
  local rc
  make_world retire; bind_secondmate local
  write_child "$MATE" scout scout
  ledger "$MATE" scout 'done: report ready'
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" bash -c '
    . "$1"; fm_parent_mirror_retire_locked scout
  ' _ "$ROOT/bin/fm-parent-mirror-lib.sh" || fail "retire failed"
  grep -F 'mirror: child=scout report ready' "$(parent_channel)" >/dev/null || fail "retire did not deliver the final line"
  [ ! -e "$MATE/state/parent-mirror/scout.record" ] || fail "retire did not remove the mirror record"

  make_world orphan; bind_secondmate local
  write_child "$MATE" scout scout
  ledger "$MATE" scout 'done: report ready'
  mkdir -p "$MAIN/state"
  chmod 0500 "$MAIN/state"
  rc=0
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" bash -c '
    . "$1"; fm_parent_mirror_retire_locked scout
  ' _ "$ROOT/bin/fm-parent-mirror-lib.sh" 2>/dev/null || rc=$?
  chmod 0755 "$MAIN/state"
  [ "$rc" -ne 0 ] || fail "retire reported success while the parent channel was unwritable"
  [ "$(record_field scout orphan)" = 1 ] || fail "a failed retire did not keep an orphan record"
  rm -f "$MATE/state/scout.meta"
  sweep "$MATE" 1000 >/dev/null || fail "orphan sweep failed"
  grep -F 'mirror: child=scout report ready' "$(parent_channel)" >/dev/null || fail "the orphan was not delivered later"
  [ ! -e "$MATE/state/parent-mirror/scout.record" ] || fail "a delivered orphan record was not removed"
  make_world retire-tail; bind_secondmate local
  write_child "$MATE" child
  printf 'done: teardown tail' > "$MATE/state/child.status"
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" bash -c '
    . "$1"; fm_parent_mirror_retire_locked child
  ' _ "$ROOT/bin/fm-parent-mirror-lib.sh" || fail "partial-tail retire failed"
  [ "$(record_field child orphan)" = 1 ] && [ "$(record_field child tail)" = 1 ] \
    || fail "retire did not preserve its incomplete tail as an orphan"
  rm -f "$MATE/state/child.meta"
  printf '\n' >> "$MATE/state/child.status"
  sweep "$MATE" 1001 >/dev/null || fail "retired-tail retry failed"
  grep -F 'mirror: child=child teardown tail' "$(parent_channel)" >/dev/null \
    || fail "retired tail was not delivered after completion"
  [ ! -e "$MATE/state/parent-mirror/child.record" ] || fail "retired-tail record was not removed"
  pass "retire and orphan paths preserve every undelivered byte"
}

# Retirement ends first-responder authority, so thresholded outcomes are due
# immediately and their record survives until delivery succeeds.
test_retired_and_orphaned_outcomes_deliver_immediately() {
  make_world retire-failed; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'failed: build broke before teardown'
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" \
    FM_PARENT_MIRROR_NOW=1000 FM_PARENT_MIRROR_OPEN_SECS=60 bash -c '
      . "$1"; fm_parent_mirror_retire_locked child
    ' _ "$ROOT/bin/fm-parent-mirror-lib.sh" || fail "failed-child retire failed"
  grep -F 'failed [key=mirror-5-child-l0]: mirror: child=child build broke before teardown (unhandled when child retired)' "$(parent_channel)" >/dev/null \
    || fail "retire did not immediately deliver the standing failure"
  [ ! -e "$MATE/state/parent-mirror/child.record" ] || fail "retire kept a delivered failure record"

  make_world retire-decision; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'needs-decision [key=ship]: choose release train'
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" \
    FM_PARENT_MIRROR_NOW=1000 FM_PARENT_MIRROR_OPEN_SECS=60 bash -c '
      . "$1"; fm_parent_mirror_retire_locked child
    ' _ "$ROOT/bin/fm-parent-mirror-lib.sh" || fail "decision-child retire failed"
  grep -F 'needs-decision [key=mirror-5-child-ship]: mirror: child=child decision ship (opened at line 1) open when child retired' "$(parent_channel)" >/dev/null \
    || fail "retire did not immediately deliver the open decision"
  [ ! -e "$MATE/state/parent-mirror/child.record" ] || fail "retire kept a delivered decision record"

  make_world orphan-failed; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'failed: orphan build broke'
  sweep "$MATE" 2000 >/dev/null || fail "orphan failure priming sweep failed"
  rm -f "$MATE/state/child.meta"
  sweep "$MATE" 2001 >/dev/null || fail "orphan failure sweep failed"
  grep -F 'orphan build broke (unhandled when child retired)' "$(parent_channel)" >/dev/null \
    || fail "orphan sweep did not immediately deliver the standing failure"
  [ ! -e "$MATE/state/parent-mirror/child.record" ] || fail "orphan failure record was removed too late"

  make_world orphan-decision; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child 'blocked [key=token]: need deploy token'
  sweep "$MATE" 3000 >/dev/null || fail "orphan decision priming sweep failed"
  rm -f "$MATE/state/child.meta"
  sweep "$MATE" 3001 >/dev/null || fail "orphan decision sweep failed"
  grep -F 'blocked [key=mirror-5-child-token]: mirror: child=child decision token (opened at line 1) open when child retired' "$(parent_channel)" >/dev/null \
    || fail "orphan sweep did not immediately deliver the open decision"
  [ ! -e "$MATE/state/parent-mirror/child.record" ] || fail "orphan decision record was removed too late"
  pass "retired and orphaned outcomes bypass the grace threshold"
}

# Lock discipline: a child whose record is held (a teardown or relaunch in
# progress) is skipped within the bounded wait rather than waited on, so the
# watcher's beacon is never held hostage, and a retire under a held meta lock
# takes no sweep lock, so a concurrent sweep can never deadlock a teardown.
test_busy_locks_are_skipped_not_waited() {
  local holder started elapsed i lock rc
  make_world locks; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child "done: PR $PR_URL checks green"
  lock="$MATE/state/.meta-child.lock"
  FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2"
    : > "$3"
    sleep 30
  ' _ "$ROOT" "$lock" "$WORLD/lock-held" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -e "$WORLD/lock-held" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/lock-held" ] || fail "meta lock holder did not start"
  started=$(date +%s)
  FM_PARENT_MIRROR_LOCK_WAIT_SECS=1 sweep "$MATE" 1000 >/dev/null || fail "sweep against a busy child failed"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 6 ] || fail "sweep waited on a busy child (${elapsed}s)"
  [ ! -e "$(parent_channel)" ] || fail "a busy child was examined under someone else's lock"
  rc=0
  FM_PARENT_MIRROR_LOCK_WAIT_SECS=1 sweep "$MATE" 1000 --child child >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 5 ] || fail "targeted child contention did not return 5 (rc=$rc)"
  reap "$holder"
  sweep "$MATE" 1001 >/dev/null || fail "sweep after release failed"
  [ "$(channel_count "done [key=mirror-5-child-l0]")" = 1 ] || fail "the child was not delivered once its lock was free"

  make_world retire-lock; bind_secondmate local
  write_child "$MATE" scout scout
  ledger "$MATE" scout 'done: report ready'
  lock="$MATE/state/.parent-mirror.lock"
  FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2"
    : > "$3"
    sleep 30
  ' _ "$ROOT" "$lock" "$WORLD/sweep-held" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -e "$WORLD/sweep-held" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/sweep-held" ] || fail "sweep lock holder did not start"
  started=$(date +%s)
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" bash -c '
    . "$1"; fm_parent_mirror_retire_locked scout
  ' _ "$ROOT/bin/fm-parent-mirror-lib.sh" || fail "retire under a held sweep lock failed"
  elapsed=$(( $(date +%s) - started ))
  reap "$holder"
  [ "$elapsed" -le 6 ] || fail "retire waited on the sweep lock (${elapsed}s)"
  grep -F 'mirror: child=scout report ready' "$(parent_channel)" >/dev/null || fail "retire did not deliver while a sweep held its lock"
  pass "busy locks are skipped within the bound and a retire never waits on a sweep"
}

# A main home has no parent channel: the sweep is silent, writes nothing, and
# exits zero.
test_main_home_is_inert() {
  local out
  make_world main
  write_child "$MAIN" child
  ledger "$MAIN" child "done: PR $PR_URL checks green"
  out=$(sweep "$MAIN" 1000) || fail "main-home sweep exited non-zero"
  [ -z "$out" ] || fail "main-home sweep printed: $out"
  [ ! -e "$MAIN/state/parent-mirror" ] || fail "main-home sweep created mirror state"
  pass "a main home is inert"
}

# A mate whose parent binding is unreadable is loud once per episode: one
# durable wake naming the binding, printed only when newly queued.
test_unreadable_binding_is_loud_once() {
  local out rc=0 holder i started elapsed pids='' pid rows actions
  make_world unbound
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  write_child "$MATE" child
  ledger "$MATE" child "done: PR $PR_URL checks green"
  out=$(sweep "$MATE" 1000 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "unreadable binding did not return 3 (rc=$rc): $out"
  case "$out" in *actionable:*".fm-secondmate-parent"*) ;; *) fail "the missing binding was not named: $out" ;; esac
  [ "$(wake_count "$MATE" 'parent-mirror-diagnostic:channel')" = 1 ] || fail "the diagnostic was not queued once"
  rc=0
  out=$(sweep "$MATE" 1001 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "second sweep did not keep returning 3"
  [ -z "$out" ] || fail "a still-queued diagnostic was printed again: $out"
  [ "$(wake_count "$MATE" 'parent-mirror-diagnostic:channel')" = 1 ] || fail "the diagnostic was queued twice"

  make_world diagnostic-concurrent
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  write_child "$MATE" child
  ledger "$MATE" child "done: PR $PR_URL checks green"
  i=0
  while [ "$i" -lt 8 ]; do
    sweep "$MATE" 1000 > "$WORLD/diag-$i.out" 2> "$WORLD/diag-$i.err" &
    pid=$!
    pids="$pids $pid"
    i=$((i + 1))
  done
  for pid in $pids; do wait "$pid" 2>/dev/null || true; done
  rows=$(grep -c 'parent-mirror-diagnostic:channel' "$MATE/state/.wake-queue" 2>/dev/null || true)
  actions=$(grep -h -c 'actionable: parent channel unavailable' "$WORLD"/diag-*.out | awk '{ total += $1 } END { print total + 0 }')
  [ "$rows" -eq 1 ] || fail "concurrent diagnostics queued $rows rows"
  [ "$actions" -eq 1 ] || fail "concurrent diagnostics emitted $actions actionable wakes"

  make_world diagnostic-lock
  pids=''
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  write_child "$MATE" child
  ledger "$MATE" child "done: PR $PR_URL checks green"
  FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    : > "$2"
    sleep 30
  ' _ "$ROOT" "$WORLD/wake-held" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -e "$WORLD/wake-held" ]; do sleep 0.1; i=$((i + 1)); done
  started=$(date +%s)
  rc=0
  out=$(FM_PARENT_MIRROR_LOCK_WAIT_SECS=1 sweep "$MATE" 1000 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - started ))
  reap "$holder"
  [ "$rc" -eq 3 ] || fail "contended diagnostic changed the channel error (rc=$rc)"
  [ "$elapsed" -le 4 ] || fail "diagnostic blocked on the wake queue (${elapsed}s)"
  case "$out" in *"parent channel unavailable"*) ;; *) fail "contended diagnostic did not degrade to stderr" ;; esac
  [ ! -e "$MATE/state/.wake-queue" ] \
    || fail "contended diagnostic wrote through a held queue"
  pass "parent diagnostics are once-only and bounded by the wake queue"
}

# The real watcher poll delivers a terminal child within one poll, so the
# parent's own watcher can wake on it, without the mate itself being woken.
test_watcher_poll_delivers_terminal_child() {
  local pid i
  make_world watcher; bind_secondmate local
  write_child "$MATE" child
  ledger "$MATE" child "done: PR $PR_URL checks green"
  printf 'do not truncate\n' > "$WORLD/diagnostic-target"
  ln -s "$WORLD/diagnostic-target" "$MATE/state/.parent-mirror.stderr"
  prime_seen "$MATE/state" "$MATE/state/child.status"
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" \
    FM_DATA_OVERRIDE="$MATE/data" FM_CONFIG_OVERRIDE="$MATE/config" FM_FORGE_LOG="$WORLD/forge.log" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_INACTIVE_RECONCILE_SECS=1800 \
    "$WATCH" > "$WORLD/watch.out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    grep -F 'mirror: child=child' "$(parent_channel)" >/dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
  done
  reap "$pid"
  [ "$(cat "$WORLD/diagnostic-target")" = 'do not truncate' ] \
    || fail "the watcher followed the predictable diagnostic symlink"
  grep -F "done [key=mirror-5-child-l0]: mirror: child=child PR $PR_URL checks green" "$(parent_channel)" >/dev/null \
    || fail "the watcher poll did not deliver the terminal child: $(cat "$WORLD/watch.out")"
  ! grep -F 'check: parent-mirror' "$WORLD/watch.out" >/dev/null || fail "a clean delivery woke the mate: $(cat "$WORLD/watch.out")"
  pass "the watcher poll delivers a terminal child to the parent channel"
}

test_done_line_delivered_once
test_scout_report_pointer
test_scratch_paths_refuse_symlink_redirection
test_partial_line_waits_for_newline
test_orphan_retains_unterminated_tail
test_partial_thresholded_outcomes_do_not_age
test_open_decision_thresholded_then_closed
test_failed_decision_close_retries_without_child_change
test_reopened_decision_is_raised_again
test_decision_handled_inside_threshold_is_silent
test_failed_line_thresholded_and_superseded
test_untracked_decision_line_is_delivered_as_done
test_injective_keys_and_concurrent_append
test_parent_channel_repairs_unterminated_tail
test_remote_route_writes_parent_replies
test_pr_check_registration_delivers_now
test_retire_delivers_then_orphan_retries
test_retired_and_orphaned_outcomes_deliver_immediately
test_busy_locks_are_skipped_not_waited
test_main_home_is_inert
test_unreadable_binding_is_loud_once
test_watcher_poll_delivers_terminal_child

echo "all parent mirror tests passed"
