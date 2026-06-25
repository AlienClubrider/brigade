---
name: updatebrigade
description: Self-update a running brigade and its sous-chefs to the latest from origin. Use when the head chef invokes /updatebrigade (e.g. "/updatebrigade", "update brigade", "pull the latest brigade"). Fast-forwards this brigade repo's default branch and every sous-chef home from origin (fast-forward only, never forced, never disruptive), then re-reads AGENTS.md and nudges each updated sous-chef to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
---

# updatebrigade

Self-update brigade in place.
Brigade is its own repo, behind the same no-mistakes gate as any project, so new tracked material (AGENTS.md, bin/, skills) reaches `main` and then sits there until each running brigade pulls it.
This skill performs that pull for the running main brigade and every sous-chef, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync brigade already runs.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a sous-chef's in-flight work is never disrupted.
This touches only the brigade repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/brigade-update.sh
   ```
   It fast-forwards this brigade repo's default branch from origin, then fast-forwards every registered sous-chef home (each a worktrunk worktree of this same repo, leased at a detached HEAD on the default branch) the same way.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-brigade: yes|no`
   - `nudge-sous-chefs: <window-targets...>|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-brigade: yes`, the tracked instruction surface (AGENTS.md, bin/, or skills) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-brigade: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live sous-chef.**
   For every target listed on the `nudge-sous-chefs:` line (do nothing when it says `none`), send a one-line re-read nudge so that sous-chef picks up its new instructions too:
   ```sh
   bin/brigade-send.sh <window-target> 'brigade was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   This is a gentle steer, not an interruption: the sous-chef already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A sous-chef that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Report to the head chef in plain outcomes.**
   Summarize what landed without brigade's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Head chef, brigade and both domain supervisors are now on the latest."
   Surface any skipped target whose reason needs the head chef's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the brigade repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Sous-Chefs are never disrupted.**
  A sous-chef gets a tracked-files fast-forward (safe while it is mid-ticket, since its work lives in gitignored operational dirs and separate project worktrees) plus a gentle re-read nudge.
  It is never torn down, interrupted, or forced.
