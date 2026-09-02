#!/usr/bin/env bash
# fm-parent-mirror-lib.sh - deterministic mirror of a secondmate's child ledgers
# onto its parent channel.
#
# docs/secondmate-parent-channel.md owns the design and the delivery rule this
# library implements: the machinery reports facts, the mate reports judgement.
# Inside a secondmate home every captain-relevant event a direct child records
# in its append-only state/<child>.status ledger is copied onto the parent
# channel (bin/fm-parent-channel-lib.sh) by this sweep, so a child's PR-ready,
# terminal, failed, or long-open decision line reaches the parent whether or
# not the mate model ever appends a line of its own. A main home is a silent
# no-op: it has no parent channel.
#
# Per-child durable record: state/parent-mirror/<child>.record, key=value:
#   schema=fm-parent-mirror.v1
#   offset=<bytes of the ledger already examined>
#   ident=<ledger file identity the offset belongs to>
#   incarnation=<spawn generation the record last saw>
#   terminal_line=<the standing failed line, when the ledger ends in one>
#   terminal_offset=<byte offset identifying that failed event>
#   terminal_first_seen=<epoch that line was first seen standing>
#   terminal_reported=0|1
#   tail=0|1          (1: captured bytes remain past the last complete line)
#   orphan=0|1        (1: the child's record is gone but delivery is still owed)
#   context_pr=<recorded canonical PR URL>
#   context_mode=<recorded delivery mode>
#   context_yolo=<recorded merge posture>
#   context_report=0|1
#   line_count=<whole ledger lines through offset>
#   open=<key>|<first-seen-epoch>|<mirrored 0|1>|<origin-line>|<verb>|<note>
# The record is rewritten atomically; a changed ledger identity or a shrunk
# ledger resets the offset to 0, an incarnation change marks the prior
# generation's standing failure handled while a later failed line starts a new
# clock, and exact-line deduplication on the channel keeps a re-examined line
# from being delivered twice. A record whose child
# record is gone is an orphan and is swept until it is delivered or its ledger
# disappears.
#
# What is mirrored, and when:
#   - a done line, or a legacy free-text captain-relevant line, immediately:
#       done [key=mirror-<child-length>-<child>-l<offset>]: mirror: child=<child> <note> [pr=<url>] [report=data/<child>/report.md] [mode=<mode>] [yolo=<posture>]
#   - a failed line, once it has stood as the ledger's last line for
#     FM_PARENT_MIRROR_OPEN_SECS (default 600, valid 60..86400), or immediately
#     when the child has retired and no first responder remains:
#       failed [key=mirror-<child-length>-<child>-l<offset>]: mirror: child=<child> <note> (unhandled past <threshold>s)
#   - a needs-decision or blocked decision, once it has stayed open in the
#     child's fold (bin/fm-classify-lib.sh's status_open_decisions) for that
#     same threshold without a resolution or captain-held transfer:
#       <verb> [key=mirror-<child-length>-<child>-<key>]: mirror: child=<child> decision <key> (opened at line <n>) open past <threshold>s without an answer or a captain hold: <note>
#     A retiring or orphaned child's still-open decision is raised immediately,
#     because its first-responder window has ended. Its close, when the child's
#     fold no longer holds the key, is:
#       resolved [key=mirror-<child-length>-<child>-<key>]: mirror: child=<child> decision <key> (opened at line <n>) closed
#     An opening is identified by its key and the ledger line that opened it,
#     so a key re-opened after a close is a new delivery even with the same
#     note, while the exact-line deduplication still holds for one opening.
#   - a decision line the fold cannot track (invalid or reserved key) is
#     delivered immediately under the done verb with an explicit note, because
#     an untrackable open must never open a parent decision nothing can close.
# The threshold is what keeps the mate the first responder: a decision it
# answers, a blocker it clears, or a failure it relaunches inside the window
# is never raised to the parent, and one it leaves standing is. Line text is
# deterministic for one event so a replayed sweep after a lost record cannot
# deliver it twice.
#
# Ordering and safety: each child is examined under its own meta lock, the
# same lock teardown and relaunch hold, so a record is never read while it is
# being replaced; the *_locked entry points are for callers that already hold
# that meta lock and take no other lock, so the lock order is always meta lock
# first and a teardown can never wait on a sweep. A sweep serializes with other
# sweeps through state/.parent-mirror.lock, and every wait is bounded: a child
# whose lock is busy, or a sweep whose lock is busy, is simply left for the
# next poll, so the watcher's beacon is never held hostage by a long teardown.
# Only whole lines are examined, so a line still being appended is left for
# the next sweep. Nothing here reads a pane, calls a harness, a forge, or
# bin/fm-crew-state.sh. Every examination runs in its own subshell, so a
# caller under set -e is never aborted by the sweep's own bookkeeping.
#
# Return codes for the sweep entry points: 0 delivered or nothing to deliver,
# 2 unusable identity marker, 3 unreadable parent binding, 4 an append or
# record write failed (the record keeps the undelivered position for the next
# sweep), and 5 a targeted sweep deferred by lock contention. Every non-zero outcome is also queued once per unhandled episode as
# a durable check wake in this home, and printed on stdout only when newly
# queued, so an unreportable home is loud rather than quietly silent and a
# standing problem does not wake the mate on every poll.
#
# Sourced by bin/fm-parent-mirror.sh, bin/fm-pr-check.sh, bin/fm-teardown.sh,
# bin/fm-inactive-reconcile.sh, and tests. No side effects on source.

