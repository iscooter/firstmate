#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude), `›` (codex), `⟩` (muse), and `→`
#      (cursor) are a genuine empty agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  # muse draws `⟩` at luminance ~150, the tightest margin over the 128 ghost
  # threshold in the fleet, so a raised threshold really can strip it to empty
  # and leave only the plain row. This branch is what keeps that pane readable.
  for plain in '❯' '›' '⟩'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  out=$(classify 0 '⟩'); [ "$out" = empty ] || fail "bare muse '⟩' should read empty, got '$out'"
  out=$(classify 1 '⟩'); [ "$out" = empty ] || fail "bordered muse '⟩' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex, ⟩ muse) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'Type a message...' "$idle" sensitive 'Type a message...' 1 1)
  [ "$out" = pending ] || fail "placeholder-like text surviving a styled box capture should read pending, got '$out'"
  out=$(classify 1 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 1 0)
  [ "$out" = empty ] || fail "a glyph-bearing plain box placeholder should read empty, got '$out'"
  out=$(classify 0 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 0 1)
  [ "$out" = pending ] || fail "placeholder text on a styled bare input row must be pending, got '$out'"
  out=$(classify 0 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 0 0)
  [ "$out" = unknown ] || fail "placeholder text on a plain bare input row must be unknown, got '$out'"
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: idle matching is limited to proven placeholder positions"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle" sensitive 'type a message...' 1 0)
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive 'type a message...' 1 0)
  [ "$out" = empty ] || fail "an explicitly insensitive plain placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # muse restores the interrupted prompt into its composer after Escape, as real
  # bright text. Reading that as pending is correct - it really is unsubmitted.
  out=$(classify 0 '⟩ second turn to interrupt'); [ "$out" = pending ] || fail "bare '⟩ <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# =============================================================================
# fm_composer_classify_screen: the adapter-facing screen classifier and the
# correctness matrix (audit data/fm-composer-consolidation-audit-s1, task
# fm-composer-thin-adapter-refactor-r1).
#
# Fixtures are the audit's byte-level captures of six REAL idle harnesses:
# claude 2.1.226 (bare `❯` + U+00A0 NO-BREAK SPACE), codex 0.146.0 (bold `›`
# + SGR-2 dim hint), muse (truecolor `⟩`, 38;2;90;160;255), pi (blank row
# between solid `─` rules), opencode 1.14.46 (left-bar `┃` rows), and grok
# 1.0.0 (bordered box with a TITLED bottom border), plus claude captured
# inside zellij through `dump-screen --ansi` (`ESC[m` `❯` U+00A0).
#
# Capability profiles mirror the real adapters' descriptors: tmux
# (styled+cursor+identity), herdr/zellij (styled), cmux/orca (plain). Every
# emptiness verdict is asserted under the ambient UTF-8 locale AND LC_ALL=C,
# pinning the locale-safe Unicode-space normalization (issue #1988).
# =============================================================================

ESC=$(printf '\033')
NBSP=$(printf '\302\240')
CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'      # herdr
CAPS_STYLED_NOID=$'styled=1\ncursor=0\nidentity=0\nrows=20' # zellij
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'       # cmux, orca

# assert_screen <label> <want> <caps> <screen> [cursor] [identity]: one
# verdict, asserted under the ambient locale AND LC_ALL=C.
assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

test_matrix_claude_bare_nbsp_row() {
  # Real idle claude: `❯` + U+00A0, borderless, between horizontal rules.
  # The audit's headline defect: this row read `pending` under LC_ALL=C
  # (issue #1988), deferring every away-mode escalation in daemon contexts.
  local screen typed
  screen=$'transcript line\n────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n  bypass permissions'
  assert_screen "claude idle on tmux" empty "$CAPS_TMUX" "$screen" 2 probe-absent
  assert_screen "claude idle on herdr" empty "$CAPS_STYLED" "$screen" '' probe-absent
  assert_screen "claude idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  typed=$'────────────────────────\n❯ fix the login bug\n────────────────────────'
  assert_screen "claude typed on tmux" pending "$CAPS_TMUX" "$typed" 1 probe-absent
  # Plain capture cannot tell typed text from claude's rotating suggestion:
  # the styled=0 degradation defers instead of fabricating pending.
  assert_screen "claude typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  pass "matrix: claude's ❯+NBSP row reads empty on every profile in both locales (#1988)"
}

test_matrix_codex_dim_hint_row() {
  # Real idle codex: bold `›`, reset, then an SGR-2 dim hint. Styled captures
  # strip the ghost and prove empty; plain captures must defer as unknown -
  # NEVER the old false `pending` that read the hint as unsent text.
  local styled plain
  styled=$'banner\n'"${ESC}[1m›${ESC}[0m ${ESC}[2mUse /skills to list available skills${ESC}[0m"
  plain=$'banner\n› Use /skills to list available skills'
  assert_screen "codex idle on tmux" empty "$CAPS_TMUX" "$styled" 1
  assert_screen "codex idle on herdr" empty "$CAPS_STYLED" "$styled"
  assert_screen "codex idle on zellij" empty "$CAPS_STYLED_NOID" "$styled"
  assert_screen "codex idle on plain backends" unknown "$CAPS_PLAIN" "$plain"
  pass "matrix: codex's dim hint is empty when styling proves it, unknown (never pending) when it cannot"
}

test_matrix_muse_truecolor_glyph_survives_signal_loss() {
  # Real idle muse: truecolor `⟩` (38;2;90;160;255, luminance ~149.9) under a
  # TITLED rule. Two independent signals prove emptiness: the glyph surviving
  # the ghost strip, and the UNSTRIPPED plain row carrying an agent glyph.
  # Drive them apart: with the luma threshold raised past the glyph's
  # luminance, the ghost strip erases it, and the verdict must survive on the
  # plain-row signal alone.
  local screen plain out
  screen=$'── Voice input (⌥ + v to start) ─────\n'"${ESC}[0m${ESC}[38;2;90;160;255m⟩${ESC}[0m"
  plain=$'── Voice input (⌥ + v to start) ─────\n⟩'
  assert_screen "muse idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "muse idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "muse idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "muse idle on cmux/orca" empty "$CAPS_PLAIN" "$plain"
  out=$(FM_COMPOSER_GHOST_LUMA_MAX=200 fm_composer_classify_screen "$CAPS_STYLED" "$screen")
  [ "$out" = empty ] || fail "muse must stay empty when the ghost strip eats its glyph (plain-row signal), got '$out'"
  pass "matrix: muse's ⟩ reads empty everywhere and survives losing the styled-glyph signal"
}

