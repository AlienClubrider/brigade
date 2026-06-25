#!/usr/bin/env bash
# Promote a scout ticket to a ship ticket in place: the line cook keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<ticket-id>.meta so brigade-teardown.sh applies the full unpushed-work protection
# again. After promoting, send the line cook its ship instructions via brigade-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<ticket-id>, implement, then report done
# according to the project's delivery mode).
# Usage: brigade-promote.sh <ticket-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/brigade-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=fire" >> "$TMP"
mv "$TMP" "$META"

echo "promoted $ID to ship (teardown protection restored)"
echo "next: bin/brigade-send.sh brigade-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
