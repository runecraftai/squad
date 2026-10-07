#!/usr/bin/env bash
# Behavior tests for bin/sq-factory-collect.py (via its bin/sq-factory-collect.sh
# launcher): the verifiability test, dedupe against the backlog and across runs,
# the candidate record shape, human-digest grouping, and graceful source failure.
#
# sq-gh and sq-tasks are stubbed in a per-test fakebin directory prepended to
# PATH (the repo's established pattern, e.g. tests/sq-pr-check-security.test.sh)
# so these tests never touch the network or a real backlog. The TOON decode
# step (bin/sq-factory-collect-toon.mjs) runs for real against the vendored
# @toon-format/toon copy, so stub sq-gh output must be real TOON text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COLLECT="$ROOT/bin/sq-factory-collect.sh"
TMP_ROOT=$(fm_test_tmproot sq-factory-collect)

command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the TOON decode step)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# --- fixture builders --------------------------------------------------------

write_config() {
  local path=$1 issues_enabled=$2 ci_enabled=$3
  cat > "$path" <<EOF
schema_version = 1

[source.github_issues]
enabled = $issues_enabled
repo = "owner/repo"
state = "open"
limit = 10
repro_patterns = ["(?i)steps to reproduce"]

[source.ci_failures]
enabled = $ci_enabled
repo = "owner/repo"
workflow = "ci.yml"
branch = "main"
run_limit = 10
min_failures = 2
EOF
}

# Stub sq-gh covering both sources. Controlled by a few env knobs so each test
# can select which calls succeed, fail, or return which fixture rows.
write_sq_gh_stub() {
  local dir=$1
  cat > "$dir/sq-gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    if [ "${STUB_ISSUE_FAIL:-0}" = 1 ]; then
      echo "simulated GitHub API outage" >&2
      exit 1
    fi
    cat <<'EOF'
count: 2
issues[2]{number,title,state,author,created,body,url}:
  101,"Login crashes on submit",open,alice,2d ago,"Steps to reproduce:\n1. Open /login\n2. Submit empty form\nExpected: a validation error, not a crash","https://github.com/owner/repo/issues/101"
  102,"Something feels off",open,bob,1d ago,"I think there might be a bug somewhere but I am not sure what triggers it.","https://github.com/owner/repo/issues/102"
EOF
    ;;
  "run list")
    if [ "${STUB_RUN_FAIL:-0}" = 1 ]; then
      echo "simulated GitHub API outage" >&2
      exit 1
    fi
    cat <<'EOF'
count: 3
runs[3]{id,title,status,conclusion,workflow,branch,event,created,url}:
  1001,"fix: widget alignment",completed,failure,CI,main,push,3h ago,"https://github.com/owner/repo/actions/runs/1001"
  1002,"feat: add export button",completed,failure,CI,main,push,2h ago,"https://github.com/owner/repo/actions/runs/1002"
  1003,"chore: bump deps",completed,failure,CI,main,push,1h ago,"https://github.com/owner/repo/actions/runs/1003"
EOF
    ;;
  "run view")
    if [ "${STUB_RUN_VIEW_FAIL:-}" = "all" ] || [ "${STUB_RUN_VIEW_FAIL:-}" = "$3" ]; then
      echo "simulated run view outage for $3" >&2
      exit 1
    fi
    case "$3" in
      1001|1002)
        cat <<'EOF'
run:
  id: 1001
  title: "fix: widget alignment"
  status: completed
  conclusion: failure
  workflow: CI
  branch: main
  created: 3h ago
jobs[1]{id,name,status,conclusion}:
  5001,flaky-test,completed,failure
EOF
        ;;
      1003)
        cat <<'EOF'
run:
  id: 1003
  title: "chore: bump deps"
  status: completed
  conclusion: failure
  workflow: CI
  branch: main
  created: 1h ago
jobs[1]{id,name,status,conclusion}:
  5003,other-test,completed,failure
EOF
        ;;
      *)
        echo "unexpected run id: $3" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "unexpected sq-gh args: $*" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$dir/sq-gh"
}