test_matrix_cursor_reverse_video_placeholder_remnant() {
  # Real idle cursor-agent (2026.08.11-e8db854), captured byte-for-byte from a
  # live pane: the `→ ` glyph and the placeholder tail are dim (SGR 2), but the
  # cell under the terminal cursor is REVERSE VIDEO (SGR 0;7). Reverse video is
  # neither dim nor a dark foreground, so the ghost stripper keeps that one
  # character and an idle composer reduces to a lone `P`.
  local row screen plain out stripped
  row="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0;7m${ESC}[48;2;21;21;21mP"
  row="${row}${ESC}[0;2m${ESC}[48;2;21;21;21mlan, search, build anything${ESC}[0m"
  screen=$'transcript\n\n'"$row"
  plain=$'transcript\n\n  → Plan, search, build anything'

  # NON-VACUOUSNESS: prove the remnant really survives stripping. If the ghost
  # stripper ever learned SGR 7, `stripped` would be empty and the verdict below
  # would come from the empty-content path instead, silently retiring the
  # plain-row branch this case exists to cover.
  stripped=$(printf '%s' "$row" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" = P ] \
    || fail "cursor's reverse-video remnant must survive ghost stripping as 'P', got '$stripped'"

  assert_screen "cursor idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "cursor idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  # An UNSTYLED capture carries no ghost-strip proof, so a bare row matching a
  # placeholder is indistinguishable from typed text and must stay unknown -
  # the same degradation every other bare-row placeholder already takes.
  assert_screen "cursor idle on cmux/orca" unknown "$CAPS_PLAIN" "$plain"

  # The dangerous direction: text a user actually TYPED is uniformly bright, so
  # stripping leaves it EQUAL to the plain row. Even when that text is exactly
  # the placeholder, it must stay pending - never a false empty.
  local typed typed_plain
  typed="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0m${ESC}[38;2;224;222;244mAdd a follow-up${ESC}[0m"
  typed_plain=$'transcript\n\n  → Add a follow-up'
  assert_screen "cursor typed placeholder text stays pending" pending \
    "$CAPS_STYLED" $'transcript\n\n'"$typed"
  # Without styling there is no proof either way, so it must not read empty.
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$typed_plain")
  [ "$out" != empty ] \
    || fail "an unstyled cursor row matching the placeholder must not read empty, got '$out'"
  pass "matrix: cursor's reverse-video placeholder remnant reads empty; real typed text stays pending"
}

test_matrix_herdr_halfblock_rule_bounds_bare_wrap() {
  # Herdr draws a composer's rules with half-block glyphs (▄ above, ▀ below)
  # rather than the box-drawing family. Without treating those as edges, a bare
  # composer's WRAP region walks through its own closing rule and swallows the
  # footer, whose real content turns an idle pane into a false `pending`.
  # Captured live from a herdr cursor pane.
  local screen plain out
  plain=$'transcript\n \u2584\u2584\u2584\u2584\u2584\u2584\u2584\u2584\n  \u2192 Add a follow-up\n \u2580\u2580\u2580\u2580\u2580\u2580\u2580\u2580\n  Cursor Grok 4.5 High \u00b7 6.7%   Run Everything\n  ~/wt \u00b7 64cdd3a'
  # The closing rule must bound the region, so the footer below is not input.
  fm_composer_row_has_edge " $(printf '\u2580\u2580\u2580')" \
    || fail "a half-block rule row must count as a structural edge"
  fm_composer_row_has_edge " $(printf '\u2584\u2584\u2584')" \
    || fail "the upper half-block rule must count as a structural edge"
  # Non-vacuousness: the footer rows really are non-blank content that would be
  # swallowed if the rule did not bound the region.
  case "$plain" in *"Run Everything"*) : ;; *) fail "fixture lost its footer content" ;; esac
  ESC_LOCAL=$(printf '\033')
  screen=$'transcript\n \u2584\u2584\u2584\u2584\u2584\u2584\u2584\u2584\n'"  ${ESC_LOCAL}[2m\u2192 ${ESC_LOCAL}[0;7mA${ESC_LOCAL}[0;2mdd a follow-up${ESC_LOCAL}[0m"$'\n \u2580\u2580\u2580\u2580\u2580\u2580\u2580\u2580\n  Cursor Grok 4.5 High \u00b7 6.7%   Run Everything\n  ~/wt \u00b7 64cdd3a'
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$(printf '%b' "$screen")")
  [ "$out" = empty ] \
    || fail "an idle cursor composer inside herdr half-block rules must read empty, got '$out'"
  pass "matrix: herdr half-block rules bound a bare composer's wrap region"
}

test_matrix_pi_separated_needs_identity() {
  # Real idle pi: a blank row between two solid rules. The blank row alone is
  # exactly what the strict rule refuses; only structure PLUS a live
  # idle/done/blocked pi identity proves the composer (herdr's rule, now
  # fleet-wide; tmux supplies identity from its foreground-process probe).
  local screen typed pi_idle pi_working none
  screen=$'transcript\n────────────────────────\n\n────────────────────────\n footer'
  pi_idle=$(printf 'pi\tidle'); pi_working=$(printf 'pi\tworking'); none=$(printf 'zsh\t')
  assert_screen "pi idle with identity" empty "$CAPS_STYLED" "$screen" '' "$pi_idle"
  assert_screen "pi idle on tmux with identity" empty "$CAPS_TMUX" "$screen" 2 "$pi_idle"
  assert_screen "pi idle on zellij" unknown "$CAPS_STYLED_NOID" "$screen"
  # Identity-capable but unfetched: the adapter is asked to probe lazily.
  [ "$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")" = need-identity ] \
    || fail "an identity-capable profile should request the lazy identity probe"
  # No identity capability (cmux/orca/zellij): the shape is unprovable.
  assert_screen "pi pair without identity capability" unknown "$CAPS_PLAIN" "$screen"
  # A working pi cannot authorize injection into the blank region.
  assert_screen "working pi defers" unknown "$CAPS_STYLED" "$screen" '' "$pi_working"
  # The audit's live counterexample: a plain shell running sleep, cursor
  # parked on a blank line between two rules, NO pi process. The permissive
  # rule read this `empty`; identity+structure refuses it.
  assert_screen "sleep-pane counterexample" unknown "$CAPS_TMUX" "$screen" 2 "$none"
  assert_screen "absent identity cannot prove blank pi pair" unknown "$CAPS_TMUX" "$screen" 2 probe-absent
  typed=$'────────────────────────\nfix the flaky test\n────────────────────────'
  assert_screen "pi typed" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  typed=$'────────────────────────\n❯\n────────────────────────'
  assert_screen "pi lone-glyph draft with identity" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  assert_screen "pi lone-glyph draft on tmux" pending "$CAPS_TMUX" "$typed" 1 "$pi_idle"
  assert_screen "lone glyph without identity capability" empty "$CAPS_STYLED_NOID" "$typed"
  assert_screen "lone glyph on plain backend" empty "$CAPS_PLAIN" "$typed"
  assert_screen "lone glyph with non-pi identity" empty "$CAPS_STYLED" "$typed" '' "$none"
  pass "matrix: pi's separated composer needs identity + structure; the blank row alone never proves it"
}

test_matrix_opencode_leftbar_signals() {
  # Real idle opencode: `┃`-prefixed rows holding the "Ask anything..." hint,
  # blanks, and a Build-mode footer. Two independent idle signals: the shared
  # idle-placeholder pattern (works on plain captures) and the ghost strip
  # (works on styled captures even if the pattern is overridden away).
  local screen typed dim_screen out
  screen=$'  ┃\n  ┃  Ask anything... "What is the tech stack?"\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀'
  dim_screen=$'  ┃\n  ┃  '"${ESC}[2mAsk anything...${ESC}[0m"$'\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀'
  assert_screen "opencode idle on tmux (cursor on hint)" empty "$CAPS_TMUX" "$dim_screen" 1
  assert_screen "opencode idle on herdr" empty "$CAPS_STYLED" "$dim_screen"
  assert_screen "opencode idle on zellij" empty "$CAPS_STYLED_NOID" "$dim_screen"
  assert_screen "opencode idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  # Signal separation: with the idle pattern overridden to something that
  # cannot match, a DIM-styled hint still proves empty through the ghost strip.
  out=$(FM_COMPOSER_IDLE_RE='^NEVER-MATCHES$' fm_composer_classify_screen "$CAPS_TMUX" "$dim_screen" 1)
  [ "$out" = empty ] || fail "a dim opencode hint must stay empty via the ghost strip alone, got '$out'"
  typed=$'┃\n┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  assert_screen "opencode typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  Ask anything... please investigate\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode placeholder-like input on tmux" pending "$CAPS_TMUX" "$typed" 0
  assert_screen "opencode placeholder-like input on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high'
  assert_screen "opencode multiline draft above blank cursor row" pending "$CAPS_TMUX" "$typed" 1
  pass "matrix: opencode's left-bar composer reads empty everywhere and scans the full active run"
}

