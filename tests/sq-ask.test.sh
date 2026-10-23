#!/usr/bin/env bash
# Tests for bin/sq-ask.sh - decision prose renderer, prose parser, answer parser,
# card validator, and the opt-in terminal picker.
#
# The prose block is the only shape the commander reads or types (AGENTS.md
# section 9); the JSON card is the internal payload. These tests drive the real
# executable and compare against golden prose in tests/fixtures/decision-prose/.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASK="$ROOT/bin/sq-ask.sh"
FIX="$ROOT/tests/fixtures/decision-prose"
TMP_ROOT=$(fm_test_tmproot sq-ask)

# jget <python-expr-over-d>: read JSON on stdin, print the expression.
jget() {
  python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1])))' "$1"
}

# ask_answer <cards-json> <answer> [extra args]: sets A_OUT, A_ERR, A_RC.
ask_answer() {
  local cards=$1 answer=$2; shift 2
  A_OUT=$(printf '%s' "$cards" | "$ASK" "--answer=$answer" "$@" 2>"$TMP_ROOT/err"); A_RC=$?
  A_ERR=$(cat "$TMP_ROOT/err")
}

MERGE=$(cat "$FIX/merge.json")
SCOPE=$(cat "$FIX/scope.json")
GATE=$(cat "$FIX/gate.json")
BOTH="[$MERGE,$SCOPE]"

VALID_CARD='{
  "version": 1,
  "id": "merge-strategy",
  "title": "Merge Strategy",
  "question": "How should we merge this PR?",
  "context": "The PR has 3 commits. CI is green.",
  "options": [
    {"id": "squash", "label": "Squash & Merge", "description": "Combine into one commit", "recommended": true},
    {"id": "rebase", "label": "Rebase & Merge", "description": "Preserve individual commits"},
    {"id": "merge", "label": "Create Merge Commit", "description": "Standard merge commit"}
  ],
  "default_option_id": "squash",
  "allow_free_text": true,
  "expires_at": null,
  "metadata": {"task_id": "test-task", "key": "merge-strategy", "source": "ask-user"}
}'

MINIMAL_CARD='{
  "version": 1,
  "id": "test-minimal",
  "title": "Simple Choice",
  "question": "Pick one?",
  "options": [
    {"id": "a", "label": "Option A"},
    {"id": "b", "label": "Option B"}
  ],
  "default_option_id": "a"
}'

NO_FREE_TEXT_CARD='{
  "version": 1,
  "id": "test-no-free",
  "title": "Fixed Choice",
  "question": "Must pick from options",
  "options": [
    {"id": "x", "label": "Option X"},
    {"id": "y", "label": "Option Y"}
  ],
  "default_option_id": "x",
  "allow_free_text": false
}'

# --- validation (existing rules plus T8) ---
assert_valid() {
  local desc=$1 json=$2
  printf '%s' "$json" | "$ASK" --validate >/dev/null 2>&1 || fail "$desc (expected valid)"
  pass "$desc"
}

assert_invalid() {
  local desc=$1 json=$2
  if printf '%s' "$json" | "$ASK" --validate >/dev/null 2>&1; then
    fail "$desc (expected invalid)"
  fi
  pass "$desc"
}

# card_with <jq-ish python statement over c> : mutate MERGE with python, print JSON.
card_with() {
  printf '%s' "$MERGE" | python3 -c 'import sys,json; c=json.load(sys.stdin); exec(sys.argv[1]); print(json.dumps(c))' "$1"
}

