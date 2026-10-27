#!/usr/bin/env bash
# tests/sq-sentry-triage.test.sh - the always-on wake triage built into
# bin/sq-sentry.sh and the shared classifier (bin/sq-classify-lib.sh). The sentry
# now absorbs the benign majority of wakes in bash and exits ONLY on an actionable
# wake, so Squad's LLM re-arms once per actionable event instead of once per
# wake. These tests cover the classifier predicates as pure functions, then drive
# a real sq-sentry.sh subprocess to assert the behavioral contract:
# provably-working no-verb wakes absorbed (no exit, no queue entry, suppressor
# advanced, beacon fresh), stopped-crew no-verb wakes surfaced (queue + exit),
# provably-working stale panes absorbed-then-escalated past the threshold (deferred
# while an active drill run-step holds), terminal-looking stale status lines
# overridden by an active run, the heartbeat
# backstop fail-safe, and afk coherence (no double-triage while the away-mode
# daemon owns supervision).
#
# Daemon-side classification/injection lives in sq-daemon.test.sh; sentry/lock
# liveness in sq-sentry-lock.test.sh; the durable-queue safety matrix in
# sq-stand-to-queue.test.sh.
set -u

# shellcheck source=tests/stand-to-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/stand-to-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/sq-classify-lib.sh"

WATCH="$ROOT/bin/sq-sentry.sh"
DRAIN="$ROOT/bin/sq-stand-to-drain.sh"

TMP_ROOT=$(fm_test_tmproot sq-sentry-triage-tests)

# Common sentry knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. SQUAD_CREW_STATE_BIN
# points at the case's hermetic fake sq-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via SQUAD_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see sq-sentry.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds, for aging a marker by
# a precise amount (touch -t takes a local-time stamp, not an epoch, on both
# platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors sq-sentry.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# Prime <file>'s .seen-* suppressor to its CURRENT signature, so the per-poll
# no-verb signal scan (which watches every *.turn-ended for a size:mtime change)
# treats a just-created or just-backdated turn-ended marker as already seen.
# Busy-expiry fixtures create/backdate turn-ended directly (there is no real
# harness touching it), so without this the marker's own first sighting would
# fire an unrelated "signal:" wake and mask the static-busy assertion under
# test. Call again after any further touch/set_mtime on the same file.
# Wraps the case's fake tmux so `capture-pane -S -N` returns only the last N lines
# of the fixture, as a real pane's bottom-anchored capture does. Without this the
# fake returns the whole fixture and a tall pane's above-tail content is invisible.
use_tail_aware_tmux() {  # <fakebin>
  local fakebin=$1
  mv "$fakebin/tmux" "$fakebin/tmux-base"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ] && [ -n "${SQUAD_FAKE_TMUX_CAPTURE:-}" ]; then
  lines=
  while [ $# -gt 0 ]; do
    if [ "$1" = -S ]; then lines=${2#-}; fi
    shift
  done
  if [ -n "$lines" ]; then tail -n "$lines" "$SQUAD_FAKE_TMUX_CAPTURE"; else cat "$SQUAD_FAKE_TMUX_CAPTURE"; fi
  exit 0
fi
exec "$(dirname "$0")/tmux-base" "$@"
SH
  chmod +x "$fakebin/tmux"
}

prime_turnend_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/sq-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/sq-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

# Arms a fresh incarnation and immediately applies event=compaction (seq 2),
# matching what the generated pi-ext now writes from session_before_compact.
# Prints the gen so a caller can apply a further event under the same
# incarnation (e.g. a second, genuinely later compaction).
record_pi_compaction() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/sq-busy-event.sh" arm "$state" "$id" --source pi-ext --event agent-start)
  "$ROOT/bin/sq-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event compaction >/dev/null
  printf '%s' "$gen"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Minimal fake TUIOS daemon for the blocked-pane wake tests below. It covers
# only the verbs the per-poll loop actually calls on an already-existing
# window (get-window, list-windows, list-agents, peek-prompt, capture-pane) -
# no spawn/workspace surface, since these tests never go through
# fm_backend_tuios_container_ensure. Window id defaults to w1 and is driven by
# SQUAD_TUIOS_FAKE_WINDOW_ID so a case can target a different window; its
# label (name) must match window_label's "sq-<task>" or fm_backend_tuios_target_ready
# refuses the whole read, so SQUAD_TUIOS_FAKE_WINDOW_NAME must be set to match
# the test's meta-derived task id.
install_fake_tuios() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/tuios" <<'SH'
#!/usr/bin/env bash
set -u
id=${SQUAD_TUIOS_FAKE_WINDOW_ID:-w1}
case "${1:-}" in
  get-window)
    printf '{"window":{"id":"%s","name":"%s","cwd":"/tmp/wt","has_foreground_process":false}}\n' \
      "$id" "${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task}"
    ;;
  list-windows)
    [ "${SQUAD_TUIOS_FAKE_LIST_FAIL:-0}" = 1 ] && exit 1
    printf '{"windows":[{"id":"%s","name":"%s"}]}\n' "$id" "${SQUAD_TUIOS_FAKE_WINDOW_NAME:-sq-task}"
    ;;
  list-agents)
    printf '{"agents":[{"id":"%s","foreground":"","state":"%s","harness_id":"claude","confidence":"certain","blocked_by":"%s"}]}\n' \
      "$id" "${SQUAD_TUIOS_FAKE_AGENT_STATE:-working}" "${SQUAD_TUIOS_FAKE_BLOCKED_BY:-}"
    ;;
  peek-prompt)
    if [ "${SQUAD_TUIOS_FAKE_PROMPT_BLOCKED:-0}" = 1 ]; then
      printf '{"blocked":true,"found":true,"kind":"%s","message":"%s","lines":["%s"],"options":%s,"prompt_id":"p1","success":true}\n' \
        "${SQUAD_TUIOS_FAKE_PROMPT_KIND:-approval}" "${SQUAD_TUIOS_FAKE_PROMPT_MESSAGE:-trust this directory?}" \
        "${SQUAD_TUIOS_FAKE_PROMPT_MESSAGE:-trust this directory?}" "${SQUAD_TUIOS_FAKE_PROMPT_OPTIONS:-[]}"
    else
      printf '{"blocked":false,"found":false,"reason":"the pane is not on needs_input","success":true}\n'
    fi
    ;;
  capture-pane)
    printf '%s\n' "${SQUAD_TUIOS_FAKE_CAPTURE_TEXT:-pane text}"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tuios"
}

install_fake_orca() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  'terminal show')
    [ "${SQUAD_FAKE_ORCA_SHOW_FAIL:-0}" = 1 ] && exit 1
    printf '{"ok":true,"result":{"observation":{"agentWait":%s}}}\n' "${SQUAD_FAKE_ORCA_AGENT_WAIT:-null}"
    ;;
  'terminal read')
    printf '{"ok":true,"result":{"terminal":{"tail":["idle shell prompt"]}}}\n'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/orca"
}

# --- pure classifier predicates (sq-classify-lib.sh) ------------------------

test_signal_reason_is_actionable_classifier() {
  local dir state
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/a.status"
  signal_reason_is_actionable "$state/a.status" && fail "benign working: signal classified actionable"
  printf 'working: x\nneeds-decision: pick A or B\n' > "$state/b.status"
  signal_reason_is_actionable "$state/b.status" || fail "commander-relevant signal classified benign"
  : > "$state/c.turn-ended"
  signal_reason_is_actionable "$state/c.turn-ended" && fail "a bare turn-ended marker classified actionable"
  # Coalesced batch: one benign + one commander-relevant -> actionable.
  signal_reason_is_actionable "$state/a.status" "$state/b.status" || fail "coalesced benign+actionable not actionable"
  pass "signal_reason_is_actionable: benign absorbed, commander verbs and coalesced batches surfaced"
}

test_stale_is_terminal_classifier() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: ready in branch sq/x\n' > "$state/term.status"
  stale_is_terminal "sess:sq-term" "$state" || fail "terminal stale status not classified terminal"
  fm_write_meta "$state/herdr-term.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch sq/herdr\n' > "$state/herdr-term.status"
  stale_is_terminal "default:w1:p2" "$state" || fail "terminal herdr stale status not resolved through metadata"
  printf 'working: compiling\n' > "$state/nonterm.status"
  stale_is_terminal "sess:sq-nonterm" "$state" && fail "non-terminal stale classified terminal"
  stale_is_terminal "sess:sq-missing" "$state" && fail "stale with no status classified terminal"
  pass "stale_is_terminal: terminal status surfaces, non-terminal and no-status are benign"
}

test_scan_commander_relevant_statuses_classifier() {
  local dir state out
  dir=$(make_case classify-scan); state="$dir/state"
  printf 'working: a\n' > "$state/one.status"
  printf 'blocked: no perms\n' > "$state/two.status"
  printf 'done: PR https://x/y/pull/1\n' > "$state/three.status"
  out=$(scan_commander_relevant_statuses "$state")
  printf '%s' "$out" | grep -F "two.status" >/dev/null || fail "scan missed a blocked: status"
  printf '%s' "$out" | grep -F "three.status" >/dev/null || fail "scan missed a done: status"
  printf '%s' "$out" | grep -F "one.status" >/dev/null && fail "scan surfaced a benign working: status"
  pass "scan_commander_relevant_statuses lists only commander-relevant statuses"
}

test_classifier_primitives() {
  local dir state open activity cursor ident size
  dir=$(make_case classify-primitives); state="$dir/state"
  printf 'working: a\n\ndone: b\n\n' > "$state/x.status"
  [ "$(last_status_line "$state/x.status")" = "done: b" ] || fail "last_status_line did not return the last non-blank line"
  status_is_commander_relevant "done: b" || fail "done: not recognized as commander-relevant"
  status_is_commander_relevant "needs-decision [key=q1]: b" || fail "keyed needs-decision not recognized as commander-relevant"
  status_is_commander_relevant "working: b" && fail "working: wrongly recognized as commander-relevant"
  # Incident regression: free-text "merged" inside a nonterminal working: line must
  # not become commander-relevant (AFK false-terminal path).
  status_is_commander_relevant \
    "working: stage 2 setup complete on PR #74 exact source branch rebased onto merged #76; task dates preserved" \
    && fail "working: ... merged #N wrongly recognized as commander-relevant"
  status_is_commander_relevant "working: rebased onto predecessor #76" \
    && fail "working: predecessor prose wrongly recognized as commander-relevant"
  status_is_commander_relevant "working: PR ready checks green merged ready in branch" \
    && fail "working: free-text tokens wrongly recognized as commander-relevant"
  status_is_commander_relevant "done: PR https://x/pull/76 checks green" \
    || fail "genuine done: checks green not commander-relevant"
  status_is_terminal_verb "done: PR https://x/pull/76 checks green" \
    || fail "done: not a terminal verb"
  status_is_terminal_verb "working: rebased onto merged #76" \
    && fail "working: wrongly classed as terminal verb"
  status_is_commander_relevant "merged" || fail "legacy bare merged free-text not commander-relevant"
  status_is_commander_relevant "PR ready https://x/pull/2" \
    || fail "legacy bare PR ready free-text not commander-relevant"
  [ "$(window_to_task "sess:sq-fix-login-k3")" = "fix-login-k3" ] || fail "window_to_task did not strip session+sq- prefix"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  [ "$(window_to_task "default:w1:p2" "$state")" = "herdr-task" ] || fail "window_to_task did not resolve opaque backend target through metadata"
  SQUAD_COMMANDER_RE='custom-verb:' status_is_commander_relevant "custom-verb: x" || fail "SQUAD_COMMANDER_RE override not honored"
  SQUAD_COMMANDER_RE='custom-verb:' status_is_commander_relevant "done: x" && fail "SQUAD_COMMANDER_RE override did not replace the default verb set"
  SQUAD_COMMANDER_RE='merged|custom-verb:' status_is_commander_relevant "working: rebased onto merged #76" \
    && fail "SQUAD_COMMANDER_RE override bypassed working: suppression"
  SQUAD_COMMANDER_RE='checks green|custom-verb:' status_is_commander_relevant "paused: checks green pending approval" \
    && fail "SQUAD_COMMANDER_RE override bypassed paused: suppression"
  SQUAD_COMMANDER_RE='custom-verb:' status_is_commander_relevant "custom-verb: x" \
    || fail "nonterminal suppression weakened custom bare-line behavior"
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1]\nneeds-decision [key=bad key]: malformed\n' > "$state/keys.status"
  open=$(status_open_decisions "$state/keys.status")
  printf '%s' "$open" | grep -F $'q1\t' >/dev/null \
    || fail "a key token in resolved note prose closed the keyed decision"
  printf '%s' "$open" | grep -F $'prose\t' >/dev/null \
    && fail "a key token in note prose changed the decision key"
  printf '%s' "$open" | grep -F $'bad key\t' >/dev/null \
    && fail "an invalid key slug entered the open-decision set"
  printf 'needs-decision: [key=colon-form] select a path\nresolved [key=colon-form]: selected\n' > "$state/colon-form.status"
  [ -z "$(status_open_decisions "$state/colon-form.status")" ] \
    || fail "colon-then-bracket keyed opening did not resolve under the same key"
  [ -z "$(status_open_decisions_incremental "$state/colon-form.status")" ] \
    || fail "incremental fold disagreed on colon-then-bracket keyed opening"
  printf 'needs-decision: choose a path\nresolved [key=not-default]: answered\n' > "$state/unkeyed-mismatch.status"
  open=$(status_open_decisions "$state/unkeyed-mismatch.status")
  printf '%s' "$open" | grep -F $'default\tneeds-decision\t' >/dev/null \
    || fail "a resolution with a different key incorrectly closed an unkeyed opening"
  open=$(status_open_decisions_incremental "$state/unkeyed-mismatch.status")
  printf '%s' "$open" | grep -F $'default\tneeds-decision\t' >/dev/null \
    || fail "incremental fold did not preserve a mismatched unkeyed opening"
  printf 'needs-decision [key=stale]: choose\nresolved [key=stale]: answered\n' > "$state/stale-cursor.status"
  cursor=$( _fm_open_decisions_cursor_path "$state/stale-cursor.status")
  ident=$(_fm_open_decisions_file_ident "$state/stale-cursor.status")
  size=$(wc -c < "$state/stale-cursor.status" | tr -d '[:space:]')
  printf 'version=2\noffset=%s\nident=%s\nstale\tneeds-decision\tchoose\n' "$size" "$ident" > "$cursor"
  [ -z "$(status_open_decisions_incremental "$state/stale-cursor.status")" ] \
    || fail "incremental fold retained a stale persisted key after an earlier resolution"
  [ -z "$(status_open_decisions "$state/stale-cursor.status")" ] \
    || fail "whole-file fold disagreed that the stale-cursor decision was closed"
  cat > "$state/activity.status" <<'EOF'
working [key=phase7]: Phase 7 started
working [key=phase6]: Phase 6 started
working [key=legal]: reviewing legal dependency
done [key=phase6]: Phase 6 completed
resolved [key=phase7]: Phase 7 completed and moved to Done
paused [key=legal]: awaiting external counsel
resolved [key=legal]: legal item returned to the queue
working [key=phase8]: Phase 8 started
EOF
  activity=$(status_open_activities "$state/activity.status")
  printf '%s' "$activity" | grep -F $'phase8\tworking\tPhase 8 started' >/dev/null \
    || fail "the current keyed working phase was not retained"
  printf '%s' "$activity" | grep -F $'phase7\t' >/dev/null \
    && fail "a keyed resolved event did not close the older working phase"
  printf '%s' "$activity" | grep -F $'phase6\t' >/dev/null \
    && fail "a same-key terminal event did not supersede the older working phase"
  printf '%s' "$activity" | grep -F $'legal\t' >/dev/null \
    && fail "a keyed resolved event did not close the declared pause"
  printf 'working: legacy start\ndone: legacy completion\n' > "$state/legacy-activity.status"
  [ -z "$(status_open_activities "$state/legacy-activity.status")" ] \
    || fail "a legacy terminal event did not supersede the default working phase"
  pass "classifier primitives: keyed decisions and activity phases, commander relevance, window-to-task, and overrides"
}

# operator_is_provably_working: the absorb-only-when-provably-working predicate. It is
# benign (absorb) ONLY when sq-crew-state.sh reports the operator as working from an
# actively-running pipeline step (source run-step) or a busy pane (source pane);
# everything else - a stale working: status-log line, a finished/parked/failed run,
# an unknown/torn-down crew, or an empty id - is NOT provable, so it surfaces. The
# fake sq-crew-state.sh (SQUAD_CREW_STATE_BIN) returns a canned verdict per case.
test_operator_is_provably_working_classifier() {
  local dir fakebin
  dir=$(make_case provably-working); fakebin="$dir/fakebin"
  # Point the predicate at this case's hermetic fake and drive its verdict per case.
  # export marks the var for the fake subprocess; it is unset again at the end so it
  # cannot leak into a later test (every behavioral test sets its own verdict anyway).
  export SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh"
  export SQUAD_FAKE_CREW_STATE
  SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  operator_is_provably_working a || fail "active run-step not treated as provably working"
  SQUAD_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  operator_is_provably_working a || fail "busy pane not treated as provably working"
  SQUAD_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  ! operator_is_provably_working a || fail "stale status-log working: treated as provably working"
  SQUAD_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! operator_is_provably_working a || fail "finished run treated as provably working"
  SQUAD_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! operator_is_provably_working a || fail "parked run treated as provably working"
  SQUAD_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  ! operator_is_provably_working a || fail "failed run treated as provably working"
  SQUAD_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  ! operator_is_provably_working a || fail "unknown crew treated as provably working"
  SQUAD_FAKE_CREW_STATE='state: working · source: run-step · x'
  ! operator_is_provably_working "" || fail "empty id treated as provably working"
  unset SQUAD_FAKE_CREW_STATE
  pass "operator_is_provably_working: only working+run-step/pane is provable; idle/finished/parked/failed/unknown surface"
}

# status_is_paused: the shared pause verb test both consumers read (so neither
# hardcodes the literal). Matches only the verb before the first colon, so a reason
# that merely mentions "paused" does not false-match, and a genuine blocker stays a
# blocker.
test_status_is_paused_classifier() {
  local dir file
  dir=$(make_case resolved-after-pause); file="$dir/state/held.status"
  printf 'paused: waiting for commander\nresolved: commander answered the separate decision\n' > "$file"
  [ "$(last_status_state_line "$file")" = 'paused: waiting for commander' ] \
    || fail "resolved event masked the active declared wait"
  status_is_paused 'paused: holding for the upstream release' || fail "paused verb not recognized"
  status_is_paused '  paused:   waiting on a rate-limit reset' || fail "leading-space paused verb not recognized"
  status_is_paused 'blocked: the build is paused upstream' && fail "a blocked line mentioning paused false-matched"
  status_is_paused 'working: paused the animation loop' && fail "a working line mentioning paused false-matched"
  status_is_paused 'done: shipped' && fail "done classified as paused"
  status_is_paused '' && fail "empty line classified as paused"
  # A pause is deliberately NOT commander-relevant: it is a stop-nagging signal, not
  # work to keep surfacing.
  status_is_commander_relevant 'paused: holding for the upstream release' && fail "paused is commander-relevant (should not be)"
  status_is_paused_or_commander_held 'paused: holding for the upstream release' \
    || fail "declared pause not recognized by the bounded-idle classifier"
  status_is_paused_or_commander_held 'commander-held [key=route]: tracked by task-decision-route' \
    || fail "commander-held transfer not recognized by the bounded-idle classifier"
  status_is_paused_or_commander_held 'resolved [key=route]: commander answered' \
    && fail "resolved decision remained classed as commander-held"
  pass "status_is_paused: only the leading paused verb matches, and paused is not commander-relevant"
}

# operator_absorb_class: the single sq-crew-state.sh read that returns BOTH absorb
# reasons - working (active run/busy pane), paused (declared external wait), or none
# (surface it) - so the sentry's stale path gets both for one bounded call.
# operator_is_paused delegates to it exactly as operator_is_provably_working does.
test_operator_absorb_class_classifier() {
  local dir fakebin state
  dir=$(make_case absorb-class); fakebin="$dir/fakebin"; state="$dir/state"
  export SQUAD_STATE_OVERRIDE="$state"
  export SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh"
  export SQUAD_FAKE_CREW_STATE
  SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(operator_absorb_class a)" = working ] || fail "active run-step not classed working"
  SQUAD_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(operator_absorb_class a)" = working ] || fail "busy pane not classed working"
  SQUAD_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream'
  [ "$(operator_absorb_class a)" = paused ] || fail "declared pause not classed paused"
  operator_is_paused a || fail "operator_is_paused did not recognize a paused verdict"
  ! operator_is_provably_working a || fail "a paused crew was treated as provably working"
  SQUAD_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  [ "$(operator_absorb_class a)" = none ] || fail "stale working: status-log classed absorbable"
  SQUAD_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  [ "$(operator_absorb_class a)" = none ] || fail "unknown crew classed absorbable"
  ! operator_is_paused a || fail "unknown crew classed paused"
  [ "$(operator_absorb_class "")" = none ] || fail "empty id not classed none"
  SQUAD_FAKE_CREW_STATE='state: parked · source: run-step · parked at rebase (ask-user: authority decision)'
  printf 'needs-decision [key=gate]: choose an authority\n' > "$state/a.status"
  [ "$(operator_absorb_class a)" = paused ] || fail "parked run-step with an open decision was not classed paused"
  : > "$state/a.status"
  SQUAD_FAKE_CREW_STATE='state: parked · source: run-step · parked at rebase'
  [ "$(operator_absorb_class a)" = none ] || fail "parked run-step without an open decision was classed paused"
  unset SQUAD_FAKE_CREW_STATE SQUAD_STATE_OVERRIDE
  pass "operator_absorb_class: working/paused/none from one read; decision-parked run-steps are paused"
}

# signal_operator_provably_working: a no-verb "signal:" wake is benign ONLY when EVERY
# task it references is provably working; if any crew has stopped, or no task can be
# resolved, it surfaces. Files map to ids by stripping .status / .turn-ended.
test_signal_operator_provably_working_classifier() {
  local dir fakebin state
  dir=$(make_case signal-provably-working); fakebin="$dir/fakebin"; state="$dir/state"
  export SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh"
  export SQUAD_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export SQUAD_FAKE_CREW_STATE_b='state: done · source: run-step · run passed'
  signal_operator_provably_working "$state/a.status" "$state/a.turn-ended" \
    || fail "a single provably-working crew (status+turn-end) was not benign"
  ! signal_operator_provably_working "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a stopped crew was treated as benign"
  ! signal_operator_provably_working "$state/b.turn-ended" \
    || fail "a stopped crew's bare turn-end was treated as benign"
  ! signal_operator_provably_working "$state/a.meta" \
    || fail "a non-signal file resolved to a benign verdict"
  ! signal_operator_provably_working \
    || fail "an empty signal file list was treated as benign"
  unset SQUAD_FAKE_CREW_STATE_a SQUAD_FAKE_CREW_STATE_b
  pass "signal_operator_provably_working: benign only when every referenced crew is provably working"
}

# signal_operator_is_paused: a no-verb "signal:" wake is benign when EVERY
# task it references is in a declared external-wait pause. This matches the
# stale path's handle_paused_stale absorption so paused operators are not
# woken by the signal path independently.
test_signal_operator_is_paused_classifier() {
  local dir fakebin state
  dir=$(make_case signal-is-paused); fakebin="$dir/fakebin"; state="$dir/state"
  export SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh"
  export SQUAD_FAKE_CREW_STATE_a='state: paused · source: status-log · awaiting external'
  export SQUAD_FAKE_CREW_STATE_b='state: working · source: run-step · running'
  signal_operator_is_paused "$state/a.status" "$state/a.turn-ended" \
    || fail "a single paused crew (status+turn-end) was not recognized as paused"
  ! signal_operator_is_paused "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a working crew was treated as paused"
  ! signal_operator_is_paused "$state/b.turn-ended" \
    || fail "a working crew's bare turn-end was treated as paused"
  ! signal_operator_is_paused \
    || fail "an empty signal file list was treated as paused"
  unset SQUAD_FAKE_CREW_STATE_a SQUAD_FAKE_CREW_STATE_b
  pass "signal_operator_is_paused: true only when every referenced crew is paused"
}