test_matrix_grok_titled_bottom_border() {
  # Real idle grok: a bordered box whose BOTTOM border carries the model name.
  # The audit showed the title alone flipped tmux's geometry check to
  # ambiguous and the verdict to unknown, stranding every grok steer.
  local titled plain_border typed placeholder_draft
  titled=$'  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────── Grok 4.5 (high) ─╯'
  plain_border=$'  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────────────────────────╯'
  assert_screen "grok titled on tmux" empty "$CAPS_TMUX" "$titled" 1
  assert_screen "grok titled on tmux bottom-border cursor" empty "$CAPS_TMUX" "$titled" 2
  assert_screen "grok titled on herdr" empty "$CAPS_STYLED" "$titled"
  placeholder_draft=$'  ╭──────────────────────────────────────╮\n  │ ❯ Type a message...                  │\n  ╰──────────────────── Grok 4.5 (high) ─╯'
  assert_screen "grok bright placeholder-like draft on tmux" pending "$CAPS_TMUX" "$placeholder_draft" 1
  assert_screen "grok placeholder on plain backends" empty "$CAPS_PLAIN" "$placeholder_draft"
  assert_screen "grok titled on cmux/orca" empty "$CAPS_PLAIN" "$titled"
  assert_screen "grok titled on zellij" empty "$CAPS_STYLED_NOID" "$titled"
  # The tolerance is additive: an untitled border still proves the same box.
  assert_screen "grok untitled border" empty "$CAPS_TMUX" "$plain_border" 1
  typed=$'  ╭──────────────────────────────────────╮\n  │ ❯ deploy the fix                     │\n  ╰──────────────────── Grok 4.5 (high) ─╯'
  assert_screen "grok typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  pass "matrix: grok's titled bottom border is tolerated as a title, not read as ambiguity"
}

test_matrix_kimi_bordered_shell_glyph_box() {
  # Kimi's bordered `│ > │` composer - the shape fm-spawn.sh's retired
  # spawn-local regex used to own. Now the shared owner proves it everywhere,
  # which is what kimi launch-readiness and delivery route through.
  local screen
  screen=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯'
  assert_screen "kimi idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "kimi idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  assert_screen "kimi idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "kimi idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  pass "matrix: kimi's bordered shell-glyph box reads empty through the shared owner (spawn's fourth copy retired)"
}

test_matrix_claude_inside_zellij_ansi_dump() {
  # Real claude captured through `zellij action dump-screen --ansi`
  # (capability established by the audit): `ESC[m` `❯` U+00A0.
  local screen plain
  screen=$'zellij pane transcript\n'"${ESC}[m❯${NBSP}"
  plain=$'zellij pane transcript\n❯'"$NBSP"
  assert_screen "claude-in-zellij on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "claude-in-zellij on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "claude-in-zellij on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude-in-zellij on plain backends" empty "$CAPS_PLAIN" "$plain"
  pass "matrix: the real claude-in-zellij --ansi dump reads empty in both locales"
}

test_strict_blank_row_divergence() {
  # THE STRICT POSTURE PIN (captain decision blank-row-injection-posture,
  # 2026-08-09): a blank or otherwise unidentified input row with no positive
  # container proof is `unknown`. Each case below read `empty` (or `pending`)
  # under the replaced permissive rule; if any of them drifts back, the
  # permissive posture has silently returned and away-mode injection would
  # again type escalations into unproven panes.
  local out
  # Permissive read this blank cursor row as empty = safe to inject.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'some output\nmore output\n' 2)
  [ "$out" = unknown ] || fail "a blank unidentified cursor row must be unknown (was permissive empty), got '$out'"
  # A dead shell's prompt row.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\n$ ' 1)
  [ "$out" = unknown ] || fail "a dead-shell prompt row must be unknown, got '$out'"
  # A bare busy-footer row is not a composer container.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'Working...' 0)
  [ "$out" = unknown ] || fail "a bare busy-footer row must be unknown (was permissive empty), got '$out'"
  # An unidentified free-text cursor row carries no container proof either.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\nhuman draft text' 1)
  [ "$out" = unknown ] || fail "an unidentified text row must be unknown under strict, got '$out'"
  # A blank screen with no cursor capability.
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'\n\n')
  [ "$out" = unknown ] || fail "a blank screen must be unknown, got '$out'"
  pass "strict posture: blank and unidentified rows are unknown, never injectable empty"
}

test_bare_wrap_region_classifies() {
  # Long typed input wraps below the glyph row; the cursor rides the wrapped
  # continuation. The region is IDENTIFIED (glyph row + contiguous non-blank,
  # non-structural rows), so a swallowed Enter still reads pending and earns
  # its retry; a wrapped GHOST suggestion still proves empty.
  local wrapped ghost_wrapped out
  wrapped=$'❯ a very long steer message that\nwraps onto the following line'
  assert_screen "wrapped typed input" pending "$CAPS_TMUX" "$wrapped" 1
  wrapped=$'❯ wrapped typed input\ncontinues without a terminal-inserted glyph'
  assert_screen "ordinary wrapped input" pending "$CAPS_TMUX" "$wrapped" 1
  ghost_wrapped=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$ghost_wrapped" 1)
  [ "$out" = empty ] || fail "a wrapped ghost suggestion should still prove empty, got '$out'"
  # A structural row between the glyph and the cursor breaks the wrap claim.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n────────────────\nbelow the rule' 2)
  [ "$out" = unknown ] || fail "a rule between glyph and cursor must break the wrap region, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n$ live shell' 1)
  [ "$out" = unknown ] || fail "a shell prompt below a glyph row must not become wrapped input, got '$out'"
  pass "fm_composer_classify_screen: the bare composer's wrap region stays identified; structure breaks it"
}

test_contiguous_transcript_reanchors_on_live_prompt() {
  local screen
  screen=$'❯ hi\nHello!\n❯'
  assert_screen "contiguous transcript live prompt on cursorless styled backend" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "contiguous transcript live prompt on cursorless plain backend" empty "$CAPS_PLAIN" "$screen"
  assert_screen "contiguous transcript live prompt with cursor" empty "$CAPS_TMUX" "$screen" 2
  pass "fm_composer_classify_screen: a row-leading agent glyph reanchors the live composer"
}

test_lower_dead_shell_invalidates_cursorless_candidate() {
  local stale live out
  stale=$'old transcript\n❯\nprocess exited\n$'
  assert_screen "stale composer above dead shell on herdr" unknown "$CAPS_STYLED" "$stale"
  assert_screen "stale composer above dead shell on zellij" unknown "$CAPS_STYLED_NOID" "$stale"
  assert_screen "stale composer above dead shell on cmux/orca" unknown "$CAPS_PLAIN" "$stale"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$stale" 1)
  [ "$out" = empty ] \
    || fail "cursor mode must keep the cursor-anchored composer verdict, got '$out'"

  live=$'transcript shell snippet\n$ echo old output\nmore transcript\n❯'
  assert_screen "shell transcript above live composer on herdr" empty "$CAPS_STYLED" "$live"
  assert_screen "shell transcript above live composer on zellij" empty "$CAPS_STYLED_NOID" "$live"
  assert_screen "shell transcript above live composer on cmux/orca" empty "$CAPS_PLAIN" "$live"
  pass "fm_composer_classify_screen: a lower dead shell invalidates only cursorless stale composers"
}

test_cursorless_bare_wrap_region_classifies() {
  local activity status bounded ghost out
  activity=$'❯\nWorking on request...'
  assert_screen "cursorless activity below bare row on herdr" pending "$CAPS_STYLED" "$activity"
  assert_screen "cursorless activity below bare row on zellij" pending "$CAPS_STYLED_NOID" "$activity"
  assert_screen "cursorless activity below bare row on cmux/orca" unknown "$CAPS_PLAIN" "$activity"

  status=$'›\n\ncodex status line'
  assert_screen "blank-separated codex status on herdr" empty "$CAPS_STYLED" "$status"
  assert_screen "blank-separated codex status on zellij" empty "$CAPS_STYLED_NOID" "$status"
  assert_screen "blank-separated codex status on cmux/orca" empty "$CAPS_PLAIN" "$status"

  bounded=$'────────────────────────\n❯\n────────────────────────\nClaude 4.1'
  assert_screen "rule-bounded claude footer on herdr" empty "$CAPS_STYLED" "$bounded" '' probe-absent
  assert_screen "rule-bounded claude footer on zellij" empty "$CAPS_STYLED_NOID" "$bounded"
  assert_screen "rule-bounded claude footer on cmux/orca" empty "$CAPS_PLAIN" "$bounded"

  ghost=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$ghost")
  [ "$out" = empty ] || fail "cursorless ghost wrap on herdr should be empty, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_STYLED_NOID" "$ghost")
  [ "$out" = empty ] || fail "cursorless ghost wrap on zellij should be empty, got '$out'"
  pass "fm_composer_classify_screen: cursorless bare wrap regions participate in verdicts"
}

