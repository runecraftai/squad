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
  ID="retired$1"
  WT="$HOME/.fob/pi-durable-host-test/$ID"
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

make_terminal_case() {
  CASE_DIR="$TMP_ROOT/terminal-$1"
  BASE="$CASE_DIR/base"
  STATE="$BASE/state"
  HOME="$CASE_DIR/home"
  PROJECT="$CASE_DIR/project"
  ID="terminal$1"
  WT="$CASE_DIR/orca-worktree"
  mkdir -p "$STATE" "$HOME" "$WT" "$CASE_DIR/fakebin"
  cat > "$STATE/$ID.meta" <<EOF
backend=orca
terminal=term-$1
orca_worktree_id=repo::$WT
worktree=$WT
project=$PROJECT
kind=strike
EOF
  cat > "$CASE_DIR/orca.json" <<EOF
{"runtime_id":"runtime-1","fail_close":true,"terminals":[{"handle":"term-$1","worktreeId":"repo::$WT","worktreePath":"$WT"}]}
EOF
  cat > "$CASE_DIR/fakebin/orca" <<'SH'
#!/usr/bin/env node
const fs=require('fs');
const file=process.env.SQUAD_FAKE_ORCA_DB;
const db=JSON.parse(fs.readFileSync(file,'utf8'));
const args=process.argv.slice(2);
const json=value=>process.stdout.write(JSON.stringify(value)+'\n');
if(args[0]==='status'&&args[1]==='--json') json({ok:true,result:{runtime:{reachable:true,state:'ready',runtimeId:db.runtime_id}}});
else if(args[0]==='terminal'&&args[1]==='list') json({ok:true,result:{terminals:db.terminals,truncated:false},_meta:{runtimeId:db.runtime_id}});
else if(args[0]==='terminal'&&args[1]==='close') { if(!db.fail_close) { db.terminals=db.terminals.filter(t=>t.handle!==args[args.indexOf('--terminal')+1]); fs.writeFileSync(file,JSON.stringify(db)); } json({ok:true,result:{}}); }
else process.exit(2);
SH
  chmod +x "$CASE_DIR/fakebin/orca"
  export CASE_DIR BASE STATE HOME PROJECT WT ID
}

run_terminal() {
  PATH="$CASE_DIR/fakebin:$PATH" HOME="$HOME" SQUAD_FAKE_ORCA_DB="$CASE_DIR/orca.json" \
    SQUAD_BASE="$BASE" SQUAD_STATE_OVERRIDE="$STATE" SQUAD_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/sq-retired-missions.sh" "$@"
}

test_failed_terminal_close_is_retried_from_record() {
  local out record
  make_terminal_case close-retry
  run_terminal record "$ID" || fail "could not write the terminal retirement record"
  record="$STATE/.retired-terminals/$ID.record"
  assert_present "$record" "terminal retirement record was not written before close"
  assert_contains "$(<"$record")" "backend=orca" "terminal record omitted its backend"
  assert_contains "$(<"$record")" "terminal=term-close-retry" "terminal record omitted the exact handle"
  assert_contains "$(<"$record")" "task_id=$ID" "terminal record omitted its task identity"
  assert_contains "$(<"$record")" "base=$BASE" "terminal record omitted its base identity"
  out=$(run_terminal retire-terminal "$ID") && fail "failing terminal close was treated as complete"
  assert_present "$record" "failed terminal close did not retain its retry record"
  assert_contains "$(<"$record")" "close_attempted=1" "failed terminal close was not durably marked for retry"
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.fail_close=false;fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  rm "$STATE/$ID.meta"
  out=$(run_terminal sweep) || fail "terminal sweep failed while retrying: $out"
  assert_contains "$out" "retired terminal term-close-retry" "successful retry was not reported"
  assert_absent "$record" "confirmed terminal closure left its retirement record behind"
  pass "failed terminal close remains durable and a later exact-handle sweep retries it"
}

test_live_terminal_metadata_wins() {
  local out
  make_terminal_case live
  run_terminal record "$ID" || fail "could not write the terminal retirement record"
  out=$(run_terminal sweep) || fail "terminal sweep failed while preserving a live task: $out"
  assert_contains "$out" "live task metadata wins" "live terminal metadata refusal was not reported"
  node -e 'const fs=require("fs"),d=JSON.parse(fs.readFileSync(process.argv[1]));if(d.terminals.length!==1)process.exit(1);' "$CASE_DIR/orca.json" \
    || fail "live task metadata allowed the terminal to close"
  pass "live task metadata prevents retired-terminal sweep from closing a terminal"
}

test_ambiguous_terminal_owner_is_preserved() {
  local out
  make_terminal_case ambiguous
  run_terminal record "$ID" || fail "could not write the terminal retirement record"
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.terminals[0].worktreeId="foreign::worktree";fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  out=$(run_terminal retire-terminal "$ID") && fail "ambiguous terminal ownership was treated as safe"
  assert_contains "$out" "ambiguous" "ambiguous terminal refusal reason was omitted"
  assert_present "$STATE/.retired-terminals/$ID.record" "ambiguous terminal record was discarded"
  pass "mismatched terminal ownership is preserved with a reason"
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

test_dirty_orphan_is_preserved() {
  local out
  make_case dirty
  printf 'uncommitted\n' >> "$WT/file"
  run_record || fail "could not write the worktree retirement record"
  rm "$STATE/$ID.meta"
  out=$(run_sweep) || fail "worktree sweep errored while preserving dirty work: $out"
  assert_contains "$out" "uncommitted changes" "dirty worktree refusal reason was omitted"
  assert_present "$WT" "dirty orphan worktree was removed"
  pass "uncommitted worktree is preserved with an explicit reason"
}

test_fob_pool_ownership_preserves_reusable_worktree() {
  local out
  make_case pooled
  SQUAD_FAKE_FOB_STATUS="[{\"path\":\"$WT\",\"status\":\"available\"}]" run_record || fail "could not write the worktree retirement record"
  rm "$STATE/$ID.meta"
  out=$(SQUAD_FAKE_FOB_STATUS="[{\"path\":\"$WT\",\"status\":\"available\"}]" run_sweep) || fail "worktree sweep errored for a pool-owned worktree: $out"
  assert_contains "$out" "fob still owns" "reusable pool worktree preservation reason was omitted"
  assert_present "$WT" "reusable pool worktree was removed"
  pass "fob-owned reusable worktree is preserved"
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

test_failed_terminal_close_is_retried_from_record
test_live_terminal_metadata_wins
test_ambiguous_terminal_owner_is_preserved
test_remote_tracking_reachable_orphan_is_removed
test_unmerged_unreachable_orphan_is_preserved
test_dirty_orphan_is_preserved
test_fob_pool_ownership_preserves_reusable_worktree
test_live_meta_wins_over_worktree_record
