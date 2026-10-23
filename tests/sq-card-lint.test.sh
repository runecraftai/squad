#!/usr/bin/env bash
# Tests for bin/sq-card-lint.sh - the warning-only decision-card grammar check.
#
# The linter never blocks: warnings go to stderr and the exit code is always 0.
# These tests drive the real executable over fixture records and assert the
# exact warning lines, so an extra or missing warning fails the case.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/sq-card-lint.sh"
FIX="$ROOT/tests/fixtures/decision-prose"
TMP_ROOT=$(fm_test_tmproot sq-card-lint)

# lint_file <path>: sets L_ERR (stderr only) and L_RC (exit code).
lint_file() {
  L_ERR=$("$LINT" "$1" 2>&1 >/dev/null); L_RC=$?
}

# expect_warnings <path> <label> [warning...]: lints the file, then asserts the
# exit code is 0 and stderr is exactly the given warning lines, in order.
expect_warnings() {
  local path=$1 label=$2 want
  shift 2
  want=$(printf '%s\n' "$@")
  lint_file "$path"
  expect_code 0 "$L_RC" "$label"
  [ "$L_ERR" = "$want" ] || fail "$label: stderr mismatch"$'\n'"--- want ---"$'\n'"$want"$'\n'"--- got ---"$'\n'"$L_ERR"
  pass "$label"
}

# write_record <name>: writes stdin to $TMP_ROOT/<name> and sets REC to its path.
# Not called via $(...): stock Bash 3.2 cannot parse backticks in a heredoc
# body inside a command substitution.
write_record() {
  cat > "$TMP_ROOT/$1"
  REC="$TMP_ROOT/$1"
}

test_well_formed_records_are_silent() {
  expect_warnings "$FIX/merge.prose" "T1: golden merge prose is silent"
  expect_warnings "$FIX/gate.prose" "T1b: golden gate prose is silent"
  expect_warnings "$FIX/scope.prose" "T1c: golden scope prose is silent"

  local path
  write_record well-formed.md <<'EOF'
# Review

F1 - review-1 src/a.go:10 - flags an intentional guard

D1 - Review gate: 2 open findings (ref: review-gate-1)
  Should the findings be fixed?
  Context: CI is red on two checks.
  O1 - Fix F1 and F2: apply both as proposed (recommended)
  O2 - Accept as is: keep the code, finish this step
  O3 - Skip the step: do not run this check
  O0 - Your own words
EOF
  path=$REC
  expect_warnings "$path" "T2: a well-formed card with findings and the O0 escape is silent"
}

test_no_recommended_option() {
  local path
  write_record no-recommended.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one commit
  O2 - Rebase: keep both commits
EOF
  path=$REC
  expect_warnings "$path" "T3: a card with no recommended option warns on its header" \
    "warning: $path:1: RECOMENDACAO_AUSENTE no option ends with (recommended)"
}

test_two_recommended_options() {
  local path
  write_record two-recommended.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one commit (recommended)
  O2 - Rebase: keep both commits (recommended)
EOF
  path=$REC
  expect_warnings "$path" "T4: two recommended options warn on the header" \
    "warning: $path:1: RECOMENDACAO_DUPLICADA 2 options end with (recommended)"
}

test_orphan_option() {
  local path
  write_record blank-keeps-block.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one commit (recommended)

  O2 - Rebase: keep both commits
EOF
  path=$REC
  expect_warnings "$path" "T5a: an option after a blank line stays inside the block"

  write_record heading-closes-block.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one commit (recommended)
# Notes
  O2 - Rebase: keep both commits
EOF
  path=$REC
  expect_warnings "$path" "T5c: a heading closes the block so the following option is an orphan" \
    "warning: $path:4: OPCAO_ORFA O2 is outside any decision block"

  write_record orphan-no-header.md <<'EOF'
Some prose.
  O1 - Squash: one commit (recommended)
EOF
  path=$REC
  expect_warnings "$path" "T5b: an option with no decision header is an orphan" \
    "warning: $path:2: OPCAO_ORFA O1 is outside any decision block"
}

test_recommended_marker_must_match_owner() {
  local path
  write_record no-space-marker.md <<'EOF'
D1 - Merge strategy
  O1 - Squash:(recommended)
EOF
  path=$REC
  expect_warnings "$path" "T3b: a marker with no space before it does not count as recommended" \
    "warning: $path:1: RECOMENDACAO_AUSENTE no option ends with (recommended)"

  write_record trailing-space-marker.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one (recommended) 
EOF
  path=$REC
  expect_warnings "$path" "T3c: a marker followed by trailing space does not count as recommended" \
    "warning: $path:1: RECOMENDACAO_AUSENTE no option ends with (recommended)"
}

test_unindented_option_in_block() {
  local path
  write_record unindented-option.md <<'EOF'
D1 - Merge strategy
O1 - Squash: one (recommended)
  O2 - Rebase: keep both commits
EOF
  path=$REC
  expect_warnings "$path" "T5d: an unindented option is reported once, and its marker and number still count" \
    "warning: $path:2: OPCAO_ORFA O1 must be indented two spaces inside its decision block"
}

test_crlf_records_are_silent() {
  local path
  path="$TMP_ROOT/crlf.md"
  printf 'D1 - Merge strategy\r\n  O1 - Squash: one commit\r\n  O2 - Rebase: keep both (recommended)\r\n' > "$path"
  expect_warnings "$path" "T5e: CRLF line endings do not hide the recommended marker"
}

