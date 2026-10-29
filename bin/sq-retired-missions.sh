#!/usr/bin/env bash
# Durable owner for task-retirement records and bounded orphan reconciliation.
#
# Usage:
#   sq-retired-missions.sh record <task-id>
#     Persist the task's exact retirement identity before teardown can remove
#     state/<id>.meta: the Orca terminal handle, runtime, and worktree identity
#     for a non-XO Orca task, and the fob worktree project and path while fob
#     still owns that worktree. Malformed identity, a missing or symlinked
#     metadata file, an unverified base, or a record that cannot be persisted
#     refuses instead of continuing, so teardown never destroys the only handle a
#     retry would need. XO tasks are skipped because their runtime lifecycle has
#     its own removal path.
#   sq-retired-missions.sh retire-terminal <task-id>
#     Close that recorded exact handle and clear its record only after Orca
#     reports the handle absent. Ambiguous or unreadable inventory, unverifiable
#     runtime ownership, a missing or symlinked task metadata file, a recorded
#     base or terminal that no longer matches, or any unconfirmed close preserves
#     every durable record and exits nonzero, so a rerun retries the same handle.
#   sq-retired-missions.sh sweep
#     Bounded reconciliation that runs only while bootstrap holds the session
#     lock. Recorded terminal handles retire exactly as above. A recorded fob
#     worktree loses its git registration through `git worktree remove` only when
#     no live task record references it, fob no longer owns it, the exact
#     registration and project identity verify, it is clean, and its HEAD is
#     reachable from the default branch or a remote-tracking ref; fob reclaiming
#     the reusable worktree clears its record and keeps the worktree.
#     Every ambiguous, dirty, unreachable, still-owned, or malformed candidate is
#     preserved with its record, the sweep never deletes a worktree directory by
#     hand, a branch, a ref, a patch, or a task record, and
#     SQUAD_RETIRED_MISSIONS_SWEEP_LIMIT bounds the actions taken per kind.
#     docs/configuration.md owns the exact state/.retired-terminals/ and
#     state/.retired-worktrees/ record layout, and AGENTS.md section 2 owns when
#     this sweep is authorized to run.
# Every subcommand refuses inside the drill gate via bin/sq-gate-refuse-lib.sh.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SQUAD_ROOT=${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
SQUAD_BASE=${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}
STATE=${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}
LIMIT=${SQUAD_RETIRED_MISSIONS_SWEEP_LIMIT:-20}
RECORD_IDENTITY_KEYS=(kind task_id base backend terminal worktree_id worktree_path project pool_backend)

# shellcheck source=bin/sq-gate-refuse-lib.sh
. "$SCRIPT_DIR/sq-gate-refuse-lib.sh"
# shellcheck source=bin/sq-pr-lib.sh
. "$SCRIPT_DIR/sq-pr-lib.sh"

case "$LIMIT" in ''|*[!0-9]*) LIMIT=20 ;; esac
[ "$LIMIT" -gt 0 ] || LIMIT=20

usage() {
  echo 'usage: sq-retired-missions.sh record <task-id> | retire-terminal <task-id> | sweep' >&2
}

identity_dir() {
  [ -n "$1" ] && [ -d "$1" ] || return 1
  ( CDPATH='' cd -- "$1" && pwd -P )
}

canonical_dir() {
  [ -n "$1" ] && [ -d "$1" ] && [ ! -L "$1" ] || return 1
  identity_dir "$1"
}

single_link_file() {
  local links
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  if [ "$(uname)" = Darwin ]; then links=$(stat -f %l "$1" 2>/dev/null) || return 1
  else links=$(stat -c %h "$1" 2>/dev/null) || return 1
  fi
  [ "$links" = 1 ]
}

meta_value() {
  local file=$1 key=$2
  awk -v key="$key" 'index($0, "=") { k=substr($0,1,index($0,"=")-1); if (k==key) { print substr($0,index($0,"=")+1); n++ } } END { if (n != 1) exit 1 }' "$file"
}

field_safe() {
  case "$1" in ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  return 0
}

record_dir() {
  local dir=$1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    mkdir -m 700 -- "$dir" || return 1
  fi
  chmod 700 -- "$dir" || return 1
}

