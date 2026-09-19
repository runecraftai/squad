#!/usr/bin/env bash
# Focused behavior tests for bug-fix@1 evidence validation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot sq-playbook-validator)
HOME="$TMP_ROOT/home"
ID=bug-fix-test
mkdir -p "$HOME/data/$ID/artifacts" "$HOME/state"
printf 'playbook=bug-fix\nplaybook_version=1\n' > "$HOME/state/$ID.meta"
CHECK="$HOME/data/$ID/artifacts/checks.md"
write_valid() {
  cat > "$CHECK" <<'EOF'
# bug-fix@1 checklist
## Criterion 1
Proof: reproduction before fix command: reproduce failure
## Criterion 2
Proof: causal explanation with refutable evidence before fix observation and command
## Criterion 3
Proof: regression test post-fix command and pre-fix failure
## Criterion 4
Proof: relevant suite command post-fix suite green
## Criterion 5
Proof: original surface re-exercised post-fix command with same surface
EOF
}
write_valid
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$ID" 2>&1); rc=$?
expect_code 0 "$rc" "complete bug-fix evidence should validate"
assert_contains "$out" "playbook evidence valid" "validator should report a successful validation"
# A missing section and an empty proof are reported together.
cat > "$CHECK" <<'EOF'
# bug-fix@1 checklist
## Criterion 1
Proof:
## Criterion 2
Proof: causal explanation with refutable evidence command
EOF
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$ID" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "incomplete evidence should fail"
assert_contains "$out" "criterion 1" "validator omitted criterion 1 failure"
assert_contains "$out" "criterion 3" "validator did not list all missing evidence"
pass "sq-playbook validator: complete and incomplete evidence are distinguished"
