#!/usr/bin/env bash
# Behavior tests for bin/fm-mini-reboot-guard.sh and the mini-only gate,
# privileged-execution refusal, reboot marker, and single-instance lock in
# bin/fm-mini-reboot-lib.sh.
#
# These are the direct regressions for the acceptance criteria:
#   - the generation-scoped host-maintenance-drain machinery this feature
#     REPLACES no longer exists in this codebase (captain 2026-08-24 retarget)
#   - NO automatic reboot path exists without BOTH the resource trigger and a
#     confirmed idle window holding at once
#   - reboot execution is refused (never faked) off-mini and without a
#     configured, executable privileged helper
#   - the reboot marker prevents an immediate re-fire after a reboot attempt,
#     and self-clears both on a genuine boot-session change and on staleness
#   - the single-instance lock is crash-safe: a dead owner's lock is reclaimed
#   - nothing here ever uses --force, kills a process, aborts a validation
#     run, or discards a worktree
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-mini-reboot-lib.sh"
GUARD="$ROOT/bin/fm-mini-reboot-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-mini-reboot-guard)

fake_sysctl_bin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/sysctl" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-n" ] && [ "$2" = "kern.bootsessionuuid" ]; then
  [ "${FM_FAKE_BOOT_ID_UNREADABLE:-0}" = 1 ] && exit 1
  echo "${FM_FAKE_BOOT_ID:-BOOT-A}"
  exit 0
fi
if [ "$1" = "-n" ]; then echo 0; exit 0; fi
echo "vm.swapusage: total = 1M used = 0M free = 1M"
SH
  chmod +x "$fb/sysctl"
  printf '%s\n' "$fb"
}

# --- the CLI dispatches to the same library functions -----------------------

t_cli_status_subcommand_runs_end_to_end() {
  local home fb out
  home="$TMP_ROOT/cli-status"; mkdir -p "$home/config"
  fb=$(fake_sysctl_bin "$home")
  cat > "$fb/vm_stat" <<'SH'
#!/usr/bin/env bash
echo "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
echo "Pages free: 0."
echo "Pages wired down: 0."
echo "Pages purgeable: 0."
echo "Pages occupied by compressor: 0."
echo "Swapins: 0."
echo "Swapouts: 0."
SH
  chmod +x "$fb/vm_stat"
  cat > "$fb/zprint" <<'SH'
#!/usr/bin/env bash
echo "zone name elem size ... inuse"
SH
  chmod +x "$fb/zprint"
  out=$(PATH="$fb:$PATH" FM_HOME="$home" "$GUARD" status 2>&1)
  local status=$?
  [ "$status" -eq 0 ] || fail "guard status subcommand exited $status: $out"
  assert_contains "$out" "host-role: not mini" "status reports the mini-only gate state"
  assert_contains "$out" "trigger=no" "status reports the resource evaluate verdict"
  assert_contains "$out" "no homes registered" "status reports the idle registry state"
  pass "the CLI status subcommand runs end-to-end and reports the real guard state"
}

