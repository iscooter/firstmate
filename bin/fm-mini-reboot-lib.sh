#!/usr/bin/env bash
# fm-mini-reboot-lib.sh - detect-and-idle-gated self-reboot logic for a single
# mini host. NOT sourced by fm-spawn.sh, fm-promote.sh, or fm-backlog-handoff.sh:
# this feature does not touch cross-home admission at all.
#
# Design (captain 2026-08-24 retarget): no drain, no admission lock, no
# blocking or holding new work, no fleet-emptying, no attack resistance, no
# readiness-receipt machinery. Reboot the mini ONLY when BOTH:
#   (a) a resource-leak/pressure threshold has genuinely been crossed
#       (never from a single sample - see fm_mrb_evaluate); AND
#   (b) the fleet is genuinely, robustly idle (two consecutive confirmed-idle
#       checks at least 5 minutes apart - see fm_mrb_idle_confirm).
# If both are not true, do nothing; the machine handles load best-effort.
#
# Mini only: fm_mrb_host_is_mini gates every reboot attempt on an explicit
# config/host-role file that must say exactly "mini". A MacBook (or any host
# without that file) never reboots through this code, by construction.
#
# Reboot EXECUTION is delegated to an external, separately-provisioned
# executable named by config/mini-reboot-helper. This library never fakes or
# stubs privileged access: if that file is absent or not executable,
# fm_mrb_execute_reboot logs a clear diagnostic and returns non-zero rather than
# attempting anything.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

FM_MRB_LOG_PREFIX="${FM_MRB_LOG_PREFIX:-fm-mini-reboot}"

fm_mrb_log() {
  echo "$FM_MRB_LOG_PREFIX: $*" >&2
}

fm_mrb_now() {
  echo "${FM_MRB_NOW:-$(date +%s)}"
}

# --- paths -------------------------------------------------------------

fm_mrb_config_dir() {
  echo "${FM_MRB_CONFIG_OVERRIDE:-$FM_HOME/config}"
}

fm_mrb_state_dir() {
  local dir
  dir="${FM_MRB_STATE_OVERRIDE:-$FM_HOME/state/mini-reboot}"
  mkdir -p "$dir"
  echo "$dir"
}

fm_mrb_samples_file() { echo "$(fm_mrb_state_dir)/samples.tsv"; }
fm_mrb_idle_snapshot_file() { echo "$(fm_mrb_state_dir)/idle-snapshot.tsv"; }
fm_mrb_lock_dir() { echo "$(fm_mrb_state_dir)/check.lock"; }
fm_mrb_reboot_marker_file() { echo "$(fm_mrb_state_dir)/reboot-in-progress"; }
fm_mrb_attempts_log() { echo "$(fm_mrb_state_dir)/reboot-attempts.log"; }

# --- thresholds (mini 64 GiB row, report section 4) ---------------------
# Overridable only via env, for tests. No persistent tunable config file:
# keep this minimal and single-purpose rather than growing a generic knob
# surface.

fm_mrb_maint_zone_bytes()  { echo "${FM_MRB_MAINT_ZONE_BYTES:-$((9  * 1024 * 1024 * 1024))}"; }   # 9 GiB
fm_mrb_maint_wired_bytes() { echo "${FM_MRB_MAINT_WIRED_BYTES:-$((13 * 1024 * 1024 * 1024))}"; }  # 13 GiB
fm_mrb_hard_zone_bytes()   { echo "${FM_MRB_HARD_ZONE_BYTES:-$((12 * 1024 * 1024 * 1024))}"; }    # 12 GiB ceiling
fm_mrb_slope_window_secs() { echo "${FM_MRB_SLOPE_WINDOW_SECS:-21600}"; }    # 6h recent window
fm_mrb_forecast_horizon_secs() { echo "${FM_MRB_FORECAST_HORIZON_SECS:-86400}"; }  # 24h
fm_mrb_swap_trend_samples() { echo "${FM_MRB_SWAP_TREND_SAMPLES:-3}"; }
fm_mrb_min_trigger_samples() { echo "${FM_MRB_MIN_TRIGGER_SAMPLES:-3}"; }
fm_mrb_prune_window_secs() { echo "${FM_MRB_PRUNE_WINDOW_SECS:-1209600}"; }  # 14 days
fm_mrb_idle_min_gap_secs() { echo "${FM_MRB_IDLE_MIN_GAP_SECS:-300}"; }   # 5 min, report Phase D
fm_mrb_idle_max_gap_secs() { echo "${FM_MRB_IDLE_MAX_GAP_SECS:-1800}"; }  # 30 min: stitched, not stale
fm_mrb_marker_max_age_secs() { echo "${FM_MRB_MARKER_MAX_AGE_SECS:-1200}"; }  # 20 min