test_cursorless_container_rejects_contiguous_lower_activity() {
  local box leftbar grok kimi opencode
  box=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nWorking on request...'
  assert_screen "stale box above activity on herdr" unknown "$CAPS_STYLED" "$box"
  assert_screen "stale box above activity on zellij" unknown "$CAPS_STYLED_NOID" "$box"
  assert_screen "stale box above activity on cmux/orca" unknown "$CAPS_PLAIN" "$box"

  leftbar=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀\nWorking on request...'
  assert_screen "stale left-bar above activity on herdr" unknown "$CAPS_STYLED" "$leftbar"
  assert_screen "stale left-bar above activity on zellij" unknown "$CAPS_STYLED_NOID" "$leftbar"
  assert_screen "stale left-bar above activity on cmux/orca" unknown "$CAPS_PLAIN" "$leftbar"

  grok=$'╭────────────────────────╮\n│ ❯                      │\n╰──────── Grok 4.5 ──────╯\n\nGrok status'
  kimi=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯\n\nKimi status'
  opencode=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀\n\nOpenCode status'
  assert_screen "blank-separated grok footer" empty "$CAPS_STYLED_NOID" "$grok"
  assert_screen "blank-separated kimi footer" empty "$CAPS_PLAIN" "$kimi"
  assert_screen "left-bar floor and blank-separated footer" empty "$CAPS_STYLED_NOID" "$opencode"
  pass "fm_composer_classify_screen: cursorless containers reject only contiguous unclaimed activity"
}

test_bottom_most_candidate_wins() {
  # The one ranking rule: the live composer is bottom-anchored, so a stale
  # decorative box (codex's startup banner) can never outrank the real row
  # below it - the confidently-wrong orca case from the audit.
  local screen out
  screen=$'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n❯'"$NBSP"
  assert_screen "banner above live claude row" empty "$CAPS_PLAIN" "$screen"
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n› Use /skills to list available skills')
  [ "$out" != pending ] || fail "a stale banner must never classify as pending composer text"
  screen=$'❯ old draft\n\n❯'
  assert_screen "blank-separated newer bare composer" empty "$CAPS_STYLED_NOID" "$screen"
  pass "fm_composer_classify_screen: the bottom-most candidate wins; stale banners cannot"
}

test_incomplete_lower_box_invalidates_stale_candidate() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nstartup complete\n╭────────────────────────╮\n│ ❯ clipped live draft  '
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$screen")
  [ "$out" = unknown ] \
    || fail "an incomplete lower box must invalidate an earlier empty box, got '$out'"
  pass "fm_composer_classify_screen: incomplete lower structure invalidates stale boxes"
}

test_titled_bottom_requires_matching_width() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰─ Grok ─╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 1)
  [ "$out" = unknown ] \
    || fail "a short titled bottom must not prove an empty box, got '$out'"
  pass "fm_composer_classify_screen: titled bottoms retain full box geometry"
}

test_cursor_on_proven_box_bottom_classifies_content() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 2)
  [ "$out" = empty ] \
    || fail "a cursor on a proven box bottom must classify its content, got '$out'"
  pass "fm_composer_classify_screen: a proven box tolerates a bottom-border cursor"
}

test_queued_enter_verdict_busy_pending_is_empty() {
  local out
  out=$(fm_composer_queued_enter_verdict pending busy)
  [ "$out" = empty ] || fail "busy + proven pending must be queued delivery (empty), got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + busy returns empty (queued Enter)"
}

test_queued_enter_verdict_idle_pending_stays_pending() {
  local out
  out=$(fm_composer_queued_enter_verdict pending idle)
  [ "$out" = pending ] || fail "idle + proven pending must stay a genuine swallow, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending unknown)
  [ "$out" = pending ] || fail "unknown busy is not proof of a queue, got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + idle/unknown stays pending"
}

test_queued_enter_verdict_does_not_convert_other_states() {
  local state out
  for state in empty pending-unproven unknown send-failed future-state; do
    out=$(fm_composer_queued_enter_verdict "$state" busy)
    [ "$out" = "$state" ] || fail "busy must not convert '$state', got '$out'"
    out=$(fm_composer_queued_enter_verdict "$state" idle)
    [ "$out" = "$state" ] || fail "idle must not convert '$state', got '$out'"
  done
  pass "fm_composer_queued_enter_verdict: only proven pending is converted"
}

test_queued_enter_verdict_busy_pending_is_empty
test_queued_enter_verdict_idle_pending_stays_pending
test_queued_enter_verdict_does_not_convert_other_states

# --- pre-Enter delivery proof: fm_composer_delivery_delta_verdict -----------
#
# The proof under test never asks where the composer is; it asks whether the
# payload became NEWLY PRESENT between two captures. These regressions drive it
# through its public entry point against captures taken from REAL harnesses
# (tests/fixtures/composer-delta/, provenance in that directory's README), not
# hand-drawn boxes: a hand-drawn fixture can only confirm the shape assumption
# its author wrote into it, and shape assumptions are the failure class this
# proof exists to end.

DELTA_FIXTURES="$(dirname "${BASH_SOURCE[0]}")/fixtures/composer-delta"
# The exact 152-character payload typed into every fixture pair.
DELTA_PAYLOAD='LAVISH PROPOSAL: investigate the fm-send delivery path end to end and produce a design-only report; do not implement anything. END-OF-PAYLOAD-MARKER-7Q4Z'

delta_fixture_verdict() {  # <name> <plain|ansi> -> verdict on stdout
  local name=$1 fidelity=$2 before after
  before=$(cat "$DELTA_FIXTURES/$name.before.$fidelity")
  after=$(cat "$DELTA_FIXTURES/$name.after.$fidelity")
  fm_composer_delivery_delta_verdict "$before" "$after" "$DELTA_PAYLOAD" || true
}

# Every healthy send must be accepted and every swallow refused, on BOTH
# capture fidelities. Asserting the two fidelities agree is the regression that
# keeps the deleted styled=1/styled=0 fork from returning: that fork is what
# made the same real screen accept under tmux and refuse under cmux, orca, and
# herdr's plain fallback.
test_delta_verdict_matches_real_harness_captures() {
  local name expect got_plain got_ansi checked=0
  for name in \
    claude-healthy:accepted \
    claude-trust:not-accepted \
    codex-healthy:accepted \
    codex-launch:not-accepted \
    opencode-healthy:accepted \
    opencode-launch:not-accepted \
    cursor-healthy:accepted \
    grok-healthy:accepted \
    muse-healthy:accepted \
    pi-healthy:accepted \
    pisigned-healthy:accepted; do
    expect=${name#*:}
    name=${name%%:*}
    got_plain=$(delta_fixture_verdict "$name" plain)
    got_ansi=$(delta_fixture_verdict "$name" ansi)
    case "$got_plain" in
      "$expect"*) ;;
      *) fail "$name (plain capture) must be $expect, got '$got_plain'" ;;
    esac
    case "$got_ansi" in
      "$expect"*) ;;
      *) fail "$name (ANSI capture) must be $expect, got '$got_ansi'" ;;
    esac
    [ "$got_plain" = "$got_ansi" ] \
      || fail "$name must reach the same verdict on both capture fidelities: plain='$got_plain' ansi='$got_ansi'"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 11 ] \
    || fail "the real-capture matrix checked only $checked scenarios; a missing fixture must fail, not silently shrink the matrix"
  pass "fm_composer_delivery_delta_verdict: 11 real-harness scenarios, plain and ANSI captures agreeing (22 verdicts)"
}

# opencode's composer hard-wraps mid-word inside a left bar, sits ABOVE a
# footer rather than at the bottom of the pane, and carries a keybinding-hint
# row underneath. Each of those defeated a region parser. This asserts the
# fixture really has those properties, so the case cannot pass vacuously if a
# future capture is replaced with a tidier one.
test_delta_verdict_survives_opencode_wrap_and_furniture() {
  local after
  after=$(cat "$DELTA_FIXTURES/opencode-healthy.after.plain")
  assert_contains "$after" 'END-OF-' "the opencode fixture must still hard-wrap the payload mid-word"
  assert_contains "$after" 'tab agents' "the opencode fixture must still carry the hint row below its composer"
  assert_contains "$after" '1.14.46' "the opencode fixture must still carry the footer BELOW the composer (not bottom-anchored)"
  [ "$(delta_fixture_verdict opencode-healthy plain)" = accepted ] \
    || fail "a healthy opencode send must be accepted despite the wrap and the furniture"
  pass "fm_composer_delivery_delta_verdict: a mid-word wrap, a hint row, and a non-bottom-anchored composer do not block acceptance"
}