# Stub sq-tasks that mimics the real binary's idempotent `add` and `hold`:
# the first add for a given id returns already=false, every subsequent add
# for that same id (even from a fresh process) returns already=true,
# matching how a real backlog already holding that id would respond. Every
# `hold` call is appended to "$seen_file.holds" (one "id reason kind" line
# per call) so tests can assert exactly which ids were held and how many
# times, without needing a real backlog read-back.
write_sq_tasks_stub() {
  local dir=$1 seen_file=$2
  touch "$seen_file"
  cat > "$dir/sq-tasks" <<STUB
#!/usr/bin/env bash
SEEN_FILE="$seen_file"
HOLDS_FILE="$seen_file.holds"
if [ "\$1" = "add" ]; then
  if [ "\${STUB_TASKS_QUEUE_FAIL:-0}" = 1 ]; then
    echo "simulated backlog write failure" >&2
    exit 1
  fi
  id=\$2
  if grep -qxF "\$id" "\$SEEN_FILE" 2>/dev/null; then
    already=true
  else
    already=false
    echo "\$id" >> "\$SEEN_FILE"
  fi
  printf '{"ok": true, "already": %s, "task": {"id": "%s", "created": "2026-01-01"}}\n' "\$already" "\$id"
  exit 0
fi
if [ "\$1" = "hold" ]; then
  if [ "\${STUB_TASKS_HOLD_FAIL:-0}" = 1 ]; then
    echo "simulated hold write failure" >&2
    exit 1
  fi
  id=\$2
  printf '%s\n' "\$*" >> "\$HOLDS_FILE"
  printf '{"ok": true, "task": {"id": "%s", "hold": {"kind": "commander"}}}\n' "\$id"
  exit 0
fi
echo "unexpected sq-tasks args: \$*" >&2
exit 2
STUB
  chmod +x "$dir/sq-tasks"
}

run_collect() {
  # Runs the collector with the given extra args, fakebin prepended to PATH.
  local fakebin=$1 data_dir=$2
  shift 2
  SQUAD_DATA_OVERRIDE="$data_dir" PATH="$fakebin:$PATH" "$COLLECT" "$@"
}

json_get() {
  local json=$1 expr=$2
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))" "$json" "$expr"
}

# --- tests -------------------------------------------------------------------

test_github_issue_verifiability_and_candidate_shape() {
  local dir="$TMP_ROOT/issue-verify" fakebin config data out
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  config="$dir/config.toml"; write_config "$config" true false
  data="$dir/data"

  out=$(run_collect "$fakebin" "$data" run --config "$config" --dry-run --json) \
    || fail "collector failed on the issue-verifiability fixture"

  [ "$(json_get "$out" "d['sources']['github_issues']['fetched']")" = 2 ] \
    || fail "expected 2 issues fetched from the source"
  [ "$(json_get "$out" "d['candidates_fetched']")" = 1 ] \
    || fail "expected exactly 1 pre-dedupe candidate (the repro-matching issue), got: $(json_get "$out" "d['candidates_fetched']")"
  [ "$(json_get "$out" "d['candidates_queued']")" = 1 ] \
    || fail "expected exactly 1 verifiable candidate (the repro-matching issue)"
  [ "$(json_get "$out" "d['digest_count']")" = 1 ] \
    || fail "expected exactly 1 non-qualifying issue in the human digest"

  local cand_id
  cand_id=$(json_get "$out" "d['queued'][0]['id']")
  [ "$cand_id" = "fc-issue-101" ] || fail "unexpected candidate id for the repro-matching issue: $cand_id"

  local keys
  keys=$(json_get "$out" "','.join(sorted(d['queued'][0].keys()))")
  [ "$keys" = "evidence,fingerprint,id,link,repro,source,title,verifiable_reason" ] \
    || fail "candidate record is missing or has extra fields: $keys"

  local evidence
  evidence=$(json_get "$out" "d['queued'][0]['evidence']")
  assert_contains "$evidence" "Steps to reproduce" "candidate evidence does not quote the matched reproduction text"

  local repro
  repro=$(json_get "$out" "d['queued'][0]['repro']")
  assert_contains "$repro" "101" "candidate repro path does not name the issue to open"

  pass "sq-factory-collect: issue repro signal qualifies, plain issue goes to the digest, candidate record shape is exact"
}

