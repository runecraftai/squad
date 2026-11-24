#!/usr/bin/env bash
# sq-queue-pilot.sh - the opt-in away queue pilot: dispatch exactly one
# pre-approved backlog task, once, while the commander is away, and do nothing
# else.
#
# Why this exists: the away-mode daemon absorbs wakes and decides nothing, so
# without an awake Squad turn a notification never becomes work - two absences
# ended with a green PR unmerged and the next planned task never dispatched.
# The design is the queue-executor recon report recorded on that task. This
# script is only its dispatch-once slice.
#
# Usage:
#   sq-queue-pilot.sh arm --task <id> --project <abs-path> --repo <name> \
#                         --mode <drill|direct-PR> --yolo <on|off> \
#                         --harness <name> [--model <name>] [--effort <level>] \
#                         --max-missions <n> --expires <epoch-seconds> \
#                         --authority "<the commander's quoted instruction>"
#   sq-queue-pilot.sh check
#   sq-queue-pilot.sh status
#   sq-queue-pilot.sh revoke
#
# arm    Prepare the grant for the ONE task the commander approved before
#        departure. It refuses unless exactly one absence record is open, that
#        record names the exact task id, and the task's brief already carries the
#        same delivery contract. It never creates, edits, completes or holds a
#        backlog task: filing the task stays ordinary Squad intake.
# check  Run one admission. It inspects, then either refuses or launches that one
#        task through bin/sq-spawn.sh, and prints exactly one outcome line for the
#        away-mode ledger ("routine|<text>", or "escalation|<text>" when the
#        launch outcome needs reconciliation). Silent when no grant is armed.
# status Print one read-only machine-readable state line.
# revoke Mark the grant revoked. A revoked grant never launches again.
#
# Grant and intent schema (state/queue-pilot.grant, state/queue-pilot.intent):
# docs/configuration.md "Away queue pilot" owns the field list. The intent is
# written BEFORE any effect and is never removed, so a repeated trigger always
# finds it spent; nothing here relaunches, retries or repairs an attempt.
#
# Authority is exact and positive: one open absence record, one recorded grant,
# one named ready task, one spend-free intent. Anything missing, ambiguous,
# contradictory or unreadable means no action, with the reason recorded once.
# This script has no code path that merges, registers, closes or holds a task,
# steers a worker, decides a gate finding, forces anything, or dispatches a
# second id: the only effect it can have is one bin/sq-spawn.sh invocation.
#
# Refusal reasons, each one stable line (a changed reason is recorded once; an
# unchanged repeat is not):
#   no-grant | grant-malformed | grant-revoked | grant-expired | away-mode-off
#   no-open-absence-record | multiple-open-absence-records | mode-unsupported
#   absence-record-mismatch | absence-generation-mismatch | return-in-progress
#   task-not-named-in-absence-record | brief-missing | brief-mode-mismatch
#   brief-drift | project-unresolvable | backlog-not-compatible
#   backlog-ready-contract | not-in-backlog | not-ready | not-queued
#   blockers-uncleared | predecessor-missing | held | intent-spent
#   target-not-virgin | census-ambiguous | mission-cap | low-memory
#   memory-unknown | prompt-budget | intent-unwritable | launch-failed
#   delivery-unverified | start-unrecorded
#
# Test seams, never set in production: SQUAD_QUEUE_PILOT_SPAWN overrides the
# spawn command, SQUAD_QUEUE_PILOT_AVAILABLE_MB overrides the host memory sample,
# and SQUAD_QUEUE_PILOT_AGENT_STATE overrides the described endpoint agent state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"
DATA="${SQUAD_DATA_OVERRIDE:-$SQUAD_BASE/data}"
GRANT="$STATE/queue-pilot.grant"
INTENT="$STATE/queue-pilot.intent"
REASON="$STATE/.queue-pilot-reason"
LOCK="$STATE/queue-pilot.lock"
SPAWN="${SQUAD_QUEUE_PILOT_SPAWN:-$SCRIPT_DIR/sq-spawn.sh}"
GRANT_VERSION=1
# Memory floor in MiB of free(1) "available" memory, per occupied slot. The
# three-mission ceiling is the commander's recorded limit: slot 4 is never
# eligible, and the third mission needs the largest recorded floor.
SLOT1_MB=4096
SLOT3_MB=9216
MAX_SLOTS=3

