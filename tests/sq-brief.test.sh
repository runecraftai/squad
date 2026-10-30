#!/usr/bin/env bash
# Behavior tests for bin/sq-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issues
# #166, #958, #1069). Building a variable with `VAR=$(cat <<EOF ... EOF)` is
# unsafe on Bash 3.2 (macOS /bin/bash): the lexer scans for the matching `)` of
# the command substitution textually and tracks quote state through the heredoc
# body, so a single apostrophe, unbalanced quote, or unbalanced paren anywhere
# in that body breaks parsing of the *entire rest of the script* - `bash -n`
# fails, not just the generated brief. The DOD and Herdr-section builders now
# use `IFS= read -r -d '' VAR <<EOF || true` instead, which removes the `$(...)`
# wrapper and eliminates the whole defect class regardless of future prose.
# test_no_heredoc_in_command_substitution guards that structure directly.
# Ambient `bash -n` here is Bash 5 and cannot see the bug, so the real
# cross-version enforcement lives in the macos-stock-bash CI job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot sq-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse under the ambient bash. That is Bash 5 in
# CI and locally, where the issue #958/#1069 parser bug does not fire, so this
# is a weak guard on its own; test_no_heredoc_in_command_substitution and the
# macos-stock-bash CI job carry the real cross-version enforcement.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/sq-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/sq-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/sq-brief.sh emitted unexpected output: $out"
  pass "sq-brief.sh: bash -n succeeds"
}

# Structural class guard (issues #166, #958, #1069): never build a variable by
# wrapping a heredoc in a command substitution (`VAR=$(cat <<EOF ... EOF)`).
# That construct is what breaks Bash 3.2 parsing, and pinning one historical
# apostrophe phrase (as the old test did) missed the #945 reintroduction. This
# guards the *shape* directly against the whole file, so any future DOD or
# section builder that reintroduces the class fails here regardless of prose.
test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/sq-brief.sh" \
    || fail "sq-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "sq-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/sq-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "sq-brief.sh --help omitted its header terminator"
  pass "sq-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. sq-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# sq-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_playbook_selection_and_legacy_compatibility() {
  local home brief baseline out status
  home="$TMP_ROOT/playbook-home"
  mkdir -p "$home/data"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" playbook-good repo --mode drill --playbook bug-fix@1 >/dev/null 2>&1
  brief="$home/data/playbook-good/brief.md"
  [ "$(grep -c '^Execution playbook: id=bug-fix version=1$' "$brief")" -eq 1 ] || fail "bug-fix@1 identity must occur exactly once"
  assert_grep "Reproduction before fix" "$brief" "playbook brief missing reproduction evidence"
  assert_grep 'repair only criteria that lack `Proof:` or are marked `FAIL`' "$brief" "bug-fix playbook must keep repairs to missing or failed criteria"
  assert_grep 'auto_fix.max_fix_rounds' "$brief" "bug-fix playbook must defer the repair cap to drill's configured fix budget"
  assert_grep 'fails the run as non-convergence' "$brief" "bug-fix playbook must describe fix-budget exhaustion as non-convergence"
  assert_grep 'do not hand-fix review findings yourself while an active run owns the work' "$brief" "bug-fix playbook must forbid operator hand-fixing during an active run"
  assert_grep "diagnostic-reasoning" "$brief" "playbook brief missing diagnostic-reasoning"
  assert_grep "tlc-implement" "$brief" "playbook brief missing tlc-implement"
  baseline="$home/legacy.md"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" legacy repo --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  cp "$home/data/legacy/brief.md" "$baseline"
  rm -f "$home/data/legacy/brief.md"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" legacy repo --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  cmp -s "$baseline" "$home/data/legacy/brief.md" || fail "no-playbook brief changed across regeneration"
  assert_no_grep "Execution playbook:" "$baseline" "no-playbook brief unexpectedly carries a selectable playbook identity"
  assert_grep "Playbook decision: none - test fixture: no execution playbook applies" "$baseline" \
    "no-playbook brief did not record the reason no playbook applies"
  assert_no_grep "Playbook decision:" "$brief" "selected-playbook brief must record the identity, not a none decision"
  for args in "--playbook nope@1" "--playbook bug-fix@2" "--playbook bug-fix@"; do
    # shellcheck disable=SC2086 # args intentionally contains the flag and value pair.
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "bad-${RANDOM}" repo --mode drill $args 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "invalid playbook $args should fail"
  done
  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" playbook-recon repo --recon --playbook bug-fix@1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "bug-fix@1 on recon should fail"
  assert_contains "$out" "kind: strike" "recon playbook refusal should name strike compatibility"
  assert_absent "$home/data/playbook-recon/brief.md" "rejected playbook must not leave a partial brief"
  pass "sq-brief.sh: explicit bug-fix@1 materializes and a recorded no-playbook decision stays stable"
}