test_ci_recurring_failure_is_verifiable_single_occurrence_is_not() {
  local dir="$TMP_ROOT/ci-recurring" fakebin config data out
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  config="$dir/config.toml"; write_config "$config" false true
  data="$dir/data"

  out=$(run_collect "$fakebin" "$data" run --config "$config" --dry-run --json) \
    || fail "collector failed on the ci-recurring-failure fixture"

  [ "$(json_get "$out" "d['candidates_queued']")" = 1 ] \
    || fail "expected exactly 1 candidate for the job that recurred twice (flaky-test)"
  [ "$(json_get "$out" "d['digest_count']")" = 1 ] \
    || fail "expected exactly 1 digest entry for the job that only failed once (other-test)"

  local cand_id evidence
  cand_id=$(json_get "$out" "d['queued'][0]['id']")
  [[ "$cand_id" == fc-ci-* ]] || fail "ci candidate id does not use the fc-ci- prefix: $cand_id"
  evidence=$(json_get "$out" "d['queued'][0]['evidence']")
  assert_contains "$evidence" "flaky-test" "ci candidate evidence does not name the recurring job"
  assert_contains "$evidence" "2 of the last 3" "ci candidate evidence does not state the recurrence count"

  pass "sq-factory-collect: a job failing twice across fetched runs is a verifiable candidate, a single failure is not"
}

test_human_digest_groups_by_source() {
  local dir="$TMP_ROOT/digest-grouping" fakebin config data out digest
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  config="$dir/config.toml"; write_config "$config" true true
  data="$dir/data"

  out=$(run_collect "$fakebin" "$data" run --config "$config" --dry-run --json) \
    || fail "collector failed on the combined digest-grouping fixture"

  [ "$(json_get "$out" "d['digest_count']")" = 2 ] \
    || fail "expected 2 total non-qualifying items across both sources"

  digest=$(json_get "$out" "d['digest']")
  assert_contains "$digest" "## github_issues (1)" "digest is missing the github_issues group heading"
  assert_contains "$digest" "## ci_failures (1)" "digest is missing the ci_failures group heading"
  assert_contains "$digest" "issue-102" "digest does not list the non-qualifying issue"
  assert_contains "$digest" "chore: bump deps" "digest does not list the single-occurrence ci run"
  assert_contains "$digest" "occurrences needed for a stable identity" "digest does not explain why the ci item did not qualify"

  pass "sq-factory-collect: the human digest groups non-qualifying inputs by source in one bounded list"
}

