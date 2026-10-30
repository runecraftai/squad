#!/usr/bin/env bash
# Behavior tests for the report-mode scope gate: the `Files to touch` entries a
# brief declares compared with the files the task's worktree actually changed,
# and its report-only wiring inside bin/sq-playbook-validate.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

GATE="$ROOT/bin/sq-scope-gate.py"
VALIDATOR="$ROOT/bin/sq-playbook-validate.sh"
TMP=$(fm_test_tmproot sq-scope-gate)
fm_git_identity

# One repository with a default branch plus a task worktree whose branch touches
# one declared file, one sibling file the brief never names, and leaves a third
# file untouched.
REPO="$TMP/repo"
WT="$TMP/wt"
mkdir -p "$REPO/src"
printf 'a\n' > "$REPO/src/planned.txt"
printf 'b\n' > "$REPO/src/sibling.txt"
printf 'c\n' > "$REPO/src/untouched.txt"
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" commit -qm initial
git -C "$REPO" worktree add -q -b sq/task "$WT"
printf 'a2\n' > "$WT/src/planned.txt"
printf 'b2\n' > "$WT/src/sibling.txt"
git -C "$WT" add -A
git -C "$WT" commit -qm change

BASE="$TMP/base"
STATE="$BASE/state"
DATA="$BASE/data"
mkdir -p "$STATE" "$DATA"
fm_write_meta "$STATE/task.meta" "worktree=$WT" "branch=sq/task"

write_brief() {
  mkdir -p "$DATA/$1"
  cat > "$DATA/$1/brief.md"
}

gate() {
  SQUAD_BASE="$BASE" python3 "$GATE" "$@" 2>&1
}

write_brief task <<'EOF'
## Execution plan

Files to touch
- `src/planned.txt` - the declared change

Ordered steps
1. edit the declared file

Acceptance criteria
- the declared file changes

Verification commands
- true

Out of scope
- anything else
EOF

out=$(gate task); rc=$?
expect_code 0 "$rc" "the scope gate must always exit 0"
assert_contains "$out" "declared=1 touched=2" "the gate should count both sides of the comparison"
assert_contains "$out" "planned src/planned.txt" "the declared and touched file should be reported as planned"
undeclared_lines=$(printf '%s\n' "$out" | grep -c '^undeclared ')
[ "$undeclared_lines" -eq 1 ] || fail "a sibling file outside the plan should print exactly one undeclared line (got $undeclared_lines): $out"
assert_contains "$out" "undeclared src (1): src/sibling.txt" "the undeclared sibling should be grouped by its directory"
assert_not_contains "$out" "declared_but_untouched" "a matched declaration must not be reported as untouched"
assert_not_contains "$out" "src/untouched.txt" "an untouched, undeclared file must not be reported"
pass "sq-scope-gate: a declared file and an undeclared sibling classify apart"

# An unread brief declares a file the diff never touched.
fm_write_meta "$STATE/task2.meta" "worktree=$WT"
write_brief task2 <<'EOF'
## Execution plan

Files to touch
- `src/nowhere.txt`
EOF
out=$(gate task2); rc=$?
expect_code 0 "$rc" "an untouched declaration must not fail the gate"
assert_contains "$out" "declared_but_untouched src/nowhere.txt" "an untouched declaration should be reported"
assert_contains "$out" "undeclared src (2)" "both touched files should be undeclared under one area"
pass "sq-scope-gate: a declaration the diff never touched is reported"

# A declaration written as an absolute worktree path is normalized before the
# comparison, so it is not double-counted as both untouched and undeclared.
fm_write_meta "$STATE/task3.meta" "worktree=$WT"
write_brief task3 <<EOF
## Execution plan

