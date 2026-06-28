#!/usr/bin/env bash
# tests/wake-helpers.sh - shared fixtures and mocks for the wake-queue,
# watcher/lock, and supervise-daemon suites. The fake tmux surfaces here encode
# watcher/daemon/composer behavior, so they live here rather than in the generic
# tests/lib.sh. Generic reporters/assertions come from lib.sh, pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# append_wake <state> <kind> <key> <payload>: append a wake record to the durable
# queue in a subshell scoped to <state>, using the production wake library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4 lib="$ROOT/bin/brigade-wake-lib.sh"
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$lib" "$kind" "$key" "$payload"
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/wezterm" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = cli ] && shift
case "${1:-}" in
  get-text)
    [ -n "${FM_FAKE_WEZTERM_CAPTURE:-}" ] && cat "$FM_FAKE_WEZTERM_CAPTURE"
    exit 0 ;;
  list) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/wezterm"
  printf '%s\n' "$dir"
}

make_supercase() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  # fm_wezterm_composer_state reads the last non-blank line of get-text output.
  # Tests set FM_FAKE_WEZTERM_CAPTURE to a file whose last non-blank line is
  # the composer line under test (no cursor_y logic needed).
  # FM_FAKE_SENT captures sent text (without \r) and [ENTER] markers.
  cat > "$fakebin/wezterm" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = cli ] && shift
case "${1:-}" in
  get-text)
    [ -n "${FM_FAKE_WEZTERM_CAPTURE:-}" ] && cat "$FM_FAKE_WEZTERM_CAPTURE" 2>/dev/null
    exit 0 ;;
  send-text)
    content=$(cat)
    case "$content" in
      $'\r') [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT" ;;
      *)     [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$content" >> "$FM_FAKE_SENT" ;;
    esac
    exit 0 ;;
  list)
    if [ "${FM_FAKE_WEZTERM_PANE_ALIVE:-1}" = "1" ]; then
      printf 'WINID\tTABID\tPANE\tWORKSPACE\tSIZE\tTITLE\tCWD\n'
      printf '0\t0\t%s\tdefault\t80x24\t⏳ brigade\t.\n' "${FM_SUPERVISOR_TARGET:-99}"
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/wezterm"
  printf '%s\n' "$dir"
}

make_bordered_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  printf '│ > │\n' > "$dir/composer"
  # fm_wezterm_submit_core sends text then \r (Enter) via wezterm cli send-text.
  # get-text returns composer state; send-text updates it.
  cat > "$fakebin/wezterm" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
[ "${1:-}" = cli ] && shift
case "${1:-}" in
  get-text)
    cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-text)
    content=$(cat)
    case "$content" in
      $'\r')
        # Carriage return = Enter submission
        if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
          [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
        else
          [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
          printf '│ > │\n' > "$COMPOSER"
        fi
        ;;
      *)
        [ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
        [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$content" >> "$FM_FAKE_SENT"
        printf '│ > %s │\n' "$content" > "$COMPOSER"
        ;;
    esac
    exit 0 ;;
  list)
    if [ "${FM_FAKE_WEZTERM_PANE_ALIVE:-1}" = "1" ]; then
      printf 'WINID\tTABID\tPANE\tWORKSPACE\tSIZE\tTITLE\tCWD\n'
      printf '0\t0\t%s\tdefault\t80x24\t⏳ brigade\t.\n' "${FM_SUPERVISOR_TARGET:-99}"
    fi
    exit 0 ;;
  set-tab-title|spawn|kill-pane) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/wezterm"
  printf '%s\n' "$dir"
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do
    p=$((p + 1))
  done
  printf '%s\n' "$p"
}