# operator_compaction_silent_reason / signal_compaction_needs_attention: the
# compaction-without-status absorb override (bin/sq-classify-lib.sh). Exercises
# every gate directly: event=compaction required, no status line required, the
# minimum-age floor, and the one-wake-per-distinct-compaction bound (seq dedup).
test_compaction_silent_reason_classifier() {
  local dir state gen now r r2
  dir=$(make_case compaction-silent-reason); state="$dir/state"
  export SQUAD_STATE_OVERRIDE="$state"
  now=$(date +%s)

  printf 'id=old\n' > "$state/old.meta"
  gen=$(record_pi_compaction "$state" old)
  set_mtime "$((now - 400))" "$state/old.busy-gen"
  r=$(operator_compaction_silent_reason old) \
    || fail "an old, status-silent task with event=compaction did not fire"
  case "$r" in
    compaction:*) ;;
    *) fail "unexpected reason string: $r" ;;
  esac
  # Pure read: checking again before anything marks it notified must keep
  # firing (operator_compaction_silent_reason never writes the marker
  # itself - see operator_compaction_mark_notified for the write half, which
  # bin/sq-sentry.sh calls only after it durably queues the wake).
  operator_compaction_silent_reason old >/dev/null \
    || fail "a pure re-check before marking notified stopped firing"
  operator_compaction_mark_notified old
  ! r2=$(operator_compaction_silent_reason old) \
    || fail "the same compaction seq re-fired after being marked notified (bound violated): $r2"

  # A later, genuinely new compaction (seq advances) is allowed to fire again.
  "$ROOT/bin/sq-busy-event.sh" apply "$state" old busy --gen "$gen" --source pi-ext --event compaction >/dev/null
  operator_compaction_silent_reason old >/dev/null \
    || fail "a new compaction occurrence (advanced seq) did not re-fire after the bound"

  printf 'id=young\n' > "$state/young.meta"
  record_pi_compaction "$state" young >/dev/null
  set_mtime "$((now - 10))" "$state/young.busy-gen"
  ! operator_compaction_silent_reason young >/dev/null \
    || fail "a task younger than the minimum age fired (false positive on startup noise)"

  printf 'id=busy\n' > "$state/busy.meta"
  record_pi_busy "$state" busy >/dev/null
  set_mtime "$((now - 400))" "$state/busy.busy-gen"
  ! operator_compaction_silent_reason busy >/dev/null \
    || fail "an ordinary busy event (not compaction) fired"

  printf 'id=reported\n' > "$state/reported.meta"
  record_pi_compaction "$state" reported >/dev/null
  set_mtime "$((now - 400))" "$state/reported.busy-gen"
  printf 'working: setup complete\n' > "$state/reported.status"
  ! operator_compaction_silent_reason reported >/dev/null \
    || fail "a task that already reported a status line fired"

  # A same-id relaunch re-arms the busy contract: the gen changes and seq
  # restarts. The prior incarnation's notified marker must not suppress the new
  # incarnation's compaction merely because it reuses the same seq number.
  printf 'id=relaunch\n' > "$state/relaunch.meta"
  record_pi_compaction "$state" relaunch >/dev/null
  set_mtime "$((now - 400))" "$state/relaunch.busy-gen"
  operator_compaction_silent_reason relaunch >/dev/null \
    || fail "the first incarnation's compaction did not fire"
  operator_compaction_mark_notified relaunch
  sleep 1
  record_pi_compaction "$state" relaunch >/dev/null
  set_mtime "$((now - 400))" "$state/relaunch.busy-gen"
  operator_compaction_silent_reason relaunch >/dev/null \
    || fail "a re-armed incarnation's compaction on the same seq was suppressed"

  ! operator_compaction_silent_reason nonexistent >/dev/null \
    || fail "a task with no busy-state record at all fired"

  unset SQUAD_STATE_OVERRIDE
  pass "compaction-without-status override: event+no-status+min-age gates and the per-compaction bound all hold"
}

# Co-batched over-mark regression: signal_compaction_mark_notified must
# advance only the task that currently matches the full override. A task that
# merely carries event=compaction but is still too young (or already reported
# a status line) shares the wake file list with a genuinely matching task and
# must NOT have its suppressor set - otherwise its later, genuine compaction
# wake is silently suppressed.
test_compaction_mark_notified_does_not_advance_non_matching_tasks() {
  local dir state now
  dir=$(make_case compaction-mark-notified-scope); state="$dir/state"
  export SQUAD_STATE_OVERRIDE="$state"
  now=$(date +%s)

  printf 'id=co-old\n' > "$state/co-old.meta"
  record_pi_compaction "$state" co-old >/dev/null
  set_mtime "$((now - 400))" "$state/co-old.busy-gen"

  printf 'id=co-young\n' > "$state/co-young.meta"
  record_pi_compaction "$state" co-young >/dev/null
  set_mtime "$((now - 10))" "$state/co-young.busy-gen"

  signal_compaction_mark_notified \
    "$state/co-old.turn-ended" "$state/co-young.turn-ended"

  [ -f "$state/.compaction-notified-co-old" ] \
    || fail "signal_compaction_mark_notified did not advance the genuinely matching compaction"
  [ ! -f "$state/.compaction-notified-co-young" ] \
    || fail "signal_compaction_mark_notified advanced a too-young task that never matched the override"

  # Once it genuinely ages past the floor, the co-batched young task's own
  # compaction must still fire (its marker was never written).
  set_mtime "$((now - 400))" "$state/co-young.busy-gen"
  operator_compaction_silent_reason co-young >/dev/null \
    || fail "the co-batched, previously-too-young task's later genuine compaction was suppressed"

  unset SQUAD_STATE_OVERRIDE
  pass "signal_compaction_mark_notified advances only the compaction task that currently matches the override"
}

# --- a no-verb signal for a paused operator is absorbed (defect regression) ------
# The signal path previously surfaced .turn-ended signals for paused operators
# because signal_operator_provably_working returned false for "paused" (only
# "working" returns true). The stale path correctly absorbed these via
# handle_paused_stale, but the signal path independently found the turn-ended
# file and surfaced it. This test verifies the fix: paused operators' turn-end
# signals are absorbed, matching the stale path's behavior.
test_paused_signal_absorbed() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case paused-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'paused: awaiting external review\n' > "$status_file"
  printf 'id=task\n' > "$state/task.meta"
  : > "$state/task.turn-ended"
  # The crew is in a declared external-wait pause: the signal path must absorb.
  export SQUAD_FAKE_CREW_STATE='state: paused · source: status-log · awaiting external'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited for a turn-end signal on a paused operator (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "paused signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.stand-to-queue" ] || fail "paused signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "paused signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-sentry-beat" ] || fail "sentry beacon was not touched while absorbing"
  # Verify the triage log recorded the absorption.
  grep -q "absorbed benign" "$state/.sentry-triage.log" 2>/dev/null \
    || fail "triage log did not record the absorbed benign signal"
  reap "$pid"
  pass "a no-verb signal for a paused operator is absorbed (no exit, no queue, triage logged)"
}

# --- benign wakes are absorbed ONLY when the operator is provably working ---------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  printf 'id=task\n' > "$state/task.meta"
  # The crew's pipeline is in an actively-running step: positive evidence it is
  # still working, so a no-verb working: signal is absorbed (the original low-churn
  # case during a long validation).
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited for a working: signal whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.stand-to-queue" ] || fail "provably-working signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "provably-working signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-sentry-beat" ] || fail "sentry beacon was not touched while absorbing"
  reap "$pid"
  pass "a no-verb signal whose crew is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  printf 'id=task\n' > "$state/task.meta"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export SQUAD_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited for a turn-end whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.stand-to-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  pass "a bare turn-end whose crew is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose crew is NOT provably working SURFACES -------------
# This is the swallowed-finish fix: an operator that finished (or stopped and waits)
# reports its final turn-end with no commander-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # A live task record: the marker below belongs to a task that still exists, so
  # its stopped verdict must keep waking supervision (control for the orphan drop).
  printf 'id=task\n' > "$state/task.meta"
  # No running pipeline, no busy pane: the operator has stopped (e.g. it finished via
  # an interactive menu and wrote no done: status). Default unknown verdict.
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not surface a turn-end whose crew is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "sentry did not print the surfaced turn-end signal"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "surfaced turn-end was not queued"
  pass "a bare turn-end whose crew is not provably working is surfaced (the swallowed-finish fix)"
}

# --- a turn-end whose task record is gone is dropped, not surfaced -------------
# A completed teardown removes the task's meta, status, and turn-end marker, but a
# late turn-end hook touch can recreate the marker after the record is gone. With
# no state/<id>.meta nothing is left to supervise, so the signal scan must drop the
# marker: surfacing it would repeat a stopped-operator wake on every poll for a
# task that no longer exists.
test_orphan_turn_ended_dropped() {
  local dir state fakebin out pid
  dir=$(make_case orphan-turn-ended); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'id=task\n' > "$state/task.meta"
  : > "$state/task.turn-ended"
  # Bookkeeping left over from an earlier sighting: the orphan drop must retire it
  # the same way the stale path resets a vanished target's markers.
  printf '0:0' > "$state/.seen-task_turn-ended"
  # Teardown shape: the task record is removed while its turn-end marker survives.
  # The crew verdict is the same not-working verdict that surfaces a live stopped
  # operator, so only the missing record keeps this wake from surfacing.
  rm -f "$state/task.meta"
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry surfaced a turn-end whose task record is gone: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -s "$out" ] || fail "orphan turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.stand-to-queue" ] || fail "orphan turn-end enqueued a durable wake record"
  [ ! -e "$state/.seen-task_turn-ended" ] || fail "orphan turn-end left its .seen-* marker behind"
  pass "a turn-end whose task record is gone is dropped instead of waking supervision"
}

# --- a task torn down during SIGNAL_GRACE does not wake on the pre-grace entry --
# The scan that first sees a live turn-end returns it, and the sentry then sleeps a
# grace period before classifying. A teardown completing inside that window leaves
# the already-collected entry in flight, so the wake boundary must re-check the task
# record just like the scan does.
test_orphan_signal_dropped_inside_grace() {
  local dir state fakebin out pid real_sleep ticks grace
  dir=$(make_case orphan-signal-grace); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  grace=5
  printf 'id=task\n' > "$state/task.meta"
  : > "$state/task.turn-ended"
  printf '0:0' > "$state/.seen-task_turn-ended"
  # The grace sleep starts only after the first scan collected the live marker, so
  # a shim on that exact value makes the teardown deterministic instead of racing
  # the sentry's unbounded startup: the test acts once the sleep is entered.
  real_sleep=$(command -v sleep)
  cat > "$fakebin/sleep" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = "$grace" ] && : > "$state/.grace-entered"
exec "$real_sleep" "\$@"
EOF
  chmod +x "$fakebin/sleep"
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_POLL=1 SQUAD_SIGNAL_GRACE="$grace" SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  ticks=0
  while [ ! -e "$state/.grace-entered" ] && kill -0 "$pid" 2>/dev/null && [ "$ticks" -lt 300 ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if [ ! -e "$state/.grace-entered" ]; then
    reap "$pid"; fail "sentry never entered the signal grace sleep: $(cat "$out")"
  fi
  rm -f "$state/task.meta" "$state/task.status" "$state/task.turn-ended"
  if ! wait_live "$pid" 80; then
    reap "$pid"; fail "sentry woke for a task torn down inside the signal grace window: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -s "$out" ] || fail "torn-down signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.stand-to-queue" ] || fail "torn-down signal enqueued a durable wake record"
  [ ! -e "$state/.seen-task_turn-ended" ] || fail "torn-down signal left a .seen-* marker behind"
  pass "a task torn down inside the signal grace window is dropped at the wake boundary"
}

# --- compaction-without-status override: integration through sq-sentry.sh -------
# The gap this guards against: a compaction's burst of turn-end touches looks
# exactly like ordinary busy churn, so the provably-working absorb path above
# (test_turn_ended_provably_working_absorbed) would otherwise swallow it too.

test_turn_ended_compaction_without_status_surfaced() {
  local dir state fakebin out drain_out pid now
  dir=$(make_case compaction-silent-surfaced); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  printf 'id=task\n' > "$state/task.meta"
  now=$(date +%s)
  record_pi_compaction "$state" task >/dev/null
  set_mtime "$((now - 400))" "$state/task.busy-gen"
  # Otherwise provably working (busy pane): without the override this is
  # exactly test_turn_ended_provably_working_absorbed's absorbed case.
  export SQUAD_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not surface a compaction-without-status turn-end: $(cat "$out")"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null \
    || fail "sentry did not print the surfaced turn-end signal: $(cat "$out")"
  grep -F "compaction: context compaction with no status line" "$out" >/dev/null \
    || fail "surfaced wake did not carry the compaction reason: $(cat "$out")"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the surfaced compaction turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null \
    || fail "surfaced compaction turn-end was not queued"
  pass "a busy-looking turn-end with event=compaction and no status line surfaces instead of absorbing"
}

test_turn_ended_compaction_too_young_absorbed() {
  local dir state fakebin out pid now
  dir=$(make_case compaction-silent-young); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  : > "$state/task.turn-ended"
  printf 'id=task\n' > "$state/task.meta"
  now=$(date +%s)
  record_pi_compaction "$state" task >/dev/null
  set_mtime "$((now - 10))" "$state/task.busy-gen"
  export SQUAD_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry surfaced a too-young compaction-without-status turn-end (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "too-young compaction turn-end printed a wake reason: $(cat "$out")"
  reap "$pid"
  pass "a compaction-without-status turn-end younger than the minimum age is absorbed, not surfaced"
}

test_turn_ended_compaction_event_mismatch_absorbed() {
  local dir state fakebin out pid now
  dir=$(make_case compaction-event-mismatch); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  : > "$state/task.turn-ended"
  printf 'id=task\n' > "$state/task.meta"
  now=$(date +%s)
  record_pi_busy "$state" task >/dev/null  # event=agent-start, not compaction
  set_mtime "$((now - 400))" "$state/task.busy-gen"
  export SQUAD_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry surfaced an ordinary busy turn-end mistaken for a compaction (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "ordinary busy (non-compaction) turn-end printed a wake reason: $(cat "$out")"
  reap "$pid"
  pass "an old, status-silent, ordinary-busy (non-compaction) turn-end is absorbed, not surfaced"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  printf 'id=task\n' > "$state/task.meta"
  # A non-drill crew (no run) whose pane went idle: sq-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export SQUAD_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "sentry did not print the surfaced working: signal"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}

# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  printf 'id=task\n' > "$state/task.meta"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "sentry did not print the actionable signal reason"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "commander-relevant signal is surfaced (queue + exit) and marked surfaced"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:sq-done"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "sentry did not print the terminal stale wake"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# A current finished result makes an idle pane intentional. Keep the legacy
# terminal-status surface above when current-state evidence is unavailable, but
# do not repeatedly wake on a green finished task awaiting merge.
test_finished_stale_is_absorbed() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case finished-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:sq-finished"
  printf 'finished, awaiting merge' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/finished.meta"
  printf 'done: PR https://example.test/pr/7 checks green\n' > "$state/finished.status"
  sig=$(seen_sig "$state/finished.status"); printf '%s' "$sig" > "$state/.seen-finished_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting merge")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export SQUAD_FAKE_CREW_STATE='state: done · source: run-step · checks green, awaiting merge'

  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=1 \
    SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry surfaced a current finished task as stale: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "finished task printed a stale wake: $(cat "$out")"
  [ ! -s "$state/.stand-to-queue" ] || fail "finished task queued a stale wake"
  reap "$pid"
  unset SQUAD_FAKE_CREW_STATE
  pass "a current finished task awaiting merge is absorbed without a stale wake"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: an operator's own status
# log gets no new entry once Squad hands it to a drill validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing an operator that is actively validating. operator_is_provably_working
# must get a chance to override a commander-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:sq-validating"
  printf 'drill axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE Squad triggered drill validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "drill axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the commander-relevant "done:" status-log line.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.stand-to-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"

  # Phase B: the run-step has ended and the pane is still frozen, so no active
  # step defers the wedge timer. Backdate the idle timer past the threshold; the
  # next poll escalates exactly like the non-terminal case. (While the run-step is
  # active the timer defers instead; see test_wedge_timer_deferred_while_run_step_active.)
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · no active run'
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset SQUAD_FAKE_CREW_STATE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- non-terminal stale, crew provably working: absorbed, then wedge-escalated ---
# A provably-working crew (an actively-running pipeline) legitimately sits on a
# static pane (e.g. waiting on CI), so a non-terminal stale is absorbed and only
# the wedge timer eventually escalates it - the low-churn behavior preserved.

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:sq-quiet"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/quiet.meta"
  # Non-terminal status, and prime .seen-* so the signal scan does not pre-empt
  # the stale path.
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh provably-working stale printed a wake reason during absorb"
  [ ! -s "$state/.stand-to-queue" ] || fail "fresh provably-working stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"

  # Phase B: the run-step has ended and the pane is still frozen, so no active
  # step defers the wedge timer. Backdate the idle timer past the threshold; the
  # next run escalates. (While the run-step is active the timer defers instead; see
  # test_wedge_timer_deferred_while_run_step_active.)
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · no active run'
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not escalate a provably-working non-terminal stale past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  unset SQUAD_FAKE_CREW_STATE
  pass "provably-working non-terminal stale is absorbed on first sight, then wedge-escalated past the threshold"
}

# --- foreground gate or CI wait: an active run-step defers the wedge timer ----
# Regression for the false wedge alarm: an operator driving `drill axi respond` or
# a CI monitor in the foreground cannot append paused:, so its idle pane goes stale
# while the run-step is working. The first sighting is absorbed, but the wedge timer
# then escalated every STALE_ESCALATE_SECS on later polls without re-reading the
# run-step, reaching demand-deep-inspection while CI progressed normally. An active
# run-step is the authoritative declared wait, so the timer must not escalate while
# it holds. The companion below proves the wedge limit still applies with no step.
# Exercise the real crew-state attribution and Drill activity parser, not a
# canned working verdict. Only Drill's already-thresholded quiet flag may alarm.
test_pipeline_step_quiet_activity() {
  local dir state fakebin out window key pid head branch activity step mode wakes=0
  dir=$(make_case pipeline-step-quiet); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; window="test:sq-step-quiet"; key=test_sq-step-quiet
  branch=sq/step-quiet
  mkdir -p "$dir/repo"
  git -C "$dir/repo" init -q
  git -C "$dir/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm init --allow-empty
  git -C "$dir/repo" checkout -qb "$branch"
  head=$(git -C "$dir/repo" rev-parse HEAD)
  printf 'window=%s\nkind=strike\nworktree=%s\n' "$window" "$dir/repo" > "$state/step-quiet.meta"
  printf 'working: validating\n' > "$state/step-quiet.status"
  printf '%s' "$(seen_sig "$state/step-quiet.status")" > "$state/.seen-step-quiet_status"
  printf 'waiting on drill\n' > "$dir/pane"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$ROOT/bin/sq-crew-state.sh" > "$fakebin/sq-crew-state.sh"
  cat > "$fakebin/drill" <<'SH'
#!/usr/bin/env bash
if [ "$*" = 'axi status' ]; then cat "$SQUAD_FAKE_STEP_STATUS"; fi
SH
  chmod +x "$fakebin/drill"
  export SQUAD_FAKE_STEP_STATUS="$dir/drill-status"
  export SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$dir/pane"
  for mode in progressing quiet duplicate recovered requiet ci-monitor ci-fixing; do
    step='test'; activity='2s ago: log: test output, still progressing'
    case "$mode" in
      quiet|duplicate|requiet) activity='quiet 1h17m0s ago: log: last test output' ;;
      ci-monitor|ci-fixing) step=ci; activity='quiet 4h0m0s ago: log: monitoring PR' ;;
    esac
    cat > "$SQUAD_FAKE_STEP_STATUS" <<EOF
run:
  id: "01QUIET"
  branch: $branch
  head: $head
  status: running
  steps[1]{step,status,findings,duration_ms}:
    $step,$([ "$mode" = ci-fixing ] && echo fixing || echo running),0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    $step,$([ "$mode" = ci-fixing ] && echo fixing || echo running),1h20m0s,"$activity","123",starting
EOF
    # Force a new observation, without changing the continuous quiet episode.
    rm -f "$state/.step-quiet-checked-$key"
    watch_bg "$state" "$fakebin" "$out" env SQUAD_CHECK_INTERVAL=1 SQUAD_STALE_ESCALATE_SECS=1
    pid=$!
    case "$mode" in
      quiet|requiet|ci-fixing)
        wakes=$((wakes + 1))
        wait_for_exit "$pid" 60 || { reap "$pid"; fail "$mode did not surface a quiet-step wake"; }
        grep -F "stale: $window (pipeline step $step quiet for" "$out" >/dev/null \
          || fail "quiet wake lost step name: $(cat "$out")"
        grep -F "$([ "$step" = ci ] && echo 4h0m0s || echo 1h17m0s)" "$out" >/dev/null \
          || fail 'quiet wake lost duration'
        [ "$(wc -l < "$state/.stand-to-queue" | tr -d ' ')" = "$wakes" ] \
          || fail 'quiet episode queued more than one wake'
        ;;
      *)
        wait_live "$pid" 40 || { reap "$pid"; fail "$mode unexpectedly alarmed: $(cat "$out")"; }
        reap "$pid"
        [ ! -s "$out" ] || fail "$mode printed a wake"
        [ -e "$state/.step-quiet-checked-$key" ] || fail 'quiet-step observation never ran'
        ;;
    esac
  done
  unset SQUAD_FAKE_STEP_STATUS SQUAD_FAKE_TMUX_WINDOW SQUAD_FAKE_TMUX_CAPTURE
  pass 'Drill activity: progressing steps and quiet CI monitor absorbed; quiet test/fix wakes once with step and duration'
}

test_wedge_timer_deferred_while_run_step_active() {
  local dir state fakebin out capture_file window key pane_hash since pid
  dir=$(make_case wedge-run-step-active); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:sq-gate-wait"
  printf 'waiting on drill gate' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/gate-wait.meta"
  printf 'working: validating\n' > "$state/gate-wait.status"
  sig=$(seen_sig "$state/gate-wait.status"); printf '%s' "$sig" > "$state/.seen-gate-wait_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "waiting on drill gate")
  # A prior poll already absorbed this idle hash and started the idle timer,
  # which has since run past the wedge threshold.
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Across several polls the sentry must stay alive and silent.
  if ! wait_live "$pid" 50; then
    reap "$pid"; fail "active run-step did not defer the wedge timer: sentry escalated: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -s "$out" ] || fail "active run-step printed a wedge wake: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "active run-step counted a wedge escalation"
  [ ! -s "$state/.stand-to-queue" ] || fail "active run-step queued a wedge wake"
  # The idle timer must have been refreshed by the check itself, so a vacuous pass
  # (the stale path never ran) cannot satisfy the assertions above.
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  case "$since" in ''|*[!0-9]*) fail "idle timer was lost while the run-step is active" ;; esac
  [ $(( $(date +%s) - since )) -lt 240 ] || fail "idle timer was not refreshed while the run-step is active: the stale check never ran"
  unset SQUAD_FAKE_CREW_STATE
  pass "an active run-step defers the wedge timer past the threshold: no escalation, idle timer kept fresh"
}

# Companion: the same stale pane with the idle timer past the threshold and NO
# active step is a genuinely stuck worker, so the wedge limit still escalates it.
test_wedge_timer_escalates_without_active_step() {
  local dir state fakebin out capture_file window key pane_hash pid
  dir=$(make_case wedge-no-active-step); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:sq-gate-stuck"
  printf 'frozen with no drill step' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/gate-stuck.meta"
  printf 'working: validating\n' > "$state/gate-stuck.status"
  sig=$(seen_sig "$state/gate-stuck.status"); printf '%s' "$sig" > "$state/.seen-gate-stuck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "frozen with no drill step")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · no active run'

  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a stale pane with no active step did not escalate past the wedge threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset SQUAD_FAKE_CREW_STATE
  pass "without an active step the wedge limit still escalates a stuck pane"
}

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: an operator with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-drill crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:sq-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the operator never wrote a commander-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "sentry did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: an operator intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:sq-held"
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not commander-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # operator_absorb_class reads the declared pause from sq-crew-state.sh.
  export SQUAD_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_TMUX_CURRENT_COMMAND=zsh \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.stand-to-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_TMUX_CURRENT_COMMAND=zsh \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_PAUSE_RESURFACE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# A parked run-step with an open decision is an expected gate wait. It can be
