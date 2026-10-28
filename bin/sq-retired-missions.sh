#!/usr/bin/env bash
# Durable owner for task-retirement records and bounded orphan reconciliation.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SQUAD_ROOT=${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
SQUAD_BASE=${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}
STATE=${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}
LIMIT=${SQUAD_RETIRED_MISSIONS_SWEEP_LIMIT:-20}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=20 ;; esac
[ "$LIMIT" -gt 0 ] || LIMIT=20

usage() {
  echo 'usage: sq-retired-missions.sh record <task-id> | sweep' >&2
}

valid_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

canonical_dir() {
  [ -n "$1" ] && [ -d "$1" ] && [ ! -L "$1" ] || return 1
  ( CDPATH='' cd -- "$1" && pwd -P )
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

record_write() {
  local dir=$1 id=$2 content=$3 file tmp
  record_dir "$dir" || return 1
  file="$dir/$id.record"
  if [ -e "$file" ] || [ -L "$file" ]; then
    single_link_file "$file" || return 1
    cmp -s <(grep -v '^retired_at=' "$file") <(printf '%s\n' "$content" | grep -v '^retired_at=')
    return $?
  fi
  tmp=$(umask 077; mktemp "$dir/.pending.XXXXXX") || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! chmod 600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
  single_link_file "$file"
}

record_load() {
  local file=$1 line key value seen=' '
  REC_KIND= REC_TASK_ID= REC_BASE= REC_RETIRED_AT=
  REC_BACKEND= REC_TERMINAL= REC_RUNTIME= REC_CLOSE_ATTEMPTED= REC_WORKTREE_ID= REC_WORKTREE_PATH=
  REC_PROJECT= REC_POOL_BACKEND=
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
    && [ -n "$REC_RETIRED_AT" ] && valid_id "$REC_TASK_ID" || return 1
  case "$REC_KIND" in
    terminal) [ "$REC_BACKEND" = orca ] && [ -n "$REC_TERMINAL" ] && [ -n "$REC_WORKTREE_ID" ] && [ -n "$REC_WORKTREE_PATH" ] && [ -n "$REC_RUNTIME" ] && { [ "$REC_CLOSE_ATTEMPTED" = 0 ] || [ "$REC_CLOSE_ATTEMPTED" = 1 ]; } ;;
    worktree) [ -n "$REC_PROJECT" ] && [ -n "$REC_WORKTREE_PATH" ] && [ -n "$REC_POOL_BACKEND" ] ;;
    *) return 1 ;;
  esac
}

