# Strike PR review (vendored pr-review)

Squad maintains `@runecraft/pr-review` (0.1.0) in `packages/pr-review` and
wires it into the strike flow between PR creation and the commander's merge
decision (AGENTS.md section 7).

## Surface

- `.pi/extensions/sq-pr-review.ts` — Squad-named bootstrapper that registers
  the vendored package extension in the Pi session (`/pr-review <n>`, focus
  viewer, findings table). The package's own `pi` manifest also enables
  auto-discovery through the root workspace.
- `bin/sq-pr-review.sh [<pr-number>]` — thin wrapper for CI/scripting. It
  validates, with clear failure messages (REQ-M3-02 AC3):
  1. `gh` and `git` are on PATH;
  2. the command runs inside a git checkout;
  3. the PR resolves (explicit number, or from the current branch) and exists
     as an OPEN PR readable by `gh`;
  4. `gh` is authenticated.
  It never starts a review by itself — the review runs in the Pi session —
  and prints the in-session command to run.

## Guards

- Publication is COMMENT-only (the package default; auto-approve is disabled).
- The review never merges and never approves; the commander alone decides
  merges. `+yolo` posture does not let the review self-approve.
- Findings feed the commander decision; they are a review deliverable, not an
  authority override.

## Validation

- Wrapper guard paths are unit-checked in `tests/sq-pr-review-guard.test.sh`
  (no repo / no PR / no gh auth / closed PR → clear failures, exit 1).
- One documented live run against a scratch repo is A-08 (manual, not a CI
  gate): run `/pr-review <n>` in a Pi session on a test PR and confirm the
  COMMENT-only findings table.