# surfaced once for recheck after the anchored pause cadence, but not on every poll.
test_decision_parked_stale_is_throttled() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back wakes
  dir=$(make_case decision-parked-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gated.status"
  window="test:sq-gated"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/gated.meta"
  printf 'needs-decision [key=authority]: decide who may approve the rebase\n' > "$statusf"
  back=$(( $(date +%s) - 20 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gated_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'idle at decision gate' > "$capture_file"
  pane_hash=$(hash_text "idle at decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export SQUAD_FAKE_CREW_STATE='state: parked · source: run-step · parked at rebase (ask-user: authority decision)'
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_PAUSE_RESURFACE_SECS=10 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "decision-parked gate did not surface its bounded first recheck"
  grep -F 'stale: ' "$out" >/dev/null || fail "decision-parked recheck omitted the stale reason"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_PAUSE_RESURFACE_SECS=10 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_live "$pid" 25; then reap "$pid"; fail "decision-parked run emitted a repeat wake inside the pause cadence"; fi
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf '0')
  [ "$wakes" -eq 1 ] || fail "decision-parked run emitted $wakes wakes inside the pause cadence"
  reap "$pid"
  unset SQUAD_FAKE_CREW_STATE
  pass "a decision-parked run is rechecked on the pause cadence instead of waking on every poll"
}

# A live declared pause can have a changing pane footer on every poll. The first
# stale observation is surfaced for confirmation, then the stable per-key cadence
# marker suppresses footer-driven repeats.
test_live_paused_churning_pane_is_throttled() {
  local dir state fakebin out capture_file statusf window key sig pid round wakes
  dir=$(make_case live-paused-churning); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:sq-held"
  printf 'window=%s\nkind=strike\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # The live endpoint is present but its current-state read is inconclusive, so
  # pause_state_class deliberately returns none and the confirmation path runs.
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · current state unavailable'

  # Seed a prior pane state so the first poll enters the confirmation path. Before
  # the fix every later changed footer emitted another stale wake.
  printf 'old-pane-state' > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf 'idle external-decision gate token-0 elapsed-0\n' > "$capture_file"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_TMUX_CURRENT_COMMAND=grok SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "initial live paused confirmation did not surface"
  round=1
  while [ "$round" -le 5 ]; do
    printf 'idle external-decision gate token-%s elapsed-%s\n' "$round" "$round" > "$capture_file"
    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
      SQUAD_FAKE_TMUX_CURRENT_COMMAND=grok SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
      SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 \
      "$WATCH" >> "$out" &
    pid=$!
    if wait_live "$pid" 20; then reap "$pid"; else wait "$pid" || true; fi
    round=$((round + 1))
  done
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf '0')
  [ "$wakes" -eq 1 ] || fail "live paused churning pane emitted $wakes stale wakes across five polls"
  unset SQUAD_FAKE_CREW_STATE
  pass "a live declared pause with a churning pane is surfaced once per cadence, not once per poll"
}

# Regression (2026-10-05 field report, "Spinner vence pausa" in data/learnings.md):
# a merely busy PANE (a foreground long poll's spinner, source: pane) must not
# win over a declared pause the way a genuinely active drill run-step
# (source: run-step) legitimately does. Before the fix, pause_state_class
# trusted operator_absorb_class's merged working verdict and returned
# "working" for a busy pane exactly as it would for a real run-step, so the
# wedge timer started and kept re-escalating "possible wedge" every poll
# instead of ever reaching the long pause cadence.
test_paused_busy_pane_without_run_step_does_not_override_pause() {
  local dir state fakebin out capture_file statusf window key sig pid round wakes
  dir=$(make_case paused-busy-pane-no-run-step); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:sq-held"
  printf 'window=%s\nkind=strike\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # The agent is alive (a verified harness process, not a bare shell) and its
  # authoritative state is "working" from a busy PANE only - no active
  # run-step - which is exactly the foreground-long-poll shape from the field
  # report.
  export SQUAD_FAKE_CREW_STATE='state: working · source: pane · still rendering output'

  printf 'idle external-decision gate token-0 elapsed-0\n' > "$capture_file"
  printf 'old-pane-state' > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_TMUX_CURRENT_COMMAND=grok SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a declared pause with only a busy pane did not surface its first bounded recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a busy pane alone (no run-step) was mislabeled a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "a busy pane alone (no run-step) started the wedge timer"

  # Five more polls with a churning pane (changing footer text, same shape as
  # the real spinner) must stay on the long pause cadence: no wedge timer ever
  # appears, and the stale queue never grows past the single first-sight entry.
  round=1
  while [ "$round" -le 5 ]; do
    printf 'idle external-decision gate token-%s elapsed-%s\n' "$round" "$round" > "$capture_file"
    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
      SQUAD_FAKE_TMUX_CURRENT_COMMAND=grok SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
      SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 \
      "$WATCH" >> "$out" &
    pid=$!
    if wait_live "$pid" 20; then reap "$pid"; else wait "$pid" || true; fi
    [ ! -e "$state/.stale-since-$key" ] || fail "round $round: a busy pane alone (no run-step) started the wedge timer"
    round=$((round + 1))
  done
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf '0')
  [ "$wakes" -eq 1 ] || fail "a declared pause with only a busy pane emitted $wakes stale wakes instead of one bounded recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a busy pane alone (no run-step) eventually escalated a possible wedge"
  unset SQUAD_FAKE_CREW_STATE
  pass "a declared pause outranks a merely busy pane with no genuine run-step: the long pause cadence applies, never a wedge"
}

# A foreground long poll can change its footer on every capture, so a live
# declared pause must surface its first recheck without waiting for a stable
# pane hash. Later changing hashes must retain the same long pause cadence.
test_paused_busy_churning_pane_surfaces_first_recheck() {
  local record dir state fakebin out window key statusf sig pid wakes case_id=0
  for record in 'paused: waiting on an external decision' 'commander-held [key=route]: waiting on an external decision'; do
    case_id=$((case_id + 1))
    dir=$(make_case "paused-busy-churning-$case_id"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; window="test:sq-held"; statusf="$state/held.status"
    printf 'window=%s\nkind=strike\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
    printf '%s\n' "$record" > "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    mv "$fakebin/tmux" "$fakebin/tmux-original"
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ]; then
  counter="$(dirname "$0")/captures"
  n=$(cat "$counter" 2>/dev/null || printf '0')
  n=$((n + 1))
  printf '%s\n' "$n" > "$counter"
  printf 'external-decision gate elapsed-%s\n' "$n"
  exit 0
fi
exec "$(dirname "$0")/tmux-original" "$@"
SH
    chmod +x "$fakebin/tmux"

    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CURRENT_COMMAND=grok \
      SQUAD_FAKE_CREW_STATE='state: working · source: pane · foreground long poll' \
      SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
      SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
      SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    if ! wait_for_exit "$pid" 40; then
      reap "$pid"; fail "$record: a continually changing busy pane never surfaced its first pause recheck"
    fi
    grep -F "stale: $window" "$out" >/dev/null || fail "first pause recheck did not name its window"
    grep -F 'possible wedge' "$out" >/dev/null && fail "first pause recheck was mislabeled a wedge"

    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CURRENT_COMMAND=grok \
      SQUAD_FAKE_CREW_STATE='state: working · source: pane · foreground long poll' \
      SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
      SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
      SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if ! wait_live "$pid" 30; then
      reap "$pid"; fail "$record: changing busy pane did not retain the long pause cadence"
    fi
    reap "$pid"
    [ "$(cat "$fakebin/captures")" -ge 3 ] || fail "$record: fixture did not exercise repeated changing captures"
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue")
    [ "$wakes" -eq 1 ] || fail "$record: changing busy pane emitted $wakes rechecks instead of one"
    [ ! -e "$state/.stale-since-$key" ] || fail "$record: changing busy pane started a wedge timer"
    [ ! -e "$state/.wedge-escalations-$key" ] || fail "$record: changing busy pane escalated a wedge"
  done
  pass "live declared pauses and commander holds on changing busy panes surface once, then retain the long cadence"
}

# A continuously changing busy pane must not absorb every later poll forever: once
# the first recheck has surfaced, later changing polls belong to the bounded pause
# cadence, so a second recheck still lands when PAUSE_RESURFACE_SECS elapses.
# Before the fix the new route re-entered the nonterminal absorb path on every
# poll, refreshed its throttle marker each time, and never reached the long
# cadence again.
test_paused_busy_churning_pane_rearms_long_cadence() {
  local record dir state fakebin out window key statusf sig pid wakes before after case_id=0
  for record in 'paused: waiting on an external decision' 'commander-held [key=route]: waiting on an external decision'; do
    case_id=$((case_id + 1))
    dir=$(make_case "paused-busy-rearm-$case_id"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; window="test:sq-held"; statusf="$state/held.status"
    printf 'window=%s\nkind=strike\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
    printf '%s\n' "$record" > "$statusf"
    # Backdate the declaration so only the pause cadence window, not the status
    # age, decides when the second recheck is due.
    set_mtime $(( $(date +%s) - 500 )) "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    mv "$fakebin/tmux" "$fakebin/tmux-original"
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ]; then
  counter="$(dirname "$0")/captures"
  n=$(cat "$counter" 2>/dev/null || printf '0')
  n=$((n + 1))
  printf '%s\n' "$n" > "$counter"
  printf 'external-decision gate elapsed-%s\n' "$n"
  exit 0
fi
exec "$(dirname "$0")/tmux-original" "$@"
SH
    chmod +x "$fakebin/tmux"

    # Phase A: the first bounded recheck surfaces for the changed pane.
    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CURRENT_COMMAND=grok \
      SQUAD_FAKE_CREW_STATE='state: working · source: pane · foreground long poll' \
      SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
      SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
      SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    if ! wait_for_exit "$pid" 100; then
      reap "$pid"; fail "$record: the first changed-pane pause recheck never surfaced"
    fi
    grep -F "stale: $window" "$out" >/dev/null || fail "$record: first pause recheck did not name its window"
    grep -F 'possible wedge' "$out" >/dev/null && fail "$record: first pause recheck was mislabeled a wedge"
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue")
    [ "$wakes" -eq 1 ] || fail "$record: expected exactly one first recheck, got $wakes"
    before=$(cat "$fakebin/captures")

    # Phase B: keep the pane changing every poll and confirm the bounded cadence
    # re-arms rather than absorbing the churn indefinitely.
    : > "$out"
    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CURRENT_COMMAND=grok \
      SQUAD_FAKE_CREW_STATE='state: working · source: pane · foreground long poll' \
      SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
      SQUAD_PAUSE_RESURFACE_SECS=2 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
      SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    if ! wait_for_exit "$pid" 150; then
      reap "$pid"; fail "$record: a continually changing busy pane never re-armed the pause cadence after the first recheck"
    fi
    after=$(cat "$fakebin/captures")
    [ "$after" -gt "$before" ] || fail "$record: fixture did not keep changing the pane during the cadence window"
    grep -F 'awaiting external' "$out" >/dev/null || fail "$record: the second recheck was not a paused/awaiting-external recheck"
    grep -F 'rechecked on a long cadence' "$out" >/dev/null || fail "$record: the second recheck did not use the long pause cadence: $(cat "$out")"
    grep -F 'possible wedge' "$out" >/dev/null && fail "$record: the second pause recheck was mislabeled a wedge"
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue")
    [ "$wakes" -eq 2 ] || fail "$record: changing busy pane emitted $wakes rechecks across the cadence window instead of two"
    [ ! -e "$state/.stale-since-$key" ] || fail "$record: the pause cadence recheck started a wedge timer"
    [ ! -e "$state/.wedge-escalations-$key" ] || fail "$record: the pause cadence recheck escalated a wedge"
  done
  pass "a continually changing busy pane under a live declared pause re-arms the long pause cadence after its first recheck"
}

# Companion to the regression above: with NO declared pause at all, a busy
# pane (source: pane, same as a foreground long poll) must still escalate
# exactly as it does today once it crosses the wedge threshold - the fix must
# never silence a genuine wedge on an operator that never declared a pause.
test_busy_pane_without_declared_pause_still_escalates() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case busy-pane-no-pause-escalates); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:sq-busy-pane"
  printf 'idle rendering output' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/busy.meta"
  printf 'working: still going\n' > "$state/busy.status"
  sig=$(seen_sig "$state/busy.status"); printf '%s' "$sig" > "$state/.seen-busy_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle rendering output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export SQUAD_FAKE_CREW_STATE='state: working · source: pane · still rendering output'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited for a fresh busy-pane non-terminal stale with no declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh busy-pane stale printed a wake reason during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"

  # Phase B: backdate the idle timer past the threshold; the next run escalates.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not escalate a busy-pane non-terminal stale past the threshold with no declared pause"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  unset SQUAD_FAKE_CREW_STATE
  pass "with no declared pause, a busy pane still escalates past the wedge threshold exactly as before"
}

# Regression: the static-busy wedge path must honor a declared pause too.
# window_is_busy is true there, so before the fix the sentry took the busy
# branch without ever consulting the paused: last status line and wedge-
# escalated instead of applying the long pause cadence. This drives a real
# busy pane (record_pi_busy) with a pre-aged turn marker through both pane-
# hash shapes and then asserts the pause cadence is stable across polls.
test_paused_busy_pane_with_static_output_does_not_wedge() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid round wakes back
  dir=$(make_case paused-static-busy); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/paused-busy-age.status"
  window="test:sq-paused-busy-age"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/paused-busy-age.meta"
  record_pi_busy "$state" paused-busy-age
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-paused-busy-age_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'Working...' > "$capture_file"
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No completed turn ever recorded for this task: age the spawn record.
  touch -t 200001010000 "$state/paused-busy-age.meta"

  # Stable hash (h == prev): a declared pause must not start the wedge timer.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_STALE_ESCALATE_SECS=999 SQUAD_PAUSE_RESURFACE_SECS=999 \
    SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_live "$pid" 30 || { reap "$pid"; fail "declared pause + busy pane with static output exited: $(cat "$out")"; }
  [ ! -e "$state/.stale-since-$key" ] || fail "declared pause did not outrank a busy pane with static output (wedge timer started)"
  [ -e "$state/.paused-$key" ] || fail "declared pause was not retained on the stable-hash static-busy path"
  grep -F "possible wedge" "$out" >/dev/null && fail "declared pause + busy pane with static output wedge-escalated"
  reap "$pid"

  # Changing hash (h != prev): same precedence, the branch the field spinner hits.
  rm -f "$state/.hash-$key" "$state/.count-$key"
  printf 'Working... (3601.2s)' > "$capture_file"
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_STALE_ESCALATE_SECS=999 SQUAD_PAUSE_RESURFACE_SECS=999 \
    SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_live "$pid" 30 || { reap "$pid"; fail "declared pause + changed busy pane with static output exited: $(cat "$out")"; }
  [ ! -e "$state/.stale-since-$key" ] || fail "declared pause did not outrank a changed busy pane with static output (wedge timer started)"
  [ -e "$state/.paused-$key" ] || fail "declared pause was not retained on the changing-hash static-busy path"
  grep -F "possible wedge" "$out" >/dev/null && fail "declared pause + changed busy pane with static output wedge-escalated"
  reap "$pid"

  # Long cadence: with the pause marker preserved, repeated polls surface at most
  # one bounded recheck rather than a pause wake every poll.
  back=$(( $(date +%s) - 500 ))
  set_mtime "$back" "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-paused-busy-age_status"
  rm -f "$state/.paused-resurfaced-$key"
  : > "$out"
  round=1
  while [ "$round" -le 4 ]; do
    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
      SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
      SQUAD_STALE_ESCALATE_SECS=999 SQUAD_PAUSE_RESURFACE_SECS=60 \
      SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_live "$pid" 20; then reap "$pid"; else wait "$pid" 2>/dev/null || true; fi
    round=$((round + 1))
  done
  wakes=$(grep -c "awaiting external" "$out" || true)
  [ "$wakes" -le 1 ] || fail "declared pause + busy pane re-surfaced $wakes times across polls instead of one bounded recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "declared pause + busy pane wedge-escalated during the cadence loop"
  pass "a declared pause outranks a provably busy pane with static output and keeps the long pause cadence"
}

# Companion to the static-busy precedence test: with NO declared pause the
# same provably busy, static-output pane must still walk the wedge timer and
# escalate - the fix must not silence a genuine wedge baked into the busy path.
test_busy_pane_static_without_pause_still_wedges() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case static-busy-no-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-no-pause"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-no-pause.meta"
  record_pi_busy "$state" busy-no-pause
  printf 'working: setup complete\n' > "$state/busy-no-pause.status"
  sig=$(seen_sig "$state/busy-no-pause.status"); printf '%s' "$sig" > "$state/.seen-busy-no-pause_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'Working...' > "$capture_file"
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  touch -t 200001010000 "$state/busy-no-pause.meta"

  # Phase A: the static busy pane starts the wedge timer without escalating.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a no-pause busy pane with static output escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a no-pause busy pane with static output did not start the wedge timer"
  reap "$pid"

  # Phase B: backdate the timer and the next poll must escalate.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a no-pause busy pane with static output did not wedge-escalate"
  grep -F "stale: $window" "$out" >/dev/null || fail "no-pause static busy escalation did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "no-pause static busy escalation did not flag a possible wedge"
  pass "with no declared pause, a busy pane with static output still wedge-escalates"
}

# Regression: surface_nonterminal_stale must refresh the resurfaced throttle
# marker in its absorb path so a changing pane footer cannot age it past
# PAUSE_RESURFACE_SECS between polls. Exercises the decision directly by
# calling surface_nonterminal_stale via subshells (it calls wake/exit) with
# a fresh vs stale marker.
test_paused_churning_pane_throttle_refreshes_marker() {
  local dir state window key h shell_libs
  dir=$(make_case paused-throttle-unit); state="$dir/state"
  window="test:sq-held"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/held.meta"
  printf 'paused: waiting at external gate\n' > "$state/held.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  h="abc123"
  # shell_libs sources every library surface_nonterminal_stale needs, including
  # the sentry source guard that loads the function without entering the loop.
  shell_libs=". $ROOT/bin/sq-push-transition-lib.sh; . $ROOT/bin/sq-pr-lib.sh; . $ROOT/bin/sq-x-lib.sh; . $ROOT/bin/sq-check-lib.sh; . $ROOT/bin/sq-pending-reply-lib.sh; . $ROOT/bin/sq-busy-lib.sh; . $ROOT/bin/sq-stall-detect.sh; . $ROOT/bin/sq-sentry.sh 2>/dev/null"
  sub() { bash -c "export SQUAD_STATE_OVERRIDE='$state'; export SQUAD_PAUSE_RESURFACE_SECS=$1; $shell_libs; surface_nonterminal_stale '$window' '$h'" 2>/dev/null; }

  # Phase A: fresh marker - absorb path must run and refresh the marker.
  date +%s > "$state/.paused-resurfaced-$key"
  local mtime_a
  mtime_a=$(file_mtime "$state/.paused-resurfaced-$key")
  sub 999
  [ ! -s "$state/.stand-to-queue" ] || fail "fresh marker: absorb path surfaced instead of absorbing"
  local mtime_a2
  mtime_a2=$(file_mtime "$state/.paused-resurfaced-$key")
  [ "${mtime_a2:-0}" -ge "${mtime_a:-0}" ] || fail "fresh marker: absorb path did not refresh the resurfaced marker"

  # Phase B: stale marker - surfacing must happen and refresh the marker.
  set_mtime $(( $(date +%s) - 500 )) "$state/.paused-resurfaced-$key"
  printf '%s' "$(seen_sig "$state/held.status")" > "$state/.seen-held_status"
  local mtime_b
  mtime_b=$(file_mtime "$state/.paused-resurfaced-$key")
  sub 240
  local wakes_b
  wakes_b=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf '0')
  [ "$wakes_b" -ge 1 ] || fail "stale marker: surfacing path did not enqueue a wake"
  local mtime_b2
  mtime_b2=$(file_mtime "$state/.paused-resurfaced-$key")
  [ "${mtime_b2:-0}" -ge "${mtime_b:-0}" ] || fail "stale marker: surfacing path did not refresh the resurfaced marker"

  # Phase C: age the marker to 300s (older than PAUSE_RESURFACE_SECS=240) so
  # the absorb path would surface instead of absorb if it weren't for the
  # throttle check. Then call surface_nonterminal_stale - the marker is old
  # enough to trigger surfacing. This also refreshes the marker.
  set_mtime $(( $(date +%s) - 300 )) "$state/.paused-resurfaced-$key"
  sub 240
  local wakes_total
  wakes_total=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf '0')
  [ "$wakes_total" -ge 2 ] || fail "aged marker: expected >=2 wakes total after re-surfacing, got $wakes_total"

  # Phase D: age the marker to 200s (fresh enough for absorb, since 200 < 240).
  # The absorb path should run and refresh the marker. Without the fix, the
  # marker would stay at 200s old; with the fix, it gets refreshed to ~now.
  set_mtime $(( $(date +%s) - 200 )) "$state/.paused-resurfaced-$key"
  sub 240
  # Should still be exactly 2 wakes - absorb ran, refreshed marker, did NOT surface.
  wakes_total=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf '0')
  [ "$wakes_total" -eq 2 ] || fail "re-absorb: emitted $wakes_total wakes total after re-absorb (expected 2)"

  # Phase E: verify the marker was refreshed in Phase D.
  local mtime_d now_d
  mtime_d=$(file_mtime "$state/.paused-resurfaced-$key")
  now_d=$(date +%s)
  [ "$(( now_d - mtime_d ))" -lt 10 ] || fail "re-absorb: marker mtime is $(( now_d - mtime_d ))s old (should be <10s after refresh)"

  pass "surface_nonterminal_stale absorb path refreshes throttle marker; stale marker surfaces; re-absorb works"
}

# --- TUIOS native blocked-pane wake, through the backend-neutral transition --
# producer (bin/sq-transition-lib.sh) on the sentry's ordinary poll loop. A
# pane whose backend reports a person is needed must wake Squad, naming the
# task and the prompt the daemon read (including numbered options when
# present), exactly once per distinct pending prompt, and must never be folded
# into the ordinary stale/wedge machinery. docs/tuios-backend.md and
# sq-sentry.sh's own header comment own this contract.

test_tuios_blocked_pane_wakes_via_poll_transition() {
  local dir state fakebin out drain_out window key pid
  dir=$(make_case tuios-blocked-wake); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  install_fake_tuios "$fakebin"
  window="tsess:w1"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'window=%s\nkind=strike\nbackend=tuios\n' "$window" > "$state/blocked.meta"
  printf 'working: starting up\n' > "$state/blocked.status"
  # Mark the pre-existing status as already seen so the signal scan does not
  # fire first: this test exercises the native blocked poll, not the signal
  # path, and must not depend on an earlier suite test having absorbed a
  # leaked crew-state verdict.
  printf '%s' "$(seen_sig "$state/blocked.status")" > "$state/.seen-blocked_status"
  export SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-blocked

  # SQUAD_BASE is pinned to this case's own scratch dir (not just
  # SQUAD_STATE_OVERRIDE) so nothing in the chain - fm_wake_append's queue
  # path, sq-guard.sh's home resolution - can fall back to this operator
  # shell's ambient SQUAD_BASE and leak a fixture wake into the real base.
  SQUAD_BASE="$dir" SQUAD_TUIOS_FAKE_PROMPT_BLOCKED=1 SQUAD_TUIOS_FAKE_AGENT_STATE=needs_input SQUAD_TUIOS_FAKE_BLOCKED_BY=approval \
    SQUAD_TUIOS_FAKE_PROMPT_KIND=approval SQUAD_TUIOS_FAKE_PROMPT_MESSAGE='trust this directory?' \
    SQUAD_TUIOS_FAKE_PROMPT_OPTIONS='["Yes","No"]' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not exit for a native TUIOS blocked prompt"
  grep -Fx "stale: $window (tuios: agent blocked - approval: trust this directory? [1) Yes 2) No] prompt_id=p1 - waiting on human, escalated immediately, not via wedge timer)" "$out" >/dev/null \
    || fail "blocked wake did not carry the backend-generic wording, prompt summary, numbered options, and the exact prompt id: $(cat "$out")"

  [ ! -e "$state/.hash-$key" ] || fail "a blocked pane must never start the ordinary stale hash tracking"
  [ ! -e "$state/.count-$key" ] || fail "a blocked pane must never advance the ordinary stale counter"
  [ ! -e "$state/.stale-$key" ] || fail "a blocked pane must never be recorded as a possible wedge"
  [ -e "$state/.tuios-escalated-$key" ] || fail "the TUIOS producer's own dedupe marker was not committed"

  SQUAD_BASE="$dir" SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the blocked wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" | grep -F 'trust this directory?' >/dev/null \
    || fail "the blocked wake was not queued with its window and prompt: $(cat "$drain_out")"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F 'prompt_id=p1' >/dev/null \
    || fail "the queued blocked wake did not carry the exact prompt id the answer must name: $(cat "$drain_out")"
  unset SQUAD_TUIOS_FAKE_WINDOW_NAME
  pass "a native TUIOS blocked prompt wakes once through the shared transition producer, naming its prompt and numbered options, without touching stale bookkeeping"
}

