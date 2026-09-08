#!/usr/bin/env bash
# sq-board-github.sh - read-only GitHub issue monitor for the mission board.
#
# The monitor is deliberately opt-in: a repository must declare tracker.kind:
# github in WORKFLOW.md.  It observes issues through sq-gh and never mutates
# GitHub or Squad's backlog.  Poll snapshots and dispatch suggestions live in
# state/github-monitor/.
set -euo pipefail

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
ROOT="$(dirname "$(dirname "$SELF")")"
BASE="${SQUAD_BASE:-${SQUAD_HOME:-$ROOT}}"
MONITOR_DIR="${SQ_BOARD_GITHUB_STATE_DIR:-$BASE/state/github-monitor}"
WORKFLOW="${SQ_BOARD_GITHUB_WORKFLOW:-${SQUAD_WORKFLOW:-$BASE/WORKFLOW.md}}"
ISSUES_FILE="$MONITOR_DIR/issues.json"
SUGGESTIONS_FILE="$MONITOR_DIR/suggestions.json"
CURSOR_FILE="$MONITOR_DIR/cursor"

usage() {
  cat >&2 <<'USAGE'
usage: sq-board-github <list|poll|report|approve> [issue-number]

Read-only GitHub issue observation (opt in with tracker.kind: github).
  list       print currently eligible open issues as JSON
  poll       refresh the snapshot and print new/changed issues
  report     print aggregate monitor status as JSON
  approve N  record approval for a suggestion (does not dispatch or mutate)
USAGE
}

err() { printf 'sq-board-github: %s\n' "$*" >&2; exit 1; }

[ -f "$WORKFLOW" ] || { printf '%s\n' '{"enabled":false,"reason":"no WORKFLOW.md"}'; exit 0; }
command -v jq >/dev/null 2>&1 || err 'jq is required'
command -v sq-gh >/dev/null 2>&1 || err 'sq-gh is required'
command -v sq-workflow.sh >/dev/null 2>&1 || {
  [ -x "$ROOT/bin/sq-workflow.sh" ] || err 'sq-workflow.sh is required'
  PATH="$ROOT/bin:$PATH"
}

CONFIG=$(sq-workflow.sh parse "$WORKFLOW") || err "invalid WORKFLOW.md: $WORKFLOW"
KIND=$(printf '%s' "$CONFIG" | jq -r '.tracker.kind // empty')
if [ "$KIND" != github ]; then
  printf '%s\n' '{"enabled":false,"reason":"tracker.kind is not github"}'
  exit 0
fi
REPO=$(printf '%s' "$CONFIG" | jq -r '.tracker.provider.repo // empty')
[ -n "$REPO" ] || err 'tracker.provider.repo is required for GitHub monitoring'

mkdir -p "$MONITOR_DIR"

fetch_issues() {
  local raw
  raw=$(sq-gh issue list --repo "$REPO" --state open --limit 100 --json)
  # sq-gh emits an AXI envelope; accepting a bare array keeps the monitor
  # useful with test doubles and older compatible clients.
  printf '%s' "$raw" | jq -c 'if type == "array" then . elif (.data|type) == "array" then .data else [] end'
}

list_cmd() {
  fetch_issues | jq '.'
}

poll_cmd() {
  local current old diff tmp now
  current=$(fetch_issues)
  old='[]'
  [ -f "$ISSUES_FILE" ] && old=$(cat "$ISSUES_FILE")
  diff=$(jq -n --argjson old "$old" --argjson new "$current" '
    [$new[] as $n | ($old[] | select((.number // "") == ($n.number // ""))) as $o |
      select($o == null or (($o | del(.body,.comments)) != ($n | del(.body,.comments)))) |
      {change:(if $o == null then "new" else "changed" end), issue:$n}]
    + [$new[] as $n | select([ $old[].number ] | index($n.number) | not) |
      {change:"new", issue:$n}] | unique_by(.issue.number)')
  tmp=$(mktemp "$MONITOR_DIR/.issues.XXXXXX")
  printf '%s\n' "$current" | jq '.' > "$tmp" && mv "$tmp" "$ISSUES_FILE"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$now" > "$CURSOR_FILE"
  # Suggestions are durable, but each issue/change pair is idempotent.
  [ -f "$SUGGESTIONS_FILE" ] || printf '%s\n' '[]' > "$SUGGESTIONS_FILE"
  tmp=$(mktemp "$MONITOR_DIR/.suggestions.XXXXXX")
  jq -n --argjson existing "$(cat "$SUGGESTIONS_FILE")" --argjson changes "$diff" '
    ($existing + [$changes[] | {issue:.issue, change:.change, status:"suggested", suggested_at:(now|todateiso8601)}])
    | unique_by(.issue.number) | sort_by(.issue.number)' > "$tmp" && mv "$tmp" "$SUGGESTIONS_FILE"
  jq -n --arg polled_at "$now" --argjson changes "$diff" '{polled_at:$polled_at, changes:$changes}'
}

report_cmd() {
  local issues='[]' suggestions='[]' cursor=''
  [ -f "$ISSUES_FILE" ] && issues=$(cat "$ISSUES_FILE")
  [ -f "$SUGGESTIONS_FILE" ] && suggestions=$(cat "$SUGGESTIONS_FILE")
  [ -f "$CURSOR_FILE" ] && cursor=$(cat "$CURSOR_FILE")
  jq -n --arg repo "$REPO" --arg cursor "$cursor" --argjson issues "$issues" --argjson suggestions "$suggestions" '
    {enabled:true, repo:$repo, last_poll:($cursor // ""), total:($issues|length),
     by_state:($issues|group_by(.state)|map({key:(.[0].state // "unknown"),value:length})|from_entries),
     suggestions:($suggestions|length), pending_suggestions:([$suggestions[]|select(.status=="suggested")]|length), issues:$issues}'
}

approve_cmd() {
  local number=${1:-} tmp
  [[ "$number" =~ ^[0-9]+$ ]] || err 'approve requires an issue number'
  [ -f "$SUGGESTIONS_FILE" ] || err "no suggestion for issue #$number"
  tmp=$(mktemp "$MONITOR_DIR/.suggestions.XXXXXX")
  jq --argjson n "$number" 'map(if .issue.number == $n then . + {status:"approved", approved_at:(now|todateiso8601)} else . end)' "$SUGGESTIONS_FILE" > "$tmp"
  mv "$tmp" "$SUGGESTIONS_FILE"
  local result
  result=$(jq --argjson n "$number" '[.[]|select(.issue.number==$n)]|first // empty' "$SUGGESTIONS_FILE")
  [ -n "$result" ] || err "no suggestion for issue #$number"
  printf '%s\n' "$result"
}

case "${1:-}" in
  list) list_cmd ;;
  poll) poll_cmd ;;
  report) report_cmd ;;
  approve) approve_cmd "${2:-}" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