_FM_PARENT_MIRROR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$_FM_PARENT_MIRROR_LIB_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$_FM_PARENT_MIRROR_LIB_DIR/fm-wake-lib.sh"
_fm_wake_require_classify
_fm_wake_require_timeout

FM_PARENT_MIRROR_SCHEMA='fm-parent-mirror.v1'
FM_PARENT_MIRROR_OPEN_SECS_DEFAULT=600
# Bounded lock waits: a busy child or sweep is retried on the next poll.
FM_PARENT_MIRROR_LOCK_WAIT_SECS=${FM_PARENT_MIRROR_LOCK_WAIT_SECS:-3}

fm_parent_mirror_dir() {  # <state>
  printf '%s/parent-mirror\n' "$1"
}

fm_parent_mirror_record_path() {  # <state> <child>
  printf '%s/parent-mirror/%s.record\n' "$1" "$2"
}

fm_parent_mirror_lock_path() {  # <state>
  printf '%s/.parent-mirror.lock\n' "$1"
}

_fm_parent_mirror_key() {  # <child> <suffix>
  printf 'mirror-%s-%s-%s' "${#1}" "$1" "$2"
}

_fm_parent_mirror_now() {
  case "${FM_PARENT_MIRROR_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_PARENT_MIRROR_NOW" ;;
  esac
}

# The open threshold, validated on every call so a bad override is loud.
fm_parent_mirror_open_secs() {
  local secs=${FM_PARENT_MIRROR_OPEN_SECS:-$FM_PARENT_MIRROR_OPEN_SECS_DEFAULT}
  case "$secs" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$secs" -ge 60 ] && [ "$secs" -le 86400 ] || return 1
  printf '%s\n' "$secs"
}

_fm_parent_mirror_meta_field() {  # <meta> <key>
  [ -n "$1" ] && [ -f "$1" ] && [ ! -L "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

_fm_parent_mirror_record_field() {  # <record> <key>
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

_fm_parent_mirror_record_open_lines() {  # <record>
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  grep '^open=' "$1" 2>/dev/null | cut -d= -f2- || true
}

# 0 when the child's ledger already states its own outcome: it ends in a
# terminal captain verb. That evidence belongs to this mirror, so the
# current-state inactive-outcome scan yields it (bin/fm-inactive-reconcile.sh).
fm_parent_mirror_owns_ledger() {  # <state> <child>
  local state=$1 child=$2 status size captured prefix complete_size=0 line last rc=1
  local LC_ALL=C
  status="$state/$child.status"
  [ -f "$status" ] && [ ! -L "$status" ] || return 1
  size=$(_fm_status_file_size "$status") || return 1
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  captured=$(mktemp "$state/.parent-mirror-owns.XXXXXX") || return 1
  prefix=$(mktemp "$state/.parent-mirror-prefix.XXXXXX") || { rm -f "$captured"; return 1; }
  if _fm_status_read_span "$status" 0 "$size" > "$captured" 2>/dev/null; then
    while IFS= read -r line; do
      complete_size=$((complete_size + ${#line} + 1))
    done < "$captured"
    if _fm_status_read_span "$captured" 0 "$complete_size" > "$prefix" 2>/dev/null; then
      last=$(last_status_line "$prefix")
      status_is_terminal_verb "$last" && rc=0
    fi
  fi
  rm -f "$captured" "$prefix"
  return "$rc"
}

# Exact-key lookups over the TAB-separated fold and the |-separated open set.
_fm_parent_mirror_fold_has() {  # <fold> <key>
  local line
  while IFS= read -r line; do
    case "$line" in "$2"$'\t'*) return 0 ;; esac
  done <<EOF
$1
EOF
  return 1
}

_fm_parent_mirror_fold_entry() {  # <fold> <key> -> "<verb>\t<note>"
  local line
  while IFS= read -r line; do
    case "$line" in "$2"$'\t'*) printf '%s' "${line#*$'\t'}"; return 0 ;; esac
  done <<EOF
$1
EOF
  return 1
}

_fm_parent_mirror_open_entry() {  # <open-lines> <key> -> "<key>|<seen>|<mirrored>|<origin>"
  local line
  while IFS= read -r line; do
    case "$line" in "$2|"*) printf '%s' "$line"; return 0 ;; esac
  done <<EOF
$1
EOF
  return 1
}

_fm_parent_mirror_origin_of() {  # <origins> <key> -> opening line number
  local line
  while IFS= read -r line; do
    case "$line" in "$2"$'\t'*) printf '%s' "${line#*$'\t'}"; return 0 ;; esac
  done <<EOF
$1
EOF
  return 1
}

# Queue one durable check wake for a delivery problem, keyed so it is not
# requeued while still unhandled, and print it on stdout only when it was
# newly queued: stdout is what the watcher turns into a wake, so a standing
# problem is loud exactly once per unhandled episode rather than every poll.
_fm_parent_mirror_diagnostic() {  # <rc>
  local rc=$1 key payload append_rc=0
  case "$rc" in
    2) key='parent-mirror-diagnostic:channel'
       payload='parent channel unavailable: invalid .fm-secondmate-home marker; child outcomes are not reaching the parent' ;;
    3) key='parent-mirror-diagnostic:channel'
       payload='parent channel unavailable: missing or unreadable parent binding .fm-secondmate-parent; child outcomes are not reaching the parent' ;;
    4) key='parent-mirror-diagnostic:delivery'
       payload='parent channel delivery failed; a child outcome is retained for retry but has not reached the parent' ;;
    *) return 0 ;;
  esac
  fm_wake_append_if_key_absent_bounded check "$key" "check: $payload" \
    "$FM_PARENT_MIRROR_LOCK_WAIT_SECS" >/dev/null 2>&1 || append_rc=$?
  case "$append_rc" in
    0) printf 'actionable: %s\n' "$payload" ;;
    3) ;;
    *) printf '%s\n' "$payload" >&2 ;;
  esac
}

