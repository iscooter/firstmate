#!/usr/bin/env bash
# Behavior tests for bin/fm-mini-reboot-lib.sh's idle-check and two-snapshot
# idle-confirm logic (report section 6, Phase C/D adapted for the
# captain's 2026-08-24 retarget: local-only idleness, no drain, no
# cross-host receipts).
#
# Pins:
#   (a) each documented blocking condition individually blocks: child task
#       metadata, in-flight backlog item, held captain decision, unhandled
#       steering inbox, pending remote reply, promised public reply owed,
#       registered process-event source
#   (b) a genuinely clear home reports idle
#   (c) a missing backlog file is treated as busy (fail-closed), never as "no
#       obligation" - the direct regression for the tasks-axi
#       missing-file-reports-count-zero trap
#   (d) an empty/unregistered homes registry reports busy, never idle, so an
#       unconfigured guard never reboots
#   (e) idle-confirm requires TWO consecutive idle reads at least
#       idle_min_gap_secs apart - a single idle read is never "confirmed"
#   (f) idle-confirm rejects a gap that is too large (stitching two unrelated
#       far-apart observations together) as well as too small
#   (g) never uses --force, never kills, never aborts, never discards
#       anything - this suite only ever reads state
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-mini-reboot-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-mini-reboot-idle)

# make_clear_home <dir>: a home with an empty backlog (no in_flight/held/
# followup items), no state/ obligations - the baseline "idle" fixture that
# each blocking test starts from and mutates exactly one thing.
make_clear_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Done
EOF
}

run_idle_check_home() {
  local home=$1
  bash -c ". '$LIB'; fm_mrb_idle_check_home '$home'"
}

t_clear_home_is_idle() {
  local home
  home="$TMP_ROOT/clear"
  make_clear_home "$home"
  local out
  out=$(run_idle_check_home "$home")
  [ "$out" = idle ] || fail "expected idle, got: $out"
  pass "a genuinely clear home reports idle"
}

t_child_task_metadata_blocks() {
  local home
  home="$TMP_ROOT/meta"
  make_clear_home "$home"
  fm_write_meta "$home/state/some-task.meta" "kind=ship" "worktree=/tmp/x"
  local out
  out=$(run_idle_check_home "$home")
  assert_contains "$out" "busy" "child task metadata must block idleness"
  pass "child task metadata blocks idleness"
}

t_missing_state_directory_blocks() {
  local home out
  home="$TMP_ROOT/no-state"
  mkdir -p "$home/data"
  printf '# Backlog\n\n## Done\n' > "$home/data/backlog.md"
  out=$(run_idle_check_home "$home")
  assert_contains "$out" "busy" "a missing state directory must fail closed"
  assert_contains "$out" "state directory" "the reason should name the missing state directory"
  pass "a missing state directory blocks idleness"
}

t_state_enumeration_failure_blocks() {
  local home fb out
  home="$TMP_ROOT/state-find-failure"
  make_clear_home "$home"
  fb=$(fm_fakebin "$home")
  cat > "$fb/find" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "$home/state" ]; then
  echo "simulated state read failure" >&2
  exit 1
fi
exec /usr/bin/find "\$@"
EOF
  chmod +x "$fb/find"
  out=$(PATH="$fb:$PATH" bash -c ". '$LIB'; fm_mrb_idle_check_home '$home'")
  assert_contains "$out" "busy" "a failed state enumeration must fail closed"
  assert_contains "$out" "could not enumerate" "the enumeration failure should be diagnosed"
  pass "a state enumeration error blocks idleness"
}

t_missing_backlog_file_blocks() {
  local home
  home="$TMP_ROOT/no-backlog"
  mkdir -p "$home/state" "$home/data"
  # Deliberately do NOT create data/backlog.md - regression for the
  # tasks-axi trap where a nonexistent file reports "count: 0" (exit 0)
  # instead of erroring, which would otherwise silently read as idle.
  local out
  out=$(run_idle_check_home "$home")
  assert_contains "$out" "busy" "a missing backlog file must fail closed, not read as empty"
  assert_contains "$out" "backlog" "the reason should name the backlog"
  pass "a missing backlog file blocks idleness (fail-closed, not silently empty)"
}

