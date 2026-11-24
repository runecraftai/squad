#!/usr/bin/env bash
# sq-queue-pilot.sh - the opt-in away queue pilot: dispatch exactly one
# pre-approved backlog task, once, and do nothing else.
#
# Why this exists: the away-mode daemon absorbs wakes and decides nothing, so
# without an awake Squad turn a notification never becomes work - the absences
# recorded in data/absence-2026-11-22-noite.md and data/absence-2026-11-24-0100.md
# both ended with a green PR unmerged and the next planned task never dispatched.
# The design is data/squad-queue-executor-recon/report.md; this script is only its
# dispatch-once slice.
#
# Usage:
#   sq-queue-pilot.sh arm --base <abs-squad-base>
#   sq-queue-pilot.sh check --base <abs-squad-base>
#   sq-queue-pilot.sh --help
#
# arm   Read the one open absence record and freeze its named pilot fields into a
#       durable one-use intent under <base>/state/queue-pilot.intent. Nothing is
#       launched. The away-entry owner runs this after state/.afk exists.
# check One admission pass: re-read the live base, revalidate every guard, spend
#       the intent, launch that one task through bin/sq-spawn.sh, then verify
#       delivery. A second check finds the intent spent and launches nothing.
#
# The only input is --base. Every launch field comes from a named field of the
# absence record, so nothing is forwarded from prose, a status line, a command
# line, or a list. Exit 0 means the pilot either recorded the intent (arm) or
# dispatched and verified exactly one task (check); exit 1 prints exactly one
# `refused: ...` line and performs no effect.
#
# Nothing invokes this script on its own: it ships inert, so away mode keeps
# behaving exactly as it does today until the away-entry owner runs `arm` for one
# commander-approved task and a trigger runs `check`.
#
# Guard order. arm runs 9, 7, 2, 6, 3 (record values), 16, 13, 8, then 5.
# check runs 9, 7 (flag and expiry), 2, 6, 4, 3, 8, 16, 13, 10, 15, 14, 11, then
# 5 (spend), the launch, and 12. Guard 1 and guard 13's force rule are ambient:
# they hold for every effect, whatever the order.
#
# Absence record contract (the named fields this script reads, each required
# exactly once in the open record; a duplicate or an empty value admits nothing):
#   pilot-generation: <token>            identity of this absence grant
#   pilot-task: <task-id>                the one pre-filed task
#   pilot-project: <absolute path>       the project worktree base
#   pilot-repo: <registry name>          must equal the task's recorded repo
#   pilot-mode: <drill|direct-PR|local-only>
#   pilot-yolo: <on|off>
#   pilot-harness: <verified harness>    claude|codex|opencode|pi|pi-signed|grok|kimi|muse
#   pilot-model: <name|->                '-' means no explicit model axis
#   pilot-effort: <low|medium|high|xhigh|max|->
#   pilot-max-missions: <1|2|3>          the commander's concurrent-mission ceiling
#   pilot-expires: <epoch-seconds>       the grant's hard expiry
#
# Intent schema (<base>/state/queue-pilot.intent, one key=value per line): this
# header is the owner of the field list, which is closed - a field outside it is
# admitted by nothing, and every field below is pattern-validated before launch.
#   schema=1  arm_state=armed|spent  key=<base>|<generation>|<task>
#   base=  generation=  task=  source_record=  project=  repo=  mode=  yolo=
#   harness=  model=  effort=  max_missions=  expires=  authority=  armed_epoch=
# The intent is written to a temporary sibling and renamed, then re-read and
# revalidated before any effect, so a partial write admits nothing.
#
# Guard table. Every row is one implemented check with one stable refusal line; a
# refusal is recorded once and nothing is launched. The guard names are also the
# function names in this file, in execution order.
#   1  No task mutation          pilot_effect     no add/start/done/hold/... verb ever runs
#                                                 refused: task mutation is outside pilot authority
#   2  Authority from the record guard_filed_task_id  the id comes from pilot-task only
#                                                 refused: no filed task id in the absence record
#   3  No forwarded authority    guard_intent_fields  the closed intent schema, every value matched
#                                                 refused: field not covered by the intent
#   4  Intent identity           guard_identity   base|generation|task compared before launch
#                                                 refused: intent does not match this base, generation and task
#   5  Atomic intent             guard_intent_durable  tmp-file rename, then revalidated
#                                                 refused: intent not durable
#   6  Spent intent              guard_intent_armed   a spent or second intent launches nothing
#                                                 refused: intent already spent
#   7  Open absence required     guard_absence_open   reads state/.afk, never the return gate
#                                                 refused: no absence record is open
#   8  Ready and unblocked       guard_task_ready  live ready set, unheld, blockers present and done
#                                                 refused: task is not ready
#   9  Base binding              guard_base_bound  explicit --base only, never the current directory
#                                                 refused: base not bound
#   10 Census                    guard_census     task records, attempt records and endpoints agree
#                                                 refused: census mismatch
#   11 Admitted id is the intent's guard_admitted_id  the queue head is the intent's id
#                                                 refused: admitted id changed
#   12 Delivery evidence         guard_delivery   beyond a live endpoint and a running attempt
#                                                 refused: delivery unproven
#   13 No force                  guard_backend / pilot_effect  no --force, no force-cleanup backend
#                                                 refused: backend would force
#   14 Memory ceiling            guard_memory     portable measured sample before launch
#                                                 refused: memory budget
#   15 Mission cap               guard_mission_cap  the recorded ceiling before launch
#                                                 refused: mission cap
#   16 Delivery posture          guard_posture    data/projects.md mode and yolo, local-only included
#                                                 refused: posture not satisfied
#
# A command outside a guard's own subject is refused as
# `refused: effect outside pilot authority`: this script has no code path that
# merges, registers a pull request, steers, decides a gate, tears down, or
# dispatches a second id, and pilot_effect is the single exec boundary every
# external command passes through.
#
# Test seams, never set in production:
#   SQUAD_QUEUE_PILOT_SPAWN         the launch command (default bin/sq-spawn.sh)
#   SQUAD_QUEUE_PILOT_TASKS         the read-only backlog CLI (default sq-tasks)
#   SQUAD_QUEUE_PILOT_MEMINFO       the /proc/meminfo-shaped sample source
#   SQUAD_QUEUE_PILOT_AGENT_STATE   the endpoint agent state (default the backend
#                                   adapter's own classifier)
#   SQUAD_QUEUE_PILOT_DELIVERY_WAIT seconds allowed for delivery evidence (default 120)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The sixteen stable refusal lines. Each is printed alone on its own line.
REFUSE_MUTATION='refused: task mutation is outside pilot authority'
REFUSE_NO_TASK_ID='refused: no filed task id in the absence record'
REFUSE_FIELD='refused: field not covered by the intent'
REFUSE_IDENTITY='refused: intent does not match this base, generation and task'
REFUSE_NOT_DURABLE='refused: intent not durable'
REFUSE_SPENT='refused: intent already spent'
REFUSE_NO_ABSENCE='refused: no absence record is open'
REFUSE_NOT_READY='refused: task is not ready'
REFUSE_BASE='refused: base not bound'
REFUSE_CENSUS='refused: census mismatch'
REFUSE_ADMITTED='refused: admitted id changed'
REFUSE_DELIVERY='refused: delivery unproven'
REFUSE_FORCE='refused: backend would force'
REFUSE_MEMORY='refused: memory budget'
REFUSE_CAP='refused: mission cap'
REFUSE_POSTURE='refused: posture not satisfied'
REFUSE_EFFECT='refused: effect outside pilot authority'