# --- metric collection ---------------------------------------------------

fm_mrb_pagesize_bytes() {
  sysctl -n hw.pagesize 2>/dev/null
}

# fm_mrb_vm_stat_field <label> <vm_stat output>: prints the raw integer count
# for a "Label:  12345." line, or empty on no match.
fm_mrb_vm_stat_field() {
  local label=$1 raw=$2
  printf '%s\n' "$raw" | awk -F: -v label="$label" '
    $1 == label { gsub(/[ .]/, "", $2); print $2; exit }
  '
}

# fm_mrb_zone_bytes: live payload of the two named leaking zones (report
# section 4: element size * in-use count for data.kalloc.1024 and
# data_shared.kalloc.1024), in bytes.
fm_mrb_zone_bytes() {
  local raw
  raw=$(zprint 2>/dev/null) || return 1
  printf '%s\n' "$raw" | awk '
    $1 == "data.kalloc.1024" || $1 == "data_shared.kalloc.1024" {
      found = 1
      if ($2 !~ /^[0-9]+$/ || $7 !~ /^[0-9]+$/) invalid = 1
      sum += $2 * $7
    }
    END {
      if (!found || invalid) exit 1
      printf "%.0f\n", sum
    }
  '
}

# fm_mrb_swap_used_bytes: parses `sysctl vm.swapusage`'s "used = 552.25M"
# (or ...G) into bytes.
fm_mrb_swap_used_bytes() {
  local raw
  raw=$(sysctl vm.swapusage 2>/dev/null) || return 1
  printf '%s\n' "$raw" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "used") { val = $(i + 2); break }
      }
    }
    END {
      if (val !~ /^[0-9]+([.][0-9]+)?[MG]$/) exit 1
      unit = substr(val, length(val), 1)
      num = substr(val, 1, length(val) - 1)
      mult = 1024 * 1024
      if (unit == "G") mult = 1024 * 1024 * 1024
      printf "%.0f\n", num * mult
    }
  '
}

# fm_mrb_pressure_level: normal|warn|critical|unknown, from
# kern.memorystatus_vm_pressure_level (1=normal, 2=warn, 4=critical - standard
# macOS values; any other/unreadable value is unknown, never assumed normal).
fm_mrb_pressure_level() {
  local raw
  raw=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
  case "$raw" in
    1) echo normal ;;
    2) echo warn ;;
    4) echo critical ;;
    *) echo unknown ;;
  esac
}

fm_mrb_boot_session_id() {
  sysctl -n kern.bootsessionuuid 2>/dev/null
}

# fm_mrb_collect_sample: prints one TSV row of RAW metrics (no deltas - those
# are computed and persisted by fm_mrb_append_sample against the prior row,
# per the sample contract):
#   epoch  zone_bytes  wired_bytes  free_bytes  compressor_bytes  purgeable_bytes  swap_used_bytes  swapins  swapouts  pressure
fm_mrb_collect_sample() {
  local page vmstat wired free compressor purgeable swapins swapouts zone swap pressure value
  page=$(fm_mrb_pagesize_bytes) || return 1
  case "$page" in ''|*[!0-9]*|0) return 1 ;; esac
  vmstat=$(vm_stat 2>/dev/null) || return 1
  wired=$(fm_mrb_vm_stat_field "Pages wired down" "$vmstat")
  free=$(fm_mrb_vm_stat_field "Pages free" "$vmstat")
  compressor=$(fm_mrb_vm_stat_field "Pages occupied by compressor" "$vmstat")
  purgeable=$(fm_mrb_vm_stat_field "Pages purgeable" "$vmstat")
  swapins=$(fm_mrb_vm_stat_field "Swapins" "$vmstat")
  swapouts=$(fm_mrb_vm_stat_field "Swapouts" "$vmstat")
  for value in "$wired" "$free" "$compressor" "$purgeable" "$swapins" "$swapouts"; do
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
  done
  zone=$(fm_mrb_zone_bytes) || return 1
  swap=$(fm_mrb_swap_used_bytes) || return 1
  case "$zone:$swap" in *[!0-9:]*) return 1 ;; esac
  pressure=$(fm_mrb_pressure_level)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(fm_mrb_now)" \
    "$zone" \
    "$(( wired * page ))" \
    "$(( free * page ))" \
    "$(( compressor * page ))" \
    "$(( purgeable * page ))" \
    "$swap" \
    "$swapins" \
    "$swapouts" \
    "$pressure"
}

