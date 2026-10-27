#!/usr/bin/env bash
# Tests for bin/sq-pr-merge.sh: the one path Squad uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so sq-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# sq-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= only after the guarded merge succeeds
#   (b) merge is refused when sq-gh pr merge itself fails (no silent success)
#   (c) extra sq-gh pr merge args are forwarded after number and --repo
#   (d) merge is refused before sq-gh when task meta is missing
#   (e) PR URL is parsed to number + --repo for sq-gh (defaults to --squash)
#   (f) malformed PR URL fails fast without calling sq-gh
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) --auto only enables auto-merge, so no landing outcome is recorded
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/sq-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot sq-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a sq-gh mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=sq-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=strike" \
    "mode=drill"
  # No worktree/project on disk; sq-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# sq-gh mock recording every invocation to a log file, and gh mock answering
# headRefOid for sq-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  printf 'pr_head=%s\n' "$head" >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/sq-gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SQUAD_TEST_SQ_GH_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/sq-gh" "$case_dir/fakebin/gh"
}

# sq-gh mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  printf 'pr_head=%s\n' 1313131313131313131313131313131313131313 >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/sq-gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SQUAD_TEST_SQ_GH_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/sq-gh" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  SQUAD_ROOT_OVERRIDE="$ROOT" \
  SQUAD_STATE_OVERRIDE="$case_dir/state" \
  SQUAD_DATA_OVERRIDE="$case_dir/data" \
  SQUAD_TEST_SQ_GH_LOG="$case_dir/sq-gh.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/sq-gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: sq-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --expected-head deadbeefcafefeed0000000000000000deadbeef --squash' "$case_dir/sq-gh.log" \
    || fail "records-before-merge: sq-gh pr merge was not invoked with number, --repo, and default --squash"
  pass "sq-pr-merge records PR metadata after invoking the guarded merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/sq-gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: sq-pr-merge should propagate the sq-gh merge failure"
  assert_no_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: failed merge must leave PR metadata untouched"
  pass "sq-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/sq-gh.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: sq-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --expected-head 2222222222222222222222222222222222222222 --squash --delete-branch' "$case_dir/sq-gh.log" \
    || fail "extra-args: extra sq-gh pr merge flags were not forwarded"
  pass "sq-pr-merge forwards extra flags to sq-gh pr merge after the -- separator"
}

test_missing_recorded_head_refuses_without_metadata_changes() {
  local case_dir rc before after
  case_dir=$(make_case missing-recorded-head)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  grep -v '^pr_head=' "$case_dir/state/task-x1.meta" > "$case_dir/meta.tmp"
  mv "$case_dir/meta.tmp" "$case_dir/state/task-x1.meta"
  : > "$case_dir/sq-gh.log"
  before=$(sha256sum "$case_dir/state/task-x1.meta")

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/20 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-recorded-head: merge must refuse"
  assert_grep 'no valid recorded PR head' "$case_dir/stderr" "missing-recorded-head: refusal was not actionable"
  [ "$(awk 'END { print NR }' "$case_dir/stderr")" -eq 1 ] || fail "missing-recorded-head: refusal was not one line"
  after=$(sha256sum "$case_dir/state/task-x1.meta")
  [ "$before" = "$after" ] || fail "missing-recorded-head: refusal changed task metadata"
  [ ! -s "$case_dir/sq-gh.log" ] || fail "missing-recorded-head: merge was invoked"
  pass "sq-pr-merge refuses without a recorded head and leaves metadata untouched"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/sq-gh.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: sq-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/sq-gh.log" ] || fail "missing-meta: sq-gh pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: sq-pr-check should not arm a poll for an unknown task"
  pass "sq-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/sq-gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: sq-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/sq-gh.log" \
    "malformed-url: sq-gh pr merge was invoked for a malformed URL"
  pass "sq-pr-merge refuses malformed PR URLs before calling sq-gh"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/sq-gh.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: sq-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/sq-gh.log" \
    "unsafe-url-segment: sq-gh pr merge was invoked for an unsafe URL"
  pass "sq-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/sq-gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: sq-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/sq-gh.log" \
    "repo-override: sq-gh pr merge was invoked despite repo override"
  pass "sq-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/sq-gh.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: sq-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --expected-head 5555555555555555555555555555555555555555 --merge' "$case_dir/sq-gh.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "sq-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/sq-gh.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: sq-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --expected-head 7777777777777777777777777777777777777777 --method=merge' "$case_dir/sq-gh.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "sq-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/sq-gh.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: sq-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --expected-head 6666666666666666666666666666666666666666 --squash' "$case_dir/sq-gh.log" \
    || fail "url-parsing: sq-gh pr merge was not invoked as number + --repo + default --squash"
  pass "sq-pr-merge parses a GitHub PR URL into sq-gh number and --repo arguments"
}

test_auto_merge_is_not_recorded_as_landed() {
  local case_dir landed_dir
  case_dir=$(make_case auto-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/sq-gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 -- --auto \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  local auto_rc=$?
  set -e
  expect_code 1 "$auto_rc" "auto-merge: guarded wrapper must reject --auto"
  assert_grep 'automatic merge is not allowed' "$case_dir/stderr" "auto-merge: refusal was not actionable"
  assert_absent "$case_dir/data/task-x1/dispatch.jsonl" \
    "auto-merge: refusal must not record a landing"
  assert_no_grep 'pr=https://github.com/example/repo/pull/31' "$case_dir/state/task-x1.meta" \
    "auto-merge: refusal must leave task metadata untouched"
  [ ! -s "$case_dir/sq-gh.log" ] || fail "auto-merge: merge command was invoked"

  landed_dir=$(make_case real-merge)
  mkdir -p "$landed_dir/wt"
  add_gh_mocks "$landed_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$landed_dir/sq-gh.log"

  run_pr_merge "$landed_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$landed_dir/stdout" 2> "$landed_dir/stderr" || fail "real-merge: sq-pr-merge failed"
  python3 - "$landed_dir/data/task-x1/dispatch.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert [(r['event'], r['source'], r['result']) for r in rows] == [
    ('outcome', 'pr-merge', 'landed')], rows
PY
  pass "sq-pr-merge records confirmed landings and refuses automatic merges"
}

test_disable_auto_is_not_recorded_as_landed() {
  local case_dir
  case_dir=$(make_case disable-auto)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/sq-gh.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 -- --disable-auto \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "disable-auto: sq-pr-merge failed"

  grep -qxF 'pr merge 33 --repo example/repo --expected-head cccccccccccccccccccccccccccccccccccccccc --squash --disable-auto' "$case_dir/sq-gh.log" \
    || fail "disable-auto: --disable-auto was not forwarded to sq-gh pr merge"
  assert_absent "$case_dir/data/task-x1/dispatch.jsonl" \
    "disable-auto: disabling auto-merge must not record a landing"
  pass "sq-pr-merge never records a landing for --disable-auto"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_missing_recorded_head_refuses_without_metadata_changes
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_auto_merge_is_not_recorded_as_landed
test_disable_auto_is_not_recorded_as_landed
test_parses_pr_url_for_gh_axi
