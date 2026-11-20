#!/usr/bin/env bash
# Tests for bin/sq-card-pi-dialog.sh - the decision card to Pi ask_user_question
# dialog mapping, its refusal paths, and the answer it hands back to bin/sq-ask.sh.
#
# A native dialog is a presentation surface only: docs/decision-card-standard.md
# owns the card schema and bin/sq-ask.sh owns the prose block and the answer
# grammar. Every case here is offline: no extension, no pi binary, no network.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIALOG="$ROOT/bin/sq-card-pi-dialog.sh"
ASK="$ROOT/bin/sq-ask.sh"
LINT="$ROOT/bin/sq-card-lint.sh"
FIX="$ROOT/tests/fixtures/decision-prose"
TMP_ROOT=$(fm_test_tmproot sq-card-pi-dialog)

PAIR="$FIX/pair.json"
FOUR="$FIX/four.json"
GATE="$FIX/gate.json"
FIVE="$FIX/five.json"
SIX="$FIX/six.json"
NINE="$FIX/nine.json"
SEVENTEEN="$FIX/seventeen.json"

# check <card file> <python expression>: convert the card to a dialog payload and
# evaluate the expression with `p` (the payload array) and `c` (the cards array).
check() {
  local card=$1 expr=$2
  "$DIALOG" --payload < "$card" > "$TMP_ROOT/payload.json" || fail "payload conversion failed for $card"
  python3 - "$card" "$TMP_ROOT/payload.json" "$expr" <<'PY' || fail "$(basename "$card"): expected $expr"
import json, sys
card = json.load(open(sys.argv[1], encoding="utf-8"))
p = json.load(open(sys.argv[2], encoding="utf-8"))
c = card if isinstance(card, list) else [card]
sys.exit(0 if eval(sys.argv[3]) else 1)
PY
}

# fragment <card file> <dialog> <answers array json>: the answer text the mapping hands
# back to bin/sq-ask.sh --answer, built into a whole extension tool result the way the
# extension returns it (details.answers plus details.cancelled).
tool_result() {
  local payload
  payload=$("$DIALOG" --payload < "$1") || return
  python3 - "$payload" "$2" "$3" <<'PY'
import json, sys
payload, number, answers = json.loads(sys.argv[1]), int(sys.argv[2]), json.loads(sys.argv[3])
if 1 <= number <= len(payload):
    question = payload[number - 1]["questions"][0]["question"]
    for answer in answers:
        answer.setdefault("question", question)
print(json.dumps({"content": [{"type": "text", "text": "answered"}],
                  "details": {"answers": answers, "cancelled": False}}))
PY
}

fragment() {
  local result
  result=$(tool_result "$@") || return
  "$DIALOG" --answer --dialog "$2" --result "$result" < "$1"
}

# fragments <card file> <dialog> <answers> [<dialog> <answers> ...]: one merge call
# across several dialogs, one per card.
fragments() {
  local card=$1
  shift
  local result args=()
  while [ "$#" -gt 0 ]; do
    result=$(tool_result "$card" "$1" "$2") || return
    args+=(--dialog "$1" --result "$result")
    shift 2
  done
  "$DIALOG" --answer "${args[@]}" < "$card"
}

# resolve <card file> <answer text> <python expression>: resolve an answer through
# the real parser and evaluate the expression with `r` (the first result) and `ro`
# (the whole result, an array when several decisions came in).
resolve() {
  local card=$1 answer=$2 expr=$3
  "$ASK" --answer "$answer" < "$card" > "$TMP_ROOT/result.json" 2>/dev/null \
    || fail "sq-ask --answer rejected '$answer' for $(basename "$card")"
  python3 - "$TMP_ROOT/result.json" "$expr" <<'PY' || fail "$(basename "$card"): expected $expr for answer '$answer'"
import json, sys
ro = json.load(open(sys.argv[1], encoding="utf-8"))
r = ro[0] if isinstance(ro, list) else ro
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
}