# fm_mrb_append_sample: collects one sample, computes deltas against the most
# recent persisted row (0 when there is none), and appends the full row -
# raw values AND deltas persisted together, never derived only transiently at
# evaluation time. Prunes rows older than fm_mrb_prune_window_secs first.
#
# Persisted columns:
#   epoch zone wired free compressor purgeable swap swapins swapouts pressure \
#   zone_delta wired_delta swapouts_delta
fm_mrb_append_sample() {
  local file raw prev_zone=0 prev_wired=0 prev_swapouts=0 has_prev=0
  file=$(fm_mrb_samples_file)
  fm_mrb_prune_old_samples
  if [ -s "$file" ]; then
    local last
    last=$(tail -n 1 "$file")
    if [ -n "$last" ]; then
      prev_zone=$(printf '%s' "$last" | cut -f2)
      prev_wired=$(printf '%s' "$last" | cut -f3)
      prev_swapouts=$(printf '%s' "$last" | cut -f9)
      has_prev=1
    fi
  fi
  if ! raw=$(fm_mrb_collect_sample); then
    fm_mrb_log "sample collection failed; leaving history unchanged"
    return 1
  fi
  local zone wired swapouts zone_delta wired_delta swapouts_delta
  zone=$(printf '%s' "$raw" | cut -f2)
  wired=$(printf '%s' "$raw" | cut -f3)
  swapouts=$(printf '%s' "$raw" | cut -f9)
  if [ "$has_prev" = 1 ]; then
    zone_delta=$(( zone - prev_zone ))
    wired_delta=$(( wired - prev_wired ))
    swapouts_delta=$(( swapouts - prev_swapouts ))
  else
    zone_delta=0
    wired_delta=0
    swapouts_delta=0
  fi
  printf '%s\t%s\t%s\t%s\n' "$raw" "$zone_delta" "$wired_delta" "$swapouts_delta" >> "$file"
}

fm_mrb_prune_old_samples() {
  local file cutoff tmp
  file=$(fm_mrb_samples_file)
  [ -s "$file" ] || return 0
  cutoff=$(( $(fm_mrb_now) - $(fm_mrb_prune_window_secs) ))
  tmp="$file.tmp.$$"
  awk -F'\t' -v cutoff="$cutoff" '$1 >= cutoff' "$file" > "$tmp" && mv "$tmp" "$file"
}

# fm_mrb_recent_samples <window_secs>: prints rows with epoch within the last
# <window_secs>, oldest first.
fm_mrb_recent_samples() {
  local window=$1 file cutoff
  file=$(fm_mrb_samples_file)
  [ -s "$file" ] || return 0
  cutoff=$(( $(fm_mrb_now) - window ))
  awk -F'\t' -v cutoff="$cutoff" '$1 >= cutoff' "$file"
}

fm_mrb_sample_count() {
  local file=$1
  [ -s "$file" ] || { echo 0; return; }
  wc -l < "$file" | tr -d ' '
}

# --- resource evaluation --------------------------------------------------

