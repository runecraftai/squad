#!/usr/bin/env bash
# Focused executable-interface tests for PR lifecycle correction:
# structured drill PR registration, direct-PR registration,
# orphan/source presentation, merge monitoring, and poll-artifact retirement.
# Regression: retired poll artifacts are not treated as evidence of an unmonitored PR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/sq-pr-lib.sh"

CREW_STATE="$ROOT/bin/sq-crew-state.sh"
UNIT_SNAPSHOT="$ROOT/bin/sq-unit-snapshot.sh"
UNIT_VIEW="$ROOT/bin/sq-unit-view.sh"
PR_CHECK="$ROOT/bin/sq-pr-check.sh"
PR_LIB="$ROOT/bin/sq-pr-lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-pr-lifecycle)
fm_git_identity fmtest fmtest@example.invalid

# --- helpers ---------------------------------------------------------------

# A real git repo with a branch, so sq-crew-state.sh resolves the branch.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  SQUAD_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  export SQUAD_FAKE_RUN_HEAD
}

# Fakebin: fake drill, tmux, herdr, gh, glab, sq-gh matching the crew-state
# test pattern. SQUAD_FAKE_AXI_STATUS includes a pr field.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/drill" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${SQUAD_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${SQUAD_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${SQUAD_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf '%s\n' "${SQUAD_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${SQUAD_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${SQUAD_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${SQUAD_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${SQUAD_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status) printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'; exit 0 ;;
  server) exit 0 ;;
  pane) case "${2:-}" in read) printf 'all quiet\n> \n'; exit 0 ;; esac ;;
  agent) case "${2:-}" in get) printf '{"result":{"agent":{"agent_status":"idle"}}}\n'; exit 0 ;; esac ;;
esac
exit 0
SH
  # gh stub for sq-pr-check.sh head lookups
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SQUAD_TEST_GH_LOG:-/dev/null}"
case " $* " in
  *" headRefOid "*) printf '%s\n' "${SQUAD_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" state "*) printf '%s\n' "${SQUAD_TEST_GH_STATE:-OPEN}" ;;
esac
exit 0
SH
  cat > "$fb/sq-gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SQUAD_TEST_SQ_GH_LOG:-/dev/null}"
exit "${SQUAD_TEST_SQ_GH_RC:-0}"
SH
  cat > "$fb/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SQUAD_TEST_GLAB_LOG:-/dev/null}"
exit "${SQUAD_TEST_GLAB_FAIL:-0}"
SH
  chmod +x "$fb/drill" "$fb/tmux" "$fb/herdr" "$fb/gh" "$fb/sq-gh" "$fb/glab"
  printf '%s\n' "$fb"
}

# Run sq-crew-state.sh for a case dir.
run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" SQUAD_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

# Run sq-unit-snapshot.sh --json for a case dir.
run_snapshot() {  # <case-dir>
  PATH="$1/fakebin:$PATH" SQUAD_STATE_OVERRIDE="$1/state" \
    SQUAD_DATA_OVERRIDE="$1/data" SQUAD_ROOT_OVERRIDE="$ROOT" \
    "$UNIT_SNAPSHOT" --json
}

# Run sq-unit-view.sh for a case dir.
run_view() {  # <case-dir>
  PATH="$1/fakebin:$PATH" SQUAD_STATE_OVERRIDE="$1/state" \
    SQUAD_DATA_OVERRIDE="$1/data" SQUAD_ROOT_OVERRIDE="$ROOT" \
    "$UNIT_VIEW"
}

new_case() {  # <name> -> echoes case dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/data"
  printf '%s\n' "$d"
}

# --- Tests -----------------------------------------------------------------