record_task() {
  local id=$1 meta base backend terminal worktree_id worktree_path project retired_at runtime=unknown content canonical_project canonical_wt
  valid_id "$id" || { echo "error: invalid task id" >&2; return 1; }
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { echo "error: live task metadata is unavailable" >&2; return 1; }
  base=$(canonical_dir "$SQUAD_BASE") || { echo "error: base identity cannot be verified" >&2; return 1; }
  backend=$(meta_value "$meta" backend 2>/dev/null || true)
  terminal=$(meta_value "$meta" terminal 2>/dev/null || true)
  worktree_id=$(meta_value "$meta" orca_worktree_id 2>/dev/null || true)
  worktree_path=$(meta_value "$meta" worktree 2>/dev/null || true)
  project=$(meta_value "$meta" project 2>/dev/null || true)
  retired_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || { echo "error: retirement time unavailable" >&2; return 1; }

  if [ "$backend" = orca ] && [ -n "$terminal" ]; then
    field_safe "$terminal" && field_safe "$worktree_id" && field_safe "$worktree_path" \
      || { echo "error: Orca terminal identity is malformed" >&2; return 1; }
    if [ -n "$worktree_id" ] && [ -n "$worktree_path" ]; then
      runtime=$(orca_runtime_id 2>/dev/null || printf unknown)
    fi
    content=$(printf 'kind=terminal\ntask_id=%s\nbase=%s\nretired_at=%s\nbackend=orca\nterminal=%s\nruntime_id=%s\nclose_attempted=0\nworktree_id=%s\nworktree_path=%s' \
      "$id" "$base" "$retired_at" "$terminal" "$runtime" "$worktree_id" "$worktree_path")
    record_write "$STATE/.retired-terminals" "$id" "$content" \
      || { echo "error: could not persist the Orca terminal retirement record" >&2; return 1; }
  fi

  if [ -n "$worktree_path" ] && [ -n "$project" ] && [ "$backend" != orca ]; then
    canonical_wt=$(canonical_dir "$worktree_path" 2>/dev/null || true)
    canonical_project=$(canonical_dir "$project" 2>/dev/null || true)
    case "$canonical_wt" in
      "${HOME:-/nonexistent}"/.fob/pi-durable-host-*/*) ;;
      *) return 0 ;;
    esac
    [ -n "$canonical_project" ] && git -C "$canonical_project" rev-parse --git-dir >/dev/null 2>&1 \
      || { echo "error: worktree project identity cannot be verified" >&2; return 1; }
    content=$(printf 'kind=worktree\ntask_id=%s\nbase=%s\nretired_at=%s\nproject=%s\nworktree_path=%s\npool_backend=fob' \
      "$id" "$base" "$retired_at" "$canonical_project" "$canonical_wt")
    record_write "$STATE/.retired-worktrees" "$id" "$content" \
      || { echo "error: could not persist the fob worktree retirement record" >&2; return 1; }
  fi
}

orca_runtime_id() {
  local status
  status=$(orca status --json) || return 1
  printf '%s' "$status" | node -e '
const fs=require("fs"),d=JSON.parse(fs.readFileSync(0,"utf8")),r=d.result&&d.result.runtime;
if(d.ok!==true || !r || r.reachable!==true || r.state!=="ready" || typeof r.runtimeId!=="string" || !r.runtimeId) process.exit(1);
process.stdout.write(r.runtimeId);
'
}

record_update_close_attempted() {
  local file=$1 content tmp
  content=$(printf 'kind=terminal\ntask_id=%s\nbase=%s\nretired_at=%s\nbackend=orca\nterminal=%s\nruntime_id=%s\nclose_attempted=1\nworktree_id=%s\nworktree_path=%s' \
    "$REC_TASK_ID" "$REC_BASE" "$REC_RETIRED_AT" "$REC_TERMINAL" "$REC_RUNTIME" "$REC_WORKTREE_ID" "$REC_WORKTREE_PATH")
  tmp=$(umask 077; mktemp "${file%/*}/.pending.XXXXXX") || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
  single_link_file "$file"
}

record_references_live_meta() {  # <task-id> <field> <value>
  local id=$1 field=$2 value=$3 meta
  if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ]; then return 0; fi
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
    grep -qxF "$field=$value" "$meta" 2>/dev/null && return 0
  done
  return 1
}

orca_inventory_check() {  # <handle> <runtime-id> <worktree-id> <path> -> present|absent
  local handle=$1 expected_runtime=$2 worktree_id=$3 path=$4 status inventory runtime
  status=$(orca status --json) || return 1
  runtime=$(printf '%s' "$status" | node -e '
const fs=require("fs"),d=JSON.parse(fs.readFileSync(0,"utf8")),r=d.result&&d.result.runtime;
if(d.ok!==true || !r || r.reachable!==true || r.state!=="ready" || String(r.runtimeId||"")!==process.argv[1]) process.exit(1);
process.stdout.write(String(r.runtimeId));
' "$expected_runtime") || return 1
  [ "$runtime" = "$expected_runtime" ] || return 1
  inventory=$(orca terminal list --worktree "id:$worktree_id" --json) || return 1
  printf '%s' "$inventory" | node -e '
const fs=require("fs"),d=JSON.parse(fs.readFileSync(0,"utf8")),a=d.result&&d.result.terminals;
if(d.ok!==true || !d._meta || d._meta.runtimeId!==process.argv[1] || !d.result || d.result.truncated!==false || ((d.result.hostScope&&d.result.hostScope.omittedHostIds)||[]).length!==0 || !Array.isArray(a) || a.some(t=>!t||typeof t.handle!=="string")) process.exit(2);
const found=a.filter(t=>t.handle===process.argv[2]);
if(found.length===0) { process.stdout.write("absent"); process.exit(0); }
if(found.length!==1 || found[0].worktreeId!==process.argv[3] || found[0].worktreePath!==process.argv[4]) process.exit(2);
process.stdout.write("present");
' "$expected_runtime" "$handle" "$worktree_id" "$path"
}

remove_record() {
  local file=$1
  single_link_file "$file" || return 1
  rm -f -- "$file" && [ ! -e "$file" ] && [ ! -L "$file" ]
}

retire_live_terminal() {
  local id=$1 file="$STATE/.retired-terminals/$1.record" state base
  valid_id "$id" || return 1
  [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || { echo "preserved terminal $id: live task metadata is unavailable"; return 1; }
  record_load "$file" && [ "$REC_KIND" = terminal ] && [ "$REC_TASK_ID" = "$id" ] \
    || { echo "preserved terminal $id: retirement identity is unavailable"; return 1; }
  base=$(canonical_dir "$SQUAD_BASE" 2>/dev/null || true)
  [ -n "$base" ] && [ "$REC_BASE" = "$base" ] \
    || { echo "preserved terminal $REC_TERMINAL: base identity does not match"; return 1; }
  [ "$(meta_value "$STATE/$id.meta" terminal 2>/dev/null || true)" = "$REC_TERMINAL" ] \
    || { echo "preserved terminal $REC_TERMINAL: task metadata identity differs"; return 1; }
  [ "$REC_RUNTIME" != unknown ] \
    || { echo "preserved terminal $REC_TERMINAL: runtime ownership could not be verified"; return 1; }
  state=$(orca_inventory_check "$REC_TERMINAL" "$REC_RUNTIME" "$REC_WORKTREE_ID" "$REC_WORKTREE_PATH" 2>/dev/null) \
    || state=ambiguous
  case "$state" in
    absent)
      if [ "$REC_CLOSE_ATTEMPTED" = 1 ]; then
        remove_record "$file" && { echo "retired terminal $REC_TERMINAL: exact handle absence confirmed"; return 0; }
        echo "preserved terminal $REC_TERMINAL: retirement record could not be cleared"
      else
        echo "preserved terminal $REC_TERMINAL: exact handle was absent before a close could be verified"
      fi
      return 1
      ;;
    present) ;;
    *) echo "preserved terminal $REC_TERMINAL: Orca ownership inventory is ambiguous or unavailable"; return 1 ;;
  esac
  record_update_close_attempted "$file" || { echo "preserved terminal $REC_TERMINAL: could not durably record the close attempt"; return 1; }
  orca terminal close --terminal "$REC_TERMINAL" --json >/dev/null 2>&1 || true
  state=$(orca_inventory_check "$REC_TERMINAL" "$REC_RUNTIME" "$REC_WORKTREE_ID" "$REC_WORKTREE_PATH" 2>/dev/null) \
    || state=ambiguous
  if [ "$state" = absent ] && remove_record "$file"; then
    echo "retired terminal $REC_TERMINAL: exact handle closed and absence confirmed"
    return 0
  fi
  echo "preserved terminal $REC_TERMINAL: close or exact-handle absence could not be confirmed"
  return 1
}

sweep_terminals() {
  local base dir file count id state reason
  dir="$STATE/.retired-terminals"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  count=0
  for file in "$dir"/*.record; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$LIMIT" ]; then
      echo "preserved terminal records: sweep limit $LIMIT reached"
      break
    fi
    id=${file##*/}; id=${id%.record}
    if ! record_load "$file" || [ "$REC_KIND" != terminal ] || [ "$REC_TASK_ID" != "$id" ]; then
      echo "preserved terminal record $id: malformed or unsafe record"
      continue
    fi
    base=$(canonical_dir "$SQUAD_BASE" 2>/dev/null || true)
    if [ -z "$base" ] || [ "$REC_BASE" != "$base" ]; then
      echo "preserved terminal $REC_TERMINAL: base identity does not match"
      continue
    fi
    if record_references_live_meta "$id" terminal "$REC_TERMINAL"; then
      echo "preserved terminal $REC_TERMINAL: live task metadata wins"
      continue
    fi
    if [ "$REC_RUNTIME" = unknown ]; then
      echo "preserved terminal $REC_TERMINAL: runtime ownership was not verified at retirement"
      continue
    fi
    state=$(orca_inventory_check "$REC_TERMINAL" "$REC_RUNTIME" "$REC_WORKTREE_ID" "$REC_WORKTREE_PATH" 2>/dev/null) || state=ambiguous
    case "$state" in
      absent)
        if [ "$REC_CLOSE_ATTEMPTED" = 1 ] && remove_record "$file"; then
          echo "retired terminal $REC_TERMINAL: exact handle absence confirmed"
        elif [ "$REC_CLOSE_ATTEMPTED" = 0 ]; then
          echo "preserved terminal $REC_TERMINAL: exact handle was absent before a close could be verified"
        else
          echo "preserved terminal $REC_TERMINAL: could not remove retirement record"
        fi
        ;;
      present)
        record_update_close_attempted "$file" || { echo "preserved terminal $REC_TERMINAL: could not durably record the close attempt"; continue; }
        orca terminal close --terminal "$REC_TERMINAL" --json >/dev/null 2>&1 || true
        state=$(orca_inventory_check "$REC_TERMINAL" "$REC_RUNTIME" "$REC_WORKTREE_ID" "$REC_WORKTREE_PATH" 2>/dev/null) || state=ambiguous
        if [ "$state" = absent ] && remove_record "$file"; then
          echo "retired terminal $REC_TERMINAL: exact handle closed and absence confirmed"
        else
          echo "preserved terminal $REC_TERMINAL: close or exact-handle absence could not be confirmed"
        fi
        ;;
      *) echo "preserved terminal $REC_TERMINAL: Orca ownership inventory is ambiguous or unavailable" ;;
    esac
  done
}