test_tuios_blocked_pane_dedupes_then_rearms_on_change_or_unblock() {
  local dir state fakebin out window key pid wakes
  dir=$(make_case tuios-blocked-dedupe); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  install_fake_tuios "$fakebin"
  window="tsess:w1"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'window=%s\nkind=strike\nbackend=tuios\n' "$window" > "$state/dedupe.meta"
  printf 'working: starting up\n' > "$state/dedupe.status"
  # Mark the pre-existing status as already seen (see the sibling test above).
  printf '%s' "$(seen_sig "$state/dedupe.status")" > "$state/.seen-dedupe_status"
  export SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-dedupe

  # SQUAD_BASE is pinned to this case's own scratch dir on every launch below
  # (see the sibling test above for why), never just SQUAD_STATE_OVERRIDE.

  # Phase 1: first sighting of the prompt wakes and records the dedup marker.
  SQUAD_BASE="$dir" SQUAD_TUIOS_FAKE_PROMPT_BLOCKED=1 SQUAD_TUIOS_FAKE_AGENT_STATE=needs_input \
    SQUAD_TUIOS_FAKE_PROMPT_MESSAGE='trust this directory?' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "first sighting of a blocked prompt did not wake"
  [ -e "$state/.tuios-escalated-$key" ] || fail "the dedup marker was not recorded after the first wake"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf 0)
  [ "$wakes" -eq 1 ] || fail "expected exactly 1 queued wake after phase 1, got $wakes"

  # Phase 2: the SAME standing prompt must not wake again on a fresh sentry
  # invocation (the normal production restart-per-wake shape).
  : > "$out"
  SQUAD_BASE="$dir" SQUAD_TUIOS_FAKE_PROMPT_BLOCKED=1 SQUAD_TUIOS_FAKE_AGENT_STATE=needs_input \
    SQUAD_TUIOS_FAKE_PROMPT_MESSAGE='trust this directory?' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 20; then
    reap "$pid"; fail "an unchanged standing prompt re-woke Squad: $(cat "$out")"
  fi
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf 0)
  [ "$wakes" -eq 1 ] || fail "an unchanged prompt added a duplicate queued wake (now $wakes)"

  # Phase 3: a changed prompt text wakes again, with no intervening non-blocked
  # edge - the prompt's own content, not just the status, drives the dedupe.
  : > "$out"
  SQUAD_BASE="$dir" SQUAD_TUIOS_FAKE_PROMPT_BLOCKED=1 SQUAD_TUIOS_FAKE_AGENT_STATE=needs_input \
    SQUAD_TUIOS_FAKE_PROMPT_MESSAGE='allow network access?' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "a changed prompt did not wake again"
  grep -F 'allow network access?' "$out" >/dev/null || fail "the changed-prompt wake did not name the new prompt: $(cat "$out")"

  # Phase 4: the pane becomes unblocked - the dedup marker must clear.
  : > "$out"
  SQUAD_BASE="$dir" SQUAD_TUIOS_FAKE_PROMPT_BLOCKED=0 SQUAD_TUIOS_FAKE_AGENT_STATE=working \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 20; then
    reap "$pid"; fail "an ordinary busy pane unexpectedly exited: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -e "$state/.tuios-escalated-$key" ] || fail "unblocking did not clear the dedup marker"

  # Phase 5: the identical original prompt text re-arms and wakes again, since
  # unblocking cleared the marker - "unrelated activity never re-arms it" cuts
  # the other way too: only a genuine transition through unblocked does.
  : > "$out"
  SQUAD_BASE="$dir" SQUAD_TUIOS_FAKE_PROMPT_BLOCKED=1 SQUAD_TUIOS_FAKE_AGENT_STATE=needs_input \
    SQUAD_TUIOS_FAKE_PROMPT_MESSAGE='trust this directory?' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "a byte-identical prompt did not re-wake after an intervening unblock"
  grep -F 'trust this directory?' "$out" >/dev/null || fail "the re-armed wake did not name the prompt: $(cat "$out")"

  unset SQUAD_TUIOS_FAKE_WINDOW_NAME
  pass "a TUIOS blocked prompt wakes once per distinct prompt, rewakes on a change, and rearms after unblocking"
}

test_tuios_ambiguous_read_after_escalation_skips_stale() {
  local dir state fakebin out window key pid wakes
  dir=$(make_case tuios-ambiguous-skip-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  install_fake_tuios "$fakebin"
  window="tsess:w1"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'window=%s\nkind=strike\nbackend=tuios\n' "$window" > "$state/ambiguous.meta"
  printf 'working: starting up\n' > "$state/ambiguous.status"
  # Mark the pre-existing status as already seen (see the sibling test above).
  printf '%s' "$(seen_sig "$state/ambiguous.status")" > "$state/.seen-ambiguous_status"
  export SQUAD_TUIOS_FAKE_WINDOW_NAME=sq-ambiguous

  # Phase 1: a real blocked read wakes once and commits the escalation marker.
  SQUAD_BASE="$dir" SQUAD_TUIOS_FAKE_PROMPT_BLOCKED=1 SQUAD_TUIOS_FAKE_AGENT_STATE=needs_input \
    SQUAD_TUIOS_FAKE_PROMPT_MESSAGE='trust this directory?' \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "the blocked prompt did not wake"
  [ -e "$state/.tuios-escalated-$key" ] || fail "the escalation marker was not committed"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf 0)
  [ "$wakes" -eq 1 ] || fail "expected exactly 1 wake after the blocked read, got $wakes"

  # Phase 2: the native inventory read now fails for the still-escalated pane.
  # The sentry must stay live (skip stale) and must not start stale bookkeeping.
  : > "$out"
  SQUAD_BASE="$dir" SQUAD_TUIOS_FAKE_LIST_FAIL=1 \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 20; then
    reap "$pid"; fail "an ambiguous read over a still-escalated blocked pane produced a stale wake: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -e "$state/.hash-$key" ] || fail "an ambiguous read over a blocked pane started stale hash tracking"
  [ ! -e "$state/.count-$key" ] || fail "an ambiguous read over a blocked pane advanced the stale counter"
  [ ! -e "$state/.stale-$key" ] || fail "an ambiguous read over a blocked pane recorded it as a possible wedge"
  [ -e "$state/.tuios-escalated-$key" ] || fail "an ambiguous read cleared the escalation marker"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf 0)
  [ "$wakes" -eq 1 ] || fail "an ambiguous read over a blocked pane added a duplicate wake (now $wakes)"
  unset SQUAD_TUIOS_FAKE_WINDOW_NAME
  pass "an ambiguous native read after escalation skips the stale/wedge path instead of reclassifying a blocked pane"
}

test_orca_blocked_prompt_wakes_exact_terminal_then_dedupes() {
  local dir state fakebin out drain_out terminal key pid wakes blocked i
  dir=$(make_case orca-blocked-wake); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  install_fake_orca "$fakebin"
  terminal="term-oki"
  key=$terminal
  printf 'window=sq-orca-task\nterminal=%s\nkind=strike\nbackend=orca\n' "$terminal" > "$state/orca-task.meta"
  printf 'working: starting up\n' > "$state/orca-task.status"
  printf '%s' "$(seen_sig "$state/orca-task.status")" > "$state/.seen-orca-task_status"
  blocked='{"kind":"permission","message":"Allow this directory?"}'

  # Phase 1: the shared consumer must name the EXACT terminal - Orca's target is
  # the terminal id, not a "<session>:<pane>" window - and carry the prompt.
  SQUAD_BASE="$dir" SQUAD_FAKE_ORCA_AGENT_WAIT="$blocked" \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not exit for a native Orca blocked prompt"
  grep -Fx "stale: $terminal (orca: agent blocked - Allow this directory? - waiting on human, escalated immediately, not via wedge timer)" "$out" >/dev/null \
    || fail "the Orca blocked wake did not name the exact terminal and prompt: $(cat "$out")"
  [ -e "$state/.orca-escalated-$key" ] || fail "the Orca producer's dedupe marker was not committed"
  [ -e "$state/.orca-prompt-$key" ] || fail "the Orca producer's prompt identity marker was not written"
  [ ! -e "$state/.hash-$key" ] || fail "a blocked Orca terminal must never start ordinary stale hash tracking"
  [ ! -e "$state/.stale-$key" ] || fail "a blocked Orca terminal must never be recorded as a possible wedge"
  wakes=$(awk -F '\t' -v w="$terminal" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf 0)
  [ "$wakes" -eq 1 ] || fail "expected exactly 1 queued wake after the blocked read, got $wakes"
  SQUAD_BASE="$dir" SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the blocked wake failed"
  wakes=$(awk -F '\t' -v w="$terminal" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf 0)
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$terminal" | grep -F 'Allow this directory?' >/dev/null \
    || fail "the blocked wake was not queued against the exact terminal: $(cat "$drain_out")"
  grep -F "$terminal:$terminal" "$drain_out" >/dev/null && fail "the Orca wake invented a session:pane window instead of the exact terminal"

  # Phase 2: the same standing prompt must not wake again.
  : > "$out"
  SQUAD_BASE="$dir" SQUAD_FAKE_ORCA_AGENT_WAIT="$blocked" \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 20; then
    reap "$pid"; fail "an unchanged Orca prompt re-woke Squad: $(cat "$out")"
  fi
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$terminal" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf 0)
  [ "$wakes" -eq 0 ] || fail "an unchanged Orca prompt added a duplicate queued wake (now $wakes)"

  # Phase 3: an unreadable observation after escalation is ambiguous, so the
  # still-blocked terminal must skip the stale/wedge machinery entirely.
  : > "$out"
  SQUAD_BASE="$dir" SQUAD_FAKE_ORCA_SHOW_FAIL=1 \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 20; then
    reap "$pid"; fail "an ambiguous Orca read over a still-escalated prompt woke Squad: $(cat "$out")"
  fi
  reap "$pid"
  [ -e "$state/.orca-escalated-$key" ] || fail "an ambiguous Orca read cleared the escalation marker"
  [ ! -e "$state/.hash-$key" ] || fail "an ambiguous Orca read started ordinary stale hash tracking"
  wakes=$(awk -F '\t' -v w="$terminal" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue" 2>/dev/null || printf 0)
  [ "$wakes" -eq 0 ] || fail "an ambiguous Orca read added a duplicate queued wake (now $wakes)"

  # Phase 4: a positively-read clear record clears both dedupe markers and hands
  # the terminal back to ordinary supervision.
  : > "$out"
  SQUAD_BASE="$dir" SQUAD_FAKE_ORCA_AGENT_WAIT=null \
    watch_bg "$state" "$fakebin" "$out"
  pid=$!
  i=0
  while [ -e "$state/.orca-escalated-$key" ] && [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
  reap "$pid"
  [ ! -e "$state/.orca-escalated-$key" ] || fail "a clear Orca record did not clear the escalation marker"
  [ ! -e "$state/.orca-prompt-$key" ] || fail "a clear Orca record did not clear the prompt identity marker"
  pass "an Orca blocked prompt wakes once against the exact terminal, dedupes, survives an ambiguous read, and clears on unblock"
}

test_tmux_pane_with_prompt_like_text_never_fakes_a_blocked_wake() {
  local dir state fakebin out capture_file window pid
  dir=$(make_case tmux-no-native-blocked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:sq-prompty"
  # tmux has no native blocked verdict and no poll-transition producer
  # (fm_backend_can_poll_transition tmux is false), so pane text that merely
  # LOOKS like a dialog must never be guessed into a blocked wake.
  printf 'Do you want to proceed?\n1) Yes\n2) No\n' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/prompty.meta"
  printf 'working: starting up\n' > "$state/prompty.status"
  # Mark the pre-existing status as already seen so the only wake candidate is
  # the prompt-like pane text, which must never be guessed into a blocked wake.
  printf '%s' "$(seen_sig "$state/prompty.status")" > "$state/.seen-prompty_status"

  # The pane's crew is genuinely working (the prompt-like text is only rendered
  # output), so the ordinary stale machinery absorbs it; only a guessed blocked
  # escalation would produce a wake. Pin the crew verdict explicitly so the test
  # does not depend on a leaked SQUAD_FAKE_CREW_STATE from an earlier case.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    SQUAD_BASE="$dir" SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" \
    SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 20; then
    reap "$pid"; fail "a tmux pane with prompt-like text produced a wake on no native verdict: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "tmux silently guessed a blocked wake from pane text: $(cat "$out")"
  reap "$pid"
  pass "a backend with no poll-transition producer (tmux) never guesses blocked from pane text"
}

# A commander-held crew can leave a stable backend endpoint after its agent exits.
# sq-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or commander-held transfer must retain
# bounded pause handling.
# A still-live agent at an external-decision gate is the disconfirming case: it
# must surface once, while the unchanged hash must not append the same wake on
# every sentry re-arm.
test_exited_declared_pause_is_bounded_but_live_gate_surfaces() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:sq-held"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: held per commander while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  round=1
  while [ "$round" -le 6 ]; do
    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
      SQUAD_FAKE_TMUX_CURRENT_COMMAND=zsh SQUAD_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_PAUSE_RESURFACE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
      SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_live "$pid" 15; then reap "$pid"; else wait "$pid" || fail "dead-agent sentry round $round failed"; fi
    round=$((round + 1))
  done
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.stand-to-queue")
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.stand-to-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-commander-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:sq-held"
  printf 'idle bare shell after commander-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'commander-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after commander-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_TMUX_CURRENT_COMMAND=zsh SQUAD_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_PAUSE_RESURFACE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "commander-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting external" "$state/.stand-to-queue" >/dev/null \
    || fail "commander-held dead-agent pane surfaced as a stopped crew"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:sq-gate"
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight must surface promptly so a live external-decision gate is not
  # hidden behind the pause cadence.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_TMUX_CURRENT_COMMAND=grok SQUAD_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "live external-decision gate did not surface immediately"

  # Re-arm with the stale timer already beyond the wedge threshold. This is the
  # exact unchanged-hash fallback after the immediate surface: it must retain
  # the pause cadence and discard any residual wedge timer instead of emitting
  # a second possible-wedge wake.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_TMUX_CURRENT_COMMAND=grok SQUAD_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"
    fail "live external-decision gate escalated on the wedge timer after its immediate surface: $(cat "$out")"
  fi
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live external-decision gate lost its pause cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live external-decision gate retained the wedge timer"; }
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.stand-to-queue")
  [ "$wakes" -eq 1 ] || fail "live external-decision gate should surface once, got $wakes wakes"
  [ "$bare" -eq 1 ] || fail "live external-decision gate lost its immediate bare stale surface"
  pass "exited declared-pause and commander-held panes use bounded pause cadence while a live decision gate still surfaces once"
}

test_XO_paused_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case XO-paused-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/XO-held.status"
  window="test:sq-xo-held"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=xo\n' "$window" > "$state/XO-held.meta"
  printf 'paused: awaiting the upstream release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-XO-held_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export SQUAD_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_PAUSE_RESURFACE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not re-surface a paused XO"
  grep -F "stale: $window" "$out" >/dev/null || fail "paused XO did not emit a stale recheck"
  grep -F "awaiting external" "$out" >/dev/null || fail "paused XO recheck omitted its external-wait reason"
  grep -F "possible wedge" "$out" >/dev/null && fail "paused XO was mislabeled a wedge"
  unset SQUAD_FAKE_CREW_STATE
  pass "a declared paused XO re-surfaces on the bounded normal-mode cadence"
}

test_XO_nonpaused_stale_remains_suppressed() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case XO-stale-suppressed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/XO-working.status"
  window="test:sq-xo-working"
  printf 'idle while the parent supervises\n' > "$capture_file"
  printf 'window=%s\nkind=xo\n' "$window" > "$state/XO-working.meta"
  printf 'working: the parent supervises this XO\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-XO-working_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle while the parent supervises")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry surfaced an ordinary XO stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "ordinary XO stale pane printed a wake reason: $(cat "$out")"; }
  reap "$pid"
  pass "a non-paused XO retains normal stale suppression"
}

test_XO_unpause_clears_pause_tracking() {
  local dir state fakebin out statusf window key pid
  dir=$(make_case XO-unpause-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; statusf="$state/XO-resumed.status"; window="test:sq-xo-resumed"
  printf 'window=%s\nkind=xo\n' "$window" > "$state/XO-resumed.meta"
  printf 'working: upstream landed\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-XO-resumed_status"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  : > "$state/.paused-$key"
  : > "$state/.paused-rechecked-$key"
  : > "$state/.paused-resurfaced-$key"
  : > "$state/.stale-$key"
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 20 || fail "sentry exited while reconciling a resumed XO: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "resumed XO retained the pause marker"; }
  [ ! -e "$state/.stale-$key" ] || { reap "$pid"; fail "resumed XO retained stale tracking"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "resumed XO retained wedge tracking"; }
  reap "$pid"
  pass "a resumed XO clears pause and stale tracking before stale exemption"
}

test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid i
  dir=$(make_case nonterminal-stale-pause-transition); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-transition"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/transition.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export SQUAD_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'

  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_TMUX_CURRENT_COMMAND=zsh \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_PAUSE_RESURFACE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash did not enter paused mode"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "pause transition retained its wedge timer"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  reap "$pid"

  printf 'working: upstream landed, resuming\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ ! -e "$state/.paused-$key" ] && [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash retained paused mode after resume"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "unchanged stale hash did not restart wedge tracking after resume"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  reap "$pid"
  unset SQUAD_FAKE_CREW_STATE
  pass "unchanged stale hashes reclassify when an operator enters or leaves pause"
}

test_nonterminal_paused_rechecks_authoritative_state() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an active run behind a declared pause surfaced instead of resuming wedge tracking: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "authoritative active run retained paused mode"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "authoritative active run did not resume wedge tracking"; }
  reap "$pid"
  unset SQUAD_FAKE_CREW_STATE
  pass "a declared pause is periodically rechecked against authoritative active-run state"
}

test_paused_authoritative_working_preserves_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case paused-working-preserves-wedge-timer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-paused-working"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/paused-working.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "authoritative working state did not start wedge tracking"; }
  since=$(cat "$state/.stale-since-$key")
  sleep 2
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || true)" = "$since" ] \
    || { reap "$pid"; fail "repeat authoritative working recheck reset the wedge timer"; }
  reap "$pid"

  # Phase B: the still-active run-step defers the wedge timer rather than
  # escalating it past the threshold; the pane stays silent and the idle clock restarts.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 50; then
    reap "$pid"; fail "authoritative working state escalated past the threshold instead of deferring: $(cat "$out")"
  fi
  reap "$pid"
  [ ! -s "$out" ] || fail "authoritative working state printed a wedge wake: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "authoritative working state counted a wedge escalation"
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  case "$since" in ''|*[!0-9]*) fail "wedge timer was lost while the run-step is active" ;; esac
  [ $(( $(date +%s) - since )) -lt 240 ] || fail "wedge timer was not restarted while the run-step is active"
  unset SQUAD_FAKE_CREW_STATE
  pass "a paused status overridden by authoritative working keeps its wedge timer and defers it while the run-step is active"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# SQUAD_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:sq-wedged"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"
  # The run-step has ended and the pane stays frozen: a genuine wedge with no
  # active step, so the escalation counter accumulates. (While a run-step is
  # active the timer defers instead; see test_wedge_timer_deferred_while_run_step_active.)
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · no active run'

  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B (the subsequent-sight timer
    # path does not re-read the operator state).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
      SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
      SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 40 || fail "sentry did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset SQUAD_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:sq-wedged-reset"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired.
  printf '1\n' > "$state/.wedge-escalations-$key"
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the operator is active again): the hash no longer
  # matches, so the sentry resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited on a fresh (changed) pane hash: $(cat "$out")"
  fi
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  reap "$pid"
  unset SQUAD_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter"
}

# Regression for the 2026-10-20 phantom-wedge incident: after a completed
# bin/sq-teardown.sh released its window, the sentry kept emitting
# "stale: <window> (idle Ns, possible wedge, escalation N)" every poll - reaching
# escalation 8 with demand-deep-inspection - for a task whose state/<id>.meta and
# status were already gone. A target whose task record is gone must be dropped
# from supervision with its wedge bookkeeping reset, so a teardown ends
# supervision instead of ageing into a repeating wedge alarm and a window id that
# later carries that key starts its own count. A live task's window must keep
# escalating exactly as before.
test_teardown_drops_target_and_wedge_counter() {
  local dir state fakebin out capture_file window key pane_hash sig pid live_window live_key i
  dir=$(make_case teardown-drops-target); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:sq-torn"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/torn.meta"
  printf 'working: still monitoring ci\n' > "$state/torn.status"
  sig=$(seen_sig "$state/torn.status"); printf '%s' "$sig" > "$state/.seen-torn_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: the first sighting of this stale hash absorbs it and starts the wedge timer.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited on the absorb round for a fresh stale (should absorb): $(cat "$out")"
  fi
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"

  # Phase B: past the threshold the idle pane escalates on a LIVE task record (escalation 1).
  # The run-step has ended and the pane is still frozen, so no active step defers it.
  export SQUAD_FAKE_CREW_STATE='state: unknown · source: none · no active run'
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not escalate a live task's stale window past the threshold: $(cat "$out")"
  grep -F "escalation 1" "$out" >/dev/null || fail "live task's escalation did not report count 1: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = "1" ] || fail "live task's escalation counter was not recorded"
  rm -f "$state/.stand-to-queue"

  # Teardown shape: the task metadata and status are gone while the window-keyed
  # bookkeeping survives (the release could not resolve the window it released).
  rm -f "$state/torn.meta" "$state/torn.status" "$state/.seen-torn_status"
  : > "$state/.step-quiet-checked-$key"
  : > "$state/.step-quiet-reported-$key"
  # Control: an unrelated LIVE task's window, mid-episode and past its threshold,
  # whose escalation round must be untouched by the drop.
  live_window="test:sq-live"
  printf 'window=%s\nkind=strike\n' "$live_window" > "$state/live.meta"
  printf 'working: still monitoring ci\n' > "$state/live.status"
  sig=$(seen_sig "$state/live.status"); printf '%s' "$sig" > "$state/.seen-live_status"
  live_key=$(printf '%s' "$live_window" | tr ':/.' '___')
  printf '%s' "$pane_hash" > "$state/.hash-$live_key"
  printf '1\n' > "$state/.count-$live_key"
  printf '%s' "$pane_hash" > "$state/.stale-$live_key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$live_key"
  printf '1\n' > "$state/.wedge-escalations-$live_key"

  # Phase C: the next scan drops the torn-down target's bookkeeping and still
  # escalates the live window normally in the same cycle.
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "sentry did not escalate the live control window after the teardown: $(cat "$out")"
  grep -F "stale: $live_window" "$out" >/dev/null || fail "the live control window stopped escalating after another task was torn down"
  grep -F "stale: $window" "$out" >/dev/null && fail "a torn-down target still escalated a wedge: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a torn-down target kept its wedge-escalation counter"
  [ ! -e "$state/.stale-since-$key" ] || fail "a torn-down target kept its wedge timer"
  [ ! -e "$state/.stale-$key" ] || fail "a torn-down target kept its stale suppressor"
  [ ! -e "$state/.hash-$key" ] || fail "a torn-down target kept its pane hash"
  [ ! -e "$state/.count-$key" ] || fail "a torn-down target kept its pane hash count"
  [ ! -e "$state/.step-quiet-checked-$key" ] || fail "a torn-down target kept its step observation marker"
  [ ! -e "$state/.step-quiet-reported-$key" ] || fail "a torn-down target kept its quiet-step episode"
  [ "$(cat "$state/.wedge-escalations-$live_key" 2>/dev/null || true)" = "2" ] || fail "the live control window's own escalation counter was reset by the drop"
  [ "$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.stand-to-queue")" = 0 ] \
    || fail "a torn-down target queued a stale wake"

  # Phase D: repeated later scans stay quiet for the released window.
  rm -f "$state/live.meta" "$state/live.status" "$state/.seen-live_status"
  i=0
  while [ "$i" -lt 3 ]; do
    : > "$out"
    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
      SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
      SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    if ! wait_live "$pid" 30; then
      reap "$pid"; fail "scan $i re-escalated a torn-down target: $(cat "$out")"
    fi
    reap "$pid"
    [ ! -s "$out" ] || fail "scan $i printed a wake for a torn-down target: $(cat "$out")"
    i=$((i + 1))
  done
  unset SQUAD_FAKE_CREW_STATE
  pass "a torn-down target is dropped with its wedge counter reset, and a live window keeps escalating"
}

# --- busy claims expire only when the rendered pane, including its usage
# gauge, stays static. Reuse the ordinary pane hash and wedge timer. ------------

test_busy_static_pane_escalates_without_turn_age() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-static-expiry); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-static"
  printf 'Working...\n12k tokens USD 0.42' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-static.meta"
  record_pi_busy "$state" busy-static
  printf 'working: setup complete\n' > "$state/busy-static.status"
  sig=$(seen_sig "$state/busy-static.status"); printf '%s' "$sig" > "$state/.seen-busy-static_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # A fresh completed turn must not give a frozen agent an hour of immunity.
  touch "$state/busy-static.turn-ended"
  prime_turnend_seen "$state/busy-static.turn-ended"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a static busy pane never expired: $(cat "$out")"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "static busy expiry did not print the stale wake"
  grep -F "busy expired without activity" "$out" >/dev/null || fail "static busy expiry reason was not explicit"
  grep -F "busy expired without activity" "$state/.stand-to-queue" >/dev/null || fail "busy expiry was not durably queued"
  [ "$(cat "$state/.wedge-escalations-$key")" = 1 ] || fail "busy expiry did not reuse the escalation counter"
  pass "a fresh busy claim expires within the bounded static-pane window"
}

