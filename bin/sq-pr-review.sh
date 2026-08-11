#!/usr/bin/env bash
# Squad pr-review wrapper (T-M3-03, REQ-M3-02 AC3): thin manual/CI entry point
# for the maintained @runecraft/pr-review review of a strike PR. Validates the
# repo, the PR, and gh auth with clear failure messages; the review itself runs
# inside the Pi session (extension) — this wrapper exists for CI/scripting and
# surfaces the same COMMENT-only posture.
set -u

USAGE='usage: sq-pr-review.sh [<pr-number>]

Reviews the current branch'"'"'s GitHub PR with the maintained @runecraft/pr-review
logic (COMMENT-only; never merges, never approves). With no argument, the PR
number is resolved from the current branch. Run inside a git checkout of the
repo whose PR is being reviewed.'

die() { echo "sq-pr-review: $*" >&2; exit 1; }

[ "$#" -le 1 ] || die "$USAGE"

command -v gh >/dev/null 2>&1 || die "gh CLI is required but not on PATH"
command -v git >/dev/null 2>&1 || die "git is required but not on PATH"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not inside a git repository; run from the repo whose PR is being reviewed"
ROOT_DIR=$(git rev-parse --show-toplevel)

PR=${1:-}
if [ -z "$PR" ]; then
  BRANCH=$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true)
  [ -n "$BRANCH" ] || die "cannot resolve the current branch; pass a PR number explicitly"
  PR=$(gh pr view "$BRANCH" --json number --jq .number 2>/dev/null) \
    || die "no open PR found for branch '$BRANCH' (or gh cannot read it); pass a PR number explicitly"
fi
case "$PR" in
  ''|*[!0-9]*) die "invalid PR number: $PR" ;;
esac

gh auth status >/dev/null 2>&1 \
  || die "gh is not authenticated; run 'gh auth login' first"

gh pr view "$PR" --json state --jq .state >/dev/null 2>&1 \
  || die "PR #$PR not found or not readable from this repo"
STATE=$(gh pr view "$PR" --json state --jq .state 2>/dev/null)
[ "$STATE" = OPEN ] || die "PR #$PR is $STATE, not OPEN; only open PRs are reviewed"

echo "sq-pr-review: PR #$PR validated (open, readable, gh authenticated)." >&2
echo "sq-pr-review: run the review inside the Pi session with /pr-review $PR" >&2
echo "sq-pr-review: publication is COMMENT-only; the commander decides merges." >&2