fob_path_state() {  # <project> <path> -> pool-owned|not-owned|unknown
  local project=$1 path=$2 out
  command -v fob >/dev/null 2>&1 || { printf unknown; return 0; }
  out=$(cd "$project" && fob status --json 2>/dev/null) || { printf unknown; return 0; }
  printf '%s' "$out" | node -e '
const fs=require("fs");let d;try{d=JSON.parse(fs.readFileSync(0,"utf8"));}catch(_){process.exit(2);}
if(!Array.isArray(d) || d.some(x=>!x || typeof x.path!=="string" || typeof x.status!=="string")) process.exit(2);
const a=d.filter(x=>x.path===process.argv[1]); if(a.length>1) process.exit(2);
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

worktree_reachable() {  # <project> <path>
  local project=$1 path=$2 head ref default found=0
  head=$(git -C "$path" rev-parse --verify HEAD 2>/dev/null) || return 1
  default=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$default" ] && git -C "$path" merge-base --is-ancestor "$head" "$default" 2>/dev/null; then return 0; fi
  if [ -z "$default" ]; then
    for default in main master; do
      if git -C "$project" show-ref --verify --quiet "refs/heads/$default" \
        && git -C "$path" merge-base --is-ancestor "$head" "refs/heads/$default" 2>/dev/null; then return 0; fi
    done
  fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if git -C "$path" merge-base --is-ancestor "$head" "$ref" 2>/dev/null; then found=1; break; fi
  done < <(git -C "$project" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)
  [ "$found" -eq 1 ]
}

sweep_worktrees() {
  local dir file count id base live pool dirty project path canonical status
  dir="$STATE/.retired-worktrees"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  count=0
  for file in "$dir"/*.record; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$LIMIT" ]; then
      echo "preserved worktree records: sweep limit $LIMIT reached"
      break
    fi
    id=${file##*/}; id=${id%.record}
    if ! record_load "$file" || [ "$REC_KIND" != worktree ] || [ "$REC_TASK_ID" != "$id" ]; then
      echo "preserved worktree record $id: malformed or unsafe record"
      continue
    fi
    base=$(canonical_dir "$SQUAD_BASE" 2>/dev/null || true)
    if [ -z "$base" ] || [ "$REC_BASE" != "$base" ]; then
      echo "preserved worktree $REC_WORKTREE_PATH: base identity does not match"
      continue
    fi
    if record_references_live_meta "$id" worktree "$REC_WORKTREE_PATH"; then
      echo "preserved worktree $REC_WORKTREE_PATH: live task metadata wins"
      continue
    fi
    path=$REC_WORKTREE_PATH; project=$REC_PROJECT
    case "$path" in "${HOME:-/nonexistent}"/.fob/pi-durable-host-*/*) ;; *) echo "preserved worktree $path: outside the recorded fob pool scope"; continue ;; esac
    canonical=$(canonical_dir "$project" 2>/dev/null || true)
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
        remove_record "$file" && echo "preserved worktree $path: fob still owns the reusable worktree" || echo "preserved worktree $path: fob owns it but retirement record could not be cleared"
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
    dirty=$(git -C "$path" status --porcelain 2>/dev/null) || dirty=unknown
    if [ -n "$dirty" ]; then
      echo "preserved worktree $path: uncommitted changes are present or status is unreadable"
      continue
    fi
    if ! worktree_reachable "$project" "$path"; then
      echo "preserved worktree $path: HEAD is not reachable from the default branch or any remote-tracking ref"
      continue
    fi
    if git -C "$project" worktree remove -- "$path" \
      && git -C "$project" worktree prune; then
      if remove_record "$file"; then echo "retired worktree $path: clean HEAD is reachable and exact registration was removed"
      else echo "preserved worktree record $id: worktree retired but record cleanup failed"; fi
    else
      echo "preserved worktree $path: owning git worktree removal or prune failed"
    fi
  done
}

sweep() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  sweep_terminals
  sweep_worktrees
}

case "${1:-}" in
  record) [ "$#" -eq 2 ] || { usage; exit 2; }; record_task "$2" ;;
  retire-terminal) [ "$#" -eq 2 ] || { usage; exit 2; }; retire_live_terminal "$2" ;;
  sweep) [ "$#" -eq 1 ] || { usage; exit 2; }; sweep ;;
  *) usage; exit 2 ;;
esac