test_dedupe_across_runs_and_against_backlog() {
  local dir="$TMP_ROOT/dedupe" fakebin config data tasks_seen out
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  tasks_seen="$dir/.sq-tasks-seen"
  write_sq_tasks_stub "$fakebin" "$tasks_seen"
  config="$dir/config.toml"; write_config "$config" true false
  data="$dir/data"

  # Run 1: real (non-dry-run) run against an empty ledger and an empty backlog.
  out=$(run_collect "$fakebin" "$data" run --config "$config" --json) \
    || fail "first real run failed"
  [ "$(json_get "$out" "d['candidates_queued']")" = 1 ] || fail "first run did not queue the one verifiable candidate"
  [ "$(json_get "$out" "d['candidates_already_seen']")" = 0 ] || fail "first run should have no ledger dupes"
  [ -f "$data/factory-collect/seen.json" ] || fail "the durable dedupe ledger was not written"
  grep -q "fc-issue-101" "$data/factory-collect/seen.json" || fail "the ledger does not record the queued candidate's id"
  [ "$(wc -l < "$tasks_seen.holds")" -eq 1 ] || fail "the freshly queued candidate was not held exactly once"
  assert_grep "fc-issue-101" "$tasks_seen.holds" "the hold call did not target the freshly queued candidate"
  assert_grep "commander" "$tasks_seen.holds" "the hold was not applied with hold-kind commander"
  local held
  held=$(python3 -c "import json; d=json.load(open('$data/factory-collect/seen.json')); print([v['held'] for v in d.values() if v['id']=='fc-issue-101'])")
  [ "$held" = "[True]" ] || fail "the ledger did not record the successful hold as held: true (got '$held')"

  # Run 2: same ledger still present -> must not re-propose across runs, and
  # must not even need to ask sq-tasks about it again. A held:true entry is
  # never re-held even if a commander has since cleared the backlog hold.
  out=$(run_collect "$fakebin" "$data" run --config "$config" --json) \
    || fail "second real run failed"
  [ "$(json_get "$out" "d['candidates_queued']")" = 0 ] || fail "second run re-proposed a candidate already in the ledger"
  [ "$(json_get "$out" "d['candidates_already_seen']")" = 1 ] || fail "second run did not report the ledger dedupe hit"
  [ "$(wc -l < "$tasks_seen.holds")" -eq 1 ] \
    || fail "a later run re-applied the hold for a candidate already recorded as held, clobbering a commander's decision to clear it"

  # Run 3: simulate ledger loss (e.g. state reset) while the backlog itself
  # still holds the item (the stub's own seen-ids file still has it) -> the
  # live add-idempotency check must catch it as already-in-backlog, not queue
  # a duplicate.
  rm -rf "$data/factory-collect"
  out=$(run_collect "$fakebin" "$data" run --config "$config" --json) \
    || fail "third real run (ledger reset) failed"
  [ "$(json_get "$out" "d['candidates_queued']")" = 0 ] || fail "third run queued a duplicate after the ledger was lost"
  [ "$(json_get "$out" "d['candidates_already_in_backlog']")" = 1 ] \
    || fail "third run did not detect the candidate already present in the backlog"
  [ "$(json_get "$out" "d['candidates_already_seen']")" = 0 ] \
    || fail "third run should not have an in-memory ledger hit (it was just reset)"
  [ "$(wc -l < "$tasks_seen.holds")" -eq 1 ] \
    || fail "an already-in-backlog hit re-applied the hold, which would clobber a commander's own decision to clear it"

  pass "sq-factory-collect: dedupes a candidate already in the ledger and, separately, one already in the backlog"
}

test_one_source_failing_degrades_instead_of_aborting() {
  local dir="$TMP_ROOT/source-failure" fakebin config data out
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  config="$dir/config.toml"; write_config "$config" true true
  data="$dir/data"

  out=$(STUB_RUN_FAIL=1 run_collect "$fakebin" "$data" run --config "$config" --dry-run --json)
  local rc=$?
  [ "$rc" -eq 0 ] || fail "a single failed source should not fail the whole run (exit $rc)"

  [ "$(json_get "$out" "d['sources']['github_issues']['ok']")" = True ] \
    || fail "the healthy github_issues source was incorrectly marked failed"
  [ "$(json_get "$out" "d['sources']['ci_failures']['ok']")" = False ] \
    || fail "the broken ci_failures source was not reported as failed"
  local error_text
  error_text=$(json_get "$out" "d['sources']['ci_failures']['error']")
  assert_contains "$error_text" "simulated GitHub API outage" "the source failure did not surface the underlying error"
  [ "$(json_get "$out" "d['digest_count']")" = 1 ] \
    || fail "the healthy source's own digest entry was lost when the other source failed"

  pass "sq-factory-collect: a failed source degrades and reports its error instead of failing the whole run"
}

