#!/usr/bin/env bash
# Focused behavior tests for execution playbook evidence validation.
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
# Criterion-specific quality checks: criterion 1 must contain before or pre-fix.
cat > "$CHECK" <<'EOF'
# bug-fix@1 checklist
## Criterion 1
Proof: reproduction command: reproduce failure
## Criterion 2
Proof: causal explanation with refutable observation command
## Criterion 3
Proof: regression test pre-fix and post-fix command
## Criterion 4
Proof: relevant suite command green pass
## Criterion 5
Proof: original surface re-exercised same command
EOF
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$ID" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "criterion 1 without before/pre-fix should fail"
assert_contains "$out" "quality" "validator should report quality check failure"
# Criterion-specific quality checks: criterion 3 must contain both pre-fix and post-fix.
cat > "$CHECK" <<'EOF'
# bug-fix@1 checklist
## Criterion 1
Proof: reproduction before fix command
## Criterion 2
Proof: causal explanation refutable observation command
## Criterion 3
Proof: regression test pre-fix command only
## Criterion 4
Proof: relevant suite command green pass
## Criterion 5
Proof: original surface re-exercised same command
EOF
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$ID" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "criterion 3 without post-fix should fail"
assert_contains "$out" "criterion 3" "validator should report criterion 3 quality failure"
# Duplicate-proof detection: adjacent criteria must not reuse identical proof.
cat > "$CHECK" <<'EOF'
# bug-fix@1 checklist
## Criterion 1
Proof: reproduction before fix command
## Criterion 2
Proof: reproduction before fix command
## Criterion 3
Proof: regression test pre-fix and post-fix command
## Criterion 4
Proof: relevant suite green pass command
## Criterion 5
Proof: original surface re-exercised same command
EOF
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$ID" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "duplicate proofs for criteria 1 and 2 should fail"
assert_contains "$out" "reuse one generic proof" "validator should report duplicate proof"
# Duplicate-proof detection: non-adjacent criteria must not reuse identical proof.
cat > "$CHECK" <<'EOF'
# bug-fix@1 checklist
## Criterion 1
Proof: reproduction before fix command
## Criterion 2
Proof: causal explanation refutable observation command
## Criterion 3
Proof: reproduction before fix command
## Criterion 4
Proof: relevant suite green pass command
## Criterion 5
Proof: original surface re-exercised same command
EOF
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$ID" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "duplicate proofs for criteria 1 and 3 should fail"
assert_contains "$out" "criteria 1 and 3" "validator should report non-adjacent duplicate proof"
pass "sq-playbook validator: complete and incomplete evidence are distinguished"

for playbook in investigation feature refactoring prototype; do
  id="wave-$playbook"
  mkdir -p "$HOME/data/$id/artifacts"
  printf 'playbook=%s\nplaybook_version=1\n' "$playbook" > "$HOME/state/$id.meta"
  {
    printf '# %s@1 checklist\n' "$playbook"
    case "$playbook" in
      investigation)
        printf '%s\n' '## Criterion 1' 'Proof: facts and inferences observation command' '## Criterion 2' 'Proof: source citation artifact command' '## Criterion 3' 'Proof: uncertainty gap report command' '## Criterion 4' 'Proof: implication decision hold command' ;;
      feature)
        printf '%s\n' '## Criterion 1' 'Proof: behavior contract expected rejected command' '## Criterion 2' 'Proof: data shape boundary caller command' '## Criterion 3' 'Proof: vertical slice implementation command' '## Criterion 4' 'Proof: surface test command result' ;;
      refactoring)
        printf '%s\n' '## Criterion 1' 'Proof: characterization capture before command' '## Criterion 2' 'Proof: invariants target shape command' '## Criterion 3' 'Proof: bounded transformation subtract command' '## Criterion 4' 'Proof: equivalence preserve behavior command' ;;
      prototype)
        printf '%s\n' '## Criterion 1' 'Proof: decision question scope command' '## Criterion 2' 'Proof: alternatives reference gather command' '## Criterion 3' 'Proof: timebox start end command' '## Criterion 4' 'Proof: surface observation comparison command' '## Criterion 5' 'Proof: decision cite recommendation command' ;;
    esac
  } > "$HOME/data/$id/artifacts/checks.md"
  out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
  expect_code 0 "$rc" "$playbook evidence should validate"
  assert_contains "$out" "playbook evidence valid: $playbook@1" "$playbook validator identity missing"
