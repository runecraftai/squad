#!/usr/bin/env bash
# Report task-owned Squad artifacts found in a PR's changed-file list.
# Usage: sq-pr-artifact-guard.sh <task-id> (reads newline-delimited paths on stdin)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/sq-pr-lib.sh
. "$SCRIPT_DIR/sq-pr-lib.sh"

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid PR artifact guard request" >&2
  exit 2
fi
ID=$1
matches=$(awk -v prefix="data/$ID/" 'index($0, prefix) == 1 { print }' | LC_ALL=C sort -u)
if [ -n "$matches" ]; then
  printf 'warning: PR contains Squad internal artifact path(s) for task %s; remove them before merge:\n%s\n' "$ID" "$matches" >&2
fi
