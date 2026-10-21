#!/usr/bin/env bash
# Behavior tests for the synchronous AXI recovery adapter (protocol stubs, real Git).
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot sq-drill-drive)
mkdir -p "$TMP/bin" "$TMP/base/state" "$TMP/repo"
export SQUAD_BASE="$TMP/base" RECOVERY_TEST="$TMP"
export PATH="$TMP/bin:$PATH"
git -C "$TMP/repo" init -q -b main
git -C "$TMP/repo" -c user.name=Test -c user.email=test@example.org commit -qm seed --allow-empty
git -C "$TMP/repo" checkout -qb feature
export RECOVERY_HEAD
authoritative_head() { git -C "$TMP/repo" rev-parse HEAD; }
RECOVERY_HEAD=$(authoritative_head)
cat > "$TMP/bin/drill" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$RECOVERY_TEST/calls"
case "$2" in
  run|respond)
    count=$(wc -l < "$RECOVERY_TEST/count" | tr -d ' ')
    count=$((count + 1))
    echo x >> "$RECOVERY_TEST/count"
    if [ "$MODE" = gate ] || { [ "$MODE" = retry-gate ] && [ "$count" -eq 2 ]; }; then
      printf 'run:\n  id: run-%s\n  status: running\ngate:\n  step: review\n  action: ask-user\n' "$count"
      exit 0
    fi
    printf 'run:\n  id: run-%s\n  status: failed\n  branch: feature\noutcome: %s\n' "$count" "${OUTCOME:-failed}"
    exit 1 ;;
  status)
    printf 'run:\n  id: %s\n  status: failed\n  branch: %s\n' "$4" "${RUN_BRANCH:-feature}"
    printf 'branch_sync:\n  state: %s\n  local:\n    head: %s\n' "${CUSTODY:-user_owned}" "$RECOVERY_HEAD"
    if [ "${CUSTODY:-}" = pipeline_owned ]; then
      printf '  next_action:\n    code: %s\n' "${NEXT:-recover_custody}"
    fi ;;
  sync)
    if [ "$MODE" = refuse ]; then
      printf 'branch_sync:\n  state: diverged\n  safety: blocked_diverged\n'
      exit 1
    fi
    printf 'branch_sync:\n  state: custody_returned\n  local:\n    head: %s\n' "$RECOVERY_HEAD" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$TMP/bin/drill"
cd "$TMP/repo"
reset_case() {
  : > "$TMP/count"; : > "$TMP/calls"
  rm -f "$SQUAD_BASE/state/probe.status"
  unset OUTCOME CUSTODY NEXT RUN_BRANCH
  export MODE=$1
}
drive() {
  RC=0
  "$ROOT/bin/sq-drill-drive.sh" probe "$@" > "$TMP/output" 2>&1 || RC=$?
}
reset_case persistent
drive run --intent 'preserve the entire accepted intent'
expect_code 1 "$RC" 'persistent failures must block'
expect_code 3 "$(wc -l < "$TMP/count" | tr -d ' ')" 'initial attempt plus two reruns'
assert_grep 'runs=run-1,run-2,run-3' "$SQUAD_BASE/state/probe.status" 'attempt ids survive exhaustion'
assert_grep 'axi run --intent preserve the entire accepted intent' "$TMP/calls" 'original intent is passed'
pass 'bounded reruns retain intent and report attempted ids'

reset_case retry-gate
export CUSTODY=pipeline_owned
drive respond --intent 'same accepted intent' --action fix --findings r1
expect_code 0 "$RC" 'rerun gate must return to the worker'
expect_code 2 "$(wc -l < "$TMP/count" | tr -d ' ')" 'legitimate recovery starts one new run'
assert_grep 'axi sync --recover' "$TMP/calls" 'guarded recovery is used'
assert_grep 'axi respond --action fix --findings r1' "$TMP/calls" 'only the explicit gate response is sent'
assert_grep 'action: ask-user' "$TMP/output" 'ask-user gate remains visible'
[ ! -e "$SQUAD_BASE/state/probe.status" ] || fail 'normal gate emitted a blocker'
pass 'failed respond recovers and reruns, then stops at the next gate'

reset_case gate
drive run --intent intent
expect_code 0 "$RC" 'ordinary gates remain normal returns'
expect_code 1 "$(wc -l < "$TMP/calls" | tr -d ' ')" 'no status, recovery or response at a gate'
pass 'no gate is automatically answered'

reset_case refuse
export CUSTODY=pipeline_owned
drive run --intent intent
expect_code 1 "$RC" 'refused recovery blocks'
expect_code 1 "$(wc -l < "$TMP/count" | tr -d ' ')" 'no submission after refused recovery'
assert_grep 'blocked_diverged' "$TMP/output" 'exact refusal evidence is retained'
assert_grep 'drill_state=diverged' "$SQUAD_BASE/state/probe.status" 'event names the actual refused state'
pass 'unreturned custody reports the actual refusal without a new run'

reset_case active
export CUSTODY=pipeline_owned NEXT=continue_active_run
drive run --intent intent
expect_code 1 "$RC" 'active custody blocks'
expect_code 1 "$(wc -l < "$TMP/count" | tr -d ' ')" 'active run never restarts'
assert_grep 'drill_state=pipeline_owned' "$SQUAD_BASE/state/probe.status" 'exact custody state is actionable'
pass 'active custody never triggers recovery'

reset_case dirty
printf 'uncommitted\n' > dirty.txt
drive run --intent intent
expect_code 1 "$RC" 'dirty branch blocks'
expect_code 1 "$(wc -l < "$TMP/count" | tr -d ' ')" 'dirty branch never restarts'
rm dirty.txt
pass 'dirty recovered branch is not resubmitted'

reset_case wrong
export RUN_BRANCH=another-task
drive run --intent intent
expect_code 1 "$RC" 'wrong run identity blocks'
expect_code 1 "$(wc -l < "$TMP/count" | tr -d ' ')" 'other branches never restart'
pass 'run attribution is checked before recovery'

reset_case cancel
export OUTCOME=cancelled
drive run --intent intent
expect_code 1 "$RC" 'cancellation is not automatically undone'
expect_code 1 "$(wc -l < "$TMP/calls" | tr -d ' ')" 'no recovery for cancelled outcome'
pass 'cancellation and AXI errors stop instead of retrying'

reset_case forbidden
drive run --intent intent --yes
expect_code 2 "$RC" 'auto approval is rejected'
drive run --intent intent --skip review
expect_code 2 "$RC" 'skipping validation steps is rejected'
[ ! -s "$TMP/calls" ] || fail 'forbidden flags reached Drill'
pass 'no automatic approval or skipped steps'