done

for playbook in perf hillclimb runtime-forensics trace-forensics visual-parity; do
  id="wave-two-$playbook"
  mkdir -p "$HOME/data/$id/artifacts"
  printf 'playbook=%s\nplaybook_version=1\n' "$playbook" > "$HOME/state/$id.meta"
  {
    printf '# %s@1 checklist\n' "$playbook"
    case "$playbook" in
      perf)
        printf '%s\n' '## Criterion 1' 'Proof: reproducible baseline repeat command path' '## Criterion 2' 'Proof: profile artifact path command' '## Criterion 3' 'Proof: hypothesis smallest change command' '## Criterion 4' 'Proof: same command numeric comparison measurement' '## Criterion 5' 'Proof: regression check incompatible baseline stop command' ;;
      hillclimb)
        printf '%s\n' '## Criterion 1' 'Proof: target metric baseline command' '## Criterion 2' 'Proof: one cycle hypothesis alteration measurement command' '## Criterion 3' 'Proof: decision keep command' '## Criterion 4' 'Proof: accepted gain commit retained command' '## Criterion 5' 'Proof: incompatible measurement stop command' ;;
      runtime-forensics)
        printf '%s\n' '## Criterion 1' 'Proof: live capture before instrumentation command path' '## Criterion 2' 'Proof: timeline reduced smoking gun command' '## Criterion 3' 'Proof: mechanism proof causal command' '## Criterion 4' 'Proof: source diagnosis recon command' ;;
      trace-forensics)
        printf '%s\n' '## Criterion 1' 'Proof: artifact path hash command' '## Criterion 2' 'Proof: queryable transform command' '## Criterion 3' 'Proof: trace event evidence query command' '## Criterion 4' 'Proof: source diagnosis unknown symbols stop command' ;;
      visual-parity)
        printf '%s\n' '## Criterion 1' 'Proof: prior posterior reference path command' '## Criterion 2' 'Proof: surface viewport data state command' '## Criterion 3' 'Proof: reexecuted comparison command' '## Criterion 4' 'Proof: named divergence list command' '## Criterion 5' 'Proof: predicate recon report and strike validation command' ;;
    esac
  } > "$HOME/data/$id/artifacts/checks.md"
  out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
  expect_code 0 "$rc" "$playbook evidence should validate"
  assert_contains "$out" "playbook evidence valid: $playbook@1" "$playbook validator identity missing"
  case "$playbook" in
    perf) sed -i 's/same command numeric comparison measurement/numeric comparison measurement/' "$HOME/data/$id/artifacts/checks.md" ;;
    hillclimb) sed -i 's/one cycle hypothesis alteration measurement/one cycle hypothesis alteration/' "$HOME/data/$id/artifacts/checks.md" ;;
    runtime-forensics) sed -i 's/live capture before instrumentation/capture after instrumentation/' "$HOME/data/$id/artifacts/checks.md" ;;
    trace-forensics) sed -i 's/artifact path hash/artifact path/' "$HOME/data/$id/artifacts/checks.md" ;;
    visual-parity) sed -i 's/surface viewport data state/surface viewport/' "$HOME/data/$id/artifacts/checks.md" ;;
  esac
  out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$playbook non-comparable or incomplete evidence should fail"
  assert_contains "$out" "quality" "$playbook refusal should identify an evidence quality failure"
