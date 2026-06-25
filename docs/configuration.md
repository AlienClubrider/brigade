# Configuration

The files and environment variables you set to operate brigade.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a line cook while tickets are in flight.

## Backlog backend (.tickets.toml / tasks-axi)

The tracked `.tickets.toml` pins the optional `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When compatible `tasks-axi` is on `PATH`, brigade uses its verbs for routine backlog mutations and keeps sous-chef transfers behind `brigade-backlog-handoff.sh` validation; without it, backlog bookkeeping remains manual.
Compatible means the shared bootstrap probe accepts `tasks-axi --version` as 0.1.1 or newer.

## Head chef preferences (data/kitchen.md)

Personal preferences for one head chef's fleet live locally in `data/kitchen.md`; it is gitignored and read after `data/projects.md` and optional `data/sous-chefs.md` during bootstrap.

## Sous-Chef routes (data/sous-chefs.md)

Persistent sous-chef routes live locally in `data/sous-chefs.md`.
Each line records the sous-chef id, charter summary, absolute home path, natural-language scope, project clone list, and added date; `brigade-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main brigade routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `brigade-home-seed.sh <id> - <project>...` to lease a fresh brigade worktree for the sous-chef home.
The lease is held under the sous-chef id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `worktrunk return` cannot release the lease; plain-clone homes with no worktrunk pool slot are removed directly.
Sous-Chef routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-brigade work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a sous-chef home and refuses to mutate a preexisting clone that is not already initialized.
After creating a sous-chef, move existing main-backlog items that you have judged in-scope with `brigade-backlog-handoff.sh <sous-chef-id> <item-key>...`; it is idempotent and refuses in-flight items or non-sous-chef homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.

## FM_HOME

`FM_HOME` selects the operational home for one brigade instance.
When it is unset, the repo root is the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the brigade repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.

## Harness support

claude, codex, opencode, and pi are all empirically verified; new harnesses get verified through a supervised trial ticket before joining the set.
The verified adapter knowledge - busy signatures, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
Launch mechanics, including the verified command templates, live in [`bin/brigade-spawn.sh`](../bin/brigade-spawn.sh).

## Toolchain

On first launch the brigade detects what its required toolchain is missing or too old (zellij, node, gh, worktrunk with durable lease support, no-mistakes, gh-axi, chrome-devtools-axi), lists it with the exact install commands, and installs only after you say go.
If compatible `tasks-axi` is already on `PATH`, bootstrap records it as an optional capability fact and brigade uses its verbs for routine backlog mutations; when it is absent or incompatible, brigade keeps hand-editing `data/backlog.md` exactly as before.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home; unset means this repo root
FM_ROOT_OVERRIDE=        # override brigade repo root and tangle-guard target; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_POLL=15              # seconds between watcher cycles
FM_HEARTBEAT=600        # base seconds between fleet reviews; backs off exponentially while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (merged-PR polls)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings and arm health checks treat a watcher beacon as stale
FM_ARM_CONFIRM_TIMEOUT=10   # seconds brigade-watch-arm waits to confirm a fresh watcher before reporting FAILED
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=20   # seconds allowed for bootstrap's best-effort clone refresh
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.'   # busy-pane signatures, shared by watcher and zellij helper
FM_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after dim-ghost and border stripping
FM_SEND_RETRIES=3       # brigade-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between brigade-send submit checks
# sub-supervisor (bin/brigade-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_TARGET=brigade:0   # supervisor zellij target (override; auto-discovers from $TMUX_PANE)
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_HEAD CHEF_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # status regex that escalates daemon signal/stale/scan output
FM_STALE_ESCALATE_SECS=240         # idle seconds before a stale pane escalates as a possible wedge
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed head chef verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```