# shellcheck source=bin/sq-backend.sh
. "$SCRIPT_DIR/sq-backend.sh"
# shellcheck source=bin/sq-tasks-lib.sh
. "$SCRIPT_DIR/sq-tasks-lib.sh"

usage() {
  cat <<'EOF'
usage: sq-queue-pilot.sh <command>

  arm --task <id> --project <abs-path> --repo <name> --mode <drill|direct-PR>
      --yolo <on|off> --harness <name> [--model <name>] [--effort <level>]
      --max-missions <1..3> --expires <epoch-seconds> --authority "<quote>"
        Prepare the grant for the one task the commander approved before
        departure. Requires exactly one open absence record naming that id.
  check   Run one admission: inspect, then refuse or launch that one task once.
  status  Print the read-only grant, intent and last-refusal state.
  revoke  Mark the grant revoked so it can never launch again.

A check prints one away-mode ledger line ("routine|..." or "escalation|...")
and is silent when no grant is armed. docs/configuration.md "Away queue pilot"
owns the grant and intent schema; this script's header owns the admission
sequence and the refusal vocabulary.
EOF
}

die() {
  printf 'sq-queue-pilot: %s\n' "$*" >&2
  exit 2
}

now() { date +%s; }

sha256_of() {  # <path>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    return 1
  fi
}

grant_get() {  # <key>
  grep -m1 "^$1=" "$GRANT" 2>/dev/null | cut -d= -f2- || true
}

intent_get() {  # <key>
  grep -m1 "^$1=" "$INTENT" 2>/dev/null | cut -d= -f2- || true
}

# --- the outcome line ------------------------------------------------------
# Every check with something to say prints exactly one ledger line. The caller
# (the away-mode daemon) appends it to its own ledger buffer, so this script
# never writes the daemon's buffers itself.
say() {  # <routine|escalation> <text>
  printf '%s|queue-pilot: %s\n' "$1" "$2"
}

refuse() {  # <reason-line>
  local line=$1 last=""
  [ -f "$REASON" ] && last=$(cat "$REASON" 2>/dev/null || true)
  printf '%s\n' "$line" > "$REASON" 2>/dev/null || true
  [ "$line" = "$last" ] && return 0
  say routine "refused: $line"
}

escalate() {  # <text>
  printf '%s\n' "$1" > "$REASON" 2>/dev/null || true
  say escalation "$1"
}

# --- serialized admission boundary ----------------------------------------
# One base-wide owner of the admission decision, so two triggers, a return and a
# revocation cannot interleave inside it. mkdir is atomic and portable (flock is
# absent on macOS). A held lock means another check owns the boundary, so this
# trigger does nothing rather than queueing a second one.
acquire_lock() {
  mkdir "$LOCK" 2>/dev/null || return 1
  trap 'rm -rf "$LOCK"' EXIT
  return 0
}

# --- absence record --------------------------------------------------------
# A record is open while it carries no Retorno: line, and its file name is its
# generation. Exactly one may be open, and the grant must name that one.
# shellcheck source=bin/sq-absence-lib.sh
. "$SCRIPT_DIR/sq-absence-lib.sh"

record_names_task() {  # <record-basename> <task-id>
  local record="$DATA/$1" task=$2
  [ -f "$record" ] || return 1
  tr -c 'A-Za-z0-9._-' '\n' < "$record" | grep -Fqx -- "$task"
}

brief_mode_of() {  # <path>
  grep -m1 '^Delivery contract: mode=' "$1" 2>/dev/null |
    sed 's/^Delivery contract: mode=//' | tr -d '[:space:]'
}

