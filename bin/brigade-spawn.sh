#!/usr/bin/env bash
# Spawn a direct report: a line cook in a worktrunk worktree, or a sous-chef in
# its isolated brigade home.
# Usage: brigade-spawn.sh <ticket-id> <project-dir> [harness|launch-command] [--scout]
#        brigade-spawn.sh <ticket-id> [<brigade-home>] [harness|launch-command] --sous-chef
#   With no harness arg, the harness comes from brigade-harness.sh kitchen (config/kitchen-harness,
#   falling back to brigade's own harness). A bare adapter name (claude|codex|
#   opencode|pi) overrides it for this spawn. A non-flag string containing whitespace
#   is treated as a RAW launch command - the escape hatch for verifying new adapters.
#   --scout records kind=scout in the ticket's meta (report deliverable, scratch worktree;
#   see AGENTS.md ticket lifecycle); --sous-chef records kind=sous-chef and launches in a
#   provisioned brigade home; the default is kind=fire.
#   Ship/scout spawns refuse to launch after wt switch --create unless the resolved pane
#   path is a real git worktree root distinct from the primary project checkout.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     brigade-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-ticket mode, so the single path stays the only
#   source of truth; a shared --scout applies to every pair. The loop lives here, in bash,
#   so callers never hand-write a multi-ticket shell loop (the tool shell is zsh, which does
#   not word-split unquoted $vars and silently breaks ad-hoc `for ... in $pairs` loops).
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<ticket-id>/brief.md
#     __TURNEND__  absolute path to state/<ticket-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<ticket-id>.pi-ext.ts (pi turn-end extension,
#                  written by this script; outside the worktree to avoid pi's trust gate)
# Per-harness turn-end hooks are installed automatically; some live outside the worktree.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|sous-chef> mode=<mode> yolo=<on|off> window=<session:window> worktree=<path>
# mode/yolo are resolved per-project from data/projects.md for ship/scout tickets;
# sous-chef spawns record mode=sous-chef, yolo=off, home=, and projects=.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
SUB_HOME_MARKER=".brigade-sous-chef-home"
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/brigade-guard.sh" || true
KIND=fire
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --sous-chef) KIND=sous-chef ;;
    *) POS+=("$a") ;;
  esac
done

# Batch dispatch (see header): when the first positional is an `id=repo` pair, treat every
# positional as one and spawn each by re-execing this script in single-ticket mode. We use
# the FM_ROOT path (not $0) so it works whatever cwd or relative path invoked us, and reuse
# the single path verbatim. A failed pair is reported and skipped; the rest still launch;
# exit is non-zero if any pair failed. Single-ticket invocations never carry an '=' in arg
# one (ticket ids are bare slugs), so they fall straight through to the logic below.
idpart=${POS[0]:-}
idpart=${idpart%%=*}
if [ "${#POS[@]}" -gt 0 ] && [ "${POS[0]}" != "$idpart" ] && case "$idpart" in */*) false ;; *) true ;; esac; then
  rc=0
  for pair in "${POS[@]}"; do
    case "$pair" in
      *=*) : ;;
      *) echo "error: batch dispatch expects every argument as id=repo; got '$pair'" >&2; rc=2; continue ;;
    esac
    if [ "$KIND" = sous-chef ]; then
      echo "error: batch dispatch does not support --sous-chef; spawn each sous-chef explicitly" >&2
      rc=2
      continue
    elif [ "$KIND" = scout ]; then
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/brigade-spawn.sh" "${pair%%=*}" "${pair#*=}" --scout; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    else
      if FM_SPAWN_NO_GUARD=1 "$FM_ROOT/bin/brigade-spawn.sh" "${pair%%=*}" "${pair#*=}"; then :; else echo "batch: FAILED to spawn ${pair%%=*} (${pair#*=})" >&2; rc=1; fi
    fi
  done
  exit "$rc"
fi
ID=${POS[0]}
PROJ=
ARG3=
BRIGADE_HOME=

if [ "$KIND" = sous-chef ]; then
  case "${POS[1]:-}" in
    ''|claude|codex|opencode|pi)
      ARG3=${POS[1]:-}
      ;;
    *' '*)
      if [ "${#POS[@]}" -gt 2 ] || [ -d "${POS[1]}" ]; then
        BRIGADE_HOME=${POS[1]}
        ARG3=${POS[2]:-}
      else
        ARG3=${POS[1]}
      fi
      ;;
    *)
      BRIGADE_HOME=${POS[1]}
      ARG3=${POS[2]:-}
      ;;
  esac
else
  PROJ=${POS[1]}
  ARG3=${POS[2]:-}
fi

# The verified launch command per adapter. The knowledge half of each adapter
# (busy signature, exit command, dialogs, quirks) lives in the harness-adapters skill.
launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the line cook pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # brigade captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this brigade-launched agent; it never touches the head chef's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in brigade-zellij-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "$(cat __BRIEF__)"' ;;
    codex)
      if [ "$kind" = sous-chef ]; then
        printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox "$(cat __BRIEF__)"'
      else
        printf '%s' 'codex --dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(cat __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode --prompt "$(cat __BRIEF__)"' ;;
    pi)
      if [ "$kind" = sous-chef ]; then
        printf '%s' 'pi "$(cat __BRIEF__)"'
      else
        printf '%s' 'pi -e __PIEXT__ "$(cat __BRIEF__)"'
      fi
      ;;
    *) return 1 ;;
  esac
}

case "$ARG3" in
  *' '*)  # raw launch command (unverified-adapter escape hatch)
    LAUNCH=$ARG3
    HARNESS=""
    for word in $LAUNCH; do
      case "$word" in [A-Za-z_]*=*) continue ;; *) HARNESS=$(basename "$word"); break ;; esac
    done
    ;;
  '')
    HARNESS=$("$FM_ROOT/bin/brigade-harness.sh" kitchen)
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: no launch template for harness '$HARNESS' (from config/kitchen-harness or detection); pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
  *)
    HARNESS=$ARG3
    LAUNCH=$(launch_template "$HARNESS" "$KIND") || { echo "error: unknown harness '$HARNESS'; pass a raw launch command to use an unverified adapter" >&2; exit 1; }
    ;;
esac

sous-chef_registry_value() {
  local id=$1 key=$2 reg line value
  reg="$DATA/sous-chefs.md"
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: \([^;)]*\);.*/\1/p') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/^[^(]*(home: [^;)]*; scope: [^;)]*; projects: \([^;)]*\); added .*/\1/p') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || { echo "error: brigade home does not exist or is not a directory: $path" >&2; return 1; }
  cd "$path" && pwd -P
}

