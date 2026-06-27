#!/usr/bin/env bash
# Behavior tests for brigade-bootstrap.sh tool detection.
#
# Bootstrap prints one line per problem or capability fact and is silent when all
# is well. brigade consumes the exact 'MISSING: wt (install: ...)' and
# 'TASKS_AXI: available' lines, so those contracts are pinned verbatim.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot brigade-bootstrap-tests)

# A fake toolchain where every required tool is present and gh is authenticated.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" wezterm wt node no-mistakes gh-axi chrome-devtools-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

add_tasks_axi() {
  local fakebin=$1 version=$2
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

# Each row (fields are '^'-separated):
#   <label>^<tasks-axi version or ->^<mode>^<expect>^<notcontains>
#   mode=empty -> output must be empty (expect/notcontains ignored)
#   mode=exact -> output must equal <expect>
#   mode=grep  -> output must contain <expect> (fixed string); <notcontains> must not appear
test_bootstrap_reporting() {
  local label tasks mode expect notcontains case_dir fakebin out n
  n=0
  while IFS='^' read -r label tasks mode expect notcontains; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/case-$n"
    mkdir -p "$case_dir/home"
    fakebin=$(make_fake_toolchain "$case_dir")
    [ "$tasks" = "-" ] || add_tasks_axi "$fakebin" "$tasks"
    # FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
    # it stays inert: this suite pins tool detection, not the tangle guard, and the
    # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      "$ROOT/bin/brigade-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)"
        if [ -n "$notcontains" ]; then
          printf '%s\n' "$out" | grep -F "$notcontains" >/dev/null && fail "$label: unexpected '$notcontains' in: $out"
        fi
        ;;
    esac
  done <<'ROWS'
all tools present, no tasks-axi: silent^-^empty^^
compatible tasks-axi is reported available^0.1.1^exact^TASKS_AXI: available^
incompatible tasks-axi is ignored^0.1.0^empty^^
ROWS
  pass "bootstrap reports tool availability and tasks-axi compatibility contracts"
}

test_bootstrap_missing_wezterm() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/missing-wezterm"
  mkdir -p "$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  # All tools EXCEPT wezterm
  fm_fake_exit0 "$fakebin" wt node no-mistakes gh-axi chrome-devtools-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] && exit 0; exit 0
SH
  chmod +x "$fakebin/gh"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/brigade-bootstrap.sh")
  printf '%s\n' "$out" | grep -Fq "MISSING: wezterm" \
    || fail "expected MISSING: wezterm line, got: $out"
  pass "bootstrap reports MISSING: wezterm when wezterm is absent"
}

test_bootstrap_reporting
test_bootstrap_missing_wezterm
