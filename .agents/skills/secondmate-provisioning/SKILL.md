---
name: sous-chef-provisioning
description: Agent-only reference for persistent sous-chef setup and retirement. Use when creating, seeding, validating, recovering, handing backlog to, or retiring a sous-chef home, or when editing data/sous-chefs.md. Covers home leases, transactional seeding, project clone restrictions, idle charter, handoff helper, and teardown safety.
user-invocable: false
---

# sous-chef-provisioning

Use this reference before creating, seeding, validating, handing backlog to, recovering, or retiring a persistent sous-chef, and before editing `data/sous-chefs.md`.

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main brigade, and sous-chefs are idle by default.

## Routing table

`data/sous-chefs.md` has one line per persistent domain supervisor:

```markdown
- <id> - <charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

The `scope:` field is used during intake.
The `projects:` field is a non-exclusive clone list, not ownership.

## Charter and seed

Scaffold a sous-chef charter with:

```sh
bin/brigade-brief.sh <id> --sous-chef <project>...
```

The scaffold writes a charter brief instead of a ticket brief.
Set `FM_SECONDMATE_CHARTER='<charter>'` to fill the charter text and `FM_SECONDMATE_SCOPE='<scope>'` when the routing scope differs.
If you scaffold without `FM_SECONDMATE_CHARTER`, replace the `{TASK}` placeholder before seeding.
Keep the charter focused on the persistent responsibility, available project clones, and escalation back to the main brigade status file.
The scaffold's definition of done encodes the idle-by-default contract: on startup the sous-chef reconciles only its own in-flight work and then waits for routed tickets, never self-initiating a survey or audit.
Preserve that wording when filling the charter.

Provision the persistent home and registry entry after the charter is filled:

```sh
bin/brigade-home-seed.sh <id> <home|-> <project>...
```

`-` durably leases a fresh brigade worktree via `worktrunk get --lease` under the sous-chef id.
The lease survives with no live process and is never recycled by later `worktrunk get` or `prune`.
The slot stays reserved across restarts until the lease is released.
Release happens only on explicit retirement or seed rollback, never on routine restart or recovery.

`bin/brigade-home-seed.sh` copies the charter into the sous-chef home as `data/charter.md`.
`bin/brigade-spawn.sh --sous-chef` launches it through the same launch-template path.
`bin/brigade-home-seed.sh` refuses to copy a missing or placeholder charter.

Direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`.
Run `bin/brigade-home-seed.sh validate` when checking registry integrity; it refuses duplicate ids, duplicate homes, and nested or overlapping homes.

Seeding is transactional.
If validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

Sous-Chef project lists may include `no-mistakes` and `direct-PR` projects only.
`local-only` projects stay with the main brigade.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a sous-chef home and refuses to mutate a preexisting clone that is not already initialized.

## Backlog handoff

When a sous-chef is created for a domain, existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is brigade's judgment against the sous-chef's natural-language scope, not a keyword rule.
Read `data/backlog.md`, pick queued items that fit the new scope, and move them with:

```sh
bin/brigade-backlog-handoff.sh <sous-chef-id> <item-key>...
```

After seeding, run this handoff for the new sous-chef's in-scope queued items.
The helper resolves the sous-chef home from `data/sous-chefs.md` and mechanically moves each named item from the main `data/backlog.md` into the sous-chef home's `data/backlog.md`.
It preserves the line and its section, so the item is neither duplicated nor lost.
It refuses `## In flight` entries because active ticket ownership also lives in zellij and `state/`.
It is idempotent; an item already in the sous-chef backlog is skipped.
It refuses any destination that is not a genuine seeded brigade home with safe operational directories and a matching `.brigade-sous-chef-home` marker, so a move can never land in a project.
Do not hand off `local-only` items.

## Recovery

For `kind=sous-chef` meta with no window, treat the sous-chef as a dead persistent direct report and respawn it with:

```sh
bin/brigade-spawn.sh <id> --sous-chef
```

Use the recorded `home=` in meta.
If meta is missing but `data/sous-chefs.md` still registers the sous-chef, respawn from the registry entry and its persistent on-disk home.

Do not reconstruct a sous-chef's whole tree from the main home.
The main brigade reconciles only direct reports.
Each sous-chef is a brigade in its own home, so it runs recovery on startup and reconciles its own line cooks.
A sous-chef's recovery reconciles only work that is already its own and then idles.
It never initiates a survey or audit during recovery.

## Retirement and teardown

A sous-chef is persistent by default.
An empty queue is healthy and does not trigger teardown.
Run `bin/brigade-teardown.sh <id>` for `kind=sous-chef` only when the head chef or main brigade explicitly decides to retire that persistent supervisor.

The safety check is the sous-chef's own home.
Teardown refuses while its `state/*.meta` contains in-flight work.
When safe, teardown kills the direct zellij tab, removes the `data/sous-chefs.md` route, clears the main home metadata, and removes the retired sous-chef home.
Removing a leased home releases its durable worktrunk lease via `worktrunk return`, so the pool slot is freed for reuse rather than left leased forever.
A plain-clone home with no pool slot is simply removed.
If `worktrunk return` fails for a leased home, teardown stops with state intact rather than raw-removing the directory and hiding a held lease.

With `--force`, teardown is the explicit discard path.
It kills child windows, discards child work and state inside the sous-chef home, removes the route, releases the lease, and removes the retired sous-chef home.
Never use `--force` unless the head chef explicitly said to discard the work.
