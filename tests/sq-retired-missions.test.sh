#!/usr/bin/env bash
# Tests durable teardown retirement records and exact, safe orphan cleanup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-retired-missions)

init_git_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email squad@example.invalid
  git -C "$repo" config user.name Squad
  printf 'base\n' > "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -qm base
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
}

make_case() {
  CASE_DIR="$TMP_ROOT/$1"
  BASE="$CASE_DIR/base"
  STATE="$BASE/state"
  HOME="$CASE_DIR/home"
  PROJECT="$CASE_DIR/project"
  WT="$HOME/.fob/pi-durable-host-test/$ID"
  ID="retired$1"
  mkdir -p "$STATE" "$HOME/.fob"
  init_git_repo "$PROJECT"
  git -C "$PROJECT" worktree add -q -b "sq/$ID" "$WT"
  cat > "$STATE/$ID.meta" <<EOF
backend=tmux
worktree=$WT
project=$PROJECT
kind=strike
EOF
  mkdir -p "$CASE_DIR/fakebin"
  cat > "$CASE_DIR/fakebin/fob" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] && [ "${2:-}" = --json ] || exit 2
printf '%s\n' "${SQUAD_FAKE_FOB_STATUS:-[]}"
SH
  chmod +x "$CASE_DIR/fakebin/fob"
  export CASE_DIR BASE STATE HOME PROJECT WT ID
}

run_record() {
  SQUAD_BASE="$BASE" SQUAD_STATE_OVERRIDE="$STATE" SQUAD_ROOT_OVERRIDE="$ROOT" \
    SQUAD_RETIREMENT_PROJECT="$PROJECT" SQUAD_RETIREMENT_WORKTREE="$WT" \
    "$ROOT/bin/sq-retired-missions.sh" record "$ID"
}

run_sweep() {
  PATH="$CASE_DIR/fakebin:$PATH" HOME="$HOME" SQUAD_BASE="$BASE" \
    SQUAD_STATE_OVERRIDE="$STATE" SQUAD_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/sq-retired-missions.sh" sweep
}

test_remote_tracking_reachable_orphan_is_removed() {
  local out
  make_case remote
  git -C "$WT" checkout -q -b "sq/$ID-change"
  printf 'remote-safe\n' >> "$WT/file"
  git -C "$WT" add file
  git -C "$WT" commit -qm remote-safe
  git -C "$PROJECT" update-ref "refs/remotes/origin/sq/$ID-change" "$(git -C "$WT" rev-parse HEAD)"
  run_record || fail "could not write the worktree retirement record"
  rm "$STATE/$ID.meta"
  out=$(run_sweep) || fail "worktree sweep failed: $out"
  assert_contains "$out" "retired worktree $WT" "remote-tracking-reachable worktree was not reported retired"
  assert_absent "$WT" "remote-tracking-reachable orphan worktree directory remains"
  if git -C "$PROJECT" worktree list --porcelain | grep -F "$WT" >/dev/null; then
    fail "remote-tracking-reachable orphan registration remains"
  fi
  pass "retired clean worktree reachable from a remote-tracking ref is removed safely"
}

test_unmerged_unreachable_orphan_is_preserved() {
  local out
  make_case unreachable
  git -C "$WT" checkout -q -b "sq/$ID-change"
  printf 'private\n' >> "$WT/file"
  git -C "$WT" add file
  git -C "$WT" commit -qm private
  run_record || fail "could not write the worktree retirement record"
  rm "$STATE/$ID.meta"
  out=$(run_sweep) || fail "worktree sweep errored while preserving unsafe record: $out"
  assert_contains "$out" "preserved worktree $WT" "unsafe worktree was not reported preserved"
  assert_contains "$out" "not reachable" "unreachable commit refusal reason was omitted"
  assert_present "$WT" "unmerged and unreachable worktree directory was removed"
  if ! git -C "$PROJECT" worktree list --porcelain | grep -F "$WT" >/dev/null; then
    fail "unmerged and unreachable worktree registration was pruned"
  fi
  pass "unmerged, unreachable worktree is preserved with an explicit reason"
}

test_live_meta_wins_over_worktree_record() {
  local out
  make_case live
  run_record || fail "could not write the worktree retirement record"
  out=$(run_sweep) || fail "worktree sweep errored while preserving a live task: $out"
  assert_contains "$out" "preserved worktree $WT" "live task worktree was not reported preserved"
  assert_contains "$out" "live task metadata" "live-meta preservation reason was omitted"
  assert_present "$WT" "live task worktree was removed"
  pass "live task metadata always wins over a retirement record"
}

test_remote_tracking_reachable_orphan_is_removed
test_unmerged_unreachable_orphan_is_preserved
test_live_meta_wins_over_worktree_record
