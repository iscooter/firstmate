#!/usr/bin/env bash
# tests/fm-composer-matrix-live-e2e.test.sh - the live composer-matrix guard
# (live-harness-optin family; task fm-composer-thin-adapter-refactor-r1).
#
# The shared composer classifier's shape catalogue (bin/fm-composer-lib.sh) is
# built entirely from vendor-rendered signals, so per
# .agents/skills/firstmate-coding-guidelines it must be proven against the
# REAL harnesses: a stub can only confirm the assumption already written into
# the stub. This guard launches every INSTALLED verified harness idle in an
# isolated tmux server and requires the real fm_tmux_composer_state to reach
# `empty`, failing loudly with the harness name and version. It also proves:
#   - the strict blank-row posture live: a plain shell pane with a blank
#     cursor row must classify unknown and defer injection;
#   - the zellij false-positive regression live (when zellij is installed): a
#     pane whose content changes for reasons unrelated to submission must NOT
#     report a delivered send, and a real claude-in-zellij `dump-screen
#     --ansi` capture must classify empty through the zellij thin adapter;
#   - the PRE-ENTER DELIVERY PROOF live (fm_composer_delivery_delta_verdict):
#     for every installed harness, a payload really typed into the real
#     composer must be ACCEPTED, and the same two captures with nothing typed
#     between them must be REFUSED. This is the tier that catches a vendor
#     release masking, reflowing, or scrolling typed input out of view - the
#     one genuinely new false-refusal class the delta proof introduces - and
#     it is checked on both capture fidelities so the deleted styled/plain
#     fork cannot quietly return.
#
# Run explicitly with FM_COMPOSER_MATRIX_LIVE=1. No prompt is ever submitted
# to any harness (the delivery proof gates Enter and this guard never sends
# it), so no model tokens are spent. An absent harness is reported explicitly
# and skipped; a run that verified nothing fails rather than passing
# vacuously. Refresh docs/verification/runtime-backends.md ("Composer
# classification matrix" and "Pre-Enter delivery proof") from this guard's
# output after any harness upgrade.
#
# Folder trust: harnesses are launched with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unreadable-composer state and correctly fails that harness's check.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_COMPOSER_MATRIX_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_COMPOSER_MATRIX_LIVE=1 to run the live composer-matrix guard"
  exit 0
fi

command -v tmux >/dev/null 2>&1 || { echo "not ok - FM_COMPOSER_MATRIX_LIVE=1 but tmux is not installed" >&2; exit 1; }

SOCKET="fm-cmx-live-$$"
SESSION="cmxlive"
ZELLIJ_SESSION="fm-cmx-live-zj-$$"
CHECKED=0
FAILED=0

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "${ZJ_BG:-}" ] || kill "$ZJ_BG" 2>/dev/null || true
  if command -v zellij >/dev/null 2>&1; then
    zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# The library under test, driven against the private socket through a PATH
# shim so its bare `tmux` calls stay isolated from any live fleet.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-cmx-live.XXXXXX")
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# The 152-character steer this guard types into every real composer. Long
# enough to wrap at any realistic pane width, and marked so it is obvious in a
# pane tail that it came from this guard and was never submitted.
DELTA_PAYLOAD='fm live delivery-proof probe: this text is typed once and never submitted, only captured either side of the write. END-OF-PROBE-MARKER-7Q4Z'