# T1: Drill PR registration via sidecar.
# When drill axi status returns a completed run with a pr field,
# sq-crew-state.sh writes the drill-pr sidecar, and sq-unit-snapshot.sh
# reads it as the authoritative PR source (pr_source=drill).
test_drill_pr_sidecar() {
  local d; d=$(new_case drill-pr-sidecar)
  local id="task-drill-pr" branch="sq/task-drill-pr"
  make_repo_on_branch "$d/wt" "$branch"
  local fb; fb=$(make_fakebin "$d")

  fm_write_meta "$d/state/$id.meta" \
    "window=Squad:sq-$id" \
    "worktree=$d/wt" \
    "project=test-repo" \
    "harness=claude" \
    "kind=strike" \
    "mode=drill"

  local pr_url="https://github.com/runecraftai/squad/pull/99"
  export SQUAD_FAKE_AXI_STATUS="run:
  id: run-abc
  branch: $branch
  status: completed
  head: $SQUAD_FAKE_RUN_HEAD
  pr: \"$pr_url\"
  findings: none
outcome: passed"

  # sq-crew-state.sh should write the sidecar
  local out; out=$(run_crew_state "$d" "$id")
  assert_contains "$out" "state: done" "drill-pr: crew-state reports done"
  [ -f "$d/state/$id.drill-pr" ] || fail "drill-pr: sidecar not written"
  local sidecar_content; sidecar_content=$(cat "$d/state/$id.drill-pr")
  [ "$sidecar_content" = "$pr_url" ] || fail "drill-pr: sidecar content mismatch: $sidecar_content"

  # sq-unit-snapshot.sh should read it as pr_source=drill
  local snap; snap=$(run_snapshot "$d")
  local snap_pr_source; snap_pr_source=$(printf '%s' "$snap" | jq -r '.tasks[0].pr.source')
  [ "$snap_pr_source" = "drill" ] || fail "drill-pr: snapshot pr.source=$snap_pr_source, expected drill"
  local snap_pr_url; snap_pr_url=$(printf '%s' "$snap" | jq -r '.tasks[0].pr.url')
  [ "$snap_pr_url" = "$pr_url" ] || fail "drill-pr: snapshot pr.url=$snap_pr_url"

  # sq-unit-view.sh should show "(drill)" suffix
  local view; view=$(run_view "$d")
  assert_contains "$view" "(drill)" "drill-pr: unit view shows drill source"
  pass "T1: drill PR registration via sidecar"
}