test_validation() {
  assert_valid "full valid card" "$VALID_CARD"
  assert_valid "minimal valid card" "$MINIMAL_CARD"
  assert_valid "no free text card" "$NO_FREE_TEXT_CARD"
  assert_valid "array of cards" "$BOTH"
  assert_valid "gate card with payload and findings" "$GATE"

  assert_invalid "missing version" '{"id":"x","title":"T","question":"Q","options":[{"id":"a","label":"A"}],"default_option_id":"a"}'
  assert_invalid "wrong version" '{"version":2,"id":"x","title":"T","question":"Q","options":[{"id":"a","label":"A"}],"default_option_id":"a"}'
  assert_invalid "missing id" '{"version":1,"title":"T","question":"Q","options":[{"id":"a","label":"A"}],"default_option_id":"a"}'
  assert_invalid "missing title" '{"version":1,"id":"x","question":"Q","options":[{"id":"a","label":"A"}],"default_option_id":"a"}'
  assert_invalid "missing question" '{"version":1,"id":"x","title":"T","options":[{"id":"a","label":"A"}],"default_option_id":"a"}'
  assert_invalid "missing options" '{"version":1,"id":"x","title":"T","question":"Q","default_option_id":"a"}'
  assert_invalid "empty options" '{"version":1,"id":"x","title":"T","question":"Q","options":[],"default_option_id":"a"}'
  assert_invalid "default not in options" '{"version":1,"id":"x","title":"T","question":"Q","options":[{"id":"a","label":"A"}],"default_option_id":"b"}'
  assert_invalid "duplicate option ids" '{"version":1,"id":"x","title":"T","question":"Q","options":[{"id":"a","label":"A"},{"id":"a","label":"B"}],"default_option_id":"a"}'
  assert_invalid "empty option label" '{"version":1,"id":"x","title":"T","question":"Q","options":[{"id":"a","label":""}],"default_option_id":"a"}'
  assert_invalid "not JSON" 'not json at all'
  assert_invalid "empty array" '[]'

  # T8: each new rule has one failing card.
  assert_invalid "key longer than 64 characters" "$(card_with "c['metadata']['key']='k'*65; c['id']='k'*65")"
  assert_invalid "key 'default' is reserved" "$(card_with "c['metadata']['key']='default'; c['id']='default'")"
  assert_invalid "key outside the sq-send charset" "$(card_with "c['metadata']['key']='bad key'; c['id']='bad key'")"
  assert_invalid "id must equal key when keyed" "$(card_with "c['id']='other-id'")"
  assert_invalid "recommended on a non-default option" "$(card_with "c['options'][1]['recommended']=True")"
  assert_invalid "title over 60 characters" "$(card_with "c['title']='t'*61")"
  assert_invalid "label over 60 characters" "$(card_with "c['options'][0]['label']='l'*61")"
  assert_invalid "description over 120 characters" "$(card_with "c['options'][0]['description']='d'*121")"
  assert_invalid "question over 160 characters" "$(card_with "c['question']='q'*161")"
  assert_invalid "context over 240 characters" "$(card_with "c['context']='c'*241")"
  assert_invalid "label with a pipe" "$(card_with "c['options'][1]['label']='A|B'")"
  assert_invalid "label with a colon and space" "$(card_with "c['options'][1]['label']='Fix: now'")"
  assert_invalid "label with a key marker" "$(card_with "c['options'][1]['label']='x [key=a]'")"
  assert_invalid "label with a verb pattern" "$(card_with "c['options'][1]['label']='done:ok'")"
  assert_invalid "label ending in the recommended marker" "$(card_with "c['options'][1]['label']='Rebase (recommended)'")"
  assert_invalid "newline in a description" "$(card_with "c['options'][0]['description']='a\nb'")"
  assert_invalid "non-ASCII label" "$(card_with "c['options'][1]['label']='Café'")"
  assert_invalid "zero-width character in the title" "$(card_with "c['title']='a​b'")"
  assert_invalid "option id outside the charset" "$(card_with "c['options'][1]['id']='bad id'")"
  assert_invalid "duplicate card ids in an array" "[$MERGE,$MERGE]"
  assert_invalid "payload action outside approve/fix/skip" "$(printf '%s' "$GATE" | python3 -c 'import sys,json; c=json.load(sys.stdin); c["options"][0]["payload"]["action"]="delete"; print(json.dumps(c))')"
  assert_invalid "payload finding id not in findings" "$(printf '%s' "$GATE" | python3 -c 'import sys,json; c=json.load(sys.stdin); c["options"][0]["payload"]["findings"]=["review-9"]; print(json.dumps(c))')"
  assert_invalid "payload step outside the charset" "$(printf '%s' "$GATE" | python3 -c 'import sys,json; c=json.load(sys.stdin); c["options"][0]["payload"]["step"]="a b"; print(json.dumps(c))')"
  assert_invalid "control character in a payload string" "$(printf '%s' "$GATE" | python3 -c 'import sys,json; c=json.load(sys.stdin); c["options"][1]["payload"]["step"]="x"; c["options"][1]["payload"]["note"]="a\x1bb"; print(json.dumps(c))')"
  assert_invalid "payload findings without a findings array" "$(printf '%s' "$GATE" | python3 -c 'import sys,json; c=json.load(sys.stdin); del c["findings"]; print(json.dumps(c))')"

  local rc
  printf '%s' "$(printf '%s' "$GATE" | python3 -c 'import sys,json; c=json.load(sys.stdin); c["findings"]=5; print(json.dumps(c))')" | "$ASK" --validate >/dev/null 2>&1; rc=$?
  [[ $rc -eq 2 ]] || fail "a non-array findings block with payloads must exit 2, got $rc"
  printf '\xff\xfe{}' | "$ASK" --validate >/dev/null 2>&1; rc=$?
  [[ $rc -eq 2 ]] || fail "non-UTF-8 card input must exit 2, got $rc"
  pass "malformed findings type and non-UTF-8 input exit 2 instead of crashing"
}

