#!/usr/bin/env bash
# Behavior tests for bin/fm-mini-reboot-lib.sh's sampler and resource-trigger
# evaluation (report section 6, Phase A: detection only).
#
# Pins:
#   (a) metric collection parses fake vm_stat/zprint/sysctl output correctly
#   (b) deltas are computed and PERSISTED alongside raw values on each append
#   (c) evaluate() never triggers with fewer than the minimum sample count -
#       the direct regression for "must not reboot from a single threshold
#       crossing"
#   (d) trigger condition 1: maintenance threshold crossed in N CONSECUTIVE
#       samples (not just any N out of a longer history)
#   (e) trigger condition 2: slope forecast over a recent window predicts the
#       hard ceiling within the forecast horizon; a shallower slope that would
#       cross beyond the horizon does not trigger
#   (f) trigger condition 3: pressure no longer normal AND swapouts trending
#       up over the recent window; pressure alone, or swapouts alone, does not
#       trigger
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-mini-reboot-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-mini-reboot-sampler)

# fake_bin <dir>: a fakebin with deterministic vm_stat/zprint/sysctl, driven by
# env vars read at call time so each test can vary them per sample.
fake_bin() {
  local fb
  fb=$(fm_fakebin "$1")

  cat > "$fb/vm_stat" <<'SH'
#!/usr/bin/env bash
echo "Mach Virtual Memory Statistics: (page size of ${FM_FAKE_PAGESIZE:-16384} bytes)"
echo "Pages free:                    ${FM_FAKE_FREE_PAGES:-0}."
echo "Pages wired down:              ${FM_FAKE_WIRED_PAGES:-0}."
echo "Pages purgeable:               ${FM_FAKE_PURGEABLE_PAGES:-0}."
echo "Pages occupied by compressor:  ${FM_FAKE_COMPRESSOR_PAGES:-0}."
echo "Swapins:                       ${FM_FAKE_SWAPINS:-0}."
echo "Swapouts:                      ${FM_FAKE_SWAPOUTS:-0}."
SH
  chmod +x "$fb/vm_stat"

  cat > "$fb/zprint" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_ZPRINT_FAIL:-0}" = 1 ] && exit 1
echo "                            elem         cur         max        cur         max         cur  alloc  alloc"
echo "zone name                   size        size        size      #elts       #elts       inuse   size  count"
echo "-----------------------------------------------------------------------------------------------------------"
if [ "${FM_FAKE_ZPRINT_MALFORMED:-0}" = 1 ]; then
  echo "data.kalloc.1024             bad        0K          0K           0           0     bad     0K      0"
else
  echo "data.kalloc.1024             1          0K          0K           0           0     ${FM_FAKE_ZONE_BYTES:-0}     0K      0"
fi
SH
  chmod +x "$fb/zprint"

  cat > "$fb/sysctl" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-n" ]; then
  case "$2" in
    hw.pagesize) echo "${FM_FAKE_PAGESIZE:-16384}" ;;
    kern.memorystatus_vm_pressure_level) echo "${FM_FAKE_PRESSURE:-1}" ;;
    kern.bootsessionuuid) echo "${FM_FAKE_BOOT_ID:-BOOT-A}" ;;
    *) echo "0" ;;
  esac
  exit 0
fi
if [ "$1" = "vm.swapusage" ]; then
  echo "vm.swapusage: total = 2048.00M  used = ${FM_FAKE_SWAP_USED_M:-0}.00M  free = 1000.00M  (encrypted)"
  exit 0
fi
echo "0"
SH
  chmod +x "$fb/sysctl"

  printf '%s\n' "$fb"
}

# --- (a) metric collection parses fake output correctly ---------------------