INTENT_SCHEMA=1
BASE_MB=4096   # first and second mission, measured available memory
THIRD_MB=9216  # third mission, measured available memory; a fourth is never eligible
MAX_SLOTS=3
# Backends whose verified failure or cleanup path forces: bin/backends/orca.sh
# removes a worktree with --force, and bin/sq-spawn.sh returns a TUIOS lease with
# `fob return --force`. Neither is selectable by this pilot.
FORCE_BACKENDS='orca tuios'
# Harness adapters verified for dispatch (AGENTS.md section 4).
VERIFIED_HARNESSES='claude codex opencode pi pi-signed grok kimi muse'
# The closed intent schema: any other key admits nothing (guard 3).
INTENT_KEYS='armed_epoch arm_state authority base effort expires generation harness key max_missions mode model project repo schema source_record task yolo'

usage() {
  cat <<'EOF'
usage: sq-queue-pilot.sh <command> --base <abs-squad-base>

  arm    Read the one open absence record and freeze its named pilot fields into
         a durable one-use intent. Launches nothing.
  check  One admission pass: revalidate every guard, spend the intent, launch
         that one task through bin/sq-spawn.sh, then verify delivery.

The only input is --base. Every launch field comes from a named field of the
absence record. Exit 0 records the intent (arm) or dispatches and verifies the
one task (check); exit 1 prints one `refused: ...` line and does nothing.
The script header owns the record contract, the intent schema, and the guard
table with its exact conditions and refusal lines.
EOF
}

now() { date +%s; }

refuse() {  # <message>: the single refusal exit path
  printf '%s\n' "$1"
  exit 1
}

file_mtime() {  # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# --- guard 1 and 13: the single effect boundary -----------------------------

pilot_effect() {  # <command> [args...]
  local cmd=${1:-} base arg spawn_cmd
  [ -n "$cmd" ] || return 1
  base=$(basename -- "$cmd")
  spawn_cmd=${SQUAD_QUEUE_PILOT_SPAWN:-$SCRIPT_DIR/sq-spawn.sh}
  for arg in "$@"; do
    case $arg in
      --force | --force=* | force) refuse "$REFUSE_FORCE" ;;
    esac
  done
  # The one write effect this pilot owns: the launch of the filed task.
  if [ "$cmd" = "$spawn_cmd" ]; then
    "$@"
    return $?
  fi
  case $base in
    sq-tasks | tasks-axi)
      case ${2:-} in
        ready | show | list) ;;
        add | start | done | reopen | update | rm | block | unblock | hold | unhold | mv | prune | setup)
          refuse "$REFUSE_MUTATION"
          ;;
        *) refuse "$REFUSE_EFFECT" ;;
      esac
      ;;
    sq-spawn.sh) ;;
    sq-pr-merge.sh | sq-pr-check.sh | sq-merge-local.sh | sq-send.sh | sq-teardown.sh | sq-promote.sh | sq-brief.sh | sq-ask.sh | sq-decision-hold.sh | gh | glab | git)
      refuse "$REFUSE_EFFECT"
      ;;
    *) refuse "$REFUSE_EFFECT" ;;
  esac
  "$@"
}

# --- guard 9: base binding --------------------------------------------------