# fm_mrb_evaluate: prints "trigger=yes|no" on the first line, followed by one
# reason line per condition that held. Never triggers with fewer than
# fm_mrb_min_trigger_samples total samples recorded (never fires from a single
# sample, or from an as-yet too-short history).
fm_mrb_evaluate() {
  local file total maint_zone maint_wired hard_zone
  file=$(fm_mrb_samples_file)
  total=$(fm_mrb_sample_count "$file")
  maint_zone=$(fm_mrb_maint_zone_bytes)
  maint_wired=$(fm_mrb_maint_wired_bytes)
  hard_zone=$(fm_mrb_hard_zone_bytes)

  local min_n
  min_n=$(fm_mrb_min_trigger_samples)
  if [ "$total" -lt "$min_n" ]; then
    echo "trigger=no"
    echo "reason=insufficient-samples($total<$min_n)"
    return 0
  fi

  local trigger=no
  local -a reasons=()

  # Condition 1: maintenance threshold crossed in the last N consecutive
  # samples.
  local last_n
  last_n=$(tail -n "$min_n" "$file")
  local crossed=1
  local rows_seen=0
  while IFS=$'\t' read -r _epoch zone _w free _c _p _s _si _so _pr _zd _wd _sod; do
    [ -n "${zone:-}" ] || continue
    rows_seen=$((rows_seen + 1))
    local wired
    wired=$(printf '%s\n' "$last_n" | awk -F'\t' -v e="$_epoch" '$1==e{print $3; exit}')
    if ! { [ "$zone" -ge "$maint_zone" ] || [ "${wired:-0}" -ge "$maint_wired" ]; }; then
      crossed=0
    fi
  done <<< "$last_n"
  if [ "$rows_seen" -ge "$min_n" ] && [ "$crossed" -eq 1 ]; then
    trigger=yes
    reasons+=("maintenance-threshold-crossed-in-${min_n}-samples")
  fi

  # Condition 2: slope forecast over a recent window predicts the hard
  # ceiling before the forecast horizon.
  local window recent oldest_line latest_line
  window=$(fm_mrb_slope_window_secs)
  recent=$(fm_mrb_recent_samples "$window")
  if [ -n "$recent" ] && [ "$(printf '%s\n' "$recent" | wc -l | tr -d ' ')" -ge 2 ]; then
    oldest_line=$(printf '%s\n' "$recent" | head -n 1)
    latest_line=$(printf '%s\n' "$recent" | tail -n 1)
    local o_epoch o_zone l_epoch l_zone dt dz
    o_epoch=$(printf '%s' "$oldest_line" | cut -f1)
    o_zone=$(printf '%s' "$oldest_line" | cut -f2)
    l_epoch=$(printf '%s' "$latest_line" | cut -f1)
    l_zone=$(printf '%s' "$latest_line" | cut -f2)
    dt=$(( l_epoch - o_epoch ))
    dz=$(( l_zone - o_zone ))
    if [ "$dt" -gt 0 ] && [ "$dz" -gt 0 ] && [ "$l_zone" -lt "$hard_zone" ]; then
      local remaining forecast_secs horizon
      remaining=$(( hard_zone - l_zone ))
      # forecast_secs = remaining / (dz/dt), rearranged to avoid float math.
      forecast_secs=$(( remaining * dt / dz ))
      horizon=$(fm_mrb_forecast_horizon_secs)
      if [ "$forecast_secs" -le "$horizon" ]; then
        trigger=yes
        reasons+=("slope-forecast-crosses-hard-ceiling-in-${forecast_secs}s")
      fi
    elif [ "$l_zone" -ge "$hard_zone" ]; then
      trigger=yes
      reasons+=("zone-already-at-or-past-hard-ceiling")
    fi
  fi

  # Condition 3: pressure no longer normal and swapouts trending up.
  local latest_pressure trend_n trend_rows swap_sum=0
  latest_pressure=$(tail -n 1 "$file" | cut -f10)
  trend_n=$(fm_mrb_swap_trend_samples)
  trend_rows=$(tail -n "$trend_n" "$file")
  while IFS=$'\t' read -r _e _z _w _f _c _p _s _si _so _pr _zd _wd sod; do
    [ -n "${sod:-}" ] || continue
    swap_sum=$(( swap_sum + sod ))
  done <<< "$trend_rows"
  if { [ "$latest_pressure" = warn ] || [ "$latest_pressure" = critical ]; } \
      && [ "$swap_sum" -gt 0 ]; then
    trigger=yes
    reasons+=("pressure-${latest_pressure}-with-rising-swapouts")
  fi

  echo "trigger=$trigger"
  local r
  for r in "${reasons[@]:-}"; do
    [ -n "$r" ] && echo "reason=$r"
  done
}

fm_mrb_evaluate_triggered() {
  fm_mrb_evaluate | head -n 1 | grep -q '^trigger=yes$'
}

# --- idleness -------------------------------------------------------------
# Reuses the existing idleness signals fm-crew-state.sh, tasks-axi, and the
# documented state/ layout already establish, rather than inventing parallel
# machinery. Every check fails closed: a missing tool, an unreadable
# directory, or any command error is treated as "busy", never as "empty".

