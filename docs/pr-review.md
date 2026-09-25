# Requested PR and diff reviews

Squad uses Drill's read-only standalone review surface for requested PR/diff reviews and knowledge-only reviews.
Run `bin/sq-pr-review.sh <pr-number>` to resolve an open PR, fetch its exact base and head commits, and call `drill review`.
For local refs, use `drill review --base <base> --head <head> [--intent <intent>]` directly.
This is an audit that returns local native findings, not a delivery gate, approval, or GitHub publication path.
Delivery continues through the complete `git push drill` pipeline.

`packages/pr-review` remains present until the separate R7 retirement task.

## Surface

- `drill review --base <base> --head <head> [--intent <intent>]` reviews local refs non-interactively with Drill's snapshot, specialist lenses, and consolidator.
- `bin/sq-pr-review.sh <pr-number>` validates an open PR and authentication, fetches immutable base/head refs, invokes Drill, then verifies that the remote head is unchanged before releasing the result.
- `drill review --format json` emits repository identity, reviewed SHAs, and native findings; text output includes the same structured result.

## Guards

- Standalone review never runs fixes or delivery steps and performs no GitHub writes.
- A standalone audit cannot satisfy `Require drill` or approve a delivery HEAD.
- Findings are local review deliverables; external publication and merge remain human actions.

## Validation

- Wrapper guard, stale-head, and side-effect checks run in `tests/sq-pr-review-guard.test.sh`.
- Drill's CLI and shared-engine checks are colocated in `packages/drill/internal/cli` and `packages/drill/internal/pipeline/steps`.