guard_base_bound() {  # <base>
  local base=${1:-}
  [ -n "$base" ] || return 1
  case $base in /*) ;; *) return 1 ;; esac
  [ -d "$base" ] && [ -d "$base/state" ] && [ -d "$base/data" ] || return 1
  [ -f "$base/bin/sq-spawn.sh" ] || return 1
  return 0
}

# --- guard 7: the absence flag, never the return gate -----------------------

absence_records_open() {  # <data-dir>
  local data=$1 f
  for f in "$data"/absence-*.md; do
    [ -e "$f" ] || continue
    [ -f "$f" ] || continue
    grep -q '^## Retorno' "$f" && continue
    printf '%s\n' "$f"
  done
}

guard_absence_open() {  # <state-dir> <data-dir>; sets ABSENCE_RECORD
  local state=$1 data=$2 count record
  ABSENCE_RECORD=
  # The absence flag is state/.afk. The return gate (state/.afk-return-catchup)
  # records that a return is under way and is deliberately not consulted here.
  [ -f "$state/.afk" ] || return 1
  count=$(absence_records_open "$data" | wc -l | tr -d ' ')
  [ "$count" = 1 ] || return 1
  record=$(absence_records_open "$data")
  [ -n "$record" ] || return 1
  ABSENCE_RECORD=$record
  return 0
}

# --- named absence-record fields -------------------------------------------

record_field() {  # <record> <name>: exactly one non-empty occurrence, else fails
  local record=$1 name=$2 count value
  count=$(grep -c "^$name: " "$record" 2>/dev/null || true)
  [ "${count:-0}" = 1 ] || return 1
  value=$(sed -n "s/^$name: //p" "$record" | head -1)
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

valid_task_id() {
  case ${1:-} in
    '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# --- guard 2: authority from the named field only ---------------------------

guard_filed_task_id() {  # <record>
  local task
  task=$(record_field "$1" pilot-task) || return 1
  valid_task_id "$task" || return 1
  return 0
}

# --- guard 4: intent identity ----------------------------------------------

identity_key() {  # <base> <generation> <task>
  printf '%s|%s|%s\n' "$1" "$2" "$3"
}

valid_generation() {
  case ${1:-} in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

intent_field() {  # <intent> <key>
  local value
  value=$(grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-) || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

guard_identity() {  # <base> <record> <intent>
  local base=$1 record=$2 intent=$3 generation task key
  generation=$(record_field "$record" pilot-generation) || return 1
  valid_generation "$generation" || return 1
  task=$(record_field "$record" pilot-task) || return 1
  valid_task_id "$task" || return 1
  key=$(intent_field "$intent" key) || return 1
  [ "$(intent_field "$intent" base)" = "$base" ] || return 1
  [ "$(intent_field "$intent" generation)" = "$generation" ] || return 1
  [ "$(intent_field "$intent" task)" = "$task" ] || return 1
  [ "$key" = "$(identity_key "$base" "$generation" "$task")" ] || return 1
  return 0
}

# --- guard 3: the closed intent schema --------------------------------------

intent_keys() {  # <intent>
  sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$1"
}

intent_value_count() {  # <intent> <key>
  grep -c "^$2=" "$1" 2>/dev/null || true
}

guard_intent_fields() {  # <intent>; sets INTENT_* for every launch field
  local intent=$1 field key count declared schema_key
  INTENT_TASK='' INTENT_PROJECT='' INTENT_REPO='' INTENT_MODE='' INTENT_YOLO=''
  INTENT_HARNESS='' INTENT_MODEL='' INTENT_EFFORT='' INTENT_MAX_MISSIONS=''
  INTENT_EXPIRES='' INTENT_SCHEMA_VALUE=''
  # Every key present in the file must be one this schema declares.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    declared=0
    for schema_key in $INTENT_KEYS; do
      [ "$schema_key" = "$key" ] && declared=1 && break
    done
    [ "$declared" = 1 ] || return 1
  done <<EOF
$(intent_keys "$intent")
EOF
  # Required fields, each exactly once.
  for field in schema arm_state key base generation task source_record project repo mode yolo harness model effort max_missions expires authority armed_epoch; do
    count=$(intent_value_count "$intent" "$field")
    [ "${count:-0}" = 1 ] || return 1
  done
  INTENT_SCHEMA_VALUE=$(intent_field "$intent" schema) || return 1
  [ "$INTENT_SCHEMA_VALUE" = "$INTENT_SCHEMA" ] || return 1
  INTENT_TASK=$(intent_field "$intent" task) || return 1
  valid_task_id "$INTENT_TASK" || return 1
  INTENT_PROJECT=$(intent_field "$intent" project) || return 1
  case $INTENT_PROJECT in /*) ;; *) return 1 ;; esac
  [ -d "$INTENT_PROJECT" ] || return 1
  INTENT_REPO=$(intent_field "$intent" repo) || return 1
  case $INTENT_REPO in '' | *[!A-Za-z0-9._/-]*) return 1 ;; esac
  INTENT_MODE=$(intent_field "$intent" mode) || return 1
  case $INTENT_MODE in drill | direct-PR | local-only) ;; *) return 1 ;; esac
  INTENT_YOLO=$(intent_field "$intent" yolo) || return 1
  case $INTENT_YOLO in on | off) ;; *) return 1 ;; esac
  INTENT_HARNESS=$(intent_field "$intent" harness) || return 1
  case " $VERIFIED_HARNESSES " in
    *" $INTENT_HARNESS "*) ;;
    *) return 1 ;;
  esac
  INTENT_MODEL=$(intent_field "$intent" model) || return 1
  case $INTENT_MODEL in
    -) ;;
    *[!A-Za-z0-9._/-]* | '') return 1 ;;
  esac
  INTENT_EFFORT=$(intent_field "$intent" effort) || return 1
  case $INTENT_EFFORT in low | medium | high | xhigh | max | -) ;; *) return 1 ;; esac
  INTENT_MAX_MISSIONS=$(intent_field "$intent" max_missions) || return 1
  case $INTENT_MAX_MISSIONS in 1 | 2 | 3) ;; *) return 1 ;; esac
  INTENT_EXPIRES=$(intent_field "$intent" expires) || return 1
  case $INTENT_EXPIRES in '' | *[!0-9]*) return 1 ;; esac
  return 0
}

# --- guard 5: durable intent ------------------------------------------------

intent_write() {  # <intent> <arm-state> and the INTENT_* values already set
  local intent=$1 arm_state=$2 tmp="$1.tmp.$$"
  {
    printf 'schema=%s\n' "$INTENT_SCHEMA"
    printf 'arm_state=%s\n' "$arm_state"
    printf 'key=%s\n' "$(identity_key "$INTENT_BASE" "$INTENT_GENERATION" "$INTENT_TASK")"
    printf 'base=%s\n' "$INTENT_BASE"
    printf 'generation=%s\n' "$INTENT_GENERATION"
    printf 'task=%s\n' "$INTENT_TASK"
    printf 'source_record=%s\n' "$INTENT_SOURCE_RECORD"
    printf 'project=%s\n' "$INTENT_PROJECT"
    printf 'repo=%s\n' "$INTENT_REPO"
    printf 'mode=%s\n' "$INTENT_MODE"
    printf 'yolo=%s\n' "$INTENT_YOLO"
    printf 'harness=%s\n' "$INTENT_HARNESS"
    printf 'model=%s\n' "$INTENT_MODEL"
    printf 'effort=%s\n' "$INTENT_EFFORT"
    printf 'max_missions=%s\n' "$INTENT_MAX_MISSIONS"
    printf 'expires=%s\n' "$INTENT_EXPIRES"
    printf 'authority=%s\n' "$INTENT_AUTHORITY"
    printf 'armed_epoch=%s\n' "$INTENT_ARMED_EPOCH"
  } 2>/dev/null >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$intent" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  return 0
}

guard_intent_durable() {  # <intent> <expected-arm-state>
  local intent=$1 expected=$2 count leftover
  [ -f "$intent" ] || return 1
  [ -s "$intent" ] || return 1
  guard_intent_fields "$intent" || return 1
  for key in schema arm_state key base generation task source_record project repo mode yolo harness model effort max_missions expires authority armed_epoch; do
    count=$(intent_value_count "$intent" "$key")
    [ "${count:-0}" = 1 ] || return 1
  done
  [ "$(intent_field "$intent" arm_state)" = "$expected" ] || return 1
  # No temporary sibling may survive a completed write.
  for leftover in "$intent".tmp.*; do
    [ -e "$leftover" ] || continue
    return 1
  done
  return 0
}

# --- guard 6: spent intent --------------------------------------------------

guard_intent_armed() {  # <intent>
  [ -f "$1" ] || return 1
  [ "$(intent_field "$1" arm_state)" = armed ] || return 1
  return 0
}

# --- readiness --------------------------------------------------------------

tasks_bin() {
  local cmd=${SQUAD_QUEUE_PILOT_TASKS:-sq-tasks}
  command -v "$cmd" >/dev/null 2>&1 || return 1
  printf '%s\n' "$cmd"
}

# The ready read is the backlog owner's own contract: its header line names the
# columns, and this pilot reads only the first (id) column. Anything unreadable,
# or a header without an id column, refuses rather than guessing.
ready_ids() {  # <backlog>; prints ready ids in the owner's order
  local backlog=$1 bin out header count
  bin=$(tasks_bin) || return 1
  out=$(pilot_effect "$bin" ready --file "$backlog" 2>/dev/null) || return 1
  header=$(printf '%s\n' "$out" | sed -n 's/^ready\[[0-9][0-9]*\]{\(.*\)}:[[:space:]]*$/\1/p' | head -1)
  if [ -z "$header" ]; then
    count=$(printf '%s\n' "$out" | sed -n 's/^count: \([0-9][0-9]*\)$/\1/p' | head -1)
    [ "${count:-x}" = 0 ] || return 1
    return 0
  fi
  case ",$header," in
    *,id,*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$out" | awk '/^  /{ line=substr($0,3); split(line, f, ","); if (f[1] != "") printf "%s\n", f[1] }'
  return 0
}

task_show() {  # <backlog> <id>; sets SHOW_* from the owner's field lines
  local backlog=$1 id=$2 bin out
  SHOW_STATE='' SHOW_BLOCKED='' SHOW_HELD='' SHOW_REPO='' SHOW_BLOCKED_BY=''
  bin=$(tasks_bin) || return 1
  out=$(pilot_effect "$bin" show "$id" --file "$backlog" 2>/dev/null) || return 1
  SHOW_STATE=$(printf '%s\n' "$out" | sed -n 's/^  state: //p' | head -1)
  SHOW_BLOCKED=$(printf '%s\n' "$out" | sed -n 's/^  blocked: //p' | head -1)
  SHOW_HELD=$(printf '%s\n' "$out" | sed -n 's/^  held: //p' | head -1)
  SHOW_REPO=$(printf '%s\n' "$out" | sed -n 's/^  repo: //p' | head -1)
  SHOW_BLOCKED_BY=$(printf '%s\n' "$out" | sed -n 's/^  blocked_by: //p' | head -1)
  [ -n "$SHOW_STATE" ] || return 1
  return 0
}

# --- guard 8: ready and unblocked ------------------------------------------

guard_task_ready() {  # <backlog> <task> <repo>; sets READY_IDS
  local backlog=$1 task=$2 repo=$3 blocker
  READY_IDS=
  READY_IDS=$(ready_ids "$backlog") || return 1
  case $'\n'"$READY_IDS"$'\n' in
    *$'\n'"$task"$'\n'*) ;;
    *) return 1 ;;
  esac
  task_show "$backlog" "$task" || return 1
  [ "$SHOW_STATE" = queued ] || return 1
  [ "$SHOW_BLOCKED" = no ] || return 1
  [ "$SHOW_HELD" = no ] || return 1
  [ "$SHOW_REPO" = "$repo" ] || return 1
  # A missing predecessor is projected as resolved by the backlog's own
  # blockedIds, so every named blocker must exist here and be done.
  for blocker in $(printf '%s\n' "$SHOW_BLOCKED_BY" | tr ',' ' '); do
    [ "$blocker" = none ] && continue
    task_show "$backlog" "$blocker" || return 1
    [ "$SHOW_STATE" = "done" ] || return 1
  done
  return 0
}

# --- guard 11: the admitted id is the intent's -----------------------------

guard_admitted_id() {  # <ready-ids> <task>
  local first
  first=$(printf '%s\n' "$1" | sed -n '1p')
  [ "$first" = "$2" ] || return 1
  return 0
}

# --- guard 16: delivery posture -------------------------------------------

registry_mode() {  # <registry> <project-name>
  local registry=$1 name=$2 line
  [ -f "$registry" ] || return 1
  line=$(grep -m1 -- "^- $name \[" "$registry" 2>/dev/null) || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | sed -n 's/^- [^ ]* \[\([^]]*\)\].*/\1/p'
}