record_replace() {  # <file> <content>
  local file=$1 content=$2 tmp
  tmp=$(umask 077; mktemp "${file%/*}/.pending.XXXXXX") || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
  single_link_file "$file"
}

record_write() {  # <dir> <id> <kind> <content>
  local dir=$1 id=$2 kind=$3 content=$4 file observed
  record_dir "$dir" || return 1
  file="$dir/$id.record"
  if [ -e "$file" ] || [ -L "$file" ]; then
    single_link_file "$file" || return 1
    record_load "$file" || return 1
    if ! record_identity_matches "$content"; then
      record_drift_report "$file" "$content"
      return 1
    fi
    observed=$(printf '%s\n' "$content" | sed -n 's/^runtime_id=//p')
    if [ -n "$REC_RUNTIME" ] && [ "$REC_RUNTIME" != unknown ] && [ "$observed" = unknown ]; then
      content=${content/runtime_id=unknown/runtime_id=$REC_RUNTIME}
    fi
    if [ "$REC_CLOSE_ATTEMPTED" = 1 ]; then
      content=$(printf '%s\n' "$content" | sed 's/^close_attempted=.*/close_attempted=1/')
    fi
  fi
  record_replace "$file" "$content"
}

record_identity_value() {  # <key>
  case "$1" in
    kind) printf '%s' "$REC_KIND" ;;
    task_id) printf '%s' "$REC_TASK_ID" ;;
    base) printf '%s' "$REC_BASE" ;;
    backend) printf '%s' "$REC_BACKEND" ;;
    terminal) printf '%s' "$REC_TERMINAL" ;;
    worktree_id) printf '%s' "$REC_WORKTREE_ID" ;;
    worktree_path) printf '%s' "$REC_WORKTREE_PATH" ;;
    project) printf '%s' "$REC_PROJECT" ;;
    pool_backend) printf '%s' "$REC_POOL_BACKEND" ;;
    *) return 1 ;;
  esac
}

record_identity_matches() {  # <content>
  local content=$1 key recorded observed
  for key in "${RECORD_IDENTITY_KEYS[@]}"; do
    recorded=$(record_identity_value "$key") || return 1
    observed=$(printf '%s\n' "$content" | sed -n "s/^$key=//p")
    [ "$recorded" = "$observed" ] || return 1
  done
  return 0
}

record_drift_report() {  # <file> <content>
  local file=$1 content=$2 key recorded observed reported=0
  for key in "${RECORD_IDENTITY_KEYS[@]}"; do
    if ! recorded=$(record_identity_value "$key"); then
      printf 'error: retirement record %s blocks teardown: identity key %s has no recorded value\n' \
        "$file" "$key" >&2
      reported=1
      continue
    fi
    observed=$(printf '%s\n' "$content" | sed -n "s/^$key=//p")
    if [ "$recorded" != "$observed" ]; then
      printf 'error: retirement record %s blocks teardown: %s recorded=%s observed=%s\n' \
        "$file" "$key" "$recorded" "$observed" >&2
      reported=1
    fi
  done
  if [ "$reported" = 0 ]; then
    printf 'error: retirement record %s blocks teardown: recorded identity format differs\n' "$file" >&2
  fi
  printf 'error: a new identity supersedes %s only after the recorded identity is proven absent; start a new Squad session so the locked bootstrap sweep retires and clears it, then rerun teardown; do not delete the record or retire the old identity manually\n' "$file" >&2
}