# --- backlog reads ---------------------------------------------------------
# Readiness comes only from the compatible backend's default `sq-tasks ready`
# group: never --include-held, never a hand-parsed backlog. The typed show read
# supplies the state, hold and dependency fields behind each refusal.
ready_ids() {
  ( cd "$SQUAD_BASE" && sq-tasks ready 2>/dev/null ) | awk '
    /^count: /{ count=$2; next }
    /^ready\[[0-9]+\]\{id,/ {
      s=$0; sub(/^ready\[/, "", s); sub(/\].*/, "", s); declared=s
      inblock=1; total=0; next
    }
    /^ready: [0-9]+ /{ declared=$2; inblock=0; next }
    inblock && /^  [^ ]*,/ {
      row=$0; sub(/^ +/, "", row); sub(/,.*/, "", row)
      if (row != "") { print row; total++ }
      next
    }
    inblock { inblock=0 }
    END {
      if (declared == "" || declared != total) exit 3
      if (count != "" && count != declared) exit 3
    }
  '
}

show_field() {  # <task-id> <field>
  ( cd "$SQUAD_BASE" && sq-tasks show "$1" --full 2>/dev/null ) |
    awk -v want="$2" '
      { line=$0; sub(/^ +/, "", line)
        if (index(line, want ": ") == 1) { print substr(line, length(want) + 3); exit } }
    '
}

dependency_ids() {  # <task-id>
  {
    show_field "$1" deps | tr ',' '\n'
    show_field "$1" blocked_by
  } | sed -n 's/.*blocked-by:[[:space:]]*\([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p' | sort -u
}

sq_start() {  # <task-id>
  ( cd "$SQUAD_BASE" && sq-tasks start "$1" >/dev/null 2>&1 )
}

# --- census ----------------------------------------------------------------
# Count this base's own occupied slots from its task records and attempt
# sidecars: a starting, active or parked attempt holds a slot until it is
# positively released, and a dead pane alone never frees one. An unreadable or
# unverified endpoint is ambiguity, and ambiguity means no action.
census() {
  local meta id kind backend target ex agent occupied active=0 starting=0 \
    parked=0 released=0 ambiguous=0 detail=""
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = xo ] && continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    ex=$(SQUAD_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/sq-exec-state.sh" get-recorded "$id" 2>/dev/null || printf 'unclaimed')
    if [ -n "${SQUAD_QUEUE_PILOT_AGENT_STATE:-}" ]; then
      agent=$SQUAD_QUEUE_PILOT_AGENT_STATE
    else
      agent=$(fm_backend_agent_state "$backend" "${target:-unknown}")
    fi
    occupied=0
    case "$agent" in
      alive) active=$((active + 1)); occupied=1 ;;
      dead | missing) ;;
      *)
        ambiguous=$((ambiguous + 1))
        detail="$detail $id=$agent"
        continue
        ;;
    esac
    [ "$occupied" -eq 1 ] && continue
    case "$ex" in
      claimed) starting=$((starting + 1)) ;;
      running) active=$((active + 1)) ;;
      retry_queued) parked=$((parked + 1)) ;;
      *) released=$((released + 1)) ;;
    esac
  done
  printf 'occupied=%d active=%d starting=%d parked=%d released=%d ambiguous=%d detail=%s\n' \
    "$((active + starting + parked))" "$active" "$starting" "$parked" "$released" "$ambiguous" "${detail:-none}"
}

# --- memory gates ----------------------------------------------------------
available_mb() {
  if [ -n "${SQUAD_QUEUE_PILOT_AVAILABLE_MB:-}" ]; then
    printf '%s' "$SQUAD_QUEUE_PILOT_AVAILABLE_MB"
    return 0
  fi
  free -m 2>/dev/null | awk '/^Mem:/{print $7}'
}