t_collect_sample_parses_metrics() {
  local dir fb out
  dir="$TMP_ROOT/collect"; mkdir -p "$dir"
  fb=$(fake_bin "$dir")
  export FM_HOME="$dir/home" FM_MRB_NOW=1000000000
  export FM_FAKE_PAGESIZE=16384 FM_FAKE_WIRED_PAGES=100 FM_FAKE_FREE_PAGES=50 \
         FM_FAKE_ZONE_BYTES=123456789 FM_FAKE_SWAP_USED_M=10 \
         FM_FAKE_PRESSURE=1 FM_FAKE_SWAPINS=5 FM_FAKE_SWAPOUTS=7
  out=$(PATH="$fb:$PATH" bash -c ". '$LIB'; fm_mrb_collect_sample")
  local epoch zone wired free swap si so pr
  epoch=$(cut -f1 <<< "$out"); zone=$(cut -f2 <<< "$out"); wired=$(cut -f3 <<< "$out")
  free=$(cut -f4 <<< "$out"); swap=$(cut -f7 <<< "$out"); si=$(cut -f8 <<< "$out")
  so=$(cut -f9 <<< "$out"); pr=$(cut -f10 <<< "$out")
  [ "$epoch" = 1000000000 ] || fail "epoch: got $epoch"
  [ "$zone" = 123456789 ] || fail "zone bytes: got $zone"
  [ "$wired" = $((100 * 16384)) ] || fail "wired bytes: got $wired"
  [ "$free" = $((50 * 16384)) ] || fail "free bytes: got $free"
  [ "$swap" = $((10 * 1024 * 1024)) ] || fail "swap bytes: got $swap"
  [ "$si" = 5 ] || fail "swapins: got $si"
  [ "$so" = 7 ] || fail "swapouts: got $so"
  [ "$pr" = normal ] || fail "pressure: got $pr"
  pass "collect_sample parses fake vm_stat/zprint/sysctl into correct byte values"
}

# --- (b) deltas computed and persisted -------------------------------------

t_append_sample_persists_deltas() {
  local dir fb
  dir="$TMP_ROOT/deltas"; mkdir -p "$dir"
  fb=$(fake_bin "$dir")
  export FM_HOME="$dir/home"
  export FM_FAKE_PAGESIZE=1 FM_FAKE_SWAP_USED_M=0 FM_FAKE_PRESSURE=1

  FM_MRB_NOW=1000 FM_FAKE_ZONE_BYTES=100 FM_FAKE_WIRED_PAGES=200 FM_FAKE_SWAPOUTS=1 \
    PATH="$fb:$PATH" bash -c ". '$LIB'; fm_mrb_append_sample"
  FM_MRB_NOW=1300 FM_FAKE_ZONE_BYTES=150 FM_FAKE_WIRED_PAGES=250 FM_FAKE_SWAPOUTS=4 \
    PATH="$fb:$PATH" bash -c ". '$LIB'; fm_mrb_append_sample"

  local samples second zone_delta wired_delta swapouts_delta
  samples="$dir/home/state/mini-reboot/samples.tsv"
  assert_present "$samples" "samples file created"
  second=$(tail -n 1 "$samples")
  zone_delta=$(cut -f11 <<< "$second")
  wired_delta=$(cut -f12 <<< "$second")
  swapouts_delta=$(cut -f13 <<< "$second")
  [ "$zone_delta" = 50 ] || fail "zone_delta: got $zone_delta, want 50"
  [ "$wired_delta" = 50 ] || fail "wired_delta: got $wired_delta, want 50"
  [ "$swapouts_delta" = 3 ] || fail "swapouts_delta: got $swapouts_delta, want 3"
  pass "append_sample computes and persists deltas against the prior row"
}

t_first_sample_has_zero_deltas() {
  local dir fb row
  dir="$TMP_ROOT/first-delta"; mkdir -p "$dir"
  fb=$(fake_bin "$dir")
  export FM_HOME="$dir/home"
  FM_MRB_NOW=1000 FM_FAKE_ZONE_BYTES=999 FM_FAKE_PAGESIZE=1 FM_FAKE_SWAP_USED_M=0 \
    PATH="$fb:$PATH" bash -c ". '$LIB'; fm_mrb_append_sample"
  row=$(cat "$dir/home/state/mini-reboot/samples.tsv")
  [ "$(cut -f11 <<< "$row")" = 0 ] || fail "first-sample zone_delta should be 0"
  [ "$(cut -f12 <<< "$row")" = 0 ] || fail "first-sample wired_delta should be 0"
  [ "$(cut -f13 <<< "$row")" = 0 ] || fail "first-sample swapouts_delta should be 0"
  pass "the very first sample records zero deltas rather than erroring"
}