record_load() {
  local file=$1 line key value seen=' '
  REC_KIND='' REC_TASK_ID='' REC_BASE='' REC_RETIRED_AT=''
  REC_BACKEND='' REC_TERMINAL='' REC_RUNTIME='' REC_CLOSE_ATTEMPTED='' REC_WORKTREE_ID='' REC_WORKTREE_PATH=''
  REC_PROJECT='' REC_POOL_BACKEND=''
  single_link_file "$file" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) key=${line%%=*}; value=${line#*=} ;; *) return 1 ;; esac
    case "$seen" in *" $key "*) return 1 ;; esac
    seen="$seen$key "
    field_safe "$value" || return 1
    case "$key" in
      kind) REC_KIND=$value ;;
      task_id) REC_TASK_ID=$value ;;
      base) REC_BASE=$value ;;
      retired_at) REC_RETIRED_AT=$value ;;
      backend) REC_BACKEND=$value ;;
      terminal) REC_TERMINAL=$value ;;
      runtime_id) REC_RUNTIME=$value ;;
      close_attempted) REC_CLOSE_ATTEMPTED=$value ;;
      worktree_id) REC_WORKTREE_ID=$value ;;
      worktree_path) REC_WORKTREE_PATH=$value ;;
      project) REC_PROJECT=$value ;;
      pool_backend) REC_POOL_BACKEND=$value ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ -n "$REC_KIND" ] && [ -n "$REC_TASK_ID" ] && [ -n "$REC_BASE" ] \
    && [ -n "$REC_RETIRED_AT" ] && fm_pr_task_id_valid "$REC_TASK_ID" || return 1
  case "$REC_KIND" in
    terminal) [ "$REC_BACKEND" = orca ] && [ -n "$REC_TERMINAL" ] && [ -n "$REC_WORKTREE_ID" ] && [ -n "$REC_WORKTREE_PATH" ] && [ -n "$REC_RUNTIME" ] && { [ "$REC_CLOSE_ATTEMPTED" = 0 ] || [ "$REC_CLOSE_ATTEMPTED" = 1 ]; } ;;
    worktree) [ -n "$REC_PROJECT" ] && [ -n "$REC_WORKTREE_PATH" ] && [ -n "$REC_POOL_BACKEND" ] ;;
    *) return 1 ;;
  esac
}

record_task() {
  local id=$1 meta base backend terminal worktree_id worktree_path project retired_at runtime=unknown content canonical_project canonical_wt kind
  fm_pr_task_id_valid "$id" || { echo "error: invalid task id" >&2; return 1; }
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { echo "error: live task metadata is unavailable" >&2; return 1; }
  kind=$(meta_value "$meta" kind 2>/dev/null || true)
  [ "$kind" = xo ] && return 0
  base=$(identity_dir "$SQUAD_BASE") || { echo "error: base identity cannot be verified" >&2; return 1; }
  backend=$(meta_value "$meta" backend 2>/dev/null || true)
  terminal=$(meta_value "$meta" terminal 2>/dev/null || true)
  worktree_id=$(meta_value "$meta" orca_worktree_id 2>/dev/null || true)
  worktree_path=$(meta_value "$meta" worktree 2>/dev/null || true)
  project=$(meta_value "$meta" project 2>/dev/null || true)
  retired_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || { echo "error: retirement time unavailable" >&2; return 1; }

  if [ "$backend" = orca ] && [ -n "$terminal" ]; then
    if ! field_safe "$terminal" || ! field_safe "$worktree_id" || ! field_safe "$worktree_path"; then
      echo "error: Orca terminal identity is malformed" >&2
      return 1
    fi
    [ -n "$worktree_id" ] && [ -n "$worktree_path" ] \
      || { echo "error: Orca terminal worktree identity is unavailable" >&2; return 1; }
    runtime=$(orca_runtime_id 2>/dev/null || printf unknown)
    content=$(printf 'kind=terminal\ntask_id=%s\nbase=%s\nretired_at=%s\nbackend=orca\nterminal=%s\nruntime_id=%s\nclose_attempted=0\nworktree_id=%s\nworktree_path=%s' \
      "$id" "$base" "$retired_at" "$terminal" "$runtime" "$worktree_id" "$worktree_path")
    record_write "$STATE/.retired-terminals" "$id" terminal "$content" \
      || { echo "error: could not persist the Orca terminal retirement record" >&2; return 1; }
  fi

  if [ -n "$worktree_path" ] && [ -n "$project" ] && [ "$backend" != orca ]; then
    canonical_wt=$(canonical_dir "$worktree_path" 2>/dev/null || true)
    canonical_project=$(identity_dir "$project" 2>/dev/null || true)
    [ -n "$canonical_wt" ] || return 0
    [ "$(fob_path_state "$project" "$canonical_wt")" = pool-owned ] || return 0
    if [ -z "$canonical_project" ] || ! git -C "$canonical_project" rev-parse --git-dir >/dev/null 2>&1; then
      echo "error: worktree project identity cannot be verified" >&2
      return 1
    fi
    content=$(printf 'kind=worktree\ntask_id=%s\nbase=%s\nretired_at=%s\nproject=%s\nworktree_path=%s\npool_backend=fob' \
      "$id" "$base" "$retired_at" "$canonical_project" "$canonical_wt")
    record_write "$STATE/.retired-worktrees" "$id" worktree "$content" \
      || { echo "error: could not persist the fob worktree retirement record" >&2; return 1; }
  fi
}