# Prints the problem and returns 0 when the startup prompt-memory estimate does
# not fit its own budget; prints nothing and returns 1 when it does. The report's
# over-budget branch is a normal exit, so the status line is authoritative, not
# the exit code.
prompt_budget_problem() {
  local budget report total status
  budget=$("$SCRIPT_DIR/sq-startup-memory-budget.sh" read 2>/dev/null) || {
    printf 'config/startup-memory-budget unreadable'
    return 0
  }
  case "$budget" in ''|*[!0-9]*) printf 'config/startup-memory-budget not numeric'; return 0 ;; esac
  report=$("$SCRIPT_DIR/sq-startup-memory-budget.sh" report 2>/dev/null) || {
    printf 'prompt-budget report failed'
    return 0
  }
  total=$(printf '%s\n' "$report" | sed -n 's/^total_estimated_tokens=//p' | head -1)
  status=$(printf '%s\n' "$report" | sed -n 's/^budget_status=//p' | head -1)
  case "$total" in ''|*[!0-9]*) printf 'prompt-budget total not numeric'; return 0 ;; esac
  [ "$status" = within-budget ] || { printf 'prompt-budget %s (total=%s budget=%s)' "$status" "$total" "$budget"; return 0; }
  [ "$total" -le "$budget" ] || { printf 'prompt-budget total=%s exceeds budget=%s' "$total" "$budget"; return 0; }
  return 1
}