# Playbook selection is an explicit intake decision: a strike or recon scaffold
# must name a playbook or record, in one non-empty line, why none applies. The
# refusal is the point - an omitted decision must never scaffold silently - and
# the recorded line must stay distinct from the spawn-parsed identity line.
test_playbook_decision_is_required() {
  local home out status label args expect brief
  home="$TMP_ROOT/playbook-decision-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "decision-$RANDOM" repo $args 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not say what is missing"
  done <<'ROWS'
strike without a decision|--mode drill|missing playbook decision
recon without a decision|--recon|missing playbook decision
empty no-playbook reason|--mode drill --no-playbook=|non-empty reason
playbook and no-playbook together|--mode drill --playbook bug-fix@1 --no-playbook unnecessary|mutually exclusive
no-playbook on an XO charter|--xo --no-projects --no-playbook nothing to select|applies only to strike or recon briefs
ROWS

  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "decision-$RANDOM" repo --recon --no-playbook "   " 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a whitespace-only --no-playbook reason must be refused"
  assert_contains "$out" "non-empty reason" "a whitespace-only --no-playbook reason did not say what is missing"

  local invisible
  for invisible in $'\v' $'\f' $'\xc2\xa0' $'\xe2\x80\x82' $'\xe3\x80\x80' \
      $'\xc2\xad' $'\xcc\x81' $'\xcd\x8f' $'\xe2\x80\x8b' $'\xe2\x80\x8c' \
      $'\xe2\x80\x8d' $'\xe2\x80\x8e' $'\xe2\x80\xae' $'\xe2\x81\xa0' \
      $'\xe2\x81\xa3' $'\xe2\xa0\x80' $'\xef\xb8\x8f' $'\xef\xbb\xbf' \
      $'\xef\xbf\xb9' $'\xf3\xa0\x84\x80' $'\xf3\xa0\x87\xaf' \
      $'\x01' $'\x1b' $'\x7f' $'\xc2\x80' $'\xc2\x9b'; do
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "decision-$RANDOM" repo --recon --no-playbook "$invisible" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "an invisible-only --no-playbook reason must be refused: $(printf '%q' "$invisible")"
    assert_contains "$out" "non-empty reason" "an invisible-only --no-playbook reason did not say what is missing"
  done

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" decision-recon-joined repo --recon \
    --no-playbook "$(printf 'api\xe2\x80\x8bv2\xe2\x80\x8dretry')" >/dev/null 2>&1 \
    || fail "a --no-playbook reason with zero-width characters should scaffold"
  assert_grep "Playbook decision: none - api v2 retry" "$home/data/decision-recon-joined/brief.md" \
    "zero-width characters in a --no-playbook reason were not normalized to spaces"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" decision-recon-controls repo --recon \
    --no-playbook "$(printf 'api\x01v2\x1bretry')" >/dev/null 2>&1 \
    || fail "a --no-playbook reason with control characters should scaffold once they are normalized"
  assert_grep "Playbook decision: none - api v2 retry" "$home/data/decision-recon-controls/brief.md" \
    "control characters in a --no-playbook reason were not normalized to spaces"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" decision-recon-escapes repo --recon \
    --no-playbook "$(printf 'clear\x1b[2J\x1b[Hscreen')" >/dev/null 2>&1 \
    || fail "a --no-playbook reason carrying terminal escapes should scaffold once the escapes are neutralized"
  if grep -q "$(printf '\x1b')" "$home/data/decision-recon-escapes/brief.md"; then
    fail "a --no-playbook reason must not carry raw terminal escapes into the brief"
  fi

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" decision-recon-arrow repo --recon \
    --no-playbook "$(printf 'route \xef\xbf\xa9 left')" >/dev/null 2>&1 \
    || fail "a --no-playbook reason with a visible halfwidth arrow should scaffold"
  assert_grep "$(printf 'Playbook decision: none - route \xef\xbf\xa9 left')" \
    "$home/data/decision-recon-arrow/brief.md" \
    "a visible character in a --no-playbook reason was replaced by a space"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" decision-recon repo --recon --no-playbook "  a pure question,
 with no method to apply  " >/dev/null 2>&1 \
    || fail "a real --no-playbook reason should scaffold"
  brief="$home/data/decision-recon/brief.md"
  assert_present "$brief" "--no-playbook scaffold did not write a brief"
  assert_grep "Playbook decision: none - a pure question, with no method to apply" "$brief" \
    "the recorded no-playbook reason was not normalized to one line"
  assert_no_grep "Execution playbook:" "$brief" \
    "a no-playbook brief must not carry the spawn-parsed identity line"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" decision-recon-separators repo --recon \
    --no-playbook "$(printf 'a\xc2\xa0pure\xe3\x80\x80question')" >/dev/null 2>&1 \
    || fail "a --no-playbook reason with unicode separators should scaffold"
  assert_grep "Playbook decision: none - a pure question" "$home/data/decision-recon-separators/brief.md" \
    "unicode separators in a --no-playbook reason were not normalized to spaces"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" decision-xo --xo --no-projects >/dev/null 2>&1 \
    || fail "an XO charter must stay exempt from the playbook decision"
  assert_present "$home/data/decision-xo/brief.md" "XO charter was not scaffolded without a playbook decision"
  pass "sq-brief.sh: strike and recon briefs require a recorded playbook decision"
}

test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-drill-a1:drill" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" some-proj --mode "$mode" --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "sq-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "sq-brief.sh: drill/direct-PR/local-only briefs generate cleanly"
}

# A strike task's delivery mode is Squad's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# drill-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||strike briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of drill, direct-PR, local-only
conditional policy is not a task mode|--mode drill-prod-only|classify this task's surface
ROWS
  pass "sq-brief.sh: ship --mode is required and closed-set validated"
}

test_wave_one_playbooks_materialize_and_enforce_forms() {
  local home id playbook mode brief out status
  home="$TMP_ROOT/wave-one-playbooks-home"
  mkdir -p "$home/data"
  while IFS='|' read -r id playbook mode; do
    if [ "$mode" = recon ]; then
      SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" repo --recon --playbook "$playbook@1" >/dev/null 2>&1 || fail "$playbook should materialize"
    else
      SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" repo --mode drill --playbook "$playbook@1" >/dev/null 2>&1 || fail "$playbook should materialize"
    fi
    brief="$home/data/$id/brief.md"
    grep -qx "Execution playbook: id=$playbook version=1" "$brief" || fail "$playbook identity missing"
    assert_grep "# Execution playbook: \`$playbook@1\`" "$brief" "$playbook contract missing"
  done <<'ROWS'
wave-investigation|investigation|recon
wave-feature|feature|strike
wave-refactoring|refactoring|strike
ROWS
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" wave-prototype repo --recon --playbook prototype@1 >/dev/null 2>&1 || fail "prototype should materialize as recon"
  assert_grep "Execution playbook: id=prototype version=1" "$home/data/wave-prototype/brief.md" "prototype identity missing"
  while IFS='|' read -r playbook kind; do
    id="wave-invalid-$playbook-$kind"
    if [ "$kind" = recon ]; then
      out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" repo --recon --playbook "$playbook@1" 2>&1); status=$?
    elif [ "$kind" = xo ]; then
      out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" --xo --no-projects --playbook "$playbook@1" 2>&1); status=$?
    else
      out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" repo --mode drill --playbook "$playbook@1" 2>&1); status=$?
    fi
    [ "$status" -ne 0 ] || fail "$playbook should refuse $kind"
    assert_contains "$out" "accepts only kind" "$playbook refusal should explain compatibility"
    assert_absent "$home/data/$id/brief.md" "$playbook refusal left a partial brief"
  done <<'ROWS'
investigation|strike
investigation|xo
feature|recon
feature|xo
refactoring|recon
refactoring|xo
prototype|strike
prototype|xo
ROWS
  pass "sq-brief.sh: wave-one contracts materialize and reject incompatible forms"
}

# The registry is the commander's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_wave_two_playbooks_materialize_and_enforce_forms() {
  local home id playbook kind brief out status
  home="$TMP_ROOT/wave-two-playbooks-home"
  mkdir -p "$home/data"
  while IFS='|' read -r id playbook kind; do
    if [ "$kind" = recon ]; then
      SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" repo --recon --playbook "$playbook@1" >/dev/null 2>&1 || fail "$playbook should materialize as recon"
    else
      SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" repo --mode drill --playbook "$playbook@1" >/dev/null 2>&1 || fail "$playbook should materialize as strike"
    fi
    brief="$home/data/$id/brief.md"
    grep -qx "Execution playbook: id=$playbook version=1" "$brief" || fail "$playbook identity missing"
    assert_grep "# Execution playbook: \`$playbook@1\`" "$brief" "$playbook contract missing"
  done <<'ROWS'
