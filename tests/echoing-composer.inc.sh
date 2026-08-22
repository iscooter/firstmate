#!/usr/bin/env bash
# tests/echoing-composer.inc.sh - shared fake-pane composer echo.
#
# Sourced by fake `tmux` stubs that model an fm-send delivery. A real pane
# shows text typed with send-keys -l in the next capture; these helpers do the
# same, so the pre-Enter delta proof (bin/fm-composer-lib.sh,
# fm_composer_delivery_delta_verdict) can see the payload become newly present
# and accept the send.
#
# A stub that never echoes still fails closed, and that is the intended proof,
# not a fixture bug. Do not weaken it to make a silent stub pass.
#
# WHY THESE STILL DRAW A BOX. The pre-Enter proof does not care: it compares
# two captures, so a container proves nothing to it either way, and
# fm_test_write_shape_free_composer below exists to pin exactly that. The
# POST-Enter half of the bracket is a different proof and is still the
# shape-aware classifier, which has to read a typed pane as `pending` and an
# emptied one as `empty` to confirm a submit at all. Drawing a composer is
# therefore modelling a real pane for that half, not a shape assumption smuggled
# into the delivery proof.
#
# State files default to ${0}.typed and ${0}.entered (the fake binary's own
# path). Override with FM_FAKE_COMPOSER_TYPED / FM_FAKE_COMPOSER_ENTERED.

fm_test_write_composer() {
  local text=$1 width border i
  if [ -z "$text" ]; then
    # An empty composer must not keep a prompt glyph: `│ >  │` classifies as
    # unknown/pending and makes a real post-Enter empty read look unsubmitted.
    printf '╭────╮\n│    │\n╰────╯\n'
    return 0
  fi
  width=$((${#text} + 4))
  [ "$width" -ge 6 ] || width=6
  border=
  i=0
  while [ "$i" -lt "$width" ]; do
    border="${border}─"
    i=$((i + 1))
  done
  printf '╭%s╮\n│ > %s │\n╰%s╯\n' "$border" "$text" "$border"
}

# The same echo with no container at all. Only the pre-Enter delta proof can
# accept from this, which is the point: a stub that draws nothing recognisable
# still proves a healthy send end to end through fm-send.
fm_test_write_shape_free_composer() {
  printf '%s\n' "$1"
}

fm_test_composer_typed_path() {
  printf '%s\n' "${FM_FAKE_COMPOSER_TYPED:-${0}.typed}"
}

fm_test_composer_entered_path() {
  printf '%s\n' "${FM_FAKE_COMPOSER_ENTERED:-${0}.entered}"
}

fm_test_tmux_note_literal() {
  printf '%s' "$1" > "$(fm_test_composer_typed_path)"
  rm -f "$(fm_test_composer_entered_path)"
}

# One character off the composer tail, modelling the erase key the pre-Enter
# proof's verification envelope uses for a short payload (bin/fm-composer-lib.sh,
# fm_composer_typed_delivery_core). A stub that ignores this leaves the suffix
# in the composer and the proof refuses - which is the correct outcome for a
# pane that really did ignore the key, so a stub modelling a HEALTHY pane must
# call this from its erase-key branch.
fm_test_tmux_note_erase() {
  local typed cur
  typed=$(fm_test_composer_typed_path)
  [ -f "$typed" ] || return 0
  cur=$(cat "$typed")
  [ -n "$cur" ] || return 0
  printf '%s' "${cur:0:$((${#cur} - 1))}" > "$typed"
}

# What the composer held when Enter was pressed - which is what the agent
# actually receives, and therefore what a test asserting "the agent got exactly
# X" must read. It differs from the raw type log whenever a short payload was
# typed with a verification suffix that was erased again before Enter.
fm_test_composer_submitted_path() {
  printf '%s\n' "${FM_FAKE_COMPOSER_SUBMITTED:-${0}.submitted}"
}

fm_test_tmux_note_enter() {
  local typed
  typed=$(fm_test_composer_typed_path)
  if [ -f "$typed" ] && [ ! -f "$(fm_test_composer_entered_path)" ]; then
    printf '%s\n' "$(cat "$typed")" >> "$(fm_test_composer_submitted_path)"
  fi
  : > "$(fm_test_composer_entered_path)"
}

fm_test_tmux_echo_capture() {
  local typed entered
  typed=$(fm_test_composer_typed_path)
  entered=$(fm_test_composer_entered_path)
  if [ -f "$typed" ] && [ ! -f "$entered" ]; then
    fm_test_write_composer "$(cat "$typed")"
  else
    fm_test_write_composer ""
  fi
}
