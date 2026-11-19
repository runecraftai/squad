#!/usr/bin/env bash
# Tests for bin/sq-card-pi-dialog.sh - the decision card to Pi ask_user_question
# dialog mapping, its split rules, its refusal paths, and the answer it hands back
# to bin/sq-ask.sh.
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
SIX="$FIX/six.json"
NINE="$FIX/nine.json"

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

# fragment <card file> <dialog> <result json>: the answer text the mapping hands
# back to bin/sq-ask.sh --answer.
fragment() {
  "$DIALOG" --answer --dialog "$2" --result "$3" < "$1"
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
  check "$PAIR" '"Context: " + c[0]["context"] in p[0]["questions"][0]["question"]'
  check "$PAIR" 'p[0]["questions"][0]["options"][1]["description"] == c[0]["options"][1]["description"] + " (recommended)"'
  check "$PAIR" 'not p[0]["questions"][0]["options"][0]["description"].endswith("(recommended)")'
  # The free-text row belongs to the dialog, so the mapping never authors an option for it.
  check "$PAIR" 'all(o["label"] not in ("Other", "Type something.", "Next") for q in p[0]["questions"] for o in q["options"])'
  pass "T1: a 2-option card becomes one dialog question with the recommended row marked"
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

  # The whole tool result is accepted, not only its details.answers array.
  answer=$(fragment "$PAIR" 1 '{"content":[{"type":"text","text":"answered"}],"details":{"answers":[{"questionIndex":0,"kind":"option","answer":"Hold Until Monday"}],"cancelled":false}}')
  [ "$answer" = "d1 o2" ] || fail "T3: expected 'd1 o2' from a whole tool result, got '$answer'"
  pass "T3: the marked recommended option round-trips back to the same card option"
}

# --- T4: more options than one question allows are split, in order, none dropped ---
test_split_keeps_every_option() {
  check "$SIX" 'len(p) == 1 and len(p[0]["questions"]) == 2'
  check "$SIX" 'all(2 <= len(q["options"]) <= 4 for q in p[0]["questions"])'
  check "$SIX" '[o["label"] for q in p[0]["questions"] for o in q["options"]] == [o["label"] for o in c[0]["options"]]'
  check "$SIX" 'len({q["question"] for q in p[0]["questions"]}) == 2'
  check "$SIX" 'all(len(q["header"]) <= 16 for q in p[0]["questions"])'
  # Option 5 lives in the second question and still maps to its card position.
  local answer
  answer=$(fragment "$SIX" 1 '[{"questionIndex":1,"kind":"option","answer":"Webhooks"}]')
  [ "$answer" = "d1 o5" ] || fail "T4: expected 'd1 o5', got '$answer'"
  resolve "$SIX" "$answer" 'r["selected_option_id"] == "webhooks"'

  # Nine options balance across three questions instead of 4+4+1.
  check "$NINE" 'len(p) == 1 and len(p[0]["questions"]) == 3'
  check "$NINE" '[len(q["options"]) for q in p[0]["questions"]] == [3, 3, 3]'
  check "$NINE" '[o["label"] for q in p[0]["questions"] for o in q["options"]] == [o["label"] for o in c[0]["options"]]'
  answer=$(fragment "$NINE" 1 '[{"questionIndex":2,"kind":"option","answer":"India"}]')
  [ "$answer" = "d1 o9" ] || fail "T4: expected 'd1 o9', got '$answer'"
  resolve "$NINE" "$answer" 'r["selected_option_id"] == "india"'
  pass "T4: extra options split in card order, balanced, and every one still round-trips"
}