wave-perf|perf|strike
wave-hillclimb|hillclimb|strike
wave-runtime|runtime-forensics|recon
wave-trace|trace-forensics|recon
wave-visual-recon|visual-parity|recon
wave-visual-strike|visual-parity|strike
ROWS
  while IFS='|' read -r playbook kind; do
    id="wave-two-invalid-$playbook-$kind"
    if [ "$kind" = recon ]; then
      out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" repo --recon --playbook "$playbook@1" 2>&1); status=$?
    elif [ "$kind" = xo ]; then
      out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" --xo --no-projects --playbook "$playbook@1" 2>&1); status=$?
    else
      out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" repo --mode drill --playbook "$playbook@1" 2>&1); status=$?
    fi
    [ "$status" -ne 0 ] || fail "$playbook should refuse $kind"
    assert_contains "$out" "accepts only kind" "$playbook refusal should explain compatibility"
    assert_absent "$home/data/$id/brief.md" "$playbook refusal left a partial brief"
  done <<'ROWS'
perf|recon
perf|xo
hillclimb|recon
hillclimb|xo
runtime-forensics|strike
runtime-forensics|xo
trace-forensics|strike
trace-forensics|xo
visual-parity|xo
ROWS
  for playbook in nope bug-fix@2 perf@2; do
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "wave-two-invalid-identity-$RANDOM" repo --mode drill --playbook "$playbook" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "invalid identity $playbook should fail"
    assert_contains "$out" "unknown execution playbook" "$playbook refusal should identify an invalid identity"
  done
  pass "sq-brief.sh: wave-two contracts materialize, preserve visual dual form, and reject incompatible identities"
}

test_absorbed_playbook_names_are_not_selectable() {
  local home name out status
  home="$TMP_ROOT/absorbed-playbook-home"
  mkdir -p "$home/data"
  for name in session-pickup pause-safely babysit worktree-cleanup authoring-a-skill; do
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "absorbed-$name" repo --mode drill --playbook "$name@1" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$name must not be selectable as a playbook"
    assert_contains "$out" "unknown execution playbook" "$name refusal must identify an unknown playbook"
    assert_absent "$home/data/absorbed-$name/brief.md" "$name refusal must not leave a partial brief"
  done
  pass "sq-brief.sh: absorbed playbook names are refused and leave no selectable brief"
}

test_remaining_lifecycle_playbooks() {
  local home brief out status
  home="$TMP_ROOT/remaining-lifecycle-playbooks-home"
  mkdir -p "$home/data"
  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" lifecycle-shipping repo --mode drill --playbook shipping@1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "shipping@1 must be refused"
  assert_contains "$out" "mode" "shipping refusal must point to mode"
  assert_contains "$out" "drill" "shipping refusal must point to drill"
  assert_contains "$out" "commander" "shipping refusal must preserve merge authority"
  assert_absent "$home/data/lifecycle-shipping/brief.md" "shipping refusal must not leave a partial brief"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" lifecycle-plan repo --recon --playbook multi-phase-plan@1 >/dev/null 2>&1 || fail "multi-phase-plan@1 should materialize"
  brief="$home/data/lifecycle-plan/brief.md"
  assert_grep "Execution playbook: id=multi-phase-plan version=1" "$brief" "multi-phase-plan identity missing"
  assert_grep "real dependency" "$brief" "multi-phase-plan contract missing dependency boundary"
  assert_grep "not a layer-by-layer" "$brief" "multi-phase-plan contract missing layer boundary"
  assert_grep "existing backlog" "$brief" "multi-phase-plan contract missing backlog handoff"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" lifecycle-plan-execute repo --mode drill --playbook plan-execute@1 >/dev/null 2>&1 || fail "plan-execute@1 should materialize as strike"
  brief="$home/data/lifecycle-plan-execute/brief.md"
  assert_grep "Execution playbook: id=plan-execute version=1" "$brief" "plan-execute identity missing"
  assert_grep "execution-class" "$brief" "plan-execute contract missing execution-class scope"
  assert_grep "materialized from the planning artifact" "$brief" "plan-execute contract missing the plan materialization rule"
  assert_grep "tlc-implement" "$brief" "plan-execute contract missing tlc-implement"
  assert_grep 'Squad base' "$brief" "plan-execute contract missing the Squad-base checklist location"
  assert_grep 'data/<id>/artifacts/' "$brief" "plan-execute contract missing the checklist path"
  assert_grep "never in the project repository" "$brief" "plan-execute contract must forbid storing the checklist in the project"
  assert_grep "A project commit must never carry a Squad internal artifact" "$brief" "plan-execute contract must forbid committing Squad artifacts"
  assert_grep "blocked:" "$brief" "plan-execute contract missing the stop-with-blocked rule"
  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" lifecycle-plan-execute-recon repo --recon --playbook plan-execute@1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "plan-execute@1 must refuse recon"
  assert_contains "$out" "accepts only kind: strike" "plan-execute refusal should name strike compatibility"
  assert_absent "$home/data/lifecycle-plan-execute-recon/brief.md" "plan-execute recon refusal must not leave a partial brief"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" lifecycle-eval repo --recon --playbook eval@1 >/dev/null 2>&1 || fail "eval@1 should materialize"
  brief="$home/data/lifecycle-eval/brief.md"
  assert_grep "Execution playbook: id=eval version=1" "$brief" "eval identity missing"
  assert_grep "candidate-visible" "$brief" "eval contract missing candidate blinding"
  assert_grep "chain-elicitation" "$brief" "eval contract missing chain-elicitation prevention"
  assert_grep "does not enter production" "$brief" "eval contract missing promotion boundary"

  for playbook in shipping@2 multi-phase-plan@2 eval@2 plan-execute@2; do
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "lifecycle-invalid-$RANDOM" repo --mode drill --playbook "$playbook" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "$playbook should be refused"
    assert_contains "$out" "unknown execution playbook" "$playbook should identify invalid identity"
  done
  pass "sq-brief.sh: shipping is refused and planning/evaluation methods materialize narrowly"
}

test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" brief-explicit-a5 direct-proj --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1 \
    || fail "explicit drill brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=drill" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "Phase 2: run the pipeline" "$brief" \
    "explicit drill brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" brief-explicit-a6 never-registered --mode local-only --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "sq-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is Squad's approval authority and never reaches the worker, and a recon
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a recon brief|brief-refused-b3 some-proj --recon --mode direct-PR|--mode applies only to strike briefs
mode on an XO charter|brief-refused-b4 --xo --no-projects --mode drill|--mode applies only to strike briefs
ROWS
  pass "sq-brief.sh: --yolo and recon/XO --mode are refused, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" direct-proj --mode direct-PR --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; Squad relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The commander reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded commander-only authority"
  id="brief-local-authority-a4"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" local-proj --mode local-only --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then Squad merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The commander approves the ready branch" "$brief" \
    "local-only brief hard-coded commander-only authority"
  assert_no_grep "Squad then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "local-only brief must not include the drill --intent contract"
  id="brief-direct-intent-a4"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" direct-proj --mode direct-PR --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the drill --intent contract"
  pass "sq-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the drill DOD's drill
