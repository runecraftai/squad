#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016 off for this file: Markdown backticks are literal test fixtures.
# Focused behavior tests for the plan-execute@1 pre-dispatch structural gate.
#
# Covers bin/sq-plan-validate.sh field detection and the sq-spawn.sh refusal it
# backs, exercising both through their command-line interfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-plan-validate)
HOME="$TMP_ROOT/home"
ID=plan-execute-test
mkdir -p "$HOME/data/$ID" "$HOME/state" "$HOME/projects/alpha"
BRIEF="$HOME/data/$ID/brief.md"
VALIDATOR="$ROOT/bin/sq-plan-validate.sh"

# plan_block <field> - emit one required field's label and body lines.
plan_block() {
  case "$1" in
    files) printf '%s\n' 'Files to touch (exact paths):' '- `bin/sq-plan-validate.sh` (new)' '- `AGENTS.md`' ;;
    steps) printf '%s\n' 'Ordered steps:' '1. Read the sources.' '2. Implement the validator.' ;;
    acceptance) printf '%s\n' 'Acceptance criteria:' '- A complete plan passes.' ;;
    verification) printf '%s\n' 'Verification commands:' '- `bin/sq-lint.sh`' ;;
    out-of-scope) printf '%s\n' 'Out of scope:' '- No change to existing playbook criteria.' ;;
  esac
}

# write_plan <file> [omit-field] [blank-field]
# omit-field: drop that field entirely. blank-field: keep its label, no body.
write_plan() {
  local file=$1 omit=${2:-} blank=${3:-} f
  {
    printf '%s\n' '# Task' '' '## Execution plan' ''
    for f in files steps acceptance verification out-of-scope; do
      [ "$f" = "$omit" ] && continue
      if [ "$f" = "$blank" ]; then
        plan_block "$f" | head -n 1
        continue
      fi
      plan_block "$f"
    done
    printf '%s\n' '' 'Constraints: repository requires the drill signature.' '' '# Next section' 'not part of the plan'
  } > "$file"
}

# ---------------------------------------------------------------------------
# A complete plan passes.
# ---------------------------------------------------------------------------
write_plan "$BRIEF"
out=$(SQUAD_BASE="$HOME" "$VALIDATOR" "$ID" 2>&1); rc=$?
expect_code 0 "$rc" "a complete execution plan should validate"
assert_contains "$out" "execution plan structurally valid" "validator should report a successful validation"

