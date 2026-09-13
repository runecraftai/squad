#!/usr/bin/env bash
# PreToolUse transport for preventing manual branch pushes from drill tasks.
#
# The task mode and worktree are authoritative in state/<id>.meta. The guard
# only fires when the current worktree is the recorded worktree of a drill
# task, so the validation pipeline's separate worktree and Squad's primary
# checkout remain free to push.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/sq-push-pretool-check.sh
#   bin/sq-push-pretool-check.sh --command '<cmd>' [--claude]
#
# Exit 0 allows the command. Exit 2 denies it and renders the established
# harness-specific deny response. Transport failures are intentionally inert.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: sq-push-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin.
Denies manual git pushes from a recorded drill task worktree.
The validation pipeline and non-drill delivery modes remain allowed.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi
[ -n "$CMD" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
POLICY="$ROOT/bin/sq-push-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

CURRENT=$(pwd -P 2>/dev/null) || exit 0
STATE=${SQUAD_STATE_OVERRIDE:-${SQUAD_BASE:-${SQUAD_HOME:-}}/state}
[ -d "$STATE" ] || exit 0

TASK_MODE=""
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  mode=$(awk -F= '$1 == "mode" { print substr($0, index($0, "=") + 1); exit }' "$meta" 2>/dev/null) || continue
  [ "$mode" = drill ] || continue
  worktree=$(awk -F= '$1 == "worktree" { print substr($0, index($0, "=") + 1); exit }' "$meta" 2>/dev/null) || continue
  [ -n "$worktree" ] || continue
  recorded=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || continue
  if [ "$recorded" = "$CURRENT" ]; then
    TASK_MODE=drill
    break
  fi
done
[ "$TASK_MODE" = drill ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" "$CMD" 2>/dev/null) || exit 0
[ "$POLICY_OUTPUT" = push ] || exit 0

DETAIL='[drill-push] manual branch pushes are denied from drill tasks; run the validation instead - it publishes the branch and opens the PR'
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