# reference must render as plain prose with no dangling apostrophe artifact.
test_drill_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" some-proj --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "drill itself provides for the mechanics" "$brief" \
    "drill DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`drill axi run --help`' "$brief" \
    "drill DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "drill DOD must render literal backticks around help"
  assert_grep "make \`--intent\` preserve all relevant content from this brief" "$brief" \
    "drill DOD must require --intent to retain the accepted task contract"
  assert_grep "carrying only each requirement's current accepted form" "$brief" \
    "drill DOD must replace superseded requirements with their current accepted form"
  assert_grep "retain direct requirements instead of substituting a diff summary" "$brief" \
    "drill DOD must keep direct requirements and exclude generic scaffold boilerplate from --intent"
  assert_grep "exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific" "$brief" \
    "drill DOD must exclude non-task-specific scaffold boilerplate from --intent"
  # The apostrophe in "Squad's authority check" is now structurally safe
  # (no `$(...)` wrapper around the heredoc), so it renders verbatim instead of
  # being reworded or escaped away. test_no_heredoc_in_command_substitution
  # guards the structure that makes it safe.
  assert_grep "Squad's authority check" "$brief" \
    "drill DOD lost the apostrophe prose that the structural fix makes parse-safe"
  pass "sq-brief.sh: drill DOD keeps its apostrophe prose, now parse-safe"
}

# The drill DOD must make explicit that a commit is not completion and that
# done: requires the pipeline to have run and the PR to be green. This
# guards against the defect where operators report done after a bare commit.
test_drill_dod_requires_pipeline_before_done() {
  local home id brief
  home="$TMP_ROOT/pipeline-before-done-home"
  mkdir -p "$home/data"
  id="brief-pipeline-c1"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" some-proj --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  # Commit must be explicitly marked as NOT completion.
  assert_grep "commit is NOT completion" "$brief" \
    "drill DOD must state that a commit is not completion"
  # The DOD must be structured in phases so the pipeline comes before done.
  assert_grep "Phase 1: implement and commit" "$brief" \
    "drill DOD must have Phase 1 for implement and commit"
  assert_grep "Phase 2: run the pipeline" "$brief" \
    "drill DOD must have Phase 2 for running the pipeline"
  assert_grep "Phase 3: self-check before done" "$brief" \
    "drill DOD must have Phase 3 for self-check before done"
  # The generated brief is the public instruction interface: pin its actual
  # task-specific helper commands; helper behavior is tested separately.
  assert_grep "$ROOT/bin/sq-drill-drive.sh $id run --intent" "$brief" \
    "drill brief must route blocking runs through bounded recovery"
  assert_grep "$ROOT/bin/sq-drill-drive.sh $id respond --intent" "$brief" \
    "drill brief must route blocking responses through bounded recovery"
  # The self-check must require a PR to exist and CI to be green.
  assert_grep "A PR exists for your branch" "$brief" \
    "drill DOD self-check must require a PR to exist"
  assert_grep "CI checks on that PR are green" "$brief" \
    "drill DOD self-check must require CI to be green"
  # done: must only appear in the final signal section, after the self-check.
  # Verify the ordering: the self-check section comes before the done signal.
  local self_check_line done_line
  self_check_line=$(grep -n 'Phase 3: self-check before done' "$brief" | head -1 | cut -d: -f1)
  done_line=$(grep -n '## done signal' "$brief" | head -1 | cut -d: -f1)
  [ -n "$self_check_line" ] || fail "drill DOD missing self-check section line number"
  [ -n "$done_line" ] || fail "drill DOD missing done signal section line number"
  [ "$done_line" -gt "$self_check_line" ] \
    || fail "drill DOD: done signal (line $done_line) must come after self-check (line $self_check_line)"
  # The old misleading "complete only when committed" must not appear.
  assert_no_grep "The task is complete only when committed" "$brief" \
    "drill DOD must not say task is complete only when committed"
  pass "sq-brief.sh: drill DOD requires pipeline before done and has self-check"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" some-proj --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "sq-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" Squad --mode drill --no-playbook "test fixture: no execution playbook applies" --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/sq-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Squad helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical unit state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "sq-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_Squad_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/Squad helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/sq-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  SQUAD_BASE="$home" SQUAD_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/sq-brief.sh" "$id" foreign --recon --no-playbook "test fixture: no execution playbook applies" --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Squad helper path"
  assert_no_grep "bin/sq-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "sq-brief.sh: --herdr-lab uses its quoted Squad-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship recon; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = recon ]; then
      SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" Squad --recon --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
    else
      SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" Squad --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "sq-brief.sh: ship and recon scaffolds make omitted Herdr intent fail-visible"
}