# --- T1 render ---
test_render() {
  local name out
  for name in merge gate scope; do
    out=$("$ASK" --render < "$FIX/$name.json" 2>&1) || fail "T1: render failed for $name: $out"
    printf '%s\n' "$out" > "$TMP_ROOT/$name.render"
    diff "$FIX/$name.prose" "$TMP_ROOT/$name.render" >/dev/null \
      || fail "T1: render of $name differs from golden: $(diff "$FIX/$name.prose" "$TMP_ROOT/$name.render")"
    [[ $(grep -c '(recommended)' "$TMP_ROOT/$name.render") -eq 1 ]] \
      || fail "T1: $name must carry exactly one (recommended)"
    if LC_ALL=C grep -q '[^ -~]' "$TMP_ROOT/$name.render"; then
      fail "T1: $name render is not ASCII-only"
    fi
    if grep -q -E '^ *[0-9]+\. ' "$TMP_ROOT/$name.render"; then
      fail "T1: $name render still has numbered-menu lines"
    fi
  done
  pass "T1: render matches the golden prose, one recommended marker, ASCII only, no numbered menu"

  out=$(printf '%s' "$MERGE" | "$ASK" --render)
  if grep -q 'Your own words' <<<"$out"; then fail "T1: O0 shown although free text is off"; fi
  out=$(printf '%s' "$SCOPE" | "$ASK" --render)
  grep -q '^  O0 - Your own words$' <<<"$out" || fail "T1: O0 missing although free text is on"
  out=$(printf '%s' "$MINIMAL_CARD" | "$ASK" --render)
  if grep -q 'Context:' <<<"$out"; then fail "T1: context line shown for a card without context"; fi
  if grep -q '(ref:' <<<"$out"; then fail "T1: ref shown for an unkeyed card"; fi
  grep -q '^D1 - Simple Choice$' <<<"$out" || fail "T1: unkeyed header should be 'D1 - <title>': $out"
  grep -q '^  Pick one?$' <<<"$out" || fail "T1: question line missing for the minimal card"
  out=$(printf '%s' "$VALID_CARD" | "$ASK" --render)
  [[ $out == "$(printf '%s' "$VALID_CARD" | "$ASK" --render)" ]] || fail "T1: render is not deterministic"
  pass "T1: O0, context, and ref appear only when the card calls for them; render is deterministic"

  out=$(printf '%s' "$BOTH" | "$ASK" --render)
  if ! { grep -q '^D1 - Merge Strategy' <<<"$out" && grep -q '^D2 - Dashboard Scope' <<<"$out"; }; then
    fail "T1: an array renders one numbered block per card: $out"
  fi
  pass "T1: an array of cards renders D1 and D2 blocks"
}

