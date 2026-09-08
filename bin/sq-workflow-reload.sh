#!/usr/bin/env bash
# Detect and atomically apply repository WORKFLOW.md changes.
# Usage: sq-workflow-reload.sh check|reload <WORKFLOW.md> [state-dir] [bundle-path ...]
#        sq-workflow-reload.sh hash <WORKFLOW.md> [bundle-path ...]
#
# A reload never overwrites the stored good configuration with invalid input.
# The record is deliberately base-local; active attempts keep their version in
# state/<id>.exec while the next claim reads the current version.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { printf '%s\n' "usage: sq-workflow-reload.sh {check|reload} <WORKFLOW.md> [state-dir] [bundle-path ...]"; }
command_name=${1:-}
case "$command_name" in check|detect|reload|hash|version) ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
workflow=${2:-}
[ -n "$workflow" ] || { usage >&2; exit 2; }
if [ "$command_name" = hash ] || [ "$command_name" = version ]; then
  shift 2
  exec "$SCRIPT_DIR/sq-workflow.sh" "$command_name" "$workflow" "$@"
fi
if [ "$command_name" = detect ]; then
  command_name=check
fi
state_dir=${3:-${SQUAD_STATE_OVERRIDE:-${SQUAD_BASE:-${SQUAD_HOME:-$SCRIPT_DIR/..}}/state}}
mkdir -p "$state_dir"
canonical=$(CDPATH='' cd "$(dirname "$workflow")" && pwd -P)/$(basename "$workflow")
record_key=$(printf '%s' "$canonical" | sha256sum | cut -d' ' -f1)
record="$state_dir/.workflow-reload-$record_key"
lock="$record.lock"
mtime=$(stat -c '%Y' "$workflow" 2>/dev/null) || { echo "error: cannot stat $workflow" >&2; exit 1; }
size=$(stat -c '%s' "$workflow" 2>/dev/null) || { echo "error: cannot stat $workflow" >&2; exit 1; }
signature="$mtime:$size"

if [ -f "$record" ] && grep -q "^observed_signature=$signature$" "$record"; then
  version=$(sed -n 's/^workflow_version=//p' "$record" | head -n 1)
  [ -n "$version" ] || version=none
  printf 'unchanged version=%s\n' "$version"
  exit 0
fi

if ! mkdir "$lock" 2>/dev/null; then
  echo "error: workflow reload is already in progress" >&2
  exit 1
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

# Re-check after taking the lock, since another reload may have won the race.
if [ -f "$record" ] && grep -q "^observed_signature=$signature$" "$record"; then
  version=$(sed -n 's/^workflow_version=//p' "$record" | head -n 1)
  printf 'unchanged version=%s\n' "${version:-none}"
  exit 0
fi

if ! "$SCRIPT_DIR/sq-workflow.sh" validate "$workflow" >/dev/null 2>"$record.error"; then
  good=$(sed -n 's/^workflow_version=//p' "$record" 2>/dev/null | head -n 1 || true)
  if [ -n "$good" ]; then
    printf 'invalid-preserved version=%s\n' "$good"
    exit 0
  fi
  cat "$record.error" >&2
  exit 1
fi
bundle=()
[ -f "$(dirname "$canonical")/AGENTS.md" ] && bundle+=("$(dirname "$canonical")/AGENTS.md")
[ -d "$SCRIPT_DIR/../.agents/skills" ] && bundle+=("$SCRIPT_DIR/../.agents/skills")
version=$("$SCRIPT_DIR/sq-workflow.sh" hash "$workflow" "${bundle[@]}")
config=$("$SCRIPT_DIR/sq-workflow.sh" parse "$workflow" | base64 | tr -d '\n')
tmp=$(mktemp "$state_dir/.workflow-reload.XXXXXX")
{
  printf 'workflow_path=%s\n' "$canonical"
  printf 'observed_signature=%s\n' "$signature"
  printf 'workflow_version=%s\n' "$version"
  printf 'workflow_config=%s\n' "$config"
} >"$tmp"
mv -f -- "$tmp" "$record"
rm -f "$record.error"
printf 'reloaded version=%s\n' "$version"
