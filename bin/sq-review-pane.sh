#!/usr/bin/env bash
# Open a visual review pane for a live Squad task without changing its worktree
# or durable unit records.
#
# Review workflow: spawn the task, run `bin/sq-review-pane.sh <task-id>`, attach
# to the printed review window, then steer corrections with
# `bin/sq-send.sh <task-id> '<feedback>'` while the review remains open.
#
# Usage: sq-review-pane.sh <task-id> [--base <ref>] [--print-command]
# The default base is origin/<default-branch>, resolved from the recorded
# project clone using the same default-branch rule as sq-review-diff.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"

# shellcheck disable=SC1091
# shellcheck source=bin/sq-backend.sh
. "$SCRIPT_DIR/sq-backend.sh"
# shellcheck disable=SC1091
# shellcheck source=bin/sq-tangle-lib.sh
. "$SCRIPT_DIR/sq-tangle-lib.sh"

usage() {
  echo "usage: sq-review-pane.sh <task-id> [--base <ref>] [--print-command]" >&2
}

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
shift
BASE_REF=
PRINT_COMMAND=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || { echo "error: --base requires a ref" >&2; exit 1; }
      BASE_REF=$2
      shift 2
      ;;
    --print-command)
      PRINT_COMMAND=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
WT=$(fm_meta_get "$META" worktree)
PROJ=$(fm_meta_get "$META" project)
WINDOW=$(fm_meta_get "$META" window)
BACKEND=$(fm_backend_of_meta "$META")
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -n "$WINDOW" ] || { echo "error: meta for task $ID is missing window=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }
[ "$BACKEND" = tmux ] || { echo "error: review pane requires a tmux task window; task $ID uses backend $BACKEND" >&2; exit 1; }
fm_backend_target_exists tmux "$WINDOW" || {
  echo "error: task window is not live: $WINDOW" >&2
  exit 1
}

if [ -n "$BASE_REF" ]; then
  BASE=$BASE_REF
else
  DEFAULT=$(fm_default_branch "$PROJ") || {
    echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2
    exit 1
  }
  if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    BASE="origin/$DEFAULT"
  else
    BASE=$DEFAULT
  fi
fi
[ -n "$BASE" ] || { echo "error: diff base must not be empty" >&2; exit 1; }
git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || {
  echo "error: base $BASE does not resolve in $WT" >&2
  exit 1
}

# Escape the base for a double-quoted Lua string. Git refs cannot contain
# controls, but reject them explicitly rather than constructing a malformed
# editor command from an explicit user argument.
case "$BASE" in
  *$'\n'*|*$'\r'*)
    echo "error: base ref contains a newline" >&2
    exit 1
    ;;
esac
LUA_BASE=$(printf '%s' "$BASE" | sed 's/\\/\\\\/g; s/"/\\"/g')
LUA="lua pcall(function() local ok,g=pcall(require, 'gitsigns'); if ok then pcall(g.change_base, \"$LUA_BASE\") end end)"
REVIEW_NAME="sq-$ID-review"
SESSION=${WINDOW%%:*}
EDITOR_INVOCATION="nvim -c $(printf '%q' "$LUA") $(printf '%q' "$WT")"

if "$PRINT_COMMAND"; then
  printf '%s\n' "$EDITOR_INVOCATION"
  exit 0
fi

CHECKED_OUT=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ -n "$CHECKED_OUT" ]; then
  echo "worktree ref: $CHECKED_OUT"
else
  COMMIT=$(git -C "$WT" rev-parse --short HEAD 2>/dev/null || true)
  echo "worktree ref: detached HEAD${COMMIT:+ at $COMMIT}"
fi

tmux new-window -d -t "$SESSION:" -n "$REVIEW_NAME" -c "$WT" nvim -c "$LUA" "$WT"
printf 'attach: tmux attach-session -t %q\n' "$SESSION"
printf "feedback: bin/sq-send.sh %q '<feedback>'\n" "$ID"
