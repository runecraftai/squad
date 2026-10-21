#!/usr/bin/env bash
# Behavior tests for the synchronous AXI recovery adapter (protocol stubs, real Git).
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/sq-classify-lib.sh
. "$ROOT/bin/sq-classify-lib.sh"
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
printf '%s %s\n' "${0##*/}" "$*" >> "$RECOVERY_TEST/calls"
if [ "$MODE" = missing ]; then
  printf 'drill: executable not found\n' >&2
  exit 127
fi
case "$2" in
  run|respond)
    for arg in "$@"; do
      case "$arg" in
        --*) case "$2:$arg" in
               run:--intent|run:--yes|run:--skip|run:--specialized-review) ;;
               respond:--action|respond:--findings|respond:--instructions|respond:--step|respond:--add-finding) ;;
               *) printf 'drill: unknown flag for %s: %s\n' "$2" "$arg" >&2; exit 2 ;;
             esac ;;
      esac
    done
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
without_drill() {
  local d out=''
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    [ -x "$d/drill" ] && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
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
assert_grep 'axi run --intent same accepted intent' "$TMP/calls" 'the automatic rerun uses the run form without respond flags'
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

reset_case persistent
printf 'working: prior' > "$SQUAD_BASE/state/probe.status"
drive run --intent intent
expect_code 1 "$RC" 'persistent failure blocks'
[ "$(sed -n '1p' "$SQUAD_BASE/state/probe.status")" = 'working: prior' ] || fail 'unterminated prior record was not separated'
printf '%s' "$(status_open_decisions "$SQUAD_BASE/state/probe.status")" | grep -q $'\tblocked\t' || fail 'blocked transition did not open a durable decision'
pass 'blocked event is its own record after an unterminated status stream'

reset_case retry-gate
export CUSTODY=pipeline_owned
drive respond --intent 'same accepted intent' --action=fix --findings=r1
expect_code 0 "$RC" 'equals-form respond flags are accepted'
expect_code 2 "$(wc -l < "$TMP/count" | tr -d ' ')" 'equals-form recovery still reruns once'
assert_grep 'axi respond --action fix --findings r1' "$TMP/calls" 'equals-form flags reach Drill'
pass 'equals-form respond flags are normalized, not rejected'

reset_case missing
RC=0
"$ROOT/bin/sq-drill-drive.sh" probe run --intent intent > "$TMP/missing.out" 2> "$TMP/missing.err" || RC=$?
expect_code 1 "$RC" 'missing CLI blocks without a run identity'
assert_grep 'drill: executable not found' "$TMP/missing.out" 'stderr failure evidence is captured into the helper output'
pass 'CLI failure keeps its stderr evidence on the helper output stream'

reset_case gate
mkdir -p "$TMP/legacy"
cp "$TMP/bin/drill" "$TMP/legacy/no-mistakes"
OLD_PATH=$PATH
PATH="$TMP/legacy:$(without_drill)"
drive run --intent intent
PATH=$OLD_PATH
expect_code 0 "$RC" 'legacy binary name is resolved'
assert_grep 'no-mistakes axi run --intent intent' "$TMP/calls" 'fallback binary receives the call'
pass 'drill binary is resolved through the shared legacy fallback'

reset_case gate
drive run --intent intent --specialized-review
expect_code 0 "$RC" 'specialized-review run flag is accepted'
assert_grep 'axi run --intent intent --specialized-review' "$TMP/calls" 'observe-only flag reaches Drill'
pass 'run-only specialized-review opt-in is forwarded'

reset_case gate
drive run --intent intent --specialized-review=true
expect_code 0 "$RC" 'explicit true form is accepted'
assert_grep 'axi run --intent intent --specialized-review' "$TMP/calls" 'explicit true opt-in reaches Drill'
pass 'explicit true specialized-review is forwarded'

reset_case gate
drive run --intent intent --specialized-review=false
expect_code 0 "$RC" 'explicit false form is accepted'
if grep -q 'specialized-review' "$TMP/calls"; then fail 'false opt-in forwarded the flag'; fi
pass 'explicit false specialized-review is not forwarded'

reset_case retry-gate
export CUSTODY=pipeline_owned
drive run --intent intent --specialized-review
expect_code 0 "$RC" 'specialized-review survives a recovery rerun'
expect_code 2 "$(wc -l < "$TMP/count" | tr -d ' ')" 'one automatic rerun was submitted'
assert_grep 'axi run --intent intent --specialized-review' "$TMP/calls" 'rerun keeps the observe-only opt-in'
pass 'specialized-review opt-in is retained across recovery reruns'

reset_case gate
drive respond --intent intent --specialized-review
expect_code 2 "$RC" 'specialized-review is refused on respond'
[ ! -s "$TMP/calls" ] || fail 'run-only flag reached Drill on respond'
pass 'specialized-review is run-only'
