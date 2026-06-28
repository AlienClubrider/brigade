#!/usr/bin/env bash
# tests/sous-chef-helpers.sh - shared fixtures and mocks for the sous-chef
# suites (brigade-sous-chef-lifecycle-e2e and brigade-sous-chef-safety).
#
# These mocks encode sous-chef-lifecycle behavior (fake wezterm that logs pane
# ops, fake wt that creates/removes sous-chef home worktrees, fake no-mistakes
# that records init/doctor), so they live here rather than in the generic
# tests/lib.sh. The generic git/identity/meta primitives come from lib.sh.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake wezterm (pane ops logged to FM_FAKE_WEZTERM_LOG, get-text returns
# FM_FAKE_WEZTERM_CAPTURE, spawn returns FM_FAKE_PANE_ID) plus a fake wt
# (switch --create creates FM_FAKE_WT_HOME as a real git worktree of FM_ROOT
# when both are set; remove cleans up unless FM_FAKE_WT_RETURN_FAIL is set).
# Echoes the fakebin dir.
make_fake_wezterm() {
  local dir=$1 fakebin capture
  fakebin=$(fm_fakebin "$dir")
  capture="$dir/pane.txt"
  printf 'idle prompt\n' > "$capture"
  cat > "$fakebin/wezterm" <<'SH'
#!/usr/bin/env bash
set -u
# strip leading "cli" subcommand if present
[ "${1:-}" = cli ] && shift
case "${1:-}" in
  spawn)
    printf 'spawn %s\n' "$*" >> "${FM_FAKE_WEZTERM_LOG:-/dev/null}"
    printf '%s\n' "${FM_FAKE_PANE_ID:-42}"
    exit 0
    ;;
  set-tab-title)
    printf 'set-tab-title %s\n' "$*" >> "${FM_FAKE_WEZTERM_LOG:-/dev/null}"
    exit 0
    ;;
  send-text)
    content=$(cat)
    printf 'send-text %s: %s\n' "$*" "$content" >> "${FM_FAKE_WEZTERM_LOG:-/dev/null}"
    exit 0
    ;;
  get-text)
    printf 'get-text %s\n' "$*" >> "${FM_FAKE_WEZTERM_LOG:-/dev/null}"
    [ -n "${FM_FAKE_WEZTERM_CAPTURE:-}" ] && cat "$FM_FAKE_WEZTERM_CAPTURE"
    exit 0
    ;;
  kill-pane)
    printf 'kill-pane %s\n' "$*" >> "${FM_FAKE_WEZTERM_LOG:-/dev/null}"
    exit 0
    ;;
  list)
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/wt" <<'SH'
#!/usr/bin/env bash
set -u
printf 'wt %s\n' "$*" >> "${FM_FAKE_WEZTERM_LOG:-/dev/null}"
# brigade-home-seed.sh calls wt inside ( cd "$FM_ROOT" && wt ... ) so PWD is
# the git root — call git directly from PWD without specifying -C.
case "${1:-}" in
  switch)
    # wt switch --create brigade-home/<id> --no-cd -y
    branch=
    for _a in "$@"; do
      case "$_a" in switch|--create|--no-cd|-y) ;; *) branch="$_a" ;; esac
    done
    if [ -n "${FM_FAKE_WT_HOME:-}" ]; then
      # Store branch name so remove can clean it up too.
      printf '%s\n' "$branch" > "${FM_FAKE_WT_HOME}.wt-branch" 2>/dev/null || true
      git worktree add -b "$branch" "$FM_FAKE_WT_HOME" HEAD 2>/dev/null || true
    fi
    exit 0
    ;;
  remove)
    target=
    for _a in "$@"; do
      case "$_a" in remove|-f|-D|--foreground) ;; *) target="$_a" ;; esac
    done
    [ -z "${FM_FAKE_WT_RETURN_FAIL:-}" ] || exit 17
    if [ -n "$target" ]; then
      _stored_branch=$(cat "${target}.wt-branch" 2>/dev/null || true)
      git worktree remove --force "$target" 2>/dev/null || true
      [ -n "$_stored_branch" ] && git branch -D "$_stored_branch" 2>/dev/null || true
      rm -rf -- "$target" "${target}.wt-branch" 2>/dev/null || true
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/wezterm"
  chmod +x "$fakebin/wt"
  : > "$dir/wezterm.log"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that touches .no-mistakes-init / .no-mistakes-doctor markers.
make_fake_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that records each "<pwd>\t<verb>" call to
# FM_FAKE_NO_MISTAKES_LOG and fails for the project named FM_FAKE_NO_MISTAKES_FAIL_PROJECT.
make_recording_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\t%s\n' "$PWD" "${1:-}" >> "$FM_FAKE_NO_MISTAKES_LOG"
if [ "$(basename "$PWD")" = "${FM_FAKE_NO_MISTAKES_FAIL_PROJECT:-}" ]; then
  exit 1
fi
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# Make a directory look like a minimal brigade home (AGENTS.md + bin/).
mark_brigade_home() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Brigade\n' > "$home/AGENTS.md"
}

# A brigade home that is also a real git repo (so it can host detached
# worktrees for teardown/lease tests). Uses symlinks into the real brigade
# bin/ so scripts launched with FM_ROOT_OVERRIDE pointing here still find
# their helpers. An optional marker content can be committed in .brigade-sous-chef-home.
# Args: home [marker_content]
make_brigade_git_root() {
  local home=$1 marker=${2:-}
  mkdir -p "$home"
  # Symlink to the real brigade bin so FM_ROOT_OVERRIDE=$home still resolves helpers.
  ln -sf "$ROOT/bin" "$home/bin"
  printf '# Brigade\n' > "$home/AGENTS.md"
  [ -n "$marker" ] && printf '%s\n' "$marker" > "$home/.brigade-sous-chef-home"
  git -C "$home" init -q
  git -C "$home" add -A
  git -C "$home" -c user.name='Brigade Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# Scaffold a filled sous-chef charter brief under <home>/data/<id>/brief.md.
# Args: home id charter [project...]
scaffold_sous-chef_charter() {
  local home=$1 id=$2 charter=$3
  shift 3
  FM_HOME="$home" FM_SECONDMATE_CHARTER="$charter" "$ROOT/bin/brigade-brief.sh" "$id" --sous-chef "$@" >/dev/null
}

# Make a directory look like a genuine seeded sous-chef home (for handoff tests).
seed_sous-chef_home_marker() {
  local home=$1 id=$2
  mark_brigade_home "$home"
  mkdir -p "$home/data"
  printf '%s\n' "$id" > "$home/.brigade-sous-chef-home"
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive. Returns 1 if it dies.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}