# fm_mrb_homes_registry: one FM_HOME path per line from config/mini-reboot-homes
# (blank/'#' lines skipped). Absent or empty registry means no home is
# configured for idle-checking - idle-check-all then reports busy, so the
# guard never reboots an unconfigured fleet by default.
fm_mrb_homes_registry() {
  local file
  file="$(fm_mrb_config_dir)/mini-reboot-homes"
  [ -r "$file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" 2>/dev/null
}

# fm_mrb_idle_check_home <home>: prints "idle" or "busy: <reason>" for one
# home. Any read/tool failure blocks (busy), never passes silently.
fm_mrb_idle_check_home() {
  local home=$1
  if [ ! -d "$home" ]; then
    echo "busy: home path does not exist: $home"
    return 0
  fi

  local state="$home/state"
  if [ ! -d "$state" ] || [ ! -r "$state" ]; then
    echo "busy: state directory is missing or unreadable: $state"
    return 0
  fi

  # 1) zero child task metadata - the strongest simple gate (report Phase C).
  local meta_paths meta_count
  if ! meta_paths=$(find "$state" -maxdepth 1 -name '*.meta' -print 2>&1); then
    echo "busy: could not enumerate $state/*.meta: $meta_paths"
    return 0
  fi
  meta_count=$(printf '%s\n' "$meta_paths" | awk 'NF { count++ } END { print count + 0 }')
  if [ "$meta_count" -gt 0 ]; then
    echo "busy: $meta_count task(s) with metadata in $state"
    return 0
  fi

  # 2) no in-flight backlog item, no open captain decision (tasks-axi held).
  # tasks-axi silently reports "count: 0" (exit 0) for a NONEXISTENT file
  # instead of erroring, so a missing backlog for a home whose directory
  # exists must be treated as busy explicitly - it is never read as "no
  # obligation". `list`/`public-followup` do not accept --json (that itself
  # errors as an unknown flag); their plain output's leading "count: N" line
  # is what is parsed here.
  local backlog="$home/data/backlog.md"
  if [ ! -f "$backlog" ]; then
    echo "busy: no backlog file at $backlog, cannot verify idleness"
    return 0
  fi
  if ! command -v tasks-axi >/dev/null 2>&1; then
    echo "busy: tasks-axi not available to check $backlog"
    return 0
  fi
  local in_flight held in_flight_n held_n
  if ! in_flight=$(tasks-axi list --file "$backlog" --state in_flight 2>&1); then
    echo "busy: tasks-axi in_flight check failed for $backlog: $in_flight"
    return 0
  fi
  in_flight_n=$(printf '%s\n' "$in_flight" | awk -F': ' '/^count:/{print $2; exit}')
  if ! [[ "$in_flight_n" =~ ^[0-9]+$ ]]; then
    echo "busy: could not parse tasks-axi in_flight count for $backlog"
    return 0
  fi
  if [ "$in_flight_n" -gt 0 ]; then
    echo "busy: $in_flight_n in-flight backlog item(s) in $backlog"
    return 0
  fi
  if ! held=$(tasks-axi list --file "$backlog" --state held 2>&1); then
    echo "busy: tasks-axi held check failed for $backlog: $held"
    return 0
  fi
  held_n=$(printf '%s\n' "$held" | awk -F': ' '/^count:/{print $2; exit}')
  if ! [[ "$held_n" =~ ^[0-9]+$ ]]; then
    echo "busy: could not parse tasks-axi held count for $backlog"
    return 0
  fi
  if [ "$held_n" -gt 0 ]; then
    echo "busy: $held_n open captain decision(s) held in $backlog"
    return 0
  fi

  # 3) no unhandled steering-inbox message for any task under this home.
  local unhandled
  if ! unhandled=$(find "$state" -mindepth 2 -maxdepth 2 -path '*.inbox/*.msg' -print 2>&1); then
    echo "busy: could not enumerate steering inboxes under $state: $unhandled"
    return 0
  fi
  if [ -n "$unhandled" ]; then
    echo "busy: unhandled steering inbox message under $state"
    return 0
  fi

  # 4) no pending remote reply.
  if [ -d "$state/pending-replies" ]; then
    local pr_paths
    if ! pr_paths=$(find "$state/pending-replies" -mindepth 1 -print 2>&1); then
      echo "busy: could not enumerate $state/pending-replies: $pr_paths"
      return 0
    fi
    if [ -n "$pr_paths" ]; then
      echo "busy: pending remote reply record(s) in $state/pending-replies"
      return 0
    fi
  fi

  # 5) no promised public reply still owed. Both the backlog and tasks-axi
  # presence were already established above (they are required, not
  # optional, for this home to be checked at all).
  if ! command -v jq >/dev/null 2>&1; then
    echo "busy: jq not available to inspect public followups for $backlog"
    return 0
  fi
  local followup followup_n
  if ! followup=$(tasks-axi public-followup list --file "$backlog" --json 2>&1); then
    echo "busy: tasks-axi public-followup check failed for $backlog: $followup"
    return 0
  fi
  if ! followup_n=$(printf '%s\n' "$followup" | jq -er \
      '(.public_followups // []) | map(select((.state // "") != "done")) | length' 2>/dev/null); then
    echo "busy: could not parse tasks-axi public-followup list for $backlog"
    return 0
  fi
  if ! [[ "$followup_n" =~ ^[0-9]+$ ]]; then
    echo "busy: invalid tasks-axi public-followup count for $backlog"
    return 0
  fi
  if [ "$followup_n" -gt 0 ]; then
    echo "busy: $followup_n promised public reply/replies still owed for $backlog"
    return 0
  fi

  # 6) no registered process-event source (presence alone keeps supervision
  #    required, per AGENTS.md).
  if [ -d "$state/procevent" ]; then
    local pe_paths
    if ! pe_paths=$(find "$state/procevent" -mindepth 1 -print 2>&1); then
      echo "busy: could not enumerate $state/procevent: $pe_paths"
      return 0
    fi
    if [ -n "$pe_paths" ]; then
      echo "busy: registered process-event source(s) in $state/procevent"
      return 0
    fi
  fi

  echo idle
}

# fm_mrb_idle_check_all: prints "idle" only when every registered home reports
# idle. An empty registry, or any single busy/error home, blocks.
fm_mrb_idle_check_all() {
  local homes home verdict any=0
  homes=$(fm_mrb_homes_registry)
  if [ -z "$homes" ]; then
    echo "busy: no homes registered for idle-check (config/mini-reboot-homes)"
    return 0
  fi
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    any=1
    verdict=$(fm_mrb_idle_check_home "$home")
    if [ "$verdict" != idle ]; then
      echo "$verdict (home=$home)"
      return 0
    fi
  done <<< "$homes"
  if [ "$any" -eq 0 ]; then
    echo "busy: no homes registered for idle-check (config/mini-reboot-homes)"
    return 0
  fi
  echo idle
}

# fm_mrb_idle_confirm: runs idle-check-all now, persists the snapshot, and
# compares it with the immediately preceding persisted snapshot. Confirmed
# only when both snapshots are idle AND the gap between them is within
# [idle_min_gap_secs, idle_max_gap_secs] - two genuinely back-to-back idle
# reads, not a momentary gap and not two isolated readings stitched together
# across an unrelated span (report Phase D: "two identical fleet snapshots at
# least 5 minutes apart"). Always persists the current snapshot for next time,
# regardless of the verdict.
fm_mrb_idle_confirm() {
  local file now verdict prev_epoch prev_verdict confirmed=no reason
  file=$(fm_mrb_idle_snapshot_file)
  now=$(fm_mrb_now)
  verdict=$(fm_mrb_idle_check_all)

  if [ -s "$file" ]; then
    local last
    last=$(tail -n 1 "$file")
    prev_epoch=$(printf '%s' "$last" | cut -f1)
    prev_verdict=$(printf '%s' "$last" | cut -f2-)
  fi

  if [ "$verdict" = idle ] && [ "${prev_verdict:-}" = idle ] && [ -n "${prev_epoch:-}" ]; then
    local gap min_gap max_gap
    gap=$(( now - prev_epoch ))
    min_gap=$(fm_mrb_idle_min_gap_secs)
    max_gap=$(fm_mrb_idle_max_gap_secs)
    if [ "$gap" -ge "$min_gap" ] && [ "$gap" -le "$max_gap" ]; then
      confirmed=yes
      reason="two-idle-snapshots-${gap}s-apart"
    else
      reason="idle-but-gap-out-of-window(${gap}s)"
    fi
  else
    reason="not-both-idle(now=$verdict prev=${prev_verdict:-none})"
  fi

  printf '%s\t%s\n' "$now" "$verdict" >> "$file"

  echo "confirmed=$confirmed"
  echo "reason=$reason"
  echo "verdict=$verdict"
}

fm_mrb_idle_confirmed() {
  fm_mrb_idle_confirm | head -n 1 | grep -q '^confirmed=yes$'
}

# --- mini-only gate and reboot execution ----------------------------------

# fm_mrb_host_is_mini: true only when config/host-role is present and its
# trimmed content is exactly "mini". Absent-by-default, so a MacBook (or any
# unconfigured host) never reboots through this code.
fm_mrb_host_is_mini() {
  local file content
  file="$(fm_mrb_config_dir)/host-role"
  [ -r "$file" ] || return 1
  content=$(tr -d '[:space:]' < "$file")
  [ "$content" = mini ]
}

# fm_mrb_reboot_marker_active: true when a reboot was already attempted and
# the marker's recorded boot-session id still matches the live one (i.e. the
# machine has not actually rebooted since) and the marker is not yet stale.
# A boot-session-id mismatch means the reboot happened - clears the marker and
# returns false. A same-session marker older than fm_mrb_marker_max_age_secs
# means the helper evidently did not reboot us - clears it and returns false
# so evaluation can resume.
fm_mrb_reboot_marker_active() {
  local file epoch boot_id now cur_boot
  file=$(fm_mrb_reboot_marker_file)
  [ -f "$file" ] || return 1
  epoch=$(awk -F'\t' 'NR==1{print $1}' "$file" 2>/dev/null)
  boot_id=$(awk -F'\t' 'NR==1{print $2}' "$file" 2>/dev/null)
  cur_boot=$(fm_mrb_boot_session_id)
  if [ -n "$boot_id" ] && [ -n "$cur_boot" ] && [ "$boot_id" != "$cur_boot" ]; then
    fm_mrb_log "boot-session changed since marker ($boot_id -> $cur_boot): reboot happened, clearing marker"
    rm -f "$file"
    return 1
  fi
  now=$(fm_mrb_now)
  if [ -n "$epoch" ] && [ $(( now - epoch )) -gt "$(fm_mrb_marker_max_age_secs)" ]; then
    fm_mrb_log "reboot marker stale (age $(( now - epoch ))s): helper apparently did not reboot us, clearing"
    rm -f "$file"
    return 1
  fi
  return 0
}

fm_mrb_write_reboot_marker() {
  local file tmp boot_id
  file=$(fm_mrb_reboot_marker_file)
  boot_id=$(fm_mrb_boot_session_id) || return 1
  case "$boot_id" in ''|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
  tmp="$file.tmp.$$"
  printf '%s\t%s\t%s\n' "$(fm_mrb_now)" "$boot_id" "$1" > "$tmp" || return 1
  mv "$tmp" "$file"
}

# fm_mrb_execute_reboot <reason>: refuses off-mini, refuses without a
# configured+executable helper (never fakes privileged execution - it STOPS
# and logs the exact requirement instead), and writes the reboot-in-progress
# marker BEFORE invoking the helper so a hang or crash after the helper starts
# does not immediately re-fire on the next cycle.
fm_mrb_execute_reboot() {
  local reason=$1 helper_path log
  log=$(fm_mrb_attempts_log)

  if ! fm_mrb_host_is_mini; then
    fm_mrb_log "refusing reboot: this host is not configured as config/host-role=mini"
    printf '%s\trefused\tnot-mini\n' "$(fm_mrb_now)" >> "$log"
    return 1
  fi

  helper_path="$(fm_mrb_config_dir)/mini-reboot-helper"
  local helper
  if [ -r "$helper_path" ]; then
    helper=$(tr -d '[:space:]' < "$helper_path")
  fi
  if [ -z "${helper:-}" ] || [ ! -x "$helper" ]; then
    fm_mrb_log "BLOCKED: no privileged reboot mechanism configured."
    fm_mrb_log "Need config/${FM_MRB_CONFIG_OVERRIDE:+(override) }host-role=mini plus config/mini-reboot-helper naming an executable, root-authorized reboot helper (e.g. a signed launchd-privileged-helper, or a narrowly-scoped sudoers NOPASSWD entry for /sbin/shutdown -r now) - not present or not executable at: ${helper:-<unset>}"
    printf '%s\tblocked\tno-helper-configured\n' "$(fm_mrb_now)" >> "$log"
    return 3
  fi

  if ! fm_mrb_write_reboot_marker "$reason"; then
    fm_mrb_log "BLOCKED: cannot read a valid macOS boot-session id; reboot marker was not published"
    printf '%s\tblocked\tno-boot-session-id\n' "$(fm_mrb_now)" >> "$log"
    return 4
  fi
  fm_mrb_log "invoking reboot helper: $helper (reason: $reason)"
  local status=0
  "$helper" "$reason" || status=$?
  if [ "$status" -eq 0 ]; then
    fm_mrb_log "reboot helper exited 0"
    printf '%s\tinvoked\t%s\n' "$(fm_mrb_now)" "$reason" >> "$log"
  else
    fm_mrb_log "reboot helper exited $status"
    printf '%s\thelper-failed(%s)\t%s\n' "$(fm_mrb_now)" "$status" "$reason" >> "$log"
  fi
  return "$status"
}

# --- orchestration ---------------------------------------------------------

# fm_mrb_with_lock <fn> [args...]: runs <fn> under a single-instance lock so
# overlapping `check` invocations (e.g. a hung prior run still active when the
# next scheduled tick fires) never race. Creation uses the shell's exclusive
# noclobber open. The owner identity combines pid and process start time, and
# an ownerless interrupted write is reclaimed only after a grace period.
fm_mrb_process_identity() {
  local pid=$1 start
  start=$(ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}')
  [ -n "$start" ] || return 1
  printf '%s\t%s\n' "$pid" "$start"
}

fm_mrb_lock_mtime() {
  local value
  value=$(stat -f '%m' "$1" 2>/dev/null || true)
  case "$value" in ''|*[!0-9]*) stat -c '%Y' "$1" 2>/dev/null ;; *) echo "$value" ;; esac
}

