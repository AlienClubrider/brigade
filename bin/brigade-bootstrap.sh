#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: brigade-bootstrap.sh
#          Detect: prints one line per problem or capability fact and exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)", "NEEDS_GH_AUTH",
#                 "KITCHEN_HARNESS_OVERRIDE: <name>", "FLEET_SYNC: <repo>: skipped: <reason>",
#                 "TASKS_AXI: available", "TANGLE: <remediation>".
#          A TANGLE line means the brigade primary checkout (FM_ROOT) is stranded
#          on a feature branch instead of its default branch - a line cook's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          wt (worktrunk) is MISSING when the binary is not found.
#          tickets-axi is an OPTIONAL backlog-management capability reported only
#          when tickets-axi --version is 0.1.1 or newer. It is never a MISSING
#          line and never prompts an install.
#          Fleet sync fetches, fast-forwards, and prunes gone local branches;
#          it is bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT, default 20s.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#        brigade-bootstrap.sh install <tool>...
#          Install the named tools (only ones the head chef approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/brigade-tickets-axi-lib.sh
. "$SCRIPT_DIR/brigade-tasks-axi-lib.sh"
# shellcheck source=bin/brigade-tangle-lib.sh
. "$SCRIPT_DIR/brigade-tangle-lib.sh"

fleet_sync() {
  [ -x "$FM_ROOT/bin/brigade-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/brigade-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/brigade-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  timeout=${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-20}
  case "$timeout" in ''|*[!0-9]*) timeout=20 ;; esac
  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
}

install_cmd() {
  case "$1" in
    zellij) echo "brew install zellij  # or: cargo install zellij" ;;
    node|gh) echo "brew install $1  # or the platform's package manager" ;;
    wt) echo "brew install worktrunk" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    *) return 1 ;;
  esac
}

TOOLS="zellij node gh wt no-mistakes gh-axi chrome-devtools-axi"

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: brigade-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    cmd=$(install_cmd "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

for t in $TOOLS; do
  command -v "$t" >/dev/null || echo "MISSING: $t (install: $(install_cmd "$t"))"
done
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
# Worktree-tangle check: the brigade primary checkout (FM_ROOT) must sit on its
# default branch, not a feature branch (see brigade-tangle-lib.sh). Scoped to the
# primary only; detached-HEAD worktrees and sous-chef homes never trip it.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
fi
kitchen_harness=
[ -f "$CONFIG/kitchen-harness" ] && kitchen_harness=$(tr -d '[:space:]' < "$CONFIG/kitchen-harness" || true)
[ -n "$kitchen_harness" ] && [ "$kitchen_harness" != "default" ] && echo "KITCHEN_HARNESS_OVERRIDE: $kitchen_harness"
fm_tasks_axi_compatible && echo "TASKS_AXI: available"
# Expeditor tools (optional — kitchen works without them, but you lose the dashboard and notifications).
command -v dot-agent-deck >/dev/null 2>/dev/null || echo "EXPEDITOR_MISSING: dot-agent-deck (install: brew tap vfarcic/tap && brew install dot-agent-deck && dot-agent-deck hooks install) — see docs/expeditor.md"
[ -f "${HOME}/.local/state/falcode-zellij/falcode-hook.sh" ] || echo "EXPEDITOR_MISSING: falcode-zellij claude hook (install: see docs/expeditor.md)"
fleet_sync
exit 0
