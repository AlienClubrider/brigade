#!/usr/bin/env bash
# tests/brigade-sous-chef-safety.test.sh - sous-chef home safety invariants:
# the path-boundary matrices (seed/spawn/teardown), registry/charter/origin
# validation, worktrunk lease handling, no-mistakes initialization of new
# clones, child-worktree protection, and backlog-handoff safety. The happy-path
# operator flow lives in brigade-sous-chef-lifecycle-e2e.test.sh; this file keeps the
# destructive-invariant coverage that an e2e run cannot deterministically reach.
set -u

# shellcheck source=tests/sous-chef-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/sous-chef-helpers.sh"

TMP_ROOT=$(fm_test_tmproot brigade-sous-chef-safety)


test_fm_home_parameterization() {
  local brief home_one home_two out
  home_one="$TMP_ROOT/home one"
  home_two="$TMP_ROOT/home-two"
  mkdir -p "$home_one/data" "$home_one/state" "$home_two/data" "$home_two/state"
  printf '%s\n' '- app [local-only +yolo] - test app (added 2026-06-22)' > "$home_one/data/projects.md"

  out=$(FM_HOME="$home_one" "$ROOT/bin/brigade-project-mode.sh" app)
  [ "$out" = "local-only on" ] || fail "brigade-project-mode did not read projects.md from FM_HOME"
  out=$(FM_HOME="$home_two" "$ROOT/bin/brigade-project-mode.sh" app 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "brigade-project-mode did not isolate missing registry by home"

  FM_HOME="$home_one" "$ROOT/bin/brigade-brief.sh" task-a app >/dev/null || fail "brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-a/brief.md"
  [ -f "$brief" ] || fail "brief was not written under FM_HOME/data"
  grep -F ">> '$home_one/state/task-a.status'" "$brief" >/dev/null || fail "brief did not shell-quote FM_HOME state path"

  FM_HOME="$home_one" "$ROOT/bin/brigade-brief.sh" task-b app --scout >/dev/null || fail "scout brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-b/brief.md"
  grep -F ">> '$home_one/state/task-b.status'" "$brief" >/dev/null || fail "scout brief did not shell-quote FM_HOME state path"

  FM_HOME="$home_one" FM_SECONDMATE_CHARTER='ops domain' "$ROOT/bin/brigade-brief.sh" task-c --sous-chef app >/dev/null \
    || fail "sous-chef brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-c/brief.md"
  grep -F ">> '$home_one/state/task-c.status'" "$brief" >/dev/null || fail "sous-chef brief did not shell-quote FM_HOME state path"

  printf 'project=x\n' > "$home_one/state/ticket-a.meta"
  FM_HOME="$home_one" FM_GUARD_GRACE=999999 "$ROOT/bin/brigade-pr-check.sh" task-a https://github.com/example/repo/pull/1 >/dev/null 2>/dev/null \
    || fail "brigade-pr-check failed under FM_HOME"
  [ -f "$home_one/state/task-a.check.sh" ] || fail "pr check was not written under FM_HOME/state"
  [ ! -e "$home_two/state/task-a.check.sh" ] || fail "pr check leaked into another home"
  pass "FM_HOME parameterizes data and state paths"
}

test_lock_status_is_per_home() {
  local home_one home_two out
  home_one="$TMP_ROOT/lock-one"
  home_two="$TMP_ROOT/lock-two"
  mkdir -p "$home_one/state" "$home_two/state"
  printf '999999\n' > "$home_one/state/.lock"
  out=$(FM_HOME="$home_one" "$ROOT/bin/brigade-lock.sh" status)
  printf '%s\n' "$out" | grep -F 'lock: stale' >/dev/null || fail "home one lock status did not read its own lock"
  out=$(FM_HOME="$home_two" "$ROOT/bin/brigade-lock.sh" status)
  [ "$out" = "lock: free" ] || fail "home two lock status was affected by home one"
  pass "brigade-lock status is scoped per home"
}

test_seed_allows_overlapping_clones_and_drops_owner() {
  # A project may appear in several sous-chefs' (non-exclusive) clone lists; the
  # registry never uses the legacy owns: field, and the removed `owner` subcommand
  # stays gone. The full happy seed - charter copied, clones+origins, no-mistakes
  # init, modes preserved - is asserted by brigade-sous-chef-lifecycle-e2e.
  local home design other
  home="$TMP_ROOT/overlap-main"
  design="$TMP_ROOT/overlap-design"
  other="$TMP_ROOT/overlap-other"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_init_commit "$home/projects/beta"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/seed-overlap-alpha.git"
  fm_git_add_origin "$home/projects/beta" "$TMP_ROOT/remotes/seed-overlap-beta.git"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
EOF

  FM_HOME="$home" FM_SECONDMATE_CHARTER='feature design for alpha beta' \
    FM_SECONDMATE_SCOPE='feature design for alpha beta' \
    "$ROOT/bin/brigade-home-seed.sh" design "$design" alpha beta >/dev/null \
    || fail "initial seed failed"
  assert_grep '- design - feature design for alpha beta' "$home/data/sous-chefs.md" "design registry line missing"
  assert_grep 'projects: alpha, beta' "$home/data/sous-chefs.md" "design project clone list missing"
  assert_no_grep 'owns:' "$home/data/sous-chefs.md" "registry used the legacy owns field"

  # beta is shared with a second sous-chef of a different scope (overlap allowed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='issue triage for beta' \
    FM_SECONDMATE_SCOPE='issue triage for beta' \
    "$ROOT/bin/brigade-home-seed.sh" other "$other" beta >/dev/null 2>&1 \
    || fail "seed refused overlapping project clones across different scopes"
  assert_grep '- other - issue triage for beta' "$home/data/sous-chefs.md" "overlapping registry line missing"
  FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" validate >/dev/null || fail "registry validation rejected overlapping clones"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" owner alpha >/dev/null 2>&1; then
    fail "owner subcommand still succeeded after routing moved to scopes"
  fi
  pass "seed allows overlapping project clone lists and drops the owns/owner routing"
}

test_home_seed_validate_rejects_duplicate_homes() {
  local home subhome subhome_abs err
  home="$TMP_ROOT/duplicate-home"
  subhome="$TMP_ROOT/duplicate-subhome"
  err="$TMP_ROOT/duplicate-home.err"
  mkdir -p "$home/data" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/data/sous-chefs.md" <<EOF
- design - design domain mentions home: $TMP_ROOT/ignored-summary-home (home: $subhome_abs; scope: design work mentions home: $TMP_ROOT/ignored-scope-home; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $subhome_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two sous-chefs with the same home"
  fi
  grep -F 'duplicate sous-chef home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate home assignment"
  pass "home seed validation rejects duplicate home routes"
}

test_home_seed_validate_rejects_duplicate_ids() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/duplicate-id-home"
  first="$TMP_ROOT/duplicate-id-first"
  second="$TMP_ROOT/duplicate-id-second"
  err="$TMP_ROOT/duplicate-id.err"
  mkdir -p "$home/data" "$first" "$second"
  first_abs=$(cd "$first" && pwd -P)
  second_abs=$(cd "$second" && pwd -P)
  cat > "$home/data/sous-chefs.md" <<EOF
- design - design domain (home: $first_abs; scope: design work; projects: alpha; added 2026-06-22)
- design - design domain (home: $second_abs; scope: design work; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted two homes for the same sous-chef id"
  fi
  grep -F 'duplicate sous-chef id assignment' "$err" >/dev/null \
    || fail "registry validation did not explain duplicate id assignment"
  pass "home seed validation rejects duplicate id routes"
}

test_home_seed_validate_rejects_nested_homes() {
  local home ancestor descendant ancestor_abs descendant_abs err
  home="$TMP_ROOT/nested-home"
  ancestor="$TMP_ROOT/nested-domain-a"
  descendant="$ancestor/domain-b"
  err="$TMP_ROOT/nested-home.err"
  mkdir -p "$home/data" "$ancestor" "$descendant"
  ancestor_abs=$(cd "$ancestor" && pwd -P)
  descendant_abs=$(cd "$descendant" && pwd -P)
  cat > "$home/data/sous-chefs.md" <<EOF
- design - design domain (home: $ancestor_abs; scope: design work; projects: alpha; added 2026-06-22)
- triage - triage domain (home: $descendant_abs; scope: issue triage; projects: beta; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" validate >/dev/null 2>"$err"; then
    fail "registry validation accepted nested sous-chef homes"
  fi
  grep -F 'overlapping sous-chef home assignment' "$err" >/dev/null \
    || fail "registry validation did not explain nested home assignment"
  pass "home seed validation rejects nested home routes"
}

test_home_seed_uses_worktrunk_acquired_home() {
  local home acquired acquired_abs fakebin log out test_root
  home="$TMP_ROOT/dash-home"
  acquired="$TMP_ROOT/dash-acquired-home"
  test_root="$TMP_ROOT/dash-test-root"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  make_brigade_git_root "$test_root"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/dash-fake")
  log="$TMP_ROOT/dash-fake/wezterm.log"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$test_root" \
    FM_FAKE_WT_HOME="$acquired" FM_FAKE_WEZTERM_LOG="$log" \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/brigade-home-seed.sh" dash - alpha) \
    || fail "seed failed for a wt-acquired home"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$acquired_abs" >/dev/null || fail "seed did not report acquired home"
  grep -F 'wt switch --create brigade-home/dash' "$log" >/dev/null || fail "seed did not create a wt home for the sous-chef id"
  [ -f "$acquired/.brigade-sous-chef-home" ] || fail "seed did not mark acquired home"
  [ "$(cat "$acquired/.brigade-sous-chef-home")" = dash ] || fail "seed wrote wrong acquired-home marker"
  [ -d "$acquired/projects/alpha/.git" ] || fail "seed did not clone project into acquired home"
  grep -F "home: $acquired_abs" "$home/data/sous-chefs.md" >/dev/null || fail "registry did not record acquired home"
  pass "home seeding uses wt switch --create to acquire dash homes under the sous-chef id"
}

test_home_seed_returns_worktrunk_acquired_home_on_assignment_failure() {
  local home acquired acquired_abs fakebin log err test_root
  home="$TMP_ROOT/dash-fail-home"
  acquired="$TMP_ROOT/dash-fail-acquired-home"
  test_root="$TMP_ROOT/dash-fail-test-root"
  err="$TMP_ROOT/dash-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  # Pre-mark the test root with another owner so the worktree checkout has the marker.
  make_brigade_git_root "$test_root" "other"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/dash-fail-fake")
  log="$TMP_ROOT/dash-fail-fake/wezterm.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$test_root" \
    FM_FAKE_WT_HOME="$acquired" FM_FAKE_WEZTERM_LOG="$log" \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/brigade-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home marked for another sous-chef"
  fi
  acquired_abs="$acquired"
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain acquired marked-home rejection"
  grep -F "wt remove -f -D --foreground $acquired_abs" "$log" >/dev/null \
    || fail "failed acquired seed did not remove the home via wt"
  if [ -f "$home/data/sous-chefs.md" ] && grep -F -- '- dash ' "$home/data/sous-chefs.md" >/dev/null; then
    fail "failed acquired seed left a registry route"
  fi
  pass "home seeding removes rejected acquired homes via wt remove"
}

test_home_seed_warns_when_acquired_home_return_fails() {
  local home acquired acquired_abs fakebin log err test_root
  home="$TMP_ROOT/dash-return-fail-home"
  acquired="$TMP_ROOT/dash-return-fail-acquired-home"
  test_root="$TMP_ROOT/dash-return-fail-test-root"
  err="$TMP_ROOT/dash-return-fail.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-return-fail-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  make_brigade_git_root "$test_root" "other"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/dash-return-fail-fake")
  log="$TMP_ROOT/dash-return-fail-fake/wezterm.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$test_root" \
    FM_FAKE_WT_HOME="$acquired" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WT_RETURN_FAIL=1 \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/brigade-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home after return failure setup"
  fi
  acquired_abs="$acquired"
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not report original acquired-home rejection"
  grep -F "warning: failed to remove wt-created home $acquired_abs during seed rollback" "$err" >/dev/null \
    || fail "seed rollback did not warn when wt remove failed"
  grep -F "wt remove -f -D --foreground $acquired_abs" "$log" >/dev/null \
    || fail "failed rollback did not attempt wt remove"
  pass "home seed rollback warns when wt-acquired remove fails"
}

test_home_seed_does_not_return_unsafe_acquired_home() {
  local home descendant fakebin log err test_root
  home="$TMP_ROOT/dash-active-home"
  descendant="$home/data/dash-descendant-home"
  test_root="$TMP_ROOT/dash-active-test-root"
  err="$TMP_ROOT/dash-active.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/dash-active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  make_brigade_git_root "$test_root"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/dash-active-fake")
  log="$TMP_ROOT/dash-active-fake/wezterm.log"

  # Use explicit path (not -) to test the active-home rejection; wt switch --create
  # cannot create a worktree at an existing non-empty directory in real life.
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$test_root" \
    FM_FAKE_WEZTERM_LOG="$log" \
    "$ROOT/bin/brigade-home-seed.sh" dash "$home" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an explicit home path matching the active brigade home"
  fi
  grep -F 'sous-chef home cannot be the active brigade home' "$err" >/dev/null \
    || fail "seed did not explain active acquired-home rejection"
  grep -F "wt remove" "$log" >/dev/null \
    && fail "seed removed an unsafe acquired active home via wt"
  [ -d "$home/projects/alpha" ] || fail "unsafe acquired-home rollback removed the active home"

  : > "$log"
  mkdir -p "$descendant"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$test_root" \
    FM_FAKE_WT_HOME="$descendant" FM_FAKE_WEZTERM_LOG="$log" \
    "$ROOT/bin/brigade-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed accepted an acquired home inside the active brigade home"
  fi
  grep -F 'sous-chef home cannot be inside the active brigade home' "$err" >/dev/null \
    || fail "seed did not explain active descendant acquired-home rejection"
  grep -F "wt remove" "$log" >/dev/null \
    && fail "seed removed an unsafe acquired active descendant via wt"
  [ -d "$descendant" ] || fail "unsafe acquired-home rollback removed the active descendant"
  pass "home seeding leaves unsafe acquired active homes untouched"
}