# --- T2 round trip ---
test_round_trip() {
  local name out parsed
  for name in merge gate scope; do
    out=$("$ASK" --parse-card < "$FIX/$name.prose" | "$ASK" --render) || fail "T2: parse-card failed for $name"
    [[ $out == "$(cat "$FIX/$name.prose")" ]] || fail "T2: prose -> card -> prose is not the identity for $name"
  done
  pass "T2: prose -> card -> prose is the identity on every golden"

  for name in merge gate scope; do
    parsed=$("$ASK" --render < "$FIX/$name.json" | "$ASK" --parse-card)
    python3 -c '
import sys, json
a = json.load(open(sys.argv[1])); b = json.loads(sys.argv[2])
def lab(c): return [(o["label"], o.get("description")) for o in c["options"]]
def dl(c): return [o["label"] for o in c["options"] if o["id"] == c["default_option_id"]]
assert a["title"] == b["title"], "title"
assert a["question"] == b["question"], "question"
assert a.get("context") == b.get("context"), "context"
assert lab(a) == lab(b), "labels/descriptions"
assert dl(a) == dl(b), "default label"
assert a.get("allow_free_text", True) == b["allow_free_text"], "free text"
assert a["metadata"]["key"] == b["metadata"]["key"], "key"
' "$FIX/$name.json" "$parsed" || fail "T2: card -> prose -> card lost a listed field for $name"
  done
  pass "T2: card -> prose -> card preserves title, question, context, labels, default label, free-text flag, key"

  parsed=$("$ASK" --render < "$FIX/merge.json" | "$ASK" --parse-card)
  [[ $(printf '%s' "$parsed" | jget 'd["default_option_id"]') == '"squash-merge"' ]] \
    || fail "T2: authored option ids are no longer rewritten by prose round trips (negative pin): $parsed"
  pass "T2: authored option ids do not survive the prose round trip (negative pin)"

  out=$(printf '%s' "$BOTH" | "$ASK" --render)
  parsed=$(printf '%s\n' "$out" | "$ASK" --parse-card)
  [[ $(printf '%s' "$parsed" | jget 'len(d)') == 2 ]] || fail "T2: two blocks should parse into two cards: $parsed"
  [[ $(printf '%s' "$parsed" | "$ASK" --render) == "$out" ]] || fail "T2: two-block array does not round-trip"
  pass "T2: a two-block array round-trips"

  if printf 'not a decision\n' | "$ASK" --parse-card >/dev/null 2>&1; then fail "T2: malformed prose should be rejected"; fi
  printf 'not a decision\n' | "$ASK" --parse-card >/dev/null 2>&1; [[ $? -eq 2 ]] || fail "T2: malformed prose should exit 2"
  pass "T2: malformed prose exits 2"

  local dup='D1 - Gate
  Proceed?
  O1 - Yes (recommended)
  O0 - Your own words
D2 - Merge (ref: gate)
  Merge now?
  O1 - Yes (recommended)'
  printf '%s\n' "$dup" | "$ASK" --parse-card >/dev/null 2>&1; [[ $? -eq 2 ]] || fail "T2: duplicate card id from a key should exit 2"
  pass "T2: parse-card rejects duplicate card ids"
}