orca_runtime_id() {
  local status
  status=$(orca status --json) || return 1
  printf '%s' "$status" | node -e '
const fs=require("fs"),d=JSON.parse(fs.readFileSync(0,"utf8")),r=d.result&&d.result.runtime;
const runtime=String((r&&r.runtimeId)||(d._meta&&d._meta.runtimeId)||"");
if(d.ok!==true || !r || r.reachable!==true || r.state!=="ready" || !runtime) process.exit(1);
process.stdout.write(runtime);
'
}

record_update_close_attempted() {
  local file=$1 content
  content=$(printf 'kind=terminal\ntask_id=%s\nbase=%s\nretired_at=%s\nbackend=orca\nterminal=%s\nruntime_id=%s\nclose_attempted=1\nworktree_id=%s\nworktree_path=%s' \
    "$REC_TASK_ID" "$REC_BASE" "$REC_RETIRED_AT" "$REC_TERMINAL" "$REC_RUNTIME" "$REC_WORKTREE_ID" "$REC_WORKTREE_PATH")
  record_replace "$file" "$content"
}

record_references_live_meta() {  # <task-id> <field> <value>
  local id=$1 field=$2 value=$3 meta status
  if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ]; then return 0; fi
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
    status=0
    grep -qxF "$field=$value" "$meta" 2>/dev/null || status=$?
    [ "$status" -eq 0 ] && return 0
    [ "$status" -eq 1 ] || return 0
  done
  return 1
}