test_home_seed_rolls_back_failed_clone() {
  local home subhome err missing_remote
  home="$TMP_ROOT/rollback-home"
  subhome="$TMP_ROOT/rollback-subhome"
  err="$TMP_ROOT/rollback-home.err"
  missing_remote="$TMP_ROOT/remotes/missing-beta.git"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_init_commit "$home/projects/beta"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/rollback-alpha.git"
  git -C "$home/projects/beta" remote add origin "file://$missing_remote"
  cat > "$home/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-06-22)
- beta [direct-PR] - beta project (added 2026-06-22)
EOF

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='rollback scope' FM_SECONDMATE_SCOPE='rollback scope' \
    "$ROOT/bin/brigade-home-seed.sh" rollback "$subhome" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though the second project clone failed"
  fi
  grep -F 'does not appear to be a git repository' "$err" >/dev/null \
    || grep -F 'repository' "$err" >/dev/null \
    || fail "seed failure did not include the clone error"
  [ ! -e "$subhome" ] || fail "failed seed left the newly created sous-chef home behind"
  [ ! -e "$subhome/.brigade-sous-chef-home" ] || fail "failed seed left a subhome marker"
  [ ! -e "$subhome/projects/alpha" ] || fail "failed seed left a previously cloned project"
  [ ! -e "$home/data/rollback/brief.md" ] || fail "failed seed left a generated charter brief"
  if [ -f "$home/data/sous-chefs.md" ] && grep -F -- '- rollback ' "$home/data/sous-chefs.md" >/dev/null; then
    fail "failed seed left a registry route"
  fi
  pass "home seeding rolls back failed clone attempts without residue"
}

test_home_seed_refuses_missing_filled_charter() {
  local home subhome err
  home="$TMP_ROOT/missing-charter-home"
  subhome="$TMP_ROOT/missing-charter-subhome"
  err="$TMP_ROOT/missing-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/missing-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a direct seed without a filled charter"
  fi
  grep -F 'no filled sous-chef charter brief' "$err" >/dev/null \
    || fail "seed did not explain missing filled charter refusal"
  [ ! -e "$subhome" ] || fail "missing charter seed left a generated subhome"
  [ ! -e "$home/data/design/brief.md" ] || fail "missing charter seed generated a placeholder charter"
  pass "home seeding refuses direct seed without filled charter text"
}

test_home_seed_refuses_placeholder_charter() {
  local home subhome err
  home="$TMP_ROOT/placeholder-charter-home"
  subhome="$TMP_ROOT/placeholder-charter-subhome"
  err="$TMP_ROOT/placeholder-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/placeholder-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  FM_HOME="$home" "$ROOT/bin/brigade-brief.sh" design --sous-chef alpha >/dev/null \
    || fail "placeholder charter scaffold failed"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an unfilled placeholder charter"
  fi
  grep -F 'still contains {TASK}' "$err" >/dev/null \
    || fail "seed did not explain placeholder charter refusal"
  [ ! -e "$subhome" ] || fail "placeholder charter seed left a generated subhome"
  [ ! -e "$subhome/projects/alpha" ] || fail "placeholder charter seed cloned before refusing"
  pass "home seeding refuses unfilled placeholder charters"
}

test_home_seed_refuses_empty_charter_fields() {
  local home subhome err
  home="$TMP_ROOT/empty-charter-home"
  subhome="$TMP_ROOT/empty-charter-subhome"
  err="$TMP_ROOT/empty-charter.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/empty-charter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='   ' "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a whitespace-only charter"
  fi
  grep -F 'empty Charter section' "$err" >/dev/null \
    || fail "seed did not explain empty charter refusal"
  [ ! -e "$subhome" ] || fail "empty charter seed left a generated subhome"

  rm -rf "$home/data/design" "$subhome" "$err"
  FM_SECONDMATE_SCOPE='   ' scaffold_sous-chef_charter "$home" design 'filled charter' alpha \
    || fail "empty scope fixture scaffold failed"
  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted an empty routing scope"
  fi
  grep -F 'empty Routing scope section' "$err" >/dev/null \
    || fail "seed did not explain empty routing scope refusal"
  [ ! -e "$subhome" ] || fail "empty routing scope seed left a generated subhome"
  pass "home seeding refuses empty normalized charter fields"
}

test_home_seed_refuses_local_only_project() {
  local home subhome err
  home="$TMP_ROOT/local-only-seed-home"
  subhome="$TMP_ROOT/local-only-seed-subhome"
  err="$TMP_ROOT/local-only-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  printf '%s\n' '- alpha [local-only] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed allowed a local-only project into a sous-chef home"
  fi
  grep -F 'project alpha is local-only; sous-chef routes support only no-mistakes and direct-PR projects' "$err" >/dev/null \
    || fail "seed did not explain local-only project rejection"
  [ ! -e "$subhome" ] || fail "seed created a subhome before rejecting a local-only project"
  pass "home seeding refuses local-only projects"
}

test_home_seed_refuses_registry_delimiter_home() {
  local home subhome err
  home="$TMP_ROOT/delimiter-home"
  subhome="$TMP_ROOT/delimiter)subhome"
  err="$TMP_ROOT/delimiter-home.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/delimiter-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='delimiter charter' "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home path with registry delimiters"
  fi
  grep -F 'sous-chef home path contains registry delimiters' "$err" >/dev/null \
    || fail "seed did not explain delimiter home refusal"
  [ ! -e "$subhome/.brigade-sous-chef-home" ] || fail "delimiter home seed wrote a marker"
  if [ -f "$home/data/sous-chefs.md" ] && grep -F -- '- design ' "$home/data/sous-chefs.md" >/dev/null; then
    fail "delimiter home seed wrote a registry route"
  fi
  pass "home seeding refuses registry delimiter home paths"
}