guard_posture() {  # <registry> <project-path> <repo> <mode> <yolo>
  local registry=$1 project=$2 repo=$3 mode=$4 yolo=$5 name registered
  name=$(basename -- "$project")
  if ! registered=$(registry_mode "$registry" "$name"); then
    registered=$(registry_mode "$registry" "$repo") || {
      # An unregistered project resolves to drill with autonomy off.
      [ "$mode" = drill ] && [ "$yolo" = off ] || return 1
      return 0
    }
  fi
  case $registered in
    local-only)
      [ "$mode" = local-only ] || return 1
      [ "$yolo" = off ] || return 1
      ;;
    drill | drill-prod-only)
      [ "$mode" = drill ] || return 1
      ;;
    direct-PR)
      case $mode in direct-PR | drill) ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
  return 0
}

# --- guard 13: no force ----------------------------------------------------

pilot_backend() {  # <base>
  local base=$1 configured
  if [ -n "${SQUAD_BACKEND:-}" ]; then
    printf '%s\n' "$SQUAD_BACKEND"
    return 0
  fi
  if [ -r "$base/config/backend" ]; then
    configured=$(head -1 "$base/config/backend" | tr -d '[:space:]')
    if [ -n "$configured" ]; then
      printf '%s\n' "$configured"
      return 0
    fi
  fi
  # Runtime auto-detection is deliberately not consulted: a backend selected from
  # whatever terminal happens to be live cannot be reviewed before departure.
  printf 'tmux\n'
}