# --- T1: a 2-option card becomes one dialog question, marker on the default row ---
test_two_option_card() {
  check "$PAIR" 'len(p) == 1 and len(p[0]["questions"]) == 1'
  check "$PAIR" 'len(p[0]["questions"][0]["options"]) == 2'
  check "$PAIR" '[o["label"] for o in p[0]["questions"][0]["options"]] == [o["label"] for o in c[0]["options"]]'
  check "$PAIR" 'len(p[0]["questions"][0]["header"]) <= 16'
  check "$PAIR" 'p[0]["questions"][0]["question"].startswith(c[0]["question"])'
  check "$PAIR" 'p[0]["questions"][0]["question"].splitlines()[:-1] == [c[0]["question"], "Context: " + c[0]["context"]]'
  check "$PAIR" 'p[0]["questions"][0]["options"][1]["description"] == c[0]["options"][1]["description"] + " (recommended)"'
  check "$PAIR" 'not p[0]["questions"][0]["options"][0]["description"].endswith("(recommended)")'
  # The free-text row belongs to the dialog, so the mapping never authors an option for it.
  check "$PAIR" 'all(o["label"] not in ("Other", "Type something.", "Next") for q in p[0]["questions"] for o in q["options"])'

  # Findings ride in the question text of that card's own question, once, in card order.
  check "$GATE" 'p[0]["questions"][0]["question"].splitlines()[:-1] == [c[0]["question"]] + ["F%d - %s %s" % (n, f["id"], f["text"]) for n, f in enumerate(c[0]["findings"], 1)]'
  pass "T1: a 2-option card becomes one dialog question with the recommended row marked and its findings carried"
}

# --- T2: a 4-option card fills one question exactly ---
test_four_option_card() {
  check "$FOUR" 'len(p) == 1 and len(p[0]["questions"]) == 1 and len(p[0]["questions"][0]["options"]) == 4'
  check "$FOUR" '[o["label"] for o in p[0]["questions"][0]["options"]] == [o["label"] for o in c[0]["options"]]'
  check "$FOUR" 'p[0]["questions"][0]["options"][0]["description"].endswith(" (recommended)")'
  pass "T2: a 4-option card becomes one question with four rows"
}

# --- T3: the recommendation survives the dialog round trip ---
test_round_trip() {
  local answer
  answer=$(fragment "$PAIR" 1 '[{"questionIndex":0,"kind":"option","answer":"Hold Until Monday"}]')
  [ "$answer" = "d1 o2" ] || fail "T3: expected 'd1 o2', got '$answer'"
  resolve "$PAIR" "$answer" 'r["selected_option_id"] == "hold" and r["selected_label"] == "Hold Until Monday"'

  answer=$(fragment "$PAIR" 1 '[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"}]')
  [ "$answer" = "d1 o1" ] || fail "T3: expected 'd1 o1', got '$answer'"
  resolve "$PAIR" "$answer" 'r["selected_option_id"] == "tonight"'

  pass "T3: the marked recommended option round-trips back to the same card option"
}

# --- T4: a card that would need more than one dialog question keeps the prose block ---
test_more_than_four_options_keep_prose() {
  local fixture rc rendered
  for fixture in "$FIVE" "$SIX" "$NINE" "$SEVENTEEN"; do
    rc=0
    "$DIALOG" --payload < "$fixture" > "$TMP_ROOT/refused.out" 2> "$TMP_ROOT/refused.err" || rc=$?
    [ "$rc" = 2 ] || fail "T4: $(basename "$fixture") must exit 2, got $rc"
    grep -q 'needs more than one dialog question' "$TMP_ROOT/refused.err" \
      || fail "T4: $(basename "$fixture") refusal is not explanatory: $(cat "$TMP_ROOT/refused.err")"
    if [ -s "$TMP_ROOT/refused.out" ]; then
      fail "T4: $(basename "$fixture") emitted a payload for a card it refuses: $(cat "$TMP_ROOT/refused.out")"
    fi
  done

  # Nothing is dropped: the prose block the caller falls back to still lists every
  # option of the refused card, in card order.
  rendered=$("$ASK" --render < "$SEVENTEEN") || fail "T4: sq-ask --render failed on the refused card"
  printf '%s\n' "$rendered" > "$TMP_ROOT/seventeen.prose"
  python3 - "$SEVENTEEN" "$TMP_ROOT/seventeen.prose" <<'PY' || fail "T4: the prose fallback dropped or reordered an option"
import json, sys
card = json.load(open(sys.argv[1], encoding="utf-8"))
rows = [line for line in open(sys.argv[2], encoding="utf-8").read().splitlines()
        if line.startswith("  O") and "Your own words" not in line]
sys.exit(0 if len(rows) == len(card["options"])
         and all(o["label"] in row for o, row in zip(card["options"], rows)) else 1)
PY
  pass "T4: more than four options refuses into the complete prose block instead of splitting"
}