test_busy_changing_pane_resets_expiry() {
  local change dir state fakebin out capture_file window key sig pid text pane_hash
  for change in content gauge; do
    dir=$(make_case "busy-changing-$change"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-changing-$change"
    printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/changing-$change.meta"
    record_pi_busy "$state" "changing-$change"
    printf 'working: setup complete\n' > "$state/changing-$change.status"
    sig=$(seen_sig "$state/changing-$change.status"); printf '%s' "$sig" > "$state/.seen-changing-${change}_status"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    text=$(printf 'Working...\n12k tokens USD 0.42')
    pane_hash=$(hash_text "$text")
    printf '%s' "$pane_hash" > "$state/.hash-$key"
    printf '2\n' > "$state/.count-$key"
    # Old turn and expired wedge clock: only actual output progress may save it.
    touch -t 200001010000 "$state/changing-$change.meta"
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    printf '2\n' > "$state/.wedge-escalations-$key"
    if [ "$change" = content ]; then
      printf 'Reading files...\n12k tokens USD 0.42' > "$capture_file"
    else
      printf 'Working...\n13k tokens USD 0.44' > "$capture_file"
    fi
    watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
      SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=240
    pid=$!
    wait_live "$pid" 30 || { reap "$pid"; fail "busy $change progress escalated: $(cat "$out")"; }
    [ ! -s "$out" ] || { reap "$pid"; fail "busy $change progress printed a wake"; }
    [ ! -s "$state/.stand-to-queue" ] || { reap "$pid"; fail "busy $change progress queued a wake"; }
    [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "busy $change progress kept the escalation counter"; }
    # A subsequent static sample may start a fresh timer, but not keep the old one.
    if [ -e "$state/.stale-since-$key" ]; then
      [ "$(cat "$state/.stale-since-$key")" -gt $(( $(date +%s) - 500 )) ] \
        || { reap "$pid"; fail "busy $change progress kept the expired timer"; }
    fi
    reap "$pid"
  done
  pass "changing rendered content or usage gauge resets busy expiry even with an old turn"
}

# A 62-line pane whose top row carries <header>; the bottom 40 lines and the
# footer gauge stay identical across calls, so only above-tail content varies.
write_tall_pane() {  # <header> <file>
  {
    printf 'status %s\n' "$1"
    for i in $(seq 2 60); do printf 'row %s\n' "$i"; done
    printf 'Working...\n12k tokens USD 0.42\n'
  } > "$2"
}

test_busy_tall_pane_above_tail_progress_resets_expiry() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-tall-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-tall"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  use_tail_aware_tmux "$fakebin"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-tall.meta"
  record_pi_busy "$state" busy-tall
  printf 'working: setup complete\n' > "$state/busy-tall.status"
  sig=$(seen_sig "$state/busy-tall.status"); printf '%s' "$sig" > "$state/.seen-busy-tall_status"

  poll_tall_pane() {
    watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
      SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=240
    pid=$!
    wait_live "$pid" 30 || { reap "$pid"; fail "tall busy pane exited: $(cat "$out")"; }
    reap "$pid"
  }

  write_tall_pane row-a "$capture_file"
  poll_tall_pane
  [ -s "$state/.stale-since-$key" ] || fail "a static busy tall pane did not start the expiry clock"

  # Only the above-tail row changes: the busy claim is not static, so no expiry.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  write_tall_pane row-b "$capture_file"
  : > "$out"
  poll_tall_pane
  [ ! -s "$out" ] || fail "progress above the bottom 40 lines was escalated as a frozen busy pane: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "progress above the bottom 40 lines escalated the wedge counter"

  # Control: the same tall pane, truly unchanged, does expire on the aged clock.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=240
  pid=$!
  wait_for_exit "$pid" 60 || { reap "$pid"; fail "a truly static tall busy pane never expired: $(cat "$out")"; }
  grep -F "busy expired without activity" "$out" >/dev/null || fail "static tall busy expiry reason was not explicit"
  pass "tall-pane progress above the bottom 40 lines resets busy expiry; a truly static tall pane still expires"
}

# AFK hands a static busy pane to the daemon exactly like a static idle stale
# pane: one stale wake per distinct unchanged hash, no wedge timer, no escalation
# counter growth on repeated polls of the same frozen pane.
test_busy_static_afk_hands_off_once_per_hash() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-static-afk); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-afk"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'Working...\n12k tokens USD 0.42' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-afk.meta"
  record_pi_busy "$state" busy-afk
  printf 'working: setup complete\n' > "$state/busy-afk.status"
  sig=$(seen_sig "$state/busy-afk.status"); printf '%s' "$sig" > "$state/.seen-busy-afk_status"
  date '+%s' > "$state/.afk"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=240
  pid=$!
  wait_for_exit "$pid" 60 || { reap "$pid"; fail "AFK static busy pane did not hand off a stale wake: $(cat "$out")"; }
  grep -F "stale: $window (busy expired without activity)" "$out" >/dev/null \
    || fail "AFK busy handoff did not name the expired busy claim: $(cat "$out")"
  [ "$(grep -c "busy expired without activity" "$out")" = 1 ] || fail "AFK busy handoff emitted more than one wake"
  wait_numeric_file "$state/.stale-since-$key" || fail "AFK busy handoff did not record its episode epoch"

  : > "$out"
  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=240
  pid=$!
  wait_live "$pid" 30 || { reap "$pid"; fail "AFK repeat poll of the same frozen busy pane exited: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "AFK re-woke the same frozen busy pane: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "AFK busy handoff accumulated deep-inspection escalations"
  [ "$(grep -c "busy expired without activity" "$state/.stand-to-queue" || true)" = 1 ] \
    || fail "AFK busy handoff was not queued exactly once"
  pass "AFK hands a static busy pane to the daemon once per distinct hash, never as a repeated wedge"
}

# An active drill run-step must suppress the away-mode busy handoff just as the
# non-afk wedge timer defers it: no wake and no handed-off hash while it runs.
test_busy_static_to_idle_surfaces_without_busy_timer_delay() {
  local mode dir state fakebin out capture_file window key sig pid gen
  for mode in normal afk; do
    dir=$(make_case "busy-to-idle-$mode"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-to-idle-$mode"
    printf 'Working...\n12k tokens USD 0.42' > "$capture_file"
    printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-to-idle-$mode.meta"
    record_pi_busy "$state" "busy-to-idle-$mode"
    printf 'working: setup complete\n' > "$state/busy-to-idle-$mode.status"
    sig=$(seen_sig "$state/busy-to-idle-$mode.status"); printf '%s' "$sig" > "$state/.seen-busy-to-idle-${mode}_status"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    [ "$mode" != afk ] || date +%s > "$state/.afk"
    watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
      SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=999999
    pid=$!
    if [ "$mode" = afk ]; then
      wait_for_exit "$pid" 60 || { reap "$pid"; fail "busy AFK control did not hand off"; }
    else
      wait_live "$pid" 40 || { reap "$pid"; fail "busy control exited before going idle: $(cat "$out")"; }
    fi
    case "$(cat "$state/.stale-$key" 2>/dev/null || true)" in
      busy:*|busy-afk:*) ;;
      *) reap "$pid"; fail "control never entered static-busy tracking" ;;
    esac
    gen=$(cat "$state/busy-to-idle-$mode.busy-gen")
    "$ROOT/bin/sq-busy-event.sh" apply "$state" "busy-to-idle-$mode" idle --gen "$gen" \
      --source pi-ext --event agent-settled
    if [ "$mode" = afk ]; then
      : > "$out"
      watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
        SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=999999
      pid=$!
    fi
    wait_for_exit "$pid" 40 || { reap "$pid"; fail "$mode busy-to-idle transition waited for busy expiry"; }
    grep -Fx -e "stale: $window" -e "routine: stale: $window" "$out" >/dev/null \
      || fail "$mode unchanged idle transition was not surfaced: $(cat "$out")"
    grep -F 'possible wedge' "$out" >/dev/null && fail "$mode idle transition was treated as busy expiry"
  done
  pass "static busy-to-idle surfaces immediately in normal and away modes without waiting out busy expiry"
}

test_busy_static_afk_run_step_defers_handoff() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-static-afk-run); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-afk-run"
  printf 'Working...\n12k tokens USD 0.42' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-afk-run.meta"
  record_pi_busy "$state" busy-afk-run
  printf 'working: validation running\n' > "$state/busy-afk-run.status"
  sig=$(seen_sig "$state/busy-afk-run.status"); printf '%s' "$sig" > "$state/.seen-busy-afk-run_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  date '+%s' > "$state/.afk"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=240 \
    SQUAD_FAKE_CREW_STATE='state: working · source: run-step · tests running'
  pid=$!
  wait_live "$pid" 30 || { reap "$pid"; fail "afk busy run-step exited: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "afk busy pane handed off during an active run-step: $(cat "$out")"
  [ ! -e "$state/.stale-$key" ] || fail "afk busy run-step recorded a handed-off hash"
  pass "an active drill run-step suppresses the away-mode busy handoff"
}

test_busy_static_pane_defers_while_run_step_active() {
  local dir state fakebin out capture_file window key sig pid since
  dir=$(make_case busy-static-active-run); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-active-run"
  printf 'Working...\n12k tokens USD 0.42' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-active-run.meta"
  record_pi_busy "$state" busy-active-run
  printf 'working: validation running\n' > "$state/busy-active-run.status"
  sig=$(seen_sig "$state/busy-active-run.status"); printf '%s' "$sig" > "$state/.seen-busy-active-run_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '2\n' > "$state/.count-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=240 \
    SQUAD_FAKE_CREW_STATE='state: working · source: run-step · tests running'
  pid=$!
  wait_live "$pid" 30 || { reap "$pid"; fail "busy active run-step escalated: $(cat "$out")"; }
  since=$(cat "$state/.stale-since-$key")
  [ "$since" -gt $(( $(date +%s) - 240 )) ] || { reap "$pid"; fail "busy active run-step did not defer the timer"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "busy active run-step counted an escalation"; }
  reap "$pid"
  pass "a genuine active drill run-step defers static busy expiry"
}

test_busy_pane_repeated_escalation_reaches_demand_deep_inspection() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case static-busy-demand-inspect); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-demand-inspect"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-demand.meta"
  record_pi_busy "$state" busy-demand
  printf 'working: setup complete\n' > "$state/busy-demand.status"
  sig=$(seen_sig "$state/busy-demand.status"); printf '%s' "$sig" > "$state/.seen-busy-demand_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  touch -t 200001010000 "$state/busy-demand.turn-ended"
  prime_turnend_seen "$state/busy-demand.turn-ended"

  # Priming round: first sighting of a static busy pane absorbs and starts
  # the wedge timer, mirroring the existing provably-working wedge tests.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "priming round for static busy escalation was not absorbed: $(cat "$out")"
  fi
  reap "$pid"

  n=1
  while [ "$n" -le 3 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
      SQUAD_STATE_OVERRIDE="$state" SQUAD_STALE_ESCALATE_SECS=240 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
      SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 40 || fail "static busy escalation round $n did not escalate: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "static busy round $n did not report escalation count $n: $(cat "$out")"
    grep -F "busy expired without activity" "$out" >/dev/null || fail "busy expiry round $n lost its explicit reason"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "static busy round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "static busy round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "static busy escalation counter did not persist across consecutive rounds"
  pass "repeated static busy escalations reuse the existing counter and demand deep inspection at the threshold"
}

