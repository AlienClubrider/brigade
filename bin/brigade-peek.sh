#!/usr/bin/env bash
# Print the tail of a line cook pane (bounded, for cheap diagnosis).
# Usage: brigade-peek.sh <ticket-id> [lines=40]
#   <ticket-id> is resolved through this home's state/<id>.meta to get the pane-id.
#   Pass an explicit pane-id (numeric) to target a pane outside this brigade home.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

"$SCRIPT_DIR/brigade-guard.sh" || true

resolve_pane() {
  local arg=$1
  case "$arg" in
    [0-9]*)
      # Already a numeric pane id
      echo "$arg"
      ;;
    brigade-*)
      local meta="$STATE/${arg#brigade-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $arg in $STATE" >&2
        exit 1
      fi
      local pane
      pane=$(grep '^pane=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$pane" ] || { echo "error: no pane recorded in $meta" >&2; exit 1; }
      echo "$pane"
      ;;
    *)
      # Try resolving as a ticket id without the brigade- prefix
      local meta="$STATE/$arg.meta"
      if [ -f "$meta" ]; then
        local pane
        pane=$(grep '^pane=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
        [ -n "$pane" ] || { echo "error: no pane recorded in $meta" >&2; exit 1; }
        echo "$pane"
      else
        echo "error: cannot resolve '$arg' to a pane id" >&2
        exit 1
      fi
      ;;
  esac
}

PANE=$(resolve_pane "$1")
N=${2:-40}

if ! wezterm cli get-text --pane-id "$PANE" 2>/dev/null | tail -"$N"; then
  echo "error: could not get text for pane $PANE" >&2
  exit 1
fi