orca_inventory_check() {  # <handle> <runtime-id|unknown> <worktree-id> <path> [<absence-needs-existing-scope>]
  local handle=$1 expected_runtime=$2 worktree_id=$3 path=$4 scope_required=${5:-1} status inventory runtime
  status=$(orca status --json) || return 1
  runtime=$(printf '%s' "$status" | node -e '
const fs=require("fs"),d=JSON.parse(fs.readFileSync(0,"utf8")),r=d.result&&d.result.runtime;
const runtime=String((r&&r.runtimeId)||(d._meta&&d._meta.runtimeId)||"");
if(d.ok!==true || !r || r.reachable!==true || r.state!=="ready" || !runtime) process.exit(1);
if(process.argv[1]!=="unknown" && runtime!==process.argv[1]) process.exit(1);
process.stdout.write(runtime);
' "$expected_runtime") || return 1
  [ -n "$runtime" ] || return 1
  inventory=$(orca terminal list --worktree "id:$worktree_id" --json) || return 1
  inventory=$(printf '%s' "$inventory" | node -e '
const fs=require("fs"),d=JSON.parse(fs.readFileSync(0,"utf8")),a=d.result&&d.result.terminals;
if(d.ok!==true || !d._meta || d._meta.runtimeId!==process.argv[1] || !d.result || d.result.truncated!==false || ((d.result.hostScope&&d.result.hostScope.omittedHostIds)||[]).length!==0 || !Array.isArray(a) || a.some(t=>!t||typeof t.handle!=="string")) process.exit(2);
const found=a.filter(t=>t.handle===process.argv[2]);
if(found.length===0) { process.stdout.write("absent"); process.exit(0); }
if(found.length!==1 || found[0].worktreeId!==process.argv[3] || found[0].worktreePath!==process.argv[4]) process.exit(2);
process.stdout.write("present");
' "$runtime" "$handle" "$worktree_id" "$path") || return 1
  if [ "$scope_required" = 1 ] && [ "$inventory" = absent ] && { [ ! -d "$path" ] || [ -L "$path" ]; }; then
    return 1
  fi
  printf '%s\n' "$inventory"
}

terminal_state() {  # <handle> <recorded-runtime> <worktree-id> <path> [<absence-needs-existing-scope>]
  local state scope_required=${5:-1}
  state=$(orca_inventory_check "$1" "$2" "$3" "$4" "$scope_required" 2>/dev/null) || state=ambiguous
  if [ "$state" = ambiguous ] && [ "$2" != unknown ]; then
    state=$(orca_inventory_check "$1" unknown "$3" "$4" "$scope_required" 2>/dev/null) || state=ambiguous
  fi
  printf '%s\n' "$state"
}

remove_record() {
  local file=$1
  single_link_file "$file" || return 1
  rm -f -- "$file" && [ ! -e "$file" ] && [ ! -L "$file" ]
}

retire_live_terminal() {
  local id=$1 file="$STATE/.retired-terminals/$1.record" state base current
  fm_pr_task_id_valid "$id" || return 1
  [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || { echo "preserved terminal $id: live task metadata is unavailable"; return 1; }
  record_load "$file" && [ "$REC_KIND" = terminal ] && [ "$REC_TASK_ID" = "$id" ] \
    || { echo "preserved terminal $id: retirement identity is unavailable"; return 1; }
  base=$(identity_dir "$SQUAD_BASE" 2>/dev/null || true)
  [ -n "$base" ] && [ "$REC_BASE" = "$base" ] \
    || { echo "preserved terminal $REC_TERMINAL: base identity does not match"; return 1; }
  [ "$(meta_value "$STATE/$id.meta" terminal 2>/dev/null || true)" = "$REC_TERMINAL" ] \
    || { echo "preserved terminal $REC_TERMINAL: task metadata identity differs"; return 1; }
  state=$(terminal_state "$REC_TERMINAL" "$REC_RUNTIME" "$REC_WORKTREE_ID" "$REC_WORKTREE_PATH")
  case "$state" in
    absent)
      remove_record "$file" && { echo "retired terminal $REC_TERMINAL: exact handle absence confirmed"; return 0; }
      echo "preserved terminal $REC_TERMINAL: retirement record could not be cleared"
      return 1
      ;;
    present) ;;
    *) echo "preserved terminal $REC_TERMINAL: Orca ownership inventory is ambiguous or unavailable"; return 1 ;;
  esac
  current=$(orca_runtime_id 2>/dev/null || true)
  [ -n "$current" ] \
    || { echo "preserved terminal $REC_TERMINAL: runtime ownership could not be verified"; return 1; }
  REC_RUNTIME=$current
  record_update_close_attempted "$file" || { echo "preserved terminal $REC_TERMINAL: could not durably record the close attempt"; return 1; }
  orca terminal close --terminal "$REC_TERMINAL" --json >/dev/null 2>&1 || true
  state=$(terminal_state "$REC_TERMINAL" "$REC_RUNTIME" "$REC_WORKTREE_ID" "$REC_WORKTREE_PATH" 0)
  if [ "$state" = absent ] && remove_record "$file"; then
    echo "retired terminal $REC_TERMINAL: exact handle closed and absence confirmed"
    return 0
  fi
  echo "preserved terminal $REC_TERMINAL: close or exact-handle absence could not be confirmed"
  return 1
}