test_home_seed_refuses_active_home_and_root() {
  local home err active_ancestor active_descendant root_clone root_descendant root_ancestor root_inside
  active_ancestor="$TMP_ROOT/active-seed-ancestor"
  home="$active_ancestor/main-home"
  err="$TMP_ROOT/active-seed.err"
  active_descendant="$home/nested/design-home"
  root_clone="$TMP_ROOT/active-seed-root"
  root_descendant="$root_clone/tmp/design-home"
  root_ancestor="$TMP_ROOT/active-seed-root-ancestor"
  root_inside="$root_ancestor/nested-root"
  git clone --quiet "$ROOT" "$active_ancestor"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/active-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_sous-chef_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for active-home seed test"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$home" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sous-chef home to reuse active FM_HOME"
  fi
  grep -F 'sous-chef home cannot be the active brigade home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME rejection"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$active_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sous-chef home inside active FM_HOME"
  fi
  grep -F 'sous-chef home cannot be inside the active brigade home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME descendant rejection"
  [ ! -e "$home/nested" ] || fail "seed created a directory inside active FM_HOME before descendant rejection"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$active_ancestor" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sous-chef home to contain active FM_HOME"
  fi
  grep -F 'sous-chef home cannot be an ancestor of the active brigade home' "$err" >/dev/null \
    || fail "seed did not explain active FM_HOME ancestor rejection"
  [ ! -f "$active_ancestor/.brigade-sous-chef-home" ] || fail "seed marked an ancestor of active FM_HOME"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$ROOT" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sous-chef home to reuse FM_ROOT"
  fi
  grep -F 'sous-chef home cannot be the brigade repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT rejection"

  git clone --quiet "$ROOT" "$root_clone"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$root_clone" "$ROOT/bin/brigade-home-seed.sh" design "$root_descendant" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sous-chef home inside FM_ROOT"
  fi
  grep -F 'sous-chef home cannot be inside the brigade repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT descendant rejection"
  [ ! -e "$root_clone/tmp" ] || fail "seed created a directory inside FM_ROOT before descendant rejection"

  git clone --quiet "$ROOT" "$root_ancestor"
  git clone --quiet "$ROOT" "$root_inside"
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$root_inside" "$ROOT/bin/brigade-home-seed.sh" design "$root_ancestor" alpha >/dev/null 2>"$err"; then
    fail "seed allowed sous-chef home to contain FM_ROOT"
  fi
  grep -F 'sous-chef home cannot be an ancestor of the brigade repo' "$err" >/dev/null \
    || fail "seed did not explain FM_ROOT ancestor rejection"
  [ ! -f "$root_ancestor/.brigade-sous-chef-home" ] || fail "seed marked an ancestor of FM_ROOT"
  pass "home seeding refuses active home and repo root"
}

test_home_seed_refuses_home_marked_for_another_id() {
  local home subhome err
  home="$TMP_ROOT/marked-seed-home"
  subhome="$TMP_ROOT/marked-seed-subhome"
  err="$TMP_ROOT/marked-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/marked-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  printf 'other\n' > "$subhome/.brigade-sous-chef-home"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_sous-chef_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for marked-home seed test"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home marked for another sous-chef"
  fi
  grep -F 'already marked for other' "$err" >/dev/null || fail "seed did not explain marked-home rejection"
  [ "$(cat "$subhome/.brigade-sous-chef-home")" = "other" ] || fail "seed overwrote another sous-chef marker"
  pass "home seeding refuses homes marked for another id"
}

test_home_seed_refuses_home_registered_to_another_id() {
  local home subhome subhome_abs err
  home="$TMP_ROOT/registered-seed-home"
  subhome="$TMP_ROOT/registered-seed-subhome"
  err="$TMP_ROOT/registered-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/registered-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  printf '%s\n' '- other - other domain (home: '"$subhome_abs"'; scope: other domain; projects: beta; added 2026-06-22)' > "$home/data/sous-chefs.md"
  scaffold_sous-chef_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for registered-home seed test"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed reused a home registered to another sous-chef"
  fi
  grep -F 'already registered to other' "$err" >/dev/null || fail "seed did not explain registered-home rejection"
  [ ! -e "$subhome/.brigade-sous-chef-home" ] || fail "seed wrote a marker before rejecting a registered home"
  pass "home seeding refuses homes registered to another id"
}

test_home_seed_refuses_reassigning_existing_id_to_different_home() {
  local home first second first_abs second_abs err
  home="$TMP_ROOT/reassign-id-home"
  first="$TMP_ROOT/reassign-id-first"
  second="$TMP_ROOT/reassign-id-second"
  err="$TMP_ROOT/reassign-id.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/reassign-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='design domain' FM_SECONDMATE_SCOPE='design domain' \
    "$ROOT/bin/brigade-home-seed.sh" design "$first" alpha >/dev/null \
    || fail "initial seed failed for reassigning-id test"
  first_abs=$(cd "$first" && pwd -P)

  if FM_HOME="$home" FM_SECONDMATE_CHARTER='design domain' FM_SECONDMATE_SCOPE='design domain' \
    "$ROOT/bin/brigade-home-seed.sh" design "$second" alpha >/dev/null 2>"$err"; then
    fail "seed reassigned an existing sous-chef id to a different home"
  fi
  grep -F "sous-chef id design is already registered to home $first_abs" "$err" >/dev/null \
    || fail "seed did not explain same-id different-home rejection"
  [ ! -e "$second" ] || fail "failed id reassignment created the new subhome"
  [ "$(cat "$first/.brigade-sous-chef-home")" = design ] || fail "failed id reassignment changed the original marker"
  grep -F "home: $first_abs" "$home/data/sous-chefs.md" >/dev/null \
    || fail "failed id reassignment did not preserve the original registry route"
  second_abs=$(cd "$(dirname "$second")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$second")")
  grep -F "home: $second_abs" "$home/data/sous-chefs.md" >/dev/null \
    && fail "failed id reassignment recorded the rejected home"
  pass "home seeding refuses same-id reassignment to a different home"
}

test_home_seed_refuses_home_overlapping_registered_home() {
  local home registered_parent registered_child nested parent err
  home="$TMP_ROOT/overlap-seed-home"
  registered_parent="$TMP_ROOT/overlap-registered-parent"
  registered_child="$TMP_ROOT/overlap-registered-child-parent/child"
  nested="$registered_parent/nested"
  parent="$TMP_ROOT/overlap-registered-child-parent"
  err="$TMP_ROOT/overlap-seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/overlap-alpha.git"
  git clone --quiet "$ROOT" "$registered_parent"
  git clone --quiet "$ROOT" "$registered_child"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  cat > "$home/data/sous-chefs.md" <<EOF
- parent - parent domain (home: $registered_parent; scope: parent domain; projects: beta; added 2026-06-22)
- child - child domain (home: $registered_child; scope: child domain; projects: gamma; added 2026-06-22)
EOF

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$nested" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home inside a registered sous-chef home"
  fi
  grep -F 'overlaps registered sous-chef home' "$err" >/dev/null \
    || fail "seed did not explain registered ancestor overlap"
  [ ! -e "$nested" ] || fail "seed created a nested home inside a registered home"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$parent" alpha >/dev/null 2>"$err"; then
    fail "seed accepted a home containing a registered sous-chef home"
  fi
  grep -F 'overlaps registered sous-chef home' "$err" >/dev/null \
    || fail "seed did not explain registered descendant overlap"
  [ ! -f "$parent/.brigade-sous-chef-home" ] || fail "seed marked a home containing a registered home"
  pass "home seeding refuses registered home overlaps"
}

test_home_seed_refuses_remote_backed_project_without_origin() {
  local home subhome err
  home="$TMP_ROOT/no-origin-home"
  subhome="$TMP_ROOT/no-origin-subhome"
  err="$TMP_ROOT/no-origin.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_sous-chef_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for no-origin seed test"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed allowed remote-backed project without origin"
  fi
  grep -F 'project alpha is direct-PR but has no origin remote' "$err" >/dev/null || fail "seed did not explain missing origin for remote-backed project"
  pass "remote-backed subhome seeding requires a source origin"
}

test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin() {
  local home subhome subhome_abs err expected
  home="$TMP_ROOT/wrong-origin-home"
  subhome="$TMP_ROOT/wrong-origin-subhome"
  err="$TMP_ROOT/wrong-origin.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/wrong-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  subhome_abs=$(cd "$subhome" && pwd -P)
  mkdir -p "$subhome/projects"
  git clone --quiet "$home/projects/alpha" "$subhome/projects/alpha"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_sous-chef_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for wrong-origin seed test"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed accepted existing remote-backed project with wrong origin"
  fi
  expected=$(git -C "$home/projects/alpha" remote get-url origin)
  grep -F "seeded project alpha at $subhome_abs/projects/alpha has origin" "$err" >/dev/null \
    || fail "seed did not identify wrong origin for existing remote-backed project"
  grep -F "expected $expected" "$err" >/dev/null \
    || fail "seed did not report expected origin for existing remote-backed project"
  pass "remote-backed subhome seeding validates existing destination origins"
}

test_home_seed_resolves_relative_source_origins() {
  local home subhome subhome_abs expected out actual
  home="$TMP_ROOT/relative-origin-home"
  subhome="$TMP_ROOT/relative-origin-subhome"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$home/remotes"
  fm_git_init_commit "$home/projects/alpha"
  git clone --quiet --bare "$home/projects/alpha" "$home/remotes/relative-alpha.git"
  git -C "$home/projects/alpha" remote add origin ../../remotes/relative-alpha.git
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_sous-chef_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for relative origin seed test"

  out=$(FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha)
  subhome_abs=$(cd "$subhome" && pwd -P)
  expected=$(cd "$home/remotes/relative-alpha.git" && pwd -P)
  printf '%s\n' "$out" | grep -F "home=$subhome_abs" >/dev/null || fail "seed did not report relative-origin subhome"
  [ -d "$subhome/projects/alpha/.git" ] || fail "relative source origin was not cloned"
  actual=$(git -C "$subhome/projects/alpha" remote get-url origin)
  [ "$actual" = "$expected" ] || fail "relative source origin was not cloned through the resolved path"
  FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null \
    || fail "relative source origin did not compare equal on reseed"
  pass "home seeding resolves relative source origins against the source project"
}