# check_harness_delta: capture, type, capture, and require the shared pre-Enter
# proof to ACCEPT - then require it to REFUSE the same pair with nothing typed,
# so a harness that simply always accepts cannot pass. Both capture fidelities
# are checked and must agree.
check_harness_delta() {  # <name> <version> <target>
  local name=$1 version=$2 target=$3
  local before_p before_a after_p after_a idle_p verdict_p verdict_a refuse
  before_p=$(tmux -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null)
  before_a=$(tmux -L "$SOCKET" capture-pane -p -e -t "$target" 2>/dev/null)
  # The refuse direction FIRST, while nothing has been typed: two captures of a
  # settled pane must never prove a delivery, however much the pane churns.
  sleep 1
  idle_p=$(tmux -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null)
  if refuse=$(fm_composer_delivery_delta_verdict "$before_p" "$idle_p" "$DELTA_PAYLOAD"); then
    FAILED=1
    printf 'not ok - %s (%s): the delivery proof accepted a pane nothing was typed into (verdict: %s)\n' \
      "$name" "$version" "$refuse" >&2
    return
  fi
  tmux -L "$SOCKET" send-keys -t "$target" -l "$DELTA_PAYLOAD" 2>/dev/null \
    || { FAILED=1; printf 'not ok - %s (%s): could not type the delivery-proof probe\n' "$name" "$version" >&2; return; }
  sleep 3
  after_p=$(tmux -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null)
  after_a=$(tmux -L "$SOCKET" capture-pane -p -e -t "$target" 2>/dev/null)
  verdict_p=$(fm_composer_delivery_delta_verdict "$before_p" "$after_p" "$DELTA_PAYLOAD") || true
  verdict_a=$(fm_composer_delivery_delta_verdict "$before_a" "$after_a" "$DELTA_PAYLOAD") || true
  if [ "$verdict_p" != accepted ] || [ "$verdict_a" != accepted ]; then
    printf '# %s pane tail at delivery-proof failure:\n' "$name" >&2
    printf '%s\n' "$after_p" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    FAILED=1
    printf 'not ok - %s (%s): a really-typed payload was not proven delivered (plain: %s; ansi: %s)\n' \
      "$name" "$version" "${verdict_p:-none}" "${verdict_a:-none}" >&2
    return
  fi
  CHECKED=$((CHECKED + 1))
  pass "$name ($version): pre-Enter delivery proof accepts a real typed payload and refuses an untyped pane, on both capture fidelities"
}

check_harness_idle_empty() {  # <name> <launch-cmd...>
  local name=$1 win="hx-$1" verdict='' i=0 budget=${FM_COMPOSER_MATRIX_LIVE_POLLS:-45} version dismissed=0 startup_screen
  shift
  version=$(harness_version "$1")
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" -- "$@" \
    || fail "$name ($version): could not launch in the isolated tmux server"
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && break
    i=$((i + 1))
    # A fresh harness may park on a vendor update-available modal (observed
    # live: codex 0.146.0 and opencode 1.14.46), which the strict classifier
    # correctly refuses to call a composer. Dismiss it once, mid-budget, with
    # a single Escape - the one key that submits nothing anywhere and is how
    # the audit declined the same prompts. Never Enter: on codex's dialog
    # Enter would RUN the upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      # Trust prompts also accept Escape, but there it exits the harness and
      # erases the actionable failure surface. Preserve those prompts; only
      # dismiss a non-trust startup modal.
      startup_screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$startup_screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  if [ "$verdict" != empty ]; then
    printf '# %s pane tail at failure:\n' "$name" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null \
      | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    FAILED=1
    printf 'not ok - %s (%s): idle composer never classified empty (last verdict: %s)\n' \
      "$name" "$version" "${verdict:-unreadable}" >&2
  else
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): real idle composer classifies empty"
  fi
  # The delivery proof reads no composer region, so it is exercised whatever
  # the classifier concluded above: a harness the shape catalogue cannot read
  # is exactly the case it has to keep steerable.
  check_harness_delta "$name" "$version" "$SESSION:$win"
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