fm_mrb_lock_owner() {
  local lock=$1
  [ ! -f "$lock" ] || cat "$lock" 2>/dev/null
}

fm_mrb_lock_owner_stale() {
  local owner=$1 pid signature live_identity
  [ -n "$owner" ] || return 1
  pid=${owner%%$'\t'*}
  signature=
  case "$owner" in *$'\t'*) signature=${owner#*$'\t'} ;; esac
  live_identity=
  case "$pid" in ''|*[!0-9]*) ;; *) live_identity=$(fm_mrb_process_identity "$pid" 2>/dev/null || true) ;; esac
  [ -z "$live_identity" ] || { [ -n "$signature" ] && [ "$live_identity" != "$owner" ]; }
}

fm_mrb_lock_ownerless_stale() {
  local lock=$1 grace=$2 mtime age
  mtime=$(fm_mrb_lock_mtime "$lock" || true)
  [ -n "$mtime" ] || return 1
  age=$(( $(fm_mrb_now) - mtime ))
  [ "$age" -ge "$grace" ]
}

fm_mrb_reclaim_lock() {
  local lock=$1 expected=$2 grace=$3 reap current reclaimed=1
  reap="$lock.reap"
  if [ ! -e "$reap" ]; then
    ln "$lock" "$reap" 2>/dev/null || return 1
  fi
  if [ -f "$lock" ] && [ "$lock" -ef "$reap" ]; then
    current=$(fm_mrb_lock_owner "$reap")
    if [ "$current" = "$expected" ]; then
      if { [ -n "$current" ] && fm_mrb_lock_owner_stale "$current"; } || \
         { [ -z "$current" ] && fm_mrb_lock_ownerless_stale "$reap" "$grace"; }; then
        rm -f "$lock"
        reclaimed=0
      fi
    fi
  fi
  rm -f "$reap"
  return "$reclaimed"
}

