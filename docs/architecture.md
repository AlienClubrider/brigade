# Architecture

How brigade works, in depth.

The [README](../README.md) carries the high-level diagram and a short synopsis.
This document expands every part of it.
brigade's full operating manual for the orchestrator agent itself is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Event-driven supervision

A zero-token bash watcher (`bin/brigade-watch.sh`) sleeps on the fleet and wakes the brigade only when a line cook reports, stalls, a PR merges, or an internal heartbeat review is due.
Detected wakes are also written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed one-shot process exit can be recovered by draining the queue.
Routine watcher polling, re-arm no-ops, elapsed waiting time, and unchanged heartbeat reviews stay silent; an idle kitchen costs you nothing.

Routine re-arms go through `bin/brigade-watch-arm.sh`, which forks the watcher as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints exactly one honest status line (`started` / `healthy` / `FAILED`, the last exiting non-zero) - never a false `already running` off a dying process.
Its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling sous-chef watchers.
A pull-based guard (`bin/brigade-guard.sh`) warns through supervision tool output if the primary checkout is tangled, or if tickets are in flight and that watcher stops running or queued wakes are waiting to be drained.
It leads with prominent bordered banners for the tangle and no-watcher cases so they cannot be skimmed past.

A presence-gated sub-supervisor (`bin/brigade-supervise-daemon.sh`) extends this for walk-away supervision: the `/afk` skill activates it, after which it self-handles routine wakes in bash and escalates only head chef-relevant events as one batched, single-line digest (prefixed with an in-band sentinel marker so brigade can tell daemon injections apart from real messages).
Its injection path shares `bin/brigade-wezterm-lib.sh` with `brigade-send.sh`, so border-aware composer detection plus verified submit retry stay consistent; stalled escalation delivery raises `state/.subsuper-inject-wedged` after `FM_MAX_DEFER_SECS` instead of silently deferring forever.

## Worktrees, not branches in your checkout

Line cooks never intentionally touch your project clone; [worktrunk](https://github.com/kunchenguid/worktrunk) pools clean worktrees so parallel tickets on one repo cannot collide.
For ship and scout work, `brigade-spawn.sh` waits for `worktrunk get` and then refuses to launch unless the pane resolves to a real git worktree root that is distinct from the project primary checkout.

The brigade repo has one extra exposure because it can dispatch line cooks to work on itself.
Its operating checkout (`FM_ROOT`) and the disposable line cook worktrees are all linked git worktrees of the same repository, so the valid discriminator is branch state, not whether the checkout is linked.
The primary checkout is healthy on its default branch, and linked worktrees or sous-chef homes are healthy at detached HEAD.
Only a named non-default branch checked out in `FM_ROOT` is a worktree tangle.

`brigade-tangle-lib.sh` resolves the default branch from `origin/HEAD`, then local `main` or `master`, and classifies that named non-default primary branch as the tangle.
`brigade-guard.sh` prints the repair command on the next fleet action, while `brigade-bootstrap.sh` reports the same condition as a `TANGLE:` line at session start.
Ship briefs also tell the line cook to verify `pwd -P` and `git rev-parse --show-toplevel` before creating `fm/<id>`, then stop with a blocked status if it landed in the primary checkout.

## Two ticket shapes

Ship tickets change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); scout tickets investigate, plan, reproduce bugs, or audit, then leave a report at `data/<id>/report.md` and never push.

## Optional sous-chefs

`data/sous-chefs.md` records persistent domain supervisors with natural-language scopes, project clone lists, and home paths.
`brigade-home-seed.sh` provisions the isolated home, clones the listed PR-based projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and `brigade-spawn.sh --sous-chef` launches it through the same WezTerm pane and status-file path as any direct report.
When seeded with `-`, the home is a durable worktrunk lease under the sous-chef id, so it survives with no live process and is not recycled by later `worktrunk get` or pruning.
Retirement or seed rollback returns the leased home; normal restart/recovery keeps it leased.
If returning the lease fails during teardown, brigade leaves the route and home intact instead of hiding a still-held lease.
Seeding is transactional: if validation, cloning, initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.
`local-only` projects stay with the main brigade because they merge into the main local checkout instead of a remote-backed PR path.
The same project may appear in multiple sous-chef homes when their scopes differ, such as issue triage versus feature development.
Sous-Chefs are idle by default: after startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tickets, and they never self-initiate surveys or audits.
After seeding a sous-chef, `brigade-backlog-handoff.sh` moves already-judged in-scope queued items from the main backlog into that sous-chef home so the domain queue starts in the right place.
Idle sous-chef panes are healthy; teardown is explicit and refuses while the sous-chef home has in-flight work unless the head chef has approved discard with `--force`.

The `data/sous-chefs.md` line schema and the sous-chef environment variables are documented in [configuration.md](configuration.md).

## Project modes are explicit

`data/projects.md` records each project's delivery mode and optional `+yolo` autonomy flag.
`no-mistakes` projects run the full validation pipeline, `direct-PR` projects open PRs without that pipeline, and `local-only` projects stay local until brigade performs an approved fast-forward merge.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
Ship briefs prompt line cooks to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
The full ownership rule - what is project-intrinsic versus fleet-private, and how brigade keeps the two apart without writing into project clones - is owned by brigade's operating manual in [`AGENTS.md`](../AGENTS.md) (project memory ownership).

## Local clones stay fresh

Bootstrap and PR-based teardown refresh remote-backed project clones with clean default-branch fast-forwards when the clone is on the default branch and has no local work, and prune local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

`/updatebrigade` fast-forwards the running brigade repo and registered sous-chef homes from `origin`, then re-reads updated instructions and nudges updated sous-chefs without touching project clones.
The update is fast-forward only: dirty, diverged, offline, and off-default targets are reported and left untouched.
The mechanics are owned by the `/updatebrigade` skill and brigade's operating manual in [`AGENTS.md`](../AGENTS.md) (self-update).

## Restart-proof

All state lives in WezTerm panes, status files, local markdown under `data/`, `data/sous-chefs.md`, and persistent sous-chef homes.
Kill the brigade session anytime; the next one reconciles and carries on.

## Development notes

The current watcher reliability work keeps the one-shot process model and adds a durable queue, race-proof singleton lock, duplicate self-eviction, and a self-verifying tracked-child arm wrapper.
The presence-gated sub-supervisor (`bin/brigade-supervise-daemon.sh`) provides proactive wake routing for walk-away supervision via the `/afk` skill; a blocking-waiter split remains a deferred follow-up phase.
