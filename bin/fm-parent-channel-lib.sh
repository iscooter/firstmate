#!/usr/bin/env bash
# fm-parent-channel-lib.sh - the one owner of a secondmate home's parent channel.
#
# A secondmate home reports upward through exactly one channel, resolved from
# the home's own durable identity and parent binding rather than from any
# caller's choice (docs/secondmate-parent-channel.md):
#   - the .fm-secondmate-home marker names the mate's id in its parent home;
#   - the .fm-secondmate-parent record (bin/fm-secondmate-parent-lib.sh) names
#     the route: a local route reports into the parent home's
#     state/<mate-id>.status, a remote route into this home's own
#     state/parent-replies.status, which the parent's remote reply adapter
#     mirrors line for line into that same parent file.
# Every writer that publishes a parent-facing fact from inside a mate home -
# the merge outcome path, the inactive-outcome scan, the ledger mirror, the PR
# registration, the captain-hold record, and teardown's final sweep - resolves
# the destination here and appends through fm_parent_channel_report, so no
# writer can pick a different file, format a route by hand, or duplicate a
# line it already delivered.
#
# Lines follow the charter's "<state> [key=<slug>]: <note>" shape and are
# appended at most once by exact newline-terminated content; an incomplete
# destination tail is delimited before deduplication or append, so a retried
# publication after a crash never concatenates or duplicates channel events.
#
# Return codes (shared by every entry point that resolves the channel):
#   0  resolved, or appended / already present
#   1  this is a main home (no .fm-secondmate-home marker): nothing to report
#   2  the identity marker exists but is unusable (symlink, NUL, bad id)
#   3  the parent binding is missing or unreadable
#   4  the append itself failed
# A caller that has already recorded the outcome locally must surface a
# non-zero return rather than treat it as delivered.
#
# Sourced by bin/fm-merge-outcome-lib.sh, bin/fm-inactive-reconcile.sh,
# bin/fm-parent-mirror-lib.sh, bin/fm-pr-check.sh, bin/fm-captain-hold.sh,
# bin/fm-teardown.sh, and tests. No side effects on source.

_FM_PARENT_CHANNEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$_FM_PARENT_CHANNEL_LIB_DIR/fm-secondmate-parent-lib.sh"

FM_PARENT_CHANNEL_LOCK_WAIT_SECS=${FM_PARENT_CHANNEL_LOCK_WAIT_SECS:-3}

_fm_parent_channel_require_lock() {
  if ! command -v fm_lock_acquire_wait_bounded >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$_FM_PARENT_CHANNEL_LIB_DIR/fm-wake-lib.sh"
  fi
  _fm_wake_require_timeout
}

# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_PARENT_CHANNEL_ID=
# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_PARENT_CHANNEL_ROUTE=

# Same path-safety rule as bin/fm-pr-lib.sh's fm_task_id_path_safe, restated
# here so this library stays free of the PR library's larger surface.
_fm_parent_channel_id_valid() {  # <id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The secondmate identity of <home>, printed, or non-zero for a main home (1)
# or an unusable identity marker (2).
fm_parent_channel_home_id() {  # <home>
  local home=$1 marker id
  marker="$home/.fm-secondmate-home"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  _fm_parent_channel_id_valid "$id" || return 2
  printf '%s\n' "$id"
}

# Resolve the channel destination for <home> whose state dir is <state>.
# Prints the destination path and sets FM_PARENT_CHANNEL_ID and
# FM_PARENT_CHANNEL_ROUTE. Returns 1 for a main home, 2 for an unusable
# marker, 3 for a missing or unreadable parent binding.
fm_parent_channel_destination() {  # <home> <state>
  local home=$1 state=$2 id rc=0
  FM_PARENT_CHANNEL_ID=
  FM_PARENT_CHANNEL_ROUTE=
  id=$(fm_parent_channel_home_id "$home") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 3
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local)
      [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 3
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ROUTE=local
      printf '%s/state/%s.status\n' "$FM_SECONDMATE_PARENT_HOME" "$id"
      ;;
    remote)
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ROUTE=remote
      printf '%s/parent-replies.status\n' "$state"
      ;;
    *) return 3 ;;
  esac
}

# Fold <text> onto one line and bound it, so a note copied from a child ledger
# or a hold reason cannot break the channel's line framing.
fm_parent_channel_clean_note() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1200
}

_fm_parent_channel_destination_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)'
  fi
}

# Append <line> to <path> unless that exact line is already there.
fm_parent_channel_append_once() {  # <writing-state> <path> <line>
  local STATE=$1 path=$2 line=$3 hash lock last_byte status=0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  _fm_parent_channel_require_lock || return 1
  hash=$(_fm_parent_channel_destination_hash "$path") || return 1
  case "$hash" in ''|*[!0-9a-f]*) return 1 ;; esac
  lock="$STATE/.parent-channel-$hash.lock"
  fm_lock_acquire_wait_bounded "$lock" "$FM_PARENT_CHANNEL_LOCK_WAIT_SECS" || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ ! -f "$path" ] || [ -L "$path" ]; then status=1; fi
  elif ! mkdir -p "$(dirname "$path")"; then
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -s "$path" ]; then
    last_byte=$(tail -c 1 "$path" 2>/dev/null | od -An -tu1 | tr -d '[:space:]') || status=1
    if [ "$status" -eq 0 ] && [ "$last_byte" != 10 ] \
      && ! printf '\n' >> "$path"; then
      status=1
    fi
  fi
  if [ "$status" -eq 0 ] && ! grep -Fqx -- "$line" "$path" 2>/dev/null \
    && ! printf '%s\n' "$line" >> "$path"; then
    status=1
  fi
  fm_lock_release "$lock"
  return "$status"
}

# Publish one parent-facing line from <home>. See the return codes above.
fm_parent_channel_report() {  # <home> <state> <line>
  local home=$1 state=$2 line=$3 destination rc=0
  destination=$(fm_parent_channel_destination "$home" "$state") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_parent_channel_append_once "$state" "$destination" "$line" || return 4
}