t_in_flight_backlog_item_blocks() {
  local home
  home="$TMP_ROOT/in-flight"
  make_clear_home "$home"
  if ! command -v tasks-axi >/dev/null 2>&1; then
    echo "skip - tasks-axi not available" >&2
    return 0
  fi
  # Built through the real tasks-axi interface, not hand-authored markdown,
  # so this pins observable behavior rather than an assumed file format.
  tasks-axi add demo-task "test in-flight task" --file "$home/data/backlog.md" \
    --kind ship --repo demo --start >/dev/null 2>&1 \
    || fail "fixture setup: tasks-axi add --start failed"
  local out
  out=$(run_idle_check_home "$home")
  assert_contains "$out" "busy" "an in-flight backlog item must block idleness"
  pass "an in-flight backlog item blocks idleness"
}

t_held_captain_decision_blocks() {
  local home
  home="$TMP_ROOT/held"
  make_clear_home "$home"
  if ! command -v tasks-axi >/dev/null 2>&1; then
    echo "skip - tasks-axi not available" >&2
    return 0
  fi
  tasks-axi add captain-call "test held task" --file "$home/data/backlog.md" \
    --kind task --repo demo >/dev/null 2>&1 \
    || fail "fixture setup: tasks-axi add failed"
  tasks-axi hold captain-call --file "$home/data/backlog.md" \
    --reason "need a decision" --kind captain >/dev/null 2>&1 \
    || fail "fixture setup: tasks-axi hold failed"
  local out
  out=$(run_idle_check_home "$home")
  assert_contains "$out" "busy" "an open captain decision must block idleness"
  pass "an open captain decision (held) blocks idleness"
}

t_unhandled_steering_inbox_blocks() {
  local home
  home="$TMP_ROOT/inbox"
  make_clear_home "$home"
  mkdir -p "$home/state/some-task.inbox"
  echo "schema=fm-task-inbox.v1" > "$home/state/some-task.inbox/001.msg"
  local out
  out=$(run_idle_check_home "$home")
  assert_contains "$out" "busy" "an unhandled steering inbox message must block idleness"
  pass "an unhandled steering inbox message blocks idleness"
}

t_handled_steering_inbox_does_not_block() {
  local home
  home="$TMP_ROOT/inbox-handled"
  make_clear_home "$home"
  mkdir -p "$home/state/some-task.inbox/handled"
  echo "schema=fm-task-inbox.v1" > "$home/state/some-task.inbox/handled/001.msg"
  local out
  out=$(run_idle_check_home "$home")
  [ "$out" = idle ] || fail "a HANDLED inbox message must not block idleness, got: $out"
  pass "an already-handled steering inbox message does not block idleness"
}

t_pending_remote_reply_blocks() {
  local home
  home="$TMP_ROOT/pending-reply"
  make_clear_home "$home"
  mkdir -p "$home/state/pending-replies"
  echo "corr=abc123" > "$home/state/pending-replies/abc123"
  local out
  out=$(run_idle_check_home "$home")
  assert_contains "$out" "busy" "a pending remote reply must block idleness"
  pass "a pending remote reply record blocks idleness"
}

t_process_event_source_blocks() {
  local home
  home="$TMP_ROOT/procevent"
  make_clear_home "$home"
  mkdir -p "$home/state/procevent"
  echo "source=github-pr-123" > "$home/state/procevent/github-pr-123"
  local out
  out=$(run_idle_check_home "$home")
  assert_contains "$out" "busy" "a registered process-event source must block idleness"
  pass "a registered process-event source blocks idleness"
}

t_malformed_public_followup_response_blocks() {
  local home fb out
  home="$TMP_ROOT/followup-malformed"
  make_clear_home "$home"
  fb=$(fm_fakebin "$home")
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = public-followup ]; then
  printf '{}\n'
else
  printf 'count: 0\n'
fi
SH
  chmod +x "$fb/tasks-axi"
  out=$(PATH="$fb:$PATH" bash -c ". '$LIB'; fm_mrb_idle_check_home '$home'")
  assert_contains "$out" "busy" "a malformed public-followup response must fail closed"
  assert_contains "$out" "could not parse" "the malformed response should be diagnosed"
  pass "a malformed public-followup response blocks idleness"
}