# --- T3 identity ---
test_identity() {
  local after grown
  ask_answer "$MERGE" 'o2'
  [[ $(printf '%s' "$A_OUT" | jget 'd["selected_option_id"]') == '"rebase"' ]] || fail "T3: o2 should pick rebase: $A_OUT"
  grown=$(printf '%s' "$MERGE" | python3 -c 'import sys,json; c=json.load(sys.stdin); c["options"].append({"id":"manual","label":"Merge Manually"}); print(json.dumps(c))')
  ask_answer "$grown" 'o2'
  after=$A_OUT
  [[ $(printf '%s' "$after" | jget 'd["selected_option_id"]') == '"rebase"' ]] \
    || fail "T3: appending an option changed what O2 means: $after"
  ask_answer "$grown" 'o4'
  [[ $(printf '%s' "$A_OUT" | jget 'd["selected_option_id"]') == '"manual"' ]] || fail "T3: appended option should be O4: $A_OUT"
  pass "T3: appending an option leaves earlier O codes meaning the same option"

  printf '%s' "$MERGE" | "$ASK" --render | grep -q '^D1 - Merge Strategy (ref: merge-strategy)$' \
    || fail "T3: keyed header must show (ref: key)"
  ask_answer "$MERGE" 'o1'
  [[ $(printf '%s' "$A_OUT" | jget 'd["decision_id"]') == '"merge-strategy"' ]] \
    || fail "T3: decision_id must equal the key: $A_OUT"
  pass "T3: keyed header shows (ref: key) and decision_id equals the key"
}

# --- T4 parser accepts ---
test_answer_accepts() {
  local ans
  for ans in 'd1 o2 d2 o1' 'D2 O1, D1 O2' 'd1 o2 and d2 o1' $'d1 o2\nd2 o1' 'd1 o2;d2 o1' '  d2  o1   d1  o2 '; do
    ask_answer "$BOTH" "$ans"
    [[ $A_RC -eq 0 ]] || fail "T4: '$ans' should be accepted (rc=$A_RC err=$A_ERR)"
    [[ $(printf '%s' "$A_OUT" | jget '[r["selected_option_id"] for r in d]') == '["rebase", "minimal"]' ]] \
      || fail "T4: '$ans' resolved to the wrong options: $A_OUT"
  done
  pass "T4: answers are case-insensitive and order/separator tolerant"

  ask_answer "$BOTH" 'd1 o1 d2 o0 "text with d2 o1 inside"'
  [[ $A_RC -eq 0 ]] || fail "T4: free text answer rejected: $A_ERR"
  [[ $(printf '%s' "$A_OUT" | jget 'd[1]["free_text"]') == '"text with d2 o1 inside"' ]] \
    || fail "T4: quoted text must stay literal: $A_OUT"
  [[ $(printf '%s' "$A_OUT" | jget 'd[1]["selected_option_id"]') == 'null' ]] || fail "T4: free text must not select an option"
  [[ $(printf '%s' "$A_OUT" | jget 'd[1]["method"]') == '"free_text"' ]] || fail "T4: free text method: $A_OUT"
  pass "T4: d1 o0 \"...\" keeps the quoted text literal"

  ask_answer "$SCOPE" 'o2'
  [[ $A_RC -eq 0 && $(printf '%s' "$A_OUT" | jget 'd["selected_option_id"]') == '"full"' ]] \
    || fail "T4: a bare option should work for one decision: $A_OUT $A_ERR"
  ask_answer "$SCOPE" 'o0 "just ship it"'
  [[ $A_RC -eq 0 && $(printf '%s' "$A_OUT" | jget 'd["free_text"]') == '"just ship it"' ]] \
    || fail "T4: a bare o0 with quotes should work for one decision: $A_OUT $A_ERR"
  pass "T4: a bare option is accepted when exactly one decision is on screen"

  ask_answer "$BOTH" 'd1 o2'
  [[ $A_RC -eq 0 ]] || fail "T4: a partial answer should be accepted: $A_ERR"
  [[ $(printf '%s' "$A_OUT" | jget 'len(d)') == 1 ]] || fail "T4: partial answer should return one result: $A_OUT"
  grep -q 'D2' <<<"$A_ERR" || fail "T4: the unanswered decision should be named on stderr: $A_ERR"
  pass "T4: a partial answer returns one result and names the unanswered decision on stderr"

  ask_answer "$BOTH" 'd1 o2 d2 o1' --format id
  [[ $A_OUT == $'rebase\nminimal' ]] || fail "T4: --format id with an answer: $A_OUT"
  ask_answer "$MERGE" 'o2' --format text
  [[ $A_OUT == 'Rebase & Merge' ]] || fail "T4: --format text with an answer: $A_OUT"
  pass "T4: --format id and text work with --answer"

  A_OUT=$(printf '%s' "$MERGE" | "$ASK" --answer 'd1 o3' --format id 2>&1)
  [[ $A_OUT == 'merge-commit' ]] || fail "T4: --answer <text> (separate argument) should work: $A_OUT"
  pass "T4: --answer accepts a separate argument"
}