# --- T5: several cards in one reply become one dialog per card, in order ---
test_one_dialog_per_card() {
  local both answer
  both="$TMP_ROOT/three-cards.json"
  python3 - "$PAIR" "$FOUR" "$GATE" > "$both" <<'PY'
import json, sys
print(json.dumps([json.load(open(p, encoding="utf-8")) for p in sys.argv[1:]]))
PY
  check "$both" 'len(p) == 3 and len(c) == 3'
  check "$both" '[len(d["questions"]) for d in p] == [1, 1, 1]'
  check "$both" '[d["questions"][0]["header"] for d in p] == ["Deploy Window", "Storage Choice", "Review gate: 2"]'
  check "$both" 'all(len(d["questions"][0]["header"]) <= 16 for d in p)'
  check "$both" 'all(d["questions"][0]["question"].startswith(x["question"]) for d, x in zip(p, c))'
  # Findings stay on the card that owns them, never repeated across the other dialogs.
  check "$both" '[q["question"].count("F1 - review-1") for d in p for q in d["questions"]] == [0, 0, 1]'
  # The second card is dialog 2, so its rows resolve as D2.
  answer=$(fragment "$both" 2 '[{"questionIndex":0,"kind":"option","answer":"Object Store"}]')
  [ "$answer" = "d2 o3" ] || fail "T5: expected 'd2 o3', got '$answer'"
  resolve "$both" "$answer" 'r["decision_id"] == "storage-choice" and r["selected_option_id"] == "object"'
  # Two cards answered together still resolve through the same parser, in one call.
  answer=$(fragments "$both" 1 '[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"}]' 3 '[{"questionIndex":0,"kind":"option","answer":"Accept as is"}]')
  [ "$answer" = "d1 o1 d3 o2" ] || fail "T5: expected 'd1 o1 d3 o2', got '$answer'"
  resolve "$both" "$answer" 'len(ro) == 2 and ro[0]["selected_option_id"] == "tonight" and ro[1]["selected_option_id"] == "accept"'
  pass "T5: several cards produce one dialog each, in card order, answered independently"
}

# --- T6: the prose fallback is untouched and the extension stays optional ---
test_prose_fallback_unchanged() {
  local expected rendered answer fakebin
  expected='D1 - Deploy Window (ref: deploy-window)
  Should this release deploy tonight?
  Context: The migration takes 20 minutes and the on-call is awake.
  O1 - Deploy Tonight: Ship now, watch the rollout
  O2 - Hold Until Monday: Wait for the change freeze to lift (recommended)
  O0 - Your own words'
  rendered=$("$ASK" --render < "$PAIR") || fail "T6: sq-ask --render failed"
  [ "$rendered" = "$expected" ] || fail "T6: the prose block changed"$'\n'"got: $rendered"
  answer=$("$ASK" --answer 'd1 o2' < "$PAIR") || fail "T6: sq-ask --answer failed"
  printf '%s' "$answer" | grep -q '"selected_option_id": "hold"' || fail "T6: prose answer did not resolve"

  # No pi binary is needed: the mapping never reaches the extension at runtime.
  fakebin="$TMP_ROOT/no-pi-bin"
  mkdir -p "$fakebin"
  PATH="$fakebin:/usr/bin:/bin" "$DIALOG" --payload < "$PAIR" >/dev/null \
    || fail "T6: the mapping needs a binary it should not need"

  # A pi binary that refuses any invocation must never be called: nothing in this
  # path installs, updates, or discovers an extension.
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
echo "unexpected pi invocation: $*" >&2
exit 9
SH
  chmod +x "$fakebin/pi"
  PATH="$fakebin:/usr/bin:/bin" "$DIALOG" --payload < "$PAIR" > "$TMP_ROOT/payload.json" 2> "$TMP_ROOT/stderr" \
    || fail "T6: the mapping called pi"
  if [ -s "$TMP_ROOT/stderr" ]; then
    fail "T6: the mapping wrote to stderr: $(cat "$TMP_ROOT/stderr")"
  fi
  pass "T6: the prose block and the answer parser are unchanged and need no extension"
}