# check_harness_delta_only: the delivery proof for a harness that is
# deliberately outside the cursor-anchored empty-composer matrix (cursor parks
# its terminal cursor outside the composer). The proof never reads a cursor, so
# this harness is covered here and nowhere else.
check_harness_delta_only() {  # <name> <launch-cmd...>
  local name=$1 win="hd-$1" version
  shift
  version=$(harness_version "$1")
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" -- "$@" \
    || fail "$name ($version): could not launch in the isolated tmux server"
  sleep "${FM_COMPOSER_MATRIX_LIVE_SETTLE:-16}"
  check_harness_delta "$name" "$version" "$SESSION:$win"
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

# --- 1. Every installed verified harness must reach a proven-empty composer --
for h in claude codex opencode pi pi-signed grok kimi muse; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_idle_empty "$h" "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

# Cursor is outside the empty-composer matrix (see the file header and
# docs/verification/runtime-backends.md), but it is NOT outside the delivery
# proof, which reads no cursor and no composer region.
if command -v cursor-agent >/dev/null 2>&1; then
  check_harness_delta_only cursor cursor-agent
else
  note "harness absent, not verified here: cursor (cursor-agent)"
fi

# --- 2. The strict blank-row posture, live ----------------------------------
# A plain shell pane parked on a blank line between two rules (the audit's
# sleep-pane counterexample): the permissive rule read this empty; strict must
# defer.
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n strictblank -c "$ROOT" \
  -- bash -c 'printf "────────────────────────\n\n"; printf "\033[A"; exec sleep 300'
sleep 1
verdict=$(fm_tmux_composer_state "$SESSION:strictblank")
if [ "$verdict" = unknown ]; then
  if fm_pane_input_pending "$SESSION:strictblank"; then
    CHECKED=$((CHECKED + 1))
    pass "strict posture live: a blank shell row classifies unknown and injection defers"
  else
    FAILED=1
    printf 'not ok - strict posture live: pane_input_pending did not defer on an unknown verdict\n' >&2
  fi
else
  FAILED=1
  printf 'not ok - strict posture live: blank shell row classified %s, expected unknown\n' "${verdict:-unreadable}" >&2
fi
tmux -L "$SOCKET" kill-window -t "$SESSION:strictblank" 2>/dev/null || true

# --- 3. zellij: real classifier + the false-positive regression -------------
if command -v zellij >/dev/null 2>&1; then
  zj_version=$(zellij --version 2>/dev/null | head -1)
  [ -n "$zj_version" ] || zj_version='version-unknown'
  export FM_ROOT_OVERRIDE="$ROOT"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source zellij 2>/dev/null \
    || fail "zellij ($zj_version): adapter source failed"

  zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
  zellij --session "$ZELLIJ_SESSION" options --default-shell bash >/dev/null 2>&1 &
  ZJ_BG=$!
  i=0
  while [ "$i" -lt 10 ] && ! fm_backend_zellij_session_exists "$ZELLIJ_SESSION"; do
    i=$((i + 1))
    sleep 0.5
  done
  fm_backend_zellij_session_exists "$ZELLIJ_SESSION" \
    || fail "zellij ($zj_version): probe session setup failed"
  panes=$(fm_backend_zellij_cli "$ZELLIJ_SESSION" action list-panes --json 2>/dev/null) \
    || fail "zellij ($zj_version): pane discovery command failed"
  pane_id=$(printf '%s' "$panes" | jq -r '.[]? | select(.is_plugin == false) | .id' 2>/dev/null | head -1)
  case "$pane_id" in
    ''|*[!0-9]*) fail "zellij ($zj_version): pane discovery returned no terminal pane" ;;
  esac
  target="$ZELLIJ_SESSION:$pane_id"

  fm_backend_zellij_send_literal "$target" 'while sleep 1; do date; done' \
    || fail "zellij ($zj_version): clock probe setup write failed"
  fm_backend_zellij_send_key "$target" Enter \
    || fail "zellij ($zj_version): clock probe setup submit failed"
  sleep 2
  probe='# audit-probe-never-submitted'
  fm_backend_zellij_send_literal "$target" "$probe" \
    || fail "zellij ($zj_version): false-positive probe write failed"
  sleep 0.5
  probe_capture=$(fm_backend_zellij_capture "$target" 40 2>/dev/null) \
    || fail "zellij ($zj_version): false-positive probe capture failed"
  case "$probe_capture" in
    *"$probe"*) ;;
    *) fail "zellij ($zj_version): false-positive probe text was not visible after typing" ;;
  esac
  verdict=$(fm_composer_submit_retry_core fm_backend_zellij_send_key fm_backend_zellij_composer_state \
    "$target" 2 0.5 2>/dev/null)
  case "$verdict" in
    pending|unknown)
      CHECKED=$((CHECKED + 1))
      pass "zellij ($zj_version): unrelated pane change never confirms delivery (verdict: $verdict)"
      ;;
    send-failed)
      FAILED=1
      printf 'not ok - zellij (%s): false-positive probe text was not typed (send-failed)\n' "$zj_version" >&2
      ;;
    *)
      FAILED=1
      printf 'not ok - zellij (%s): false-positive probe returned unexpected verdict %s (expected pending or unknown)\n' \
        "$zj_version" "${verdict:-none}" >&2
      ;;
  esac
  kill "$ZJ_BG" 2>/dev/null || true
  ZJ_BG=
  zellij delete-session --force "$ZELLIJ_SESSION" >/dev/null 2>&1 || true
else
  note "harness absent, not verified here: zellij (false-positive regression not exercised)"
fi

# --- refuse a vacuous pass ---------------------------------------------------
[ "$FAILED" -eq 0 ] || fail "live composer-matrix guard observed failures above"
[ "$CHECKED" -gt 0 ] || fail "live composer-matrix guard verified nothing (no harness installed?); refusing a vacuous pass"
pass "live composer-matrix guard verified $CHECKED live surface(s)"
