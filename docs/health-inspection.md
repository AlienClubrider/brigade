# Health Inspection

Health Inspection is brigade's quality gate — run `no-mistakes` when you're ready to ship, not automatically.
Nothing leaves the kitchen until it passes inspection.

---

## How it works

`no-mistakes` puts a local git proxy in front of your real remote.
When you push through it, it runs your configured test, lint, and AI review pipeline in an isolated worktree, and only forwards the push upstream after every check passes.

**It is manually triggered.** You decide when a line cook's work is ready for inspection. Brigade does not run it automatically.

---

## First-time setup (per project)

Install no-mistakes:

```bash
curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
```

Check prerequisites:

```bash
no-mistakes doctor
```

Initialize the gate for a project (run inside the project's working directory):

```bash
# For projects where you have direct push access:
no-mistakes init

# For projects where you contribute via fork:
no-mistakes init --fork-url git@github.com:<you>/<repo>.git
```

This creates a `no-mistakes` git remote in the project. You push through it instead of `origin`.

---

## Per-project config (`.no-mistakes.yaml`)

Each project gets its own `.no-mistakes.yaml` at the repo root. This defines what the health inspection runs.

**Minimal example:**

```yaml
test:
  command: npm test

lint:
  command: npm run lint

review:
  context_files:
    - AGENTS.md
```

**Common patterns by stack:**

```yaml
# Node / Expo
test:
  command: npx jest --ci
lint:
  command: npx eslint src/

# Python / FastAPI
test:
  command: python -m pytest
lint:
  command: ruff check .

# Java / Spring Boot
test:
  command: ./gradlew test
lint:
  command: ./gradlew checkstyleMain

# Bash scripts (brigade itself)
test:
  command: |
    bash -n bin/*.sh &&
    shellcheck bin/*.sh tests/*.sh &&
    for t in tests/*.test.sh; do "$t"; done
lint:
  command: shellcheck bin/*.sh tests/*.sh
```

Point `review.context_files` at your project's AGENTS.md so the AI review step reads your conventions:

```yaml
review:
  context_files:
    - AGENTS.md
```

Keep test evidence out of the repo (avoids dirty worktree on pooled Worktrunk slots):

```yaml
test:
  evidence:
    store_in_repo: false
```

---

## Running the inspection

When a line cook's status shows `✅` and you're ready:

```bash
# Inside the line cook's worktree (or from the project directory):
git push no-mistakes
```

Then watch the pipeline:

```bash
no-mistakes
```

Authorize auto-fixes as they appear. The pipeline pushes the branch and opens the PR once everything passes.

**You do not push to `origin` directly.** `git push no-mistakes` is the full command — the gate handles the upstream push.

---

## Prep Kitchen mode (local-only projects)

Projects marked `local-only` in `data/projects.md` never push remotely.
The health inspection still runs locally — tests and lint execute in the worktree — but the gate merges into the local default branch instead of opening a PR.

```bash
# local-only: run inspection + merge locally
git push no-mistakes
# Pipeline runs, then merges to main locally. No PR opened.
```

---

## Tweaking config during testing

The plan calls for tweaking `.no-mistakes.yaml` per project as you go:

- Run a real ticket end-to-end (Phase 06)
- If tests fail or lint is wrong, adjust `.no-mistakes.yaml` in the project
- The AI review step reads AGENTS.md — keep it updated with your conventions
- `no-mistakes doctor` checks your setup if anything looks off

---

## brigade's own health inspection

brigade uses no-mistakes to ship changes to itself.
The root `.no-mistakes.yaml` runs shellcheck + bash syntax check + all behavior tests.
See `CONTRIBUTING.md` for the full development workflow.

---

## Reference

- [no-mistakes quick start](https://kunchenguid.github.io/no-mistakes/start-here/quick-start/)
- [Repo config reference](https://kunchenguid.github.io/no-mistakes/reference/repo-config/)
- [CLI commands](https://kunchenguid.github.io/no-mistakes/reference/cli-commands/)