# The vendor update modal opencode parks on swallows a typed payload whole, and
# it trips NONE of the gate scorer's signals - no trust language, no numbered
# list, no confirm affordance. That is the live proof that the gate must not be
# load-bearing for send safety, and that the delta proof is what actually holds
# the line. Asserting BOTH halves keeps this from going vacuous if the scorer
# is later tuned to catch this particular modal.
test_delta_verdict_refuses_a_swallow_the_gate_scorer_misses() {
  local before
  before=$(cat "$DELTA_FIXTURES/opencode-launch.before.plain")
  assert_contains "$before" 'Update Available' "the fixture must still be the vendor update modal"
  if fm_composer_screen_is_gated "$before"; then
    fail "this fixture is only meaningful while the gate scorer MISSES it; re-point the assertion rather than deleting it"
  fi
  [ "$(delta_fixture_verdict opencode-launch plain)" = not-accepted:absent-from-added ] \
    || fail "an ungated modal that swallowed the payload must still be refused by the delta proof"
  pass "fm_composer_delivery_delta_verdict: refuses a swallowing modal the gate scorer does not recognise"
}

# A trust dialog is refused twice over, and loudly: the pre-type gate declines
# to type into it at all, and the delta proof independently refuses because
# nothing landed. Neither may return a verdict a caller could read as delivery.
test_gated_trust_dialog_is_refused_before_typing_and_after() {
  local before after verdict
  before=$(cat "$DELTA_FIXTURES/claude-trust.before.plain")
  after=$(cat "$DELTA_FIXTURES/claude-trust.after.plain")
  fm_composer_screen_is_gated "$before" \
    || fail "a real Claude workspace-trust dialog must score as gated"
  verdict=$(fm_composer_pre_type_ok "$before") \
    && fail "fm_composer_pre_type_ok must refuse a gated pane, got success"
  [ "$verdict" = gated ] || fail "the pre-type refusal must name the gate, got '$verdict'"
  verdict=$(fm_composer_delivery_delta_verdict "$before" "$after" "$DELTA_PAYLOAD") \
    && fail "a swallowed payload must not be accepted, got '$verdict'"
  case "$verdict" in
    not-accepted:*) ;;
    *) fail "the refusal must carry a reason, got '$verdict'" ;;
  esac
  pass "fm_composer_delivery_delta_verdict: a trust dialog refuses before typing and again after, both with a reason"
}

# The round-1 false pass: a copy of the payload is ALREADY on screen above the
# composer, the real send is swallowed, and the pane keeps changing. A
# whole-screen search accepted that. The delta proof excludes the stale copy by
# TIME rather than by location, so it cannot contribute.
test_scrollback_copy_of_the_payload_cannot_prove_delivery() {
  local before after verdict
  before=$'transcript: '"$DELTA_PAYLOAD"$'\n⏳ 0s\n╭────╮\n│    │\n╰────╯'
  after=$'transcript: '"$DELTA_PAYLOAD"$'\n⏳ 1s\n╭────╮\n│    │\n╰────╯'
  [ "$before" != "$after" ] \
    || fail "the fixture must actually differ, or it would prove nothing about a CHANGING pane"
  verdict=$(fm_composer_delivery_delta_verdict "$before" "$after" "$DELTA_PAYLOAD") \
    && fail "a pre-existing scrollback copy must never prove delivery, got '$verdict'"
  pass "fm_composer_delivery_delta_verdict: a scrollback copy plus a ticking pane is not delivery"
}

# Test A (novelty) and Test B (occurrence increase) fail in different
# directions, which is the whole reason both are required. Here every row
# carries a per-row counter, so the differ reports the ENTIRE screen as added
# and Test A is defeated outright - the anchor really is in the added set. Only
# Test B refuses, and the assertions below drive those two signals apart
# deliberately so this case cannot go quietly vacuous if Test A ever starts
# catching it for an unrelated reason.
test_occurrence_count_refuses_when_novelty_is_defeated() {
  local before after added verdict
  redrawn_screen() {  # <tick> - every row carries the tick, so nothing is unchanged
    printf '%s\n' \
      "[t+$1s] row one" \
      "[t+$1s] row two" \
      "[t+$1s] transcript: $DELTA_PAYLOAD" \
      "[t+$1s] ╭────╮" \
      "[t+$1s] │    │" \
      "[t+$1s] ╰────╯"
  }
  before=$(redrawn_screen 1)
  after=$(redrawn_screen 2)
  # Test A is genuinely defeated: the anchor IS among the rows the differ
  # reports as added.
  added=$(diff <(fm_composer_delta_rows "$before") <(fm_composer_delta_rows "$after") \
    | LC_ALL=C sed -n 's/^> //p' | LC_ALL=C tr -d '\n')
  assert_contains "$added" "$(fm_composer_payload_tail_anchor "$DELTA_PAYLOAD")" \
    "this case is only meaningful while the differ over-reports; the anchor must be inside the added set"
  verdict=$(fm_composer_delivery_delta_verdict "$before" "$after" "$DELTA_PAYLOAD") \
    && fail "a fully redrawn pane holding a stale copy must not be accepted, got '$verdict'"
  case "$verdict" in
    not-accepted:no-new-occurrence*) ;;
    *) fail "Test B (occurrence increase) must be what refuses this, got '$verdict'" ;;
  esac
  pass "fm_composer_delivery_delta_verdict: when a redrawing pane defeats novelty, the occurrence count still refuses"
}

# A partial write that landed only the head of the payload must not read as
# delivery - the anchor is the TAIL precisely so there is no silent partial.
test_partial_write_of_the_payload_is_refused() {
  local before after verdict
  before=$'╭────╮\n│    │\n╰────╯'
  after=$'╭────╮\n│ > '"${DELTA_PAYLOAD:0:60}"$' │\n╰────╯'
  assert_contains "$after" "${DELTA_PAYLOAD:0:40}" "the fixture must really carry the payload's head"
  verdict=$(fm_composer_delivery_delta_verdict "$before" "$after" "$DELTA_PAYLOAD") \
    && fail "a head-only partial write must not be accepted, got '$verdict'"
  pass "fm_composer_delivery_delta_verdict: a partial write that lost the payload tail is refused"
}

# The proof is shape-free by construction, so a stub that echoes the payload
# into no container at all is a healthy send. This is what lets the test
# fixtures across the suite stop drawing boxes, which is what stopped CI
# outcomes from depending on fixture cosmetics.
test_shape_free_echo_is_accepted() {
  local verdict
  verdict=$(fm_composer_delivery_delta_verdict '' "$DELTA_PAYLOAD" "$DELTA_PAYLOAD") \
    || fail "a bare echo of the payload with no container must be accepted, got '$verdict'"
  [ "$verdict" = accepted ] || fail "expected accepted, got '$verdict'"
  pass "fm_composer_delivery_delta_verdict: a payload echoed with no container at all is a healthy send"
}

# Uncertainty resolves to refusal, never to a bare success a caller could
# misread, and every refusal names why.
test_delta_verdict_fails_loud_on_an_empty_payload() {
  local verdict
  verdict=$(fm_composer_delivery_delta_verdict '' 'anything' '   ') \
    && fail "a payload that normalizes to nothing must not be accepted, got '$verdict'"
  [ "$verdict" = not-accepted:empty-payload ] \
    || fail "the empty-payload refusal must name itself, got '$verdict'"
  pass "fm_composer_delivery_delta_verdict: an unusable payload is refused with a named reason"
}