t_invalid_zprint_does_not_append_a_sample() {
  local dir fb home samples before status
  dir="$TMP_ROOT/invalid-zprint"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  FM_HOME="$home" FM_MRB_NOW=1000 FM_FAKE_ZONE_BYTES=100 FM_FAKE_PAGESIZE=1 \
    PATH="$fb:$PATH" bash -c ". '$LIB'; fm_mrb_append_sample"
  samples="$home/state/mini-reboot/samples.tsv"
  before=$(cat "$samples")
  FM_HOME="$home" FM_MRB_NOW=1100 FM_FAKE_ZPRINT_MALFORMED=1 FM_FAKE_PAGESIZE=1 \
    PATH="$fb:$PATH" bash -c ". '$LIB'; fm_mrb_append_sample" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "malformed zprint must make sample collection fail"
  [ "$(cat "$samples")" = "$before" ] || fail "failed metric collection must leave sample history unchanged"
  pass "malformed zprint output is rejected without appending a sample"
}

# --- helper: append N samples with per-sample overrides ---------------------

# append_series <dir> <fakebin> <home> "<epoch> <zone> <wired_pages> <pressure> <swapouts>" ...
append_series() {
  local fb=$1 home=$2
  shift 2
  local spec epoch zone wired pressure swapouts
  for spec in "$@"; do
    read -r epoch zone wired pressure swapouts <<< "$spec"
    FM_HOME="$home" FM_MRB_NOW="$epoch" FM_FAKE_ZONE_BYTES="$zone" \
      FM_FAKE_WIRED_PAGES="$wired" FM_FAKE_PAGESIZE=1 FM_FAKE_SWAP_USED_M=0 \
      FM_FAKE_PRESSURE="$pressure" FM_FAKE_SWAPOUTS="$swapouts" \
      PATH="$fb:$PATH" bash -c ". '$LIB'; fm_mrb_append_sample"
  done
}

evaluate_with() {
  local home=$1 now=$2
  FM_HOME="$home" FM_MRB_NOW="$now" bash -c ". '$LIB'; fm_mrb_evaluate"
}

# --- (c) never triggers below the minimum sample count ----------------------

t_never_triggers_from_single_sample() {
  local dir fb home out
  dir="$TMP_ROOT/single"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  # One sample already WAY past both maintenance thresholds - must still not
  # trigger, because fewer than the minimum consecutive samples exist.
  append_series "$fb" "$home" "1000 99999999999 99999999999 1 0"
  out=$(evaluate_with "$home" 1000)
  assert_contains "$out" "trigger=no" "single extreme sample must not trigger"
  assert_contains "$out" "insufficient-samples" "reason names insufficient samples"
  pass "a single sample, however extreme, never triggers a reboot condition"
}

t_two_samples_do_not_trigger_threshold_condition() {
  local dir fb home out
  dir="$TMP_ROOT/two"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  append_series "$fb" "$home" \
    "1000 99999999999 99999999999 1 0" \
    "1100 99999999999 99999999999 1 0"
  out=$(evaluate_with "$home" 1100)
  assert_contains "$out" "trigger=no" "two samples must not trigger the 3-sample condition"
  pass "two consecutive over-threshold samples do not trigger (need 3)"
}

# --- (d) maintenance threshold crossed in 3 CONSECUTIVE samples -------------

MAINT_ZONE=$((9 * 1024 * 1024 * 1024))
MAINT_WIRED=$((13 * 1024 * 1024 * 1024))
HARD_ZONE=$((12 * 1024 * 1024 * 1024))

t_three_consecutive_over_threshold_triggers() {
  local dir fb home out
  dir="$TMP_ROOT/three-consec"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  append_series "$fb" "$home" \
    "1000 $((MAINT_ZONE + 1)) 0 1 0" \
    "1100 $((MAINT_ZONE + 1)) 0 1 0" \
    "1200 $((MAINT_ZONE + 1)) 0 1 0"
  out=$(evaluate_with "$home" 1200)
  assert_contains "$out" "trigger=yes" "three consecutive over-threshold samples trigger"
  assert_contains "$out" "maintenance-threshold-crossed" "names the maintenance-threshold reason"
  pass "maintenance threshold crossed in 3 consecutive samples triggers"
}