test_source_unavailable_when_sq_gh_missing() {
  local dir="$TMP_ROOT/source-unavailable" fakebin config data out rc node_bin python_bin
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  # A PATH containing only node and python3 (both required to run the
  # collector itself) and deliberately nothing else, so sq-gh is truly
  # absent rather than merely unstubbed (it ships from the same install
  # directory as node, so a broader PATH would still find the real one).
  node_bin=$(command -v node) || fail "node not found to build the minimal PATH fixture"
  python_bin=$(command -v python3) || fail "python3 not found to build the minimal PATH fixture"
  ln -s "$node_bin" "$fakebin/node"
  ln -s "$python_bin" "$fakebin/python3"
  config="$dir/config.toml"; write_config "$config" true true
  data="$dir/data"

  # bash itself must still resolve (the launcher's #!/usr/bin/env bash
  # shebang), but /bin:/usr/bin carries no sq-gh/sq-tasks on any supported
  # platform since those ship from the mise-managed node install directory.
  out=$(SQUAD_DATA_OVERRIDE="$data" PATH="$fakebin:/bin:/usr/bin" "$COLLECT" run --config "$config" --dry-run --json)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run where every source is unavailable should exit non-zero"
  [ "$(json_get "$out" "d['sources']['github_issues']['ok']")" = False ] \
    || fail "github_issues should be reported unavailable when sq-gh is missing"
  [ "$(json_get "$out" "d['sources']['ci_failures']['ok']")" = False ] \
    || fail "ci_failures should be reported unavailable when sq-gh is missing"
  [ "$(json_get "$out" "d['ok']")" = False ] \
    || fail "overall result should not claim ok when every enabled source failed"

  pass "sq-factory-collect: reports every source unavailable (and a non-zero exit) when sq-gh cannot be found at all"
}

test_queue_failure_marks_the_owning_source_not_a_phantom() {
  local dir="$TMP_ROOT/queue-failure" fakebin config data tasks_seen out rc queue_error phantom
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  tasks_seen="$dir/.sq-tasks-seen"
  write_sq_tasks_stub "$fakebin" "$tasks_seen"
  config="$dir/config.toml"; write_config "$config" true false
  data="$dir/data"

  out=$(STUB_TASKS_QUEUE_FAIL=1 run_collect "$fakebin" "$data" run --config "$config" --json)
  rc=$?
  phantom=$(json_get "$out" "'github_issue' in d['sources']")
  [ "$phantom" = "False" ] || fail "a queue failure invented the singular phantom source key 'github_issue'"
  queue_error=$(json_get "$out" "d['sources']['github_issues'].get('queue_error','')")
  assert_contains "$queue_error" "simulated backlog write failure" \
    "the owning source did not carry the queue failure"
  [ "$(json_get "$out" "d['candidates_queued']")" = 0 ] \
    || fail "a candidate whose queue write failed was still counted as queued"
  # A single queue failure degrades; the run itself does not abort.
  [ "$rc" -eq 0 ] || fail "a queue failure should degrade instead of aborting the run (exit $rc)"

  pass "sq-factory-collect: a queue failure is reported on the owning source, not a phantom key"
}

test_hold_failure_degrades_instead_of_silently_leaving_it_ready() {
  local dir="$TMP_ROOT/hold-failure" fakebin config data tasks_seen out rc queue_error held
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  tasks_seen="$dir/.sq-tasks-seen"
  write_sq_tasks_stub "$fakebin" "$tasks_seen"
  config="$dir/config.toml"; write_config "$config" true false
  data="$dir/data"

  out=$(STUB_TASKS_HOLD_FAIL=1 run_collect "$fakebin" "$data" run --config "$config" --json)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a hold failure should degrade instead of aborting the run (exit $rc)"
  queue_error=$(json_get "$out" "d['sources']['github_issues'].get('queue_error','')")
  assert_contains "$queue_error" "simulated hold write failure" \
    "a failed hold call was not reported as a queue_error so the gap is visible, not silent"
  [ "$(json_get "$out" "d['candidates_queued']")" = 0 ] \
    || fail "a candidate whose hold call failed was still counted as cleanly queued"
  # The failed hold must be durable in the ledger, not only in this run's log.
  held=$(python3 -c "import json; d=json.load(open('$data/factory-collect/seen.json')); print([v['held'] for v in d.values() if v['id']=='fc-issue-101'])")
  [ "$held" = "[False]" ] || fail "the ledger did not record the failed hold as held: false (got '$held')"
  [ ! -s "$tasks_seen.holds" ] || fail "the failed hold call was recorded as an applied hold"

  pass "sq-factory-collect: a hold failure degrades (reported and recorded held:false) rather than silently leaving a candidate unheld"
}