fm_mrb_with_lock() {
  local lock owner_value owner pid tries=0
  local grace=${FM_MRB_LOCK_OWNERLESS_GRACE_SECS:-60}
  lock=$(fm_mrb_lock_dir)
  owner_value=$(fm_mrb_process_identity "$$") || {
    fm_mrb_log "could not establish lock owner identity"
    return 1
  }

  while :; do
    if (set -o noclobber; printf '%s\n' "$owner_value" > "$lock") 2>/dev/null; then
      break
    fi
    owner=$(fm_mrb_lock_owner "$lock")
    if fm_mrb_lock_owner_stale "$owner"; then
      pid=${owner%%$'\t'*}
      if fm_mrb_reclaim_lock "$lock" "$owner" "$grace"; then
        fm_mrb_log "reclaimed lock from stale owner pid=${pid:-unknown}"
        continue
      fi
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
      if [ -z "$owner" ] && fm_mrb_reclaim_lock "$lock" "$owner" "$grace"; then
        fm_mrb_log "reclaimed abandoned ownerless lock"
        continue
      fi
      fm_mrb_log "check already running (lock held), skipping this cycle"
      return 0
    fi
    sleep 1
  done

  local status=0 current_owner
  "$@" || status=$?
  current_owner=$(fm_mrb_lock_owner "$lock")
  if [ "$current_owner" = "$owner_value" ]; then
    rm -f "$lock"
  fi
  return "$status"
}