# ---------------------------------------------------------------------------
# Each field omitted entirely fails with its own named message, and the other
# fields are not reported as missing.
# ---------------------------------------------------------------------------
while IFS='|' read -r field label; do
  write_plan "$BRIEF" "$field"
  out=$(SQUAD_BASE="$HOME" "$VALIDATOR" "$ID" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an omitted '$field' field should fail"
  assert_contains "$out" "missing: execution plan field \"$label\"" "omitted '$field' was not named"
  while IFS='|' read -r other otherlabel; do
    [ "$other" = "$field" ] && continue
    assert_not_contains "$out" "execution plan field \"$otherlabel\"" "omitted '$field' wrongly reported '$other'"
  done <<'FIELDS'
files|files to touch (exact paths)
steps|ordered steps
acceptance|acceptance criteria
verification|verification command
out-of-scope|out of scope
FIELDS
done <<'FIELDS'
files|files to touch (exact paths)
steps|ordered steps
acceptance|acceptance criteria
verification|verification command
out-of-scope|out of scope
FIELDS

# ---------------------------------------------------------------------------
# A field present but structurally empty fails as empty, not missing.
# ---------------------------------------------------------------------------
while IFS='|' read -r field label; do
  write_plan "$BRIEF" '' "$field"
  out=$(SQUAD_BASE="$HOME" "$VALIDATOR" "$ID" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an empty '$field' field should fail"
  assert_contains "$out" "empty: execution plan field \"$label\"" "empty '$field' was not named as empty"
done <<'FIELDS'
files|files to touch (exact paths)
steps|ordered steps
acceptance|acceptance criteria
verification|verification command
out-of-scope|out of scope
FIELDS

# ---------------------------------------------------------------------------
# Structural depth: files need a path-like entry and steps need a numbered step.
# ---------------------------------------------------------------------------
{
  printf '%s\n' '# Task' '' '## Execution plan'
  printf '%s\n' 'Files to touch (exact paths):' '- somewhere in the codebase'
  plan_block steps
  plan_block acceptance
  plan_block verification
  plan_block out-of-scope
} > "$BRIEF"
out=$(SQUAD_BASE="$HOME" "$VALIDATOR" "$ID" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a files field without a path-like entry should fail"
assert_contains "$out" "no path-like entry" "missing path-like entry was not named"
{
  printf '%s\n' '# Task' '' '## Execution plan'
  plan_block files
  printf '%s\n' 'Ordered steps:' '- just do it'
  plan_block acceptance
  plan_block verification
  plan_block out-of-scope
} > "$BRIEF"
out=$(SQUAD_BASE="$HOME" "$VALIDATOR" "$ID" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a steps field without a numbered step should fail"
assert_contains "$out" "no numbered step" "missing numbered step was not named"

# ---------------------------------------------------------------------------
# A brief with no execution plan section is refused by name.
# ---------------------------------------------------------------------------
printf '%s\n' '# Task' '' 'no plan here' > "$BRIEF"
out=$(SQUAD_BASE="$HOME" "$VALIDATOR" "$ID" 2>&1); rc=$?
expect_code 1 "$rc" "a brief without an execution plan should fail"
assert_contains "$out" "missing: execution plan section" "missing plan section was not named"

# A plan section ends at the next heading: a required field supplied only under
# a later heading does not satisfy the plan.
{
  printf '%s\n' '# Task' '' '## Execution plan'
  plan_block files
  plan_block steps
  plan_block acceptance
  plan_block out-of-scope
  printf '%s\n' '' '## Notes' '' 'Verification commands:' '- `bin/sq-lint.sh`'
} > "$BRIEF"
out=$(SQUAD_BASE="$HOME" "$VALIDATOR" "$ID" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a required field under a later heading must not satisfy the plan"
assert_contains "$out" 'missing: execution plan field "verification command"' "later-heading field wrongly satisfied the plan"

# ---------------------------------------------------------------------------
# sq-spawn.sh refuses a plan-execute@1 brief whose plan is incomplete before any
# endpoint or metadata exists. Only the playbook gate is under test here; the
# refusal lands before backend selection.
# ---------------------------------------------------------------------------
SPAWN_ID=plan-execute-spawn
mkdir -p "$HOME/data/$SPAWN_ID" "$HOME/projects/alpha"
cat > "$HOME/data/$SPAWN_ID/brief.md" <<'EOF'
Execution playbook: id=plan-execute version=1
# Execution playbook: `plan-execute@1`
Delivery contract: mode=drill
The operator must report status: echo '{state}: {note}' >> 'state/task.status'
## Execution plan
Files to touch (exact paths):
- `bin/sq-plan-validate.sh`
Ordered steps:
1. Implement the validator.
EOF
out=$(SQUAD_ROOT_OVERRIDE='' SQUAD_BASE="$HOME" SQUAD_STATE_OVERRIDE="$HOME/state" \
  SQUAD_DATA_OVERRIDE="$HOME/data" SQUAD_PROJECTS_OVERRIDE="$HOME/projects" \
  SQUAD_CONFIG_OVERRIDE="$HOME/config" SQUAD_BACKEND=tmux SQUAD_SPAWN_NO_GUARD=1 TMUX='' \
  "$ROOT/bin/sq-spawn.sh" "$SPAWN_ID" projects/alpha --mode drill --yolo off 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "spawn should refuse a plan-execute@1 brief with an incomplete plan"
assert_contains "$out" 'missing: execution plan field "acceptance criteria"' "spawn refusal omitted the validator's named failure"
assert_contains "$out" "failed structural validation" "spawn refusal did not name the plan gate"
assert_absent "$HOME/state/$SPAWN_ID.meta" "a refused plan-execute spawn must not create task metadata"

pass "sq-plan validator: complete plans pass, every missing field is named, and spawn refuses an incomplete plan"