sweep_terminals() {
  local base dir file acted=0 limited=0 id state current
  dir="$STATE/.retired-terminals"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for file in "$dir"/*.record; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    id=${file##*/}; id=${id%.record}
    if ! record_load "$file" || [ "$REC_KIND" != terminal ] || [ "$REC_TASK_ID" != "$id" ]; then
      echo "preserved terminal record $id: malformed or unsafe record"
      continue
    fi
    base=$(identity_dir "$SQUAD_BASE" 2>/dev/null || true)
    if [ -z "$base" ] || [ "$REC_BASE" != "$base" ]; then
      echo "preserved terminal $REC_TERMINAL: base identity does not match"
      continue
    fi
    if record_references_live_meta "$id" terminal "$REC_TERMINAL"; then
      echo "preserved terminal $REC_TERMINAL: live task metadata wins"
      continue
    fi
    state=$(terminal_state "$REC_TERMINAL" "$REC_RUNTIME" "$REC_WORKTREE_ID" "$REC_WORKTREE_PATH")
    case "$state" in
      absent)
        if [ "$acted" -ge "$LIMIT" ]; then
          limited=1
        else
          acted=$((acted + 1))
          if remove_record "$file"; then echo "retired terminal $REC_TERMINAL: exact handle absence confirmed"
          else echo "preserved terminal $REC_TERMINAL: could not remove retirement record"; fi
        fi
        ;;
      present)
        if [ "$acted" -ge "$LIMIT" ]; then
          limited=1
          continue
        fi
        acted=$((acted + 1))
        current=$(orca_runtime_id 2>/dev/null || true)
        if [ -z "$current" ]; then
          echo "preserved terminal $REC_TERMINAL: runtime ownership could not be verified"
          continue
        fi
        REC_RUNTIME=$current
        record_update_close_attempted "$file" || { echo "preserved terminal $REC_TERMINAL: could not durably record the close attempt"; continue; }
        orca terminal close --terminal "$REC_TERMINAL" --json >/dev/null 2>&1 || true
        state=$(terminal_state "$REC_TERMINAL" "$REC_RUNTIME" "$REC_WORKTREE_ID" "$REC_WORKTREE_PATH" 0)
        if [ "$state" = absent ] && remove_record "$file"; then
          echo "retired terminal $REC_TERMINAL: exact handle closed and absence confirmed"
        else
          echo "preserved terminal $REC_TERMINAL: close or exact-handle absence could not be confirmed"
        fi
        ;;
      *) echo "preserved terminal $REC_TERMINAL: Orca ownership inventory is ambiguous or unavailable" ;;
    esac
  done
  [ "$limited" = 0 ] || echo "preserved terminal records: sweep action limit $LIMIT reached"
}

fob_path_state() {  # <project> <path> -> pool-owned|not-owned|unknown
  local project=$1 path=$2 out
  command -v fob >/dev/null 2>&1 || { printf unknown; return 0; }
  out=$(cd "$project" && fob status --json 2>/dev/null) || { printf unknown; return 0; }
  printf '%s' "$out" | node -e '
const fs=require("fs");let d;try{d=JSON.parse(fs.readFileSync(0,"utf8"));}catch(_){process.exit(2);}
if(!Array.isArray(d) || d.some(x=>!x || typeof x.path!=="string" || typeof x.status!=="string")) process.exit(2);
let target;try{target=fs.realpathSync(process.argv[1]);}catch(_){process.exit(2);}
const a=d.filter(x=>{try{return fs.realpathSync(x.path)===target;}catch(_){return false;}});
if(a.length>1) process.exit(2);
process.stdout.write(a.length ? "pool-owned" : "not-owned");
' "$path" 2>/dev/null || printf unknown
}

worktree_registered_once() {  # <project> <path>
  local project=$1 target=$2 listed line found=0
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      "worktree $target") found=$((found + 1)) ;;
    esac
  done <<EOF
$listed
EOF
  [ "$found" -eq 1 ]
}