_fm_parent_mirror_dir_ready() {  # <dir>
  local dir=$1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ]
    return
  fi
  mkdir -p "$dir" || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ]
}

# Rewrite <record> atomically from the fields the caller assembled.
_fm_parent_mirror_record_write() {  # <record> <offset> <ident> <incarnation> <terminal-line> <terminal-offset> <terminal-first-seen> <terminal-reported> <tail> <orphan> <open-lines> [<context-pr> <context-mode> <context-yolo> <context-report> <line-count>]
  local record=$1 offset=$2 ident=$3 incarnation=$4 terminal_line=$5 terminal_offset=$6
  local terminal_first_seen=$7 terminal_reported=$8 tail=$9 orphan=${10} open_lines=${11}
  local context_pr=${12:-} context_mode=${13:-} context_yolo=${14:-} context_report=${15:-0} line_count=${16:-0} dir tmp entry
  dir=$(dirname "$record")
  _fm_parent_mirror_dir_ready "$dir" || return 1
  tmp=$(mktemp "$dir/.record.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_PARENT_MIRROR_SCHEMA"
    printf 'offset=%s\n' "$offset"
    printf 'ident=%s\n' "$ident"
    printf 'incarnation=%s\n' "$incarnation"
    printf 'terminal_line=%s\n' "$terminal_line"
    printf 'terminal_offset=%s\n' "$terminal_offset"
    printf 'terminal_first_seen=%s\n' "$terminal_first_seen"
    printf 'terminal_reported=%s\n' "$terminal_reported"
    printf 'tail=%s\n' "$tail"
    printf 'orphan=%s\n' "$orphan"
    printf 'context_pr=%s\n' "$context_pr"
    printf 'context_mode=%s\n' "$context_mode"
    printf 'context_yolo=%s\n' "$context_yolo"
    printf 'context_report=%s\n' "$context_report"
    printf 'line_count=%s\n' "$line_count"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      printf 'open=%s\n' "$entry"
    done <<EOF
$open_lines
EOF
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}

# The context suffix every mirrored line carries: the child's recorded PR,
# its scout report when one exists, and its delivery mode and merge posture.
_fm_parent_mirror_context() {  # <child> <pr> <mode> <yolo> <report-0-or-1>
  local child=$1 pr=$2 mode=$3 yolo=$4 report=$5 out=''
  [ -z "$pr" ] || out="$out pr=$(fm_parent_channel_clean_note "$pr")"
  [ "$report" != 1 ] || out="$out report=data/$child/report.md"
  [ -z "$mode" ] || out="$out mode=$(fm_parent_channel_clean_note "$mode")"
  [ -z "$yolo" ] || out="$out yolo=$(fm_parent_channel_clean_note "$yolo")"
  printf '%s' "$out"
}

_fm_parent_mirror_publish() {  # <line>
  fm_parent_channel_report "$FM_HOME" "$STATE" "$1"
}

# Examine one child ledger and deliver what it owes. <meta-or-empty> is the
# child's record when it still exists. Returns the codes documented above.
# Runs in the caller's shell; the entry points below wrap it in a subshell.
_fm_parent_mirror_child() {  # <child> <meta-or-empty> <orphan 0|1> [<deliver-now 0|1>]
  local child=$1 meta=$2 orphan=$3 deliver_now=${4:-0} status record now open_secs
  local size ident offset rec_ident incarnation rec_incarnation complete_size=0 scan_start=0 span_complete=0
  local terminal_line terminal_offset terminal_first_seen terminal_reported tail=0 captured='' prefix='' dir
  local open_lines='' next_open='' close_failed='' reset_open='' fold='' rc=0 rec_line_count=0 line_count=0 processed_lines=0
  local chunk line verb note key mirror_key line_offset line_start committed context last last_verb last_offset
  local entry entry_key entry_seen entry_mirrored entry_origin entry_verb entry_note origins origin fold_verb fold_note age timing
  local line_number resolve held after was_open
  local context_pr context_mode context_yolo context_report report data
  local LC_ALL=C
  status="$STATE/$child.status"
  record=$(fm_parent_mirror_record_path "$STATE" "$child")
  dir=$(dirname "$record")
  _fm_parent_mirror_dir_ready "$dir" || return 4
  now=$(_fm_parent_mirror_now)
  open_secs=$(fm_parent_mirror_open_secs) || {
    printf 'FM_PARENT_MIRROR_OPEN_SECS must be a whole number from 60 to 86400\n' >&2
    return 4
  }
  if [ ! -e "$status" ]; then
    [ "$orphan" -ne 1 ] || return 4
    return 0
  fi
  [ -f "$status" ] && [ ! -L "$status" ] || return 4
  ident=$(_fm_open_decisions_file_ident "$status") || return 4
  size=$(_fm_status_file_size "$status") || return 4
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 4 ;; esac

  offset=$(_fm_parent_mirror_record_field "$record" offset)
  rec_ident=$(_fm_parent_mirror_record_field "$record" ident)
  rec_incarnation=$(_fm_parent_mirror_record_field "$record" incarnation)
  terminal_line=$(_fm_parent_mirror_record_field "$record" terminal_line)
  terminal_offset=$(_fm_parent_mirror_record_field "$record" terminal_offset)
  terminal_first_seen=$(_fm_parent_mirror_record_field "$record" terminal_first_seen)
  terminal_reported=$(_fm_parent_mirror_record_field "$record" terminal_reported)
  open_lines=$(_fm_parent_mirror_record_open_lines "$record")
  rec_line_count=$(_fm_parent_mirror_record_field "$record" line_count)
  case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
  case "$rec_line_count" in ''|*[!0-9]*) rec_line_count=0; offset=0; open_lines='' ;; esac
  case "$terminal_reported" in 1) ;; *) terminal_reported=0 ;; esac
  if [ "$rec_ident" != "$ident" ] || [ "$offset" -gt "$size" ]; then
    reset_open=''
    while IFS='|' read -r entry_key entry_seen entry_mirrored entry_origin entry_verb entry_note; do
      [ -n "$entry_key" ] && [ "$entry_mirrored" = 1 ] || continue
      reset_open="${reset_open}${entry_key}|${entry_seen}|${entry_mirrored}|${entry_origin}|closed|${entry_note}"$'\n'
    done <<EOF