test_hold_failure_is_retried_and_cleared_on_the_next_run() {
  local dir="$TMP_ROOT/hold-retry" fakebin config data tasks_seen out rc queue_error held
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  tasks_seen="$dir/.sq-tasks-seen"
  write_sq_tasks_stub "$fakebin" "$tasks_seen"
  config="$dir/config.toml"; write_config "$config" true false
  data="$dir/data"

  # Run A: the add lands the candidate but the hold call fails; the ledger
  # records held:false.
  out=$(STUB_TASKS_HOLD_FAIL=1 run_collect "$fakebin" "$data" run --config "$config" --json)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a hold failure should degrade instead of aborting the run (exit $rc)"
  queue_error=$(json_get "$out" "d['sources']['github_issues'].get('queue_error','')")
  assert_contains "$queue_error" "simulated hold write failure" \
    "a failed hold call was not reported as a queue_error so the gap is visible, not silent"
  held=$(python3 -c "import json; d=json.load(open('$data/factory-collect/seen.json')); print([v['held'] for v in d.values() if v['id']=='fc-issue-101'])")
  [ "$held" = "[False]" ] || fail "the first run did not record held: false in the ledger (got '$held')"

  # Run B: the very next run must retry the hold for the held:false entry and
  # flip the ledger to held:true only once the hold call actually succeeds. The
  # candidate is already in the backlog, so it must not be re-queued.
  out=$(run_collect "$fakebin" "$data" run --config "$config" --json) \
    || fail "the retry run failed"
  [ "$(json_get "$out" "d['candidates_queued']")" = 0 ] \
    || fail "the retry run re-queued a candidate that was already in the backlog"
  held=$(python3 -c "import json; d=json.load(open('$data/factory-collect/seen.json')); print([v['held'] for v in d.values() if v['id']=='fc-issue-101'])")
  [ "$held" = "[True]" ] || fail "the retry run did not flip the ledger entry to held: true (got '$held')"
  [ "$(wc -l < "$tasks_seen.holds")" -eq 1 ] \
    || fail "the retry run did not call sq-tasks hold exactly once for the unheld candidate"
  assert_grep "fc-issue-101" "$tasks_seen.holds" "the retried hold did not target the unheld candidate"

  # Run C: once held:true is recorded, a later run never calls hold again, so a
  # commander's deliberate decision to clear the backlog hold is preserved.
  out=$(run_collect "$fakebin" "$data" run --config "$config" --json) \
    || fail "the post-retry run failed"
  [ "$(wc -l < "$tasks_seen.holds")" -eq 1 ] \
    || fail "a run after held:true re-applied the hold, clobbering a commander's decision to clear it"

  # Run D: even if the local ledger is lost while the backlog still holds the
  # id, the already-in-backlog path must not re-apply the hold either.
  rm -rf "$data/factory-collect"
  out=$(run_collect "$fakebin" "$data" run --config "$config" --json) \
    || fail "the ledger-reset run failed"
  [ "$(json_get "$out" "d['candidates_already_in_backlog']")" = 1 ] \
    || fail "the ledger-reset run did not detect the candidate already present in the backlog"
  [ "$(wc -l < "$tasks_seen.holds")" -eq 1 ] \
    || fail "an already-in-backlog hit re-applied the hold, clobbering a commander's decision to clear it"

  pass "sq-factory-collect: a failed hold is retried next run, and held:true is never re-held"
}

test_one_unviewable_run_is_skipped_not_fatal() {
  local dir="$TMP_ROOT/run-view-failure" fakebin config data out rc digest
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  config="$dir/config.toml"; write_config "$config" false true
  data="$dir/data"

  out=$(STUB_RUN_VIEW_FAIL=1001 run_collect "$fakebin" "$data" run --config "$config" --dry-run --json)
  rc=$?
  [ "$rc" -eq 0 ] || fail "one unviewable run should not fail the run (exit $rc)"
  [ "$(json_get "$out" "d['sources']['ci_failures']['ok']")" = True ] \
    || fail "one unviewable run marked the whole ci_failures source failed"
  digest=$(json_get "$out" "d['digest']")
  assert_contains "$digest" "could not inspect this failed run" \
    "the unviewable run was not reported in the human digest"
  assert_contains "$digest" "1001" "the digest does not name the run that could not be inspected"

  pass "sq-factory-collect: one unviewable run is skipped and reported instead of aborting ci_failures"
}

