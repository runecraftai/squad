#!/usr/bin/env bash
# sq-remote-entrypoint.sh installs as a PATH symlink under ~/.local/bin
# (docs/remote-XOs.md). SCRIPT_DIR must resolve to the real bin/
# directory so it can source its sibling sq-remote-job-lib.sh, not to the
# symlink's own directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-remote-entrypoint)
REAL_BIN="$TMP_ROOT/real-root/bin"
LOCAL_BIN="$TMP_ROOT/local-bin"
mkdir -p "$REAL_BIN" "$LOCAL_BIN"
cp "$ROOT/bin/sq-remote-entrypoint.sh" "$ROOT/bin/sq-remote-job-lib.sh" "$REAL_BIN/"
chmod +x "$REAL_BIN/sq-remote-entrypoint.sh"
ln -s "$REAL_BIN/sq-remote-entrypoint.sh" "$LOCAL_BIN/sq-remote-entrypoint.sh"

run_entrypoint() { # <path> <stdout-file> <stderr-file>
  local path=$1 out=$2 err=$3 code
  "$path" >"$out" 2>"$err"
  code=$?
  printf '%s' "$code"
}

test_symlink_invocation_resolves_sibling_lib() {
  local out err code
  out="$TMP_ROOT/symlink.stdout"
  err="$TMP_ROOT/symlink.stderr"
  code=$(run_entrypoint "$LOCAL_BIN/sq-remote-entrypoint.sh" "$out" "$err")

  # A wrong SCRIPT_DIR fails while sourcing the sibling lib, before argv is
  # even checked, with a "No such file or directory" source error and exit 1.
  # Reaching the die() for missing protocol args proves the sibling lib
  # sourced from the real bin/, not from the symlink's own directory.
  assert_no_grep 'No such file or directory' "$err" \
    "invoking sq-remote-entrypoint.sh through a symlink failed to source its sibling lib"
  expect_code 64 "$code" "symlink invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "symlink invocation did not reach argument validation past sibling-lib sourcing"
  pass "sq-remote-entrypoint.sh invoked via a PATH symlink resolves SCRIPT_DIR to the real bin/ directory"
}

test_direct_invocation_still_works() {
  # Control: the same real script invoked directly (no symlink) must behave
  # identically, so the symlink coverage above is proven by contrast.
  local out err code
  out="$TMP_ROOT/direct.stdout"
  err="$TMP_ROOT/direct.stderr"
  code=$(run_entrypoint "$REAL_BIN/sq-remote-entrypoint.sh" "$out" "$err")

  expect_code 64 "$code" "direct invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "direct invocation did not reach argument validation"
  pass "sq-remote-entrypoint.sh invoked directly still resolves SCRIPT_DIR correctly"
}

test_symlink_invocation_resolves_sibling_lib
test_direct_invocation_still_works