done
for playbook in multi-phase-plan eval plan-execute; do
  id="lifecycle-$playbook"
  mkdir -p "$HOME/data/$id/artifacts"
  printf 'playbook=%s\nplaybook_version=1\n' "$playbook" > "$HOME/state/$id.meta"
  {
    printf '# %s@1 checklist\n' "$playbook"
    case "$playbook" in
      multi-phase-plan)
        printf '%s\n' '## Criterion 1' 'Proof: outcome and real dependencies command path' '## Criterion 2' 'Proof: unit verification command path' '## Criterion 3' 'Proof: not a layer task decomposition command path' '## Criterion 4' 'Proof: existing backlog handoff queue command path' '## Criterion 5' 'Proof: next action unresolved question command path' ;;
      eval)
        printf '%s\n' '## Criterion 1' 'Proof: baseline variant metric rubric command path' '## Criterion 2' 'Proof: sanitized candidate-visible path directory cue command path' '## Criterion 3' 'Proof: blinded cases judge command path' '## Criterion 4' 'Proof: chain elicitation prevention stop command path' '## Criterion 5' 'Proof: recommendation promote or reject production promotion command path' ;;
      plan-execute)
        printf '%s\n' '## Criterion 1' 'Proof: files touched as planned path: bin/x.sh command: git status' '## Criterion 2' 'Proof: steps executed in order command: run the plan' '## Criterion 3' 'Proof: acceptance criteria met command: verify behavior' '## Criterion 4' 'Proof: verification command run result path: out.log' ;;
    esac
  } > "$HOME/data/$id/artifacts/checks.md"
  out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
  expect_code 0 "$rc" "$playbook evidence should validate"
  assert_contains "$out" "playbook evidence valid: $playbook@1" "$playbook validator identity missing"