t_promised_public_reply_blocks() {
  local home req exp relation out
  home="$TMP_ROOT/followup"
  make_clear_home "$home"
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required for public-followup coverage"
  command -v jq >/dev/null 2>&1 || fail "jq is required for public-followup coverage"
  req="$home/req.json"; exp="$home/exp.json"; relation="$home/relation.json"
  jq -n '{request_id:"req-pf-test", platform:"discord",
    context_binding:{version:"ctx1", value:"ctx1_req-pf-test"},
    public_safe_summary:"test", received_at:"2026-08-24T00:00:00Z",
    followup_expires_at:"2099-01-01T00:00:00Z",
    reservation_expires_at:"2099-01-01T00:00:00Z"}' > "$req"
  jq -n '{type:"report-ready", project:"firstmate", required_deliverables:["report_path"],
    completion_policy:"all-required"}' > "$exp"
  jq -n '{relation_id:"rel-test", work_ref:{home_id:"main", task_id:"work-test"},
    role:"fulfills", required:true, generation:1}' > "$relation"
  tasks-axi public-followup add pf-test-1 --file "$home/data/backlog.md" \
    --request-context-file "$req" --purpose promised-final \
    --expected-final-file "$exp" --expires-at 2099-01-01T00:00:00Z >/dev/null 2>&1 \
    || fail "fixture setup: public-followup add failed"
  tasks-axi public-followup bind-work pf-test-1 --file "$home/data/backlog.md" \
    --relation-file "$relation" >/dev/null 2>&1 \
    || fail "fixture setup: public-followup bind-work failed"
  out=$(run_idle_check_home "$home")
  assert_contains "$out" "busy" "a pending-work public reply must block idleness"
  assert_contains "$out" "still owed" "the reason should identify the unresolved public reply"
  pass "a pending-work promised public reply blocks idleness"
}

# --- (d) empty/unregistered registry never reads as idle -------------------

t_empty_registry_is_busy() {
  local coordinator out
  coordinator="$TMP_ROOT/coordinator-empty"
  mkdir -p "$coordinator/config"
  out=$(FM_HOME="$coordinator" bash -c ". '$LIB'; fm_mrb_idle_check_all")
  assert_contains "$out" "busy" "an empty/absent homes registry must never read as idle"
  pass "an empty or absent homes registry reports busy (guard never reboots unconfigured)"
}

t_registered_clear_home_is_idle_via_check_all() {
  local coordinator home out
  coordinator="$TMP_ROOT/coordinator-clear"
  home="$TMP_ROOT/coordinator-clear-home"
  make_clear_home "$home"
  mkdir -p "$coordinator/config"
  printf '%s\n' "$home" > "$coordinator/config/mini-reboot-homes"
  out=$(FM_HOME="$coordinator" bash -c ". '$LIB'; fm_mrb_idle_check_all")
  [ "$out" = idle ] || fail "expected idle via check-all, got: $out"
  pass "idle-check-all reports idle when every registered home is clear"
}

t_one_busy_home_blocks_the_whole_registry() {
  local coordinator clear busy out
  coordinator="$TMP_ROOT/coordinator-mixed"
  clear="$TMP_ROOT/coordinator-mixed-clear"
  busy="$TMP_ROOT/coordinator-mixed-busy"
  make_clear_home "$clear"
  make_clear_home "$busy"
  fm_write_meta "$busy/state/some-task.meta" "kind=ship"
  mkdir -p "$coordinator/config"
  printf '%s\n%s\n' "$clear" "$busy" > "$coordinator/config/mini-reboot-homes"
  out=$(FM_HOME="$coordinator" bash -c ". '$LIB'; fm_mrb_idle_check_all")
  assert_contains "$out" "busy" "one busy home must block the whole registry"
  pass "any single busy registered home blocks the whole fleet-idle verdict"
}

# --- (e)/(f) idle-confirm two-snapshot gap logic ----------------------------

idle_confirm_at() {
  local coordinator=$1 now=$2
  FM_HOME="$coordinator" FM_MRB_NOW="$now" bash -c ". '$LIB'; fm_mrb_idle_confirm"
}