$open_lines
EOF
    open_lines=$reset_open
    terminal_line=''
    terminal_offset=''
    terminal_first_seen=''
    terminal_reported=0
    offset=0
    rec_line_count=0
  fi
  scan_start=$offset
  line_count=$rec_line_count

  # Capture only bytes not represented by the durable cursor, then materialize
  # its newline-terminated prefix for incremental classification.
  captured=$(mktemp "$dir/.capture.XXXXXX") || return 4
  prefix=$(mktemp "$dir/.prefix.XXXXXX") || { rm -f "$captured"; return 4; }
  if ! _fm_status_read_span "$status" "$scan_start" "$((size - scan_start))" > "$captured" 2>/dev/null; then
    rm -f "$captured" "$prefix"
    return 4
  fi
  while IFS= read -r line; do
    span_complete=$((span_complete + ${#line} + 1))
  done < "$captured"
  if ! _fm_status_read_span "$captured" 0 "$span_complete" > "$prefix" 2>/dev/null; then
    rm -f "$captured" "$prefix"
    return 4
  fi
  rm -f "$captured"
  complete_size=$((scan_start + span_complete))
  [ "$complete_size" -eq "$size" ] || tail=1
  incarnation=$(_fm_parent_mirror_meta_field "$meta" spawn_gen)
  [ -n "$incarnation" ] || incarnation=$rec_incarnation
  if [ -n "$rec_incarnation" ] && [ "$incarnation" != "$rec_incarnation" ] \
    && [ "$rec_ident" = "$ident" ]; then
    terminal_reported=1
  fi

  context_pr=$(_fm_parent_mirror_record_field "$record" context_pr)
  context_mode=$(_fm_parent_mirror_record_field "$record" context_mode)
  context_yolo=$(_fm_parent_mirror_record_field "$record" context_yolo)
  context_report=$(_fm_parent_mirror_record_field "$record" context_report)
  case "$context_report" in 1) ;; *) context_report=0 ;; esac
  if [ -n "$meta" ] && [ -f "$meta" ] && [ ! -L "$meta" ]; then
    context_pr=$(_fm_parent_mirror_meta_field "$meta" pr)
    context_mode=$(_fm_parent_mirror_meta_field "$meta" mode)
    context_yolo=$(_fm_parent_mirror_meta_field "$meta" yolo)
    data="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
    report="$data/$child/report.md"
    if [ -f "$report" ] && [ ! -L "$report" ]; then context_report=1; else context_report=0; fi
  fi
  context=$(_fm_parent_mirror_context "$child" "$context_pr" "$context_mode" "$context_yolo" "$context_report")
  committed=$offset

  # 1. New whole lines since the cursor: done-class lines deliver now.
  if [ "$offset" -lt "$complete_size" ]; then
    chunk=$(mktemp "$dir/.span.XXXXXX") || { rm -f "$prefix"; return 4; }
    if ! _fm_status_read_span "$prefix" 0 "$span_complete" > "$chunk" 2>/dev/null; then
      rm -f "$chunk" "$prefix"
      return 4
    fi
    line_offset=$offset
    while IFS= read -r line; do
      line_start=$line_offset
      line_offset=$((line_offset + ${#line} + 1))
      case "$line" in *[![:space:]]*) ;; *) committed=$line_offset; processed_lines=$((processed_lines + 1)); continue ;; esac
      if ! status_is_captain_relevant "$line"; then
        committed=$line_offset
        processed_lines=$((processed_lines + 1))
        continue
      fi
      verb=$(status_line_verb "$line")
      note=$(fm_parent_channel_clean_note "$(status_line_note "$line")")
      case "$verb" in
        failed)
          committed=$line_offset
          processed_lines=$((processed_lines + 1))
          continue
          ;;
        needs-decision|blocked)
          if key=$(_fm_decision_key "$line") \
            && _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")"; then
            committed=$line_offset
            processed_lines=$((processed_lines + 1))
            continue
          fi
          mirror_key=$(_fm_parent_mirror_key "$child" "l$line_start")
          _fm_parent_mirror_publish \
            "done [key=$mirror_key]: mirror: child=$child untracked $verb line: $note$context" \
            || { rc=$?; break; }
          ;;
        done)
          mirror_key=$(_fm_parent_mirror_key "$child" "l$line_start")
          _fm_parent_mirror_publish \
            "done [key=$mirror_key]: mirror: child=$child $note$context" \
            || { rc=$?; break; }
          ;;
        *)
          mirror_key=$(_fm_parent_mirror_key "$child" "l$line_start")
          _fm_parent_mirror_publish \
            "done [key=$mirror_key]: mirror: child=$child $(fm_parent_channel_clean_note "$line")$context" \
            || { rc=$?; break; }
          ;;
      esac
      committed=$line_offset
      processed_lines=$((processed_lines + 1))
    done < "$chunk"
    rm -f "$chunk"
  fi

  line_count=$((rec_line_count + processed_lines))

  # 2. A standing failed line: deliver once it has stood past the threshold.
  if [ "$rc" -eq 0 ]; then
    last=$terminal_line
    last_offset=$terminal_offset
    line_offset=$scan_start
    line_number=0
    while IFS= read -r line && [ "$line_number" -lt "$processed_lines" ]; do
      line_start=$line_offset
      line_offset=$((line_offset + ${#line} + 1))
      line_number=$((line_number + 1))
      case "$line" in
        *[![:space:]]*) last=$line; last_offset=$line_start ;;
      esac
    done < "$prefix"
    last_verb=$(status_line_verb "$last")
    if [ "$last_verb" = failed ]; then
      if [ "$terminal_line" != "$last" ] || [ "$terminal_offset" != "$last_offset" ]; then
        terminal_line=$last
        terminal_offset=$last_offset
        terminal_first_seen=$now
        terminal_reported=0
      fi
      case "$terminal_first_seen" in ''|*[!0-9]*) terminal_first_seen=$now ;; esac
      age=$((now - terminal_first_seen))
      if [ "$terminal_reported" -eq 0 ] \
        && { [ "$deliver_now" -eq 1 ] || [ "$age" -ge "$open_secs" ]; }; then
        note=$(fm_parent_channel_clean_note "$(status_line_note "$last")")
        if [ "$deliver_now" -eq 1 ]; then timing='unhandled when child retired'; else timing="unhandled past ${open_secs}s"; fi
        mirror_key=$(_fm_parent_mirror_key "$child" "l$terminal_offset")
        if _fm_parent_mirror_publish \
          "failed [key=$mirror_key]: mirror: child=$child $note ($timing)$context"; then
          terminal_reported=1
        else
          rc=4
        fi
      fi
    else
      terminal_line=''
      terminal_offset=''
      terminal_first_seen=''
      terminal_reported=0
    fi
  fi

  # 3. Fold only the new committed lines onto the compact durable open set.
  origins=''
  while IFS='|' read -r entry_key entry_seen entry_mirrored entry_origin entry_verb entry_note; do
    [ -n "$entry_key" ] || continue
    if [ "$entry_verb" != closed ]; then
      [ -n "$fold" ] && fold="${fold}"$'\n'
      fold="${fold}${entry_key}"$'\t'"${entry_verb}"$'\t'"${entry_note}"
      [ -n "$origins" ] && origins="${origins}"$'\n'
      origins="${origins}${entry_key}"$'\t'"${entry_origin}"
    fi
  done <<EOF
$open_lines
EOF
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  line_number=$rec_line_count
  processed_lines=0
  while IFS= read -r line && [ "$processed_lines" -lt "$((line_count - rec_line_count))" ]; do
    processed_lines=$((processed_lines + 1))
    line_number=$((line_number + 1))
    was_open=0
    if key=$(_fm_decision_key "$line") \
      && _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")"; then
      _fm_open_set_has "$fold" "$key" && was_open=1
    fi
    after=$(_fm_decision_fold_line "$fold" "$line" "$resolve" "$held")
    if key=$(_fm_decision_key "$line") \
      && _fm_decision_key_transition_allowed "$key" "$(status_line_note "$line")"; then
      verb=$(status_line_verb "$line")
      note=$(status_line_note "$line")
      case "$verb" in
        needs-decision|blocked)
          if [ "$was_open" -eq 0 ] && _fm_open_set_has "$after" "$key" \
            && [ "$(_fm_open_set_verb "$after" "$key")" = "$verb" ]; then
            origins=$(_fm_decision_origin_drop "$origins" "$key")
            [ -n "$origins" ] && origins="${origins}"$'\n'
            origins="${origins}${key}"$'\t'"${line_number}"
          fi
          ;;
        "$resolve"|"$held")
          _fm_open_set_has "$after" "$key" || origins=$(_fm_decision_origin_drop "$origins" "$key")
          ;;
      esac
    fi
    fold=$after
  done < "$prefix"

  next_open=''
  close_failed=''
  while IFS='|' read -r entry_key entry_seen entry_mirrored entry_origin entry_verb entry_note; do
    [ -n "$entry_key" ] || continue
    origin=$(_fm_parent_mirror_origin_of "$origins" "$entry_key") || origin=''
    if [ "$entry_verb" != closed ] \
      && _fm_parent_mirror_fold_has "$fold" "$entry_key" && [ "$origin" = "$entry_origin" ]; then
      next_open="${next_open}${entry_key}|${entry_seen}|${entry_mirrored}|${entry_origin}|${entry_verb}|${entry_note}"$'\n'
      continue
    fi
    if [ "$entry_mirrored" = 1 ]; then
      if [ "$rc" -ne 0 ]; then
        close_failed="${close_failed}${entry_key}|${entry_seen}|${entry_mirrored}|${entry_origin}|closed|${entry_note}"$'\n'
      else
        mirror_key=$(_fm_parent_mirror_key "$child" "$entry_key")
        if ! _fm_parent_mirror_publish \
          "resolved [key=$mirror_key]: mirror: child=$child decision $entry_key (opened at line $entry_origin) closed"; then
          rc=4
          close_failed="${close_failed}${entry_key}|${entry_seen}|${entry_mirrored}|${entry_origin}|closed|${entry_note}"$'\n'
        fi
      fi
    fi
  done <<EOF