# fm_mrb_check_cycle: the full detect -> idle -> reboot decision for one
# invocation of `check`. Short-circuits on an active reboot marker, and skips
# the (more expensive) idle confirmation entirely unless the resource
# condition actually triggered - AND requires both, so there is never a
# reason to pay for idle-checking when resource is fine.
fm_mrb_check_cycle() {
  if fm_mrb_reboot_marker_active; then
    fm_mrb_log "reboot marker active: a reboot attempt is already in flight, skipping this cycle"
    return 0
  fi

  if ! fm_mrb_append_sample; then
    fm_mrb_log "current sample is invalid, doing nothing"
    return 0
  fi

  local eval_out trig_line
  eval_out=$(fm_mrb_evaluate)
  trig_line=$(printf '%s\n' "$eval_out" | head -n 1)
  if [ "$trig_line" != "trigger=yes" ]; then
    fm_mrb_log "resource condition not triggered, doing nothing"
    return 0
  fi
  fm_mrb_log "resource condition triggered:"
  printf '%s\n' "$eval_out" | tail -n +2 | while IFS= read -r line; do fm_mrb_log "  $line"; done

  local idle_out confirmed_line
  idle_out=$(fm_mrb_idle_confirm)
  confirmed_line=$(printf '%s\n' "$idle_out" | head -n 1)
  if [ "$confirmed_line" != "confirmed=yes" ]; then
    fm_mrb_log "resource triggered but idle window not confirmed, staying put:"
    printf '%s\n' "$idle_out" | while IFS= read -r line; do fm_mrb_log "  $line"; done
    return 0
  fi

  fm_mrb_log "both conditions hold: resource triggered AND idle window confirmed - executing reboot"
  local reason
  reason=$(printf '%s\n' "$eval_out" | tail -n +2 | tr '\n' ';')
  fm_mrb_execute_reboot "$reason"
}