# --- T5 parser rejects ---
assert_rejected() {
  local desc=$1 cards=$2 answer=$3
  ask_answer "$cards" "$answer"
  [[ $A_RC -eq 4 ]] || fail "T5: $desc should exit 4, got $A_RC (out=$A_OUT err=$A_ERR)"
  [[ -z $A_OUT ]] || fail "T5: $desc must print nothing on stdout, got: $A_OUT"
  [[ $(printf '%s\n' "$A_ERR" | wc -l) -eq 1 && -n $A_ERR ]] || fail "T5: $desc should print exactly one stderr line, got: $A_ERR"
}

test_answer_rejects() {
  local long201 long2001
  long201=$(printf 'x%.0s' $(seq 1 201))
  long2001=$(printf 'd1 o1 %.0s' $(seq 1 400))
  assert_rejected "empty answer" "$BOTH" ''
  assert_rejected "whitespace answer" "$BOTH" '   '
  assert_rejected "comma-only answer" "$BOTH" ','
  assert_rejected "semicolon-only answer" "$BOTH" ';'
  assert_rejected "unknown decision" "$BOTH" 'd3 o1 d2 o1'
  assert_rejected "unknown option" "$BOTH" 'd1 o9 d2 o1'
  assert_rejected "decision without option" "$BOTH" 'd1 d2 o1'
  assert_rejected "bare option with two decisions" "$BOTH" 'o1'
  assert_rejected "duplicate decision" "$BOTH" 'd1 o1 d1 o2 d2 o1'
  assert_rejected "trailing junk" "$BOTH" 'd1 o1 d2 o1 junk'
  assert_rejected "o0 when free text is off" "$MERGE" 'd1 o0 "x"'
  assert_rejected "o0 without quotes" "$BOTH" 'd1 o1 d2 o0'
  assert_rejected "o0 followed by another decision" "$BOTH" 'd1 o0 d2 o1'
  assert_rejected "empty quoted text" "$BOTH" 'd1 o1 d2 o0 ""'
  assert_rejected "whitespace-only quoted text" "$BOTH" 'd1 o1 d2 o0 "   "'
  assert_rejected "unterminated quote" "$BOTH" 'd1 o1 d2 o0 "abc'
  assert_rejected "quoted text without o0" "$BOTH" 'd1 o1 d2 o1 "x"'
  assert_rejected "shell metacharacters" "$BOTH" 'd1 o1 d2 o1; rm -rf /'
  assert_rejected "full-width look-alikes" "$BOTH" $'\xef\xbd\x841 \xef\xbd\x8f1'
  assert_rejected "leading zeros" "$BOTH" 'd01 o1 d2 o1'
  assert_rejected "glued tokens" "$BOTH" 'd1o1 d2o1'
  assert_rejected "dangling and" "$BOTH" 'd1 o1 and'
  assert_rejected "newline inside quotes" "$BOTH" $'d1 o1 d2 o0 "a\nb"'
  assert_rejected "escape character inside quotes" "$BOTH" $'d1 o1 d2 o0 "a\x1bb"'
  assert_rejected "backslash escape inside quotes" "$BOTH" 'd1 o1 d2 o0 "a\nb"'
  assert_rejected "C1 control inside quotes" "$BOTH" $'d1 o1 d2 o0 "a\xc2\x85b"'
  assert_rejected "bidi override inside quotes" "$BOTH" $'d1 o1 d2 o0 "a\xe2\x80\xaeb"'
  assert_rejected "zero-width space inside quotes" "$BOTH" $'d1 o1 d2 o0 "a\xe2\x80\x8bb"'
  assert_rejected "non-ASCII inside quotes" "$BOTH" $'d1 o1 d2 o0 "caf\xc3\xa9"'
  assert_rejected "free text over 200 characters" "$BOTH" "d1 o1 d2 o0 \"$long201\""
  assert_rejected "input over 2000 characters" "$BOTH" "$long2001"
  pass "T5: every malformed answer exits 4 with empty stdout and one stderr line"

  if printf '%s' "$BOTH" | "$ASK" --answer= >/dev/null 2>&1; then fail "T5: --answer= (empty) must be rejected"; fi
  printf '%s' "$BOTH" | "$ASK" --answer= >/dev/null 2>&1; [[ $? -eq 4 ]] || fail "T5: an explicit empty --answer must exit 4"
  pass "T5: an explicit empty --answer exits 4"
}

