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
fragment() {
  "$DIALOG" --answer --dialog "$2" \
    --result "{\"details\":{\"answers\":$3,\"cancelled\":false}}" < "$1"
}

# fragments <card file> <dialog> <answers> [<dialog> <answers> ...]: one merge call
# across several dialogs, one per card.
fragments() {
  local card=$1
  shift
  local args=()
  while [ "$#" -gt 0 ]; do
    args+=(--dialog "$1" --result "{\"details\":{\"answers\":$2,\"cancelled\":false}}")
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
  check "$PAIR" 'p[0]["questions"][0]["question"].splitlines() == [c[0]["question"], "Context: " + c[0]["context"]]'
  check "$PAIR" 'p[0]["questions"][0]["options"][1]["description"] == c[0]["options"][1]["description"] + " (recommended)"'
  check "$PAIR" 'not p[0]["questions"][0]["options"][0]["description"].endswith("(recommended)")'
  # The free-text row belongs to the dialog, so the mapping never authors an option for it.
  check "$PAIR" 'all(o["label"] not in ("Other", "Type something.", "Next") for q in p[0]["questions"] for o in q["options"])'

  # Findings ride in the question text of that card's own question, once, in card order.
  check "$GATE" 'p[0]["questions"][0]["question"].splitlines() == [c[0]["question"]] + ["F%d - %s %s" % (n, f["id"], f["text"]) for n, f in enumerate(c[0]["findings"], 1)]'
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

  # The whole tool result with its details and cancelled flag is the accepted input.
  answer=$("$DIALOG" --answer --dialog 1 --result '{"content":[{"type":"text","text":"answered"}],"details":{"answers":[{"questionIndex":0,"kind":"option","answer":"Hold Until Monday"}],"cancelled":false}}' < "$PAIR")
  [ "$answer" = "d1 o2" ] || fail "T3: expected 'd1 o2' from a whole tool result, got '$answer'"
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

# --- T8: the fixtures the suite added are clean under the grammar linter ---------
test_fixtures_are_lint_clean() {
  local out
  out=$("$LINT" "$PAIR" "$FOUR" "$GATE" "$FIVE" "$SIX" "$NINE" "$SEVENTEEN" "$FIX/reserved.json" "$FIX/single.json" "$FIX/duplicate-label.json" 2>&1)
  [ -z "$out" ] || fail "T8: sq-card-lint warned on the fixtures: $out"
  pass "T8: sq-card-lint reports no warnings on the fixture cards"
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

test_two_option_card
test_four_option_card
test_round_trip
test_more_than_four_options_keep_prose
test_one_dialog_per_card
test_prose_fallback_unchanged
test_free_text_and_refusals
test_fixtures_are_lint_clean
test_merge_across_dialogs
