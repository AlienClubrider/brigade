#!/usr/bin/env bash
# Composer state tests for WezTerm pane model.
#
# In the WezTerm model, `wezterm cli get-text` returns plain text with no ANSI
# escape codes. Ghost/autocomplete text is suppressed at the source by the
# CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false env var set in brigade-spawn.sh.
#
# These tests pin two guarantees:
#   1. fm_wezterm_composer_state correctly classifies empty, pending, and busy
#      panes from plain text input (no ANSI stripping needed).
#   2. fm_pane_input_pending correctly detects pending user input.
#   3. brigade-peek.sh output is always plain (no ANSI escape codes).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/brigade-wezterm-lib.sh"
PEEK="$ROOT/bin/brigade-peek.sh"

# shellcheck source=bin/brigade-wezterm-lib.sh
. "$LIB"

TMP_ROOT=$(fm_test_tmproot brigade-ghost-tests)

# Create a fake `wezterm` binary that returns a preset plain-text pane dump.
# The fake only handles `cli get-text --pane-id <id>` — other subcommands are
# no-ops so the suite can use the pane-id as a fixture key.
make_fake_wezterm() {  # <dir>
  local dir=$1 fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/wezterm" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = cli ] && [ "${2:-}" = get-text ]; then
  f="${FM_FAKE_PANE_TEXT:-/dev/null}"
  cat "$f" 2>/dev/null
  exit 0
fi
exit 0
SH
  chmod +x "$fb/wezterm"
  printf '%s\n' "$fb"
}

# --- fm_wezterm_composer_state -----------------------------------------------

test_empty_prompt_glyph_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/prompt-glyph"; mkdir -p "$dir"
  fb=$(make_fake_wezterm "$dir")
  capture="$dir/pane.txt"
  printf 'some output\n❯ \n' > "$capture"
  state=$(PATH="$fb:$PATH" FM_FAKE_PANE_TEXT="$capture" fm_wezterm_composer_state "42")
  [ "$state" = empty ] || fail "bare prompt glyph should be empty, got: $state"
  pass "fm_wezterm_composer_state: bare prompt glyph (❯) is empty"
}

test_empty_dollar_prompt_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/dollar-prompt"; mkdir -p "$dir"
  fb=$(make_fake_wezterm "$dir")
  capture="$dir/pane.txt"
  printf 'some output\n$ \n' > "$capture"
  state=$(PATH="$fb:$PATH" FM_FAKE_PANE_TEXT="$capture" fm_wezterm_composer_state "42")
  [ "$state" = empty ] || fail "bare dollar prompt should be empty, got: $state"
  pass "fm_wezterm_composer_state: bare dollar prompt is empty"
}

test_busy_footer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/busy-footer"; mkdir -p "$dir"
  fb=$(make_fake_wezterm "$dir")
  capture="$dir/pane.txt"
  printf 'Working on your request...\nesc to interrupt\n' > "$capture"
  state=$(PATH="$fb:$PATH" FM_FAKE_PANE_TEXT="$capture" fm_wezterm_composer_state "42")
  [ "$state" = empty ] || fail "busy footer should be empty (not pending), got: $state"
  pass "fm_wezterm_composer_state: busy footer (esc to interrupt) is empty"
}

test_real_text_in_composer_is_pending() {
  local dir fb capture
  dir="$TMP_ROOT/real-text"; mkdir -p "$dir"
  fb=$(make_fake_wezterm "$dir")
  capture="$dir/pane.txt"
  printf 'previous output\n❯ fix findings 1 and 3\n' > "$capture"
  state=$(PATH="$fb:$PATH" FM_FAKE_PANE_TEXT="$capture" fm_wezterm_composer_state "42")
  [ "$state" = pending ] || fail "real typed text should be pending, got: $state"
  pass "fm_wezterm_composer_state: real typed text is pending"
}

test_bordered_empty_composer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/bordered-empty"; mkdir -p "$dir"
  fb=$(make_fake_wezterm "$dir")
  capture="$dir/pane.txt"
  # Claude Code input box with only the prompt glyph inside borders
  printf 'some output\n│ > │\n' > "$capture"
  state=$(PATH="$fb:$PATH" FM_FAKE_PANE_TEXT="$capture" fm_wezterm_composer_state "42")
  [ "$state" = empty ] || fail "bordered empty composer should be empty, got: $state"
  pass "fm_wezterm_composer_state: bordered empty composer (│ > │) is empty"
}

test_bordered_real_text_is_pending() {
  local dir fb capture
  dir="$TMP_ROOT/bordered-real"; mkdir -p "$dir"
  fb=$(make_fake_wezterm "$dir")
  capture="$dir/pane.txt"
  # Bordered composer with real typed text
  printf 'some output\n│ fix findings 1 and 3 │\n' > "$capture"
  state=$(PATH="$fb:$PATH" FM_FAKE_PANE_TEXT="$capture" fm_wezterm_composer_state "42")
  [ "$state" = pending ] || fail "real text in bordered composer should be pending, got: $state"
  pass "fm_wezterm_composer_state: real text in bordered composer is pending"
}

# --- fm_pane_input_pending ---------------------------------------------------

test_pane_input_pending_empty_prompt() {
  local dir fb capture
  dir="$TMP_ROOT/pending-empty"; mkdir -p "$dir"
  fb=$(make_fake_wezterm "$dir")
  capture="$dir/pane.txt"
  printf '❯ \n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_PANE_TEXT="$capture" fm_pane_input_pending "42"; then
    fail "empty prompt was falsely detected as pending"
  fi
  pass "fm_pane_input_pending: empty prompt is NOT pending"
}

test_pane_input_pending_real_text() {
  local dir fb capture
  dir="$TMP_ROOT/pending-real"; mkdir -p "$dir"
  fb=$(make_fake_wezterm "$dir")
  capture="$dir/pane.txt"
  printf '❯ deploy the staging environment\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_PANE_TEXT="$capture" fm_pane_input_pending "42" \
    || fail "real typed text was not detected as pending"
  pass "fm_pane_input_pending: real typed text is pending"
}

# --- brigade-peek.sh: plain output, no ANSI codes ----------------------------

test_peek_output_is_escape_free() {
  local dir fb capture home out
  dir="$TMP_ROOT/peek"; mkdir -p "$dir"
  fb=$(make_fake_wezterm "$dir")
  capture="$dir/pane.txt"
  printf 'normal output line\n❯ some typed text\n' > "$capture"
  home="$dir/home"; mkdir -p "$home/state"
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_FAKE_PANE_TEXT="$capture" \
        "$PEEK" "42" 2>/dev/null)
  ESC=$(printf '\033')
  case "$out" in
    *"$ESC"*) fail "brigade-peek surfaced ANSI escape codes in output" ;;
  esac
  case "$out" in
    *"some typed text"*) : ;;
    *) fail "brigade-peek dropped pane content (expected 'some typed text')" ;;
  esac
  pass "brigade-peek output is escape-free and includes pane content"
}

test_empty_prompt_glyph_is_not_pending
test_empty_dollar_prompt_is_not_pending
test_busy_footer_is_not_pending
test_real_text_in_composer_is_pending
test_bordered_empty_composer_is_not_pending
test_bordered_real_text_is_pending
test_pane_input_pending_empty_prompt
test_pane_input_pending_real_text
test_peek_output_is_escape_free
