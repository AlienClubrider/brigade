#!/usr/bin/env bash
# brigade-recipe.sh — manage Recipes (AGENTS.md) for a project worktree.
#
# The Recipe system gives every line cook your personal project conventions
# without touching your team's repo. Recipes live in:
#   ~/.brigade/recipes/<repo-name>/AGENTS.md
#
# On worktree creation (post-start hook): copy the Recipe into the worktree
# root as AGENTS.md, and add AGENTS.md to .git/info/exclude so it is never
# staged, committed, or pushed to your team.
#
# On worktree removal (pre-remove hook): delete the AGENTS.md copy from the
# worktree so the pool slot is clean when Worktrunk recycles it.
#
# Usage (called by Worktrunk hooks in wt.toml):
#   brigade-recipe.sh install <worktree-path> [repo-name]
#   brigade-recipe.sh remove  <worktree-path>
#
# Can also be run directly:
#   brigade-recipe.sh edit   <repo-name>    — open or create a Recipe in $EDITOR
#   brigade-recipe.sh show   <repo-name>    — print the Recipe path and contents
#   brigade-recipe.sh list                  — list all Recipes
#
# Repo name defaults to the basename of the worktree's git toplevel.
set -eu

RECIPE_HOME="${BRIGADE_RECIPE_HOME:-${HOME}/.brigade/recipes}"

usage() {
  echo "usage: brigade-recipe.sh <install|remove|edit|show|list> [args]" >&2
  exit 1
}

repo_name_from_worktree() {
  local wt=$1
  # Walk up to git toplevel, use its basename
  local toplevel
  toplevel=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$toplevel" ]; then
    basename "$toplevel"
  else
    basename "$wt"
  fi
}

recipe_path() {
  local repo=$1
  echo "$RECIPE_HOME/$repo/AGENTS.md"
}

exclude_from_git() {
  local wt=$1 rel=$2
  local excl
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$excl" ] || return 0
  mkdir -p "$(dirname "$excl")"
  grep -qxF "$rel" "$excl" 2>/dev/null || echo "$rel" >> "$excl"
}

cmd=${1:-}
[ -n "$cmd" ] || usage

case "$cmd" in

  install)
    WT=${2:-}
    [ -n "$WT" ] || { echo "brigade-recipe.sh install: missing <worktree-path>" >&2; exit 1; }
    [ -d "$WT" ] || { echo "brigade-recipe.sh install: worktree path does not exist: $WT" >&2; exit 1; }
    REPO=${3:-$(repo_name_from_worktree "$WT")}
    RECIPE=$(recipe_path "$REPO")

    if [ ! -f "$RECIPE" ]; then
      # No Recipe for this repo — nothing to install. Silent.
      exit 0
    fi

    TARGET="$WT/AGENTS.md"
    if [ -f "$TARGET" ]; then
      # Worktree already has an AGENTS.md (tracked by the project). Don't overwrite.
      # Print a note so the head chef knows the Recipe was not applied.
      echo "brigade-recipe: $REPO worktree already has AGENTS.md (project-tracked); Recipe not installed. To use your Recipe, remove the project's AGENTS.md from the worktree or rename it." >&2
      exit 0
    fi

    cp "$RECIPE" "$TARGET"
    exclude_from_git "$WT" "AGENTS.md"
    echo "brigade-recipe: installed Recipe for $REPO into $TARGET"
    ;;

  remove)
    WT=${2:-}
    [ -n "$WT" ] || { echo "brigade-recipe.sh remove: missing <worktree-path>" >&2; exit 1; }

    TARGET="$WT/AGENTS.md"
    if [ ! -f "$TARGET" ]; then
      exit 0
    fi

    # Only remove if it is excluded from git (i.e. it is our Recipe copy, not a project file).
    REPO=$(repo_name_from_worktree "$WT" 2>/dev/null || true)
    RECIPE=$(recipe_path "${REPO:-__unknown__}")
    excl=$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null || true)
    is_excluded=0
    if [ -n "$excl" ] && [ -f "$excl" ] && grep -qxF "AGENTS.md" "$excl" 2>/dev/null; then
      is_excluded=1
    fi

    if [ "$is_excluded" -eq 1 ]; then
      rm -f "$TARGET"
      echo "brigade-recipe: removed Recipe copy from $WT"
    else
      # Not our file — leave it alone.
      echo "brigade-recipe: AGENTS.md in $WT is not gitignored — not removing (project-tracked file)" >&2
    fi
    ;;

  edit)
    REPO=${2:-}
    [ -n "$REPO" ] || { echo "brigade-recipe.sh edit: missing <repo-name>" >&2; exit 1; }
    RECIPE=$(recipe_path "$REPO")
    mkdir -p "$(dirname "$RECIPE")"
    if [ ! -f "$RECIPE" ]; then
      # Seed a starter Recipe
      cat > "$RECIPE" <<'STARTER'
# Recipe for __REPO__
#
# This is your personal AGENTS.md for this project.
# It is copied into every worktree at spawn time (brigade-recipe install)
# and removed before the worktree is returned to the pool.
# Your team never sees it — it lives only in ~/.brigade/recipes/<repo>/.
#
# Put your project conventions, preferred patterns, testing commands,
# and anything you want every line cook to know about this codebase here.

## Project conventions

<!-- Add your conventions here -->

## Testing

<!-- Add test commands here -->

## Branch naming

Branches must follow the pattern: brigade/<ticket-id>
STARTER
      sed -i "s/__REPO__/$REPO/g" "$RECIPE"
      echo "Created new Recipe at $RECIPE"
    fi
    ${EDITOR:-vi} "$RECIPE"
    ;;

  show)
    REPO=${2:-}
    [ -n "$REPO" ] || { echo "brigade-recipe.sh show: missing <repo-name>" >&2; exit 1; }
    RECIPE=$(recipe_path "$REPO")
    if [ ! -f "$RECIPE" ]; then
      echo "No Recipe for $REPO (expected at $RECIPE)" >&2
      exit 1
    fi
    echo "Recipe: $RECIPE"
    echo "---"
    cat "$RECIPE"
    ;;

  list)
    if [ ! -d "$RECIPE_HOME" ]; then
      echo "No Recipes yet. Create one with: brigade-recipe.sh edit <repo-name>"
      exit 0
    fi
    found=0
    for recipe in "$RECIPE_HOME"/*/AGENTS.md; do
      [ -f "$recipe" ] || continue
      repo=$(basename "$(dirname "$recipe")")
      echo "$repo  →  $recipe"
      found=1
    done
    [ "$found" -eq 1 ] || echo "No Recipes yet. Create one with: brigade-recipe.sh edit <repo-name>"
    ;;

  *)
    usage
    ;;
esac