Files to touch
- \`$WT/src/planned.txt\`
EOF
out=$(gate task3); rc=$?
expect_code 0 "$rc" "an absolute worktree declaration must not fail the gate"
assert_contains "$out" "declared=1 touched=2" "the absolute declaration should be normalized before counting"
assert_contains "$out" "planned src/planned.txt" "an absolute worktree declaration should match the relative diff path"
assert_not_contains "$out" "declared_but_untouched" "a normalized declaration must not be reported as untouched"
assert_contains "$out" "undeclared src (1): src/sibling.txt" "only the sibling should remain undeclared"
pass "sq-scope-gate: an absolute worktree declaration is normalized"

# A brief without the section is a skip, never an error.
write_brief noplan <<'EOF'
## Execution plan

Ordered steps
1. do something
EOF
out=$(gate noplan); rc=$?
expect_code 0 "$rc" "a brief without Files to touch must exit 0"
[ "$out" = "scope-gate: skip" ] || fail "a brief without Files to touch should print the bare skip sentinel (got: $out)"
pass "sq-scope-gate: a brief without Files to touch skips"

# A brief label with nothing path-like is a skip that says why.
write_brief nopaths <<'EOF'
## Execution plan

Files to touch
- see the design report
EOF
out=$(gate nopaths); rc=$?
expect_code 0 "$rc" "an unparseable Files to touch section must exit 0"
assert_contains "$out" "scope-gate: skip (" "an empty declaration should name its reason"
pass "sq-scope-gate: an empty Files to touch section skips with a reason"

# Missing metadata and a missing worktree are skips, not failures.
write_brief nometa <<'EOF'
Files to touch
- `src/planned.txt`
EOF
out=$(gate nometa); rc=$?
expect_code 0 "$rc" "a task without metadata must exit 0"
assert_contains "$out" "scope-gate: skip (no task meta" "a missing meta file should be named in the skip"
fm_write_meta "$STATE/gone.meta" "worktree=$TMP/gone"
write_brief gone <<'EOF'
Files to touch
- `src/planned.txt`
EOF
out=$(gate gone); rc=$?
expect_code 0 "$rc" "a task whose worktree is gone must exit 0"
assert_contains "$out" "scope-gate: skip (worktree is missing" "a missing worktree should be named in the skip"
out=$(gate 'bad id!'); rc=$?
expect_code 0 "$rc" "an invalid task id must exit 0"
assert_contains "$out" "scope-gate: skip (usage" "an invalid task id should print the usage skip"
pass "sq-scope-gate: unresolvable inputs skip instead of failing"

# There is no strict mode: an extra flag cannot turn the report into a gate.
out=$(gate task --strict); rc=$?
expect_code 0 "$rc" "extra flags must not add a failing mode"
assert_contains "$out" "undeclared src (1): src/sibling.txt" "an extra flag must not change the report"
pass "sq-scope-gate: no strict mode exists"

# The validator keeps its own exit codes and messages while prefixing the report.
PB="$DATA/pb"
mkdir -p "$PB/artifacts"
write_brief pb <<'EOF'
Files to touch
- `src/planned.txt`
EOF
fm_write_meta "$STATE/pb.meta" "worktree=$WT" "playbook=plan-execute" "playbook_version=1"
cat > "$PB/artifacts/checks.md" <<'EOF'
# plan-execute@1 checklist
## Criterion 1
Proof: files touched as planned path: src/planned.txt
## Criterion 2
Proof: steps executed command: true
## Criterion 3
Proof: acceptance met criteria verified path: src/planned.txt
## Criterion 4
Proof: verification run result command: true
EOF
out=$(SQUAD_BASE="$BASE" "$VALIDATOR" pb 2>&1); rc=$?
expect_code 0 "$rc" "a valid checklist must still validate"
assert_contains "$out" "playbook evidence valid: plan-execute@1" "the validator's success message must not change"
assert_contains "$out" "scope-gate (report): declared=1 touched=2" "the validator should prefix the scope report"
assert_contains "$out" "scope-gate (report): undeclared src (1): src/sibling.txt" "the prefixed report should carry the undeclared line"
cat > "$PB/artifacts/checks.md" <<'EOF'
# plan-execute@1 checklist
## Criterion 1
Proof: files touched as planned path: src/planned.txt
## Criterion 2
Proof: steps executed command: true
## Criterion 3
Proof: acceptance met criteria verified path: src/planned.txt
EOF
out=$(SQUAD_BASE="$BASE" "$VALIDATOR" pb 2>&1); rc=$?
expect_code 1 "$rc" "an incomplete checklist must still fail the validator"
assert_contains "$out" "missing: criterion 4" "the validator's failure message must not change"
assert_contains "$out" "scope-gate (report): undeclared src (1): src/sibling.txt" "the report should still print before a failing exit"
assert_not_contains "$out" "Traceback" "the scope gate must never raise into the validator"
pass "sq-playbook validator: the scope report never changes its verdict"

# Every real brief in this base parses without raising. CI has no private data
# directory, so the sweep reports that it had nothing to read.
shopt -s nullglob
real=("$ROOT"/data/*/brief.md)
if [ "${#real[@]}" -eq 0 ]; then
  pass "sq-scope-gate: no real briefs under data/ to sweep"
else
  mkdir -p "$DATA/sweep"
  fm_write_meta "$STATE/sweep.meta" "worktree=$WT"
  for path in "${real[@]}"; do
    cp "$path" "$DATA/sweep/brief.md"
    out=$(gate sweep); rc=$?
    expect_code 0 "$rc" "the gate must exit 0 for $path"
    assert_not_contains "$out" "Traceback" "the parser must not raise on $path"
    case "$out" in
      "scope-gate: skip"*|"declared="*) : ;;
      *) fail "the gate must answer for $path with a skip or report (got: $out)" ;;
    esac
  done
  pass "sq-scope-gate: ${#real[@]} real briefs parse without raising"
fi
