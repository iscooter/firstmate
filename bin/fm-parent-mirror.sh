#!/usr/bin/env bash
# fm-parent-mirror.sh - mirror a secondmate's child ledgers onto its parent channel.
#
# Usage:
#   fm-parent-mirror.sh sweep [--child <id>]
#   fm-parent-mirror.sh owns-ledger <id>
#
# `sweep` examines every direct child ledger in this home (or one child) and
# delivers every captain-relevant event that has not reached the parent
# channel yet; bin/fm-parent-mirror-lib.sh owns what is mirrored, when, and
# the durable per-child record under state/parent-mirror/. In a main home it
# is a silent no-op. The watcher (bin/fm-watch.sh) runs it on every poll,
# bin/fm-pr-check.sh runs it for a child whose PR it just registered, and
# bin/fm-teardown.sh runs the same library in-process before a child's record
# is removed. Output is empty on a quiet sweep and one `actionable:` line per
# problem otherwise; the exit status is the library's return code.
#
# `owns-ledger` exits 0 when the child's ledger ends in a terminal captain
# verb, the evidence this mirror delivers on its own clock; the inactive
# outcome scan uses it to yield.
#
# Tunables (env): FM_PARENT_MIRROR_OPEN_SECS (default 600, valid 60..86400),
# the standing time after which a failed line, an open decision, or an open
# blocker in a child ledger is raised to the parent.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME STATE

# shellcheck source=bin/fm-parent-mirror-lib.sh
. "$SCRIPT_DIR/fm-parent-mirror-lib.sh"

usage() {
  sed -n '2,25{s/^# \{0,1\}//;p;}' "$0"
}

mode=${1:-}
case "$mode" in
  sweep)
    shift
    child=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --child)
          [ "$#" -ge 2 ] || { usage >&2; exit 2; }
          child=$2
          shift 2
          ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    if [ -n "$child" ] && ! _fm_parent_channel_id_valid "$child"; then
      printf 'error: invalid child id\n' >&2
      exit 2
    fi
    fm_parent_mirror_sweep "$child"
    ;;
  owns-ledger)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    _fm_parent_channel_id_valid "$2" || { printf 'error: invalid child id\n' >&2; exit 2; }
    fm_parent_mirror_owns_ledger "$STATE" "$2"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