worktree_belongs_to_project() {  # <project> <path>
  local expected actual
  expected=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  actual=$(git -C "$2" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  expected=$(identity_dir "$expected" 2>/dev/null || true)
  actual=$(identity_dir "$actual" 2>/dev/null || true)
  [ -n "$expected" ] && [ -n "$actual" ] && [ "$expected" = "$actual" ]
}

worktree_reachable() {  # <project> <path>
  local project=$1 path=$2 head name ref found=0
  head=$(git -C "$path" rev-parse --verify HEAD 2>/dev/null) || return 1
  name=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$name" ]; then
    name=${name#origin/}
  else
    for ref in main master; do
      if git -C "$project" show-ref --verify --quiet "refs/heads/$ref"; then name=$ref; break; fi
    done
  fi
  if [ -n "$name" ] && git -C "$path" merge-base --is-ancestor "$head" "refs/heads/$name" 2>/dev/null; then return 0; fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if git -C "$path" merge-base --is-ancestor "$head" "$ref" 2>/dev/null; then found=1; break; fi
  done < <(git -C "$project" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)
  [ "$found" -eq 1 ]
}

sweep_worktrees() {
  local dir file acted=0 limited=0 id base dirty project path canonical status
  dir="$STATE/.retired-worktrees"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  for file in "$dir"/*.record; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    id=${file##*/}; id=${id%.record}
    if ! record_load "$file" || [ "$REC_KIND" != worktree ] || [ "$REC_TASK_ID" != "$id" ]; then
      echo "preserved worktree record $id: malformed or unsafe record"
      continue
    fi
    base=$(identity_dir "$SQUAD_BASE" 2>/dev/null || true)
    if [ -z "$base" ] || [ "$REC_BASE" != "$base" ]; then
      echo "preserved worktree $REC_WORKTREE_PATH: base identity does not match"
      continue
    fi
    if record_references_live_meta "$id" worktree "$REC_WORKTREE_PATH"; then
      echo "preserved worktree $REC_WORKTREE_PATH: live task metadata wins"
      continue
    fi
    path=$REC_WORKTREE_PATH; project=$REC_PROJECT
    canonical=$(identity_dir "$project" 2>/dev/null || true)
    if [ -z "$canonical" ] || [ "$canonical" != "$project" ] || ! git -C "$project" rev-parse --git-dir >/dev/null 2>&1; then
      echo "preserved worktree $path: project repository identity is unavailable"
      continue
    fi
    if [ ! -d "$path" ] || [ -L "$path" ] || [ "$(canonical_dir "$path" 2>/dev/null || true)" != "$path" ]; then
      echo "preserved worktree $path: exact worktree path is unavailable or redirected"
      continue
    fi
    status=$(fob_path_state "$project" "$path")
    case "$status" in
      pool-owned)
        if [ "$acted" -ge "$LIMIT" ]; then limited=1
        elif remove_record "$file"; then acted=$((acted + 1)); echo "preserved worktree $path: fob still owns the reusable worktree"
        else acted=$((acted + 1)); echo "preserved worktree $path: fob owns it but retirement record could not be cleared"; fi
        continue
        ;;
      not-owned) ;;
      *) echo "preserved worktree $path: fob pool ownership could not be verified"; continue ;;
    esac
    if record_references_live_meta "$id" worktree "$path"; then
      echo "preserved worktree $path: live task metadata wins"
      continue
    fi
    if ! worktree_registered_once "$project" "$path"; then
      echo "preserved worktree $path: exact git registration could not be verified"
      continue
    fi
    if ! worktree_belongs_to_project "$project" "$path"; then
      echo "preserved worktree $path: git worktree identity does not belong to the recorded project"
      continue
    fi
    dirty=$(git -C "$path" status --porcelain 2>/dev/null) || dirty=unknown
    if [ -n "$dirty" ]; then
      echo "preserved worktree $path: uncommitted changes are present or status is unreadable"
      continue
    fi
    if ! worktree_reachable "$project" "$path"; then
      echo "preserved worktree $path: HEAD is not reachable from the default branch or any remote-tracking ref"
      continue
    fi
    if [ "$acted" -ge "$LIMIT" ]; then
      limited=1
      continue
    fi
    acted=$((acted + 1))
    if git -C "$project" worktree remove -- "$path"; then
      if remove_record "$file"; then echo "retired worktree $path: clean HEAD is reachable and exact registration was removed"
      else echo "preserved worktree record $id: worktree retired but record cleanup failed"; fi
    else
      echo "preserved worktree $path: owning git worktree removal failed"
    fi
  done
  [ "$limited" = 0 ] || echo "preserved worktree records: sweep action limit $LIMIT reached"
}

sweep() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  sweep_terminals
  sweep_worktrees
}

case "${1:-}" in
  record) [ "$#" -eq 2 ] || { usage; exit 2; }; fm_refuse_if_gate_agent; record_task "$2" ;;
  retire-terminal) [ "$#" -eq 2 ] || { usage; exit 2; }; fm_refuse_if_gate_agent; retire_live_terminal "$2" ;;
  sweep) [ "$#" -eq 1 ] || { usage; exit 2; }; fm_refuse_if_gate_agent; sweep ;;
  *) usage; exit 2 ;;
esac