test_home_seed_skips_initialized_existing_no_mistakes_projects() {
  local home subhome err fakebin log origin
  home="$TMP_ROOT/existing-initialized-home"
  subhome="$TMP_ROOT/existing-initialized-subhome"
  err="$TMP_ROOT/existing-initialized.err"
  log="$TMP_ROOT/existing-initialized-no-mistakes.log"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_init_commit "$home/projects/beta"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/existing-alpha.git"
  fm_git_add_origin "$home/projects/beta" "$TMP_ROOT/remotes/existing-beta.git"
  git clone --quiet "$ROOT" "$subhome"
  mkdir -p "$subhome/projects"
  origin=$(git -C "$home/projects/alpha" remote get-url origin)
  git clone --quiet "$origin" "$subhome/projects/alpha"
  git -C "$subhome/projects/alpha" remote add no-mistakes "$TMP_ROOT/no-mistakes-alpha.git"
  printf '%s\n' '- alpha - alpha project (added 2026-06-22)' '- beta - beta project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_recording_no_mistakes "$TMP_ROOT/existing-initialized-fake")
  : > "$log"

  if PATH="$fakebin:$PATH" FM_FAKE_NO_MISTAKES_LOG="$log" FM_FAKE_NO_MISTAKES_FAIL_PROJECT=beta \
    FM_HOME="$home" FM_SECONDMATE_CHARTER='existing init rollback scope' FM_SECONDMATE_SCOPE='existing init rollback scope' \
    "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha beta >/dev/null 2>"$err"; then
    fail "seed succeeded even though later no-mistakes initialization failed"
  fi
  grep -F 'failed to initialize no-mistakes for beta' "$err" >/dev/null \
    || fail "seed did not explain later no-mistakes initialization failure"
  grep -F "$subhome/projects/alpha" "$log" >/dev/null \
    && fail "seed ran no-mistakes against an initialized existing clone"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-init" ] || fail "seed mutated initialized existing clone with no-mistakes init"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-doctor" ] || fail "seed mutated initialized existing clone with no-mistakes doctor"
  [ ! -e "$subhome/projects/beta" ] || fail "failed seed left a newly cloned project after no-mistakes failure"
  pass "home seeding skips initialized existing no-mistakes clones"
}

test_home_seed_refuses_uninitialized_existing_no_mistakes_project() {
  local home subhome err fakebin log origin
  home="$TMP_ROOT/existing-uninitialized-home"
  subhome="$TMP_ROOT/existing-uninitialized-subhome"
  err="$TMP_ROOT/existing-uninitialized.err"
  log="$TMP_ROOT/existing-uninitialized-no-mistakes.log"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/uninitialized-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  mkdir -p "$subhome/projects"
  origin=$(git -C "$home/projects/alpha" remote get-url origin)
  git clone --quiet "$origin" "$subhome/projects/alpha"
  printf '%s\n' '- alpha - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  fakebin=$(make_recording_no_mistakes "$TMP_ROOT/existing-uninitialized-fake")
  : > "$log"

  if PATH="$fakebin:$PATH" FM_FAKE_NO_MISTAKES_LOG="$log" \
    FM_HOME="$home" FM_SECONDMATE_CHARTER='existing uninitialized scope' \
    "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed initialized a preexisting no-mistakes clone"
  fi
  grep -F 'refusing to mutate preexisting clone' "$err" >/dev/null \
    || fail "seed did not explain uninitialized existing no-mistakes clone refusal"
  [ ! -s "$log" ] || fail "seed ran no-mistakes before refusing an uninitialized existing clone"
  [ ! -f "$subhome/projects/alpha/.no-mistakes-init" ] || fail "seed mutated uninitialized existing clone"
  pass "home seeding refuses uninitialized existing no-mistakes clones"
}

test_home_seed_refuses_project_destinations_outside_subhome() {
  local home subhome sink err
  home="$TMP_ROOT/symlink-project-home"
  subhome="$TMP_ROOT/symlink-project-subhome"
  sink="$home/data/symlink-projects"
  err="$TMP_ROOT/symlink-project.err"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$sink"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-alpha.git"
  git clone --quiet "$ROOT" "$subhome"
  rm -rf "$subhome/projects"
  ln -s "$sink" "$subhome/projects"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_sous-chef_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink destination seed test"

  if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
    fail "seed followed a subhome projects symlink outside the subhome"
  fi
  grep -F 'sous-chef projects directory must resolve inside the sous-chef home' "$err" >/dev/null \
    || fail "seed did not explain unsafe project destination rejection"
  [ ! -e "$sink/alpha" ] || fail "seed cloned a project through an unsafe projects symlink"
  [ ! -f "$subhome/.brigade-sous-chef-home" ] || fail "seed marked subhome after unsafe project destination rejection"
  pass "home seeding refuses project destinations outside the subhome"
}

test_home_seed_refuses_operational_dirs_outside_subhome() {
  local home subhome sink err opdir
  home="$TMP_ROOT/symlink-opdir-home"
  err="$TMP_ROOT/symlink-opdir.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-opdir-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_sous-chef_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink operational dir seed test"

  for opdir in data state config; do
    subhome="$TMP_ROOT/symlink-opdir-subhome-$opdir"
    sink="$home/data/symlink-opdir-$opdir"
    rm -rf "$subhome" "$sink"
    git clone --quiet "$ROOT" "$subhome"
    mkdir -p "$sink"
    rm -rf "${subhome:?}/${opdir:?}"
    ln -s "$sink" "$subhome/$opdir"
    if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
      fail "seed accepted a subhome with $opdir symlinked outside the subhome"
    fi
    grep -F "sous-chef $opdir directory must resolve inside the sous-chef home" "$err" >/dev/null \
      || fail "seed did not explain unsafe $opdir directory rejection"
    [ ! -f "$subhome/.brigade-sous-chef-home" ] || fail "seed marked subhome after unsafe $opdir directory rejection"
  done
  pass "home seeding refuses operational directories outside the subhome"
}

test_home_seed_refuses_symlinked_leaf_files() {
  local home subhome sink err leaf target expected
  home="$TMP_ROOT/symlink-leaf-home"
  err="$TMP_ROOT/symlink-leaf.err"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/symlink-leaf-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  scaffold_sous-chef_charter "$home" design 'design domain' alpha || fail "charter scaffold failed for symlink leaf seed test"

  for leaf in data/projects.md data/charter.md .brigade-sous-chef-home; do
    subhome="$TMP_ROOT/symlink-leaf-subhome-${leaf//\//-}"
    sink="$home/data/symlink-leaf-${leaf//\//-}"
    rm -rf "$subhome" "$sink"
    git clone --quiet "$ROOT" "$subhome"
    mkdir -p "$(dirname "$subhome/$leaf")" "$(dirname "$sink")"
    expected=outside
    if [ "$leaf" = ".brigade-sous-chef-home" ]; then
      expected=design
    fi
    printf '%s\n' "$expected" > "$sink"
    ln -s "$sink" "$subhome/$leaf"
    if FM_HOME="$home" "$ROOT/bin/brigade-home-seed.sh" design "$subhome" alpha >/dev/null 2>"$err"; then
      fail "seed accepted symlinked leaf file $leaf"
    fi
    grep -F 'sous-chef leaf file must not be a symlink:' "$err" >/dev/null \
      || fail "seed did not explain symlinked leaf refusal for $leaf"
    target=$(cat "$sink")
    [ "$target" = "$expected" ] || fail "seed overwrote outside symlink target for $leaf"
    [ ! -f "$subhome/.brigade-sous-chef-home" ] || [ "$leaf" = ".brigade-sous-chef-home" ] || fail "seed marked subhome after symlinked leaf refusal"
  done
  pass "home seeding refuses symlinked leaf files"
}