# --- T5: several cards in one reply become one dialog per card, in order ---
test_one_dialog_per_card() {
  local both answer
  both="$TMP_ROOT/three-cards.json"
  python3 - "$PAIR" "$FOUR" "$SIX" > "$both" <<'PY'
import json, sys
print(json.dumps([json.load(open(p, encoding="utf-8")) for p in sys.argv[1:]]))
PY
  check "$both" 'len(p) == 3 and len(c) == 3'
  check "$both" '[len(d["questions"]) for d in p] == [1, 1, 2]'
  check "$both" '[d["questions"][0]["header"] for d in p][:2] == ["Deploy Window", "Storage Choice"]'
  check "$both" '[d["questions"][0]["header"] for d in p][2].startswith("Migration")'
  check "$both" 'all(d["questions"][0]["question"].startswith(x["question"]) for d, x in zip(p, c))'
  # The second card is dialog 2, so its rows resolve as D2.
  answer=$(fragment "$both" 2 '[{"questionIndex":0,"kind":"option","answer":"Object Store"}]')
  [ "$answer" = "d2 o3" ] || fail "T5: expected 'd2 o3', got '$answer'"
  resolve "$both" "$answer" 'r["decision_id"] == "storage-choice" and r["selected_option_id"] == "object"'
  # Both dialogs answered together still resolve through the same parser.
  answer="$(fragment "$both" 1 '[{"questionIndex":0,"kind":"option","answer":"Deploy Tonight"}]') $(fragment "$both" 3 '[{"questionIndex":1,"kind":"option","answer":"Admin Tools"}]')"
  [ "$answer" = "d1 o1 d3 o6" ] || fail "T5: expected 'd1 o1 d3 o6', got '$answer'"
  resolve "$both" "$answer" 'len(ro) == 2 and ro[0]["selected_option_id"] == "tonight" and ro[1]["selected_option_id"] == "admin"'
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

  # A card that forbids free text keeps that authority: the dialog's own row cannot widen it.
  answer=$(fragment "$FIX/merge.json" 1 '[{"questionIndex":0,"kind":"custom","answer":"neither"}]')
  [ "$answer" = 'd1 o0 "neither"' ] || fail "T7: expected the O0 fragment for the no-free-text card, got '$answer'"
  rc=0
  "$ASK" --answer "$answer" < "$FIX/merge.json" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 4 ] || fail "T7: a card with allow_free_text false must still reject free text, got $rc"

  rc=0
  out=$("$DIALOG" --payload < "$FIX/reserved.json" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "T7: a reserved dialog label must exit 2, got $rc"
  printf '%s' "$out" | grep -q 'reserved dialog label' || fail "T7: reserved label refusal is not explanatory: $out"

  rc=0
  out=$("$DIALOG" --payload < "$FIX/single.json" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "T7: a single-option card must exit 2, got $rc"
  printf '%s' "$out" | grep -q 'at least 2 options' || fail "T7: single-option refusal is not explanatory: $out"

  # A label shared by two options that land in different split questions is never
  # resolvable, so the card keeps the prose block before the dialog is shown.
  rc=0
  out=$("$DIALOG" --payload < "$FIX/duplicate-label.json" 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "T7: a label shared across split questions must exit 2, got $rc"
  printf '%s' "$out" | grep -q "share the label 'Same'" || fail "T7: duplicate-label refusal is not explanatory: $out"

  rc=0
  out=$(printf '%s' '{"version":1,"id":"broken","title":"Broken","question":"Broken?","options":[{"id":"a","label":"A"}],"default_option_id":"missing"}' \
    | "$DIALOG" --payload 2>&1) || rc=$?
  [ "$rc" = 2 ] || fail "T7: an invalid card must exit 2, got $rc"
  printf '%s' "$out" | grep -q 'default_option_id' || fail "T7: the card schema owner did not explain the invalid card: $out"

  rc=0
  out=$(fragment "$SIX" 1 '[{"questionIndex":0,"kind":"multi","answer":"x","selected":["Billing"]}]' 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: a multi-select answer must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'multi-select' || fail "T7: multi-select refusal is not explanatory: $out"

  rc=0
  out=$(fragment "$SIX" 1 '[{"questionIndex":0,"kind":"option","answer":"Billing"},{"questionIndex":1,"kind":"option","answer":"Webhooks"}]' 2>&1) || rc=$?
  [ "$rc" = 4 ] || fail "T7: two answers for one split card must exit 4, got $rc"
  printf '%s' "$out" | grep -q 'answered twice' || fail "T7: duplicate-answer refusal is not explanatory: $out"
  pass "T7: free text resolves through O0 and every refusal fails closed with a reason"
}

# --- T8: the fixtures the suite added are clean under the grammar linter ---------
test_fixtures_are_lint_clean() {
  local out
  out=$("$LINT" "$PAIR" "$FOUR" "$SIX" "$NINE" "$FIX/reserved.json" "$FIX/single.json" "$FIX/duplicate-label.json" 2>&1)
  [ -z "$out" ] || fail "T8: sq-card-lint warned on the fixtures: $out"
  pass "T8: sq-card-lint reports no warnings on the fixture cards"
}

test_two_option_card
test_four_option_card
test_round_trip
test_split_keeps_every_option
test_one_dialog_per_card
test_prose_fallback_unchanged
test_free_text_and_refusals
test_fixtures_are_lint_clean