t_only_two_of_three_consecutive_does_not_trigger() {
  local dir fb home out
  dir="$TMP_ROOT/two-of-three"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  # Uses wired memory (not zone) so the slope-forecast condition, which only
  # tracks zone bytes, cannot also fire and confound this isolated check of
  # the 3-consecutive-samples condition.
  append_series "$fb" "$home" \
    "1000 0 0 1 0" \
    "1100 0 $((MAINT_WIRED + 1)) 1 0" \
    "1200 0 $((MAINT_WIRED + 1)) 1 0"
  out=$(evaluate_with "$home" 1200)
  assert_contains "$out" "trigger=no" "only 2 of the last 3 over threshold must not trigger"
  pass "an earlier under-threshold sample in the last-3 window blocks the trigger"
}

t_wired_alone_over_threshold_triggers() {
  local dir fb home out
  dir="$TMP_ROOT/wired"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  append_series "$fb" "$home" \
    "1000 0 $((MAINT_WIRED + 1)) 1 0" \
    "1100 0 $((MAINT_WIRED + 1)) 1 0" \
    "1200 0 $((MAINT_WIRED + 1)) 1 0"
  out=$(evaluate_with "$home" 1200)
  assert_contains "$out" "trigger=yes" "wired-alone over threshold for 3 samples triggers"
  pass "wired memory alone crossing its threshold for 3 samples triggers (OR, not AND)"
}

# --- (e) slope forecast over a recent window --------------------------------

t_slope_forecast_within_horizon_triggers() {
  local dir fb home out
  dir="$TMP_ROOT/slope-near"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  # Recent window (last 6h = 21600s): rises from 1 GiB below hard ceiling's
  # remaining budget fast enough to cross well within the 24h horizon.
  # dt=3600s, dz = 2 GiB -> slope = 2GiB/hour; remaining to hard ceiling from
  # the latest sample is well under 2 GiB, so forecast_secs << 24h. A third,
  # older, well-under-threshold sample outside the recent window pads the
  # total to the minimum trigger-sample count without disturbing the recent
  # window's oldest/latest pick or accidentally also satisfying the
  # 3-consecutive maintenance-threshold condition.
  append_series "$fb" "$home" \
    "-30000 0 0 1 0" \
    "0 $((HARD_ZONE - 3 * 1024 * 1024 * 1024)) 0 1 0" \
    "3600 $((HARD_ZONE - 1024 * 1024 * 1024)) 0 1 0"
  out=$(evaluate_with "$home" 3600)
  assert_contains "$out" "trigger=yes" "steep recent slope forecasts crossing within horizon"
  assert_contains "$out" "slope-forecast" "names the slope-forecast reason"
  pass "a steep recent slope predicting the hard ceiling within the horizon triggers"
}

t_slope_forecast_beyond_horizon_does_not_trigger() {
  local dir fb home out
  dir="$TMP_ROOT/slope-far"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  # Tiny rise over a long recent-window span -> forecast far beyond horizon.
  append_series "$fb" "$home" \
    "-30000 0 0 1 0" \
    "0 $((1024 * 1024 * 1024)) 0 1 0" \
    "3600 $((1024 * 1024 * 1024 + 1024)) 0 1 0"
  out=$(evaluate_with "$home" 3600)
  assert_contains "$out" "trigger=no" "a shallow slope forecasting far beyond the horizon must not trigger"
  pass "a shallow recent slope that would only cross far beyond the horizon does not trigger"
}

t_rise_then_fall_below_ceiling_does_not_trigger() {
  local dir fb home out
  dir="$TMP_ROOT/slope-falling"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  append_series "$fb" "$home" \
    "1000 0 0 1 0" \
    "1100 $((HARD_ZONE - 512 * 1024 * 1024)) 0 1 0" \
    "1200 $((HARD_ZONE - 1024 * 1024 * 1024)) 0 1 0"
  out=$(evaluate_with "$home" 1200)
  assert_contains "$out" "trigger=no" "a below-ceiling falling recent segment must block the net-positive slope forecast"
  pass "a rise then fall below the hard ceiling does not trigger"
}