t_cli_unknown_subcommand_errors() {
  local out status
  out=$("$GUARD" bogus-subcommand 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown subcommand should exit non-zero"
  assert_contains "$out" "unknown subcommand" "unknown subcommand names itself as such"
  pass "the CLI rejects an unknown subcommand with a clear diagnostic"
}

# --- mini-only gate ----------------------------------------------------------

t_execute_reboot_refuses_off_mini() {
  local home fb out status
  home="$TMP_ROOT/off-mini"; mkdir -p "$home/config"
  fb=$(fake_sysctl_bin "$home")
  # No config/host-role at all: must refuse.
  out=$(PATH="$fb:$PATH" FM_HOME="$home" bash -c ". '$LIB'; fm_mrb_execute_reboot test-reason" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "execute_reboot must fail off-mini, exit was 0"
  assert_contains "$out" "not configured as config/host-role=mini" "reason for refusal should be recorded"
  local log
  log="$home/state/mini-reboot/reboot-attempts.log"
  assert_present "$log" "attempts log created"
  assert_grep "not-mini" "$log" "attempts log records the not-mini refusal"
  pass "reboot execution refuses on a host without config/host-role=mini"
}

t_execute_reboot_refuses_wrong_role_value() {
  local home fb out
  home="$TMP_ROOT/wrong-role"; mkdir -p "$home/config"
  echo "macbook" > "$home/config/host-role"
  fb=$(fake_sysctl_bin "$home")
  out=$(PATH="$fb:$PATH" FM_HOME="$home" bash -c ". '$LIB'; fm_mrb_execute_reboot test-reason" 2>&1)
  local status=$?
  [ "$status" -ne 0 ] || fail "execute_reboot must fail with host-role=macbook"
  pass "reboot execution refuses when config/host-role names anything other than mini"
}

t_host_role_rejects_internal_whitespace() {
  local home
  home="$TMP_ROOT/role-internal-space"; mkdir -p "$home/config"
  printf '  m i n i  \n' > "$home/config/host-role"
  if FM_HOME="$home" bash -c ". '$LIB'; fm_mrb_host_is_mini"; then
    fail "host-role with internal whitespace must not authorize the mini gate"
  fi
  pass "the mini-only gate rejects internal host-role whitespace"
}

t_host_role_allows_surrounding_whitespace() {
  local home
  home="$TMP_ROOT/role-surrounding-space"; mkdir -p "$home/config"
  printf ' \t mini \t \n' > "$home/config/host-role"
  FM_HOME="$home" bash -c ". '$LIB'; fm_mrb_host_is_mini" \
    || fail "surrounding host-role whitespace should be trimmed"
  pass "the mini-only gate trims only surrounding whitespace"
}

# --- never fakes privileged execution ---------------------------------------

t_execute_reboot_blocked_without_helper_configured() {
  local home fb out status
  home="$TMP_ROOT/no-helper"; mkdir -p "$home/config"
  echo "mini" > "$home/config/host-role"
  fb=$(fake_sysctl_bin "$home")
  # No config/mini-reboot-helper at all.
  out=$(PATH="$fb:$PATH" FM_HOME="$home" bash -c ". '$LIB'; fm_mrb_execute_reboot test-reason" 2>&1)
  status=$?
  [ "$status" -eq 3 ] || fail "expected exit 3 (blocked: no helper), got $status"
  assert_contains "$out" "BLOCKED" "must log a clear BLOCKED diagnostic, never fake success"
  assert_contains "$out" "no privileged reboot mechanism" "must name the missing mechanism"
  local marker
  marker="$home/state/mini-reboot/reboot-in-progress"
  assert_absent "$marker" "no reboot marker should be written when execution is blocked"
  pass "reboot execution is BLOCKED (never faked) without a configured helper"
}

t_execute_reboot_blocked_with_nonexecutable_helper() {
  local home fb out status
  home="$TMP_ROOT/non-exec-helper"; mkdir -p "$home/config"
  echo "mini" > "$home/config/host-role"
  echo "$home/helper.sh" > "$home/config/mini-reboot-helper"
  echo "#!/bin/sh" > "$home/helper.sh"   # deliberately NOT chmod +x
  fb=$(fake_sysctl_bin "$home")
  out=$(PATH="$fb:$PATH" FM_HOME="$home" bash -c ". '$LIB'; fm_mrb_execute_reboot test-reason" 2>&1)
  status=$?
  [ "$status" -eq 3 ] || fail "expected exit 3 for a non-executable helper, got $status"
  pass "a configured but non-executable helper path is refused, not silently treated as ready"
}

t_execute_reboot_invokes_a_real_configured_helper() {
  local home fb out status helper
  home="$TMP_ROOT/with-helper"; mkdir -p "$home/config"
  echo "mini" > "$home/config/host-role"
  helper="$home/fake-reboot-helper.sh"
  cat > "$helper" <<EOF
#!/usr/bin/env bash
echo "invoked with reason: \$1" >> "$home/helper-invocations.log"
exit 0
EOF
  chmod +x "$helper"
  echo "$helper" > "$home/config/mini-reboot-helper"
  fb=$(fake_sysctl_bin "$home")
  out=$(PATH="$fb:$PATH" FM_HOME="$home" bash -c ". '$LIB'; fm_mrb_execute_reboot both-conditions-held" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "expected exit 0 from a successful helper invocation, got $status: $out"
  assert_present "$home/helper-invocations.log" "helper was actually invoked"
  assert_grep "both-conditions-held" "$home/helper-invocations.log" "reason was passed through to the helper"
  assert_present "$home/state/mini-reboot/reboot-in-progress" "reboot marker written before invoking the helper"
  pass "a genuinely configured, executable, mini-role helper is invoked with the trigger reason"
}

t_execute_reboot_preserves_spaces_in_helper_path() {
  local home fb out status helper
  home="$TMP_ROOT/helper-path-space"; mkdir -p "$home/config"
  echo mini > "$home/config/host-role"
  helper="$home/reboot helper.sh"
  cat > "$helper" <<EOF
#!/usr/bin/env bash
echo invoked > "$home/helper-invoked"
EOF
  chmod +x "$helper"
  printf ' \t%s \t\n' "$helper" > "$home/config/mini-reboot-helper"
  fb=$(fake_sysctl_bin "$home")
  out=$(PATH="$fb:$PATH" FM_HOME="$home" bash -c ". '$LIB'; fm_mrb_execute_reboot test-reason" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "helper path containing a space should be preserved, got $status: $out"
  assert_present "$home/helper-invoked" "the helper whose path contains a space must run"
  pass "helper configuration trims edges while preserving internal spaces"
}

# --- reboot marker: prevents re-fire, self-clears -------------------------

t_marker_active_blocks_a_second_cycle() {
  local home fb
  home="$TMP_ROOT/marker-active"; mkdir -p "$home/state/mini-reboot"
  fb=$(fake_sysctl_bin "$home")
  FM_FAKE_BOOT_ID=BOOT-A PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=1000 \
    bash -c ". '$LIB'; fm_mrb_write_reboot_marker some-reason"
  local active
  active=$(FM_FAKE_BOOT_ID=BOOT-A PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=1100 \
    bash -c ". '$LIB'; fm_mrb_reboot_marker_active && echo yes || echo no")
  [ "$active" = yes ] || fail "marker should still be active shortly after writing, same boot session"
  pass "an active reboot marker (same boot session, not stale) is reported active"
}

t_marker_clears_on_boot_session_change() {
  local home fb active
  home="$TMP_ROOT/marker-boot-change"; mkdir -p "$home/state/mini-reboot"
  fb=$(fake_sysctl_bin "$home")
  FM_FAKE_BOOT_ID=BOOT-A PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=1000 \
    bash -c ". '$LIB'; fm_mrb_write_reboot_marker some-reason"
  # A different boot-session id means the machine actually rebooted.
  active=$(FM_FAKE_BOOT_ID=BOOT-B PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=1050 \
    bash -c ". '$LIB'; fm_mrb_reboot_marker_active && echo yes || echo no")
  [ "$active" = no ] || fail "marker must clear once the boot-session id changes (the reboot happened)"
  assert_absent "$home/state/mini-reboot/reboot-in-progress" "marker file removed after boot-session change"
  pass "the reboot marker self-clears once the boot-session id changes (reboot actually happened)"
}

t_marker_clears_when_stale() {
  local home fb active
  home="$TMP_ROOT/marker-stale"; mkdir -p "$home/state/mini-reboot"
  fb=$(fake_sysctl_bin "$home")
  FM_FAKE_BOOT_ID=BOOT-A PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=1000 \
    bash -c ". '$LIB'; fm_mrb_write_reboot_marker some-reason"
  # Same boot session, but far beyond fm_mrb_marker_max_age_secs (1200s
  # default): the helper evidently did not reboot us.
  active=$(FM_FAKE_BOOT_ID=BOOT-A PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=1000000 \
    bash -c ". '$LIB'; fm_mrb_reboot_marker_active && echo yes || echo no")
  [ "$active" = no ] || fail "a stale same-session marker must self-clear rather than wedge forever"
  assert_absent "$home/state/mini-reboot/reboot-in-progress" "stale marker removed"
  pass "a stale reboot marker self-clears without manual intervention (never wedges forever)"
}

t_execute_reboot_blocks_when_boot_session_is_unreadable() {
  local home fb helper out status
  home="$TMP_ROOT/marker-no-boot-id"; mkdir -p "$home/config"
  echo mini > "$home/config/host-role"
  helper="$home/helper.sh"
  cat > "$helper" <<EOF
#!/usr/bin/env bash
echo invoked > "$home/helper-invoked"
EOF
  chmod +x "$helper"
  echo "$helper" > "$home/config/mini-reboot-helper"
  fb=$(fake_sysctl_bin "$home")
  out=$(FM_FAKE_BOOT_ID_UNREADABLE=1 PATH="$fb:$PATH" FM_HOME="$home" \
    bash -c ". '$LIB'; fm_mrb_execute_reboot test-reason" 2>&1)
  status=$?
  [ "$status" -eq 4 ] || fail "unreadable boot-session id should block with exit 4, got $status"
  assert_contains "$out" "boot-session id" "the refusal should name the unreadable boot-session id"
  assert_absent "$home/helper-invoked" "the reboot helper must not run without a valid marker boot id"
  assert_absent "$home/state/mini-reboot/reboot-in-progress" "an invalid marker must not be published"
  pass "reboot execution blocks when the boot-session id is unreadable"
}

# --- single-instance lock is crash-safe -------------------------------------

t_lock_reclaims_from_a_dead_owner() {
  local home fb ran
  home="$TMP_ROOT/lock-dead-owner"; mkdir -p "$home/state/mini-reboot"
  fb=$(fake_sysctl_bin "$home")
  local lockdir dead_pid
  lockdir="$home/state/mini-reboot/check.lock"
  mkdir "$lockdir"
  # A pid that is certainly not alive.
  dead_pid=99999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
  echo "$dead_pid" > "$lockdir/owner"
  ran=$(PATH="$fb:$PATH" FM_HOME="$home" bash -c \
    ". '$LIB'; fm_mrb_with_lock echo ran-ok")
  assert_contains "$ran" "ran-ok" "the guarded function must still run after reclaiming a dead-owner lock"
  pass "a lock left behind by a dead owner pid is reclaimed, not left wedged forever"
}

t_lock_serializes_a_live_owner() {
  local home fb
  home="$TMP_ROOT/lock-live-owner"; mkdir -p "$home/state/mini-reboot"
  fb=$(fake_sysctl_bin "$home")
  local lockdir
  lockdir="$home/state/mini-reboot/check.lock"
  mkdir "$lockdir"
  printf '%s\n' "$$" > "$lockdir/owner"
  local out
  out=$(PATH="$fb:$PATH" FM_HOME="$home" bash -c \
    ". '$LIB'; fm_mrb_with_lock echo should-not-run" 2>&1)
  assert_not_contains "$out" "should-not-run" "a live owner's lock must not be reclaimed or bypassed"
  rm -rf "$lockdir"
  pass "a lock held by a live owner is never reclaimed or bypassed"
}

t_check_cycle_stops_after_sample_failure() {
  local home out marker
  home="$TMP_ROOT/cycle-sample-failure"; mkdir -p "$home"
  marker="$home/evaluate-called"
  out=$(FM_HOME="$home" bash -c ". '$LIB';
    fm_mrb_append_sample() { return 1; }
    fm_mrb_evaluate() { echo called > '$marker'; echo trigger=yes; }
    fm_mrb_check_cycle" 2>&1)
  assert_contains "$out" "current sample is invalid" "the cycle should diagnose invalid current metrics"
  assert_absent "$marker" "stale history must not be evaluated after current sample collection fails"
  pass "the check cycle stops when current sample collection fails"
}

# --- the AND-gate: never reboots on either condition alone ------------------

t_check_cycle_does_nothing_when_resource_not_triggered() {
  local home fb
  home="$TMP_ROOT/cycle-no-trigger"; mkdir -p "$home/config" "$home/state/mini-reboot"
  echo "mini" > "$home/config/host-role"
  local helper="$home/helper.sh"
  cat > "$helper" <<EOF
#!/usr/bin/env bash
echo invoked >> "$home/helper-invocations.log"
exit 0
EOF
  chmod +x "$helper"
  echo "$helper" > "$home/config/mini-reboot-helper"
  fb=$(fake_sysctl_bin "$home")
  cat > "$fb/vm_stat" <<'SH'
#!/usr/bin/env bash
echo "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
echo "Pages free: 0."
echo "Pages wired down: 0."
echo "Pages purgeable: 0."
echo "Pages occupied by compressor: 0."
echo "Swapins: 0."
echo "Swapouts: 0."
SH
  chmod +x "$fb/vm_stat"
  cat > "$fb/zprint" <<'SH'
#!/usr/bin/env bash
echo "zone name elem size ... inuse"
SH
  chmod +x "$fb/zprint"
  PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=1000 \
    bash -c ". '$LIB'; fm_mrb_check_cycle" >/dev/null 2>&1
  assert_absent "$home/helper-invocations.log" "the reboot helper must never be invoked when resource is not triggered"
  pass "check cycle with resource NOT triggered never invokes the reboot helper (does nothing)"
}

# fake_wired_bin <dir> <wired_pages>: page size 1, so wired bytes == wired_pages.
fake_wired_bin() {
  local dir=$1 wired=$2 fb
  fb=$(fake_sysctl_bin "$dir")
  cat > "$fb/sysctl" <<SH
#!/usr/bin/env bash
if [ "\$1" = "-n" ] && [ "\$2" = "kern.bootsessionuuid" ]; then
  echo "\${FM_FAKE_BOOT_ID:-BOOT-A}"; exit 0
fi
if [ "\$1" = "-n" ] && [ "\$2" = "hw.pagesize" ]; then echo 1; exit 0; fi
if [ "\$1" = "-n" ]; then echo 0; exit 0; fi
echo "vm.swapusage: total = 1M used = 0M free = 1M"
SH
  chmod +x "$fb/sysctl"
  cat > "$fb/vm_stat" <<EOF
#!/usr/bin/env bash
echo "Mach Virtual Memory Statistics: (page size of 1 bytes)"
echo "Pages free: 0."
echo "Pages wired down: $wired."
echo "Pages purgeable: 0."
echo "Pages occupied by compressor: 0."
echo "Swapins: 0."
echo "Swapouts: 0."
EOF
  chmod +x "$fb/vm_stat"
  cat > "$fb/zprint" <<'SH'
#!/usr/bin/env bash
echo "data.kalloc.1024 1 0K 0K 0 0 0 0K 0"
SH
  chmod +x "$fb/zprint"
  printf '%s\n' "$fb"
}

t_check_cycle_reboots_only_when_both_conditions_genuinely_hold() {
  local home fb helper other_home over
  home="$TMP_ROOT/cycle-both"; mkdir -p "$home/config" "$home/state/mini-reboot"
  other_home="$TMP_ROOT/cycle-both-idle-home"
  echo "mini" > "$home/config/host-role"
  helper="$home/helper.sh"
  cat > "$helper" <<EOF
#!/usr/bin/env bash
echo "invoked: \$1" >> "$home/helper-invocations.log"
exit 0
EOF
  chmod +x "$helper"
  echo "$helper" > "$home/config/mini-reboot-helper"
  mkdir -p "$other_home/state" "$other_home/data"
  printf '# Backlog\n\n## Done\n' > "$other_home/data/backlog.md"
  printf '%s\n' "$other_home" > "$home/config/mini-reboot-homes"

  over=$(( $(FM_HOME="$home" bash -c ". '$LIB'; fm_mrb_maint_wired_bytes") + 1 ))
  fb=$(fake_wired_bin "$home" "$over")

  # Two prior samples already over threshold (check_cycle's own internal
  # append will be the third consecutive one), and one prior idle snapshot
  # far enough back that the internal idle-confirm call completes the
  # two-snapshot window.
  PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=100 bash -c ". '$LIB'; fm_mrb_append_sample"
  PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=200 bash -c ". '$LIB'; fm_mrb_append_sample"
  PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=300 bash -c ". '$LIB'; fm_mrb_idle_confirm" >/dev/null

  PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=700 bash -c ". '$LIB'; fm_mrb_check_cycle" >&2

  assert_present "$home/helper-invocations.log" "the reboot helper must be invoked when BOTH conditions genuinely hold"
  pass "check cycle reboots only once resource is triggered AND idle is confirmed, together"
}

t_check_cycle_does_not_reboot_when_only_resource_triggers() {
  local home fb helper over
  home="$TMP_ROOT/cycle-resource-only"; mkdir -p "$home/config" "$home/state/mini-reboot"
  echo "mini" > "$home/config/host-role"
  helper="$home/helper.sh"
  cat > "$helper" <<EOF
#!/usr/bin/env bash
echo invoked >> "$home/helper-invocations.log"
exit 0
EOF
  chmod +x "$helper"
  echo "$helper" > "$home/config/mini-reboot-helper"
  # Deliberately NO config/mini-reboot-homes: idle can never be confirmed.

  over=$(( $(FM_HOME="$home" bash -c ". '$LIB'; fm_mrb_maint_wired_bytes") + 1 ))
  fb=$(fake_wired_bin "$home" "$over")
  PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=100 bash -c ". '$LIB'; fm_mrb_append_sample"
  PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=200 bash -c ". '$LIB'; fm_mrb_append_sample"
  PATH="$fb:$PATH" FM_HOME="$home" FM_MRB_NOW=700 bash -c ". '$LIB'; fm_mrb_check_cycle" >&2

  assert_absent "$home/helper-invocations.log" "the resource condition alone, without a confirmed idle window, must never reboot"
  pass "the resource condition triggering alone (idle never confirmed) never reboots"
}

t_cli_status_subcommand_runs_end_to_end
t_cli_unknown_subcommand_errors
t_execute_reboot_refuses_off_mini
t_execute_reboot_refuses_wrong_role_value
t_host_role_rejects_internal_whitespace
t_host_role_allows_surrounding_whitespace
t_execute_reboot_blocked_without_helper_configured
t_execute_reboot_blocked_with_nonexecutable_helper
t_execute_reboot_invokes_a_real_configured_helper
t_execute_reboot_preserves_spaces_in_helper_path
t_marker_active_blocks_a_second_cycle
t_marker_clears_on_boot_session_change
t_marker_clears_when_stale
t_execute_reboot_blocks_when_boot_session_is_unreadable
t_lock_reclaims_from_a_dead_owner
t_lock_serializes_a_live_owner
t_check_cycle_stops_after_sample_failure
t_check_cycle_does_nothing_when_resource_not_triggered
t_check_cycle_reboots_only_when_both_conditions_genuinely_hold
t_check_cycle_does_not_reboot_when_only_resource_triggers