# tmux without a viewport-only capture: scrollback-bounded reads still work, but the
# complete rendered screen cannot be read, so a busy claim has no proof of staticness.
use_no_viewport_tmux() {  # <fakebin>
  local fakebin=$1
  mv "$fakebin/tmux" "$fakebin/tmux-base"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ] && [ -n "${SQUAD_FAKE_TMUX_CAPTURE:-}" ]; then
  lines=
  while [ $# -gt 0 ]; do
    if [ "$1" = -S ]; then lines=${2#-}; fi
    shift
  done
  [ -n "$lines" ] || exit 1
  tail -n "$lines" "$SQUAD_FAKE_TMUX_CAPTURE"
  exit 0
fi
exec "$(dirname "$0")/tmux-base" "$@"
SH
  chmod +x "$fakebin/tmux"
}

test_busy_static_pane_without_readable_viewport_never_expires() {
  local mode dir state fakebin out capture_file window key sig pid
  for mode in readable unreadable; do
    dir=$(make_case "busy-viewport-$mode"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-viewport-$mode"
    printf 'Working...\n12k tokens USD 0.42' > "$capture_file"
    printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-viewport-$mode.meta"
    record_pi_busy "$state" "busy-viewport-$mode"
    printf 'working: setup complete\n' > "$state/busy-viewport-$mode.status"
    sig=$(seen_sig "$state/busy-viewport-$mode.status"); printf '%s' "$sig" > "$state/.seen-busy-viewport-${mode}_status"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
    printf '2\n' > "$state/.count-$key"
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    [ "$mode" = readable ] || use_no_viewport_tmux "$fakebin"
    watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
      SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=240
    pid=$!
    if [ "$mode" = readable ]; then
      wait_for_exit "$pid" 60 || { reap "$pid"; fail "control: a readable static busy viewport never expired: $(cat "$out")"; }
      grep -F "busy expired without activity" "$out" >/dev/null || fail "control: readable static busy expiry reason was not explicit"
    else
      wait_live "$pid" 30 || { reap "$pid"; fail "unreadable viewport exited: $(cat "$out")"; }
      reap "$pid"
      [ ! -s "$out" ] || fail "a busy pane with an unreadable rendered viewport woke: $(cat "$out")"
      [ ! -e "$state/.wedge-escalations-$key" ] || fail "an unreadable rendered viewport counted a wedge escalation"
      [ ! -e "$state/.stale-since-$key" ] || fail "an unreadable rendered viewport kept the busy expiry clock running"
    fi
  done
  pass "a busy claim expires only on a readable complete rendered viewport, never on tail-only evidence"
}

test_busy_static_unreadable_viewport_logs_limitation_once() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-viewport-limit); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-viewport-limit"
  printf 'Working...\n12k tokens USD 0.42' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-viewport-limit.meta"
  record_pi_busy "$state" busy-viewport-limit
  printf 'working: setup complete\n' > "$state/busy-viewport-limit.status"
  sig=$(seen_sig "$state/busy-viewport-limit.status"); printf '%s' "$sig" > "$state/.seen-busy-viewport-limit_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  use_no_viewport_tmux "$fakebin"
  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=240
  pid=$!
  wait_live "$pid" 40 || { reap "$pid"; fail "unreadable static busy pane exited: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "an unevaluable busy claim woke: $(cat "$out")"
  [ "$(grep -c "busy claim not evaluated" "$state/.sentry-triage.log" || true)" = 1 ] \
    || fail "the unevaluable busy limitation was not logged exactly once: $(cat "$state/.sentry-triage.log" 2>/dev/null || true)"
  pass "a static busy claim with no complete viewport logs its evaluation limit once and never alarms"
}

test_released_agentless_window_skips_stale_but_resumes_when_agent_returns() {
  local dir state fakebin out capture_file command_file window key pid
  dir=$(make_case released-agentless); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; command_file="$dir/command.txt"
  window="test:sq-released-agentless"
  printf 'idle shell prompt' > "$capture_file"
  printf 'bash\n' > "$command_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/released-agentless.meta"
  printf 'working: execution interrupted by outage\n' > "$state/released-agentless.status"
  printf 'stale signature\n' > "$state/.seen-released-agentless_status"
  printf 'late turn end\n' > "$state/released-agentless.turn-ended"
  printf 'stale signature\n' > "$state/.seen-released-agentless_turn-ended"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" transition released-agentless released >/dev/null \
    || fail "could not create released execution fixture"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'old pane hash' > "$state/.hash-$key"
  printf '2\n' > "$state/.count-$key"
  printf 'old pane hash' > "$state/.stale-$key"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.stale-since-$key"
  printf '4\n' > "$state/.wedge-escalations-$key"
  # Residue from an earlier away-mode episode for this same task: the daemon's
  # task-keyed watcher markers and the compaction dedup marker.
  printf '1\n' > "$state/.subsuper-stale-released-agentless"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.subsuper-paused-released-agentless"
  printf 'working: stale line\n' > "$state/.subsuper-seen-status-released-agentless"
  printf '7 2' > "$state/.compaction-notified-released-agentless"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" \
    SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  wait_live "$pid" 40 || { reap "$pid"; fail "released agentless pane escalated: $(cat "$out")"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "released agentless pane produced repeated stale output: $(cat "$out")"; }
  [ ! -s "$state/.stand-to-queue" ] || { reap "$pid"; fail "released agentless pane enqueued stale wakes"; }
  for marker in .hash- .count- .stale- .stale-since- .wedge-escalations-; do
    [ ! -e "$state/$marker$key" ] || { reap "$pid"; fail "released agentless pane left $marker bookkeeping behind"; }
  done
  for marker in .subsuper-stale- .subsuper-paused- .subsuper-seen-status- .compaction-notified-; do
    [ ! -e "$state/${marker}released-agentless" ] \
      || { reap "$pid"; fail "released agentless pane left $marker task-keyed residue behind"; }
  done
  [ ! -e "$state/.seen-released-agentless_status" ] \
    || { reap "$pid"; fail "released agentless pane left its status signal signature behind"; }
  [ ! -e "$state/.seen-released-agentless_turn-ended" ] \
    || { reap "$pid"; fail "released agentless pane left its turn-ended signal signature behind"; }

  # The execution stays released, but a harness agent appearing in the same
  # window must restore normal stale supervision rather than latch the skip.
  printf 'pi\n' > "$command_file"
  wait_for_exit "$pid" 50 || { reap "$pid"; fail "sentry did not resume supervision when an agent returned"; }
  grep -F 'signal:' "$out" >/dev/null \
    || fail "agent return did not surface the newly eligible signal: $(cat "$out")"
  pass "released agentless windows leave no signal or stale markers, while an agent return resumes normal supervision"
}

# The terminal-agentless skip must not swallow the first commander-relevant
# finish: Squad has to see the done:/failed: notice once even though the skip then
# retires every signal signature so later polls of the same files stay quiet.
test_terminal_agentless_notice_surfaces_once_then_stays_quiet() {
  local dir state fakebin out capture_file command_file window statusf queue_count pid
  dir=$(make_case terminal-agentless-notice); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; command_file="$dir/command.txt"
  window="test:sq-terminal-agentless-notice"; statusf="$state/agentless-notice.status"
  printf 'idle shell prompt' > "$capture_file"
  printf 'bash\n' > "$command_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/agentless-notice.meta"
  printf 'working: last progress note\ndone: PR https://example.test/pr/9 checks green\n' > "$statusf"
  printf 'late turn end\n' > "$state/agentless-notice.turn-ended"
  printf 'stale signature' > "$state/.seen-agentless-notice_status"
  printf 'stale signature' > "$state/.seen-agentless-notice_turn-ended"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" transition agentless-notice released >/dev/null \
    || fail "could not create the released execution fixture"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" \
    SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  wait_for_exit "$pid" 50 \
    || { reap "$pid"; fail "the first terminal notice of an agentless task was swallowed: $(cat "$out")"; }
  [ "$(grep -c '^signal:' "$out")" = 1 ] \
    || fail "the terminal notice did not surface exactly once: $(cat "$out")"
  grep -F "signal: $statusf" "$out" >/dev/null \
    || fail "the surfaced wake did not name the terminal status file: $(cat "$out")"
  [ "$(cat "$state/.hb-surfaced-agentless-notice" 2>/dev/null)" = 'done: PR https://example.test/pr/9 checks green' ] \
    || fail "the surfaced notice was not recorded for later dedup: $(cat "$state/.hb-surfaced-agentless-notice" 2>/dev/null || true)"
  [ "$(cut -f3,4 "$state/.stand-to-queue" | sort -u)" = "$(printf 'signal\tagentless-notice.status')" ] \
    || fail "the terminal notice queued something other than one signal wake: $(cat "$state/.stand-to-queue" 2>/dev/null || true)"
  queue_count=$(wc -l < "$state/.stand-to-queue" 2>/dev/null | tr -d '[:space:]')

  : > "$out"
  # Re-seed both signatures so this run's first poll reaches the already-surfaced
  # retirement gate instead of short-circuiting on the signature run 1 wrote.
  printf 'older signature' > "$state/.seen-agentless-notice_status"
  printf 'older signature' > "$state/.seen-agentless-notice_turn-ended"
  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" \
    SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  wait_live "$pid" 40 || { reap "$pid"; fail "the already-surfaced terminal notice resurfaced: $(cat "$out")"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "a later poll repeated the terminal notice: $(cat "$out")"; }
  [ "$(wc -l < "$state/.stand-to-queue" 2>/dev/null | tr -d '[:space:]')" = "$queue_count" ] \
    || { reap "$pid"; fail "a later poll enqueued a duplicate terminal wake"; }
  reap "$pid"
  for marker in _status _turn-ended; do
    [ ! -e "$state/.seen-agentless-notice$marker" ] \
      || fail "the terminal-agentless skip left .seen-agentless-notice$marker behind"
  done
  [ -s "$state/.hb-surfaced-agentless-notice" ] \
    || fail "retiring the signal signatures dropped the surfaced-notice marker"
  pass "an agentless terminal done:/failed: notice surfaces exactly once, then its signatures retire without repeating"
}

# The terminal stale skip owns the retirement of an already-delivered terminal
# notice's signal signatures, not only the per-poll signal scan. When a signature
# still matches its .seen-* marker the scan short-circuits on the unchanged
# signature before it ever reaches its retirement gate, so nothing but the skip
# can clear it. Retiring it is what keeps an unchanged done:/failed: notice from
# being re-reported once an agent returns to the same window, and the delivered
# notice's surfaced marker has to survive so the skip stays a retirement rather
# than a second delivery.
test_terminal_stale_skip_retires_signal_signatures_after_quiet_scan() {
  local dir state fakebin out capture_file command_file window pid i marker
  dir=$(make_case terminal-stale-retire-sigs); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; command_file="$dir/command.txt"
  window="test:sq-terminal-stale-retire"
  printf 'idle shell prompt' > "$capture_file"
  printf 'bash\n' > "$command_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/retire-sigs.meta"
  printf 'working: last progress note\ndone: PR https://example.test/pr/13 checks green\n' \
    > "$state/retire-sigs.status"
  printf 'late turn end\n' > "$state/retire-sigs.turn-ended"
  # Signatures already match, so scan_signals "continue"s above its retirement
  # gate for both files: only the terminal stale skip can retire them here.
  printf '%s' "$(seen_sig "$state/retire-sigs.status")" > "$state/.seen-retire-sigs_status"
  printf '%s' "$(seen_sig "$state/retire-sigs.turn-ended")" > "$state/.seen-retire-sigs_turn-ended"
  # The notice was already delivered to Squad, which is what licenses retirement.
  printf 'done: PR https://example.test/pr/13 checks green' > "$state/.hb-surfaced-retire-sigs"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" transition retire-sigs released >/dev/null \
    || fail "could not create the released execution fixture"
  # Residue from an earlier away-mode episode for this same task.
  printf '1\n' > "$state/.subsuper-stale-retire-sigs"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.subsuper-paused-retire-sigs"
  printf 'working: stale line\n' > "$state/.subsuper-seen-status-retire-sigs"
  printf '9 4' > "$state/.compaction-notified-retire-sigs"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" \
    SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  i=0
  while [ "$i" -lt 60 ] && [ -e "$state/.seen-retire-sigs_status" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  wait_live "$pid" 40 || { reap "$pid"; fail "the retired terminal-agentless generation woke the sentry: $(cat "$out")"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "the retired terminal-agentless generation printed a wake: $(cat "$out")"; }
  [ ! -s "$state/.stand-to-queue" ] || { reap "$pid"; fail "the retired terminal-agentless generation enqueued a wake"; }
  for marker in _status _turn-ended; do
    [ ! -e "$state/.seen-retire-sigs$marker" ] \
      || { reap "$pid"; fail "the terminal stale skip left .seen-retire-sigs$marker behind"; }
  done
  for marker in .subsuper-stale- .subsuper-paused- .subsuper-seen-status- .compaction-notified-; do
    [ ! -e "$state/${marker}retire-sigs" ] \
      || { reap "$pid"; fail "the terminal stale skip left $marker residue behind"; }
  done
  [ "$(cat "$state/.hb-surfaced-retire-sigs" 2>/dev/null)" = 'done: PR https://example.test/pr/13 checks green' ] \
    || { reap "$pid"; fail "retiring the signatures dropped the delivered-notice marker"; }
  [ "$(grep -c 'skipped stale supervision' "$state/.sentry-triage.log" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the terminal stale skip was not traced exactly once: $(cat "$state/.sentry-triage.log" 2>/dev/null || true)"; }
  grep -F "$window" "$state/.sentry-triage.log" >/dev/null \
    || { reap "$pid"; fail "the skip trace did not name the skipped window"; }
  reap "$pid"
  pass "the terminal stale skip retires every signal signature of an already-delivered notice even when the signal scan is quiet"
}

# A released dispatch record is immutable for dispatch, not proof that its run
# is over: the shared projection reports a gate-parked run over it as running.
# Such a window must keep ordinary supervision instead of being latched into the
# terminal-agentless skip.
test_released_record_with_live_run_keeps_stale_supervision() {
  local dir state fakebin out capture_file command_file window sig pid
  dir=$(make_case released-live-run); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; command_file="$dir/command.txt"
  window="test:sq-released-live-run"
  printf 'idle shell prompt' > "$capture_file"
  printf 'bash\n' > "$command_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/released-live-run.meta"
  printf 'working: run still active\n' > "$state/released-live-run.status"
  sig=$(seen_sig "$state/released-live-run.status")
  printf '%s' "$sig" > "$state/.seen-released-live-run_status"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" transition released-live-run released >/dev/null \
    || fail "could not create the released execution fixture"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" \
    SQUAD_FAKE_CREW_STATE='state: parked · source: run-step · parked at review gate' \
    SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  wait_for_exit "$pid" 50 \
    || { reap "$pid"; fail "a released record owning a parked run was skipped as terminal: $(cat "$out")"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "a released record with a live run did not keep ordinary stale supervision: $(cat "$out")"
  pass "a released record that still owns a live run keeps ordinary stale supervision"
}

# The incident shape the release check alone misses: teardown was refused (the
# work had not landed), so the dispatch record still says running even though the
# crew's own run is long over. The shared current-state boundary - not the raw
# dispatch record - is what proves there is nothing left to rescue.
test_agentless_window_with_unretired_terminal_execution_skips_stale() {
  local dir state fakebin out capture_file command_file window key pid sig
  dir=$(make_case agentless-terminal-running); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; command_file="$dir/command.txt"
  window="test:sq-agentless-terminal"
  printf 'idle shell prompt' > "$capture_file"
  printf 'bash\n' > "$command_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/agentless-terminal.meta"
  printf 'working: execution interrupted by outage\n' > "$state/agentless-terminal.status"
  sig=$(seen_sig "$state/agentless-terminal.status")
  printf '%s' "$sig" > "$state/.seen-agentless-terminal_status"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" claim agentless-terminal >/dev/null \
    || fail "could not claim the interrupted execution fixture"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" transition agentless-terminal running >/dev/null \
    || fail "could not create the unretired running execution fixture"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'old pane hash' > "$state/.hash-$key"
  printf '2\n' > "$state/.count-$key"
  printf 'old pane hash' > "$state/.stale-$key"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.stale-since-$key"
  printf '4\n' > "$state/.wedge-escalations-$key"
  printf '1\n' > "$state/.subsuper-stale-agentless-terminal"

  # The crew's authoritative state is terminal even though its dispatch record
  # was never retired.
  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" \
    SQUAD_FAKE_CREW_STATE='state: done · source: run-step · terminal run' \
    SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  wait_live "$pid" 40 || { reap "$pid"; fail "terminal unretired execution escalated: $(cat "$out")"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "terminal unretired execution produced stale output: $(cat "$out")"; }
  [ ! -s "$state/.stand-to-queue" ] || { reap "$pid"; fail "terminal unretired execution enqueued stale wakes"; }
  [ ! -e "$state/.hash-$key" ] || { reap "$pid"; fail "terminal unretired execution left window bookkeeping behind"; }
  [ ! -e "$state/.subsuper-stale-agentless-terminal" ] \
    || { reap "$pid"; fail "terminal unretired execution left the daemon stale marker behind"; }
  reap "$pid"

  # The same agentless running record with a gate-parked run keeps the ordinary
  # escalation path: a live or parked run is never skipped, whatever its pane
  # looks like, while an idle pane on its own is still supervised as before.
  : > "$out"
  rm -f "$state/.stand-to-queue"
  sig=$(seen_sig "$state/agentless-terminal.status")
  printf '%s' "$sig" > "$state/.seen-agentless-terminal_status"
  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" \
    SQUAD_FAKE_CREW_STATE='state: parked · source: run-step · parked at review gate' \
    SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  wait_for_exit "$pid" 50 || { reap "$pid"; fail "a gate-parked run on an agentless window stopped escalating"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "a gate-parked run did not follow the ordinary stale path: $(cat "$out")"
  pass "a terminal execution with an unretired dispatch record skips stale, while a gate-parked run still escalates"
}

# The shared current-state projection forks sq-crew-state.sh, which may make a
# bounded drill call, so an outage population of agentless panes must not pay for
# it once per window per poll. The sentry memoizes the verdict per task
# generation, which carries the pane's agent attribution and the busy-record and
# dispatch evidence the projection consumes, so a live pane is never skipped and
# never pays for the projection, the incident sequence - the operator dies on an
# unretired record whose only claim is a busy pane - yields exactly one bounded
# trace even when the sentry re-confirms that generation on its refresh cadence,
# and a changed generation re-reads instead of inheriting a terminal latch.
test_terminal_projection_is_memoized_per_task_generation() {
  local dir state fakebin window calls verdicts
  dir=$(make_case terminal-probe-memo); state="$dir/state"; fakebin="$dir/fakebin"
  window="test:sq-terminal-probe-memo"
  calls="$dir/crew-state.calls"
  : > "$calls"
  cat > "$fakebin/sq-crew-state.sh" <<SH
#!/usr/bin/env bash
printf 'read\n' >> '$calls'
printf '%s\n' "\${SQUAD_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/sq-crew-state.sh"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/memo.meta"
  printf 'working: execution interrupted by outage\n' > "$state/memo.status"
  printf 'pi\n' > "$dir/command.txt"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" claim memo >/dev/null \
    || fail "could not claim the memo fixture"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" transition memo running >/dev/null \
    || fail "could not create the running memo fixture"

  verdicts=$(PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" \
    SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_ROOT_OVERRIDE="$ROOT" \
    SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_COMMAND_FILE="$dir/command.txt" \
    SQUAD_FAKE_CREW_STATE='state: working · source: pane · harness busy' \
    bash -c '. "$1" || exit 1
      poll() { if window_is_terminal_and_agentless "$1" memo; then echo terminal; else echo open; fi; }
      i=0
      while [ "$i" -lt 4 ]; do
        poll "$2"
        i=$((i + 1))
      done
      printf "bash\n" > "$3"
      i=0
      while [ "$i" -lt 4 ]; do
        poll "$2"
        i=$((i + 1))
      done
      TERMINAL_PROBE_SECS=0
      i=0
      while [ "$i" -lt 3 ]; do
        poll "$2"
        i=$((i + 1))
      done
      TERMINAL_PROBE_SECS=300
      printf "working: run still queued\n" >> "$SQUAD_STATE_OVERRIDE/memo.status"
      SQUAD_FAKE_CREW_STATE="state: parked · source: run-step · parked at review gate"
      export SQUAD_FAKE_CREW_STATE
      poll "$2"
      printf "state=idle source=pi-ext\n" > "$SQUAD_STATE_OVERRIDE/memo.busy-state"
      SQUAD_FAKE_CREW_STATE="state: unknown · source: pane · harness state unavailable"
      export SQUAD_FAKE_CREW_STATE
      poll "$2"
      printf "pi\n" > "$3"
      poll "$2"' \
    _ "$WATCH" "$window" "$dir/command.txt") || fail "could not drive the terminal projection"
  [ "$(printf '%s\n' "$verdicts" | sed -n '1,4p' | sort -u)" = open ] \
    || fail "a live agent was skipped by a terminal projection: $verdicts"
  [ "$(printf '%s\n' "$verdicts" | sed -n '5,11p' | sort -u)" = terminal ] \
    || fail "an agentless terminal window was not read as terminal on every poll: $verdicts"
  [ "$(printf '%s\n' "$verdicts" | sed -n '12p')" = open ] \
    || fail "a started run did not re-read the terminal projection: $verdicts"
  [ "$(printf '%s\n' "$verdicts" | sed -n '13p')" = open ] \
    || fail "a cleared busy claim did not re-read the terminal projection: $verdicts"
  [ "$(printf '%s\n' "$verdicts" | sed -n '14p')" = open ] \
    || fail "a returning agent inherited the memoized verdict: $verdicts"
  [ "$(wc -l < "$calls" | tr -d ' ')" = 6 ] \
    || fail "the terminal projection ran $(wc -l < "$calls" | tr -d ' ') times across fourteen polls of one task, expected once per generation and once per refresh"
  [ "$(grep -c 'skipped stale supervision' "$state/.sentry-triage.log" 2>/dev/null || true)" = 1 ] \
    || fail "the first agentless skip of one generation was traced $(grep -c 'skipped stale supervision' "$state/.sentry-triage.log" 2>/dev/null || true) times instead of once: $(cat "$state/.sentry-triage.log" 2>/dev/null)"
  grep -F "$window" "$state/.sentry-triage.log" >/dev/null \
    || fail "the bounded skip trace did not name the skipped window: $(cat "$state/.sentry-triage.log" 2>/dev/null)"
  pass "the terminal projection is read once per task generation, and one generation is traced once across its refreshes"
}

# The signal scan runs inside a command substitution while the stale pass runs in
# the sentry's own shell. One generation must cost one projection read across
# both, so the scan's verdict has to survive the subshell: the scan retires the
# signatures of this already-surfaced terminal notice on every poll, which is
# exactly the path that would otherwise re-fork sq-crew-state.sh per poll.
test_signal_scan_and_window_pass_share_terminal_memo() {
  local dir state fakebin out capture_file command_file window calls pid i
  dir=$(make_case terminal-probe-shared); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; command_file="$dir/command.txt"
  window="test:sq-terminal-probe-shared"; calls="$dir/crew-state.calls"
  : > "$calls"
  cat > "$fakebin/sq-crew-state.sh" <<SH
#!/usr/bin/env bash
printf 'read\n' >> '$calls'
printf '%s\n' "\${SQUAD_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/sq-crew-state.sh"
  printf 'idle shell prompt' > "$capture_file"
  printf 'bash\n' > "$command_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/probe-shared.meta"
  printf 'working: last progress note\ndone: PR https://example.test/pr/11 checks green\n' > "$state/probe-shared.status"
  printf 'late turn end\n' > "$state/probe-shared.turn-ended"
  printf 'done: PR https://example.test/pr/11 checks green' > "$state/.hb-surfaced-probe-shared"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" transition probe-shared released >/dev/null \
    || fail "could not create the released execution fixture"

  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" \
    SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 SQUAD_STALE_ESCALATE_SECS=1 \
    SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -F 'skipped stale supervision' "$state/.sentry-triage.log" >/dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -F 'skipped stale supervision' "$state/.sentry-triage.log" >/dev/null 2>&1 \
    || { reap "$pid"; fail "the terminal-agentless stale pass never ran for the seeded generation: $(cat "$out")"; }
  [ "$(wc -l < "$calls" | tr -d ' ')" = 1 ] \
    || { reap "$pid"; fail "the signal scan and the stale pass read the terminal projection $(wc -l < "$calls" | tr -d ' ') times for one generation instead of sharing one memoized verdict"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "the absorbed terminal-agentless generation woke the sentry: $(cat "$out")"
  pass "the signal scan and the stale pass share one memoized terminal verdict per generation"
}

# A task record can outlive its dispatch sidecar: the meta is published before the
# exec claim (an interrupted spawn) and the exec is removed before the meta (an
# interrupted teardown). Such a record still must not enter the stale clock when
# its pane is agentless and its crew projects terminal, while a gate-parked run
# keeps the ordinary escalation path.
test_agentless_window_without_dispatch_sidecar_uses_terminal_projection() {
  local dir state fakebin out capture_file command_file window key sig pid
  dir=$(make_case agentless-no-exec); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; command_file="$dir/command.txt"
  window="test:sq-agentless-no-exec"
  printf 'idle shell prompt' > "$capture_file"
  printf 'bash\n' > "$command_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/noexec.meta"
  printf 'working: execution interrupted by outage\n' > "$state/noexec.status"
  sig=$(seen_sig "$state/noexec.status")
  printf '%s' "$sig" > "$state/.seen-noexec_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'old pane hash' > "$state/.hash-$key"
  printf '2\n' > "$state/.count-$key"
  printf 'old pane hash' > "$state/.stale-$key"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.stale-since-$key"
  printf '4\n' > "$state/.wedge-escalations-$key"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" \
    SQUAD_FAKE_CREW_STATE='state: done · source: run-step · terminal run' \
    SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  wait_live "$pid" 40 || { reap "$pid"; fail "a sidecar-less terminal record escalated: $(cat "$out")"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "a sidecar-less terminal record produced stale output: $(cat "$out")"; }
  [ ! -s "$state/.stand-to-queue" ] || { reap "$pid"; fail "a sidecar-less terminal record enqueued stale wakes"; }
  [ ! -e "$state/.hash-$key" ] || { reap "$pid"; fail "a sidecar-less terminal record left window bookkeeping behind"; }
  reap "$pid"

  : > "$out"
  rm -f "$state/.stand-to-queue"
  sig=$(seen_sig "$state/noexec.status")
  printf '%s' "$sig" > "$state/.seen-noexec_status"
  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" \
    SQUAD_FAKE_CREW_STATE='state: parked · source: run-step · parked at review gate' \
    SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  wait_for_exit "$pid" 50 || { reap "$pid"; fail "a sidecar-less gate-parked run stopped escalating"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "a sidecar-less gate-parked run did not follow the ordinary stale path: $(cat "$out")"
  pass "a record without a dispatch sidecar is judged by its terminal projection, and a gate-parked run still escalates"
}

# The incident shape the released check alone misses: the machine-wide outage
# killed the operator, teardown was refused because the work had not landed, and
# the dead operator's last busy claim survived on the sidecar. The crew projection
# therefore still says `working · pane`, but no agent is in the pane to advance
# that claim, so nothing is left to rescue: the busy-expired wedge clock must not
# run at all and must leave no bookkeeping behind.
test_unretired_running_record_with_stale_busy_claim_skips_stale() {
  local dir state fakebin out capture_file command_file window key pane_hash pid
  dir=$(make_case running-stale-busy-claim); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; command_file="$dir/command.txt"
  window="test:sq-running-stale-busy-claim"
  printf 'Working...\n12k tokens USD 0.42' > "$capture_file"
  printf 'bash\n' > "$command_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/running-stale-busy-claim.meta"
  record_pi_busy "$state" running-stale-busy-claim
  printf 'working: execution interrupted by outage\n' > "$state/running-stale-busy-claim.status"
  sig=$(seen_sig "$state/running-stale-busy-claim.status")
  printf '%s' "$sig" > "$state/.seen-running-stale-busy-claim_status"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" claim running-stale-busy-claim >/dev/null \
    || fail "could not claim the outage execution fixture"
  SQUAD_STATE_OVERRIDE="$state" "$ROOT/bin/sq-exec-state.sh" transition running-stale-busy-claim running >/dev/null \
    || fail "could not create the unretired running execution fixture"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$(cat "$capture_file")")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '2\n' > "$state/.count-$key"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.stale-since-$key"
  printf '4\n' > "$state/.wedge-escalations-$key"
  printf '1\n' > "$state/.subsuper-stale-running-stale-busy-claim"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_FAKE_TMUX_COMMAND_FILE="$command_file" \
    SQUAD_FAKE_CREW_STATE='state: working · source: pane · harness busy (pi-ext)' \
    SQUAD_STALE_ESCALATE_SECS=1
  pid=$!
  wait_live "$pid" 50 \
    || { reap "$pid"; fail "a stale busy claim on an unretired running record escalated: $(cat "$out")"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "a stale busy claim on an unretired running record produced stale output: $(cat "$out")"; }
  [ ! -s "$state/.stand-to-queue" ] || { reap "$pid"; fail "a stale busy claim on an unretired running record enqueued stale wakes"; }
  for marker in .hash- .count- .stale- .stale-since- .wedge-escalations-; do
    [ ! -e "$state/$marker$key" ] \
      || { reap "$pid"; fail "a skipped stale busy claim left $marker bookkeeping behind"; }
  done
  [ ! -e "$state/.subsuper-stale-running-stale-busy-claim" ] \
    || { reap "$pid"; fail "a skipped stale busy claim left the daemon stale marker behind"; }
  [ "$(grep -c 'skipped stale supervision' "$state/.sentry-triage.log" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the skipped window was traced $(grep -c 'skipped stale supervision' "$state/.sentry-triage.log" 2>/dev/null || true) times instead of once: $(cat "$state/.sentry-triage.log" 2>/dev/null)"; }
  reap "$pid"
  pass "an unretired running record whose only claim is a busy pane no agent backs is skipped with no residue"
}

test_busy_static_finished_task_is_absorbed_without_alarm() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-static-finished); state="$dir/state"; fakebin="$dir/fakebin"
  cat > "$fakebin/sq-crew-state.sh" <<'SH'
#!/usr/bin/env bash
cat "$(dirname "$0")/current-state"
SH
  printf 'state: done · source: status · shipped\n' > "$fakebin/current-state"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-finished"
  printf 'Working...\n12k tokens USD 0.42' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-finished.meta"
  record_pi_busy "$state" busy-finished
  printf 'done: shipped\n' > "$state/busy-finished.status"
  sig=$(seen_sig "$state/busy-finished.status"); printf '%s' "$sig" > "$state/.seen-busy-finished_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '2\n' > "$state/.count-$key"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=1 \
    SQUAD_FAKE_CREW_STATE='state: done · source: status · shipped'
  pid=$!
  wait_live "$pid" 50 || { reap "$pid"; fail "finished busy task exited: $(cat "$out")"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "a finished busy task raised an alarm: $(cat "$out")"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "a finished busy task counted an escalation"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "finished absorption rearmed the wedge timer"; }
  grep -F "absorbed busy (task already finished)" "$state/.sentry-triage.log" >/dev/null \
    || { reap "$pid"; fail "finished busy absorption was not recorded"; }
  # The same pane now belongs to a current active run; no finished latch may
  # hide it merely because the old done status and rendered output persist.
  printf 'state: working · source: run-step · newer validation\n' > "$fakebin/current-state"
  wait_live "$pid" 40 || { reap "$pid"; fail "new active validation was alarmed: $(cat "$out")"; }
  [ -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "old finished state hid the newer active run"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "new active run counted a false wedge"; }
  reap "$pid"
  pass "finished busy clears its timer without alarms and never latches over a newer authoritative active run"
}

test_busy_static_done_status_never_masks_active_run() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-static-done-active); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-busy-done-active"
  printf 'Working...\n12k tokens USD 0.42' > "$capture_file"
  printf 'window=%s\nkind=strike\nharness=pi\n' "$window" > "$state/busy-done-active.meta"
  record_pi_busy "$state" busy-done-active
  printf 'done: earlier attempt\n' > "$state/busy-done-active.status"
  sig=$(seen_sig "$state/busy-done-active.status"); printf '%s' "$sig" > "$state/.seen-busy-done-active_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '2\n' > "$state/.count-$key"

  watch_bg "$state" "$fakebin" "$out" env SQUAD_FAKE_TMUX_WINDOW="$window" \
    SQUAD_FAKE_TMUX_CAPTURE="$capture_file" SQUAD_STALE_ESCALATE_SECS=1 \
    SQUAD_FAKE_CREW_STATE='state: working · source: run-step · new validation'
  pid=$!
  wait_live "$pid" 50 || { reap "$pid"; fail "done-with-active-run busy task exited: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "an active run-step was escalated behind an old done status: $(cat "$out")"
  grep -F "already finished" "$state/.sentry-triage.log" >/dev/null 2>&1 \
    && fail "an old done status absorbed a task whose current state is an active run"
  pass "an old done status never absorbs a static busy pane whose current state is an active run-step"
}

test_nonterminal_stale_repairs_missing_or_corrupt_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case nonterminal-stale-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:sq-quiet-timer"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/quiet-timer.meta"
  printf 'working: still compiling\n' > "$state/quiet-timer.status"
  sig=$(seen_sig "$state/quiet-timer.status"); printf '%s' "$sig" > "$state/.seen-quiet-timer_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"

  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with missing timer did not initialize stale-since"; }
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "sentry exited while repairing a missing stale-since timer: $(cat "$out")"
  fi
  [ ! -s "$state/.stand-to-queue" ] || { reap "$pid"; fail "missing stale-since repair enqueued a wake"; }
  reap "$pid"

  printf 'corrupt\n' > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_STALE_ESCALATE_SECS=999 SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with corrupt timer did not repair stale-since"; }
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" != "corrupt" ] || { reap "$pid"; fail "corrupt stale-since value was left in place"; }
  [ ! -s "$state/.stand-to-queue" ] || { reap "$pid"; fail "corrupt stale-since repair enqueued a wake"; }
  reap "$pid"
  pass "matching non-terminal stale suppressors repair missing or corrupt stale-since timers"
}

# --- triage debug log stays size capped -------------------------------------

test_triage_log_size_cap_accepts_spaced_wc_counts() {
  local dir state fakebin out status_file pid lines i
  dir=$(make_case triage-log-spaced-wc); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  i=1
  while [ "$i" -le 3000 ]; do
    printf 'old line %04d\n' "$i" >> "$state/.sentry-triage.log"
    i=$((i + 1))
  done
  cat > "$fakebin/wc" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  printf '   999999\n'
  exit 0
fi
exit 127
SH
  chmod +x "$fakebin/wc"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  printf 'id=task\n' > "$state/task.meta"
  # Provably working so the no-verb signal is absorbed (which is what writes the
  # triage log line under test).
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 SQUAD_WATCH_TRIAGE_LOG_MAX_BYTES=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited for a benign signal while testing log capping: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    lines=$(awk 'END { print NR + 0 }' "$state/.sentry-triage.log")
    [ "$lines" -le 2000 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lines" -le 2000 ] || { reap "$pid"; fail "triage log was not capped when wc emitted a spaced byte count (lines=$lines)"; }
  [ ! -s "$state/.stand-to-queue" ] || { reap "$pid"; fail "benign signal enqueued a wake while testing log capping"; }
  reap "$pid"
  pass "triage log capping handles wc byte counts with leading spaces"
}

# --- process-event delivery -------------------------------------------------
# A durably captured process-event result publishes an ordinary `check` wake on
# the durable queue. The sentry must deliver that queued wake proactively -
# print an actionable reason and exit into the same rewake path every other
# actionable wake uses - rather than leaving it to be found by a manual drain.

# Run the runner against a case home. SQUAD_ROOT_OVERRIDE (exported by the shared
# wake harness to keep the drain's tangle check inert) would otherwise point the
# runner at a root with no installed adapters, and the claim root must stay
# inside the case so nothing here can observe a real home's source ownership.
pe_case() {  # <dir> <command>...
  local dir=$1
  shift
  (unset SQUAD_ROOT_OVERRIDE
   SQUAD_PROCEVENT_CLAIM_ROOT="$dir/claims" SQUAD_BASE="$dir" "$ROOT/bin/sq-procevent.sh" "$@")
}

# Capture one real process-event result into <dir>'s home, then retire the
# source so the fixture holds exactly the reported end state: one durably
# captured, unhandled, queued result and no remaining poll work.
seed_captured_procevent_result() {  # <dir>
  local dir=$1 i=0
  pe_case "$dir" register sq-report delivery-src -- \
    /bin/sh -c 'printf "session:\n  file: /a.html\n  status: waiting\n"' >/dev/null || return 1
  pe_case "$dir" reconcile >/dev/null || return 1
  while [ "$i" -lt 100 ]; do
    [ -s "$dir/state/.stand-to-queue" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  pe_case "$dir" retire delivery-src >/dev/null || return 1
  [ -s "$dir/state/.stand-to-queue" ]
}

# The sentry, scoped by SQUAD_BASE rather than SQUAD_STATE_OVERRIDE, so the
# per-cycle reconcile it launches resolves the same home's state.
procevent_watch_bg() {  # <dir> <out>
  local dir=$1 out=$2
  PATH="$dir/fakebin:$PATH" SQUAD_BASE="$dir" SQUAD_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    SQUAD_CREW_STATE_BIN="$dir/fakebin/sq-crew-state.sh" \
    SQUAD_POLL=0.2 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
}

test_procevent_captured_result_surfaces_proactively() {
  local dir state out drain_out pid beacon_age
  dir=$(make_case procevent-delivery); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"
  grep -F "procevent sq-report delivery-src 1" "$state/.stand-to-queue" >/dev/null \
    || fail "the captured result was never published to the durable queue"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a healthy sentry never surfaced a durably captured process-event result: $(cat "$out")"
  grep -F "check:" "$out" >/dev/null \
    || fail "the process-event wake was not reported as an actionable check: $(cat "$out")"
  grep -F "procevent:delivery-src:1" "$out" >/dev/null \
    || fail "the actionable reason did not name the queued result: $(cat "$out")"
  beacon_age=$(SQUAD_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/sq-stand-to-lib.sh"; fm_path_age "$2"' _ "$ROOT" "$state/.last-sentry-beat")
  [ "$beacon_age" -lt 60 ] || fail "the surfacing sentry was not a healthy one (beacon age ${beacon_age}s)"

  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the process-event wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "procevent sq-report delivery-src 1" >/dev/null \
    || fail "the process-event result was not queued for the drain that follows the wake"
  pass "a captured process-event result wakes a healthy sentry proactively, with no manual drain"
}

test_procevent_surfaced_result_does_not_rewake() {
  local dir state out pid before after
  dir=$(make_case procevent-no-rewake); state="$dir/state"
  out="$dir/watch.out"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first proactive wake never happened: $(cat "$out")"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain after the first process-event wake failed"

  # Still unhandled: the result stays eligible for re-announcement on the durable
  # queue, but that must never produce a second proactive wake.
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  if ! wait_live "$pid" 40; then
    fail "an already-surfaced process-event result woke the sentry again: $(cat "$out")"
  fi
  reap "$pid"
  grep -F "procevent sq-report delivery-src 1" "$state/.stand-to-queue" >/dev/null \
    || fail "re-announcement of the unhandled result stopped when its wake was suppressed"

  pe_case "$dir" handled delivery-src 1 >/dev/null || fail "could not acknowledge the captured result"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain before the handled control failed"
  before=$(awk 'END { print NR + 0 }' "$state/.stand-to-queue" 2>/dev/null || echo 0)
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  if ! wait_live "$pid" 40; then
    fail "a handled process-event result woke the sentry: $(cat "$out")"
  fi
  reap "$pid"
  after=$(awk 'END { print NR + 0 }' "$state/.stand-to-queue" 2>/dev/null || echo 0)
  [ "$after" = "$before" ] || fail "a handled result was announced again ($before -> $after queued records)"
  pass "a process-event wake is delivered once: no duplicate wake while queued, and none once handled"
}

test_procevent_marker_keys_are_injective() {
  local dir state out pid marker_count
  dir=$(make_case procevent-marker-identity); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:a.b:1" "check: procevent fixture a.b 1"
  append_wake "$state" check "procevent:a_b:1" "check: procevent fixture a_b 1"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "colliding-looking process-event keys were not surfaced"
  grep -F "procevent:a.b:1" "$out" >/dev/null || fail "the dotted queue key was suppressed"
  grep -F "procevent:a_b:1" "$out" >/dev/null || fail "the underscored queue key was suppressed"
  marker_count=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | awk 'END { print NR + 0 }')
  [ "$marker_count" = 2 ] || fail "distinct queue keys produced $marker_count seen markers"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker identity fixture drain failed"
  pass "complete process-event queue keys map to distinct seen markers"
}

install_marker_mv_fault() {  # <dir>
  local dir=$1
  REAL_MV=$(command -v mv)
  export REAL_MV
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
dest=${!#}
case "$dest" in
  */.seen-procevent-*)
    case "${SQUAD_MARKER_MV_MODE:-}" in
      pause)
        printf '1\n' > "$SQUAD_MARKER_MV_READY"
        while [ ! -e "$SQUAD_MARKER_MV_RELEASE" ]; do sleep 0.02; done
        ;;
      kill-before) kill -KILL "$PPID"; exit 1 ;;
      kill-after) "$REAL_MV" "$@" || exit; kill -KILL "$PPID"; exit 1 ;;
      fail) exit 1 ;;
    esac
    ;;