t_lifetime_first_sample_does_not_pollute_recent_slope() {
  local dir fb home out
  dir="$TMP_ROOT/slope-window"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  # A large jump long ago (outside the 6h recent window), then flat recently:
  # using the lifetime first-vs-last sample would show a big slope; using
  # only the recent window must not.
  append_series "$fb" "$home" \
    "0 0 0 1 0" \
    "100000 $((5 * 1024 * 1024 * 1024)) 0 1 0" \
    "$((100000 + 3600)) $((5 * 1024 * 1024 * 1024 + 1024)) 0 1 0"
  out=$(evaluate_with "$home" $((100000 + 3600)))
  assert_contains "$out" "trigger=no" "an old jump outside the recent window must not drive the slope forecast"
  pass "slope forecast uses the recent window only, not the lifetime first-vs-last sample"
}

# --- (f) pressure + rising swapouts -----------------------------------------

t_pressure_and_rising_swapouts_triggers() {
  local dir fb home out
  dir="$TMP_ROOT/pressure-swap"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  append_series "$fb" "$home" \
    "1000 0 0 1 10" \
    "1100 0 0 2 15" \
    "1200 0 0 2 20"
  out=$(evaluate_with "$home" 1200)
  assert_contains "$out" "trigger=yes" "warn pressure with rising swapouts triggers"
  assert_contains "$out" "pressure-warn-with-rising-swapouts" "names the pressure/swapout reason"
  pass "pressure no longer normal with rising swapouts triggers"
}

t_pressure_alone_without_rising_swapouts_does_not_trigger() {
  local dir fb home out
  dir="$TMP_ROOT/pressure-only"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  append_series "$fb" "$home" \
    "1000 0 0 2 20" \
    "1100 0 0 2 20" \
    "1200 0 0 2 20"
  out=$(evaluate_with "$home" 1200)
  assert_contains "$out" "trigger=no" "pressure alone without rising swapouts must not trigger"
  pass "elevated pressure with flat swapouts does not trigger"
}

t_rising_swapouts_alone_without_pressure_does_not_trigger() {
  local dir fb home out
  dir="$TMP_ROOT/swap-only"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  append_series "$fb" "$home" \
    "1000 0 0 1 10" \
    "1100 0 0 1 15" \
    "1200 0 0 1 20"
  out=$(evaluate_with "$home" 1200)
  assert_contains "$out" "trigger=no" "rising swapouts under normal pressure must not trigger"
  pass "rising swapouts alone under normal pressure does not trigger"
}

t_unknown_pressure_with_rising_swapouts_does_not_trigger() {
  local dir fb home out
  dir="$TMP_ROOT/pressure-unknown"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  append_series "$fb" "$home" \
    "1000 0 0 0 10" \
    "1100 0 0 0 15" \
    "1200 0 0 0 20"
  out=$(evaluate_with "$home" 1200)
  assert_contains "$out" "trigger=no" "unknown pressure must fail closed despite rising swapouts"
  pass "unknown pressure with rising swapouts does not trigger"
}

t_pre_window_swapout_delta_does_not_trigger() {
  local dir fb home out
  dir="$TMP_ROOT/pressure-pre-window-delta"; mkdir -p "$dir"
  fb=$(fake_bin "$dir"); home="$dir/home"
  append_series "$fb" "$home" \
    "900 0 0 1 0" \
    "1000 0 0 2 100" \
    "1100 0 0 2 50" \
    "1200 0 0 2 50"
  out=$(evaluate_with "$home" 1200)
  assert_contains "$out" "trigger=no" "a pre-window increase must not outweigh falling then flat selected swapouts"
  pass "swapout trend excludes the first selected row's pre-window delta"
}

t_collect_sample_parses_metrics
t_append_sample_persists_deltas
t_first_sample_has_zero_deltas
t_invalid_zprint_does_not_append_a_sample
t_never_triggers_from_single_sample
t_two_samples_do_not_trigger_threshold_condition
t_three_consecutive_over_threshold_triggers
t_only_two_of_three_consecutive_does_not_trigger
t_wired_alone_over_threshold_triggers
t_slope_forecast_within_horizon_triggers
t_slope_forecast_beyond_horizon_does_not_trigger
t_rise_then_fall_below_ceiling_does_not_trigger
t_lifetime_first_sample_does_not_pollute_recent_slope
t_pressure_and_rising_swapouts_triggers
t_pressure_alone_without_rising_swapouts_does_not_trigger
t_rising_swapouts_alone_without_pressure_does_not_trigger
t_unknown_pressure_with_rising_swapouts_does_not_trigger
t_pre_window_swapout_delta_does_not_trigger