# The payload's own characters are normalized exactly like the screen's, so a
# steer that itself contains box glyphs or exotic whitespace needs no special
# case on either side.
# A short payload carries too little entropy to prove itself: `2` appears in a
# newly drawn row of a live agent pane constantly. It gets no weaker test - the
# anchor minimum still refuses it outright, and the envelope below is what
# makes short steers work.
test_delta_verdict_refuses_short_collision_anchor() {
  local verdict
  verdict=$(fm_composer_delivery_delta_verdict '' '1' '1') \
    && fail "a one-character screen collision must not prove payload delivery"
  case "$verdict" in
    not-accepted:payload-too-short\(normalized=1\ minimum=24\)) ;;
    *) fail "a short payload must fail loudly with its uniqueness requirement, got '$verdict'" ;;
  esac
  pass "fm_composer_delivery_delta_verdict: short collision anchors are refused"
}

# The envelope is what lets a one-character steer reach the proof above with a
# full-length anchor, instead of being refused or given a weaker test.
test_envelope_gives_a_short_payload_a_full_length_anchor() {
  local wire_a erase_a wire_b norm i ch before probe
  before='transcript contains the first candidate 2a already'
  fm_composer_envelope_prepare '2' "$before" || fail "a short payload must be envelopable"
  wire_a=$FM_COMPOSER_ENVELOPE_WIRE
  erase_a=$FM_COMPOSER_ENVELOPE_ERASE

  # The wire carries the payload, unaltered, at its head.
  case "$wire_a" in
    2*) ;;
    *) fail "the wire must start with the payload itself, got '$wire_a'" ;;
  esac
  # ... and exactly enough entropy after it to clear the anchor minimum.
  norm=$(fm_composer_delta_rows "$wire_a" | tr -d '\n')
  [ "${#norm}" -eq "$FM_COMPOSER_DELTA_ANCHOR_MIN" ] \
    || fail "the wire must normalize to exactly the anchor minimum, got ${#norm}"
  [ "$erase_a" -eq "$((FM_COMPOSER_DELTA_ANCHOR_MIN - 1))" ] \
    || fail "the erase count must be exactly the suffix length, got '$erase_a'"
  fm_composer_payload_tail_anchor "$wire_a" >/dev/null \
    || fail "the wire must yield a usable anchor where the bare payload could not"

  # No payload character may appear in the suffix. That exclusion is what makes
  # the erase proof decidable, so it is asserted rather than assumed.
  i=1
  while [ "$i" -lt "${#wire_a}" ]; do
    ch=${wire_a:i:1}
    [ "$ch" != 2 ] || fail "the suffix must not contain a payload character, got '$wire_a'"
    i=$((i + 1))
  done
  [ "$FM_COMPOSER_ENVELOPE_NONCE" = "${wire_a:1}" ] \
    || fail "the published suffix must be exactly the wire's tail past the payload"
  probe="2${FM_COMPOSER_ENVELOPE_NONCE:0:1}"
  [ "$(fm_composer_count_occurrences "$(fm_composer_delta_rows "$before" | tr -d '\n')" "$probe")" -eq 0 ] \
    || fail "the selected boundary probe must be absent before typing, got '$probe' in '$before'"

  # A fresh suffix per send: a reused one would be screen content a later send
  # could match against.
  fm_composer_envelope_prepare '2' "$before" || fail "second prepare failed"
  wire_b=$FM_COMPOSER_ENVELOPE_WIRE
  [ "$wire_a" != "$wire_b" ] || fail "the verification suffix must be fresh per send, got '$wire_a' twice"
  pass "fm_composer_envelope_prepare: a short payload gets a fresh full-length anchor and an exact erase count"
}

# The ordinary long steer must pay nothing for this: no suffix, no erase, and
# the wire byte-identical to the payload including whitespace the anchor
# normalization would have dropped.
test_envelope_leaves_a_self_proving_payload_alone() {
  fm_composer_envelope_prepare "$DELTA_PAYLOAD" 'idle pane' || fail "a long payload must prepare cleanly"
  [ "$FM_COMPOSER_ENVELOPE_ERASE" -eq 0 ] \
    || fail "a self-proving payload must need no erase, got '$FM_COMPOSER_ENVELOPE_ERASE'"
  [ "$FM_COMPOSER_ENVELOPE_WIRE" = "$DELTA_PAYLOAD" ] \
    || fail "a self-proving payload must be typed exactly as given"
  fm_composer_envelope_prepare "$DELTA_PAYLOAD"$'  \n' 'idle pane' || fail "trailing whitespace must still prepare"
  [ "$FM_COMPOSER_ENVELOPE_WIRE" = "$DELTA_PAYLOAD"$'  \n' ] \
    || fail "the wire must preserve trailing whitespace the caller meant to type"
  pass "fm_composer_envelope_prepare: a self-proving payload is typed verbatim with no envelope"
}

# Erasing across a row boundary is a line-join on some composers and a no-op on
# others, so a short multi-row payload is refused rather than guessed at. No
# real steer is both multi-row and this short.
test_envelope_refuses_a_short_multi_row_payload() {
  fm_composer_envelope_prepare $'a\nb' 'idle pane' \
    && fail "a short multi-row payload must not be envelopable"
  fm_composer_envelope_prepare '   ' 'idle pane' \
    && fail "a payload that normalizes to nothing must not be envelopable"
  pass "fm_composer_envelope_prepare: an unerasable short payload is refused, not guessed at"
}

test_envelope_boundary_verdict_pins_both_checkpoints() {
  local before checkpoint erased verdict nonce
  before=$'idle pane\nunrelated old boundary oka'
  fm_composer_envelope_prepare 'ok' "$before" || fail "prepare failed"
  nonce=$FM_COMPOSER_ENVELOPE_NONCE
  [ "${nonce:0:1}" != a ] \
    || fail "prepare must skip a boundary probe already present before typing"
  checkpoint="idle pane
> ok${nonce:0:1}"
  erased='idle pane
> ok'
  verdict=$(fm_composer_envelope_boundary_verdict "$checkpoint" 'ok' "$nonce" present) \
    || fail "the exact boundary checkpoint must be accepted, got '$verdict'"
  verdict=$(fm_composer_envelope_boundary_verdict "$erased" 'ok' "$nonce" absent) \
    || fail "the clean final erase must be accepted, got '$verdict'"
  verdict=$(fm_composer_envelope_boundary_verdict "$checkpoint" 'ok' "$nonce" absent) \
    && fail "a single leftover suffix character must not be accepted"
  case "$verdict" in
    not-accepted:envelope-not-erased*) ;;
    *) fail "an under-erase must name itself, got '$verdict'" ;;
  esac
  checkpoint=$'idle pane\n> o\nunrelated payload redraw: ok'
  verdict=$(fm_composer_envelope_boundary_verdict "$checkpoint" 'ok' "$nonce" present) \
    && fail "an over-erase must not be offset by an unrelated payload occurrence"
  [ "$verdict" = not-accepted:envelope-erase-overran-boundary ] \
    || fail "an over-erase must name the destroyed boundary, got '$verdict'"
  pass "fm_composer_envelope_boundary_verdict: opposite checkpoints pin both erase directions"
}

# --- the shared type-and-prove core, driven through a real pane simulator ----
#
# These exercise fm_composer_typed_delivery_core the way an adapter does, with
# three primitives over a file standing in for the composer. The simulator has
# no shape at all, so nothing here can pass by matching a fixture's borders.