test_non_consecutive_option() {
  local path
  write_record gap.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one commit (recommended)
  O3 - Rebase: keep both commits
EOF
  path=$REC
  expect_warnings "$path" "T6: a skipped option number warns on the line that breaks the sequence" \
    "warning: $path:3: OPCAO_FORA_DE_SEQUENCIA found O3, expected O2"
}

test_legacy_c_prefix() {
  local path
  write_record legacy-c.md <<'EOF'
C1 - Merge strategy
  O1 - Squash: one commit (recommended)
  O2 - Rebase: keep both commits
EOF
  path=$REC
  expect_warnings "$path" "T7: a C<n> header is accepted as a block but warned as legacy" \
    "warning: $path:1: PREFIXO_LEGADO legacy C prefix on decision header; write D<n> - "
}

test_operand_with_equals_is_a_file() {
  printf 'D1 - Merge strategy\n  O1 - Squash: one commit\n' > "$TMP_ROOT/a=b.md"
  L_ERR=$(cd "$TMP_ROOT" && "$LINT" 'a=b.md' 2>&1 >/dev/null < /dev/null); L_RC=$?
  expect_code 0 "$L_RC" "T10a: a relative file name containing '=' exits 0"
  [ "$L_ERR" = "warning: a=b.md:1: RECOMENDACAO_AUSENTE no option ends with (recommended)" ] \
    || fail "T10a: a relative file name containing '=' is linted, got: $L_ERR"
  pass "T10a: a relative file name containing '=' is linted, not taken as an awk assignment"
}

test_relative_operand_is_printed_as_typed() {
  printf 'D1 - Merge strategy\n  O1 - Squash: one commit\n' > "$TMP_ROOT/plain.md"
  L_ERR=$(cd "$TMP_ROOT" && "$LINT" 'plain.md' 2>&1 >/dev/null < /dev/null); L_RC=$?
  expect_code 0 "$L_RC" "T10b: a relative file name exits 0"
  [ "$L_ERR" = "warning: plain.md:1: RECOMENDACAO_AUSENTE no option ends with (recommended)" ] \
    || fail "T10b: a relative file name is printed as typed, got: $L_ERR"
  pass "T10b: a relative file name is printed as typed, with no ./ prefix"

  printf 'D1 - Merge strategy\n  O1 - Squash: one commit\n' > "$TMP_ROOT/a\\nb.md"
  L_ERR=$(cd "$TMP_ROOT" && "$LINT" 'a\nb.md' 2>&1 >/dev/null < /dev/null); L_RC=$?
  expect_code 0 "$L_RC" "T10c: a relative file name with a backslash exits 0"
  [ "$L_ERR" = 'warning: a\nb.md:1: RECOMENDACAO_AUSENTE no option ends with (recommended)' ] \
    || fail "T10c: a backslash in a file name is printed as typed, got: $L_ERR"
  pass "T10c: a backslash in a file name is printed as typed"
}

test_fenced_examples_are_skipped() {
  local path
  write_record fenced.md <<'EOF'
```
D1 - Example
  O1 - Broken: no marker
  O3 - Gap: skipped number
```
EOF
  path=$REC
  expect_warnings "$path" "T8: a bad card inside a fenced example is not a record"
}

test_fence_closes_only_on_matching_marker() {
  local path
  write_record fence-tilde-inside.md <<'EOF'
```
D1 - Example
~~~
  O1 - Broken: no marker
```
EOF
  path=$REC
  expect_warnings "$path" "T8b: a tilde line inside a backtick example does not end the example"

  write_record fence-lang-inside.md <<'EOF'
```
D1 - Example
```bash
  O1 - Broken: no marker
```
EOF
  path=$REC
  expect_warnings "$path" "T8c: a language-tagged fence line inside a backtick example does not end the example"
}

test_exit_is_always_zero() {
  lint_file "$TMP_ROOT/does-not-exist.md"
  expect_code 0 "$L_RC" "T9a: a missing file exits 0"
  [ "$L_ERR" = "warning: $TMP_ROOT/does-not-exist.md:0: ARQUIVO_ILEGIVEL cannot read file" ] \
    || fail "T9a: a missing file reports ARQUIVO_ILEGIVEL at line 0, got: $L_ERR"
  pass "T9a: a missing file reports ARQUIVO_ILEGIVEL at line 0"

  L_ERR=$("$LINT" 2>&1 >/dev/null); L_RC=$?
  expect_code 0 "$L_RC" "T9b: no arguments exits 0"
  assert_contains "$L_ERR" "Usage: bin/sq-card-lint.sh" "T9b: no arguments prints usage on stderr"

  local out
  out=$("$LINT" --help 2>/dev/null); L_RC=$?
  expect_code 0 "$L_RC" "T9c: --help exits 0"
  assert_contains "$out" "Always exits 0" "T9c: --help states the no-failure contract"

  pass "T9: the linter never fails a pipeline"
}

test_well_formed_records_are_silent
test_no_recommended_option
test_two_recommended_options
test_recommended_marker_must_match_owner
test_orphan_option
test_unindented_option_in_block
test_crlf_records_are_silent
test_non_consecutive_option
test_legacy_c_prefix
test_operand_with_equals_is_a_file
test_relative_operand_is_printed_as_typed
test_fenced_examples_are_skipped
test_fence_closes_only_on_matching_marker
test_exit_is_always_zero
