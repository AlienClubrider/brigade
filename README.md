<h1 align="center">brigade</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
</p>

<h3 align="center">Fire your first ticket. Run the kitchen.</h3>

## What it is

You can run one coding agent easily.
But the moment you want three project tickets done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

brigade flips the model.
You talk to a single agent - the brigade - and it runs the kitchen for you: spawning autonomous agents in zellij tabs, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
For larger fleets, you can opt in to persistent sous-chefs: domain supervisors that are still ordinary direct reports, but run from their own isolated brigade homes.
There is no app to install; the orchestrator is `AGENTS.md`, bundled skills, and helper scripts that any terminal coding agent can follow.

This is not an agent harness. This is not a single skill. This is not a CLI.
This is.. a directory that turns any agent into your brigade, and you the head chef.

## Features

- **One liaison** - you talk only to the brigade; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible kitchen** - every line cook works in its own zellij tab you can watch or type into; the brigade reconciles.
- **Disposable worktrees** - each ticket runs in a clean [worktrunk](https://github.com/max-sixty/worktrunk) (`wt`) git worktree, so parallel work on one repo never collides.
- **Two ticket shapes** - ship tickets deliver a change; scout tickets investigate, plan, reproduce, or audit and leave a report.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` autonomy flag.
- **Optional sous-chefs** - opt in to persistent domain supervisors that run from isolated brigade homes with their own `FM_HOME`, state, projects, and session lock.
- **Event-driven, zero-token supervision** - a bash watcher sleeps on the fleet and wakes the brigade only when something needs you.
- **Guarded by construction** - the brigade is read-only over your projects outside clean default-branch refreshes, safe branch pruning, and approved `local-only` fast-forward merges; line cooks make every project change behind your merge approval.
- **Restart-proof** - all state lives on disk and in zellij; kill the session anytime and the next one reconciles and carries on.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

**Requirements:** a verified agent harness (claude, codex, opencode, or pi), git with GitHub auth, zellij, and worktrunk (`brew install worktrunk`).
The brigade detects and offers to install everything else.

```sh
gh auth login
brew install zellij worktrunk
git clone https://github.com/AlienClubrider/brigade
```

Then start Zellij, navigate to brigade inside it, and launch your harness:

```sh
zellij
# inside zellij:
cd brigade && claude   # or codex, opencode, pi — AGENTS.md takes over
```

Brigade auto-runs its bootstrap check on startup. If anything is missing it tells you and asks before installing. Then just talk:

```sh
> look at my github project xyz, then fix the flaky login test and add dark mode

# brigade clones the project under projects/ and spawns two line cooks in zellij tabs
# brigade-fix-login-k3 and brigade-dark-mode-p7.
# Minutes later:

  PR ready for review, head chef: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

Running inside Zellij puts every line cook window in your own session so you can watch the kitchen work in real time or type into any window to intervene.
Outside Zellij, line cooks land in a detached `brigade` session you can attach to.

## How It Works

```
            you (the head chef)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ brigade            (this repo)    │
 │ reads projects/ + brigade routes  │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ zellij action write-chars / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │brigade-ticket1│   │brigade-ticket2│  ... │brigade-ticketN│   zellij tabs you can watch
 │line cook│   │line cook│      │line cook│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  wt worktree or isolated sous-chef home
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► relay findings ► teardown
```

You chat with the brigade.
It routes each request to a line cook in its own zellij tab and git worktree, supervises the fleet with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or investigation reports.
A presence-gated sub-supervisor (`/afk`) can self-handle routine events and batch only what matters while you step away.
When brigade works on itself, spawn-time isolation checks and a primary-checkout tangle alarm keep the operating checkout on its default branch and stop a line cook that did not land in a separate worktree.

Full architecture - the supervision engine, worktree isolation, sous-chefs, project modes, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Brigade ships these user-invocable built-in skills.
Claude uses the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the sub-supervisor self-handles routine wakes in bash and escalates only head chef-relevant events as one batched digest, cutting supervision cost while you step away |
| `/updatebrigade` | Self-update the running brigade and its sous-chefs to the latest from origin with fast-forward-only pulls, then re-read instructions and nudge sous-chefs |

Agent-only reference skills live under `.agents/skills/` and are loaded by brigade at the trigger points named in [`AGENTS.md`](AGENTS.md).

## Documentation

- [docs/architecture.md](docs/architecture.md) - how the kitchen, supervision, worktrees, sous-chefs, and project modes work.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, the files you set, and harness support.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/expeditor.md](docs/expeditor.md) - install and configure dot-agent-deck and falcode-zellij (the Expeditor).
- [docs/health-inspection.md](docs/health-inspection.md) - no-mistakes setup, per-project config, and running health inspection.
- [`AGENTS.md`](AGENTS.md) - brigade's full operating manual for the orchestrator agent.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).