# --- durable intent --------------------------------------------------------
write_intent() {  # <outcome> <detail> [launch-rc]
  local tmp="$INTENT.tmp.$$"
  {
    printf 'version=%s\n' "$GRANT_VERSION"
    printf 'action=dispatch-once\n'
    printf 'base=%s\n' "$SQUAD_BASE"
    printf 'absence_generation=%s\n' "$GENERATION"
    printf 'absence_record=%s\n' "$RECORD"
    printf 'task=%s\n' "$TASK"
    printf 'state=spent\n'
    printf 'claimed_at=%s\n' "$(now)"
    printf 'outcome=%s\n' "$1"
    printf 'outcome_at=%s\n' "$(now)"
    printf 'detail=%s\n' "$(printf '%s' "$2" | tr '\t\r\n' '   ')"
    [ -z "${3:-}" ] || printf 'launch_rc=%s\n' "$3"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$INTENT" 2>/dev/null
}

# --- delivery verification -------------------------------------------------
# A launch return code is not processing proof: the task must have published its
# attempt metadata, its attempt must be running or claimed, and its recorded
# endpoint must have a live agent. Bounded, then reported for reconciliation.
verify_delivery() {  # <task-id>
  local id=$1 tries=0 meta="$STATE/$1.meta" backend target ex agent
  while [ "$tries" -lt 10 ]; do
    if [ -f "$meta" ]; then
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
      ex=$(SQUAD_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/sq-exec-state.sh" get-recorded "$id" 2>/dev/null || printf 'unclaimed')
      if [ -n "${SQUAD_QUEUE_PILOT_AGENT_STATE:-}" ]; then
        agent=$SQUAD_QUEUE_PILOT_AGENT_STATE
      else
        agent=$(fm_backend_agent_state "$backend" "${target:-unknown}")
      fi
      if [ "$agent" = alive ] && { [ "$ex" = running ] || [ "$ex" = claimed ]; }; then
        printf 'endpoint=%s backend=%s attempt=%s' "$agent" "$backend" "$ex"
        return 0
      fi
    fi
    tries=$((tries + 1))
    sleep 2
  done
  printf 'no live endpoint or running attempt within 20s'
  return 1
}

# --- admission -------------------------------------------------------------
admit() {
  local open record_count project mode harness model effort yolo repo \
    max_missions expires brief expected_sha actual_sha slots needed_mb avail \
    census_line occupied ambiguous budget_problem ready_list rc launch_out \
    detail verify dep dep_state
  local -a spawn_args

  [ -f "$GRANT" ] || return 0
  [ "$(grant_get version)" = "$GRANT_VERSION" ] || { refuse "grant-malformed:version"; return 0; }
  [ "$(grant_get action)" = dispatch-once ] || { refuse "grant-malformed:action"; return 0; }
  [ "$(grant_get revoked)" != 1 ] || { refuse "grant-revoked"; return 0; }

  TASK=$(grant_get task)
  GENERATION=$(grant_get absence_generation)
  RECORD=$(grant_get absence_record)
  MODE=$(grant_get mode)
  expires=$(grant_get expires)
  for required in "$TASK" "$GENERATION" "$RECORD" "$MODE" "$expires" \
    "$(grant_get project)" "$(grant_get harness)" "$(grant_get max_missions)"; do
    [ -n "$required" ] || { refuse "grant-malformed:field"; return 0; }
  done
  case "$expires" in ''|*[!0-9]*) refuse "grant-malformed:expires"; return 0 ;; esac
  case "$TASK" in *[!A-Za-z0-9._-]*) refuse "grant-malformed:task"; return 0 ;; esac
  case "$GENERATION" in *[!A-Za-z0-9._-]*) refuse "grant-malformed:generation"; return 0 ;; esac
  [ "$(now)" -lt "$expires" ] || { refuse "grant-expired"; return 0; }
  case "$MODE" in
    drill | direct-PR) ;;
    *) refuse "mode-unsupported:$MODE"; return 0 ;;
  esac

  # The absence record: exactly one open, and exactly the one the grant names.
  open=$(open_absence_records "$DATA")
  record_count=$(printf '%s\n' "$open" | grep -c . || true)
  [ -n "$open" ] || { refuse "no-open-absence-record"; return 0; }
  [ "$record_count" -eq 1 ] || { refuse "multiple-open-absence-records:$(printf '%s' "$open" | tr '\n' ',')"; return 0; }
  [ "$open" = "$RECORD" ] || { refuse "absence-record-mismatch:$open"; return 0; }
  [ "${RECORD%.md}" = "$GENERATION" ] || { refuse "absence-generation-mismatch:${RECORD%.md}"; return 0; }

  # Away mode must be in force and its return path must not be running.
  [ -e "$STATE/.afk" ] || { refuse "away-mode-off"; return 0; }
  [ ! -e "$STATE/.afk-return-gate" ] || { refuse "return-in-progress"; return 0; }

  record_names_task "$RECORD" "$TASK" || { refuse "task-not-named-in-absence-record:$TASK"; return 0; }

  # The prepared brief: present, same delivery contract, unchanged since arm.
  brief="$DATA/$TASK/brief.md"
  [ -f "$brief" ] || { refuse "brief-missing:$brief"; return 0; }
  mode=$(brief_mode_of "$brief")
  [ "$mode" = "$MODE" ] || { refuse "brief-mode-mismatch:${mode:-none}!=$MODE"; return 0; }
  expected_sha=$(grant_get brief_sha256)
  if [ -n "$expected_sha" ]; then
    actual_sha=$(sha256_of "$brief" || true)
    [ "$actual_sha" = "$expected_sha" ] || { refuse "brief-drift:$brief"; return 0; }
  fi

  project=$(grant_get project)
  case "$project" in /*) ;; *) refuse "grant-malformed:project"; return 0 ;; esac
  [ -d "$project" ] || { refuse "project-unresolvable:$project"; return 0; }

  # One-use intent, decided before the queue is even read: a repeated trigger
  # must find the intent spent and do nothing whatever the queue now says.
  if [ -e "$INTENT" ]; then
    refuse "intent-spent:task=$(intent_get task) generation=$(intent_get absence_generation) outcome=$(intent_get outcome)"
    return 0
  fi
  # A virgin id: an existing record for it means this is not a first attempt.
  [ ! -e "$STATE/$TASK.meta" ] || { refuse "target-not-virgin:$STATE/$TASK.meta"; return 0; }
  [ ! -e "$STATE/$TASK.exec" ] || { refuse "target-not-virgin:$STATE/$TASK.exec"; return 0; }

  # Readiness, then the recorded hold and dependency facts behind a refusal.
  fm_tasks_axi_compatible || { refuse "backlog-not-compatible"; return 0; }
  ready_list=$(ready_ids)
  rc=$?
  [ "$rc" -eq 0 ] || { refuse "backlog-ready-contract:$rc"; return 0; }
  if ! printf '%s\n' "$ready_list" | grep -Fqx -- "$TASK"; then
    dep_state=$(show_field "$TASK" state)
    [ -n "$dep_state" ] || { refuse "not-in-backlog:$TASK"; return 0; }
    [ "$(show_field "$TASK" held)" != yes ] || { refuse "held:$(show_field "$TASK" hold_kind):$(show_field "$TASK" hold_reason)"; return 0; }
    [ "$dep_state" = queued ] || { refuse "not-queued:$dep_state"; return 0; }
    [ "$(show_field "$TASK" blocked)" != yes ] || { refuse "blockers-uncleared:$(show_field "$TASK" blocked_by) $(show_field "$TASK" deps)"; return 0; }
    refuse "not-ready:$TASK"
    return 0
  fi
  for dep in $(dependency_ids "$TASK"); do
    dep_state=$(show_field "$dep" state)
    [ -n "$dep_state" ] || { refuse "predecessor-missing:$dep"; return 0; }
    [ "$dep_state" = "done" ] || { refuse "blockers-uncleared:$dep=$dep_state"; return 0; }
  done

  # Resource gates, measured immediately before the launch.
  census_line=$(census)
  occupied=$(printf '%s\n' "$census_line" | sed -n 's/.*occupied=\([0-9]*\).*/\1/p')
  ambiguous=$(printf '%s\n' "$census_line" | sed -n 's/.*ambiguous=\([0-9]*\).*/\1/p')
  [ "$ambiguous" -eq 0 ] || { refuse "census-ambiguous:$census_line"; return 0; }
  max_missions=$(grant_get max_missions)
  case "$max_missions" in ''|*[!0-9]*) refuse "grant-malformed:max-missions"; return 0 ;; esac
  [ "$max_missions" -le "$MAX_SLOTS" ] || { refuse "grant-malformed:max-missions:$max_missions"; return 0; }
  slots=$((occupied + 1))
  [ "$slots" -le "$max_missions" ] || { refuse "mission-cap:$census_line max=$max_missions"; return 0; }
  if [ "$slots" -ge 3 ]; then needed_mb=$SLOT3_MB; else needed_mb=$SLOT1_MB; fi
  avail=$(available_mb)
  case "$avail" in ''|*[!0-9]*) refuse "memory-unknown"; return 0 ;; esac
  [ "$avail" -ge "$needed_mb" ] || { refuse "low-memory:available=${avail}MiB required=${needed_mb}MiB slot=$slots"; return 0; }
  budget_problem=$(prompt_budget_problem || true)
  [ -z "$budget_problem" ] || { refuse "prompt-budget:$budget_problem"; return 0; }

  harness=$(grant_get harness)
  model=$(grant_get model)
  effort=$(grant_get effort)
  yolo=$(grant_get yolo)
  repo=$(grant_get repo)
  [ -n "$yolo" ] || yolo=off

  # Revocation and return win inside the boundary, so both are re-read at the
  # last point before the effect rather than only at entry.
  [ -e "$STATE/.afk" ] || { refuse "away-mode-off"; return 0; }
  [ "$(grant_get revoked)" != 1 ] || { refuse "grant-revoked"; return 0; }
  [ "$(open_absence_records "$DATA")" = "$RECORD" ] || { refuse "absence-record-mismatch:changed"; return 0; }
  [ ! -e "$STATE/.afk-return-gate" ] || { refuse "return-in-progress"; return 0; }
  [ ! -e "$INTENT" ] || { refuse "intent-spent:task=$(intent_get task)"; return 0; }

  # Durable before the effect: a crash, a replay or a second trigger inside this
  # window finds the intent spent and does nothing.
  write_intent pending-launch \
    "launching $TASK in $repo ($MODE yolo=$yolo) slot=$slots available=${avail}MiB" ||
    { refuse "intent-unwritable"; return 0; }

  spawn_args=("$TASK" "$project" --mode "$MODE" --yolo "$yolo" --harness "$harness")
  [ -z "$model" ] || spawn_args+=(--model "$model")
  [ -z "$effort" ] || spawn_args+=(--effort "$effort")
  launch_out=$("$SPAWN" "${spawn_args[@]}" 2>&1)
  rc=$?
  detail=$(printf '%s\n' "$launch_out" | grep -E '^spawned |^error: ' | tail -1)
  [ -n "$detail" ] || detail="spawn rc=$rc"

  if [ "$rc" -ne 0 ]; then
    write_intent failed "$detail" "$rc" || true
    escalate "launch failed for $TASK (rc=$rc) $detail; reconcile before any further action"
    return 0
  fi

  if ! verify=$(verify_delivery "$TASK"); then
    write_intent ambiguous "$detail; $verify" "$rc" || true
    escalate "launched $TASK but delivery is unverified ($verify); reconcile before any further action"
    return 0
  fi

  if ! sq_start "$TASK"; then
    write_intent ambiguous "$detail; $verify; backlog start record failed" "$rc" || true
    escalate "launched $TASK and verified $verify, but marking it in flight failed; reconcile the backlog record"
    return 0
  fi

  write_intent dispatched "$detail; $verify; started=$TASK" "$rc" || true
  : > "$REASON" 2>/dev/null || true
  say routine "dispatched $TASK ($repo, $MODE yolo=$yolo) via $harness${model:+ model=$model}; $detail; $verify; marked in flight"
}