esac
exec "$REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
}

test_procevent_surface_serializes_with_drain() {
  local dir state out drain_out ready release pid drain_pid
  dir=$(make_case procevent-drain-race); state="$dir/state"; out="$dir/watch.out"
  drain_out="$dir/drain.out"; ready="$dir/marker-ready"; release="$dir/marker-release"
  append_wake "$state" check "procevent:drain-race:1" "check: procevent fixture drain-race 1"
  install_marker_mv_fault "$dir"
  SQUAD_MARKER_MV_MODE=pause SQUAD_MARKER_MV_READY="$ready" SQUAD_MARKER_MV_RELEASE="$release" \
    procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_numeric_file "$ready" 100 || fail "the sentry never reached its marker commit boundary"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" &
  drain_pid=$!
  wait_live "$drain_pid" 10 || fail "a concurrent drain split the surfacing transition"
  [ -s "$state/.stand-to-queue" ] || fail "the concurrent drain consumed the record before marker commit"
  touch "$release"
  wait "$pid" || fail "the paused sentry did not finish surfacing"
  wait "$drain_pid" || fail "the concurrent drain failed after surfacing committed"
  grep -F "procevent:drain-race:1" "$drain_out" >/dev/null \
    || fail "the serialized drain lost the process-event record"
  pass "queue revalidation, proactive output, and marker commit serialize with drain"
}

test_procevent_surface_crash_boundaries() {
  local dir state out fifo pid reader marker exit_status
  dir=$(make_case procevent-output-fail); state="$dir/state"; out="$dir/watch.out"; fifo="$dir/output.fifo"
  append_wake "$state" check "procevent:output-fail:1" "check: procevent fixture output-fail 1"
  mkfifo "$fifo"
  sh -c ': < "$1"' _ "$fifo" & reader=$!
  PATH="$dir/fakebin:$PATH" SQUAD_BASE="$dir" SQUAD_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    SQUAD_CREW_STATE_BIN="$dir/fakebin/sq-crew-state.sh" SQUAD_POLL=0.2 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$fifo" &
  pid=$!
  wait "$reader" || true
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the sentry survived a failed actionable output write"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "failed output committed a suppression marker"
  [ -s "$state/.stand-to-queue" ] || fail "failed output consumed the durable queue record"
  procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "the record was not replayable after output failure"
  grep -F "procevent:output-fail:1" "$out" >/dev/null || fail "output failure lost proactive replay"

  dir=$(make_case procevent-before-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:before-marker:1" "check: procevent fixture before-marker 1"
  install_marker_mv_fault "$dir"
  SQUAD_MARKER_MV_MODE=kill-before procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the sentry survived the injected pre-marker crash"
  grep -F "procevent:before-marker:1" "$out" >/dev/null || fail "the pre-marker crash happened before output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "a pre-marker crash committed suppression"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 || fail "a pre-marker crash was not replayable"

  dir=$(make_case procevent-after-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:after-marker:1" "check: procevent fixture after-marker 1"
  install_marker_mv_fault "$dir"
  SQUAD_MARKER_MV_MODE=kill-after procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the sentry survived the injected post-marker crash"
  grep -F "procevent:after-marker:1" "$out" >/dev/null || fail "the post-marker crash lost actionable output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -n "$marker" ] || fail "the post-marker crash did not reach marker commit"
  : > "$out.replay"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  if ! wait_live "$pid" 40; then
    fail "a delivered and durably marked record woke again: $(cat "$out.replay")"
  fi
  reap "$pid"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "post-marker fixture drain failed"
  pass "surfacing failures replay before marker commit and suppress only after delivered output"
}

test_procevent_marker_failure_exits_and_replays() {
  local dir state out pid marker output_count
  dir=$(make_case procevent-marker-failure); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:marker-failure:1" "check: procevent fixture marker-failure 1"
  install_marker_mv_fault "$dir"
  SQUAD_MARKER_MV_MODE=fail procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not end the actionable sentry cycle successfully"
  output_count=$(grep -Fc "procevent:marker-failure:1" "$out" || true)
  [ "$output_count" = 1 ] || fail "marker failure printed the actionable reason $output_count times"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "marker failure committed suppression"
  [ ! -e "$state/.stand-to-queue.lock" ] && [ ! -L "$state/.stand-to-queue.lock" ] \
    || fail "marker failure left the queue lock held"
  procevent_watch_bg "$dir" "$out.replay"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not leave the durable record replayable"
  grep -F "procevent:marker-failure:1" "$out.replay" >/dev/null \
    || fail "marker failure lost the later proactive replay"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker-failure fixture drain failed"
  pass "marker failure exits through the shared wake owner, releases its lock, and replays later"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status --------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A truly quiet unit (no windows, no statuses) with a fast heartbeat cadence.
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "sentry exited for a no-change heartbeat (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.stand-to-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  reap "$pid"
  pass "a heartbeat with no commander-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A commander-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the heartbeat
  # unit-scan backstop must catch it and wake Squad.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  printf 'id=miss\n' > "$state/miss.meta"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" SQUAD_STATE_OVERRIDE="$state" SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat backstop did not surface an unsurfaced commander-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(cat "$state/.hb-surfaced-miss" 2>/dev/null || true)" = "done: PR https://example.test/pr/5" ] \
    || fail "backstop did not record the status as surfaced (would re-fire next heartbeat)"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the backstop heartbeat failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a commander-relevant status the per-wake path missed"
}

# --- beacon stays fresh while absorbing -------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  printf 'id=task\n' > "$state/task.meta"
  # Provably working so the working: notes are absorbed (the path that must keep the
  # beacon fresh).
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 15 || { reap "$pid"; fail "sentry exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-sentry-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_live "$pid" 20 || { reap "$pid"; fail "sentry exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-sentry-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "sentry beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  [ "$(( now - m2 ))" -lt 10 ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s)"; }
  [ ! -s "$state/.stand-to-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  pass "the liveness beacon stays fresh while the sentry absorbs benign wakes (sq-guard never false-alarms)"
}

# --- afk coherence: the daemon owns triage; the sentry does not double-triage ---

test_afk_present_reverts_sentry_to_one_shot() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  printf 'id=task\n' > "$state/task.meta"
  date '+%s' > "$state/.afk"   # away mode: the supervise-daemon owns triage
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test asserting
  # a surface therefore also proves afk reverts to one-shot and skips the costly read.
  export SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "with .afk present the sentry did not exit one-shot for a benign signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode sentry did not surface the signal for the daemon"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the afk-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  pass "with .afk present the sentry reverts to one-shot so the daemon owns triage (no double-triage)"
}

# A paused pane can first appear as a changed hash. In AFK mode that initial path
# must still hand off the plain window identity to the daemon, rather than running
# the normal-mode pause re-surface and decorating the stale identity.
test_afk_paused_changed_pane_hands_off_plain_stale() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid back
  dir=$(make_case afk-paused-changed-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:sq-afk-held"
  printf 'idle, awaiting upstream\n' > "$capture_file"
  printf 'window=%s\nkind=strike\n' "$window" > "$state/afk-held.meta"
  statusf="$state/afk-held.status"
  printf 'paused: awaiting the upstream tool release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-held_status"
  date '+%s' > "$state/.afk"
  key=$(printf '%s' "$window" | tr '.:/' '___')

  # Deliberately do not seed .hash-*: this is the changed-pane path that used to
  # call handle_paused_stale before AFK's one-shot daemon handoff.
  PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
    SQUAD_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
    SQUAD_STATE_OVERRIDE="$state" SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_PAUSE_RESURFACE_SECS=240 SQUAD_POLL=0.2 SQUAD_SIGNAL_GRACE=1 \
    SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "AFK paused changed pane did not hand off a stale wake"
  grep -F "stale: $window" "$out" >/dev/null || fail "AFK paused stale did not hand off its window identity: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "AFK sentry decorated a stale identity instead of handing it to the daemon"
  [ ! -e "$state/.paused-$key" ] || fail "AFK sentry recorded normal-mode pause tracking instead of handing off"
  SQUAD_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after AFK paused stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: $window" >/dev/null \
    || fail "AFK paused stale was not queued with the plain window identity"
  pass "AFK changed paused panes hand off plain stale identities for daemon-owned pause triage"
}

# The dirty clock is independent of both pane hashes and the pause cadence.
# Use real Git dirt, not a canned cleanliness verdict.
pause_watch_cwd=''
start_pause_watch() {  # <extra env assignments...>
  ( cd "${pause_watch_cwd:-.}" && exec env \
      PATH="$fakebin:$PATH" SQUAD_FAKE_TMUX_WINDOW="$window" SQUAD_FAKE_TMUX_CAPTURE="$capture_file" \
      SQUAD_FAKE_TMUX_CURRENT_COMMAND=zsh SQUAD_STATE_OVERRIDE="$state" \
      SQUAD_CREW_STATE_BIN="$fakebin/sq-crew-state.sh" SQUAD_FAKE_CREW_STATE='state: paused · source: status-log · external wait' \
      SQUAD_POLL=1 SQUAD_SIGNAL_GRACE=1 SQUAD_CHECK_INTERVAL=999999 SQUAD_HEARTBEAT=999999 \
      "$@" "$WATCH" ) >> "$out" &
  pid=$!
}

pause_worktree_case() {
  dir=$(make_case "$1"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:sq-held"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  wt="$dir/work tree"
  git init -q "$wt"
  printf 'window=%s\nkind=strike\nworktree=%s\n' "$window" "$wt" > "$state/held.meta"
  printf 'paused: waiting for upstream\n' > "$state/held.status"
  printf '%s' "$(seen_sig "$state/held.status")" > "$state/.seen-held_status"
  printf 'idle external wait' > "$capture_file"
  printf '%s' "$(hash_text 'idle external wait')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
}

test_idle_dirty_pause_escalates() {
  local dir state fakebin out capture_file window key wt pid i
  pause_worktree_case dirty-pause
  for i in 1 2 3 4 5 6; do printf 'base\n' > "$wt/tracked-$i"; done
  git -C "$wt" add .
  git -C "$wt" -c user.name=Test -c user.email=test@example.invalid commit -qm base
  for i in 1 2 3 4 5 6; do printf 'unfinished\n' >> "$wt/tracked-$i"; done
  i=1
  while [ "$i" -le 43 ]; do printf 'unfinished\n' > "$wt/untracked-$i"; i=$((i + 1)); done
  [ "$(git -C "$wt" status --porcelain | wc -l | tr -d ' ')" = 49 ] || fail "measured dirty fixture is not 6 modified + 43 untracked files"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=2
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "idle dirty declared pause never escalated"; }
  grep -F 'idle with uncommitted work' "$out" >/dev/null || fail "dirty pause lost its explicit reason: $(cat "$out")"
  grep -F 'idle with uncommitted work' "$state/.stand-to-queue" >/dev/null || fail "dirty stall was not durably queued"
  pass "idle uncommitted work escalates despite a fresh declared pause"
}

test_clean_fresh_pause_suppresses() {
  local dir state fakebin out capture_file window key wt pid
  pause_worktree_case clean-pause
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  wait_live "$pid" 35 || { reap "$pid"; fail "clean fresh pause escalated: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "clean pause printed a wake"
  pass "a clean fresh declared pause still suppresses stale alarms"
}

test_pause_ages_out_once_per_episode() {
  local dir state fakebin out capture_file window key wt pid round
  pause_worktree_case pause-age
  start_pause_watch env SQUAD_PAUSE_MAX_SECS=2
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "declared pause never aged out"; }
  grep -F 'declared pause aged out' "$out" >/dev/null || fail "pause age-out lost its explicit reason"
  grep -F 'confirm or clear' "$out" >/dev/null || fail "pause age-out did not request confirmation"
  # Restart and change the pane. Neither can renew an expired pause.
  printf 'idle external wait with a changed footer' > "$capture_file"
  start_pause_watch env SQUAD_PAUSE_MAX_SECS=2 SQUAD_PAUSE_RESURFACE_SECS=1
  wait_live "$pid" 35 || { reap "$pid"; fail "expired pause escalated again: $(cat "$out")"; }
  reap "$pid"
  [ "$(grep -c 'declared pause aged out' "$state/.stand-to-queue")" = 1 ] || fail "pause age-out was not one-shot"
  # An unrelated resolution does not renew the pause episode.
  printf 'resolved [key=other]: unrelated decision\n' >> "$state/held.status"
  printf '%s' "$(seen_sig "$state/held.status")" > "$state/.seen-held_status"
  start_pause_watch env SQUAD_PAUSE_MAX_SECS=2 SQUAD_PAUSE_RESURFACE_SECS=1
  wait_live "$pid" 25 || { reap "$pid"; fail "unrelated resolution renewed the pause"; }
  reap "$pid"
  # A fresh declaration, even with identical text, permits exactly one new alarm.
  for round in renewed cleared; do
    [ "$round" != cleared ] || printf 'working: resumed\n' >> "$state/held.status"
    printf 'paused: waiting for upstream\n' >> "$state/held.status"
    printf '%s' "$(seen_sig "$state/held.status")" > "$state/.seen-held_status"
    start_pause_watch env SQUAD_PAUSE_MAX_SECS=2
    wait_for_exit "$pid" 80 || { reap "$pid"; fail "$round pause never aged out"; }
  done
  [ "$(grep -c 'declared pause aged out' "$state/.stand-to-queue")" = 3 ] || fail "renewed/cleared pauses did not re-arm ageing"
  pass "pause ageing escalates once across restarts and footer changes, re-arming only on renewal or clearance"
}

test_dirty_pause_protections() {
  local dir state fakebin out capture_file window key wt pid mode
  for mode in busy run-step terminal clean; do
    pause_worktree_case "dirty-protected-$mode"
    printf 'unfinished\n' > "$wt/untracked"
    printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.dirty-since-$key"
    case "$mode" in
      busy)
        printf 'harness=pi\n' >> "$state/held.meta"
        record_pi_busy "$state" held
        start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1 SQUAD_PAUSE_MAX_SECS=0
        ;;
      run-step)
        start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1 SQUAD_PAUSE_MAX_SECS=0 \
          SQUAD_FAKE_CREW_STATE='state: working · source: run-step · validating'
        ;;
      terminal)
        printf 'done: finished\n' > "$state/held.status"
        printf '%s' "$(seen_sig "$state/held.status")" > "$state/.seen-held_status"
        start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1 SQUAD_FAKE_CREW_STATE='state: done · source: run-step · passed'
        ;;
      clean)
        rm "$wt/untracked"
        start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
        ;;
    esac
    wait_live "$pid" 25 || { reap "$pid"; fail "$mode did not defer dirty/pause escalation: $(cat "$out")"; }
    reap "$pid"
    [ ! -s "$out" ] || fail "$mode emitted an alarm"
    if [ "$mode" = run-step ]; then
      [ "$(cat "$state/.dirty-since-$key")" -gt "$(( $(date +%s) - 500 ))" ] || fail "active run did not defer the dirty timer"
    else
      [ ! -e "$state/.dirty-since-$key" ] || fail "$mode did not reset the dirty timer"
    fi
  done
  pass "busy, active run-step, terminal, and cleaned worktrees preserve their protections"
}

test_dirty_staged_pause_survives_footer_change() {
  local dir state fakebin out capture_file window key wt pid
  pause_worktree_case dirty-staged-footer
  printf 'staged unfinished work\n' > "$wt/staged"
  git -C "$wt" add .
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=240
  wait_numeric_file "$state/.dirty-since-$key" 40 || { reap "$pid"; fail "staged work did not start the dirty clock"; }
  reap "$pid"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.dirty-since-$key"
  printf 'idle external wait with a changed footer\n' > "$capture_file"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=240
  wait_for_exit "$pid" 40 || { reap "$pid"; fail "footer change or restart hid staged unfinished work"; }
  grep -F 'idle with uncommitted work' "$out" >/dev/null || fail "staged work lost the dirty reason"
  pass "staged unfinished work keeps its idle clock across a restart and changing footer"
}

test_pause_episode_classifier() {
  local dir state
  dir=$(make_case pause-episode-classifier); state="$dir/state"
  printf 'paused: upstream\nresolved: unrelated\n' > "$state/a.status"
  [ "$(status_pause_episode "$state/a.status")" = 1 ] || fail "resolution renewed pause identity"
  printf 'paused: upstream\n' >> "$state/a.status"
  [ "$(status_pause_episode "$state/a.status")" = 3 ] || fail "identical pause did not renew identity"
  printf 'working: resumed\n' >> "$state/a.status"
  [ -z "$(status_pause_episode "$state/a.status")" ] || fail "working did not clear pause identity"
  pass "pause identity renews on declarations, not resolutions, and clears on resumed work"
}

# The dirty clock must measure the task's recorded worktree. `git -C ""` does not
# fail: it silently adopts the sentry's own CWD, so an unrecorded worktree would
# read (and alarm on) an unrelated checkout.
test_dirty_check_requires_recorded_worktree() {
  local dir state fakebin out capture_file window key wt pid dirty mode
  for mode in missing empty; do
    pause_worktree_case "dirty-no-worktree-$mode"
    case "$mode" in
      missing) printf 'window=%s\nkind=strike\n' "$window" > "$state/held.meta" ;;
      empty)   printf 'window=%s\nkind=strike\nworktree=\n' "$window" > "$state/held.meta" ;;
    esac
    dirty="$dir/unrelated-checkout"
    git init -q "$dirty"
    printf 'unrelated uncommitted work\n' > "$dirty/stray"
    printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.dirty-since-$key"
    pause_watch_cwd="$dirty"
    start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
    wait_live "$pid" 30 || { reap "$pid"; pause_watch_cwd=''; fail "$mode worktree alarmed on the sentry CWD: $(cat "$out")"; }
    reap "$pid"
    pause_watch_cwd=''
    [ ! -s "$out" ] || fail "$mode worktree emitted a wake from an unrelated checkout"
    [ ! -e "$state/.dirty-since-$key" ] || fail "$mode worktree kept a dirty clock for an unrecorded tree"
  done
  pass "a missing or empty recorded worktree never reads the sentry's own checkout"
}

# A failed Git read is cannot-evaluate: it must not be reported as a clean tree,
# and it must not discard or monopolize an idle-dirty clock already measuring
# known work: away mode still gets its plain handoff.
test_failed_dirty_read_is_cannot_evaluate() {
  local dir state fakebin out capture_file window key wt pid old real_git polls
  pause_worktree_case dirty-read-failure
  printf 'unfinished\n' > "$wt/untracked"
  old=$(( $(date +%s) - 500 ))
  printf '%s\n' "$old" > "$state/.dirty-since-$key"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = status ]; then
    printf 'fatal: simulated git status failure\n' >&2
    exit 1
  fi
done
exec "$real_git" "\$@"
SH
  chmod +x "$fakebin/git"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  polls=0
  while [ "$polls" -lt 60 ]; do
    case "$(cat "$state/.count-$key" 2>/dev/null || true)" in
      ''|*[!0-9]*) ;;
      *) [ "$(cat "$state/.count-$key")" -ge 3 ] && break ;;
    esac
    sleep 0.1
    polls=$((polls + 1))
  done
  reap "$pid"
  [ ! -s "$out" ] || fail "an unreadable worktree emitted a wake: $(cat "$out")"
  [ "$(cat "$state/.dirty-since-$key" 2>/dev/null || true)" = "$old" ] \
    || fail "a failed git read reset the idle-dirty clock instead of keeping it"
  grep -F 'cannot evaluate worktree status' "$state/.sentry-triage.log" >/dev/null \
    || fail "a failed git read was not reported as cannot-evaluate"
  [ "$(grep -cF 'cannot evaluate worktree status' "$state/.sentry-triage.log")" = 1 ] \
    || fail "a persistently unreadable worktree flooded the triage log: $(grep -F 'cannot evaluate worktree status' "$state/.sentry-triage.log")"
  [ -e "$state/.dirty-unreadable-$key" ] || fail "a failed git read did not record cannot-evaluate"

  date '+%s' > "$state/.afk"
  : > "$out"
  rm -f "$state/.stale-$key" "$state/.stale-since-$key" "$state/.hash-$key" "$state/.count-$key"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "an unreadable dirty clock suppressed the away-mode handoff: $(cat "$out")"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "away mode did not hand off the window identity"
  grep -F 'operator idle with uncommitted work' "$out" >/dev/null \
    && fail "away mode escalated dirty work without a readable worktree: $(cat "$out")"
  grep -F 'deferred plain handoff' "$out" >/dev/null \
    && fail "the unreadable dirty clock still claimed pause-era ownership: $(cat "$out")"
  [ "$(cat "$state/.dirty-since-$key" 2>/dev/null || true)" = "$old" ] \
    || fail "the away-mode handoff disturbed the preserved dirty clock"
  [ "$(grep -cF 'cannot evaluate worktree status' "$state/.sentry-triage.log")" = 1 ] \
    || fail "the away-mode poll repeated the cannot-evaluate worktree log"

  rm -f "$fakebin/git"
  : > "$out"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=240
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "a recovered worktree read did not resume the preserved dirty clock: $(cat "$out")"; }
  grep -F 'operator idle with uncommitted work' "$out" >/dev/null \
    || fail "a recovered worktree read lost the preserved dirty clock: $(cat "$out")"
  [ "$(cat "$state/.dirty-since-$key")" = reported ] || fail "the recovered dirty episode did not close"
  [ ! -e "$state/.dirty-unreadable-$key" ] || fail "a recovered worktree read left cannot-evaluate state behind"
  pass "a failed worktree read is cannot-evaluate, yields the plain away handoff, and resumes its preserved clock"
}

