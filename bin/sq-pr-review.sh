#!/usr/bin/env bash
# Resolve an open GitHub pull request to immutable local commits and run Drill's read-only review.
set -euo pipefail

usage() {
  printf 'usage: sq-pr-review.sh <pr-number> [--intent <text>]\n' >&2
}
die() {
  printf 'sq-pr-review: %s\n' "$*" >&2
  exit 1
}

[ "$#" -ge 1 ] || { usage; die 'PR number is required'; }
PR=$1
shift
case "$PR" in ''|*[!0-9]*) die "invalid PR number: $PR" ;; esac
INTENT=()
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --intent ] || { usage; die 'expected optional --intent <text>'; }
  INTENT=(--intent "$2")
fi
command -v gh >/dev/null 2>&1 || die 'gh CLI is required but not on PATH'
command -v git >/dev/null 2>&1 || die 'git is required but not on PATH'
command -v drill >/dev/null 2>&1 || die 'drill CLI is required but not on PATH'
command -v jq >/dev/null 2>&1 || die 'jq is required but not on PATH'
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 'run inside the repository being reviewed'
ROOT=$(git rev-parse --show-toplevel)
gh auth status >/dev/null 2>&1 || die 'gh is not authenticated'

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || die 'cannot resolve repository identity'
PR_JSON=$(gh pr view "$PR" --json state,baseRefOid,headRefOid,headRepository --repo "$REPO" 2>/dev/null) || die "PR #$PR is missing or unreadable"
STATE=$(jq -r .state <<<"$PR_JSON")
[ "$STATE" = OPEN ] || die "PR #$PR is $STATE, not OPEN"
BASE_SHA=$(jq -r .baseRefOid <<<"$PR_JSON")
HEAD_SHA=$(jq -r .headRefOid <<<"$PR_JSON")
[ "$BASE_SHA" != null ] && [ "$HEAD_SHA" != null ] || die 'PR did not provide base and head SHAs'
BASE_REMOTE_URL="https://github.com/$REPO.git"
HEAD_REPO=$(jq -r '.headRepository.nameWithOwner // empty' <<<"$PR_JSON")
[ -n "$HEAD_REPO" ] || HEAD_REPO=$REPO
HEAD_REMOTE_URL="https://github.com/$HEAD_REPO.git"
TOKEN="sq-review-$$-$RANDOM"
BASE_REF="refs/drill/review/$TOKEN/base"
HEAD_REF="refs/drill/review/$TOKEN/head"
cleanup() {
  git -C "$ROOT" update-ref -d "$BASE_REF" >/dev/null 2>&1 || true
  git -C "$ROOT" update-ref -d "$HEAD_REF" >/dev/null 2>&1 || true
  [ -z "${TMP:-}" ] || rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TMP=$(mktemp -d)
git -C "$ROOT" fetch --no-tags --quiet "$BASE_REMOTE_URL" "$BASE_SHA" || die 'could not fetch PR base commit'
[ "$(git -C "$ROOT" rev-parse 'FETCH_HEAD^{commit}')" = "$BASE_SHA" ] || die 'fetched base SHA diverges from PR metadata'
git -C "$ROOT" fetch --no-tags --quiet "$HEAD_REMOTE_URL" "$HEAD_SHA" || die 'could not fetch PR head commit'
[ "$(git -C "$ROOT" rev-parse 'FETCH_HEAD^{commit}')" = "$HEAD_SHA" ] || die 'fetched head SHA diverges from PR metadata'
git -C "$ROOT" update-ref "$BASE_REF" "$BASE_SHA" || die 'could not bind immutable base ref'
git -C "$ROOT" update-ref "$HEAD_REF" "$HEAD_SHA" || die 'could not bind immutable head ref'
drill review --base "$BASE_REF" --head "$HEAD_REF" ${INTENT[@]+"${INTENT[@]}"} >"$TMP/result" || die 'Drill review failed'
CURRENT=$(gh pr view "$PR" --json headRefOid --jq .headRefOid --repo "$REPO" 2>/dev/null) || die 'could not verify PR head after review'
[ "$CURRENT" = "$HEAD_SHA" ] || die "stale review: PR head moved from $HEAD_SHA to $CURRENT; result withheld"
cat "$TMP/result"
