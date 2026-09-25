#!/usr/bin/env bash
# Exercise the standalone PR wrapper through fake GitHub and Drill executables.
set -euo pipefail

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/sq-pr-review.sh"
TMP_ROOT=$(fm_test_tmproot sq-pr-review)
REPO="$TMP_ROOT/repo"
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
git init -q -b main "$REPO"
git init -q --bare "$TMP_ROOT/origin.git"
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
echo base >"$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm base
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
echo head >>"$REPO/file.txt"
git -C "$REPO" commit -qam head
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

cat >"$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"
if [ "$1 $2" = 'auth status' ]; then
  [ "${GH_AUTH:-yes}" = yes ]
elif [ "$1 $2" = 'repo view' ]; then
  echo owner/repo
elif [ "$1 $2" = 'pr view' ]; then
  if [[ "$*" == *'--json state,baseRefOid,headRefOid,headRepository'* ]]; then
    [ "${GH_PR:-OPEN}" != MISSING ] || exit 1
    printf '{"state":"%s","baseRefOid":"%s","headRefOid":"%s","headRepository":{"nameWithOwner":"owner/repo"}}\n' "${GH_PR:-OPEN}" "${GH_BASE_SHA:-$BASE_SHA}" "$HEAD_SHA"
  elif [[ "$*" == *'--json headRefOid'* ]]; then
    if [ "${GH_STALE:-no}" = yes ]; then echo changed; else echo "$HEAD_SHA"; fi
  else
    exit 90
  fi
else
  exit 90
fi
GH
cat >"$FAKE_BIN/drill" <<'DRILL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\nbase_sha=%s\nhead_sha=%s\n' "$*" "$(git rev-parse "$3^{commit}")" "$(git rev-parse "$5^{commit}")" >"$DRILL_ARGS"
[ "${DRILL_FAIL:-no}" = no ] || exit 1
echo reviewed
DRILL
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/drill"
export BASE_SHA HEAD_SHA GH_CALLS="$TMP_ROOT/gh.calls" DRILL_ARGS="$TMP_ROOT/drill.args"
export PATH="$FAKE_BIN:$PATH"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$REPO/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/owner/repo.git"

run_wrapper() { (cd "$REPO" && "$WRAPPER" "$@"); }
assert_refusal() {
  local expected=$1; shift
  local out rc
  out=$(run_wrapper "$@" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "expected wrapper refusal: $expected"
  assert_contains "$out" "$expected" "wrapper refusal should explain $expected"
}
test_invalid_pr_number_refuses() { assert_refusal 'invalid PR number' abc; pass 'invalid number refused'; }
test_missing_pr_refuses() { GH_PR=MISSING; export GH_PR; assert_refusal 'missing or unreadable' 42; unset GH_PR; pass 'missing PR refused'; }
test_closed_pr_refuses() { GH_PR=CLOSED; export GH_PR; assert_refusal 'not OPEN' 42; unset GH_PR; pass 'closed PR refused'; }
test_missing_auth_refuses() { GH_AUTH=no; export GH_AUTH; assert_refusal 'not authenticated' 42; unset GH_AUTH; pass 'missing auth refused'; }
test_diverging_sha_refuses() { GH_BASE_SHA=ffffffffffffffffffffffffffffffffffffffff; export GH_BASE_SHA; assert_refusal 'could not fetch PR base' 42; [ ! -e "$DRILL_ARGS" ] || fail 'diverging SHA must be rejected before Drill'; unset GH_BASE_SHA; pass 'diverging SHA refused before review'; }
test_stale_remote_head_is_not_presented_as_current_review() {
  rm -f "$DRILL_ARGS"
  GH_STALE=yes; export GH_STALE
  local out
  out=$(run_wrapper 42 2>&1) && fail 'stale review should fail' || true
  assert_contains "$out" 'stale review' 'head movement is reported as stale'
  if [[ "$out" == *reviewed* ]]; then fail 'stale result must not be emitted'; fi
  unset GH_STALE
  pass 'stale head result withheld'
}
test_open_pr_fetches_exact_immutable_refs() {
  : >"$GH_CALLS"
  local refs_before status_before remote_before
  refs_before=$(git -C "$REPO" show-ref)
  status_before=$(git -C "$REPO" status --porcelain)
  remote_before=$(git -C "$REPO" ls-remote origin)
  run_wrapper 42 >"$TMP_ROOT/output"
  assert_contains "$(cat "$DRILL_ARGS")" "$BASE_SHA" 'Drill receives resolved base SHA'
  assert_contains "$(cat "$DRILL_ARGS")" "$HEAD_SHA" 'Drill receives resolved head SHA'
  assert_contains "$(cat "$TMP_ROOT/output")" reviewed 'successful result is emitted'
  [ -z "$(git -C "$REPO" for-each-ref --format='%(refname)' refs/drill/review)" ] || fail 'temporary immutable refs remain'
  [ "$(git -C "$REPO" show-ref)" = "$refs_before" ] || fail 'wrapper changed permanent refs'
  [ "$(git -C "$REPO" status --porcelain)" = "$status_before" ] || fail 'wrapper changed requester checkout'
  [ "$(git -C "$REPO" ls-remote origin)" = "$remote_before" ] || fail 'wrapper changed remote refs'
  if grep -Eq 'pr (comment|review)|pr merge|git (commit|push)' "$GH_CALLS" "$DRILL_ARGS"; then fail 'wrapper attempted a GitHub or delivery write'; fi
  pass 'open PR resolves, reviews, and cleans temporary refs'
}
test_invalid_pr_number_refuses
test_missing_pr_refuses
test_closed_pr_refuses
test_missing_auth_refuses
test_diverging_sha_refuses
test_stale_remote_head_is_not_presented_as_current_review
test_open_pr_fetches_exact_immutable_refs