t_single_idle_read_is_not_confirmed() {
  local coordinator home out
  coordinator="$TMP_ROOT/confirm-single"
  home="$TMP_ROOT/confirm-single-home"
  make_clear_home "$home"
  mkdir -p "$coordinator/config"
  printf '%s\n' "$home" > "$coordinator/config/mini-reboot-homes"
  out=$(idle_confirm_at "$coordinator" 1000)
  assert_contains "$out" "confirmed=no" "a single idle read must not be confirmed"
  pass "a single idle read alone is never confirmed"
}

t_two_idle_reads_within_gap_window_confirms() {
  local coordinator home out
  coordinator="$TMP_ROOT/confirm-two-ok"
  home="$TMP_ROOT/confirm-two-ok-home"
  make_clear_home "$home"
  mkdir -p "$coordinator/config"
  printf '%s\n' "$home" > "$coordinator/config/mini-reboot-homes"
  idle_confirm_at "$coordinator" 1000 >/dev/null
  out=$(idle_confirm_at "$coordinator" 1400)   # 400s gap: within [300,1800]
  assert_contains "$out" "confirmed=yes" "two idle reads 400s apart should confirm"
  pass "two consecutive idle reads within the gap window confirm the idle window"
}

t_two_idle_reads_too_close_does_not_confirm() {
  local coordinator home out
  coordinator="$TMP_ROOT/confirm-too-close"
  home="$TMP_ROOT/confirm-too-close-home"
  make_clear_home "$home"
  mkdir -p "$coordinator/config"
  printf '%s\n' "$home" > "$coordinator/config/mini-reboot-homes"
  idle_confirm_at "$coordinator" 1000 >/dev/null
  out=$(idle_confirm_at "$coordinator" 1100)   # 100s gap: below the 300s min
  assert_contains "$out" "confirmed=no" "two idle reads only 100s apart must not confirm"
  pass "two idle reads closer than the minimum gap do not confirm (not a momentary blip)"
}

t_two_idle_reads_too_far_apart_does_not_confirm() {
  local coordinator home out
  coordinator="$TMP_ROOT/confirm-too-far"
  home="$TMP_ROOT/confirm-too-far-home"
  make_clear_home "$home"
  mkdir -p "$coordinator/config"
  printf '%s\n' "$home" > "$coordinator/config/mini-reboot-homes"
  idle_confirm_at "$coordinator" 1000 >/dev/null
  out=$(idle_confirm_at "$coordinator" 100000)  # way beyond the 1800s max
  assert_contains "$out" "confirmed=no" "two idle reads stitched across an unrelated span must not confirm"
  pass "two idle reads too far apart do not confirm (not stitched-together isolated reads)"
}

t_busy_reading_between_two_idle_reads_resets_confirmation() {
  local coordinator home out
  coordinator="$TMP_ROOT/confirm-interrupted"
  home="$TMP_ROOT/confirm-interrupted-home"
  make_clear_home "$home"
  mkdir -p "$coordinator/config"
  printf '%s\n' "$home" > "$coordinator/config/mini-reboot-homes"
  idle_confirm_at "$coordinator" 1000 >/dev/null   # idle
  fm_write_meta "$home/state/some-task.meta" "kind=ship"   # now busy
  idle_confirm_at "$coordinator" 1400 >/dev/null   # busy: breaks the streak
  rm -f "$home/state/some-task.meta"                # idle again
  out=$(idle_confirm_at "$coordinator" 1800)
  assert_contains "$out" "confirmed=no" "a busy reading in between must reset the two-snapshot streak"
  pass "a busy reading between two idle reads resets the confirmation streak"
}

t_clear_home_is_idle
t_child_task_metadata_blocks
t_missing_state_directory_blocks
t_state_enumeration_failure_blocks
t_missing_backlog_file_blocks
t_in_flight_backlog_item_blocks
t_held_captain_decision_blocks
t_unhandled_steering_inbox_blocks
t_handled_steering_inbox_does_not_block
t_pending_remote_reply_blocks
t_process_event_source_blocks
t_malformed_public_followup_response_blocks
t_promised_public_reply_blocks
t_empty_registry_is_busy
t_registered_clear_home_is_idle_via_check_all
t_one_busy_home_blocks_the_whole_registry
t_single_idle_read_is_not_confirmed
t_two_idle_reads_within_gap_window_confirms
t_two_idle_reads_too_close_does_not_confirm
t_two_idle_reads_too_far_apart_does_not_confirm
t_busy_reading_between_two_idle_reads_resets_confirmation