test_sous-chef_spawn_requires_seeded_matching_home() {
  local home subhome wronghome marker_only active_descendant active_ancestor ancestor_active_home fakeroot root_descendant root_ancestor root_inside fakebin log err
  home="$TMP_ROOT/spawn-validate-home"
  subhome="$TMP_ROOT/spawn-validate-subhome"
  wronghome="$TMP_ROOT/spawn-validate-wronghome"
  marker_only="$TMP_ROOT/spawn-validate-marker-only"
  active_descendant="$home/data/spawn-descendant-home"
  active_ancestor="$TMP_ROOT/spawn-active-ancestor"
  ancestor_active_home="$active_ancestor/main-home"
  fakeroot="$TMP_ROOT/spawn-validate-root"
  root_descendant="$fakeroot/tmp/spawn-descendant-home"
  root_ancestor="$TMP_ROOT/spawn-root-ancestor"
  root_inside="$root_ancestor/repo"
  mkdir -p "$home/data" "$home/state" "$subhome/data" "$wronghome/data" "$marker_only/data" "$active_descendant/data" "$root_descendant/data" "$fakeroot/bin"
  cat > "$fakeroot/bin/brigade-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/brigade-guard.sh"
  mkdir -p "$ancestor_active_home/data" "$ancestor_active_home/state" "$active_ancestor/data" "$root_ancestor/data" "$root_inside/bin"
  cat > "$root_inside/bin/brigade-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root_inside/bin/brigade-guard.sh"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/spawn-validate-fake")
  log="$TMP_ROOT/spawn-validate-fake/wezterm.log"
  err="$TMP_ROOT/spawn-validate.err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/brigade-spawn.sh" domain "$subhome" codex --sous-chef >/dev/null 2>"$err"; then
    fail "sous-chef spawn accepted an unseeded home"
  fi
  grep -F 'not a seeded sous-chef home' "$err" >/dev/null || fail "spawn did not explain missing seed marker"
  # Canonical ordering proof: validation runs before any pane side-effect. Every rejection
  # reason below shares this one linear pre-launch path, so they each assert only their own
  # refusal message rather than re-proving "no pane created before validation" each time.
  grep -F 'spawn ' "$log" >/dev/null && fail "spawn created a pane before validation"

  printf 'other\n' > "$wronghome/.brigade-sous-chef-home"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/brigade-spawn.sh" domain "$wronghome" codex --sous-chef >/dev/null 2>"$err"; then
    fail "sous-chef spawn accepted a home marked for another sous-chef"
  fi
  grep -F 'marked for sous-chef other, expected domain' "$err" >/dev/null || fail "spawn did not explain marker mismatch"

  printf 'domain\n' > "$marker_only/.brigade-sous-chef-home"
  printf 'charter\n' > "$marker_only/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/brigade-spawn.sh" domain "$marker_only" codex --sous-chef >/dev/null 2>"$err"; then
    fail "sous-chef spawn accepted a marked home missing AGENTS.md"
  fi
  grep -F 'not a brigade home (missing AGENTS.md)' "$err" >/dev/null || fail "spawn did not explain missing AGENTS.md"

  printf '# Brigade\n' > "$marker_only/AGENTS.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/brigade-spawn.sh" domain "$marker_only" codex --sous-chef >/dev/null 2>"$err"; then
    fail "sous-chef spawn accepted a marked home missing bin"
  fi
  grep -F 'not a brigade home (missing bin/)' "$err" >/dev/null || fail "spawn did not explain missing bin"

  printf 'domain\n' > "$home/.brigade-sous-chef-home"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/brigade-spawn.sh" domain "$home" codex --sous-chef >/dev/null 2>"$err"; then
    fail "sous-chef spawn accepted the active home"
  fi
  grep -F 'sous-chef home cannot be the active brigade home' "$err" >/dev/null || fail "spawn did not reject active home"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/brigade-spawn.sh" domain "$ROOT" codex --sous-chef >/dev/null 2>"$err"; then
    fail "sous-chef spawn accepted the brigade repo root"
  fi
  grep -F 'sous-chef home cannot be the brigade repo' "$err" >/dev/null || fail "spawn did not reject brigade repo root"

  printf 'domain\n' > "$active_descendant/.brigade-sous-chef-home"
  printf 'charter\n' > "$active_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/brigade-spawn.sh" domain "$active_descendant" codex --sous-chef >/dev/null 2>"$err"; then
    fail "sous-chef spawn accepted a home inside the active brigade home"
  fi
  grep -F 'sous-chef home cannot be inside the active brigade home' "$err" >/dev/null || fail "spawn did not reject active home descendant"

  printf 'domain\n' > "$active_ancestor/.brigade-sous-chef-home"
  printf 'charter\n' > "$active_ancestor/data/charter.md"
  if PATH="$fakebin:$PATH" FM_HOME="$ancestor_active_home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/brigade-spawn.sh" domain "$active_ancestor" codex --sous-chef >/dev/null 2>"$err"; then
    fail "sous-chef spawn accepted a home containing the active brigade home"
  fi
  grep -F 'sous-chef home cannot be an ancestor of the active brigade home' "$err" >/dev/null || fail "spawn did not reject active home ancestor"

  printf 'domain\n' > "$root_descendant/.brigade-sous-chef-home"
  printf 'charter\n' > "$root_descendant/data/charter.md"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/brigade-spawn.sh" domain "$root_descendant" codex --sous-chef >/dev/null 2>"$err"; then
    fail "sous-chef spawn accepted a home inside the brigade repo"
  fi
  grep -F 'sous-chef home cannot be inside the brigade repo' "$err" >/dev/null || fail "spawn did not reject repo root descendant"

  printf 'domain\n' > "$root_ancestor/.brigade-sous-chef-home"
  printf 'charter\n' > "$root_ancestor/data/charter.md"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root_inside" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-validate-fake/pane.txt" \
    "$ROOT/bin/brigade-spawn.sh" domain "$root_ancestor" codex --sous-chef >/dev/null 2>"$err"; then
    fail "sous-chef spawn accepted a home containing the brigade repo"
  fi
  grep -F 'sous-chef home cannot be an ancestor of the brigade repo' "$err" >/dev/null || fail "spawn did not reject repo ancestor"

  pass "sous-chef spawn validates homes before launch"
}

test_sous-chef_spawn_refuses_operational_dirs_outside_subhome() {
  local home subhome sink fakebin log err opdir
  home="$TMP_ROOT/spawn-opdir-home"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/spawn-opdir-fake")
  log="$TMP_ROOT/spawn-opdir-fake/wezterm.log"
  err="$TMP_ROOT/spawn-opdir.err"
  mkdir -p "$home/data" "$home/state"

  for opdir in data state config projects; do
    subhome="$TMP_ROOT/spawn-opdir-subhome-$opdir"
    sink="$home/data/spawn-opdir-$opdir"
    rm -rf "$subhome" "$sink"
    mkdir -p "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects" "$sink"
    printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
    printf 'charter\n' > "$subhome/data/charter.md"
    rm -rf "${subhome:?}/${opdir:?}"
    ln -s "$sink" "$subhome/$opdir"
    if [ "$opdir" = data ]; then
      printf 'charter\n' > "$sink/charter.md"
    fi
    : > "$log"
    if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/spawn-opdir-fake/pane.txt" \
      "$ROOT/bin/brigade-spawn.sh" domain "$subhome" codex --sous-chef >/dev/null 2>"$err"; then
      fail "sous-chef spawn accepted a subhome with $opdir symlinked outside the subhome"
    fi
    grep -F "sous-chef $opdir directory must resolve inside the sous-chef home" "$err" >/dev/null \
      || fail "spawn did not explain unsafe $opdir directory rejection"
    grep -F 'spawn ' "$log" >/dev/null && fail "spawn created a pane before unsafe $opdir directory validation"
  done
  pass "sous-chef spawn refuses operational directories outside the subhome"
}

test_fm_send_refuses_bare_window_without_home_meta() {
  # The happy path (a bare brigade-<id> resolves the window recorded in THIS home's
  # meta and never a foreign same-named window) is asserted in the lifecycle e2e.
  # Here: with NO meta for the id, send must refuse rather than fall back to a
  # foreign same-named window that list-windows happens to return.
  local home fakebin log err
  home="$TMP_ROOT/send-home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/send-fake")
  log="$TMP_ROOT/send-fake/wezterm.log"
  err="$TMP_ROOT/send-fake/send.err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="other-session:brigade-missing" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/send-fake/pane.txt" \
    "$ROOT/bin/brigade-send.sh" brigade-missing 'wrong home' >/dev/null 2>"$err"; then
    fail "brigade-send sent to a bare brigade window without home metadata"
  fi
  grep -F "no metadata for brigade-missing in $home/state" "$err" >/dev/null \
    || fail "brigade-send did not explain missing home metadata"
  grep -F 'send-keys -t other-session:brigade-missing' "$log" >/dev/null \
    && fail "brigade-send fell back to a foreign same-name window"
  pass "brigade-send refuses a bare brigade window with no metadata in this home"
}

test_sous-chef_teardown_retires_empty_home() {
  local home subhome subhome_abs fakebin log lease fmroot
  home="$TMP_ROOT/teardown-home"
  subhome="$TMP_ROOT/teardown-subhome"
  fmroot="$TMP_ROOT/teardown-fmroot"
  make_brigade_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/teardown-fake")
  log="$TMP_ROOT/teardown-fake/wezterm.log"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/teardown-fake/pane.txt" \
    "$ROOT/bin/brigade-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for empty sous-chef home"
  grep -F "wt remove -f -D --foreground $subhome_abs" "$log" >/dev/null || fail "teardown did not remove the sous-chef home via wt"
  [ ! -d "$subhome" ] || fail "teardown did not remove the retired sous-chef home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/sous-chefs.md" >/dev/null && fail "teardown did not remove sous-chef registry route"
  pass "sous-chef teardown retires empty homes and releases routing"
}

test_sous-chef_teardown_refuses_failed_leased_home_return() {
  local home subhome subhome_abs fakebin log fmroot err rc
  home="$TMP_ROOT/teardown-return-fail-home"
  subhome="$TMP_ROOT/teardown-return-fail-subhome"
  fmroot="$TMP_ROOT/teardown-return-fail-fmroot"
  err="$TMP_ROOT/teardown-return-fail.err"
  make_brigade_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/teardown-return-fail-fake")
  log="$TMP_ROOT/teardown-return-fail-fake/wezterm.log"

  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/teardown-return-fail-fake/pane.txt" \
    FM_FAKE_WT_RETURN_FAIL=1 \
    "$ROOT/bin/brigade-teardown.sh" domain >/dev/null 2>"$err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown succeeded despite failed wt remove"
  grep -F "wt remove -f -D --foreground $subhome_abs" "$log" >/dev/null || fail "teardown did not try wt remove for the sous-chef home"
  grep -F 'error: wt remove failed for' "$err" >/dev/null || fail "teardown did not report failed wt remove"
  [ -d "$subhome" ] || fail "teardown removed a leased home after return failed"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared meta after leased home return failed"
  grep -F -- '- domain ' "$home/data/sous-chefs.md" >/dev/null || fail "teardown removed registry route after leased home return failed"
  pass "sous-chef teardown refuses to hide failed leased-home return"
}

test_sous-chef_teardown_removes_plain_clone_home_without_worktrunk_return() {
  local home subhome subhome_abs fakebin log
  home="$TMP_ROOT/plain-clone-teardown-home"
  subhome="$TMP_ROOT/plain-clone-teardown-subhome"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  mark_brigade_home "$subhome"
  printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/plain-clone-teardown-fake")
  log="$TMP_ROOT/plain-clone-teardown-fake/wezterm.log"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/plain-clone-teardown-fake/pane.txt" \
    FM_FAKE_WT_RETURN_FAIL=1 \
    "$ROOT/bin/brigade-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for plain-clone sous-chef home"
  grep -F "wt remove" "$log" >/dev/null && fail "teardown tried to wt-remove a plain-clone home"
  [ ! -d "$subhome" ] || fail "teardown did not remove the plain-clone sous-chef home"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta for plain-clone home"
  grep -F -- '- domain ' "$home/data/sous-chefs.md" >/dev/null && fail "teardown did not remove plain-clone registry route"
  pass "sous-chef teardown raw-removes plain-clone homes"
}