# COMPOSER_FILE holds what the pane's composer currently contains; MODE selects
# how the simulated pane behaves.
sim_capture() {
  # A modal pane draws no composer at all - that is what makes it a modal - so
  # the gated mode renders the dialog alone rather than under a prompt row.
  if [ "$SIM_MODE" = gated ]; then
    printf '%s' "$SIM_SCROLLBACK"
    return 0
  fi
  if [ -s "$SIM_FILE" ]; then
    case "$SIM_MODE" in
      capture-after-write-fails) return 1 ;;
      delta-refuse) printf '%s' "$SIM_SCROLLBACK"; return 0 ;;
    esac
  fi
  if [ "$SIM_MODE" = erase-greedy-churn ] && [ "$SIM_ERASE_CALLS" -gt 0 ]; then
    printf '%s\n%s\n%s' "$SIM_SCROLLBACK" 'unrelated token counter: 2' "> $(cat "$SIM_FILE")"
    return 0
  fi
  printf '%s\n%s' "$SIM_SCROLLBACK" "> $(cat "$SIM_FILE")"
}
sim_literal() {
  case "$SIM_MODE" in
    swallow) return 0 ;;
    write-fails) return 1 ;;
  esac
  SIM_WIRE=$2
  printf '%s' "$2" > "$SIM_FILE.wire"
  printf '%s' "$2" >> "$SIM_FILE"
}
sim_erase() {
  local cur take=1 keep
  cur=$(cat "$SIM_FILE")
  SIM_ERASE_CALLS=$((SIM_ERASE_CALLS + 1))
  case "$SIM_MODE" in
    erase-fails) return 1 ;;
    erase-noop) return 0 ;;
    erase-greedy|erase-greedy-churn|erase-final-greedy) take=2 ;;
    erase-last-noop) [ "${#cur}" -ne 2 ] || return 0 ;;
  esac
  keep=$((${#cur} - take))
  [ "$keep" -ge 0 ] || keep=0
  printf '%s' "${cur:0:keep}" > "$SIM_FILE"
}

sim_reset() {  # <mode> [scrollback]
  SIM_MODE=$1
  SIM_SCROLLBACK=${2:-'agent idle'}
  SIM_FILE="$SIM_DIR/composer"
  SIM_ERASE_CALLS=0
  SIM_WIRE=
  rm -f "$SIM_FILE.wire"
  : > "$SIM_FILE"
}

sim_send() {  # <text> -> the core's verdict on stdout, its return code preserved
  fm_composer_typed_delivery_core sim_capture sim_literal sim_erase pane "$1" 0
}

# The case that must not regress: a one-character steer into a healthy pane is
# DELIVERED, and the composer is left holding exactly the payload - no
# verification suffix reaches the agent.
test_core_delivers_a_short_steer_and_leaves_no_residue() {
  local verdict
  sim_reset healthy
  verdict=$(sim_send '2') || fail "a short steer into a healthy pane must be proven, got '$verdict'"
  [ -z "$verdict" ] || fail "a proven delivery prints no verdict, got '$verdict'"
  [ "$(cat "$SIM_FILE")" = '2' ] \
    || fail "the composer must hold exactly the payload before Enter, got '$(cat "$SIM_FILE")'"
  pass "fm_composer_typed_delivery_core: a short steer is proven and leaves only the payload in the composer"
}

# A long steer takes the same path with no envelope at all, so the common case
# keeps costing one write and one capture.
test_core_delivers_a_self_proving_steer_untouched() {
  local verdict
  sim_reset healthy
  verdict=$(sim_send "$DELTA_PAYLOAD") || fail "a long steer must be proven, got '$verdict'"
  [ "$(cat "$SIM_FILE")" = "$DELTA_PAYLOAD" ] \
    || fail "a self-proving steer must be typed verbatim"
  pass "fm_composer_typed_delivery_core: a self-proving steer is delivered with no envelope"
}

# A pane that swallowed the keystrokes shows no delta, so no Enter may follow.
# This is the round-1 false delivery, and it must refuse for BOTH lengths.
test_core_refuses_a_swallowed_send() {
  local verdict
  sim_reset swallow
  verdict=$(sim_send '2') && fail "a swallowed short steer must not be proven"
  case "$verdict" in
    not-accepted:*) ;;
    *) fail "a swallowed send must refuse with a named reason, got '$verdict'" ;;
  esac
  sim_reset swallow
  verdict=$(sim_send "$DELTA_PAYLOAD") && fail "a swallowed long steer must not be proven"
  pass "fm_composer_typed_delivery_core: a pane that swallowed the write is refused at both payload lengths"
}

# The round-1 false pass: the payload is already on screen from an earlier
# send, and the write goes nowhere. Novelty alone could be fooled; the
# occurrence count cannot, because a pre-existing copy cannot raise it.
test_core_refuses_a_scrollback_copy_of_the_payload() {
  local verdict
  sim_reset swallow "agent idle
$DELTA_PAYLOAD"
  verdict=$(sim_send "$DELTA_PAYLOAD") \
    && fail "a scrollback copy of the payload must not prove a new delivery"
  case "$verdict" in
    not-accepted:*) ;;
    *) fail "the scrollback case must refuse with a named reason, got '$verdict'" ;;
  esac
  pass "fm_composer_typed_delivery_core: an earlier copy of the payload on screen proves nothing"
}

# A modal is refused BEFORE anything is typed, so a swallowing dialog never
# receives keystrokes that act as control input on its numbered list.
test_core_refuses_a_gated_pane_without_typing() {
  local verdict
  sim_reset gated "Do you trust the files in this folder?
  1. Yes, proceed
  2. No, exit
Enter to confirm"
  verdict=$(sim_send '2') && fail "a gated pane must refuse"
  [ "$verdict" = gated ] || fail "the gate must name itself, got '$verdict'"
  [ -z "$(cat "$SIM_FILE")" ] || fail "a gated pane must receive no keystrokes at all"
  pass "fm_composer_typed_delivery_core: a gated modal is refused before anything is typed"
}

# A backend with no erase primitive cannot take a suffix back off, so it must
# refuse a short payload before typing rather than strand one. A long payload
# needs no erase and still works there.
test_core_refuses_when_no_absent_boundary_probe_exists() {
  local verdict before='' ch i
  i=0
  while [ "$i" -lt "${#FM_COMPOSER_ENVELOPE_ALPHABET}" ]; do
    ch=${FM_COMPOSER_ENVELOPE_ALPHABET:i:1}
    i=$((i + 1))
    [ "$ch" = 2 ] || before="$before 2$ch"
  done
  sim_reset healthy "$before"
  verdict=$(sim_send '2') && fail "a short steer with no absent boundary probe must refuse"
  [ "$verdict" = not-accepted:envelope-boundary-probe-unavailable ] \
    || fail "the refusal must name the unavailable boundary probe, got '$verdict'"
  [ ! -s "$SIM_FILE" ] || fail "probe selection failure must happen before typing"
  pass "fm_composer_typed_delivery_core: unavailable boundary probes refuse before typing"
}

test_core_refuses_a_short_steer_when_the_backend_cannot_erase() {
  local verdict
  sim_reset healthy
  verdict=$(fm_composer_typed_delivery_core sim_capture sim_literal - pane '2' 0) \
    && fail "a backend with no erase primitive must refuse a short steer"
  case "$verdict" in
    not-accepted:short-payload-needs-erase-unsupported-by-backend*) ;;
    *) fail "the refusal must name the missing capability, got '$verdict'" ;;
  esac
  [ -z "$(cat "$SIM_FILE")" ] || fail "nothing may be typed when the suffix could not be removed"
  verdict=$(fm_composer_typed_delivery_core sim_capture sim_literal - pane "$DELTA_PAYLOAD" 0) \
    || fail "a self-proving steer needs no erase and must still work, got '$verdict'"
  pass "fm_composer_typed_delivery_core: no erase primitive refuses short steers before typing, long steers still work"
}

# When the erase does not happen, the text WAS typed. That is typed-unproven -
# never retype - and it must never be reported as a refusal that implies
# nothing went out.
test_core_two_checkpoint_erase_refuses_both_directions() {
  local verdict err wire payload23
  sim_reset erase-greedy-churn
  verdict=$(sim_send '2' 2>"$SIM_DIR/over.err") \
    && fail "an over-erase hidden by unrelated payload churn must not be proven"
  err=$(cat "$SIM_DIR/over.err")
  wire=$(cat "$SIM_FILE.wire")
  [ "$verdict" = typed-unproven ] || fail "an over-erase must report typed-unproven, got '$verdict'"
  assert_contains "$err" 'envelope-erase-overran-boundary' \
    "the stage-one refusal must name the destroyed boundary"
  assert_contains "$err" "$wire" \
    "the stage-one refusal must name the exact stranded wire"

  sim_reset erase-last-noop
  verdict=$(sim_send '2' 2>"$SIM_DIR/under.err") \
    && fail "a final swallowed erase leaving one suffix character must not be proven"
  err=$(cat "$SIM_DIR/under.err")
  wire=$(cat "$SIM_FILE.wire")
  [ "$verdict" = typed-unproven ] || fail "an under-erase must report typed-unproven, got '$verdict'"
  assert_contains "$err" 'envelope-not-erased' \
    "the stage-two refusal must name the leftover boundary"
  assert_contains "$err" "$wire" \
    "the stage-two refusal must name the exact stranded wire"

  payload23=12345678901234567890123
  sim_reset healthy
  verdict=$(sim_send "$payload23") \
    || fail "a one-character suffix must pass both erase checkpoints, got '$verdict'"
  [ "$(cat "$SIM_FILE")" = "$payload23" ] \
    || fail "the one-character suffix path must leave only its payload"

  sim_reset erase-final-greedy
  verdict=$(sim_send "$payload23" 2>"$SIM_DIR/final-over.err") \
    && fail "a final erase consuming a payload character must not be proven"
  err=$(cat "$SIM_DIR/final-over.err")
  wire=$(cat "$SIM_FILE.wire")
  [ "$verdict" = typed-unproven ] \
    || fail "a greedy final erase must report typed-unproven, got '$verdict'"
  assert_contains "$err" 'envelope-final-erase-consumed-payload' \
    "the secondary barrier must name a greedy final erase"
  assert_contains "$err" "$wire" \
    "the greedy final-erase warning must name the exact wire"
  pass "fm_composer_typed_delivery_core: erase checkpoints and final payload retention refuse every measured direction"
}