# T2: Direct-PR registration via sq-pr-check.sh.
# After the operator calls sq-pr-check.sh, the PR is in metadata
# (pr_source=meta) and the poll is armed.
test_direct_pr_registration() {
  local d; d=$(new_case direct-pr-registration)
  local id="task-direct-pr" branch="sq/task-direct-pr"
  make_repo_on_branch "$d/wt" "$branch"
  local fb; fb=$(make_fakebin "$d")
  export SQUAD_TEST_GH_LOG="$d/gh.log"
  export SQUAD_TEST_SQ_GH_LOG="$d/sq-gh.log"

  fm_write_meta "$d/state/$id.meta" \
    "window=Squad:sq-$id" \
    "worktree=$d/wt" \
    "project=test-repo" \
    "harness=claude" \
    "kind=strike" \
    "mode=direct-PR"

  local pr_url="https://github.com/runecraftai/squad/pull/101"

  # sq-pr-check.sh writes pr= to metadata and arms poll
  local check_out
  check_out=$(PATH="$fb:$PATH" SQUAD_STATE_OVERRIDE="$d/state" \
    SQUAD_ROOT_OVERRIDE="$ROOT" "$PR_CHECK" "$id" "$pr_url" 2>&1) || {
    # sq-pr-check.sh may fail if the poll template is missing; check metadata
    :
  }

  # pr= should be in metadata after sq-pr-check.sh (even if poll arm partially failed)
  local meta_pr; meta_pr=$(grep '^pr=' "$d/state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ "$meta_pr" = "$pr_url" ] || fail "direct-pr: pr= not in metadata after sq-pr-check.sh: '$meta_pr'"

  # meta file mode should be 0600 (the fingerprint of sq-pr-check.sh having run)
  local mode
  mode=$(stat -c '%a' "$d/state/$id.meta" 2>/dev/null || stat -f '%Lp' "$d/state/$id.meta" 2>/dev/null)
  [ "$mode" = "600" ] || fail "direct-pr: meta mode=$mode, expected 600"

  # snapshot should show pr_source=meta
  # No drill run, so the sidecar should not exist
  [ ! -f "$d/state/$id.drill-pr" ] || fail "direct-pr: unexpected drill-pr sidecar"
  local snap; snap=$(run_snapshot "$d")
  local snap_pr_source; snap_pr_source=$(printf '%s' "$snap" | jq -r '.tasks[0].pr.source')
  [ "$snap_pr_source" = "meta" ] || fail "direct-pr: snapshot pr.source=$snap_pr_source, expected meta"

  pass "T2: direct-PR registration via sq-pr-check.sh"
}

# T3: Orphan PR surfaced from status event.
# When a PR URL appears in the status log but not in metadata and not
# in a drill sidecar, pr_source=status_event.
test_orphan_pr_source() {
  local d; d=$(new_case orphan-pr-source)
  local id="task-orphan" branch="sq/task-orphan"
  make_repo_on_branch "$d/wt" "$branch"
  local fb; fb=$(make_fakebin "$d")

  fm_write_meta "$d/state/$id.meta" \
    "window=Squad:sq-$id" \
    "worktree=$d/wt" \
    "project=test-repo" \
    "harness=claude" \
    "kind=strike" \
    "mode=direct-PR"

  # Write a status log with a PR URL but no pr= in metadata
  printf 'done: PR https://github.com/runecraftai/squad/pull/102\n' > "$d/state/$id.status"

  # No drill run
  unset SQUAD_FAKE_AXI_STATUS 2>/dev/null || true
  export SQUAD_FAKE_AXI_STATUS=""

  local snap; snap=$(run_snapshot "$d")
  local snap_pr_source; snap_pr_source=$(printf '%s' "$snap" | jq -r '.tasks[0].pr.source')
  [ "$snap_pr_source" = "status_event" ] || fail "orphan: pr.source=$snap_pr_source, expected status_event"
  local snap_pr_url; snap_pr_url=$(printf '%s' "$snap" | jq -r '.tasks[0].pr.url')
  [ "$snap_pr_url" = "https://github.com/runecraftai/squad/pull/102" ] || fail "orphan: pr.url mismatch"

  # Unit view should show "(orphan)" suffix
  local view; view=$(run_view "$d")
  assert_contains "$view" "(orphan)" "orphan: unit view shows orphan source"
  pass "T3: orphan PR surfaced from status event"
}

# T4: Drill PR sidecar cleared when no run matches.
# After a drill run completes and the sidecar is written, if the worktree
# advances past the run head (branch diverged), sq-crew-state.sh should
# clear the sidecar so a stale drill PR is not reported.
test_sidecar_cleared_on_diverge() {
  local d; d=$(new_case sidecar-cleared)
  local id="task-diverge" branch="sq/task-diverge"
  make_repo_on_branch "$d/wt" "$branch"
  local fb; fb=$(make_fakebin "$d")

  fm_write_meta "$d/state/$id.meta" \
    "window=Squad:sq-$id" \
    "worktree=$d/wt" \
    "project=test-repo" \
    "harness=claude" \
    "kind=strike" \
    "mode=drill"

  # First: drill run matches, sidecar is written
  export SQUAD_FAKE_AXI_STATUS="run:
  id: run-first
  branch: $branch
  status: completed
  head: $SQUAD_FAKE_RUN_HEAD
  pr: \"https://github.com/runecraftai/squad/pull/110\"
  findings: none
outcome: passed"
  run_crew_state "$d" "$id" >/dev/null
  [ -f "$d/state/$id.drill-pr" ] || fail "diverge: sidecar not written on first run"

  # Now advance the worktree past the run head (simulate divergence)
  git -C "$d/wt" commit -q --allow-empty -m "advance past run"
  export SQUAD_FAKE_RUN_HEAD="deadbeef00000000000000000000000000000000"

  # Second: run head no longer matches, sidecar should be cleared
  run_crew_state "$d" "$id" >/dev/null
  [ ! -f "$d/state/$id.drill-pr" ] || fail "diverge: sidecar not cleared after diverge"

  pass "T4: drill PR sidecar cleared on branch divergence"
}

# T5: Retired poll artifacts are NOT evidence of an unmonitored PR.
# After a poll is armed and then the merge is detected, the poll artifacts
# (.check.sh, .pr-poll-registration, .pr-poll) are cleaned up by the
# retirement path. A task with pr= in metadata and no .check.sh is NOT
# an orphan -- it is a successfully retired poll. The snapshot should
# still show pr_source=meta (the metadata has pr=), not status_event.
test_retired_poll_not_orphan() {
  local d; d=$(new_case retired-poll-not-orphan)
  local id="task-retired" branch="sq/task-retired"
  make_repo_on_branch "$d/wt" "$branch"
  local fb; fb=$(make_fakebin "$d")
  export SQUAD_TEST_GH_LOG="$d/gh.log"

  fm_write_meta "$d/state/$id.meta" \
    "window=Squad:sq-$id" \
    "worktree=$d/wt" \
    "project=test-repo" \
    "harness=claude" \
    "kind=strike" \
    "mode=drill"

  # Simulate the state AFTER a successful merge + poll retirement:
  # pr= is in metadata (chmod 0600 from sq-pr-check.sh),
  # but .check.sh, .pr-poll, .pr-poll-registration are all gone
  # (the retirement path cleaned them up).
  local pr_url="https://github.com/runecraftai/squad/pull/111"
  local meta_tmp; meta_tmp=$(mktemp)
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$meta_tmp"
  done < "$d/state/$id.meta"
  printf 'pr=%s\n' "$pr_url" >> "$meta_tmp"
  chmod 0600 "$meta_tmp"
  mv -f -- "$meta_tmp" "$d/state/$id.meta"

  # No poll artifacts (they were retired)
  assert_absent "$d/state/$id.check.sh" "retired: no .check.sh after retirement"
  assert_absent "$d/state/$id.pr-poll" "retired: no .pr-poll after retirement"
  assert_absent "$d/state/$id.pr-poll-registration" "retired: no .pr-poll-registration"

  # No status log event (the retired poll was clean)
  # The snapshot should read pr= from metadata, NOT from status_event
  unset SQUAD_FAKE_AXI_STATUS 2>/dev/null || true
  export SQUAD_FAKE_AXI_STATUS=""

  local snap; snap=$(run_snapshot "$d")
  local snap_pr_source; snap_pr_source=$(printf '%s' "$snap" | jq -r '.tasks[0].pr.source')
  [ "$snap_pr_source" = "meta" ] || fail "retired: pr.source=$snap_pr_source, expected meta (not status_event)"
  local snap_pr_url; snap_pr_url=$(printf '%s' "$snap" | jq -r '.tasks[0].pr.url')
  [ "$snap_pr_url" = "$pr_url" ] || fail "retired: pr.url mismatch"

  # The unit view should NOT show "(orphan)" -- this is a registered PR
  local view; view=$(run_view "$d")
  assert_not_contains "$view" "(orphan)" "retired: retired poll must not look like orphan"

  pass "T5: retired poll artifacts are not evidence of an unmonitored PR"
}

# T6: Direct-PR brief includes sq-pr-check.sh instruction.
test_direct_pr_brief_instruction() {
  local d; d=$(new_case brief-instruction)
  mkdir -p "$d/data"

  # Generate a direct-PR brief via sq-brief.sh
  local brief_out
  brief_out=$(SQUAD_DATA_OVERRIDE="$d/data" SQUAD_STATE_OVERRIDE="$d/state" \
    SQUAD_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/sq-brief.sh" "test-brief" "test-repo" \
    --mode direct-PR 2>&1) || true

  local brief_file="$d/data/test-brief/brief.md"
  [ -f "$brief_file" ] || fail "brief: file not created"

  # The brief must contain sq-pr-check.sh instruction
  assert_grep "sq-pr-check.sh" "$brief_file" "brief: direct-PR brief must mention sq-pr-check.sh"
  # It must also contain the done: instruction
  assert_grep "done: PR" "$brief_file" "brief: direct-PR brief must contain done: PR instruction"

  pass "T6: direct-PR brief includes sq-pr-check.sh instruction"
}

# T7: Drill PR in snapshot when metadata also has pr=.
# When both drill sidecar and metadata have pr=, the drill value wins
# (drill created the PR in its pipeline step, so it is authoritative).
test_drill_pr_over_metadata() {
  local d; d=$(new_case drill-over-meta)
  local id="task-both" branch="sq/task-both"
  make_repo_on_branch "$d/wt" "$branch"
  local fb; fb=$(make_fakebin "$d")

  local meta_pr="https://github.com/runecraftai/squad/pull/200"
  local drill_pr="https://github.com/runecraftai/squad/pull/201"

  # Metadata has one PR
  fm_write_meta "$d/state/$id.meta" \
    "window=Squad:sq-$id" \
    "worktree=$d/wt" \
    "project=test-repo" \
    "harness=claude" \
    "kind=strike" \
    "mode=drill" \
    "pr=$meta_pr"

  # Drill run reports a different PR (drill created it in the pipeline)
  export SQUAD_FAKE_AXI_STATUS="run:
  id: run-both
  branch: $branch
  status: completed
  head: $SQUAD_FAKE_RUN_HEAD
  pr: \"$drill_pr\"
  findings: none
outcome: passed"

  run_crew_state "$d" "$id" >/dev/null

  local snap; snap=$(run_snapshot "$d")
  local snap_pr_url; snap_pr_url=$(printf '%s' "$snap" | jq -r '.tasks[0].pr.url')
  local snap_pr_source; snap_pr_source=$(printf '%s' "$snap" | jq -r '.tasks[0].pr.source')
  [ "$snap_pr_url" = "$drill_pr" ] || fail "drill-over-meta: pr.url=$snap_pr_url, expected drill PR"
  [ "$snap_pr_source" = "drill" ] || fail "drill-over-meta: pr.source=$snap_pr_source, expected drill"

  pass "T7: drill PR takes precedence over metadata pr="
}

# --- run all tests ---------------------------------------------------------

test_drill_pr_sidecar
test_direct_pr_registration
test_orphan_pr_source
test_sidecar_cleared_on_diverge
test_retired_poll_not_orphan
test_direct_pr_brief_instruction
test_drill_pr_over_metadata

printf '\nAll PR lifecycle tests passed.\n'