guard_backend() {  # <backend>
  local backend=$1 name
  [ -n "$backend" ] || return 1
  for name in $FORCE_BACKENDS; do
    [ "$backend" = "$name" ] && return 1
  done
  return 0
}

# --- guard 10: census ------------------------------------------------------

guard_census() {  # <state-dir>; sets CENSUS_* and OCCUPIED
  local state=$1 meta exec id exec_state
  CENSUS_TASKS=0
  CENSUS_ATTEMPTS=0
  CENSUS_ENDPOINTS=0
  OCCUPIED=0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    [ -f "$meta" ] && [ -r "$meta" ] || return 1
    id=$(basename -- "$meta" .meta)
    grep -q "^endpoint_task_id=$id$" "$meta" || return 1
    grep -q '^window=..*' "$meta" || return 1
    CENSUS_TASKS=$((CENSUS_TASKS + 1))
    CENSUS_ENDPOINTS=$((CENSUS_ENDPOINTS + 1))
  done
  for exec in "$state"/*.exec; do
    [ -e "$exec" ] || continue
    id=$(basename -- "$exec" .exec)
    # An attempt record without its task record cannot be attributed.
    [ -f "$state/$id.meta" ] || return 1
    CENSUS_ATTEMPTS=$((CENSUS_ATTEMPTS + 1))
    exec_state=$(grep -m1 '^exec_state=' "$exec" 2>/dev/null | cut -d= -f2-) || exec_state=
    case $exec_state in
      claimed | running) OCCUPIED=$((OCCUPIED + 1)) ;;
    esac
  done
  return 0
}

# --- guard 15: mission cap -------------------------------------------------

guard_mission_cap() {  # <occupied> <cap>
  local occupied=$1 cap=$2
  case $cap in 1 | 2 | 3) ;; *) return 1 ;; esac
  [ "$occupied" -lt "$cap" ] || return 1
  [ "$((occupied + 1))" -le "$MAX_SLOTS" ] || return 1
  return 0
}

# --- guard 14: memory ceiling ---------------------------------------------

available_mb() {  # measured available memory in MiB, portable
  local meminfo=${SQUAD_QUEUE_PILOT_MEMINFO:-/proc/meminfo} pagesize vm
  if [ -r "$meminfo" ]; then
    awk '
      /^MemAvailable:/ { printf "%d\n", $2 / 1024; found = 1 }
      END { if (!found) exit 1 }
    ' "$meminfo"
    return
  fi
  # macOS and other BSD hosts have no /proc: derive available memory from the VM
  # counters instead, so the ceiling measured here is not Linux-only.
  if command -v vm_stat >/dev/null 2>&1 && command -v sysctl >/dev/null 2>&1; then
    pagesize=$(sysctl -n hw.pagesize 2>/dev/null) || return 1
    case $pagesize in '' | *[!0-9]*) return 1 ;; esac
    vm=$(vm_stat 2>/dev/null) || return 1
    printf '%s\n' "$vm" | awk -v ps="$pagesize" '
      /^Pages free:/ { gsub(/[^0-9]/, "", $3); free = $3 }
      /^Pages inactive:/ { gsub(/[^0-9]/, "", $3); inactive = $3 }
      /^Pages speculative:/ { gsub(/[^0-9]/, "", $3); spec = $3 }
      END {
        total = free + inactive + spec
        if (total <= 0) exit 1
        printf "%d\n", (total * ps) / 1048576
      }
    '
    return
  fi
  return 1
}

guard_memory() {  # <occupied>; sets MEM_AVAILABLE MEM_REQUIRED MEM_SLOT
  local occupied=$1 available required slot
  MEM_AVAILABLE='' MEM_REQUIRED='' MEM_SLOT=''
  available=$(available_mb) || return 1
  case $available in '' | *[!0-9]*) return 1 ;; esac
  slot=$((occupied + 1))
  [ "$slot" -le "$MAX_SLOTS" ] || return 1
  if [ "$slot" -ge 3 ]; then
    required=$THIRD_MB
  else
    required=$BASE_MB
  fi
  [ "$available" -ge "$required" ] || return 1
  MEM_AVAILABLE=$available
  MEM_REQUIRED=$required
  MEM_SLOT=$slot
  return 0
}

# --- guard 12: delivery evidence ------------------------------------------

endpoint_state() {  # <base> <backend> <window>
  local base=$1 backend=$2 window=$3
  if [ -n "${SQUAD_QUEUE_PILOT_AGENT_STATE:-}" ]; then
    printf '%s\n' "$SQUAD_QUEUE_PILOT_AGENT_STATE"
    return 0
  fi
  # shellcheck source=bin/sq-backend.sh
  ( . "$base/bin/sq-backend.sh" && fm_backend_agent_state "$backend" "$window" ) 2>/dev/null
}

worker_status_seen() {  # <state-dir> <id> <launch-epoch>
  local state=$1 id=$2 launched=$3 status mtime
  status="$state/$id.status"
  [ -f "$status" ] || return 1
  grep -Eq '^(working|needs-decision|blocked|paused|done|failed):' "$status" || return 1
  mtime=$(file_mtime "$status") || return 1
  case $mtime in '' | *[!0-9]*) return 1 ;; esac
  [ "$mtime" -ge "$((launched - 2))" ] || return 1
  return 0
}

delivery_evidence_ok() {  # <state-dir> <id> <backend> <launch-epoch>; sets DELIVERY_*
  local state=$1 id=$2 backend=$3 launched=$4 meta exec_state window worktree ep
  meta="$state/$id.meta"
  DELIVERY_WINDOW='' DELIVERY_WORKTREE='' DELIVERY_EXEC=''
  [ -f "$meta" ] || return 1
  window=$(grep -m1 '^window=' "$meta" 2>/dev/null | cut -d= -f2-) || window=
  worktree=$(grep -m1 '^worktree=' "$meta" 2>/dev/null | cut -d= -f2-) || worktree=
  [ -n "$window" ] || return 1
  [ -n "$worktree" ] || return 1
  DELIVERY_WINDOW=$window
  DELIVERY_WORKTREE=$worktree
  exec_state=$(grep -m1 '^exec_state=' "$state/$id.exec" 2>/dev/null | cut -d= -f2-) || exec_state=
  case $exec_state in
    claimed | running) ;;
    *) return 1 ;;
  esac
  DELIVERY_EXEC=$exec_state
  # A live endpoint and a running attempt are the two weakest signals, so the
  # worker's own status line is required on top of them.
  worker_status_seen "$state" "$id" "$launched" || return 1
  ep=$(endpoint_state "$BASE_DIR" "$backend" "$window") || return 1
  [ "$ep" = alive ] || return 1
  return 0
}

guard_delivery() {  # <state-dir> <id> <backend> <launch-epoch>
  local state=$1 id=$2 backend=$3 launched=$4 wait deadline
  wait=${SQUAD_QUEUE_PILOT_DELIVERY_WAIT:-120}
  case $wait in '' | *[!0-9]*) wait=120 ;; esac
  deadline=$((launched + wait))
  while :; do
    if delivery_evidence_ok "$state" "$id" "$backend" "$launched"; then
      return 0
    fi
    [ "$(now)" -lt "$deadline" ] || return 1
    sleep 2
  done
}

# --- commands --------------------------------------------------------------

parse_base() {  # <args...>: sets BASE_DIR from --base only
  BASE_DIR=
  while [ "$#" -gt 0 ]; do
    case $1 in
      --base)
        [ "$#" -ge 2 ] || return 1
        BASE_DIR=$2
        shift 2
        ;;
      --base=*)
        BASE_DIR=${1#--base=}
        shift
        ;;
      *) return 1 ;;
    esac
  done
  [ -n "$BASE_DIR" ] || return 1
  return 0
}

load_record_fields() {  # <record>: fills the INTENT_* pre-write values
  INTENT_GENERATION=$(record_field "$1" pilot-generation) || return 1
  valid_generation "$INTENT_GENERATION" || return 1
  INTENT_TASK=$(record_field "$1" pilot-task) || return 1
  valid_task_id "$INTENT_TASK" || return 1
  INTENT_PROJECT=$(record_field "$1" pilot-project) || return 1
  INTENT_REPO=$(record_field "$1" pilot-repo) || return 1
  INTENT_MODE=$(record_field "$1" pilot-mode) || return 1
  INTENT_YOLO=$(record_field "$1" pilot-yolo) || return 1
  INTENT_HARNESS=$(record_field "$1" pilot-harness) || return 1
  INTENT_MODEL=$(record_field "$1" pilot-model) || return 1
  INTENT_EFFORT=$(record_field "$1" pilot-effort) || return 1
  INTENT_MAX_MISSIONS=$(record_field "$1" pilot-max-missions) || return 1
  INTENT_EXPIRES=$(record_field "$1" pilot-expires) || return 1
  INTENT_AUTHORITY=$(record_field "$1" pilot-authority 2>/dev/null || printf 'absence record %s' "$(basename -- "$1")")
  INTENT_AUTHORITY=$(printf '%s' "$INTENT_AUTHORITY" | tr '\n' ' ')
  return 0
}

# guard 3 for the arm path: the values about to be frozen must already satisfy
# every pattern the check path enforces, so a malformed record never becomes an
# intent another reader has to defend against.
guard_record_values() {  # <record>
  local project repo mode yolo harness model effort max_missions expires
  project=$(record_field "$1" pilot-project) || return 1
  case $project in /*) ;; *) return 1 ;; esac
  repo=$(record_field "$1" pilot-repo) || return 1
  case $repo in '' | *[!A-Za-z0-9._/-]*) return 1 ;; esac
  mode=$(record_field "$1" pilot-mode) || return 1
  case $mode in drill | direct-PR | local-only) ;; *) return 1 ;; esac
  yolo=$(record_field "$1" pilot-yolo) || return 1
  case $yolo in on | off) ;; *) return 1 ;; esac
  harness=$(record_field "$1" pilot-harness) || return 1
  case " $VERIFIED_HARNESSES " in
    *" $harness "*) ;;
    *) return 1 ;;
  esac
  model=$(record_field "$1" pilot-model) || return 1
  case $model in
    -) ;;
    *[!A-Za-z0-9._/-]* | '') return 1 ;;
  esac
  effort=$(record_field "$1" pilot-effort) || return 1
  case $effort in low | medium | high | xhigh | max | -) ;; *) return 1 ;; esac
  max_missions=$(record_field "$1" pilot-max-missions) || return 1
  case $max_missions in 1 | 2 | 3) ;; *) return 1 ;; esac
  expires=$(record_field "$1" pilot-expires) || return 1
  case $expires in '' | *[!0-9]*) return 1 ;; esac
  return 0
}

cmd_arm() {
  local state data intent backlog
  parse_base "$@" || refuse "$REFUSE_BASE"
  guard_base_bound "$BASE_DIR" || refuse "$REFUSE_BASE"
  BASE_DIR=$(cd "$BASE_DIR" && pwd -P)
  state="$BASE_DIR/state"
  data="$BASE_DIR/data"
  intent="$state/queue-pilot.intent"

  guard_absence_open "$state" "$data" || refuse "$REFUSE_NO_ABSENCE"
  guard_filed_task_id "$ABSENCE_RECORD" || refuse "$REFUSE_NO_TASK_ID"
  if [ -f "$intent" ]; then
    refuse "$REFUSE_SPENT"
  fi
  load_record_fields "$ABSENCE_RECORD" || refuse "$REFUSE_FIELD"
  guard_record_values "$ABSENCE_RECORD" || refuse "$REFUSE_FIELD"

  INTENT_BASE=$BASE_DIR
  INTENT_SOURCE_RECORD=$(basename -- "$ABSENCE_RECORD")
  INTENT_ARMED_EPOCH=$(now)
  backlog="$data/backlog.md"
  guard_posture "$data/projects.md" "$INTENT_PROJECT" "$INTENT_REPO" "$INTENT_MODE" "$INTENT_YOLO" ||
    refuse "$REFUSE_POSTURE"
  guard_backend "$(pilot_backend "$BASE_DIR")" || refuse "$REFUSE_FORCE"
  guard_task_ready "$backlog" "$INTENT_TASK" "$INTENT_REPO" || refuse "$REFUSE_NOT_READY"

  intent_write "$intent" armed || refuse "$REFUSE_NOT_DURABLE"
  guard_intent_durable "$intent" armed || refuse "$REFUSE_NOT_DURABLE"
  printf 'armed %s %s\n' "$INTENT_TASK" "$(identity_key "$INTENT_BASE" "$INTENT_GENERATION" "$INTENT_TASK")"
  return 0
}

cmd_check() {
  local state data intent backlog backend launch_epoch
  parse_base "$@" || refuse "$REFUSE_BASE"
  guard_base_bound "$BASE_DIR" || refuse "$REFUSE_BASE"
  BASE_DIR=$(cd "$BASE_DIR" && pwd -P)
  state="$BASE_DIR/state"
  data="$BASE_DIR/data"
  intent="$state/queue-pilot.intent"
  backlog="$data/backlog.md"

  # 7 open absence (the flag, not the return gate), then 2 the filed id, then 6.
  guard_absence_open "$state" "$data" || refuse "$REFUSE_NO_ABSENCE"
  guard_filed_task_id "$ABSENCE_RECORD" || refuse "$REFUSE_NO_TASK_ID"
  [ -f "$intent" ] || refuse "$REFUSE_NO_TASK_ID"
  guard_intent_armed "$intent" || refuse "$REFUSE_SPENT"

  # 4 identity, then 3 the closed field set read from the intent only.
  guard_identity "$BASE_DIR" "$ABSENCE_RECORD" "$intent" || refuse "$REFUSE_IDENTITY"
  guard_intent_fields "$intent" || refuse "$REFUSE_FIELD"
  INTENT_BASE=$BASE_DIR
  INTENT_GENERATION=$(intent_field "$intent" generation)
  INTENT_SOURCE_RECORD=$(intent_field "$intent" source_record)
  INTENT_AUTHORITY=$(intent_field "$intent" authority)
  INTENT_ARMED_EPOCH=$(intent_field "$intent" armed_epoch)

  # 7 again for expiry: the grant is the absence window, so a lapsed expiry means
  # no open authority remains.
  [ "$(now)" -lt "$INTENT_EXPIRES" ] || refuse "$REFUSE_NO_ABSENCE"

  # 8 ready and unblocked, 16 posture, 13 no force.
  guard_task_ready "$backlog" "$INTENT_TASK" "$INTENT_REPO" || refuse "$REFUSE_NOT_READY"
  guard_posture "$data/projects.md" "$INTENT_PROJECT" "$INTENT_REPO" "$INTENT_MODE" "$INTENT_YOLO" ||
    refuse "$REFUSE_POSTURE"
  backend=$(pilot_backend "$BASE_DIR")
  guard_backend "$backend" || refuse "$REFUSE_FORCE"

  # 10 census, 15 cap, 14 memory, 11 admitted id - all before any effect.
  guard_census "$state" || refuse "$REFUSE_CENSUS"
  guard_mission_cap "$OCCUPIED" "$INTENT_MAX_MISSIONS" || refuse "$REFUSE_CAP"
  guard_memory "$OCCUPIED" || refuse "$REFUSE_MEMORY"
  guard_admitted_id "$READY_IDS" "$INTENT_TASK" || refuse "$REFUSE_ADMITTED"

  # 5 spend the intent atomically before the effect, and 6 make the spend durable:
  # a second trigger can never find it armed again.
  intent_write "$intent" spent || refuse "$REFUSE_NOT_DURABLE"
  guard_intent_durable "$intent" spent || refuse "$REFUSE_NOT_DURABLE"

  # The launch argv is built from the validated intent fields only.
  local -a argv=()
  argv=("${SQUAD_QUEUE_PILOT_SPAWN:-$SCRIPT_DIR/sq-spawn.sh}" "$INTENT_TASK" "$INTENT_PROJECT" \
    --mode "$INTENT_MODE" --yolo "$INTENT_YOLO" --harness "$INTENT_HARNESS" --backend "$backend")
  [ "$INTENT_MODEL" = '-' ] || argv+=(--model "$INTENT_MODEL")
  [ "$INTENT_EFFORT" = '-' ] || argv+=(--effort "$INTENT_EFFORT")

  launch_epoch=$(now)
  pilot_effect "${argv[@]}" >/dev/null 2>&1 || {
    printf 'launch-failed %s\n' "$INTENT_TASK"
    return 1
  }

  # 12 delivery evidence beyond a live endpoint and a running attempt.
  guard_delivery "$state" "$INTENT_TASK" "$backend" "$launch_epoch" || refuse "$REFUSE_DELIVERY"

  printf 'dispatched %s\n' "$INTENT_TASK"
  printf 'endpoint %s %s\n' "$backend" "$DELIVERY_WINDOW"
  printf 'worktree %s\n' "$DELIVERY_WORKTREE"
  printf 'attempt %s\n' "$DELIVERY_EXEC"
  printf 'worker-status working-line present\n'
  printf 'memory available=%s required=%s slot=%s\n' "$MEM_AVAILABLE" "$MEM_REQUIRED" "$MEM_SLOT"
  return 0
}

main() {
  local cmd=${1:-}
  [ "$#" -gt 0 ] && shift
  case $cmd in
    arm) cmd_arm "$@" ;;
    check) cmd_check "$@" ;;
    -h | --help | help) usage ;;
    '')
      usage >&2
      exit 2
      ;;
    *)
      printf 'error: unknown command %s\n' "$cmd" >&2
      exit 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