$open_lines
EOF
  open_lines=$next_open
  next_open=$close_failed
  while IFS=$'\t' read -r key fold_verb fold_note; do
    [ -n "$key" ] || continue
    origin=$(_fm_parent_mirror_origin_of "$origins" "$key") || origin=0
    entry=$(_fm_parent_mirror_open_entry "$open_lines" "$key") || entry="$key|$now|0|$origin|$fold_verb|$fold_note"
    IFS='|' read -r entry_key entry_seen entry_mirrored entry_origin entry_verb entry_note <<EOF
$entry
EOF
    case "$entry_seen" in ''|*[!0-9]*) entry_seen=$now ;; esac
    [ -n "$entry_origin" ] || entry_origin=$origin
    if [ "$rc" -eq 0 ] && [ "$entry_mirrored" != 1 ]; then
      age=$((now - entry_seen))
      if [ "$deliver_now" -eq 1 ] || [ "$age" -ge "$open_secs" ]; then
        case "$fold_verb" in
          needs-decision|blocked)
            if [ "$deliver_now" -eq 1 ]; then timing='open when child retired'; else timing="open past ${open_secs}s"; fi
            mirror_key=$(_fm_parent_mirror_key "$child" "$key")
            if _fm_parent_mirror_publish \
              "$fold_verb [key=$mirror_key]: mirror: child=$child decision $key (opened at line $entry_origin) $timing without an answer or a captain hold: $(fm_parent_channel_clean_note "$fold_note")$context"; then
              entry_mirrored=1
            else
              rc=4
            fi
            ;;
        esac
      fi
    fi
    next_open="${next_open}${key}|${entry_seen}|${entry_mirrored}|${entry_origin}|${fold_verb}|${fold_note}"$'\n'
  done <<EOF
