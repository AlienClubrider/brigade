# The bin/ toolbelt

The brigade drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each file also starts with a short header comment.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `brigade-bootstrap.sh`        | Detect required toolchain problems, optional capability facts, and primary-checkout `TANGLE:` problems; refresh clones best-effort; install tools only after consent |
| `brigade-fleet-sync.sh`       | Fetch clones, clean-fast-forward their checked-out default branches, and safely prune branches whose remote is gone |
| `brigade-update.sh`           | Self-update the running brigade repo and registered sous-chef homes with fast-forward-only pulls from origin     |
| `brigade-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded sous-chef home                 |
| `brigade-brief.sh`            | Scaffold a ship brief with a worktree-isolation assertion, a report-only scout brief with `--scout`, or a sous-chef charter with `--sous-chef` |
| `brigade-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `brigade-guard.sh`            | Warn when the primary checkout is tangled, when queued wakes are pending, or when a stale or missing watcher needs a prominent banner |
| `brigade-home-seed.sh`        | Lease/provision a sous-chef home transactionally, clone projects, initialize gates, and maintain `data/sous-chefs.md` |
| `brigade-spawn.sh`            | Spawn one ticket, several `id=repo` pairs, or a persistent sous-chef with `--sous-chef`; ship/scout spawns require an isolated worktrunk worktree |
| `brigade-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`                                          |
| `brigade-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `brigade-review-diff.sh`      | Review a line cook branch against the authoritative base, with optional `--stat` output                              |
| `brigade-watch-arm.sh`        | Verified per-home watcher re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's watcher |
| `brigade-watch.sh`            | Singleton-safe one-shot watcher; blocks until supervision work is due, queues it durably, then exits with one reason line |
| `brigade-supervise-daemon.sh` | Presence-gated sub-supervisor for walk-away (`/afk`) supervision: wraps `brigade-watch.sh`, self-handles routine wakes in bash, and escalates only head chef-relevant events as one verified, batched, single-line digest prefixed with a sentinel marker |
| `brigade-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification sourced by bootstrap and guard         |
| `brigade-tasks-axi-lib.sh`    | Shared `tasks-axi` compatibility probe sourced by bootstrap and teardown                                            |
| `brigade-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work                                              |
| `brigade-wake-lib.sh`         | Shared durable wake queue and portable lock helpers sourced by the watcher, drain, arm, guard, and daemon          |
| `brigade-send.sh`             | Send one verified literal line (or `--key Escape`) to a line cook window; exits non-zero when Enter is positively swallowed |
| `brigade-zellij-lib.sh`         | Shared zellij pane primitives for busy detection, dim-ghost-aware and border-aware composer detection, and verified submit retry |
| `brigade-peek.sh`             | Print a bounded tail of a line cook pane                                                                             |
| `brigade-pr-check.sh`         | Record a PR-ready ticket and arm the watcher's merge poll                                                             |
| `brigade-promote.sh`          | Promote a scout ticket in place so it becomes a protected ship ticket                                                   |
| `brigade-teardown.sh`         | Return the worktree or retire/release a sous-chef home; protects ship work, requires scout reports, checks child work, and prints the backlog reminder |
| `brigade-harness.sh`          | Detect the running harness; resolve the effective line cook harness                                                  |
| `brigade-lock.sh`             | Per-home brigade session lock                                                                                     |
| `brigade-recipe.sh`           | Manage Recipes (`~/.brigade/recipes/<repo>/AGENTS.md`): install into a worktree at spawn, remove at teardown, edit/show/list |
