#!/usr/bin/env bash
# Guard-path tests for bin/sq-pr-review.sh (REQ-M3-02 AC3): every refusal must
# be a clear message and a non-zero exit, never a crash.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/sq-pr-review.sh"
TMP_ROOT=$(fm_test_tmproot sq-pr-review)

command -v gh >/dev/null 2>&1 || { echo "skip: gh not found"; exit 0; }

test_no_repo_refuses() {
  local out rc
  out=$(cd "$TMP_ROOT" && "$WRAPPER" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "no-repo run must exit non-zero"
  assert_contains "$out" "not inside a git repository" \
    "no-repo refusal must name the missing repo context"
  pass "no repo -> clear refusal"
}

test_invalid_pr_number_refuses() {
  local out rc repo
  repo="$TMP_ROOT/repo-invalid"
  git init -q -b main "$repo"
  out=$(git -C "$repo" config user.email t@t; git -C "$repo" config user.name t; \
    cd "$repo" && "$WRAPPER" not-a-number 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "invalid PR number must exit non-zero"
  assert_contains "$out" "invalid PR number" \
    "invalid PR number refusal must say so"
  pass "invalid PR number -> clear refusal"
}

test_absent_pr_refuses() {
  local out rc repo
  repo="$TMP_ROOT/repo-nopr"
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  out=$(cd "$repo" && "$WRAPPER" 424242 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "absent PR run must exit non-zero"
  assert_contains "$out" "not found or not readable" \
    "absent PR refusal must name the PR lookup failure"
  pass "absent PR -> clear refusal"
}

test_closed_pr_refuses() {
  local out rc repo
  repo="$TMP_ROOT/repo-closed"
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
  out=$(cd "$repo" && "$WRAPPER" 424243 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "closed/unknown PR must exit non-zero"
  pass "closed/unknown PR -> non-zero without crash"
}

test_no_repo_refuses
test_invalid_pr_number_refuses
test_absent_pr_refuses
test_closed_pr_refuses
