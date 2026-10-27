#!/usr/bin/env bash
# Merge a task's PR only after sq-gh has freshly verified its recorded head,
# checks, and mergeability, with GitHub binding the merge to that exact SHA.
# Record pr= and pr_head= through bin/sq-pr-check.sh only after merge succeeds.
# The full canonical GitHub PR URL is parsed by bin/sq-pr-lib.sh and the derived
# owner/repository and PR number are passed to sq-gh as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: sq-pr-merge.sh <task-id> <pr-url> [-- <extra sq-gh pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUAD_ROOT="${SQUAD_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SQUAD_BASE="${SQUAD_BASE:-${SQUAD_HOME:-${SQUAD_ROOT_OVERRIDE:-$SQUAD_ROOT}}}"
STATE="${SQUAD_STATE_OVERRIDE:-$SQUAD_BASE/state}"

# shellcheck source=bin/sq-pr-lib.sh
. "$SCRIPT_DIR/sq-pr-lib.sh"
# shellcheck source=bin/sq-durable-custody.sh
. "$SCRIPT_DIR/sq-durable-custody.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/sq-pr-lib.sh parses GitLab merge request URLs so the sentry can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$SQUAD_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
# Landing a durable mission belongs to the durable core; a direct call is refused.
durable_custody_check "$ID" landing || exit 3
URL=$SQUAD_PR_URL
PR_OWNER=$SQUAD_PR_OWNER
PR_REPO=$SQUAD_PR_REPO
PR_NUMBER=$SQUAD_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --expected-head|--expected-head=*)
        echo "error: extra merge arguments must not override the verified PR head" >&2
        return 1
        ;;
      --auto)
        echo "error: automatic merge is not allowed by the guarded merge path" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

RECORDED_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
if ! fm_pr_head_valid "$RECORDED_HEAD"; then
  echo "error: task metadata has no valid recorded PR head; run sq-pr-check before merging" >&2
  exit 1
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

sq-gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --expected-head "$RECORDED_HEAD" "${merge_args[@]+"${merge_args[@]}"}" "$@"
"$SCRIPT_DIR/sq-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed after confirmed merge" >&2
  exit 1
}
SQUAD_BASE="$SQUAD_BASE" "$SCRIPT_DIR/sq-dispatch-log.sh" "$ID" outcome \
  --source pr-merge --result landed || true
