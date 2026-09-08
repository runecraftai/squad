#!/usr/bin/env bash
# Run an optional structured WORKFLOW.md workspace hook.
# Usage: sq-hooks.sh <after_create|before_run|after_run|before_remove> <workspace> <task-id> [attempt] [state] [workflow-version] [project-name]
# The workflow manifest is selected by WORKFLOW_PATH.  With no manifest or no
# hook for the requested phase, this command succeeds without changing state.
# Hook commands are JSON arrays and are executed without a shell.
set -eu
# shellcheck disable=SC2016

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sq-timeout-lib.sh
. "$SCRIPT_DIR/sq-timeout-lib.sh"

phase=${1:-}
workspace=${2:-}
task_id=${3:-}
attempt=${4:-0}
exec_state=${5:-}
workflow_version=${6:-}
project_name=${7:-}
case "$phase" in after_create|before_run|after_run|before_remove) ;; *)
  printf '%s\n' 'usage: sq-hooks.sh {after_create|before_run|after_run|before_remove} <workspace> <task-id> [attempt] [state] [workflow-version] [project-name]' >&2
  exit 2
esac
[ -n "$workspace" ] && [ -d "$workspace" ] || { echo "hook=$phase result=failure exit_code=2 reason=workspace_missing"; exit 2; }
[ -n "$task_id" ] || { echo "hook=$phase result=failure exit_code=2 reason=task_id_missing"; exit 2; }

workflow=${WORKFLOW_PATH:-}
[ -n "$workflow" ] && [ -f "$workflow" ] || exit 0

hook_json=$("$SCRIPT_DIR/sq-workflow.sh" get "$workflow" "hooks.$phase" 2>/dev/null) || exit 0
# Decode the validated command array to one hex-encoded argument per line.
# Hex avoids word splitting and does not require a non-default Ruby gem.
mapfile -t hook_parts < <(ruby -rjson -e '
  hook = JSON.parse(ARGF.read)
  abort unless hook.is_a?(Hash) && hook["command"].is_a?(Array) && !hook["command"].empty?
  hook["command"].each { |part| puts part.bytes.map { |byte| "%02x" % byte }.join }
' <<<"$hook_json")
[ "${#hook_parts[@]}" -gt 0 ] || { echo "hook=$phase result=failure exit_code=2 reason=invalid_command"; exit 2; }
command=()
for encoded in "${hook_parts[@]}"; do
  printf -v decoded '%b' "$(printf '%s' "$encoded" | sed 's/../\\x&/g')"
  command+=("$decoded")
done
timeout_ms=$(ruby -rjson -e 'h=JSON.parse(ARGF.read); n=h["timeout_ms"]; puts(n.is_a?(Integer) && n > 0 ? n : 300000)' <<<"$hook_json")
# fm_run_timed accepts seconds; round up so a sub-second manifest timeout is
# never accidentally treated as an unlimited deadline.
seconds=$(( (timeout_ms + 999) / 1000 ))

output=$(mktemp "${TMPDIR:-/tmp}/sq-hook-output.XXXXXX")
trap 'rm -f "$output"' EXIT
if (
  cd -- "$workspace"
  export WORKSPACE_PATH="$workspace" TASK_ID="$task_id" EXEC_ATTEMPT="$attempt"
  export EXEC_STATE="$exec_state" WORKFLOW_VERSION="$workflow_version"
  export SQUAD_BASE="${SQUAD_BASE:-}" PROJECT_NAME="$project_name"
  env -i PATH="${PATH:-/usr/bin:/bin}" WORKSPACE_PATH="$WORKSPACE_PATH" TASK_ID="$TASK_ID" EXEC_ATTEMPT="$EXEC_ATTEMPT" EXEC_STATE="$EXEC_STATE" WORKFLOW_VERSION="$WORKFLOW_VERSION" SQUAD_BASE="$SQUAD_BASE" PROJECT_NAME="$PROJECT_NAME" \
    bash -c "source \"\$1\"; shift; fm_run_timed \"\$@\"" _ "$SCRIPT_DIR/sq-timeout-lib.sh" "$seconds" "${command[@]}"
) >"$output" 2>&1; then
  printf 'hook=%s result=success exit_code=0\n' "$phase"
  exit 0
else
  rc=$?
  if [ "$rc" -eq 124 ]; then result=timeout; else result=failure; fi
  printf 'hook=%s result=%s exit_code=%s\n' "$phase" "$result" "$rc"
  if [ -s "$output" ]; then
    printf '%s\n' 'hook_output_begin'
    cat "$output"
    printf '%s\n' 'hook_output_end'
  fi
  exit "$rc"
fi