$fold
EOF
  open_lines=$next_open

  rm -f "$prefix"
  _fm_parent_mirror_record_write "$record" "$committed" "$ident" "$incarnation" \
    "$terminal_line" "$terminal_offset" "$terminal_first_seen" "$terminal_reported" \
    "$tail" "$orphan" "$open_lines" "$context_pr" "$context_mode" "$context_yolo" "$context_report" "$line_count" || return 4
  return "$rc"
}

# Examine one child under its meta lock. A record without a child record is
# an orphan whose delivery is still owed.
fm_parent_mirror_sweep_child() {  # <child> [<report-contention 0|1>]
  local child=$1 report_contention=${2:-0} meta lock rc=0 record
  meta="$STATE/$child.meta"
  record=$(fm_parent_mirror_record_path "$STATE" "$child")
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    [ "$(_fm_parent_mirror_meta_field "$meta" kind)" != secondmate ] || return 0
    lock=$(fm_meta_lock_path "$meta") || return 4
    # A busy child (teardown or relaunch holds its record) is left for the
    # next poll rather than waited on; nothing is lost, the ledger stays.
    if ! fm_lock_acquire_wait_bounded "$lock" "$FM_PARENT_MIRROR_LOCK_WAIT_SECS"; then
      [ "$report_contention" -eq 1 ] && return 5
      return 0
    fi
    ( set +e; _fm_parent_mirror_child "$child" "$meta" 0 ) || rc=$?
    fm_lock_release "$lock"
    return "$rc"
  fi
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  ( set +e; _fm_parent_mirror_child "$child" '' 1 1 ) || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(_fm_parent_mirror_record_field "$record" tail)" != 1 ]; then
    if status_retire_presentation_task "$STATE" "$child" "$FM_PARENT_MIRROR_LOCK_WAIT_SECS"; then
      rm -f "$record"
    else
      rc=4
    fi
  fi
  return "$rc"
}