# --- T6 picker fallback ---
test_picker_fallback() {
  local out err rc
  err="$TMP_ROOT/picker.err"
  out=$(printf '%s' "$VALID_CARD" | "$ASK" 2>"$err"); rc=$?
  [[ $rc -eq 0 ]] || fail "T6: no terminal should fall back to the default (rc=$rc)"
  [[ $(printf '%s' "$out" | jget 'd["selected_option_id"]') == '"squash"' ]] || fail "T6: default option: $out"
  [[ $(printf '%s' "$out" | jget 'd["method"]') == '"default"' ]] || fail "T6: method must be 'default', not 'picker': $out"
  grep -q '^notice: no terminal, using the recommended option$' "$err" || fail "T6: missing stderr notice: $(cat "$err")"
  pass "T6: with no terminal the recommended option is chosen, method is default, and stderr says so"

  printf '%s' "$VALID_CARD" | "$ASK" --no-interactive >/dev/null 2>&1; rc=$?
  [[ $rc -eq 3 ]] || fail "T6: --no-interactive without a terminal should exit 3, got $rc"
  pass "T6: --no-interactive exits 3"

  out=$(printf '%s' "$VALID_CARD" | "$ASK" --backend default --format id 2>/dev/null)
  [[ $out == squash ]] || fail "T6: --backend default: $out"
  pass "T6: --backend default returns the default option"

  out=$(printf '%s' "$BOTH" | "$ASK" 2>/dev/null); rc=$?
  [[ $rc -eq 0 && $(printf '%s' "$out" | jget '[r["selected_option_id"] for r in d]') == '["squash", "minimal"]' ]] \
    || fail "T6: an array with no terminal should give an array of defaults: $out"
  pass "T6: an array with no terminal gives an array of defaults"

  printf '%s' "$BOTH" | timeout 5 "$ASK" --backend bash >/dev/null 2>"$err"; rc=$?
  [[ $rc -eq 2 ]] || fail "T6: the picker must refuse an array with exit 2, got $rc"
  if ! { grep -q -e '--render' "$err" && grep -q -e '--answer' "$err"; }; then
    fail "T6: the refusal should point to --render and --answer: $(cat "$err")"
  fi
  pass "T6: the picker refuses an array and points to --render and --answer"

  # The bash backend must read from /dev/tty when stdin is a pipe. In CI there is
  # no terminal, so it errors; a silent exit 0 would mean the redirect is not active.
  local bb_exit=0
  printf '%s' "$VALID_CARD" | timeout 2 "$ASK" --backend bash --format json >/dev/null 2>&1 || bb_exit=$?
  [[ $bb_exit -ne 0 ]] || fail "T6: bash backend silently defaulted (fd redirect not active)"
  pass "T6: bash backend attempted the /dev/tty path (exit $bb_exit)"
}