test_sous-chef_force_teardown_discards_child_work() {
  local home subhome childproj childwt fakebin log
  home="$TMP_ROOT/force-teardown-home"
  subhome="$TMP_ROOT/force-teardown-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/force-child-worktree"
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  fm_git_worktree "$childproj" "$childwt" force-child
  printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
  cat > "$subhome/state/child.meta" <<EOF
pane=42
tab=⏳ brigade-child
worktree=$childwt
project=$childproj
harness=echo
kind=fire
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_wezterm "$TMP_ROOT/force-teardown-fake")
  log="$TMP_ROOT/force-teardown-fake/wezterm.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/brigade-teardown.sh" domain >/dev/null 2>&1; then
    fail "teardown allowed a sous-chef with in-flight child work"
  fi
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/force-teardown-fake/pane.txt" \
    "$ROOT/bin/brigade-teardown.sh" domain --force >/dev/null 2>/dev/null \
    || fail "force teardown failed to discard child work"
  [ ! -d "$subhome" ] || fail "force teardown did not remove the retired sous-chef home"
  [ ! -d "$childwt" ] || fail "force teardown did not remove child worktree"
  [ ! -e "$home/state/domain.meta" ] || fail "teardown did not clear parent meta"
  grep -F -- '- domain ' "$home/data/sous-chefs.md" >/dev/null && fail "force teardown did not remove sous-chef registry route"
  grep -F 'kill-pane --pane-id 42' "$log" >/dev/null || fail "force teardown did not kill child/parent panes"
  pass "sous-chef force teardown discards child work"
}

test_sous-chef_force_teardown_allows_operational_dir_symlinks_inside_home() {
  local opdir home subhome target fakebin err log
  for opdir in data state config projects; do
    home="$TMP_ROOT/symlink-inside-teardown-home-$opdir"
    subhome="$TMP_ROOT/symlink-inside-teardown-subhome-$opdir"
    target="$subhome/internal-$opdir"
    err="$TMP_ROOT/symlink-inside-teardown-$opdir.err"
    rm -rf "$home" "$subhome"
    mkdir -p "$home/state" "$home/data" "$subhome" "$target"
    printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
    ln -s "$target" "$subhome/$opdir"
    cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
    printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
    fakebin=$(make_fake_wezterm "$TMP_ROOT/symlink-inside-teardown-fake-$opdir")
    log="$TMP_ROOT/symlink-inside-teardown-fake-$opdir/wezterm.log"
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/symlink-inside-teardown-fake-$opdir/pane.txt" \
      "$ROOT/bin/brigade-teardown.sh" domain --force >/dev/null 2>"$err" \
      || fail "force teardown refused $opdir symlinked inside the sous-chef home"
    [ ! -e "$subhome" ] || fail "force teardown did not remove subhome with inside $opdir symlink"
    [ ! -e "$home/state/domain.meta" ] || fail "force teardown did not clear parent meta for inside $opdir symlink"
    grep -F 'kill-pane --pane-id 42' "$log" >/dev/null || fail "force teardown did not kill parent pane for inside $opdir symlink"
  done
  pass "force teardown allows operational directory symlinks inside the subhome"
}

test_sous-chef_force_teardown_refuses_operational_dir_symlink_outside_home() {
  local home subhome external_state fakebin err log
  home="$TMP_ROOT/symlink-state-teardown-home"
  subhome="$TMP_ROOT/symlink-state-teardown-subhome"
  external_state="$home/data/external-state"
  err="$TMP_ROOT/symlink-state-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome" "$external_state"
  printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
  ln -s "$external_state" "$subhome/state"
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/symlink-state-teardown-fake")
  log="$TMP_ROOT/symlink-state-teardown-fake/wezterm.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/symlink-state-teardown-fake/pane.txt" \
    "$ROOT/bin/brigade-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown accepted a symlinked sous-chef state directory"
  fi
  [ -d "$subhome" ] || fail "force teardown removed subhome after symlinked state refusal"
  [ -d "$external_state" ] || fail "force teardown removed external symlink target"
  grep -F 'state directory' "$err" >/dev/null || fail "teardown did not explain symlinked state refusal"
  grep -F 'resolves outside the sous-chef home' "$err" >/dev/null || fail "teardown did not identify unsafe state symlink"
  grep -F 'kill-pane' "$log" >/dev/null && fail "teardown killed a window before symlinked state refusal"
  pass "force teardown refuses operational directory symlinks outside the subhome"
}

test_sous-chef_teardown_path_boundary_matrix() {
  # The teardown path-boundary matrix: a sous-chef home is refused (and left
  # fully intact, with no window killed before validation) when it is unmarked,
  # an ancestor of the active brigade home, inside the active brigade home,
  # or inside the brigade repo. One row per hazard, one shared assertion block.
  local row base home subhome fmroot fakebin log err expect tid
  while IFS='|' read -r row expect; do
    [ -n "$row" ] || continue
    base="$TMP_ROOT/td-pb-$row"
    fmroot="$ROOT"   # real brigade repo unless a row overrides it
    tid=domain
    case "$row" in
      unmarked)
        home="$base/main"; subhome="$base/sub"
        mkdir -p "$home/state" "$home/data" "$subhome/state"
        # No .brigade-sous-chef-home marker on purpose.
        ;;
      ancestor)
        # The home being torn down is an ANCESTOR of the active brigade home.
        subhome="$base/anc"; home="$subhome/main-home"
        mkdir -p "$home/state" "$home/data" "$subhome/state"
        printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
        ;;
      active-descendant)
        home="$base/desc"; subhome="$home/data/domain-home"
        mkdir -p "$home/state" "$home/data" "$subhome/state"
        printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
        ;;
      repo-descendant)
        home="$base/home"; fmroot="$base/root"; subhome="$fmroot/tmp/domain-home"; tid='repo-domain'
        mkdir -p "$home/state" "$home/data" "$subhome/state" "$fmroot/bin"
        cat > "$fmroot/bin/brigade-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
        chmod +x "$fmroot/bin/brigade-guard.sh"
        printf 'repo-domain\n' > "$subhome/.brigade-sous-chef-home"
        ;;
    esac
    fm_write_sous-chef_meta "$home/state/$tid.meta" "$subhome"
    printf -- '- %s - design domain (home: %s; scope: design domain; projects: alpha; added 2026-06-22)\n' \
      "$tid" "$subhome" > "$home/data/sous-chefs.md"
    fakebin=$(make_fake_wezterm "$base/fake")
    log="$base/fake/wezterm.log"
    err="$base/teardown.err"
    if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" \
      FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$base/fake/pane.txt" \
      "$ROOT/bin/brigade-teardown.sh" "$tid" >/dev/null 2>"$err"; then
      fail "teardown ($row) accepted a hazardous sous-chef home"
    fi
    grep -F "$expect" "$err" >/dev/null || fail "teardown ($row) did not explain the refusal (expected '$expect'): $(cat "$err")"
    [ -d "$subhome" ] || fail "teardown ($row) removed the protected home after refusal"
    [ -e "$home/state/$tid.meta" ] || fail "teardown ($row) cleared the parent meta after refusal"
    grep -F -- "- $tid " "$home/data/sous-chefs.md" >/dev/null || fail "teardown ($row) removed the registry route after refusal"
    grep -F 'kill-pane' "$log" >/dev/null && fail "teardown ($row) killed a window before validation"
  done <<'ROWS'
unmarked|not a seeded sous-chef home
ancestor|ancestor of the active brigade home
active-descendant|inside the active brigade home
repo-descendant|inside the brigade repo
ROWS
  pass "sous-chef teardown path-boundary matrix refuses unmarked/ancestor/active-descendant/repo-descendant homes"
}

test_sous-chef_teardown_refuses_registered_nested_home() {
  local home subhome nested fakebin err log
  home="$TMP_ROOT/nested-teardown-home"
  subhome="$TMP_ROOT/nested-teardown-subhome"
  nested="$subhome/nested-domain"
  err="$TMP_ROOT/nested-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$nested/state"
  printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
  printf 'nested\n' > "$nested/.brigade-sous-chef-home"
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  cat > "$home/state/nested.meta" <<EOF
pane=42
tab=⏳ brigade-nested
worktree=$nested
project=$nested
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$nested
projects=beta
EOF
  cat > "$home/data/sous-chefs.md" <<EOF
- domain - design domain (home: $subhome; scope: design domain; projects: alpha; added 2026-06-22)
- nested - nested domain mentions home: $TMP_ROOT/ignored-summary-home (home: $nested; scope: nested domain mentions home: $TMP_ROOT/ignored-scope-home; projects: beta; added 2026-06-22)
EOF
  fakebin=$(make_fake_wezterm "$TMP_ROOT/nested-teardown-fake")
  log="$TMP_ROOT/nested-teardown-fake/wezterm.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/nested-teardown-fake/pane.txt" \
    "$ROOT/bin/brigade-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing another registered sous-chef home"
  fi
  [ -d "$subhome" ] || fail "teardown removed registered ancestor home after refusal"
  [ -d "$nested" ] || fail "teardown removed registered nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared ancestor meta after nested-home refusal"
  [ -e "$home/state/nested.meta" ] || fail "teardown cleared nested meta after nested-home refusal"
  grep -F 'kill-pane' "$log" >/dev/null && fail "teardown killed a window before nested-home refusal"
  grep -F 'contains registered sous-chef home' "$err" >/dev/null || fail "teardown did not explain registered nested-home refusal"
  pass "sous-chef teardown refuses homes containing registered nested homes"
}