# A pane that keeps reporting busy must not swallow the pause: once a pause has
# aged out, a busy pane defers to the existing pause cadence instead of being
# left with no supervision at all.
test_aged_out_pause_keeps_busy_pane_supervised() {
  local dir state fakebin out capture_file window key wt pid
  pause_worktree_case aged-out-busy
  set_mtime $(( $(date +%s) - 500 )) "$state/held.status"
  printf '%s' "$(seen_sig "$state/held.status")" > "$state/.seen-held_status"
  printf 'harness=pi\n' >> "$state/held.meta"
  record_pi_busy "$state" held
  start_pause_watch env SQUAD_PAUSE_MAX_SECS=0 SQUAD_PAUSE_RESURFACE_SECS=1
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "an aged-out pause on a busy pane lost its pause recheck"; }
  grep -F 'rechecked on a long cadence' "$out" >/dev/null || fail "busy pane did not fall back to the pause cadence: $(cat "$out")"
  grep -F 'declared pause aged out' "$out" >/dev/null && fail "a busy pane was reported as an aged-out stall"
  pass "an aged-out pause on a busy pane defers to the pause cadence instead of going unsupervised"
}

# An unreadable status mtime must not be aged from epoch 0, which would report a
# brand-new pause as aged out immediately with a nonsense age.
test_unreadable_pause_mtime_does_not_age_out() {
  local dir state fakebin out capture_file window key pid real_stat since
  pause_worktree_case pause-mtime-unreadable
  real_stat=$(command -v stat)
  cat > "$fakebin/stat" <<SH
#!/usr/bin/env bash
real=\${REAL_STAT_FOR_TEST:?}
case "\${1:-}:\${2:-}" in
  -c:%Y|-f:%m)
    for arg in "\$@"; do
      [ "\$arg" = "\$STAT_MTIME_FAIL_FILE" ] && { echo 'stat: simulated failure' >&2; exit 1; }
    done
    ;;
esac
exec "\$real" "\$@"
SH
  chmod +x "$fakebin/stat"
  start_pause_watch env REAL_STAT_FOR_TEST="$real_stat" STAT_MTIME_FAIL_FILE="$state/held.status"
  wait_live "$pid" 60 || { reap "$pid"; fail "an unreadable status mtime instantly aged out a fresh pause: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "unreadable status mtime emitted a wake: $(cat "$out")"
  since=$(awk '{ print $2 }' "$state/.pause-episode-$key" 2>/dev/null)
  [ "${since:-0}" -ge "$(( $(date +%s) - 60 ))" ] || fail "pause age was anchored on an unreadable mtime: $since"
  pass "a fresh pause with an unreadable status mtime is aged from now, not epoch 0"
}

# Away mode must not absorb the pause-era escalations. The sentry hands the named
# evidence to the daemon as a routine stale reason (the daemon persists/escalates
# it), and one dirty episode hands off exactly once even when the footer churns.
test_away_dirty_work_hands_off_evidence_once() {
  local dir state fakebin out capture_file window key wt pid deferred_before
  pause_worktree_case away-dirty-handoff
  printf 'unfinished\n' > "$wt/untracked"
  date '+%s' > "$state/.afk"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "away idle dirty work never handed off: $(cat "$out")"; }
  grep -F "routine: stale: $window (operator idle with uncommitted work" "$out" >/dev/null \
    || fail "away dirty handoff was not a daemon-classifiable routine stale naming the dirt: $(cat "$out")"
  [ "$(grep -c 'operator idle with uncommitted work' "$state/.stand-to-queue")" = 1 ] \
    || fail "away dirty handoff was not queued exactly once"
  [ "$(cat "$state/.dirty-since-$key")" = reported ] || fail "away dirty handoff did not mark its episode"

  : > "$out"
  printf 'idle external wait with a changed footer' > "$capture_file"
  deferred_before=$(grep -c 'deferred plain handoff' "$state/.sentry-triage.log" 2>/dev/null || true)
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  wait_live "$pid" 30 || { reap "$pid"; fail "away dirty episode re-escalated after a footer change: $(cat "$out")"; }
  reap "$pid"
  grep -F 'operator idle with uncommitted work' "$out" >/dev/null \
    && fail "away dirty episode re-escalated after a footer change: $(cat "$out")"
  [ "$(( $(grep -c 'deferred plain handoff' "$state/.sentry-triage.log" 2>/dev/null || true) - ${deferred_before:-0} ))" = 1 ] \
    || fail "away mode repeated the deferred-handoff log on every poll: $(cat "$state/.sentry-triage.log")"
  [ "$(grep -c 'operator idle with uncommitted work' "$state/.stand-to-queue")" = 1 ] \
    || fail "away dirty work escalated twice for one episode"
  pass "away idle dirty work hands off its evidence exactly once per episode"
}

# A clean worktree with a fresh declared pause must stay quiet in away mode too:
# the handoff the daemon receives carries no dirty or aged-pause evidence.
test_away_clean_fresh_pause_stays_quiet() {
  local dir state fakebin out capture_file window key wt pid
  pause_worktree_case away-clean-pause
  date '+%s' > "$state/.afk"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "away clean pause never reached the daemon's plain handoff: $(cat "$out")"; }
  grep -F "stale: $window" "$out" >/dev/null || fail "away clean pause did not hand off the pane identity"
  grep -F 'operator idle with uncommitted work' "$out" >/dev/null && fail "away clean pause raised a dirty-work escalation"
  grep -F 'declared pause aged out' "$out" >/dev/null && fail "away fresh pause raised an age-out escalation"
  [ "$(grep -c 'operator idle with uncommitted work\|declared pause aged out' "$state/.stand-to-queue" 2>/dev/null || true)" = 0 ] \
    || fail "away clean pause queued a pause-era escalation"
  [ ! -e "$state/.dirty-since-$key" ] || fail "away clean pause started a dirty clock"
  pass "away mode keeps a clean fresh declared pause free of pause-era escalations"
}

# The complete rendered pane is the third rule's evidence. A byte-identical pane
# that keeps showing a compaction banner escalates even under a declared pause and
# names the banner text plus the rendered hash it was read from.
test_static_compaction_signature_escalates() {
  local dir state fakebin out capture_file window key wt pid
  pause_worktree_case pane-signature-compaction
  printf '✻ Compacting conversation… (esc to interrupt)\n' > "$capture_file"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "a stuck compaction banner never escalated: $(cat "$out")"; }
  grep -F 'pane signature: compaction-banner' "$out" >/dev/null \
    || fail "the stuck pane was not escalated as a pane signature: $(cat "$out")"
  grep -F 'Compacting conversation' "$out" >/dev/null \
    || fail "the escalation did not name the observed compaction banner"
  grep -F 'declared pause aged out' "$out" >/dev/null && fail "a stuck pane was reported as an aged-out pause"
  pass "a static compaction banner escalates as a named pane signature despite a declared pause"
}

# Away mode must escalate the pane signature itself, not pre-empt it with a plain
# window identity: the daemon can only deliver the evidence the reason carries.
test_away_static_compaction_hands_off_signature() {
  local dir state fakebin out capture_file window key wt pid
  pause_worktree_case away-pane-signature
  printf '✻ Compacting conversation… (esc to interrupt)\n' > "$capture_file"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  date '+%s' > "$state/.afk"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "away stuck pane never handed off its signature: $(cat "$out")"; }
  grep -F "routine: stale: $window (pane signature: compaction-banner" "$out" >/dev/null \
    || fail "away mode pre-empted the signature evidence with a plain identity: $(cat "$out")"
  [ "$(grep -c 'pane signature' "$state/.stand-to-queue")" = 1 ] \
    || fail "away signature handoff was not queued exactly once"
  pass "away mode hands off a stuck pane signature exactly once instead of a plain identity"
}

# Changing output is progress, not a signature: a churning pane never enters the
# rule, and a pre-existing signature clock is restarted by any changed byte.
test_changing_pane_signature_never_alarms() {
  local dir state fakebin out capture_file window key wt pid before
  pause_worktree_case pane-signature-churning
  mv "$fakebin/tmux" "$fakebin/tmux-original"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ]; then
  counter="$(dirname "$0")/captures"
  n=$(cat "$counter" 2>/dev/null || printf '0')
  n=$((n + 1))
  printf '%s\n' "$n" > "$counter"
  printf 'Compacting conversation… elapsed-%s\n' "$n"
  exit 0
fi
exec "$(dirname "$0")/tmux-original" "$@"
SH
  chmod +x "$fakebin/tmux"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  wait_live "$pid" 30 || { reap "$pid"; fail "a changing pane with a compaction banner alarmed: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "changing pane output raised a wake: $(cat "$out")"
  [ ! -e "$state/.sig-reported-$key" ] || fail "changing output was reported as a stuck signature"

  pause_worktree_case pane-signature-reset
  printf '✻ Compacting conversation… (esc to interrupt)\n' > "$capture_file"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '%s' "$(hash_text 'an older, different viewport')" > "$state/.sig-hash-$key"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.sig-since-$key"
  before=$(date +%s)
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=30
  wait_live "$pid" 30 || { reap "$pid"; fail "a changed viewport reused the prior signature clock: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "a changed viewport escalated on the prior signature clock: $(cat "$out")"
  [ "$(cat "$state/.sig-since-$key")" -ge "$before" ] || fail "a changed viewport did not restart the signature clock"
  pass "changing pane output never alarms and restarts a sticky signature clock"
}

# A backend without a readable complete viewport must say cannot-evaluate: never
# proof of progress, never a false all-clear, and never an invented stall verdict.
test_unreadable_pane_signature_is_cannot_evaluate() {
  local dir state fakebin out capture_file window key wt pid
  pause_worktree_case pane-signature-unreadable
  mv "$fakebin/tmux" "$fakebin/tmux-original"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ]; then
  has_p=0; has_s=0
  for arg in "$@"; do
    [ "$arg" = -p ] && has_p=1
    [ "$arg" = -S ] && has_s=1
  done
  [ "$has_p" = 1 ] && [ "$has_s" = 0 ] && exit 1
fi
exec "$(dirname "$0")/tmux-original" "$@"
SH
  chmod +x "$fakebin/tmux"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  wait_live "$pid" 40 || { reap "$pid"; fail "an unreadable viewport was escalated as a stall: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "an unreadable viewport emitted a wake: $(cat "$out")"
  [ "$(grep -c 'cannot evaluate pane signature' "$state/.sentry-triage.log" 2>/dev/null || true)" = 1 ] \
    || fail "the unreadable viewport did not log cannot-evaluate exactly once: $(cat "$state/.sentry-triage.log" 2>/dev/null || true)"
  [ ! -e "$state/.sig-hash-$key" ] || fail "an unreadable viewport advanced the signature clock"
  [ ! -e "$state/.sig-reported-$key" ] || fail "an unreadable viewport produced a stall verdict"
  pass "an unreadable pane is reported as cannot-evaluate instead of a verdict"
}

# Quoted error vocabulary in scrollback is not an active provider dialog.
# The pause still expires normally, but must not become a 240-second error alarm.
test_paused_scrollback_error_stays_quiet_until_age_out() {
  local dir state fakebin out capture_file window key wt pid i
  pause_worktree_case paused-scrollback-error
  use_tail_aware_tmux "$fakebin"
  {
    printf 'Earlier notes discuss rate limit handling, not a live error.\n'
    for i in {1..50}; do printf 'Completed log entry %s\n' "$i"; done
    printf 'Waiting for the upstream release.\n> \n'
  } > "$capture_file"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1 SQUAD_PAUSE_MAX_SECS=240
  wait_live "$pid" 50 || { reap "$pid"; fail "scrollback prose interrupted a fresh pause: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "scrollback prose emitted a wake: $(cat "$out")"
  [ ! -s "$state/.stand-to-queue" ] || fail "scrollback prose queued an alarm"
  printf '1 %s 0\n' "$(( $(date +%s) - 500 ))" > "$state/.pause-episode-$key"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1 SQUAD_PAUSE_MAX_SECS=240
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "scrollback fixture never reached pause age-out"; }
  grep -F 'declared pause aged out' "$out" >/dev/null || fail "scrollback pause did not age out normally: $(cat "$out")"
  grep -F 'pane signature:' "$out" >/dev/null && fail "scrollback prose was escalated as a dialog"
  pass "a paused wait ignores rate-limit prose in scrollback until its pause ages out"
}

# Expiring a pause suppresses only that pause's cadence, not independent evidence
# from a real dialog which appears later in the task's rendered endpoint.
test_error_dialog_after_pause_age_out_escalates() {
  local dir state fakebin out capture_file window key wt pid
  pause_worktree_case dialog-after-pause-age-out
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1 SQUAD_PAUSE_MAX_SECS=1
  wait_for_exit "$pid" 80 || { reap "$pid"; fail "fixture pause did not age out"; }
  grep -F 'declared pause aged out' "$out" >/dev/null || fail "fixture did not record a pause age-out"
  : > "$out"
  printf 'API error: rate limit exceeded\n[r] Retry request  [q] Dismiss\n' > "$capture_file"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1 SQUAD_PAUSE_MAX_SECS=1 SQUAD_PAUSE_RESURFACE_SECS=1
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "an aged-out pause hid a later real dialog: $(cat "$out")"; }
  grep -F 'pane signature: error-dialog' "$out" >/dev/null || fail "later dialog did not name its signature: $(cat "$out")"
  grep -F 'API error: rate limit exceeded' "$out" >/dev/null || fail "later dialog omitted observed error text"
  [ "$(grep -c 'declared pause aged out' "$state/.stand-to-queue")" = 1 ] || fail "dialog observation repeated the pause age-out"
  pass "a real error dialog after pause age-out still escalates with its observed signature"
}

# The composer deferral is a standing state, not an event: an idle pane that
# holds pending input keeps the same signature and hash while away mode keeps
# polling, so the note must name it once per episode instead of rotating the
# bounded triage log every poll.
test_composer_deferral_logged_once_per_signature() {
  local dir state fakebin out capture_file window key wt pid
  pause_worktree_case composer-deferral-throttle
  printf '✻ Compacting conversation… (esc to interrupt)\n' > "$capture_file"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.sig-hash-$key"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.sig-since-$key"
  printf '╭────────────╮\n│ draft msg  │\n╰────────────╯\n' > "$fakebin/composer.txt"
  mv "$fakebin/tmux" "$fakebin/tmux-original"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
dir=$(dirname "$0")
case "${1:-}" in
  list-windows)
    if [ -n "${SQUAD_FAKE_TMUX_WINDOW:-}" ]; then printf '%s\n' "${SQUAD_FAKE_TMUX_WINDOW#*:}"; fi
    exit 0 ;;
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '2\n'; exit 0 ;;
      *pane_current_command*) printf '%s\n' "${SQUAD_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
    esac
    exit 1 ;;
  capture-pane)
    for arg in "$@"; do
      if [ "$arg" = -e ]; then cat "$dir/composer.txt"; exit 0; fi
    done
    cat "$SQUAD_FAKE_TMUX_CAPTURE"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=1
  wait_live "$pid" 60 || { reap "$pid"; fail "a pane holding composer input escalated: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "a pane holding composer input raised a wake: $(cat "$out")"
  [ "$(grep -c 'deferred pane signature (compaction-banner' "$state/.sentry-triage.log" 2>/dev/null || true)" = 1 ] \
    || fail "the composer deferral logged once per poll instead of once per signature: $(cat "$state/.sentry-triage.log" 2>/dev/null || true)"
  pass "composer deferral logging is one line per signature episode"
}

# A deferral holds the signature clock. Both the run-step and the finished-crew
# deferrals restart it, and so must an idle pane holding pending composer input:
# otherwise, once the pane has been static past the escalation window, every poll
# re-runs the crew-state reads (window_run_step_active plus operator_is_finished,
# each of which can issue a bounded drill call) plus the composer read for the
# whole episode.
test_composer_deferral_holds_the_signature_clock() {
  local dir state fakebin out capture_file window key wt pid reads
  pause_worktree_case composer-deferral-clock
  printf '✻ Compacting conversation… (esc to interrupt)\n' > "$capture_file"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.sig-hash-$key"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$state/.sig-since-$key"
  printf '╭────────────╮\n│ draft msg  │\n╰────────────╯\n' > "$fakebin/composer.txt"
  mv "$fakebin/tmux" "$fakebin/tmux-original"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
dir=$(dirname "$0")
case "${1:-}" in
  list-windows)
    if [ -n "${SQUAD_FAKE_TMUX_WINDOW:-}" ]; then printf '%s\n' "${SQUAD_FAKE_TMUX_WINDOW#*:}"; fi
    exit 0 ;;
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '2\n'; exit 0 ;;
      *pane_current_command*) printf '%s\n' "${SQUAD_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
    esac
    exit 1 ;;
  capture-pane)
    for arg in "$@"; do
      if [ "$arg" = -e ]; then cat "$dir/composer.txt"; exit 0; fi
    done
    cat "$SQUAD_FAKE_TMUX_CAPTURE"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  mv "$fakebin/sq-crew-state.sh" "$fakebin/sq-crew-state-real.sh"
  cat > "$fakebin/sq-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'read\n' >> "$(dirname "$0")/crew-reads"
exec "$(dirname "$0")/sq-crew-state-real.sh" "$@"
SH
  chmod +x "$fakebin/sq-crew-state.sh"
  start_pause_watch env SQUAD_STALE_ESCALATE_SECS=30
  wait_live "$pid" 200 || { reap "$pid"; fail "a pane holding composer input escalated: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "a pane holding composer input raised a wake: $(cat "$out")"
  reads=$(wc -l < "$fakebin/crew-reads" 2>/dev/null || printf '0')
  [ "${reads:-0}" -le 8 ] \
    || fail "the composer deferral re-read crew state on every poll (${reads} reads in ~200 polls): $(cat "$state/.sentry-triage.log" 2>/dev/null || true)"
  pass "a deferred composer signature holds its clock instead of re-reading crew state every poll"
}

test_error_dialog_requires_bottom_affordance() {
  local dialog sig
  dialog=$(printf 'API error: rate limit exceeded\n[r] Retry request  [q] Dismiss\n')
  sig=$(printf '%s\n' "$dialog" | pane_signature_classify)
  case "$sig" in error-dialog\|*) ;; *) fail "active retry dialog was not classified: $sig" ;; esac
  sig=$(printf 'API error: rate limit exceeded\nWaiting for upstream.\n' | pane_signature_classify)
  [ -z "$sig" ] || fail "bare error words without dialog controls were classified: $sig"
  sig=$(printf 'We documented rate limit handling.\n[r] Retry request\n' | pane_signature_classify)
  [ -z "$sig" ] || fail "ordinary prose next to a retry control became an error dialog: $sig"
  sig=$({ printf '%s\n' "$dialog"; printf '\n%.0s' {1..20}; printf 'Waiting for upstream.\n'; } | pane_signature_classify)
  [ -z "$sig" ] || fail "old dialog above blank viewport space became a bottom-region dialog: $sig"
  pass "built-in error dialogs require a message and active retry affordance in the bottom viewport region"
}

test_error_dialog_requires_bottom_affordance
test_paused_scrollback_error_stays_quiet_until_age_out
test_error_dialog_after_pause_age_out_escalates

test_idle_dirty_pause_escalates
test_dirty_staged_pause_survives_footer_change
test_pause_episode_classifier
test_dirty_check_requires_recorded_worktree
test_failed_dirty_read_is_cannot_evaluate
test_aged_out_pause_keeps_busy_pane_supervised
test_unreadable_pause_mtime_does_not_age_out
test_away_dirty_work_hands_off_evidence_once
test_away_clean_fresh_pause_stays_quiet
test_away_static_compaction_hands_off_signature
test_static_compaction_signature_escalates
test_changing_pane_signature_never_alarms
test_unreadable_pane_signature_is_cannot_evaluate
test_composer_deferral_logged_once_per_signature
test_composer_deferral_holds_the_signature_clock
test_dirty_pause_protections
test_clean_fresh_pause_suppresses
test_pause_ages_out_once_per_episode
test_signal_reason_is_actionable_classifier
test_stale_is_terminal_classifier
test_scan_commander_relevant_statuses_classifier
test_classifier_primitives
test_operator_is_provably_working_classifier
test_status_is_paused_classifier
test_operator_absorb_class_classifier
test_signal_operator_provably_working_classifier
test_signal_operator_is_paused_classifier
test_compaction_silent_reason_classifier
test_compaction_mark_notified_does_not_advance_non_matching_tasks
test_paused_signal_absorbed
test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_orphan_turn_ended_dropped
test_orphan_signal_dropped_inside_grace
test_turn_ended_compaction_without_status_surfaced
test_turn_ended_compaction_too_young_absorbed
test_turn_ended_compaction_event_mismatch_absorbed
test_working_note_not_working_surfaced
test_actionable_signal_surfaced
test_terminal_stale_surfaced
test_finished_stale_is_absorbed
test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_pipeline_step_quiet_activity
test_wedge_timer_deferred_while_run_step_active
test_wedge_timer_escalates_without_active_step
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_teardown_drops_target_and_wedge_counter
test_busy_static_pane_escalates_without_turn_age
test_busy_changing_pane_resets_expiry
test_busy_tall_pane_above_tail_progress_resets_expiry
test_busy_static_afk_hands_off_once_per_hash
test_busy_static_afk_run_step_defers_handoff
test_busy_static_to_idle_surfaces_without_busy_timer_delay
test_busy_static_pane_defers_while_run_step_active
test_busy_pane_repeated_escalation_reaches_demand_deep_inspection
test_busy_static_pane_without_readable_viewport_never_expires
test_busy_static_unreadable_viewport_logs_limitation_once
test_released_agentless_window_skips_stale_but_resumes_when_agent_returns
test_terminal_agentless_notice_surfaces_once_then_stays_quiet
test_terminal_stale_skip_retires_signal_signatures_after_quiet_scan
test_released_record_with_live_run_keeps_stale_supervision
test_agentless_window_with_unretired_terminal_execution_skips_stale
test_terminal_projection_is_memoized_per_task_generation
test_signal_scan_and_window_pass_share_terminal_memo
test_agentless_window_without_dispatch_sidecar_uses_terminal_projection
test_unretired_running_record_with_stale_busy_claim_skips_stale
test_busy_static_finished_task_is_absorbed_without_alarm
test_busy_static_done_status_never_masks_active_run
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_decision_parked_stale_is_throttled
test_live_paused_churning_pane_is_throttled
test_paused_busy_pane_without_run_step_does_not_override_pause
test_paused_busy_churning_pane_surfaces_first_recheck
test_paused_busy_churning_pane_rearms_long_cadence
test_busy_pane_without_declared_pause_still_escalates
test_paused_busy_pane_with_static_output_does_not_wedge
test_busy_pane_static_without_pause_still_wedges
test_exited_declared_pause_is_bounded_but_live_gate_surfaces
test_XO_paused_resurfaces_in_normal_mode
test_XO_nonpaused_stale_remains_suppressed
test_XO_unpause_clears_pause_tracking
test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
test_nonterminal_paused_rechecks_authoritative_state
test_paused_authoritative_working_preserves_wedge_timer
test_nonterminal_stale_repairs_missing_or_corrupt_timer
test_triage_log_size_cap_accepts_spaced_wc_counts
test_procevent_captured_result_surfaces_proactively
test_procevent_surfaced_result_does_not_rewake
test_procevent_marker_keys_are_injective
test_procevent_surface_serializes_with_drain
test_procevent_surface_crash_boundaries
test_procevent_marker_failure_exits_and_replays
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_beacon_stays_fresh_while_absorbing
test_afk_present_reverts_sentry_to_one_shot
test_afk_paused_changed_pane_hands_off_plain_stale
test_paused_churning_pane_throttle_refreshes_marker
test_tuios_blocked_pane_wakes_via_poll_transition
test_tuios_blocked_pane_dedupes_then_rearms_on_change_or_unblock
test_tuios_ambiguous_read_after_escalation_skips_stale
test_orca_blocked_prompt_wakes_exact_terminal_then_dedupes
test_tmux_pane_with_prompt_like_text_never_fakes_a_blocked_wake
