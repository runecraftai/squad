#!/usr/bin/env bash
# Private, regenerable projection of allowlisted per-task execution metadata.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${SQUAD_BASE:-${SQUAD_HOME:-$ROOT}}"
STATE="${SQUAD_STATE_OVERRIDE:-$BASE/state}"
DATA="${SQUAD_DATA_OVERRIDE:-$BASE/data}"
COST="$ROOT/bin/sq-cost.sh"

usage() {
  printf '%s\n' 'Usage: sq-trajectory.sh task <task-id> --json' '       sq-trajectory.sh snapshot <task-id>' '       sq-trajectory.sh coverage --limit <1-20> [--json]'
}
error() { printf 'error: %s\n' "$*" >&2; exit 2; }
valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# Read exactly one key from a trusted sidecar. Duplicates are ambiguous.
field() {
  local file=$1 key=$2
  awk -F= -v key="$key" '$1 == key { n++; value=substr($0,index($0,"=")+1) } END { if (n > 1) { print "error: ambiguous duplicate " key " field in " FILENAME > "/dev/stderr"; exit 2 } if (n == 1) print value }' "$file"
}

source_json() {
  local file=$1 rel size stamp
  rel=${file#"$BASE"/}
  [[ "$rel" != "$file" && "$rel" != ../* ]] || error "source is outside SQUAD_BASE"
  size=$(stat -c %s "$file") || error "cannot stat source $rel"
  stamp=$(stat -c %Y "$file") || error "cannot stat source $rel"
  jq -cn --arg path "$rel" --argjson size "$size" --argjson observed_at "$stamp" \
    '{path:$path,size:$size,observed_at:$observed_at}'
}

build_task() {
  local id=$1 meta="$STATE/$1.meta" exec="$STATE/$1.exec" status="$STATE/$1.status"
  valid_id "$id" || error 'invalid task id'
  [[ -f "$meta" && -f "$exec" && -f "$status" ]] || error "task or required source is missing: $id"
  local task harness model attempt retries started ended endstate cost_json sources receipts='[]'
  awk 'NF && $0 !~ /^[A-Za-z_][A-Za-z0-9_]*=/ { exit 1 }' "$meta" || error "malformed metadata source for $id"
  awk 'NF && $0 !~ /^[A-Za-z_][A-Za-z0-9_]*=/ { exit 1 }' "$exec" || error "malformed execution source for $id"
  task=$(field "$meta" task)
  # Metadata identity is the exact filename id; optional task=, when present, must agree.
  [[ -z "$task" || "$task" == "$id" ]] || error "ambiguous task identity in $id.meta"
  harness=$(field "$meta" harness)
  model=$(field "$meta" model)
  attempt=$(field "$exec" exec_attempt)
  retries=$(field "$exec" exec_retry_count)
  started=$(field "$exec" exec_started_at)
  ended=$(field "$exec" exec_last_activity)
  [[ -z "$attempt" || "$attempt" =~ ^[0-9]+$ ]] || error "malformed attempt count in $id.exec"
  [[ -z "$retries" || "$retries" =~ ^[0-9]+$ ]] || error "malformed retry count in $id.exec"
  [[ -z "$started" || "$started" =~ ^[0-9]+$ ]] || error "malformed start timestamp in $id.exec"
  [[ -z "$ended" || "$ended" =~ ^[0-9]+$ ]] || error "malformed end timestamp in $id.exec"
  # Required structured inputs must be readable and syntactically sound.
  jq -e -n 'true' >/dev/null || error 'jq is unavailable'
  local terminal
  terminal=$(awk 'NF { line=$0 } END { sub(/:.*/,"",line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line }' "$status")
  case "$terminal" in done|failed) endstate="$terminal" ;; *) endstate="" ;; esac
  [[ -n "$endstate" ]] || error "task is not completed: $id"
  if [[ -x "$COST" ]]; then
    cost_json=$(SQUAD_BASE="$BASE" SQUAD_STATE_OVERRIDE="$STATE" "$COST" task "$id" --json 2>/dev/null) || cost_json='{}'
  else cost_json='{}'; fi
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$cost_json" || cost_json='{}'
  sources=$(jq -cn --argjson m "$(source_json "$meta")" --argjson e "$(source_json "$exec")" --argjson s "$(source_json "$status")" '[$m,$e,$s]')
  local evidence_dir="$DATA/$id/artifacts/evidence"
  if [[ -d "$evidence_dir" ]]; then
    receipts=$(find "$evidence_dir" -maxdepth 1 -type f -name '*.json' -print0 | xargs -0 -r jq -c '{id,sha256,range_count:(.spans|length)}' | jq -s 'sort_by(.id)')
  fi
  jq -cn --arg id "$id" --arg harness "$harness" --arg model "$model" \
    --arg attempt "$attempt" --arg retries "$retries" --arg started "$started" --arg ended "$ended" \
    --arg outcome "$endstate" --argjson cost "$cost_json" --argjson sources "$sources" --argjson receipts "$receipts" '
    def metric($v;$ok;$why): {value:$v,availability:(if $ok then "known" else "unknown" end),reason:(if $ok then "" else $why end)};
    ($started|tonumber?) as $start | ($ended|tonumber?) as $finish |
    (.models // []) as $models |
    ([ $models[].input? ]|if length>0 then add else null end) as $input |
    ([ $models[].output? ]|if length>0 then add else null end) as $output |
    ([ $models[].cache_read? ]|if length>0 then add else null end) as $cache_read |
    ([ $models[].cache_write? ]|if length>0 then add else null end) as $cache_write |
    ([ $models[].cost? ]|map(select(type=="number"))|if length>0 then add else null end) as $reported_cost |
    {schema_version:1,task:{id:$id},
     harness:metric((if $harness=="" then null else $harness end);($harness!="");"harness is absent from task metadata"),
     model:metric((if $model=="" then null else $model end);($model!="");"model is absent from task metadata"),
     attempts:metric((if $attempt=="" then null else ($attempt|tonumber) end);($attempt!="");"execution attempt count is absent"),
     retries:metric((if $retries=="" then null else ($retries|tonumber) end);($retries!="");"retry count is absent"),
     timestamps:{started_at:metric($start;($start!=null);"execution start timestamp is unavailable"),ended_at:metric($finish;($finish!=null);"execution end timestamp is unavailable")},
     duration_seconds:metric((if $start!=null and $finish!=null and $finish >= $start then $finish-$start else null end);($start!=null and $finish!=null and $finish >= $start);"valid execution start and end timestamps are required"),
     tokens:{input:metric($input;($input!=null);"sq-cost has no attributable input token count"),output:metric($output;($output!=null);"sq-cost has no attributable output token count")},
     cache:{read:metric($cache_read;($cache_read!=null);"sq-cost has no attributable cache-read count"),write:metric($cache_write;($cache_write!=null);"sq-cost has no attributable cache-write count")},
     cost:metric($reported_cost;($reported_cost!=null);"sq-cost has no attributable provider-recorded cost"),
     checks:metric(null;false;"no task-attributable structured check summary is available"),
     repairs:metric(null;false;"no task-attributable structured repair count is available"),
     outcome:metric($outcome;true;""),sources:$sources, evidence_receipts:$receipts}'
}

cmd_task() {
  [[ $# == 2 && $2 == --json ]] || error 'task requires <task-id> --json'
  build_task "$1"
}
cmd_snapshot() {
  [[ $# == 1 ]] || error 'snapshot requires <task-id>'
  local id=$1 json dir target tmp
  json=$(build_task "$id")
  dir="$DATA/$id/artifacts"; target="$dir/trajectory.v1.json"
  mkdir -p "$dir" || error 'cannot create artifact directory'
  tmp=$(mktemp "$dir/.trajectory.XXXXXX") || error 'cannot create temporary artifact'
  trap 'rm -f "${tmp:-}"' EXIT
  printf '%s\n' "$json" > "$tmp"
  chmod 600 "$tmp"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then rm -f "$tmp"; tmp=""
  else mv -f "$tmp" "$target"; tmp=""; fi
  printf '%s\n' "${target#"$BASE"/}"
}

cmd_coverage() {
  local limit='' json=0
  while (($#)); do
    case "$1" in
      --limit) (($# >= 2)) || error '--limit needs a value'; limit=$2; shift 2 ;;
      --json) json=1; shift ;;
      *) error "unknown coverage option: $1" ;;
    esac
  done
  if [[ ! "$limit" =~ ^[0-9]+$ ]] || ((limit < 1 || limit > 20)); then
    error 'coverage requires --limit from 1 to 20'
  fi
  local docs='[]' id doc count=0
  while IFS= read -r id; do
    [[ -n "$id" && -f "$STATE/$id.meta" && -f "$STATE/$id.status" ]] || continue
    local last
    last=$(awk 'NF { line=$0 } END { sub(/:.*/,"",line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line }' "$STATE/$id.status")
    case "$last" in done|failed) ;; *) continue ;; esac
    doc=$(build_task "$id" 2>/dev/null) || continue
    docs=$(jq -cn --argjson old "$docs" --argjson item "$doc" '$old + [$item]')
    count=$((count+1)); ((count >= limit)) && break
  done < <(find "$STATE" -maxdepth 1 -type f -name '*.meta' -printf '%f\n' | sed 's/\.meta$//' | sort)
  local result
  result=$(jq -cn --argjson tasks "$docs" '
    def fields: ["harness","model","attempts","retries","timestamps.started_at","timestamps.ended_at","duration_seconds","tokens.input","tokens.output","cache.read","cache.write","cost","checks","repairs","outcome"];
    def getpathstr($p): ($p|split(".")) as $parts | getpath($parts);
    {schema_version:1,analyzed:($tasks|length),tasks:[$tasks[]|{id:.task.id,outcome:.outcome}],coverage:(fields as $fs | [$fs[] as $f | [$tasks[]|getpathstr($f)] as $v | {field:$f,known:([$v[]|select(.availability=="known")]|length),unknown:([$v[]|select(.availability=="unknown")]|length),not_applicable:([$v[]|select(.availability=="not_applicable")]|length)}])}')
  if ((json)); then printf '%s\n' "$result"; else
    jq -r '"Analyzed tasks: \(.analyzed)",(.coverage[]|"\(.field): known=\(.known), unknown=\(.unknown), not_applicable=\(.not_applicable)")' <<<"$result"
    local reasons
    reasons=$(jq -cn --argjson tasks "$docs" '[ $tasks[] | [.harness,.model,.attempts,.retries,.timestamps.started_at,.timestamps.ended_at,.duration_seconds,.tokens.input,.tokens.output,.cache.read,.cache.write,.cost,.checks,.repairs,.outcome][] | select(.availability=="unknown") | .reason ] | group_by(.) | map({reason:.[0],count:length}) | sort_by(-.count,.reason) | .[:3]')
    printf '%s\n' 'Most frequent unknown reasons:'
    jq -r 'if length == 0 then "  none" else .[] | "  \(.count)x \(.reason)" end' <<<"$reasons"
  fi
}

case "${1:-}" in
  task) shift; cmd_task "$@" ;;
  snapshot) shift; cmd_snapshot "$@" ;;
  coverage) shift; cmd_coverage "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