test_sous-chef_teardown_refuses_child_registry_nested_home() {
  local home subhome nested fakebin err log
  home="$TMP_ROOT/child-registry-teardown-home"
  subhome="$TMP_ROOT/child-registry-teardown-subhome"
  nested="$subhome/nested-domain"
  err="$TMP_ROOT/child-registry-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/data" "$nested/state"
  printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
  printf 'nested\n' > "$nested/.brigade-sous-chef-home"
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
  printf '%s\n' '- nested - nested domain (home: '"$nested"'; scope: nested domain; projects: beta; added 2026-06-22)' > "$subhome/data/sous-chefs.md"
  fakebin=$(make_fake_wezterm "$TMP_ROOT/child-registry-teardown-fake")
  log="$TMP_ROOT/child-registry-teardown-fake/wezterm.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/child-registry-teardown-fake/pane.txt" \
    "$ROOT/bin/brigade-teardown.sh" domain >/dev/null 2>"$err"; then
    fail "teardown removed a home containing a child-registry sous-chef home"
  fi
  [ -d "$subhome" ] || fail "teardown removed ancestor home after child-registry refusal"
  [ -d "$nested" ] || fail "teardown removed child-registry nested home after refusal"
  [ -e "$home/state/domain.meta" ] || fail "teardown cleared parent meta after child-registry refusal"
  grep -F 'kill-pane' "$log" >/dev/null && fail "teardown killed a window before child-registry refusal"
  grep -F 'contains registered sous-chef home' "$err" >/dev/null || fail "teardown did not explain child-registry nested-home refusal"
  pass "sous-chef teardown refuses nested homes from the child registry"
}

test_sous-chef_force_teardown_prevalidates_before_child_cleanup() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/prevalidate-teardown-home"
  subhome="$TMP_ROOT/prevalidate-teardown-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/prevalidate-child-worktree"
  err="$TMP_ROOT/prevalidate-teardown.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt"
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
  cat > "$subhome/state/child.meta" <<EOF
pane=42
tab=⏳ brigade-child
worktree=$childwt
project=$childproj
harness=echo
kind=fire
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_wezterm "$TMP_ROOT/prevalidate-teardown-fake")
  log="$TMP_ROOT/prevalidate-teardown-fake/wezterm.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/prevalidate-teardown-fake/pane.txt" \
    "$ROOT/bin/brigade-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown discarded child work before validating subhome"
  fi
  [ -d "$subhome" ] || fail "force teardown removed unmarked subhome after refusal"
  [ -d "$childwt" ] || fail "force teardown removed child worktree before validation"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta before validation"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta before validation"
  grep -F 'kill-pane' "$log" >/dev/null && fail "force teardown killed windows before subhome validation"
  grep -F 'not a seeded sous-chef home' "$err" >/dev/null || fail "force teardown did not explain missing seed marker"
  pass "force teardown validates subhome before child cleanup"
}

test_sous-chef_force_teardown_refuses_child_active_home_descendant() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/child-active-descendant-home"
  subhome="$TMP_ROOT/child-active-descendant-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$home/data"
  err="$TMP_ROOT/child-active-descendant.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj"
  printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
  cat > "$subhome/state/child.meta" <<EOF
pane=42
tab=⏳ brigade-child
worktree=$childwt
project=$childproj
harness=echo
kind=fire
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_wezterm "$TMP_ROOT/child-active-descendant-fake")
  log="$TMP_ROOT/child-active-descendant-fake/wezterm.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/child-active-descendant-fake/pane.txt" \
    "$ROOT/bin/brigade-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed a child worktree inside active FM_HOME"
  fi
  [ -d "$home/data" ] || fail "force teardown removed active home data"
  [ -d "$subhome" ] || fail "force teardown removed subhome after child validation refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after child validation refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after child validation refusal"
  grep -F 'kill-pane' "$log" >/dev/null && fail "force teardown killed windows before child validation refusal"
  grep -F 'inside the active brigade home' "$err" >/dev/null || fail "force teardown did not explain active home descendant rejection"
  pass "force teardown refuses child worktrees inside the active home"
}

test_sous-chef_force_teardown_refuses_child_repo_descendant() {
  local home subhome childproj childwt fakeroot fakebin err log
  home="$TMP_ROOT/child-repo-descendant-home"
  subhome="$TMP_ROOT/child-repo-descendant-subhome"
  childproj="$subhome/projects/alpha"
  fakeroot="$TMP_ROOT/child-repo-descendant-root"
  childwt="$fakeroot/data"
  err="$TMP_ROOT/child-repo-descendant.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt" "$fakeroot/bin"
  cat > "$fakeroot/bin/brigade-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakeroot/bin/brigade-guard.sh"
  printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
  cat > "$subhome/state/child.meta" <<EOF
pane=42
tab=⏳ brigade-child
worktree=$childwt
project=$childproj
harness=echo
kind=fire
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_wezterm "$TMP_ROOT/child-repo-descendant-fake")
  log="$TMP_ROOT/child-repo-descendant-fake/wezterm.log"
  if PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fakeroot" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/child-repo-descendant-fake/pane.txt" \
    "$ROOT/bin/brigade-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed a child worktree inside FM_ROOT"
  fi
  [ -d "$childwt" ] || fail "force teardown removed repo descendant worktree"
  [ -d "$subhome" ] || fail "force teardown removed subhome after repo child validation refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after repo child validation refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after repo child validation refusal"
  grep -F 'kill-pane' "$log" >/dev/null && fail "force teardown killed windows before repo child validation refusal"
  grep -F 'inside the brigade repo' "$err" >/dev/null || fail "force teardown did not explain repo descendant rejection"
  pass "force teardown refuses child worktrees inside the brigade repo"
}

test_sous-chef_force_teardown_refuses_unregistered_child_worktree() {
  local home subhome childproj childwt fakebin err log
  home="$TMP_ROOT/unregistered-child-home"
  subhome="$TMP_ROOT/unregistered-child-subhome"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/unregistered-child-worktree"
  err="$TMP_ROOT/unregistered-child.err"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$childproj" "$childwt"
  printf 'domain\n' > "$subhome/.brigade-sous-chef-home"
  cat > "$home/state/domain.meta" <<EOF
pane=42
tab=⏳ brigade-domain
worktree=$subhome
project=$subhome
harness=echo
kind=sous-chef
mode=sous-chef
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/sous-chefs.md"
  cat > "$subhome/state/child.meta" <<EOF
pane=42
tab=⏳ brigade-child
worktree=$childwt
project=$childproj
harness=echo
kind=fire
mode=no-mistakes
yolo=off
EOF
  fakebin=$(make_fake_wezterm "$TMP_ROOT/unregistered-child-fake")
  log="$TMP_ROOT/unregistered-child-fake/wezterm.log"
  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_WEZTERM_LOG="$log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/unregistered-child-fake/pane.txt" \
    "$ROOT/bin/brigade-teardown.sh" domain --force >/dev/null 2>"$err"; then
    fail "force teardown removed an unregistered child worktree"
  fi
  [ -d "$childwt" ] || fail "force teardown removed unregistered child worktree"
  [ -d "$subhome" ] || fail "force teardown removed subhome after unregistered child refusal"
  [ -e "$home/state/domain.meta" ] || fail "force teardown cleared parent meta after unregistered child refusal"
  [ -e "$subhome/state/child.meta" ] || fail "force teardown cleared child meta after unregistered child refusal"
  grep -F 'kill-pane' "$log" >/dev/null && fail "force teardown killed windows before unregistered child refusal"
  grep -F 'is not a git worktree for' "$err" >/dev/null || fail "force teardown did not explain unregistered child rejection"
  pass "force teardown refuses unregistered child worktree paths"
}

test_sous-chef_idle_pane_is_not_stale() {
  local home fakebin out pid window
  home="$TMP_ROOT/watch-home"
  mkdir -p "$home/state"
  window="brigade:brigade-domain"
  cat > "$home/state/domain.meta" <<EOF
window=$window
worktree=$TMP_ROOT/watch-subhome
project=$TMP_ROOT/watch-subhome
harness=echo
kind=sous-chef
home=$TMP_ROOT/watch-subhome
projects=alpha
EOF
  fakebin=$(make_fake_wezterm "$TMP_ROOT/watch-fake")
  out="$TMP_ROOT/watch-fake/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_WEZTERM_LOG="$TMP_ROOT/watch-fake/wezterm.log" FM_FAKE_WEZTERM_CAPTURE="$TMP_ROOT/watch-fake/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/brigade-watch.sh" > "$out" &
  pid=$!
  if ! wait_live "$pid" 25; then
    wait "$pid" || true
    grep -F "stale: $window" "$out" >/dev/null && fail "idle sous-chef pane triggered stale wake"
    fail "watcher exited unexpectedly while supervising idle sous-chef"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  grep -F "stale: $window" "$out" >/dev/null && fail "idle sous-chef pane triggered stale wake"
  pass "idle kind=sous-chef pane is healthy and not stale"
}

test_sous-chef_charter_brief_is_idle_by_default() {
  local home brief
  home="$TMP_ROOT/idle-charter-home"
  mkdir -p "$home/data" "$home/state"
  scaffold_sous-chef_charter "$home" idle-sm 'feature work for alpha' alpha
  brief="$home/data/idle-sm/brief.md"
  [ -f "$brief" ] || fail "sous-chef charter brief was not scaffolded"
  # Idle contract: waits for routed work, never self-initiates.
  grep -F 'go idle and wait silently for the main brigade' "$brief" >/dev/null \
    || fail "charter brief does not tell the sous-chef to go idle and wait for routed work"
  grep -F 'Act only on tasks the main brigade routes to you' "$brief" >/dev/null \
    || fail "charter brief does not restrict work to routed tasks"
  grep -F 'never spawn a survey, audit, or any self-directed' "$brief" >/dev/null \
    || fail "charter brief does not forbid self-initiated survey/audit work"
  # Reconcile-on-startup must remain: bootstrap and recovery still run, scoped to own work.
  grep -F 'run normal brigade bootstrap and recovery' "$brief" >/dev/null \
    || fail "charter brief dropped the bootstrap/recovery reconciliation step"
  grep -F 'only to RECONCILE work that is already yours' "$brief" >/dev/null \
    || fail "charter brief does not scope startup work to reconciling existing work"
  # Regression guard: the over-broad phrasing that got misread as "go find work" is gone.
  if grep -F 'then supervise work that matches your scope' "$brief" >/dev/null; then
    fail "charter brief still uses the over-broad 'supervise work that matches your scope' phrasing"
  fi
  pass "sous-chef charter brief is idle by default and does not self-initiate work"
}