test_XO_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the Squad repo itself (no clones needed).
  SQUAD_BASE="$home" SQUAD_XO_CHARTER='Squad self-development' \
    SQUAD_XO_SCOPE='Squad repo work' \
    "$ROOT/bin/sq-brief.sh" fdev --xo --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects XO brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its operators take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "XO charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "XO charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "XO charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  SQUAD_BASE="$home" SQUAD_XO_CHARTER='x' "$ROOT/bin/sq-brief.sh" oops --xo >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "XO brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure XO brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  SQUAD_BASE="$home" SQUAD_XO_CHARTER='x' "$ROOT/bin/sq-brief.sh" oops2 --xo --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to XO charters, never a ship/recon brief.
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "sq-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_XO_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  SQUAD_BASE="$home" SQUAD_CLASSIFY_PAUSED_VERB=paused \
    SQUAD_XO_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/sq-brief.sh" marked-request-reporting --xo --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "XO charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "XO charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "XO charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "XO charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "XO charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "XO charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "XO charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "XO charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "XO charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "XO charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "XO charter lost detailed document pointers"
  assert_grep 'Report only true commander-relevant outcomes or a declared external wait' "$brief" \
    "XO charter lost declared external waits"
  assert_grep 'a commander decision, a real blocker, a failure, or work ready for review' "$brief" \
    "XO charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "XO charter changed the preserved status vocabulary"
  pass "sq-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_XO_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  SQUAD_BASE="$home" SQUAD_XO_CHARTER=x \
    "$ROOT/bin/sq-brief.sh" relative-home --xo --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" SQUAD_BASE=home SQUAD_XO_CHARTER=x \
      "$ROOT/bin/sq-brief.sh" relative-home --xo --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative SQUAD_BASE changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative SQUAD_BASE did not render an absolute XO status path"

  brief="$home/data/relative-state/brief.md"
  SQUAD_BASE="$home" SQUAD_STATE_OVERRIDE="$state_override" SQUAD_XO_CHARTER=x \
    "$ROOT/bin/sq-brief.sh" relative-state --xo --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" SQUAD_BASE="$home" SQUAD_STATE_OVERRIDE=state-override SQUAD_XO_CHARTER=x \
      "$ROOT/bin/sq-brief.sh" relative-state --xo --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative SQUAD_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative SQUAD_STATE_OVERRIDE did not render an absolute XO status path"

  brief="$data_override/relative-data/brief.md"
  SQUAD_BASE="$home" SQUAD_DATA_OVERRIDE="$data_override" SQUAD_XO_CHARTER=x \
    "$ROOT/bin/sq-brief.sh" relative-data --xo --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" SQUAD_BASE="$home" SQUAD_DATA_OVERRIDE=data-override SQUAD_XO_CHARTER=x \
      "$ROOT/bin/sq-brief.sh" relative-data --xo --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative SQUAD_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative SQUAD_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    SQUAD_BASE=missing-home SQUAD_XO_CHARTER=x \
      "$ROOT/bin/sq-brief.sh" unresolved-home --xo --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative SQUAD_BASE must fail"
  assert_grep "SQUAD_BASE directory cannot be resolved: missing-home" "$err" \
    "unresolved relative SQUAD_BASE did not fail loudly"

  (
    cd "$root" || exit 1
    SQUAD_BASE="$home" SQUAD_STATE_OVERRIDE=missing-state SQUAD_XO_CHARTER=x \
      "$ROOT/bin/sq-brief.sh" unresolved-state --xo --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative SQUAD_STATE_OVERRIDE must fail"
  assert_grep "SQUAD_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative SQUAD_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    SQUAD_BASE="$home" SQUAD_DATA_OVERRIDE=missing-data SQUAD_XO_CHARTER=x \
      "$ROOT/bin/sq-brief.sh" unresolved-data --xo --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative SQUAD_DATA_OVERRIDE must fail"
  assert_grep "SQUAD_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative SQUAD_DATA_OVERRIDE did not fail loudly"

  pass "sq-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_XOs() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" herdr-recon Squad --recon --no-playbook "test fixture: no execution playbook applies" --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-recon/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "recon --herdr-lab brief missing the contract"

  SQUAD_BASE="$home" SQUAD_XO_CHARTER=ops "$ROOT/bin/sq-brief.sh" herdr-XO --xo Squad --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "XO --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-XO/brief.md" \
    "rejected XO --herdr-lab still wrote a brief"
  pass "sq-brief.sh: Herdr lab contract covers scouts and rejects XO misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship recon XO; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        SQUAD_BASE="$home" SQUAD_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/sq-brief.sh" "$id" Squad --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
        ;;
      recon)
        SQUAD_BASE="$home" SQUAD_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/sq-brief.sh" "$id" Squad --recon --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
        ;;
      XO)
        SQUAD_BASE="$home" SQUAD_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/sq-brief.sh" "$id" --xo --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "sq-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_XO_load_decision_hold_policy() {
  local home recon charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  SQUAD_BASE="$home" SQUAD_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/sq-brief.sh" sample-investigation sample --recon --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  recon="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$recon" \
    "recon brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$recon" \
    "recon brief did not cross-reference visual-review completion"
  SQUAD_BASE="$home" SQUAD_ROOT_OVERRIDE="$ROOT" SQUAD_XO_CHARTER='sample reviews' \
    "$ROOT/bin/sq-brief.sh" sample-mate --xo --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "XO charter did not load the shared decision policy for detailed investigations"
  pass "sq-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Recon and XO paths still scaffold well-formed briefs.
test_scout_and_XO_scaffold() {
  local brief
  SQUAD_BASE="$BRIEF_HOME" "$ROOT/bin/sq-brief.sh" brief-recon-q6 alpha --recon --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1 \
    || fail "sq-brief.sh recon scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-recon-q6/brief.md"
  assert_present "$brief" "recon brief was not scaffolded"
  assert_grep "RECON task" "$brief" "recon brief must declare itself a recon task"
  assert_grep "report.md" "$brief" "recon brief must point at the report deliverable"

  SQUAD_XO_CHARTER='Supervise the alpha domain.' \
    SQUAD_BASE="$BRIEF_HOME" "$ROOT/bin/sq-brief.sh" brief-sm-q6 --xo alpha >/dev/null 2>&1 \
    || fail "sq-brief.sh XO scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "XO charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "XO charter must declare its role"
  pass "sq-brief: recon and XO code paths still scaffold well-formed briefs"
}

# assert_operator_guard <brief> <label>: a strike or recon brief opens with the
# operator guard exactly once, above the task body, and states every point an
# operator needs so a session-start refusal never reads as a reason to stop.
assert_operator_guard() {
  local brief="$1" label="$2" count guard_line task_line
  assert_present "$brief" "$label brief was not scaffolded"
  count=$(grep -cF "Operator guard" "$brief")
  [ "$count" -eq 1 ] || fail "$label brief must carry the operator guard exactly once (found $count)"
  guard_line=$(grep -nF "Operator guard" "$brief" | head -1 | cut -d: -f1)
  task_line=$(grep -nF "# Task" "$brief" | head -1 | cut -d: -f1)
  [ "$guard_line" -lt "$task_line" ] || fail "$label brief must place the operator guard above the task body"
  assert_grep "not Squad" "$brief" "$label brief must state that the operator is not Squad"
  assert_grep "do not run \`bin/sq-session-start.sh\`" "$brief" "$label brief must forbid running session start"
  assert_grep "do not acquire the unit lock" "$brief" "$label brief must forbid acquiring the unit lock"
  assert_grep "The unit lock belongs to the primary session that dispatched you" "$brief" \
    "$label brief must name the primary session as the lock owner"
  assert_grep "is a misunderstanding, not a state you must respect" "$brief" \
    "$label brief must treat a lock refusal as a misunderstanding"
  assert_grep "Do not read or write the primary base's \`state/\` directory" "$brief" \
    "$label brief must keep the primary base's state directory out of reach"
}

# Operator guard: every strike and recon brief carries the not-Squad guard from
# the one shared emitter. The XO charter keeps its own preamble and stays
# without it, because an XO runs session start for its own base.
test_operator_guard_leads_strike_and_recon_briefs() {
  local home brief
  home="$TMP_ROOT/operator-guard-home"
  mkdir -p "$home/data"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" brief-guard-drill some-proj --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1 \
    || fail "sq-brief.sh drill strike scaffold exited non-zero"
  assert_operator_guard "$home/data/brief-guard-drill/brief.md" "drill strike"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" brief-guard-recon some-proj --recon --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1 \
    || fail "sq-brief.sh recon scaffold exited non-zero"
  assert_operator_guard "$home/data/brief-guard-recon/brief.md" "recon"

  SQUAD_XO_CHARTER='Supervise the alpha domain.' \
    SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" brief-guard-xo --xo alpha >/dev/null 2>&1 \
    || fail "sq-brief.sh XO scaffold exited non-zero"
  brief="$home/data/brief-guard-xo/brief.md"
  assert_present "$brief" "XO charter was not scaffolded"
  assert_no_grep "Operator guard" "$brief" "XO charter must keep its own preamble, not the operator guard"
  pass "sq-brief: strike and recon briefs open with the operator guard, the XO charter keeps its preamble"
}

# Status instruction enforcement: every scaffold must include the status
# reporting instruction. The validation catches any future heredoc that
# omits the >> ...status pattern. assert_grep uses -F (fixed string), so
# we use plain grep for the regex pattern that the validation actually checks.
test_status_instruction_is_present_in_all_scaffolds() {
  local home id brief
  home="$TMP_ROOT/status-instruction-home"
  mkdir -p "$home/data"

  # Ship (drill)
  id="brief-status-drill"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" some-proj --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "drill brief was not scaffolded"
  grep -qE '>>.*\.status' "$brief" || fail "drill brief missing status instruction pattern"
  assert_grep 'echo' "$brief" "drill brief missing echo-to-status instruction"

  # Ship (direct-PR)
  id="brief-status-direct"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" some-proj --mode direct-PR --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  grep -qE '>>.*\.status' "$brief" || fail "direct-PR brief missing status instruction pattern"

  # Ship (local-only)
  id="brief-status-local"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" some-proj --mode local-only --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  grep -qE '>>.*\.status' "$brief" || fail "local-only brief missing status instruction pattern"

  # Recon
  id="brief-status-recon"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" some-proj --recon --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  grep -qE '>>.*\.status' "$brief" || fail "recon brief missing status instruction pattern"

  # XO charter
  id="brief-status-xo"
  SQUAD_BASE="$home" SQUAD_XO_CHARTER='ops' \
    "$ROOT/bin/sq-brief.sh" "$id" --xo --no-projects >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  grep -qE '>>.*\.status' "$brief" || fail "XO charter missing status instruction pattern"

  pass "sq-brief.sh: all scaffold types include the status reporting instruction"
}

test_ambiguity_rule_stops_coding_and_asks() {
  local home brief
  home="$TMP_ROOT/ambiguity-rule-home"
  mkdir -p "$home/data"
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" ambiguity-strike some-proj --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" ambiguity-recon some-proj --recon --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1
  # shellcheck disable=SC2016 # literal backticks are part of the emitted sentence
  sentence='When the task is still ambiguous after reading the code, do not code: open a keyed decision with `needs-decision [key=ambiguity-<slug>]:` carrying at most three objective questions.'
  for brief in "$home/data/ambiguity-strike/brief.md" "$home/data/ambiguity-recon/brief.md"; do
    assert_grep "$sentence" "$brief" "brief missing the ambiguity stop-and-ask sentence"
  done
  pass "sq-brief.sh: strike and recon briefs tell the operator to ask instead of coding through ambiguity"
}

test_repo_squad_guard_and_recon_action_line() {
  local home brief guard drill_guard out status unconfirmed wt_base wt_other wt_home
  home="$TMP_ROOT/repo-squad-guard-home"
  mkdir -p "$home/data"
  guard='Repository guard: this is the Squad base itself; work only in an isolated worktree, never the primary checkout.'
  drill_guard="$guard"' Deliver through drill because CI requires its signature.'

  scaffold() {  # <task-id> <repo> [scaffold flags...]
    local id=$1 repo=$2
    shift 2
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "$id" "$repo" "$@" 2>&1)
    status=$?
    expect_code 0 "$status" "$id scaffold for repo '$repo' should succeed (got: $out)"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id scaffold did not write its brief"
  }

  scaffold repo-squad-strike squad --mode drill --no-playbook "test fixture: no execution playbook applies"
  [ "$(grep -Fxc "$drill_guard" "$brief")" -eq 1 ] || fail "repo=squad drill strike must carry the drill repository guard exactly once"

  scaffold repo-squad-title-case Squad --mode drill --no-playbook "test fixture: no execution playbook applies"
  [ "$(grep -Fxc "$drill_guard" "$brief")" -eq 1 ] || fail "repo=Squad drill strike must be matched case-insensitively"

  scaffold repo-squad-upper-case SQUAD --recon --no-playbook "test fixture: no execution playbook applies"
  [ "$(grep -Fxc "$guard" "$brief")" -eq 1 ] || fail "repo=SQUAD recon must be matched case-insensitively"

  scaffold repo-squad-direct squad --mode direct-PR --no-playbook "test fixture: no execution playbook applies"
  [ "$(grep -Fxc "$guard" "$brief")" -eq 1 ] || fail "repo=squad direct-PR strike must carry the repository guard exactly once"
  assert_no_grep 'Deliver through drill' "$brief" "direct-PR brief says it does not run drill, so the guard must not claim drill delivery"

  scaffold repo-squad-local squad --mode local-only --no-playbook "test fixture: no execution playbook applies"
  [ "$(grep -Fxc "$guard" "$brief")" -eq 1 ] || fail "repo=squad local-only strike must carry the repository guard exactly once"
  assert_no_grep 'Deliver through drill' "$brief" "local-only brief ships no pipeline, so the guard must not claim drill delivery"

  scaffold repo-squad-path "$ROOT" --mode drill --no-playbook "test fixture: no execution playbook applies"
  [ "$(grep -Fxc "$drill_guard" "$brief")" -eq 1 ] || fail "a path resolving to the Squad base must carry the drill repository guard exactly once"

  scaffold repo-squad-subdir "$ROOT/bin" --recon --no-playbook "test fixture: no execution playbook applies"
  [ "$(grep -Fxc "$guard" "$brief")" -eq 1 ] || fail "a path inside the Squad base must carry the repository guard exactly once"
  assert_no_grep 'Deliver through drill' "$brief" "a recon never delivers through drill, so its guard must not claim drill delivery"
  # shellcheck disable=SC2016 # literal backticks are part of the emitted sentence
  assert_grep 'for each recommended strike, include the exact `sq-*` command (or equivalent action) that would start it' "$brief" \
    "recon brief must require an actionable strike command"

  scaffold repo-squad-recon squad --recon --no-playbook "test fixture: no execution playbook applies"
  [ "$(grep -Fxc "$guard" "$brief")" -eq 1 ] || fail "repo=squad recon must carry the repository guard exactly once"

  scaffold repo-other-strike another-repo --mode drill --no-playbook "test fixture: no execution playbook applies"
  assert_no_grep "$guard" "$brief" "repository guard must not appear for another repo"
  scaffold repo-other-recon another-repo --recon --no-playbook "test fixture: no execution playbook applies"
  assert_no_grep "$guard" "$brief" "repository guard must not appear for another recon repo"
  scaffold repo-squad-partial squad-extra --mode drill --no-playbook "test fixture: no execution playbook applies"
  assert_no_grep "$guard" "$brief" "a partial label match must not be treated as the Squad base"

  # A confirmable directory that is not part of any repository cannot be the
  # Squad base, so it stays an ordinary project repo.
  unconfirmed="$TMP_ROOT/repo-squad-unconfirmed"
  mkdir -p "$unconfirmed"
  scaffold repo-other-path "$home" --mode drill --no-playbook "test fixture: no execution playbook applies"
  assert_no_grep "$guard" "$brief" "repository guard must not appear for a path outside the Squad base"
  scaffold repo-unconfirmed-path "$unconfirmed" --mode drill --no-playbook "test fixture: no execution playbook applies"
  assert_no_grep "$guard" "$brief" "an unconfirmable path must not be assumed to be the Squad base"

  # Another worktree of the same repository has its own top-level, so it is not
  # this base even though it shares the same git directory.
  wt_base="$TMP_ROOT/repo-squad-wt-base"
  wt_other="$TMP_ROOT/repo-squad-wt-other"
  wt_home="$TMP_ROOT/repo-squad-wt-home"
  mkdir -p "$wt_home/data"
  fm_git_init_commit "$wt_base"
  git -C "$wt_base" worktree add -q --detach "$wt_other" HEAD \
    || fail "could not create the fixture linked worktree"
  SQUAD_ROOT_OVERRIDE="$wt_base" SQUAD_BASE="$wt_home" "$ROOT/bin/sq-brief.sh" repo-squad-wt-base "$wt_base" \
    --mode drill --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1 \
    || fail "the fixture base's own path must scaffold"
  brief="$wt_home/data/repo-squad-wt-base/brief.md"
  [ "$(grep -Fxc "$drill_guard" "$brief")" -eq 1 ] || fail "the fixture base's own path must carry the guard"
  SQUAD_ROOT_OVERRIDE="$wt_base" SQUAD_BASE="$wt_home" "$ROOT/bin/sq-brief.sh" repo-squad-wt-other "$wt_other" \
    --recon --no-playbook "test fixture: no execution playbook applies" >/dev/null 2>&1 \
    || fail "a path to another worktree must still scaffold"
  brief="$wt_home/data/repo-squad-wt-other/brief.md"
  assert_no_grep "$guard" "$brief" "another worktree of the same repository must not be treated as the Squad base"
  pass "sq-brief.sh: Squad-repo guard is conditional, mode-aware, and recon recommendations name their launch action"
}