cmd_check() {
  [ -f "$GRANT" ] || return 0
  acquire_lock || return 0
  admit
  trap - EXIT
  rm -rf "$LOCK"
  return 0
}

cmd_status() {
  local grant_state intent_state reason=none
  if [ -f "$GRANT" ]; then
    if [ "$(grant_get revoked)" = 1 ]; then grant_state=revoked; else grant_state=armed; fi
    grant_state="$grant_state task=$(grant_get task) generation=$(grant_get absence_generation) expires=$(grant_get expires)"
  else
    grant_state=none
  fi
  if [ -f "$INTENT" ]; then
    intent_state="spent outcome=$(intent_get outcome)"
  else
    intent_state=unspent
  fi
  [ -f "$REASON" ] && reason=$(cat "$REASON" 2>/dev/null || true)
  printf 'grant: %s\nintent: %s\nlast-refusal: %s\n' "$grant_state" "$intent_state" "${reason:-none}"
}

cmd_revoke() {
  local tmp="$GRANT.tmp.$$"
  [ -f "$GRANT" ] || die "no grant to revoke"
  if grep -q '^revoked=' "$GRANT"; then
    sed 's/^revoked=.*/revoked=1/' "$GRANT" > "$tmp" || die "could not write $tmp"
  else
    { cat "$GRANT"; printf 'revoked=1\n'; } > "$tmp" || die "could not write $tmp"
  fi
  mv -f "$tmp" "$GRANT" || die "could not revoke the grant"
  printf 'revoked\n'
}