resolve_project_dir_arg() {
  local path=$1
  case "$path" in
    projects/*) printf '%s/%s\n' "$PROJECTS" "${path#projects/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

validate_brigade_home_for_spawn() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  abs_home=$(resolved_existing_dir "$home") || return 1
  abs_active_home=$(resolved_existing_dir "$FM_HOME")
  abs_root=$(resolved_existing_dir "$FM_ROOT")
  if [ "$abs_home" = "/" ]; then
    echo "error: sous-chef home cannot be the filesystem root: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    echo "error: sous-chef home cannot be the active brigade home: $home" >&2
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    echo "error: sous-chef home cannot be the brigade repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    echo "error: sous-chef home cannot be inside the active brigade home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    echo "error: sous-chef home cannot be inside the brigade repo: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    echo "error: sous-chef home cannot be an ancestor of the active brigade home: $home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    echo "error: sous-chef home cannot be an ancestor of the brigade repo: $home" >&2
    return 1
  fi
  validate_brigade_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    echo "error: brigade home $home is not a seeded sous-chef home" >&2
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    echo "error: brigade home $home is marked for sous-chef ${marker_id:-unknown}, expected $id" >&2
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    echo "error: $home is not a brigade home (missing AGENTS.md)" >&2
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    echo "error: $home is not a brigade home (missing bin/)" >&2
    return 1
  fi
  printf '%s\n' "$abs_home"
}

validate_brigade_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "error: sous-chef $name directory must resolve inside the sous-chef home: $dir" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "error: sous-chef $name path is not a directory: $dir" >&2
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "error: sous-chef $name directory must resolve inside the sous-chef home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      echo "error: sous-chef $name directory cannot be inside the active brigade home: $dir" >&2
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      echo "error: sous-chef $name directory cannot be inside the brigade repo: $dir" >&2
      return 1
    fi
  done
}

if [ "$KIND" = sous-chef ]; then
  if [ -z "$BRIGADE_HOME" ] && [ -f "$STATE/$ID.meta" ]; then
    BRIGADE_HOME=$(grep '^home=' "$STATE/$ID.meta" | cut -d= -f2- || true)
  fi
  if [ -z "$BRIGADE_HOME" ]; then
    BRIGADE_HOME=$(sous-chef_registry_value "$ID" home || true)
  fi
fi

if [ "$KIND" = sous-chef ]; then
  [ -n "$BRIGADE_HOME" ] || { echo "error: no brigade home supplied or registered for $ID" >&2; exit 1; }
  PROJ_ABS=$(validate_brigade_home_for_spawn "$ID" "$BRIGADE_HOME")
  WT="$PROJ_ABS"
  if [ -f "$PROJ_ABS/data/charter.md" ]; then
    BRIEF="$PROJ_ABS/data/charter.md"
  else
    BRIEF="$DATA/$ID/brief.md"
  fi
else
  PROJ_ABS="$(cd "$(resolve_project_dir_arg "$PROJ")" && pwd)"
  WT=""
  BRIEF="$DATA/$ID/brief.md"
fi
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

# Open a new Zellij tab named brigade-<id>, cd into the project, run wt.
# Zellij action new-tab opens in the current working directory; we cd in the
# launch command itself to land in the right place.
TAB_NAME="⏳ brigade-$ID"

# Check the tab doesn't already exist
if zellij action list-tabs 2>/dev/null | grep -qF "$TAB_NAME"; then
  echo "error: Zellij tab '$TAB_NAME' already exists" >&2
  exit 1
fi

# Open new tab — Zellij sets the tab name and cwd via the action flags.
# --cwd sets the working directory for the new pane's shell.
zellij action new-tab --name "$TAB_NAME" --cwd "$PROJ_ABS"
sleep 0.5  # Let the shell initialise before we send commands

# Get the pane id of the newly focused pane in this tab.
# Zellij assigns an incrementing numeric pane id; we read it from the focused pane.
PANE_ID=$(zellij action dump-screen /dev/stderr 2>&1 >/dev/null | head -0; \
          zellij query --focused-pane 2>/dev/null | grep '^pane_id' | cut -d= -f2 || true)
# Fallback: if query is unavailable, use a state file written by the tab itself.
# For now record PANE_ID as "tab:$TAB_NAME" — brigade-peek/send resolve it.
[ -n "$PANE_ID" ] || PANE_ID="tab:$TAB_NAME"

if [ "$KIND" != sous-chef ]; then
  # Use wt switch --create to get a worktree via Worktrunk.
  # wt switch --create <branch> checks out an isolated worktree on a new branch
  # named after the ticket id, cd-ing the shell into it.
  zellij action write-chars "cd $(printf '%s' "$PROJ_ABS" | sed 's/ /\\ /g') && wt switch --create brigade/$ID"
  sleep 0.3
  zellij action write 13  # Enter

  # Wait for Worktrunk to finish and the cwd to move to the worktree.
  # wt switch --create prints the worktree path on stdout; we poll for it.
  WTFILE=$(mktemp /tmp/brigade-wt-XXXXXX.txt)
  WT=
  for _ in $(seq 1 60); do
    sleep 1
    zellij action dump-screen "$WTFILE" 2>/dev/null || true
    # wt switch --create prints: "worktree @ <path>"
    candidate=$(grep -oP '(?<=worktree @ )\S+' "$WTFILE" 2>/dev/null | tail -1 || \
                grep -oE 'worktree @ [^ ]+' "$WTFILE" 2>/dev/null | sed 's/worktree @ //' | tail -1 || true)
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
      WT="$candidate"
      break
    fi
  done
  rm -f "$WTFILE"

  if [ -z "$WT" ]; then
    # Last resort: look up the worktree path via git's own porcelain
    WT=$(git -C "$PROJ_ABS" worktree list --porcelain 2>/dev/null | \
         awk '/^worktree /{p=$2} /^branch /{if($2=="refs/heads/brigade/'"$ID"'"){print p;exit}}')
  fi

  if [ -z "$WT" ]; then
    echo "error: wt switch --create brigade/$ID did not produce a worktree within 60s; inspect tab '$TAB_NAME'" >&2
    exit 1
  fi

  # Isolation guard: WT must be a real git worktree root, distinct from PROJ_ABS.
  wt_real=
  if ! wt_real=$(cd "$WT" 2>/dev/null && pwd -P); then wt_real=; fi
  proj_real=
  if ! proj_real=$(cd "$PROJ_ABS" 2>/dev/null && pwd -P); then proj_real=; fi
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top_real=
  if ! wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P); then wt_top_real=; fi
  if [ -z "$wt_real" ] || [ -z "$wt_top_real" ] || [ "$wt_real" != "$wt_top_real" ] || [ "$wt_real" = "$proj_real" ]; then
    echo "error: wt switch --create did not yield an isolated worktree (resolved '$WT'; worktree root '${wt_top:-none}'; primary '$PROJ_ABS'); refusing to launch to avoid tangling the primary checkout. Inspect tab '$TAB_NAME'" >&2
    exit 1
  fi

  # Install Recipe (AGENTS.md) into the worktree if one exists for this project.
  "$FM_ROOT/bin/brigade-recipe.sh" install "$WT" "$(basename "$PROJ_ABS")" 2>/dev/null || true
fi

# Per-harness turn-end hook: a file that touches state/<id>.turn-ended when the
# agent finishes a turn. Worktree-resident hooks are kept out of git's view so
# they never block teardown's dirty check or leak into a commit.
TURNEND="$STATE/$ID.turn-ended"
exclude_path() {
  local rel=$1 EXCL
  EXCL=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$EXCL" ] || return 0
  mkdir -p "$(dirname "$EXCL")"
  grep -qxF "$rel" "$EXCL" 2>/dev/null || echo "$rel" >> "$EXCL"
}
if [ "$KIND" != sous-chef ]; then
  case "$HARNESS" in
    claude*)
      mkdir -p "$WT/.claude"
      cat > "$WT/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '$TURNEND'"}]}]}}
EOF
      exclude_path '.claude/settings.local.json'
      ;;
    opencode*)
      mkdir -p "$WT/.opencode/plugins"
      cat > "$WT/.opencode/plugins/brigade-turn-end.js" <<EOF
export const FmTurnEnd = async ({ \$ }) => ({
  event: async ({ event }) => {
    if (event.type === "session.idle") await \$\`touch $TURNEND\`
  },
})
EOF
      exclude_path '.opencode/plugins/brigade-turn-end.js'
      ;;
    pi*)
      # Written OUTSIDE the worktree: pi's project-trust gate fires on any extension
      # loaded from inside the project (verified live), but an explicit -e path
      # elsewhere loads without a dialog. Lives in state/, cleaned by teardown.
      cat > "$STATE/$ID.pi-ext.ts" <<EOF
// Brigade turn-end signal; written by brigade-spawn.
// Use "turn_end" (fires after each turn the agent finishes), not "agent_end"
// (fires once, only when the whole run exits): the watcher needs a signal at
// every turn boundary so an idle line cook is surfaced, not just at shutdown.
import { execFile } from "node:child_process";
export default function (pi: any) {
  pi.on("turn_end", () => execFile("touch", ["$TURNEND"]));
}
EOF
      ;;
    codex*)
      # codex: turn-end rides the launch command via -c notify=[...] and __TURNEND__.
      ;;
  esac
fi

# Per-project delivery mode + yolo flag (bin/brigade-project-mode.sh; AGENTS.md project management and ticket lifecycle).
# Recorded in meta so brigade-teardown's safety check and the validate/merge stages can
# branch on them. Mode governs ship tickets; a scout's deliverable is a report, not a
# merge, so scout teardown ignores mode.
SECONDMATE_PROJECTS=
if [ "$KIND" = sous-chef ]; then
  MODE=sous-chef
  YOLO=off
  SECONDMATE_PROJECTS=$(sous-chef_registry_value "$ID" projects || true)
else
  PROJ_NAME=$(basename "$PROJ_ABS")
  read -r MODE YOLO <<EOF
$("$FM_ROOT/bin/brigade-project-mode.sh" "$PROJ_NAME")
EOF
fi

mkdir -p "$STATE"
{
  echo "pane=$PANE_ID"
  echo "tab=$TAB_NAME"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  if [ "$KIND" = sous-chef ]; then
    echo "home=$PROJ_ABS"
    echo "projects=$SECONDMATE_PROJECTS"
  fi
} > "$STATE/$ID.meta"

sq_brief=$(shell_quote "$BRIEF")
sq_turnend=$(shell_quote "$TURNEND")
sq_piext=$(shell_quote "$STATE/$ID.pi-ext.ts")
LAUNCH=${LAUNCH//__BRIEF__/$sq_brief}
LAUNCH=${LAUNCH//__TURNEND__/$sq_turnend}
LAUNCH=${LAUNCH//__PIEXT__/$sq_piext}
if [ "$KIND" = sous-chef ]; then
  sq_home=$(shell_quote "$PROJ_ABS")
  LAUNCH="FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_HOME=$sq_home $LAUNCH"
fi

# Focus the pane and launch the agent
zellij action focus-terminal-pane "$PANE_ID" 2>/dev/null || true
zellij action write-chars "$LAUNCH"
sleep 0.3
zellij action write 13  # Enter

echo "spawned $ID harness=$HARNESS kind=$KIND mode=$MODE yolo=$YOLO tab=$TAB_NAME pane=$PANE_ID worktree=$WT"