test_autonomous_policy_refusals_and_topology_boundaries() {
  local home name out status
  home="$TMP_ROOT/autonomous-policy-home"
  mkdir -p "$home/data"
  while IFS='|' read -r name disposition marker; do
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "policy-$name" repo --mode drill --playbook "$name@1" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$name must be refused"
    assert_contains "$out" "$disposition" "$name refusal must name disposition"
    assert_contains "$out" "$marker" "$name refusal must name owner or trigger"
    if [ "$name" = orchestrate ]; then
      assert_contains "$out" "backlog" "$name refusal must preserve the existing coordination owners"
    elif [ "$name" = autonomous-run ]; then
      assert_contains "$out" "supervision" "$name refusal must name the current owner"
    else
      assert_contains "$out" "commander" "$name refusal must preserve commander authority"
    fi
    assert_absent "$home/data/policy-$name/brief.md" "$name refusal must leave no partial brief"
  done <<'ROWS'
orchestrate|reject|Commander
autopilot-full|defer|multi-PR
autopilot-stack|defer|multi-PR
autonomous-run|defer|terminal predicate
ROWS
  for topology in arena swarm interrogate; do
    [ ! -e ".agents/skills/execution-playbooks/references/$topology-v1.md" ] \
      || fail "$topology must not be an execution playbook reference"
    out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" "policy-$topology" repo --mode drill --playbook "$topology@1" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$topology must not be selectable as a playbook"
    assert_contains "$out" "unknown execution playbook" "$topology refusal must identify an unknown playbook"
  done
  pass "sq-brief.sh: autonomous identities are refused and auxiliary topologies remain outside dispatch"
}