test_backlog_handoff_aborts_safely() {
  # The happy move (verbatim into the Queued section, out-of-scope left alone,
  # idempotent re-run) is asserted in the lifecycle e2e. Here: every refusal path
  # aborts atomically and mutates neither backlog.
  local home subhome subhome_abs before
  home="$TMP_ROOT/handoff-main"
  subhome="$TMP_ROOT/handoff-sub"
  mkdir -p "$home/data" "$home/state"
  seed_sous-chef_home_marker "$subhome" design
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/sous-chefs.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-task - active work (repo: alpha, since 2026-06-20)

## Queued
- [ ] bug-z - fix bug z (repo: gamma)

## Done
- [x] old-task - shipped thing - local main (merged 2026-06-19)
EOF

  # A key matching neither backlog aborts atomically: nothing moves.
  before=$(cat "$home/data/backlog.md")
  if FM_HOME="$home" "$ROOT/bin/brigade-backlog-handoff.sh" design bug-z no-such-key >/dev/null 2>&1; then
    fail "handoff succeeded despite an unmatched key"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an unmatched key still mutated the main backlog"
  grep -F 'bug-z' "$home/data/backlog.md" >/dev/null || fail "atomic abort lost the valid bug-z item"

  # An in-flight item is refused (active ownership lives in tmux + state too).
  before=$(cat "$home/data/backlog.md")
  if FM_HOME="$home" "$ROOT/bin/brigade-backlog-handoff.sh" design live-task >/dev/null 2>&1; then
    fail "handoff accepted an in-flight backlog item"
  fi
  [ "$before" = "$(cat "$home/data/backlog.md")" ] || fail "handoff with an in-flight key mutated the main backlog"
  grep -F 'live-task' "$home/data/backlog.md" >/dev/null || fail "in-flight refusal lost the live task"
  [ ! -e "$subhome/data/backlog.md" ] || ! grep -F 'live-task' "$subhome/data/backlog.md" >/dev/null     || fail "in-flight refusal copied the live task into the sous-chef backlog"

  # An unregistered sous-chef id is refused.
  if FM_HOME="$home" "$ROOT/bin/brigade-backlog-handoff.sh" ghost bug-z >/dev/null 2>&1; then
    fail "handoff accepted an unregistered sous-chef id"
  fi
  pass "brigade-backlog-handoff aborts atomically on unmatched, in-flight, and unregistered targets"
}

test_backlog_handoff_creates_absent_section_and_refuses_non_sous-chef_home() {
  local home subhome subhome_abs projhome projhome_abs markerhome markerhome_abs symlinkhome symlinkhome_abs outside
  home="$TMP_ROOT/handoff-safety-main"
  subhome="$TMP_ROOT/handoff-safety-sub"
  projhome="$TMP_ROOT/handoff-safety-proj"
  markerhome="$TMP_ROOT/handoff-safety-marker"
  symlinkhome="$TMP_ROOT/handoff-safety-symlink"
  outside="$TMP_ROOT/handoff-safety-outside"
  mkdir -p "$home/data" "$home/state"

  # A Done item handed into a sous-chef backlog lacking a Done section gets one.
  seed_sous-chef_home_marker "$subhome" archive
  subhome_abs=$(cd "$subhome" && pwd -P)
  printf '## Queued\n- [ ] keep-me - stays (repo: alpha)\n' > "$subhome/data/backlog.md"
  printf -- '- archive - archival (home: %s; scope: archival; projects: alpha; added 2026-06-22)\n' "$subhome_abs" > "$home/data/sous-chefs.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Done
- [x] shipped-task - shipped thing - local main (merged 2026-06-19)
EOF
  FM_HOME="$home" "$ROOT/bin/brigade-backlog-handoff.sh" archive shipped-task >/dev/null \
    || fail "handoff of a Done item failed"
  grep -F '## Done' "$subhome/data/backlog.md" >/dev/null \
    || fail "handoff did not create the missing Done section in the sous-chef backlog"
  awk '/^## Done/{d=1;next} /^## /{d=0} d && /shipped-task/{found=1} END{exit found?0:1}' "$subhome/data/backlog.md" \
    || fail "Done item did not land under the created Done section"
  grep -F 'keep-me' "$subhome/data/backlog.md" >/dev/null || fail "handoff clobbered the existing sous-chef backlog content"

  # A registered home that is not a seeded sous-chef home (e.g. a project clone)
  # is refused, and nothing is written into it.
  fm_git_init_commit "$projhome"
  projhome_abs=$(cd "$projhome" && pwd -P)
  printf -- '- proj-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$projhome_abs" >> "$home/data/sous-chefs.md"
  if FM_HOME="$home" "$ROOT/bin/brigade-backlog-handoff.sh" proj-sm shipped-task >/dev/null 2>&1; then
    fail "handoff wrote into a destination that is not a seeded sous-chef home"
  fi
  [ ! -e "$projhome/data/backlog.md" ] || fail "handoff created a backlog inside a non-sous-chef home"

  mkdir -p "$markerhome/data"
  markerhome_abs=$(cd "$markerhome" && pwd -P)
  printf 'marker-sm\n' > "$markerhome/.brigade-sous-chef-home"
  printf -- '- marker-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$markerhome_abs" >> "$home/data/sous-chefs.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] marker-task - should not move (repo: alpha)
EOF
  if FM_HOME="$home" "$ROOT/bin/brigade-backlog-handoff.sh" marker-sm marker-task >/dev/null 2>&1; then
    fail "handoff accepted a marker-only directory as a sous-chef home"
  fi
  [ ! -e "$markerhome/data/backlog.md" ] || fail "handoff wrote into a marker-only directory"
  grep -F 'marker-task' "$home/data/backlog.md" >/dev/null || fail "marker-only refusal lost the main backlog item"

  seed_sous-chef_home_marker "$symlinkhome" symlink-sm
  symlinkhome_abs=$(cd "$symlinkhome" && pwd -P)
  mkdir -p "$outside"
  rm -rf "$symlinkhome/data"
  ln -s "$outside" "$symlinkhome/data"
  printf -- '- symlink-sm - bogus (home: %s; scope: bogus; projects: alpha; added 2026-06-22)\n' "$symlinkhome_abs" >> "$home/data/sous-chefs.md"
  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] symlink-task - should not move (repo: alpha)
EOF
  if FM_HOME="$home" "$ROOT/bin/brigade-backlog-handoff.sh" symlink-sm symlink-task >/dev/null 2>&1; then
    fail "handoff accepted a sous-chef home with data outside the home"
  fi
  [ ! -e "$outside/backlog.md" ] || fail "handoff wrote through a symlinked sous-chef data directory"
  grep -F 'symlink-task' "$home/data/backlog.md" >/dev/null || fail "symlink refusal lost the main backlog item"
  pass "brigade-backlog-handoff creates absent sections and refuses unsafe homes"
}

test_fm_home_parameterization
test_lock_status_is_per_home
test_seed_allows_overlapping_clones_and_drops_owner
test_home_seed_validate_rejects_duplicate_homes
test_home_seed_validate_rejects_duplicate_ids
test_home_seed_validate_rejects_nested_homes
test_home_seed_uses_worktrunk_acquired_home
test_home_seed_returns_worktrunk_acquired_home_on_assignment_failure
test_home_seed_warns_when_acquired_home_return_fails
test_home_seed_does_not_return_unsafe_acquired_home
test_home_seed_rolls_back_failed_clone
test_home_seed_refuses_missing_filled_charter
test_home_seed_refuses_placeholder_charter
test_home_seed_refuses_empty_charter_fields
test_home_seed_refuses_local_only_project
test_home_seed_refuses_registry_delimiter_home
test_home_seed_refuses_active_home_and_root
test_home_seed_refuses_home_marked_for_another_id
test_home_seed_refuses_home_registered_to_another_id
test_home_seed_refuses_reassigning_existing_id_to_different_home
test_home_seed_refuses_home_overlapping_registered_home
test_home_seed_refuses_remote_backed_project_without_origin
test_home_seed_refuses_existing_remote_backed_project_with_wrong_origin
test_home_seed_resolves_relative_source_origins
test_home_seed_skips_initialized_existing_no_mistakes_projects
test_home_seed_refuses_uninitialized_existing_no_mistakes_project
test_home_seed_refuses_project_destinations_outside_subhome
test_home_seed_refuses_operational_dirs_outside_subhome
test_home_seed_refuses_symlinked_leaf_files
test_sous-chef_spawn_requires_seeded_matching_home
test_sous-chef_spawn_refuses_operational_dirs_outside_subhome
test_fm_send_refuses_bare_window_without_home_meta
test_sous-chef_teardown_retires_empty_home
test_sous-chef_teardown_refuses_failed_leased_home_return
test_sous-chef_teardown_removes_plain_clone_home_without_worktrunk_return
test_sous-chef_force_teardown_discards_child_work
test_sous-chef_force_teardown_allows_operational_dir_symlinks_inside_home
test_sous-chef_force_teardown_refuses_operational_dir_symlink_outside_home
test_sous-chef_teardown_refuses_registered_nested_home
test_sous-chef_teardown_refuses_child_registry_nested_home
test_sous-chef_force_teardown_prevalidates_before_child_cleanup
test_sous-chef_force_teardown_refuses_child_active_home_descendant
test_sous-chef_force_teardown_refuses_child_repo_descendant
test_sous-chef_force_teardown_refuses_unregistered_child_worktree
test_sous-chef_teardown_path_boundary_matrix
test_sous-chef_idle_pane_is_not_stale
test_sous-chef_charter_brief_is_idle_by_default
test_backlog_handoff_aborts_safely
test_backlog_handoff_creates_absent_section_and_refuses_non_sous-chef_home
