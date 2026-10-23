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

# write_record <name>: writes stdin to $TMP_ROOT/<name> and echoes its path.
write_record() {
  cat > "$TMP_ROOT/$1"
  printf '%s\n' "$TMP_ROOT/$1"
}

test_well_formed_records_are_silent() {
  expect_warnings "$FIX/merge.prose" "T1: golden merge prose is silent"
  expect_warnings "$FIX/gate.prose" "T1b: golden gate prose is silent"
  expect_warnings "$FIX/scope.prose" "T1c: golden scope prose is silent"

  local path
  path=$(write_record well-formed.md <<'EOF'
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
  )
  expect_warnings "$path" "T2: a well-formed card with findings and the O0 escape is silent"
}

test_no_recommended_option() {
  local path
  path=$(write_record no-recommended.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one commit
  O2 - Rebase: keep both commits
EOF
  )
  expect_warnings "$path" "T3: a card with no recommended option warns on its header" \
    "warning: $path:1: RECOMENDACAO_AUSENTE no option ends with (recommended)"
}

test_two_recommended_options() {
  local path
  path=$(write_record two-recommended.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one commit (recommended)
  O2 - Rebase: keep both commits (recommended)
EOF
  )
  expect_warnings "$path" "T4: two recommended options warn on the header" \
    "warning: $path:1: RECOMENDACAO_DUPLICADA 2 options end with (recommended)"
}

test_orphan_option() {
  local path
  path=$(write_record blank-keeps-block.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one commit (recommended)

  O2 - Rebase: keep both commits
EOF
  )
  expect_warnings "$path" "T5a: an option after a blank line stays inside the block"

  path=$(write_record heading-closes-block.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one commit (recommended)
# Notes
  O2 - Rebase: keep both commits
EOF
  )
  expect_warnings "$path" "T5c: a heading closes the block so the following option is an orphan" \
    "warning: $path:4: OPCAO_ORFA O2 is outside any decision block"

  path=$(write_record orphan-no-header.md <<'EOF'
Some prose.
  O1 - Squash: one commit (recommended)
EOF
  )
  expect_warnings "$path" "T5b: an option with no decision header is an orphan" \
    "warning: $path:2: OPCAO_ORFA O1 is outside any decision block"
}

test_recommended_marker_must_match_owner() {
  local path
  path=$(write_record no-space-marker.md <<'EOF'
D1 - Merge strategy
  O1 - Squash:(recommended)
EOF
  )
  expect_warnings "$path" "T3b: a marker with no space before it does not count as recommended" \
    "warning: $path:1: RECOMENDACAO_AUSENTE no option ends with (recommended)"

  path=$(printf 'D1 - Merge strategy\n  O1 - Squash: one (recommended) \n' | write_record trailing-space-marker.md)
  expect_warnings "$path" "T3c: a marker followed by trailing space does not count as recommended" \
    "warning: $path:1: RECOMENDACAO_AUSENTE no option ends with (recommended)"
}

test_unindented_option_in_block() {
  local path
  path=$(write_record unindented-option.md <<'EOF'
D1 - Merge strategy
O1 - Squash: one (recommended)
EOF
  )
  expect_warnings "$path" "T5d: an option not indented two spaces is an orphan, leaving the block without a recommendation" \
    "warning: $path:2: OPCAO_ORFA O1 must be indented two spaces inside its decision block" \
    "warning: $path:1: RECOMENDACAO_AUSENTE decision has no options"
}

test_non_consecutive_option() {
  local path
  path=$(write_record gap.md <<'EOF'
D1 - Merge strategy
  O1 - Squash: one commit (recommended)
  O3 - Rebase: keep both commits
EOF
  )
  expect_warnings "$path" "T6: a skipped option number warns on the line that breaks the sequence" \
    "warning: $path:3: OPCAO_FORA_DE_SEQUENCIA found O3, expected O2"
}

test_legacy_c_prefix() {
  local path
  path=$(write_record legacy-c.md <<'EOF'
C1 - Merge strategy
  O1 - Squash: one commit (recommended)
  O2 - Rebase: keep both commits
EOF
  )
  expect_warnings "$path" "T7: a C<n> header is accepted as a block but warned as legacy" \
    "warning: $path:1: PREFIXO_LEGADO legacy C prefix on decision header; write D<n> - "
}

test_fenced_examples_are_skipped() {
  local path
  path=$(write_record fenced.md <<'EOF'
```
D1 - Example
  O1 - Broken: no marker
  O3 - Gap: skipped number
```
EOF
  )
  expect_warnings "$path" "T8: a bad card inside a fenced example is not a record"
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
test_non_consecutive_option
test_legacy_c_prefix
test_fenced_examples_are_skipped
test_exit_is_always_zero