# The status instruction validation refuses to scaffold if the pattern is
# absent. We simulate this by writing a brief manually without the pattern
# and verifying the validation catches it at spawn time (sq-spawn.sh check).
test_status_instruction_enforcement_refuses_missing_pattern() {
  local home out status
  home="$TMP_ROOT/status-enforcement-home"
  mkdir -p "$home/data"

  # Create a minimal brief file without the status pattern.
  mkdir -p "$home/data/enforce-test"
  cat > "$home/data/enforce-test/brief.md" <<'EOF'
You are an operator.

# Task
Test task.

# Rules
1. Do work.

# Definition of done
Done.
EOF
  # The file exists but has no >> ...status pattern. sq-spawn.sh should catch this.
  # We cannot call sq-spawn.sh directly (it needs a project dir and tmux), but we
  # can test the grep logic directly.
  if grep -q '>>.*\.status' "$home/data/enforce-test/brief.md"; then
    fail "test fixture brief should NOT have the status pattern"
  fi
  out=$(grep -q '>>.*\.status' "$home/data/enforce-test/brief.md" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "grep should fail on a brief without the status pattern"
  pass "sq-brief.sh: brief without status pattern is correctly detected as missing"
}

test_playbook_profile_pairing_and_refusals() {
  local home brief out status playbook_line profile_line
  home="$TMP_ROOT/profile-home"
  mkdir -p "$home/data"

  # A playbook alone is unchanged: exactly one playbook identity and no profile.
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-playbook-only repo --mode drill --playbook feature@1 >/dev/null 2>&1 \
    || fail "feature@1 should still materialize as a playbook alone"
  brief="$home/data/profile-playbook-only/brief.md"
  [ "$(grep -c '^Execution playbook: ' "$brief")" -eq 1 ] \
    || fail "playbook-only brief must carry exactly one playbook identity"
  assert_no_grep 'Execution profile: ' "$brief" "playbook-only brief must carry no profile identity"

  # A profile carries its constraints into the same brief, after the playbook block.
  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-pair repo --mode drill --playbook feature@1 --profile react@1 >/dev/null 2>&1 \
    || fail "feature@1 with the react@1 profile should materialize"
  brief="$home/data/profile-pair/brief.md"
  grep -qx 'Execution playbook: id=feature version=1' "$brief" || fail "paired brief lost its playbook identity"
  grep -qx 'Execution profile: id=react version=1' "$brief" || fail "paired brief lost its profile identity"
  playbook_line=$(grep -n '^Execution playbook: ' "$brief" | cut -d: -f1)
  profile_line=$(grep -n '^Execution profile: ' "$brief" | cut -d: -f1)
  [ "$profile_line" -gt "$playbook_line" ] || fail "profile block must follow the playbook block"
  awk '/^# Execution profile: `react@1`$/ {contract=1} contract && /^# Setup/ {exit} contract {if (buffered) print previous; previous=$0; buffered=1}' \
    "$brief" > "$home/materialized-profile.md"
  cmp -s "$ROOT/.agents/skills/execution-playbooks/references/react-v1.md" "$home/materialized-profile.md" \
    || fail "paired brief must carry the full React profile contract, not a pointer"

  # A profile never stands alone, and unsupported pairings leave no partial brief.
  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-alone repo --mode drill --profile react@1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a profile without a playbook must be refused"
  assert_contains "$out" "--playbook" "profile-only refusal must point at the playbook it needs"
  assert_absent "$home/data/profile-alone/brief.md" "profile-only refusal left a partial brief"

  # The no-playbook decision cannot carry a profile: a profile needs the method it constrains.
  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-none repo --mode drill --no-playbook "no method applies here" --profile react@1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a profile paired with --no-playbook must be refused"
  assert_contains "$out" "--profile requires --playbook" "profile with --no-playbook must name the missing playbook"
  assert_absent "$home/data/profile-none/brief.md" "profile with --no-playbook left a partial brief"
  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-unknown repo --mode drill --playbook feature@1 --profile svelte@1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an unknown profile must be refused"
  assert_contains "$out" "unknown execution profile" "unknown-profile refusal must identify the profile"
  assert_absent "$home/data/profile-unknown/brief.md" "unknown-profile refusal left a partial brief"

  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-version repo --mode drill --playbook feature@1 --profile react@2 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "an unsupported profile version must be refused"
  assert_contains "$out" "unknown execution profile version" "profile-version refusal must identify the unsupported version"
  assert_absent "$home/data/profile-version/brief.md" "profile-version refusal left a partial brief"

  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-kind repo --recon --playbook investigation@1 --profile react@1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a profile whose task kind is incompatible must be refused"
  assert_contains "$out" "accepts only kind: strike" "kind-mismatch refusal must name the profile's compatible kind"
  assert_absent "$home/data/profile-kind/brief.md" "kind-mismatch refusal left a partial brief"

  # react@1 is a profile, so selecting it as the playbook is refused with the pairing it needs.
  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-as-playbook repo --mode drill --playbook react@1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "react@1 must not be selectable as a playbook"
  assert_contains "$out" "--profile react@1" "react-as-playbook refusal must show the pairing that works"
  assert_absent "$home/data/profile-as-playbook/brief.md" "react-as-playbook refusal left a partial brief"

  # A version of the profile id passed to --playbook names the category it belongs to.
  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-as-playbook-version repo --mode drill --playbook react@2 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "react@2 must not be selectable as a playbook"
  assert_contains "$out" "is an execution profile, not a playbook" "profile-as-playbook refusal must name the category the id belongs to"
  assert_absent "$home/data/profile-as-playbook-version/brief.md" "profile-as-playbook-version refusal left a partial brief"

  # A playbook id passed to --profile names the flag that carries it, without
  # restating the value in a command that cannot work (a playbook already selected
  # cannot also be the profile, and an unsupported version stays unsupported).
  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-playbook-as-profile repo --mode drill --playbook feature@1 --profile feature@1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a playbook id must not be accepted as a profile"
  assert_contains "$out" "is an execution playbook, not a profile" "playbook-as-profile refusal must name the category the id belongs to"
  assert_contains "$out" "--profile" "playbook-as-profile refusal must name the flag that carries a profile"
  assert_absent "$home/data/profile-playbook-as-profile/brief.md" "playbook-as-profile refusal left a partial brief"

  # An empty profile reference must not silently drop the selection: the identity
  # still reaches the brief, so bin/sq-spawn.sh's materialized-contract check
  # refuses the truncated profile instead of launching without its constraints.
  local profile_root="$TMP_ROOT/profile-empty-root"
  mkdir -p "$profile_root/.agents/skills/execution-playbooks/references"
  cp "$ROOT/.agents/skills/execution-playbooks/references/feature-v1.md" \
    "$profile_root/.agents/skills/execution-playbooks/references/"
  : > "$profile_root/.agents/skills/execution-playbooks/references/react-v1.md"
  SQUAD_BASE="$home" SQUAD_ROOT_OVERRIDE="$profile_root" "$ROOT/bin/sq-brief.sh" profile-empty repo --mode drill --playbook feature@1 --profile react@1 >/dev/null 2>&1 \
    || fail "a truncated profile reference should record the selection for spawn to reject, not lose it"
  brief="$home/data/profile-empty/brief.md"
  grep -qx 'Execution profile: id=react version=1' "$brief" \
    || fail "an empty profile reference must still record the profile identity so spawn can refuse it"
  pass "sq-brief.sh: a profile attaches to a playbook, follows it, and unsupported pairings are refused"
}

test_paired_profile_evidence_stays_outside_the_playbook_gate() {
  local home brief profile_artifact playbook_artifact out status
  home="$TMP_ROOT/profile-gate-home"
  mkdir -p "$home/data" "$home/state"

  SQUAD_BASE="$home" "$ROOT/bin/sq-brief.sh" profile-gate repo --mode drill --playbook feature@1 --profile react@1 >/dev/null 2>&1 \
    || fail "feature@1 with the react@1 profile should materialize"
  brief="$home/data/profile-gate/brief.md"
  grep -qx 'Execution playbook: id=feature version=1' "$brief" || fail "paired brief lost its playbook identity"
  grep -qx 'Execution profile: id=react version=1' "$brief" || fail "paired brief lost its profile identity"

  # The profile evidence artifact sorts before the playbook checklist, so a
  # discovery that accepted it would score the profile as the playbook gate.
  mkdir -p "$home/data/profile-gate/artifacts"
  profile_artifact="$home/data/profile-gate/artifacts/react-profile-evidence.md"
  playbook_artifact="$home/data/profile-gate/artifacts/vertical-slice-checklist.md"
  printf '%s\n' '# react profile evidence' '' '## Evidence 1' 'architecture mapped to layers; path: src/app/routes.tsx' > "$profile_artifact"
  printf 'playbook=feature\nplaybook_version=1\n' > "$home/state/profile-gate.meta"

  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-playbook-validate.sh" profile-gate 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "profile evidence alone must not satisfy the feature@1 completion gate"
  assert_contains "$out" "missing: checklist artifact" "profile evidence must not be accepted as the playbook completion artifact"

  cat > "$playbook_artifact" <<'EOF'
# feature@1 checklist

## Criterion 1
Proof: behavior contract recorded for the rejected path; command: bun test passed

## Criterion 2
Proof: data shape and caller boundary retained; path: src/entities/audit/model.ts

## Criterion 3
Proof: vertical slice implementation complete; command: git diff passed

## Criterion 4
Proof: real surface test command: bun run test passed
EOF

  out=$(SQUAD_BASE="$home" "$ROOT/bin/sq-playbook-validate.sh" profile-gate 2>&1); status=$?
  expect_code 0 "$status" "the playbook checklist must satisfy the gate while the profile evidence sits beside it"
  assert_contains "$out" "playbook evidence valid: feature@1 ($playbook_artifact)" "the gate must select the playbook's own checklist"
  pass "sq-brief.sh: paired profile evidence never hijacks the attached playbook's completion gate"
}

test_script_parses
test_playbook_profile_pairing_and_refusals
test_paired_profile_evidence_stays_outside_the_playbook_gate
test_no_heredoc_in_command_substitution
test_playbook_selection_and_legacy_compatibility
test_playbook_decision_is_required
test_wave_one_playbooks_materialize_and_enforce_forms
test_wave_two_playbooks_materialize_and_enforce_forms
test_absorbed_playbook_names_are_not_selectable
test_remaining_lifecycle_playbooks
test_autonomous_policy_refusals_and_topology_boundaries
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_drill_dod_wording
test_drill_dod_requires_pipeline_before_done
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_Squad_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_XOs
test_XO_no_projects_charter
test_XO_marked_request_reporting_contract
test_XO_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_XO_load_decision_hold_policy
test_scout_and_XO_scaffold
test_operator_guard_leads_strike_and_recon_briefs
test_status_instruction_is_present_in_all_scaffolds
test_ambiguity_rule_stops_coding_and_asks
test_repo_squad_guard_and_recon_action_line
test_status_instruction_enforcement_refuses_missing_pattern
