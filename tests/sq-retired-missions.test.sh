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
  WT="$HOME/.fob/squad-test/$ID"
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
  local fob_status
  fob_status=${SQUAD_FAKE_FOB_STATUS:-}
  [ -n "$fob_status" ] || fob_status="[{\"path\":\"$WT\",\"status\":\"in-use\"}]"
  PATH="$CASE_DIR/fakebin:$PATH" HOME="$HOME" SQUAD_FAKE_FOB_STATUS="$fob_status" \
    SQUAD_BASE="$BASE" SQUAD_STATE_OVERRIDE="$STATE" SQUAD_ROOT_OVERRIDE="$ROOT" \
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

test_local_default_branch_landing_is_reachable() {
  local out
  make_case local-default
  git -C "$PROJECT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$WT" checkout -q -b "sq/$ID-change"
  printf 'local-safe\n' >> "$WT/file"
  git -C "$WT" add file
  git -C "$WT" commit -qm local-safe
  git -C "$PROJECT" merge --ff-only "sq/$ID-change" >/dev/null
  run_record || fail "could not write the worktree retirement record"
  rm "$STATE/$ID.meta"
  out=$(run_sweep) || fail "worktree sweep failed: $out"
  assert_contains "$out" "retired worktree $WT" "worktree landed on the local default branch was not reported retired"
  assert_absent "$WT" "worktree landed on the local default branch was not removed"
  if git -C "$PROJECT" worktree list --porcelain | grep -F "$WT" >/dev/null; then
    fail "local-default-branch landing left its orphan registration behind"
  fi
  pass "local-only landing is reachable through the local default branch when origin/HEAD exists"
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

test_unverified_runtime_record_is_refreshed_on_retry() {
  local out record
  make_terminal_case refresh-unknown
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.runtime_id="";fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  run_terminal record "$ID" || fail "could not write the terminal record without a verified runtime"
  record="$STATE/.retired-terminals/$ID.record"
  assert_contains "$(<"$record")" "runtime_id=unknown" "unavailable Orca runtime was not recorded as unknown"
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.runtime_id="runtime-1";d.fail_close=false;fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  run_terminal record "$ID" || fail "re-recording with a verified runtime was refused"
  assert_contains "$(<"$record")" "runtime_id=runtime-1" "verified runtime did not refresh the retirement record"
  out=$(run_terminal retire-terminal "$ID") || fail "refreshed record could not retire the terminal: $out"
  assert_contains "$out" "retired terminal term-refresh-unknown" "refreshed retirement was not reported"
  assert_absent "$record" "refreshed terminal retirement left its record behind"
  pass "a retirement recorded without a verified runtime is refreshed instead of locking teardown"
}

test_runtime_refresh_preserves_pending_close_attempt() {
  local out record
  make_terminal_case refresh-runtime
  run_terminal record "$ID" || fail "could not write the terminal retirement record"
  record="$STATE/.retired-terminals/$ID.record"
  out=$(run_terminal retire-terminal "$ID") && fail "failing terminal close was treated as complete"
  assert_contains "$(<"$record")" "close_attempted=1" "failed terminal close was not marked for retry"
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.runtime_id="runtime-2";d.fail_close=false;fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  run_terminal record "$ID" || fail "re-recording after an Orca restart was refused"
  assert_contains "$(<"$record")" "runtime_id=runtime-2" "Orca restart did not refresh the recorded runtime"
  assert_contains "$(<"$record")" "close_attempted=1" "refreshing the record dropped the pending close attempt"
  out=$(run_terminal retire-terminal "$ID") || fail "refreshed record could not finish the retirement: $out"
  assert_contains "$out" "retired terminal term-refresh-runtime" "refreshed retirement was not reported"
  assert_absent "$record" "refreshed terminal retirement left its record behind"
  pass "refreshing a record after an Orca restart keeps the pending close attempt and unblocks retirement"
}

test_record_identity_drift_still_refuses() {
  local record before
  make_terminal_case drift
  run_terminal record "$ID" || fail "could not write the terminal retirement record"
  record="$STATE/.retired-terminals/$ID.record"
  before=$(<"$record")
  cat > "$STATE/$ID.meta" <<EOF
backend=orca
terminal=term-foreign
orca_worktree_id=repo::$WT
worktree=$WT
project=$PROJECT
kind=strike
EOF
  run_terminal record "$ID" && fail "a changed terminal handle was accepted as the same retirement identity"
  [ "$(<"$record")" = "$before" ] || fail "refused identity drift still modified the retirement record"
  pass "a different terminal handle is refused instead of refreshing the retirement record"
}

test_verified_runtime_survives_unverified_rerecord() {
  local out record
  make_terminal_case runtime-downgrade
  run_terminal record "$ID" || fail "could not write the terminal retirement record"
  record="$STATE/.retired-terminals/$ID.record"
  assert_contains "$(<"$record")" "runtime_id=runtime-1" "verified runtime was not recorded"
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.runtime_id="";fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  run_terminal record "$ID" || fail "re-recording while Orca is unavailable was refused"
  assert_contains "$(<"$record")" "runtime_id=runtime-1" "an unverified runtime observation downgraded the recorded runtime"
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.runtime_id="runtime-1";d.fail_close=false;fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  out=$(run_terminal retire-terminal "$ID") || fail "preserved runtime could not retire the terminal: $out"
  assert_contains "$out" "retired terminal term-runtime-downgrade" "refreshed retirement was not reported"
  assert_absent "$record" "preserved terminal retirement left its record behind"
  pass "an unverified re-record keeps the verified runtime so the terminal can still be retired"
}

test_non_pool_worktree_is_not_recorded() {
  make_case nonpool
  SQUAD_FAKE_FOB_STATUS='[]' run_record || fail "recording refused a worktree fob does not manage"
  assert_absent "$STATE/.retired-worktrees/$ID.record" \
    "a worktree outside fob pool ownership was recorded for retirement"
  pass "only worktrees fob reports as pool-owned are recorded for retirement"
}

test_unknown_runtime_record_is_reverified_and_retired() {
  local out record
  make_terminal_case unknown-runtime
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.runtime_id="";fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  run_terminal record "$ID" || fail "could not write the terminal record without a verified runtime"
  record="$STATE/.retired-terminals/$ID.record"
  assert_contains "$(<"$record")" "runtime_id=unknown" "unavailable Orca runtime was not recorded as unknown"
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.runtime_id="runtime-1";d.fail_close=false;fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  out=$(run_terminal retire-terminal "$ID") || fail "retire-terminal could not re-verify the recorded handle: $out"
  assert_contains "$out" "retired terminal term-unknown-runtime" "re-verified retirement was not reported"
  assert_absent "$record" "re-verified terminal retirement left its record behind"
  pass "a record written without a verified runtime is re-verified and retired once Orca is ready"
}

test_stale_runtime_record_is_reverified_by_sweep() {
  local out record
  make_terminal_case stale-runtime
  run_terminal record "$ID" || fail "could not write the terminal retirement record"
  record="$STATE/.retired-terminals/$ID.record"
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.runtime_id="runtime-2";d.fail_close=false;fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  rm "$STATE/$ID.meta"
  out=$(run_terminal sweep) || fail "terminal sweep failed after an Orca restart: $out"
  assert_contains "$out" "retired terminal term-stale-runtime" "a stale recorded runtime was never re-verified"
  assert_absent "$record" "re-verified terminal retirement left its record behind"
  pass "a sweep re-verifies exact identity after an Orca runtime change instead of skipping forever"
}

test_confirmed_absence_clears_record_without_close_attempt() {
  local out record
  make_terminal_case absent-clear
  run_terminal record "$ID" || fail "could not write the terminal retirement record"
  record="$STATE/.retired-terminals/$ID.record"
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.terminals=[];fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  rm "$STATE/$ID.meta"
  out=$(run_terminal sweep) || fail "terminal sweep failed for a confirmed absence: $out"
  assert_contains "$out" "retired terminal term-absent-clear" "confirmed absence was not retired"
  assert_absent "$record" "a confirmed-absent terminal left a permanent retirement record"
  pass "a terminal confirmed absent is cleared even when no close was ever attempted"
}

test_sweep_action_limit_does_not_starve_later_records() {
  local out record
  make_terminal_case action-budget
  mkdir -p "$STATE/.retired-terminals"
  printf 'kind=terminal\ntask_id=aaaforeign\nbase=/nonexistent/base\nretired_at=2026-01-01T00:00:00Z\nbackend=orca\nterminal=term-foreign\nruntime_id=runtime-1\nclose_attempted=0\nworktree_id=repo::/foreign\nworktree_path=/foreign\n' \
    > "$STATE/.retired-terminals/aaaforeign.record"
  run_terminal record "$ID" || fail "could not write the terminal retirement record"
  record="$STATE/.retired-terminals/$ID.record"
  node -e 'const fs=require("fs"),p=process.argv[1],d=JSON.parse(fs.readFileSync(p));d.fail_close=false;fs.writeFileSync(p,JSON.stringify(d));' "$CASE_DIR/orca.json"
  rm "$STATE/$ID.meta"
  out=$(SQUAD_RETIRED_MISSIONS_SWEEP_LIMIT=1 run_terminal sweep) || fail "terminal sweep failed under a one-action budget: $out"
  assert_contains "$out" "base identity does not match" "the permanent record was not inspected"
  assert_contains "$out" "retired terminal term-action-budget" "a permanent record consumed the whole sweep budget"
  assert_absent "$record" "a later retirement record was starved by permanent records"
  assert_present "$STATE/.retired-terminals/aaaforeign.record" "the permanent record was removed"
  pass "the sweep budget bounds actions so permanent records cannot starve later retirements"
}

test_failed_terminal_close_is_retried_from_record
test_unverified_runtime_record_is_refreshed_on_retry
test_verified_runtime_survives_unverified_rerecord
test_unknown_runtime_record_is_reverified_and_retired
test_stale_runtime_record_is_reverified_by_sweep
test_confirmed_absence_clears_record_without_close_attempt
test_sweep_action_limit_does_not_starve_later_records
test_non_pool_worktree_is_not_recorded
test_runtime_refresh_preserves_pending_close_attempt
test_record_identity_drift_still_refuses
test_live_terminal_metadata_wins
test_ambiguous_terminal_owner_is_preserved
test_remote_tracking_reachable_orphan_is_removed
test_local_default_branch_landing_is_reachable
test_unmerged_unreachable_orphan_is_preserved
test_dirty_orphan_is_preserved
test_fob_pool_ownership_preserves_reusable_worktree
test_live_meta_wins_over_worktree_record