test_all_unviewable_runs_fail_the_source_and_preserve_the_digest() {
  local dir="$TMP_ROOT/run-view-outage" fakebin config data tasks_seen out rc digest_before digest_after
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  tasks_seen="$dir/.sq-tasks-seen"
  write_sq_tasks_stub "$fakebin" "$tasks_seen"
  config="$dir/config.toml"; write_config "$config" false true
  data="$dir/data"

  run_collect "$fakebin" "$data" run --config "$config" --json >/dev/null \
    || fail "the healthy first run failed"
  digest_before=$(cat "$data/factory-collect/digest.md")
  assert_contains "$digest_before" "chore: bump deps" "the first run did not persist its human digest"

  # A whole-endpoint run-view outage: every fetched run is unviewable, so the
  # source must fail and report, not masquerade as a healthy empty fetch that
  # overwrites the last good digest with outage entries.
  out=$(STUB_RUN_VIEW_FAIL=all run_collect "$fakebin" "$data" run --config "$config" --json)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an all-unviewable ci_failures fetch should fail the run (exit $rc)"
  [ "$(json_get "$out" "d['sources']['ci_failures']['ok']")" = False ] \
    || fail "an all-unviewable ci_failures fetch was reported as a healthy source"
  local error_text
  error_text=$(json_get "$out" "d['sources']['ci_failures'].get('error','')")
  assert_contains "$error_text" "could not inspect any" \
    "the source failure did not explain that no run could be inspected"
  digest_after=$(cat "$data/factory-collect/digest.md")
  [ "$digest_after" = "$digest_before" ] \
    || fail "an all-unviewable fetch overwrote the last good human digest"

  pass "sq-factory-collect: an all-unviewable run-view outage fails the source and preserves the digest"
}

test_all_failed_run_does_not_blank_the_last_digest() {
  local dir="$TMP_ROOT/digest-preserved" fakebin config data tasks_seen digest_before digest_after
  mkdir -p "$dir"
  fakebin="$dir/fakebin"; mkdir -p "$fakebin"
  write_sq_gh_stub "$fakebin"
  tasks_seen="$dir/.sq-tasks-seen"
  write_sq_tasks_stub "$fakebin" "$tasks_seen"
  config="$dir/config.toml"; write_config "$config" true false
  data="$dir/data"

  run_collect "$fakebin" "$data" run --config "$config" --json >/dev/null \
    || fail "the healthy first run failed"
  digest_before=$(cat "$data/factory-collect/digest.md")
  assert_contains "$digest_before" "issue-102" "the first run did not persist its human digest"

  # Second run: the only enabled source fails, so the run produces no current
  # state and must leave the last good digest on disk untouched.
  STUB_ISSUE_FAIL=1 run_collect "$fakebin" "$data" run --config "$config" --json >/dev/null
  digest_after=$(cat "$data/factory-collect/digest.md")
  [ "$digest_after" = "$digest_before" ] \
    || fail "an all-failed run blanked the previously persisted human digest"

  pass "sq-factory-collect: an all-failed run preserves the last good human digest"
}

test_github_issue_verifiability_and_candidate_shape
test_ci_recurring_failure_is_verifiable_single_occurrence_is_not
test_human_digest_groups_by_source
test_dedupe_across_runs_and_against_backlog
test_one_source_failing_degrades_instead_of_aborting
test_source_unavailable_when_sq_gh_missing
test_queue_failure_marks_the_owning_source_not_a_phantom
test_hold_failure_degrades_instead_of_silently_leaving_it_ready
test_hold_failure_is_retried_and_cleared_on_the_next_run
test_one_unviewable_run_is_skipped_not_fatal
test_all_unviewable_runs_fail_the_source_and_preserve_the_digest
test_all_failed_run_does_not_blank_the_last_digest
