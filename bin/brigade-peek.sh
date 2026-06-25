#!/usr/bin/env bash
# Print the tail of a line cook pane (bounded, for cheap diagnosis).
# Usage: brigade-peek.sh <window> [lines=40]
#   <window> may be a bare brigade window name (brigade-xyz), resolved through
#   this home's state/<id>.meta, or explicit session:window.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

"$SCRIPT_DIR/brigade-guard.sh" || true

resolve() {
  case "$1" in
    *:*) echo "$1" ;;
    brigade-*)
      meta="$STATE/${1#brigade-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $1 in $STATE; pass session:window to target a window outside this brigade home" >&2
        exit 1
      fi
      window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; exit 1; }
      echo "$window"
      ;;
    *) tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$1\$" \
         || { echo "error: no window named $1" >&2; exit 1; } ;;
  esac
}

T=$(resolve "$1")
N=${2:-40}
tmux capture-pane -p -t "$T" -S -"$N"