# Same as above for a caller that already holds the child's meta lock.
fm_parent_mirror_sweep_child_locked() {  # <child> [<deliver-now 0|1>]
  local child=$1 deliver_now=${2:-0} meta rc=0
  meta="$STATE/$child.meta"
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    [ "$(_fm_parent_mirror_meta_field "$meta" kind)" != secondmate ] || return 0
    ( set +e; _fm_parent_mirror_child "$child" "$meta" 0 "$deliver_now" ) || rc=$?
    return "$rc"
  fi
  ( set +e; _fm_parent_mirror_child "$child" '' 1 1 ) || rc=$?
  return "$rc"
}

# Resolve the channel once for a sweep; a main home returns 1 silently and an
# unresolvable channel is reported and returned as 2 or 3.
_fm_parent_mirror_channel_ready() {
  local rc=0
  fm_parent_channel_destination "$FM_HOME" "$STATE" >/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      _fm_parent_mirror_diagnostic "$rc"
      return "$rc"
      ;;
  esac
}

# Sweep every direct child and every orphan record under the sweep lock.
# With <child>, sweep only that child. A main home returns 0 silently.
fm_parent_mirror_sweep() {  # [<child>]
  local only=${1:-} lock rc=0 child_rc meta child record
  _fm_parent_mirror_channel_ready || { rc=$?; [ "$rc" -eq 1 ] && return 0; return "$rc"; }
  lock=$(fm_parent_mirror_lock_path "$STATE")
  # Another sweep is already delivering; this poll has nothing to add.
  if ! fm_lock_acquire_wait_bounded "$lock" "$FM_PARENT_MIRROR_LOCK_WAIT_SECS"; then
    [ -n "$only" ] && return 5
    return 0
  fi
  if [ -n "$only" ]; then
    fm_parent_mirror_sweep_child "$only" 1 || rc=$?
  else
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      child=$(basename "$meta" .meta)
      _fm_parent_channel_id_valid "$child" || continue
      child_rc=0
      fm_parent_mirror_sweep_child "$child" || child_rc=$?
      [ "$child_rc" -eq 0 ] || rc=$child_rc
    done
    for record in "$(fm_parent_mirror_dir "$STATE")"/*.record; do
      [ -f "$record" ] || continue
      child=$(basename "$record" .record)
      _fm_parent_channel_id_valid "$child" || continue
      [ -f "$STATE/$child.meta" ] && continue
      child_rc=0
      fm_parent_mirror_sweep_child "$child" || child_rc=$?
      [ "$child_rc" -eq 0 ] || rc=$child_rc
    done
  fi
  fm_lock_release "$lock"
  [ "$rc" -eq 0 ] || _fm_parent_mirror_diagnostic "$rc"
  return "$rc"
}

fm_parent_mirror_orphan_durable() {  # <child>
  local child=$1 dir record
  _fm_parent_channel_id_valid "$child" || return 1
  dir=$(fm_parent_mirror_dir "$STATE")
  record=$(fm_parent_mirror_record_path "$STATE" "$child")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  [ "$(_fm_parent_mirror_record_field "$record" schema)" = "$FM_PARENT_MIRROR_SCHEMA" ] || return 1
  [ "$(_fm_parent_mirror_record_field "$record" orphan)" = 1 ]
}

# Final sweep for a child that is leaving the home, then retire its record.
# The caller holds the child's meta lock, which is the only lock this path
# takes. When the final sweep cannot deliver for any reason, a record is kept
# (or created) as an orphan so later sweeps keep trying, because the ledger
# outlives the child's record.
fm_parent_mirror_retire_locked() {  # <child>
  local child=$1 record meta rc=0 context_pr context_mode context_yolo context_report report data
  record=$(fm_parent_mirror_record_path "$STATE" "$child")
  meta="$STATE/$child.meta"
  _fm_parent_mirror_channel_ready || { rc=$?; [ "$rc" -eq 1 ] && return 0; }
  if [ "$rc" -eq 0 ]; then
    fm_parent_mirror_sweep_child_locked "$child" 1 || rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ "$(_fm_parent_mirror_record_field "$record" tail)" != 1 ]; then
    rm -f "$record"
    return 0
  fi
  if [ -e "$STATE/$child.status" ]; then
    context_pr=$(_fm_parent_mirror_record_field "$record" context_pr)
    context_mode=$(_fm_parent_mirror_record_field "$record" context_mode)
    context_yolo=$(_fm_parent_mirror_record_field "$record" context_yolo)
    context_report=$(_fm_parent_mirror_record_field "$record" context_report)
    if [ -f "$meta" ] && [ ! -L "$meta" ]; then
      context_pr=$(_fm_parent_mirror_meta_field "$meta" pr)
      context_mode=$(_fm_parent_mirror_meta_field "$meta" mode)
      context_yolo=$(_fm_parent_mirror_meta_field "$meta" yolo)
      data="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
      report="$data/$child/report.md"
      if [ -f "$report" ] && [ ! -L "$report" ]; then context_report=1; else context_report=0; fi
    fi
    if ! _fm_parent_mirror_record_write "$record" \
      "$(_fm_parent_mirror_record_field "$record" offset)" \
      "$(_fm_parent_mirror_record_field "$record" ident)" \
      "$(_fm_parent_mirror_record_field "$record" incarnation)" \
      "$(_fm_parent_mirror_record_field "$record" terminal_line)" \
      "$(_fm_parent_mirror_record_field "$record" terminal_offset)" \
      "$(_fm_parent_mirror_record_field "$record" terminal_first_seen)" \
      "$(_fm_parent_mirror_record_field "$record" terminal_reported)" \
      "$(_fm_parent_mirror_record_field "$record" tail)" \
      1 \
      "$(_fm_parent_mirror_record_open_lines "$record")" \
      "$context_pr" "$context_mode" "$context_yolo" "$context_report" \
      "$(_fm_parent_mirror_record_field "$record" line_count)"; then
      [ "$rc" -ne 0 ] || rc=4
    fi
  fi
  return "$rc"
}