# --- T7: free text comes back through O0, and refusals fail closed ---
test_free_text_and_refusals() {
  local answer rc out
  answer=$(fragment "$PAIR" 1 '[{"questionIndex":0,"kind":"custom","answer":"ship it on Friday"}]')
  [ "$answer" = 'd1 o0 "ship it on Friday"' ] || fail "T7: expected the O0 fragment, got '$answer'"
  resolve "$PAIR" "$answer" 'r["free_text"] == "ship it on Friday" and r["selected_option_id"] is None'

  # Free text the prose grammar cannot quote is refused, never emitted unparseable.
  rc=0
  out=$(fragment "$PAIR" 1 '[{"questionIndex":0,"kind":"custom","answer":"ship \"it\" now"}]' 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: a double quote in free text must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'double quotes' || fail "T7: the free-text refusal is not explanatory: $out"

  rc=0
  "$DIALOG" --payload < "$FIX/merge.json" > "$TMP_ROOT/refusal.out" 2> "$TMP_ROOT/refusal.err" || rc=$?
  [ "$rc" = 2 ] && [ ! -s "$TMP_ROOT/refusal.out" ] || fail "T7: a no-free-text card must be refused without a payload"
  grep -q 'allow_free_text=false' "$TMP_ROOT/refusal.err" || fail "T7: missing no-free-text diagnostic"

  rc=0
  out=$("$DIALOG" --payload < "$FIX/reserved.json" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "T7: a reserved dialog label must exit 2, got $rc"
  printf '%s' "$out" | grep -q 'reserved dialog label' || fail "T7: reserved label refusal is not explanatory: $out"

  rc=0
  out=$("$DIALOG" --payload < "$FIX/single.json" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "T7: a single-option card must exit 2, got $rc"
  printf '%s' "$out" | grep -q 'at least 2 options' || fail "T7: single-option refusal is not explanatory: $out"

  # A label shared by two options is never resolvable, so the card keeps the prose block.
  rc=0
  out=$("$DIALOG" --payload < "$FIX/duplicate-label.json" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "T7: a card with a shared option label must exit 2, got $rc"
  printf '%s' "$out" | grep -q "share the label 'Same'" || fail "T7: duplicate-label refusal is not explanatory: $out"

  # A refusal keeps stdout clean: stdout is the protocol channel, so a failed
  # conversion prints nothing a caller could mistake for a payload.
  rc=0
  printf '%s' '{"version":1,"id":"broken","title":"Broken","question":"Broken?","options":[{"id":"a","label":"A"}],"default_option_id":"missing"}' \
    | "$DIALOG" --payload > "$TMP_ROOT/refusal.out" 2> "$TMP_ROOT/refusal.err" || rc=$?
  [ "$rc" = 2 ] || fail "T7: an invalid card must exit 2, got $rc"
  if [ -s "$TMP_ROOT/refusal.out" ]; then
    fail "T7: the invalid-card refusal wrote to stdout: $(cat "$TMP_ROOT/refusal.out")"
  fi
  grep -q 'default_option_id' "$TMP_ROOT/refusal.err" \
    || fail "T7: the card schema owner did not explain the invalid card: $(cat "$TMP_ROOT/refusal.err")"

  rc=0
  out=$(fragment "$PAIR" 1 '[{"questionIndex":0,"kind":"multi","answer":"x","selected":["Deploy Tonight"]}]' 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: a multi-select answer must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'multi-select' || fail "T7: multi-select refusal is not explanatory: $out"

  # One dialog carries one question, so a second answer for it is a named error.
  rc=0
  out=$(fragment "$PAIR" 1 '[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"},{"questionIndex":0,"kind":"option","answer":"Hold Until Monday"}]' 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: two answers for one decision must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'answered more than once' || fail "T7: duplicate-answer refusal is not explanatory: $out"

  # Esc is not a decision: only the whole tool result can prove a dialog was not
  # cancelled, so a bare answers array is refused even when it looks answerable.
  rc=0
  out=$("$DIALOG" --answer --dialog 1 \
    --result '[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"}]' < "$PAIR" 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: a bare answers array must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'whole tool result' || fail "T7: the bare-array refusal is not explanatory: $out"

  rc=0
  out=$("$DIALOG" --answer --dialog 1 \
    --result '{"details":{"answers":[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"}],"cancelled":true}}' < "$PAIR" 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: a cancelled details result must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'cancelled' || fail "T7: cancelled refusal is not explanatory: $out"

  rc=0
  out=$("$DIALOG" --answer --dialog 1 \
    --result '{"details":{"answers":[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"}]}}' < "$PAIR" 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: a result without details.cancelled must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'cancelled' || fail "T7: the missing-cancelled refusal is not explanatory: $out"

  rc=0
  out=$("$DIALOG" --answer --dialog 1 \
    --result '{"answers":[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"}],"cancelled":true}' < "$PAIR" 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: a top-level result must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'whole tool result' || fail "T7: the top-level result refusal is not explanatory: $out"

  # A malformed answer payload is a usage error, never a traceback.
  rc=0
  out=$(fragment "$PAIR" 1 '[{"questionIndex":0,"kind":"custom","answer":5}]' 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: a non-string custom answer must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'custom answer must carry the typed text' || fail "T7: the custom-answer type refusal is not explanatory: $out"

  rc=0
  out=$(fragment "$PAIR" 1 '[{"questionIndex":0,"kind":"option","answer":4}]' 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: a non-string option answer must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'option answer must name the chosen label' || fail "T7: the option-answer type refusal is not explanatory: $out"
  pass "T7: free text resolves through O0 and every refusal fails closed with a reason"
}

# --- T8: every fixture renders to prose the grammar linter accepts --------------
test_fixtures_are_lint_clean() {
  local fixture name rendered out
  local rendered_files=()
  for fixture in "$PAIR" "$FOUR" "$GATE" "$FIVE" "$SIX" "$NINE" "$SEVENTEEN" \
    "$FIX/reserved.json" "$FIX/single.json" "$FIX/duplicate-label.json"; do
    name=$(basename "$fixture" .json)
    rendered="$TMP_ROOT/rendered-$name.prose"
    "$ASK" --render < "$fixture" > "$rendered" \
      || fail "T8: sq-ask --render failed on $(basename "$fixture")"
    python3 - "$fixture" "$rendered" <<'PY' || fail "T8: the rendered block for $(basename "$fixture") does not match its card"
import json, sys
card = json.load(open(sys.argv[1], encoding="utf-8"))
card = card[0] if isinstance(card, list) else card
lines = open(sys.argv[2], encoding="utf-8").read().splitlines()
opts = [line for line in lines if line.startswith("  O") and "Your own words" not in line]
rec = [line for line in opts if line.endswith(" (recommended)")]
sys.exit(0 if any(line.startswith("D1 - ") for line in lines)
         and len(opts) == len(card["options"])
         and all(o["label"] in line for o, line in zip(card["options"], opts))
         and len(rec) == 1 else 1)
PY
    rendered_files+=("$rendered")
  done
  out=$("$LINT" "${rendered_files[@]}" 2>&1)
  [ -z "$out" ] || fail "T8: sq-card-lint warned on the rendered fixtures: $out"
  pass "T8: every fixture renders to a complete prose block sq-card-lint accepts"
}

# --- T9: answering several cards in one call merges one fragment per decision ----
test_merge_across_dialogs() {
  local both answer rc out
  both="$TMP_ROOT/two-cards.json"
  python3 - "$PAIR" "$FOUR" > "$both" <<'PY'
import json, sys
print(json.dumps([json.load(open(p, encoding="utf-8")) for p in sys.argv[1:]]))
PY
  check "$both" 'len(p) == 2 and [len(d["questions"]) for d in p] == [1, 1]'

  # Each card keeps its own number, so the second dialog's pick is still D2's option.
  answer=$(fragments "$both" 1 '[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"}]' 2 '[{"questionIndex":0,"kind":"option","answer":"Object Store"}]')
  [ "$answer" = "d1 o1 d2 o3" ] || fail "T9: expected 'd1 o1 d2 o3', got '$answer'"
  resolve "$both" "$answer" 'len(ro) == 2 and ro[0]["selected_option_id"] == "tonight" and ro[1]["selected_option_id"] == "object"'

  # A repeated decision across the pairs is a named error, never a guessed pick.
  rc=0
  out=$(fragments "$both" 1 '[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"}]' 1 '[{"questionIndex":0,"kind":"option","answer":"Hold Until Monday"}]' 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T9: two answers for one decision across dialogs must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'answered more than once across the dialogs' \
    || fail "T9: the cross-dialog duplicate refusal is not explanatory: $out"

  # Each card renders exactly one dialog, so a third dialog is out of range.
  rc=0
  out=$(fragments "$both" 3 '[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"}]' 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "T9: a dialog past the rendered count must exit 2, got $rc"
  printf '%s' "$out" | grep -q 'out of range' || fail "T9: the out-of-range refusal is not explanatory: $out"
  pass "T9: several cards merge into one fragment per decision, with a named duplicate error"
}

test_protocol_validation() {
  python3 - "$DIALOG" "$ASK" "$PAIR" "$GATE" "$FIX/blank-description.json" \
    "$FIX/recommended-marker.json" <<'PY' || fail "dialog protocol validation failed"
import json, copy, subprocess, sys

dialog, ask, fixture, gate_fixture, blank_fixture, marker_fixture = sys.argv[1:]
with open(fixture, "rb") as f:
    raw = f.read()
card = json.loads(raw)

def run(program, *args, data):
    return subprocess.run([program, *args], input=data, capture_output=True)

def result(question, kind, answer, call_id="call-1", is_error=False):
    return json.dumps({
        "role": "toolResult", "toolName": "ask_user_question", "toolCallId": call_id,
        "isError": is_error, "timestamp": 0,
        "content": [{"type": "text", "text": "Tool failed" if is_error else answer}],
        "details": {"cancelled": False, "answers": [
            {"questionIndex": 0, "question": question, "kind": kind, "answer": answer}
        ]},
    })

def saved_call(arguments, call_id="call-1"):
    return json.dumps({
        "type": "toolCall", "id": call_id, "name": "ask_user_question", "arguments": arguments,
    }, sort_keys=True, indent=2)

def check_heading(candidate, eligible):
    data = json.dumps(candidate).encode()
    assert run(ask, "--validate", data=data).returncode == 0
    converted = run(dialog, "--payload", data=data)
    if eligible:
        assert converted.returncode == 0, converted
        return json.loads(converted.stdout)[0]["questions"][0]["question"]
    assert converted.returncode == 2 and not converted.stdout and b"dialog heading exceeds" in converted.stderr, converted

heading_card = copy.deepcopy(card)
for count in (2, 3, 4):
    heading_card["findings"] = [{"id": f"finding-{n}", "text": "Check this change"} for n in range(count)]
    heading = check_heading(heading_card, count < 4)
    if heading is not None:
        assert len(heading.splitlines()) == count + 3 and len(heading) < 600, heading

heading_card["question"] = "Q" * 150
heading_card["findings"] = [{"id": "long-finding", "text": "F" * 180}]
heading_card["context"] = "C"
base_length = len(check_heading(heading_card, True)) - 1
for size in (599, 600, 601):
    heading_card["context"] = "C" * (size - base_length)
    heading = check_heading(heading_card, size <= 600)
    if heading is not None:
        assert len(heading) == size and len(heading.splitlines()) == 4, heading

with open(blank_fixture, "rb") as f:
    blank = json.load(f)
for description in (blank["options"][1]["description"], "", None):
    blank["options"][1]["description"] = description
    data = json.dumps(blank).encode()
    assert run(ask, "--validate", data=data).returncode == 0
    refused = run(dialog, "--payload", data=data)
    assert refused.returncode == 2 and not refused.stdout and b"non-blank description" in refused.stderr, refused
del blank["options"][1]["description"]
refused = run(dialog, "--payload", data=json.dumps(blank).encode())
assert refused.returncode == 2 and not refused.stdout and b"non-blank description" in refused.stderr, refused

with open(marker_fixture, "rb") as f:
    marker = json.load(f)
for default in ("wait", "now"):
    marker["default_option_id"] = default
    for field in ("description", "label"):
        candidate = copy.deepcopy(marker)
        if field == "label":
            option = candidate["options"][1]
            option["label"] = option["description"]
            option["description"] = "Wait for legal"
        data = json.dumps(candidate).encode()
        assert run(ask, "--validate", data=data).returncode == 0
        refused = run(dialog, "--payload", data=data)
        reason = f"{field} may not end with (recommended)".encode()
        assert refused.returncode == 2 and not refused.stdout and reason in refused.stderr, refused

padded = copy.deepcopy(card)
padded["title"] = " " * 16 + "Deploy Window"
padded["options"][0]["description"] += " (Recommended)"
presented = run(dialog, "--payload", data=json.dumps(padded).encode())
assert presented.returncode == 0, presented
question = json.loads(presented.stdout)[0]["questions"][0]
assert question["header"] == "Deploy Window", question
assert question["options"][0]["description"].endswith(" (Recommended)"), question

cards = []
for n in range(10):
    clone = copy.deepcopy(card)
    clone["id"] = "decision-%d" % (n + 1)
    clone["metadata"] = {}
    cards.append(clone)

def check_binding():
    data = json.dumps(cards[:2]).encode()
    payload = json.loads(run(dialog, data=data).stdout)
    question = payload[1]["questions"][0]["question"]
    tool_result = result(question, "option", card["options"][0]["label"])
    swapped = run(dialog, "--answer", "--dialog", "1", "--result", tool_result, data=data)
    assert swapped.returncode == 4 and not swapped.stdout and b"question" in swapped.stderr, swapped
    correct = run(dialog, "--answer", "--dialog", "2", "--result", tool_result, data=data)
    assert correct.returncode == 0 and correct.stdout.strip() == b"d2 o1", correct

cards[1]["question"] = "Should this release wait?"
check_binding()
cards[1]["question"] = card["question"]
check_binding()

first, second = [json.dumps(c).encode() for c in cards[:2]]
question = json.loads(run(dialog, data=first).stdout)[0]["questions"][0]["question"]
option_result = result(question, "option", card["options"][0]["label"])
swapped = run(dialog, "--answer", "--dialog", "1", "--result", option_result, data=second)
assert swapped.returncode == 4 and not swapped.stdout and b"question" in swapped.stderr, swapped
correct = run(dialog, "--answer", "--dialog", "1", "--result", option_result, data=first)
assert correct.returncode == 0 and correct.stdout.strip() == b"d1 o1", correct

with open(gate_fixture, "rb") as f:
    gate = json.load(f)
gate_call = json.loads(run(dialog, data=json.dumps(gate).encode()).stdout)[0]
gate_question = gate_call["questions"][0]["question"]
accept_result = result(gate_question, "option", gate["options"][1]["label"])
reformatted = json.dumps(gate, sort_keys=True, indent=2).encode()
correct = run(dialog, "--answer", "--dialog", "1", "--result", accept_result, data=reformatted)
assert correct.returncode == 0 and correct.stdout.strip() == b"d1 o2", correct
gate["options"][1]["payload"]["action"] = "skip"
stale = run(dialog, "--answer", "--dialog", "1", "--result", accept_result, data=json.dumps(gate).encode())
assert stale.returncode == 4 and not stale.stdout and b"card snapshot" in stale.stderr, stale

canonical = run(ask, "--answer", "d1 o2", data=reformatted)
resolve_args = ["--resolve", "--dialog", "1", "--result", accept_result]
call_args = ["--call", saved_call(gate_call)]
resolved = run(dialog, *resolve_args, *call_args, data=reformatted)
assert resolved.returncode == canonical.returncode == 0 and resolved.stdout == canonical.stdout, resolved
assert json.loads(resolved.stdout)["selected_payload"]["action"] == "approve", resolved
stale = run(dialog, *resolve_args, *call_args, data=json.dumps(gate).encode())
assert stale.returncode == 4 and not stale.stdout and b"card snapshot" in stale.stderr, stale

swapped_call = copy.deepcopy(gate_call)
first, second = swapped_call["questions"][0]["options"][:2]
first["description"], second["description"] = second["description"], first["description"]
mismatch = run(dialog, *resolve_args, "--call", saved_call(swapped_call), data=reformatted)
assert mismatch.returncode == 2 and not mismatch.stdout and b"--call arguments do not match" in mismatch.stderr, mismatch
missing = run(dialog, *resolve_args, data=reformatted)
assert missing.returncode == 2 and not missing.stdout and b"needs one --call" in missing.stderr, missing

deep_json = "[" * 60000 + "0" + "]" * 60000
for mode, extra in [("--answer", []), ("--resolve", call_args)]:
    refused = run(dialog, mode, *resolve_args[1:-1], deep_json, *extra, data=reformatted)
    assert refused.returncode == 4 and not refused.stdout, refused
    assert any(reason in refused.stderr for reason in (
        b"--result has too many nested JSON levels", b"--result must be the whole tool result object"
    )), refused
refused = run(dialog, *resolve_args, "--call", deep_json, data=reformatted)
assert refused.returncode == 2 and not refused.stdout, refused
assert any(reason in refused.stderr for reason in (
    b"--call for dialog 1 has too many nested JSON levels", b"--call for dialog 1 needs a saved entry"
)), refused

for result_id, reason in [("other-call", b"toolCallId does not match"), (None, b"missing toolCallId")]:
    returned = json.loads(accept_result)
    if result_id is None:
        del returned["toolCallId"]
    else:
        returned["toolCallId"] = result_id
    refused = run(dialog, *resolve_args[:-1], json.dumps(returned), *call_args, data=reformatted)
    assert refused.returncode == 4 and not refused.stdout and reason in refused.stderr, refused

failed_result = result(gate_question, "option", gate["options"][1]["label"], is_error=True)
structured_failure = json.loads(accept_result)
structured_failure["details"]["error"] = "Tool failed"
for failure in (failed_result, json.dumps(structured_failure)):
    for mode, extra in [("--answer", []), ("--resolve", call_args)]:
        refused = run(dialog, mode, *resolve_args[1:-1], failure, *extra, data=reformatted)
        assert refused.returncode == 4 and not refused.stdout and b"tool result is marked as an error" in refused.stderr, refused

for field in ("notes", "globalNote"):
    returned = json.loads(accept_result)
    details = returned["details"]
    target = details["answers"][0] if field == "notes" else details
    target[field] = "Only after legal signs off"
    for mode, extra in [("--answer", []), ("--resolve", call_args)]:
        refused = run(dialog, mode, *resolve_args[1:-1], json.dumps(returned), *extra, data=reformatted)
        assert refused.returncode == 4 and not refused.stdout and b"dialog notes cannot be recorded" in refused.stderr, refused

ineligible = json.loads(reformatted)
ineligible["options"][0]["label"] = "Next"
changed = json.dumps(ineligible).encode()
assert run(ask, "--validate", data=changed).returncode == 0
refused = run(dialog, "--payload", data=changed)
assert refused.returncode == 2 and b"reserved dialog label" in refused.stderr, refused
for mode, extra in [("--answer", []), ("--resolve", call_args)]:
    stale = run(dialog, mode, *resolve_args[1:], *extra, data=changed)
    assert stale.returncode == 4 and not stale.stdout and b"card snapshot" in stale.stderr, stale

data = json.dumps(cards[:2]).encode()
question = json.loads(run(dialog, data=data).stdout)[1]["questions"][0]["question"]
empty = run(dialog, "--answer", "--dialog", "1", "--result",
            '{"details":{"cancelled":false,"answers":[]}}',
            "--dialog", "2", "--result", result(question, "option", card["options"][0]["label"]), data=data)
assert empty.returncode == 4 and not empty.stdout and b"no answer for decision D1" in empty.stderr, empty

data = json.dumps(cards).encode()
payload = json.loads(run(dialog, data=data).stdout)
args = []
for n, entry in enumerate(payload, 1):
    args += ["--dialog", str(n), "--result", result(entry["questions"][0]["question"], "custom", "a" * 200, f"call-{n}")]
merged = run(dialog, "--answer", *args, data=data)
assert merged.returncode == 4 and not merged.stdout and b"fewer dialogs" in merged.stderr, merged
canonical = run(ask, "--answer", " ".join('d%d o0 "%s"' % (n, "a" * 200) for n in range(1, 11)), data=data)
calls = [saved_call(entry, f"call-{n}") for n, entry in enumerate(payload, 1)]
call_flags = [part for call in calls for part in ("--call", call)]
resolved = run(dialog, "--resolve", *args, *call_flags, data=data)
assert resolved.returncode == canonical.returncode == 4 and not resolved.stdout, resolved
assert resolved.stderr == canonical.stderr, resolved
resolved = run(dialog, "--resolve", *args[:8], *call_flags[:4], data=data)
canonical = run(ask, "--answer", 'd1 o0 "' + "a" * 200 + '" d2 o0 "' + "a" * 200 + '"', data=data)
assert resolved.returncode == canonical.returncode == 0 and resolved.stdout == canonical.stdout, resolved
for batch in [args[:36], args[36:]]:
    fragment = run(dialog, "--answer", *batch, data=data)
    assert fragment.returncode == 0, fragment
    parsed = run(ask, "--answer", fragment.stdout.decode().strip(), data=data)
    assert parsed.returncode == 0 and len(json.loads(parsed.stdout)) == len(batch) // 4, parsed

malformed = raw.replace(b"Deploy Tonight", b"Deploy\x00 Tonight", 1)
canonical = run(ask, "--validate", data=malformed)
conversion = run(dialog, "--payload", data=malformed)
assert canonical.returncode == conversion.returncode == 2 and not conversion.stdout, conversion
PY
  pass "dialog results bind to the presented question and fragments satisfy the canonical parser"
}

test_two_option_card
test_four_option_card
test_round_trip
test_more_than_four_options_keep_prose
test_one_dialog_per_card
test_prose_fallback_unchanged
test_free_text_and_refusals
test_fixtures_are_lint_clean
test_merge_across_dialogs
test_protocol_validation