test_core_reports_a_failed_erase_as_typed_unproven() {
  local verdict mode
  for mode in erase-fails erase-noop erase-greedy; do
    sim_reset "$mode"
    verdict=$(sim_send '2' 2>/dev/null) && fail "a broken erase ($mode) must not be proven"
    [ "$verdict" = typed-unproven ] \
      || fail "a broken erase ($mode) must report typed-unproven, got '$verdict'"
  done
  pass "fm_composer_typed_delivery_core: every way the erase can fail reports typed-unproven, never a bare refusal"
}

# The operator settling a typed-unproven request needs the literal text to look
# for; a verdict token alone cannot carry it.
test_core_names_the_stranded_suffix_on_stderr() {
  local err mode wire
  for mode in erase-noop capture-after-write-fails delta-refuse; do
    sim_reset "$mode"
    err=$(sim_send '2' 2>&1 >/dev/null)
    wire=$(cat "$SIM_FILE")
    assert_contains "$err" "$wire" \
      "the $mode warning must quote the exact text that may remain in the composer"
    assert_contains "$err" 'NOT part of the message' \
      "the $mode warning must say which part of that text is the suffix"
  done
  sim_reset capture-after-write-fails
  err=$(sim_send "$DELTA_PAYLOAD" 2>&1 >/dev/null)
  assert_not_contains "$err" 'verification suffix' \
    "a self-proving payload failure must not claim that a suffix was stranded"
  pass "fm_composer_typed_delivery_core: every stranded suffix path is named on stderr"
}

test_delta_verdict_normalizes_payload_and_screen_identically() {
  local payload verdict
  payload=$'draw │ a ╰ box ┃ then ▀ stop  END-MARK-3XQ'
  verdict=$(fm_composer_delivery_delta_verdict $'╭──╮\n│  │\n╰──╯' \
    $'╭──╮\n│ > draw a box then stop END-MARK-3XQ │\n╰──╯' "$payload") \
    || fail "a payload containing box glyphs must still match a rendered composer, got '$verdict'"
  pass "fm_composer_delivery_delta_verdict: box glyphs in the payload vanish on both sides, not just one"
}

test_post_enter_classifier_does_not_emit_pre_type_gate() {
  local screen verdict
  screen=$(cat "$DELTA_FIXTURES/claude-trust.before.plain")
  fm_composer_screen_is_gated "$screen" || fail "the fixture must remain a recognized launch gate"
  verdict=$(fm_composer_classify_screen "$CAPS_PLAIN" "$screen")
  [ "$verdict" != gated ] \
    || fail "the post-Enter classifier must not emit the pre-type gated verdict"
  pass "fm_composer_classify_screen: pre-type gate verdicts do not leak post-Enter"
}

test_gate_ignores_transcript_signals_above_healthy_composer() {
  local screen verdict
  screen=$'Normal response:\n1. Keep the first item\n2. Keep the second item\nPress Enter to continue · Esc to cancel\n❯'
  if fm_composer_screen_is_gated "$screen"; then
    fail "numbered response text above a healthy composer must not be combined into a gate"
  fi
  fm_composer_pre_type_ok "$screen" \
    || fail "transcript gate-like text must not block typing into the current composer"
  verdict=$(fm_composer_classify_screen "$CAPS_PLAIN" "$screen")
  [ "$verdict" = empty ] \
    || fail "transcript gate-like text must not override the healthy composer, got '$verdict'"
  pass "fm_composer_screen_is_gated: only current modal evidence is combined"
}

test_post_enter_classifier_does_not_emit_pre_type_gate
test_gate_ignores_transcript_signals_above_healthy_composer
test_delta_verdict_matches_real_harness_captures
test_delta_verdict_survives_opencode_wrap_and_furniture
test_delta_verdict_refuses_a_swallow_the_gate_scorer_misses
test_gated_trust_dialog_is_refused_before_typing_and_after
test_scrollback_copy_of_the_payload_cannot_prove_delivery
test_occurrence_count_refuses_when_novelty_is_defeated
test_partial_write_of_the_payload_is_refused
test_shape_free_echo_is_accepted
test_delta_verdict_fails_loud_on_an_empty_payload
test_delta_verdict_refuses_short_collision_anchor
test_envelope_gives_a_short_payload_a_full_length_anchor
test_envelope_leaves_a_self_proving_payload_alone
test_envelope_refuses_a_short_multi_row_payload
test_envelope_boundary_verdict_pins_both_checkpoints
SIM_DIR=$(mktemp -d)
trap 'rm -rf "$SIM_DIR"' EXIT
test_core_delivers_a_short_steer_and_leaves_no_residue
test_core_delivers_a_self_proving_steer_untouched
test_core_refuses_a_swallowed_send
test_core_refuses_a_scrollback_copy_of_the_payload
test_core_refuses_a_gated_pane_without_typing
test_core_refuses_when_no_absent_boundary_probe_exists
test_core_refuses_a_short_steer_when_the_backend_cannot_erase
test_core_two_checkpoint_erase_refuses_both_directions
test_core_reports_a_failed_erase_as_typed_unproven
test_core_names_the_stranded_suffix_on_stderr
test_delta_verdict_normalizes_payload_and_screen_identically

# A single-row composer that horizontally SCROLLS shows only a window of its
# buffer, so the anchor has to be short enough to fit inside that window or a
# perfectly healthy steer is refused. This pins the constraint that sets
# FM_COMPOSER_DELTA_ANCHOR_MAX, measured against the shape firstmate's own
# away-mode end-to-end reference draws (tests/fm-afk-inject-herdr-e2e.test.sh).
# The assertion deliberately proves the window really is narrower than the
# payload first, so it cannot pass vacuously if the fixture is ever widened.
test_narrow_scrolling_composer_still_accepts() {
  local payload window before after verdict anchor
  payload='Supervisor escalate (1 event(s)): fake-c1: done: PR https://example.test/pr/100 (pre-read; re-arm not needed - watcher daemon-managed)'
  # 40 visible columns: three characters of ellipsis plus the last 37 typed.
  window="...${payload: -37}"
  before=$'transcript line\n\xe2\x9d\xaf '
  after=$'transcript line\n\xe2\x9d\xaf '"$window"
  anchor=$(fm_composer_payload_tail_anchor "$payload")
  [ "${#anchor}" -eq "$FM_COMPOSER_DELTA_ANCHOR_MAX" ] \
    || fail "this case only means anything while the payload is longer than the anchor cap"
  case "$after" in
    *"$payload"*) fail "the scrolled fixture must NOT contain the whole payload, or it proves nothing" ;;
  esac
  verdict=$(fm_composer_delivery_delta_verdict "$before" "$after" "$payload") \
    || fail "a healthy steer into a narrow horizontally-scrolling composer must be accepted, got '$verdict'"
  pass "fm_composer_delivery_delta_verdict: a narrow single-row composer that scrolls its buffer still proves delivery"
}

test_narrow_scrolling_composer_still_accepts