cmd_arm() {
  local task="" project="" repo="" mode="" yolo="" harness="" model="" effort="" \
    max_missions="" expires="" authority="" open record_count brief brief_mode sha value
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) task=${2:-}; shift 2 || die "--task needs a value" ;;
      --project) project=${2:-}; shift 2 || die "--project needs a value" ;;
      --repo) repo=${2:-}; shift 2 || die "--repo needs a value" ;;
      --mode) mode=${2:-}; shift 2 || die "--mode needs a value" ;;
      --yolo) yolo=${2:-}; shift 2 || die "--yolo needs a value" ;;
      --harness) harness=${2:-}; shift 2 || die "--harness needs a value" ;;
      --model) model=${2:-}; shift 2 || die "--model needs a value" ;;
      --effort) effort=${2:-}; shift 2 || die "--effort needs a value" ;;
      --max-missions) max_missions=${2:-}; shift 2 || die "--max-missions needs a value" ;;
      --expires) expires=${2:-}; shift 2 || die "--expires needs a value" ;;
      --authority) authority=${2:-}; shift 2 || die "--authority needs a value" ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  for value in "$task" "$project" "$repo" "$mode" "$yolo" "$harness" "$max_missions" "$expires" "$authority"; do
    [ -n "$value" ] ||
      die "arm needs --task --project --repo --mode --yolo --harness --max-missions --expires --authority"
  done
  case "$mode" in drill | direct-PR) ;; *) die "unsupported --mode '$mode' (drill|direct-PR only)" ;; esac
  case "$yolo" in on | off) ;; *) die "--yolo must be on or off" ;; esac
  case "$max_missions" in ''|*[!0-9]*) die "--max-missions must be a number" ;; esac
  { [ "$max_missions" -ge 1 ] && [ "$max_missions" -le "$MAX_SLOTS" ]; } ||
    die "--max-missions must be 1..$MAX_SLOTS"
  case "$expires" in ''|*[!0-9]*) die "--expires must be epoch seconds" ;; esac
  [ "$expires" -gt "$(now)" ] || die "--expires must be in the future"
  case "$project" in /*) ;; *) die "--project must be an absolute path" ;; esac
  case "$task" in *[!A-Za-z0-9._-]*) die "--task must be a plain task id" ;; esac
  [ -d "$project" ] || die "--project is not a directory: $project"
  [ ! -e "$GRANT" ] || die "a grant already exists; revoke it before arming another ($GRANT)"

  open=$(open_absence_records "$DATA")
  record_count=$(printf '%s\n' "$open" | grep -c . || true)
  [ "$record_count" -eq 1 ] || die "arming needs exactly one open absence record (found $record_count)"
  record_names_task "$open" "$task" || die "the open absence record $open does not name $task"

  brief="$DATA/$task/brief.md"
  [ -f "$brief" ] || die "missing prepared brief: $brief"
  brief_mode=$(brief_mode_of "$brief")
  [ "$brief_mode" = "$mode" ] || die "brief delivery contract '${brief_mode:-none}' disagrees with --mode $mode"
  sha=$(sha256_of "$brief") || die "no sha256 tool available to bind the brief"

  mkdir -p "$STATE" || die "cannot create $STATE"
  {
    printf 'version=%s\n' "$GRANT_VERSION"
    printf 'action=dispatch-once\n'
    printf 'base=%s\n' "$SQUAD_BASE"
    printf 'absence_record=%s\n' "$open"
    printf 'absence_generation=%s\n' "${open%.md}"
    printf 'task=%s\n' "$task"
    printf 'project=%s\n' "$project"
    printf 'repo=%s\n' "$repo"
    printf 'mode=%s\n' "$mode"
    printf 'yolo=%s\n' "$yolo"
    printf 'harness=%s\n' "$harness"
    printf 'max_missions=%s\n' "$max_missions"
    printf 'expires=%s\n' "$expires"
    printf 'created=%s\n' "$(now)"
    printf 'brief_sha256=%s\n' "$sha"
    printf 'authority=%s\n' "$(printf '%s' "$authority" | tr '\t\r\n' '   ')"
    [ -z "$model" ] || printf 'model=%s\n' "$model"
    [ -z "$effort" ] || printf 'effort=%s\n' "$effort"
  } > "$GRANT.tmp.$$" || die "could not write the grant"
  mv -f "$GRANT.tmp.$$" "$GRANT" || die "could not publish the grant"
  printf 'armed: task=%s generation=%s mode=%s yolo=%s max=%s expires=%s\n' \
    "$task" "${open%.md}" "$mode" "$yolo" "$max_missions" "$expires"
}

main() {
  local cmd=${1:-}
  case "$cmd" in
    arm)
      shift
      cmd_arm "$@"
      ;;
    check) cmd_check ;;
    status) cmd_status ;;
    revoke) cmd_revoke ;;
    -h | --help | help | '') usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