# --- JSON output ---
test_json_output() {
  local special opt
  special='{"version":1,"id":"test-special","title":"Test \"Special\" Chars","question":"Pick one?","options":[{"id":"a","label":"Say \"hi\""},{"id":"b","label":"Back\\slash"}],"default_option_id":"a"}'
  printf '%s' "$special" | "$ASK" --validate >/dev/null 2>&1 || fail "validate card with special characters"
  opt=$(printf '%s' "$special" | "$ASK" --backend default --format json 2>/dev/null)
  printf '%s' "$opt" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null || fail "option selection must produce valid JSON: $opt"
  printf '%s' "$opt" | grep -q 'Say \\"hi\\"' || fail "option label quotes must be escaped in JSON: $opt"
  pass "JSON output is valid and escapes quotes"
}

# --- T7 payload ---
test_payload() {
  ask_answer "$GATE" 'd1 o1'
  [[ $(printf '%s' "$A_OUT" | jget 'd["selected_payload"]') == '{"action": "fix", "step": "review", "findings": ["review-1", "review-2"]}' ]] \
    || fail "T7: the gate payload must come back unchanged: $A_OUT"
  ask_answer "$GATE" 'd1 o2'
  [[ $(printf '%s' "$A_OUT" | jget 'd["selected_payload"]["action"]') == '"approve"' ]] || fail "T7: o2 should approve: $A_OUT"
  ask_answer "$MERGE" 'd1 o1'
  [[ $(printf '%s' "$A_OUT" | jget 'd["selected_payload"]') == 'null' ]] || fail "T7: a card without payload returns null: $A_OUT"
  local rendered
  rendered=$(printf '%s' "$GATE" | "$ASK" --render)
  if grep -q -e 'payload' -e 'approve' -e '"action"' <<<"$rendered"; then fail "T7: payload leaked into the prose: $rendered"; fi
  if ! { grep -q '^F1 - review-1 ' <<<"$rendered" && grep -q '^D1 - Review gate' <<<"$rendered"; }; then
    fail "T7: the gate renders its findings block and one decision block: $rendered"
  fi
  ask_answer "$GATE" 'd1 o0 "fix only the first one"'
  [[ $(printf '%s' "$A_OUT" | jget 'd["selected_payload"]') == 'null' ]] || fail "T7: free text carries no payload: $A_OUT"
  pass "T7: the chosen option's payload is returned unchanged and never rendered"
}

# --- T9 doc drift ---
# The examples doc is the commander-facing contract: each golden it shows must be
# exactly what the real renderer prints for that card. Blocks are read from the
# doc's fenced text sections and compared whole, never as substrings.
test_doc_drift() {
  local name rendered
  for name in merge gate scope; do
    rendered=$("$ASK" --render < "$FIX/$name.json") || fail "T9: render failed for $name"
    [[ $rendered == "$(cat "$FIX/$name.prose")" ]] || fail "T9: render of $name drifted from its golden"
    WANT=$rendered python3 -c '
import os, sys
want = os.environ["WANT"]
blocks, cur = [], None
for line in open(sys.argv[1], encoding="utf-8").read().split("\n"):
    if cur is None:
        if line == "```text":
            cur = []
    elif line == "```":
        blocks.append("\n".join(cur))
        cur = None
    else:
        cur.append(line)
sys.exit(0 if want in blocks else 1)
' "$ROOT/docs/decision-card-examples.md" \
      || fail "T9: docs/decision-card-examples.md has no text block equal to the current render of $name"
  done
  pass "T9: the examples doc shows exactly what the renderer prints for each golden"
}

test_validation
test_render
test_round_trip
test_identity
test_answer_accepts
test_answer_rejects
test_picker_fallback
test_json_output
test_payload
test_doc_drift