done
react_proofs=(
  'architecture layers and boundaries path: src/app/routes.tsx command: lint passed'
  'components named functions and kebab-case path: src/pages/sign-in/ui.tsx'
  ''
  'lint proposal with rationale and approval pending path: artifacts/lint-decision.md'
  'behavior surface test command: web test passed'
)
react_records='Routing: unchanged - no route or guard edits; path: src/app/routes.tsx
Queries: changed - added the read-only use-audits key in entities/audit/model.ts; command: bun run check passed'
write_react_evidence() {
  local omitted=${1:-0} i
  printf '# react@1 checklist\n'
  for ((i=0; i<${#react_proofs[@]}; i++)); do
    printf '## Criterion %s\n' "$((i+1))"
    [ "$((i+1))" -eq "$omitted" ] && continue
    if [ "$((i+1))" -eq 3 ]; then
      printf '%s\n' "$react_records"
    else
      printf 'Proof: %s\n' "${react_proofs[$i]}"
    fi
  done
}
id=react-evidence
mkdir -p "$HOME/data/$id/artifacts"
printf 'playbook=react\nplaybook_version=1\n' > "$HOME/state/$id.meta"
write_react_evidence > "$HOME/data/$id/artifacts/checks.md"
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
expect_code 0 "$rc" "complete React evidence should validate"
assert_contains "$out" 'playbook evidence valid: react@1' 'React evidence identity missing'
# Both dimensions are required, but any changed/unchanged combination and free-text phrasing is valid.
while IFS='|' read -r routing queries; do
  react_records="$routing
$queries"
  write_react_evidence > "$HOME/data/$id/artifacts/checks.md"
  out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
  expect_code 0 "$rc" "React records should validate: $routing / $queries"
  assert_contains "$out" 'playbook evidence valid: react@1' 'React record evidence identity missing'
done <<'EOF'
Routing: changed - code-based route added in src/app/routes.tsx; command: bun run check passed|Queries: changed - new use-audits key in entities/audit/model.ts; no mutation; command: bun test
routing: CHANGED - Route tree built in code, see src/app/routes.tsx|QUERIES: UNCHANGED - no query module touched
Routing: unchanged - no route or guard edits; path: src/app/routes.tsx|Queries: unchanged - existing invalidation retained; path: entities/session/model.ts
Routing: changed - beforeLoad guard redirect in src/app/routes.tsx|Queries: unchanged - path: entities/audit/model.ts
EOF
react_records='Routing: unchanged - no route or guard edits; path: src/app/routes.tsx
Queries: changed - added the read-only use-audits key in entities/audit/model.ts; command: bun run check passed'
expect_react_refusal() {
  local records=$1 message=$2 expected=$3
  react_records=$records
  write_react_evidence > "$HOME/data/$id/artifacts/checks.md"
  out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$message"
  assert_contains "$out" "$expected" "$message"
}
for criterion in 1 2 4 5; do
  write_react_evidence "$criterion" > "$HOME/data/$id/artifacts/checks.md"
  out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "React must reject missing criterion $criterion"
  assert_contains "$out" "missing: criterion $criterion" 'React refusal must identify missing evidence'
done
write_react_evidence 3 > "$HOME/data/$id/artifacts/checks.md"
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail 'React must reject a criterion 3 with no routing or queries record'
assert_contains "$out" 'criterion 3' 'React refusal must identify the empty routing/queries criterion'
expect_react_refusal 'Queries: unchanged - path: entities/audit/model.ts' \
  'React must reject criterion 3 without a routing record' 'missing Routing record'
expect_react_refusal 'Routing: unchanged - path: src/app/routes.tsx' \
  'React must reject criterion 3 without a queries record' 'missing Queries record'
expect_react_refusal 'Routing: changed - path: src/app/routes.tsx
Routing: unchanged - duplicate; path: src/app/routes.tsx
Queries: unchanged - path: entities/audit/model.ts' \
  'React must reject a duplicated routing record' 'duplicate Routing record'
expect_react_refusal 'Routing: modified - path: src/app/routes.tsx
Queries: unchanged - path: entities/audit/model.ts' \
  'React must reject a routing record with an unknown state' 'must declare changed or unchanged'
expect_react_refusal 'Routing: changed path: src/app/routes.tsx
Queries: unchanged - path: entities/audit/model.ts' \
  'React must reject a routing record without the separator' 'must follow Routing: <state> - <free text>'
expect_react_refusal 'Routing: changed - path: src/app/routes.tsx
Queries: unchanged -' \
  'React must reject an unchanged queries record without explanatory text' 'Queries record needs nonblank free-text evidence'
expect_react_refusal "$(printf 'Routing: changed -   \nQueries: changed - path: entities/audit/model.ts')" \
  'React must reject a changed routing record with whitespace-only evidence' 'Routing record needs nonblank free-text evidence'
react_proofs[3]='lint proposal path: artifacts/lint-decision.md'
react_records='Routing: unchanged - path: src/app/routes.tsx
Queries: unchanged - path: entities/audit/model.ts'
write_react_evidence > "$HOME/data/$id/artifacts/checks.md"
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail 'React must reject lint evidence without rationale and approval disposition'
assert_contains "$out" 'criterion 4' 'React refusal must identify incomplete lint evidence'
react_proofs[3]='lint proposal with rationale and approval pending path: artifacts/lint-decision.md'
write_react_evidence > "$HOME/data/$id/artifacts/checks.md"
printf 'playbook=react\nplaybook_version=2\n' > "$HOME/state/$id.meta"
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" "$id" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail 'React must reject unsupported evidence versions'
assert_contains "$out" 'unsupported execution playbook identity' 'React version refusal missing'
pass 'sq-playbook validator: React requires all five criteria and a deliberated lint proposal'

printf 'playbook=shipping\nplaybook_version=1\n' > "$HOME/state/rejected.meta"
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" rejected 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "rejected shipping identity should be refused"
assert_contains "$out" "unsupported execution playbook identity" "rejected identity refusal missing"
printf 'playbook=unknown\nplaybook_version=1\n' > "$HOME/state/invalid.meta"
out=$(SQUAD_BASE="$HOME" "$ROOT/bin/sq-playbook-validate.sh" invalid 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "invalid playbook identity should be refused"
assert_contains "$out" "unsupported execution playbook identity" "invalid identity refusal missing"
pass "sq-playbook validator: wave-one contracts validate and invalid identity is refused"
