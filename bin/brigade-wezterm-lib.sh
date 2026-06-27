#!/usr/bin/env bash
# brigade-wezterm-lib.sh — shared WezTerm pane primitives for brigade.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by the away-mode
# daemon (bin/brigade-supervise-daemon.sh) and bin/brigade-send.sh so the
# composer/submit logic cannot drift between the two.
#
# WezTerm pane operations:
#   - Get text:   wezterm cli get-text --pane-id <id>      (plain, no ANSI)
#   - Send text:  wezterm cli send-text --pane-id <id> --no-paste [text]
#                 (or via stdin when text contains special chars)
#   - Kill pane:  wezterm cli kill-pane --pane-id <id>
#   - Rename tab: wezterm cli set-tab-title --pane-id <id> <title>
#   - List panes: wezterm cli list [--format json]
#
# Pane targeting: WezTerm CLI accepts --pane-id directly. No focus step needed.
# Brigade tracks pane IDs in state/<id>.meta (pane=<wezterm-pane-id>).
#
# Tab state convention (AGENTS.md):
#   ⏳ <name>  — working
#   🔴 <name>  — needs input
#   ✅ <name>  — done
#
# Line cooks rename their tab with:
#   wezterm cli set-tab-title --pane-id "$WEZTERM_PANE" "✅ brigade-<id>"
#
# CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false is set in the claude launch
# command (see brigade-spawn.sh) to prevent ghost/autocomplete text appearing
# in get-text output and being misread as real pending input.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer line
# after border stripping. FM_BUSY_REGEX overrides the busy footer set.
#
# All functions are `set -u` and `set -e` safe (guarded wezterm calls,
# explicit returns) so they can be sourced into either context.

FM_WEZTERM_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.'

# ---------------------------------------------------------------------------
# fm_wezterm_dump_pane: dump the visible screen of a pane to stdout.
# ---------------------------------------------------------------------------
fm_wezterm_dump_pane() {  # <pane-id>
  local pane_id=$1
  wezterm cli get-text --pane-id "$pane_id" 2>/dev/null
}

# ---------------------------------------------------------------------------
# fm_wezterm_composer_state: classify the cursor/composer line of a pane.
# Returns: empty | pending | unknown
# Reads the last few lines of the pane and checks the bottom-most non-blank line.
# ---------------------------------------------------------------------------
fm_wezterm_composer_state() {  # <pane-id> -> empty|pending|unknown
  local pane_id=$1 raw line stripped

  raw=$(wezterm cli get-text --pane-id "$pane_id" 2>/dev/null) || {
    printf 'unknown'; return 0
  }

  # Get the last non-empty line (the composer line)
  line=$(printf '%s\n' "$raw" | grep -v '^[[:space:]]*$' | tail -1 || true)
  [ -n "$line" ] || { printf 'empty'; return 0; }

  # Strip composer box borders (Claude Code input box uses │ ┃ | characters)
  stripped=${line//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  # Trim whitespace
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"

  [ -n "$stripped" ] || { printf 'empty'; return 0; }

  if [ -n "${FM_COMPOSER_IDLE_RE:-}" ] \
     && printf '%s' "$stripped" | grep -qiE "$FM_COMPOSER_IDLE_RE"; then
    printf 'empty'; return 0
  fi

  case "$stripped" in
    '>'|'❯'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac

  if printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_WEZTERM_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi

  printf 'pending'; return 0
}

# ---------------------------------------------------------------------------
# fm_pane_input_pending: true if the cursor line holds real unsubmitted text.
# ---------------------------------------------------------------------------
fm_pane_input_pending() {  # <pane-id>
  [ "$(fm_wezterm_composer_state "$1")" = pending ]
}

# ---------------------------------------------------------------------------
# fm_pane_is_busy: true if the pane's last lines show a busy footer.
# ---------------------------------------------------------------------------
fm_pane_is_busy() {  # <pane-id>
  local pane_id=$1 tail40
  tail40=$(wezterm cli get-text --pane-id "$pane_id" 2>/dev/null | tail -40) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_WEZTERM_BUSY_REGEX_DEFAULT}"
}

# ---------------------------------------------------------------------------
# fm_wezterm_send_enter: send Enter (carriage return) to a pane.
# ---------------------------------------------------------------------------
fm_wezterm_send_enter() {  # <pane-id>
  printf '\r' | wezterm cli send-text --pane-id "$1" --no-paste 2>/dev/null
}

# ---------------------------------------------------------------------------
# fm_wezterm_submit_enter_core: send Enter, verify composer cleared, retry.
# ---------------------------------------------------------------------------
fm_wezterm_submit_enter_core() {  # <pane-id> <retries> <enter-sleep>
  local pane_id=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    fm_wezterm_send_enter "$pane_id" || true
    sleep "$sleep_s"
    state=$(fm_wezterm_composer_state "$pane_id")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# ---------------------------------------------------------------------------
# fm_wezterm_submit_core: type text into pane ONCE, send Enter, verify.
# Returns verdict: empty|pending|unknown|send-failed
# ---------------------------------------------------------------------------
fm_wezterm_submit_core() {  # <pane-id> <text> <retries> <enter-sleep> <settle>
  local pane_id=$1 text=$2 retries=$3 sleep_s=$4 settle=$5

  # Send text to the pane
  if ! printf '%s' "$text" | wezterm cli send-text --pane-id "$pane_id" --no-paste 2>/dev/null; then
    printf 'send-failed'; return 0
  fi
  sleep "$settle"
  fm_wezterm_submit_enter_core "$pane_id" "$retries" "$sleep_s"
}

# ---------------------------------------------------------------------------
# fm_wezterm_pane_alive: true if the given pane-id exists in the WezTerm session.
# ---------------------------------------------------------------------------
fm_wezterm_pane_alive() {  # <pane-id>
  local pane_id=$1
  wezterm cli list 2>/dev/null | awk 'NR>1 { print $3 }' | grep -qx "$pane_id"
}
