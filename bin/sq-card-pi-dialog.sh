#!/usr/bin/env bash
# Map a decision card to the Pi ask_user_question dialog payload and back.
#
# A native dialog is a presentation surface only. docs/decision-card-standard.md
# owns the card schema, bin/sq-ask.sh owns the prose block and the answer grammar,
# and docs/decision-card-pi-recipe.md owns this mapping. Nothing here changes the
# card, the prose block, the codes, or any existing decision path, and the Pi
# extension itself stays optional: this script never installs it, never imports it,
# and never touches the network.
#
# Usage: echo '<card json>' | bin/sq-card-pi-dialog.sh [--payload]
#        bin/sq-card-pi-dialog.sh '<card json>' [--payload]
#        echo '<card json>' | bin/sq-card-pi-dialog.sh --resolve --dialog 1 --result '<tool result json>' \
#          [--dialog 2 --result '<tool result json>' ...]
#
# Input is one card object or a JSON array of cards, validated first by
# bin/sq-ask.sh --validate so the schema keeps exactly one owner.
#
# Modes:
#   --payload      Print the ask_user_question payload(s) as a JSON array, one entry
#                  per dialog, in card order; each entry is one tool call. The default.
#   --resolve      Use this mode to record a dialog decision. It checks the echoed
#                  question against the card snapshot, passes the derived answer and
#                  the same card bytes to bin/sq-ask.sh --answer, and returns that
#                  parser's output and exit code unchanged.
#   --answer       Print only the answer fragment, such as "d1 o2" or 'd1 o0 "ship it"'.
#                  Like --resolve, this accepts repeated --dialog/--result pairs to
#                  answer several cards in one call; the pairs are merged.
#                  Both modes take the whole tool result, never a bare answers array:
#                  only details.cancelled proves the dialog was not cancelled.
#   --help         Show this help.
#
# Mapping (card -> dialog):
#   question      -> questions[].question, then one "F<n> - <id> <text>" line per finding
#                    and finally one "Context: <context>" line when the card has context.
#                    The published payload has no notes field, so context and findings
#                    ride in the question text rather than being dropped.
#   title         -> questions[].header, cut to the 16-character payload limit
#   label         -> options[].label, unchanged
#   description   -> options[].description; the recommended option gains a trailing
#                    " (recommended)", so the recommendation is visible on its own row
#   free text     -> the dialog's own free-text row; the mapping authors no option for it
#
# One card is one dialog question: a question holds 2-4 options, so a card inside that
# range becomes exactly one ask_user_question question, and several cards in one reply
# become one dialog per card, in card order.
#
# A split mapping is not used for this payload path: the extension answers one entry per
# question, so a card split across questions would come back as several answers for one
# decision and could only be recorded by guessing a pick. A card with more than four
# options is therefore refused, never split and never truncated, and the prose block
# stays authoritative. Nothing is ever dropped or renumbered.
#
# Answering several cards merges their dialogs into exactly one fragment per decision,
# mechanically: no fold, no renumbering, no guessed pick. Two answers for the same
# decision exit 4 instead of choosing one.
#
# Refused, because the dialog cannot show that card without dropping or misrepresenting
# an option: an option label that is a reserved dialog label ("Other", "Type something.",
# "Next"), a label shared by two options of the card, a card with a single option, and a
# card with more than four options (it would need more than one dialog question),
# a card with allow_free_text disabled (the built-in free-text row cannot be hidden),
# a card with any missing, null, or blank option description, or any option label
# or description ending in "(recommended)" after trimming trailing whitespace.
# A refusal exits 2 with a message and leaves the caller on the prose block, which stays
# the canonical shape. A result without details.cancelled, or a cancelled one (Esc), is
# never converted into an answer: it exits 4, so nothing is recorded.
#
# Exit codes: 0=ok, 2=invalid card or the dialog cannot represent it, 4=unusable result
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required but not found in PATH" >&2
  exit 2
fi

IFS= read -r -d '' PY_PROG <<'PY' || true
import hashlib, json, os, subprocess, sys

MAX_OPTIONS = 4
HEADER_MAX = 16
MARK = "(recommended)"
CTX = "Context: "
FREE_MAX = 200
RESERVED = ("Other", "Type something.", "Next")


class Invalid(Exception):
    pass


class Unusable(Exception):
    pass


def printable(s):
    return all(0x20 <= ord(c) <= 0x7e for c in s)


def header_for(title):
    head = title[:HEADER_MAX].rstrip()
    if len(title) > HEADER_MAX and " " in head:
        head = head[:head.rfind(" ")].rstrip() or title[:HEADER_MAX]
    return head or title[:1]


def question_for(card, findings):
    lines = [card["question"]]
    for code, finding in findings:
        lines.append("F%d - %s %s" % (code, finding["id"], finding["text"]))
    if card.get("context"):
        lines.append(CTX + card["context"])
    snapshot = json.dumps(card, sort_keys=True, separators=(",", ":"))
    fingerprint = hashlib.sha256(snapshot.encode("utf-8")).hexdigest()[:24]
    lines.append("Decision: %s (snapshot: %s)" % (card["id"], fingerprint))
    return "\n".join(lines)


def check_labels(card, where):
    seen = set()
    for option in card["options"]:
        label = option["label"]
        if label in RESERVED:
            raise Invalid("%s option label '%s' is a reserved dialog label (%s)" % (where, label, ", ".join(RESERVED)))
        if label in seen:
            raise Invalid("%s two options share the label '%s', which the dialog cannot resolve" % (where, label))
        seen.add(label)


def option_rows(chunk, default_id):
    rows = []
    for option in chunk:
        label = option["label"]
        description = option.get("description") or ""
        if option["id"] == default_id:
            description = description + " " + MARK if description else MARK
        rows.append({"label": label, "description": description})
    return rows


def build(cards):
    """Return (dialogs, origin); origin[d] = the card index behind dialog d."""
    dialogs, origin = [], []
    finding_code = 0
    for index, card in enumerate(cards):
        where = "card %d:" % (index + 1) if len(cards) > 1 else "card:"
        findings = [(finding_code + n, f) for n, f in enumerate(card.get("findings") or [], 1)]
        finding_code += len(findings)
        check_labels(card, where)
        if len(card["options"]) > MAX_OPTIONS:
            raise Invalid("%s card '%s' has %d options and needs more than one dialog question; "
                          "this mapping never splits a card, so the prose block stays authoritative"
                          % (where, card["id"], len(card["options"])))
        dialogs.append({"questions": [{
            "question": question_for(card, findings),
            "header": header_for(card["title"]),
            "options": option_rows(card["options"], card["default_option_id"]),
        }]})
        origin.append(index)
    return dialogs, origin


def result_answer(payload, number):
    """Read one dialog's whole tool result; nothing else can prove it was not cancelled."""
    if not isinstance(payload, dict):
        raise Unusable("--result must be the whole tool result object with details.answers, not a bare answers array")
    details = payload.get("details")
    if not isinstance(details, dict):
        raise Unusable("--result must be the whole tool result: details is missing, so cancellation cannot be ruled out")
    cancelled = details.get("cancelled")
    if not isinstance(cancelled, bool):
        raise Unusable("--result must be the whole tool result: details.cancelled is missing, so cancellation cannot be ruled out")
    if cancelled:
        raise Unusable("the dialog was cancelled; Esc never records a decision")
    answers = details.get("answers")
    if not isinstance(answers, list):
        raise Unusable("--result must be the whole tool result: details.answers is missing")
    if not answers:
        raise Unusable("the result carries no answer for decision D%d" % number)
    if len(answers) > 1:
        raise Unusable("decision D%d was answered more than once across the dialogs; answer one" % number)
    return answers[0]


def answer_text(cards, pairs):
    """Merge the dialogs of one or more cards into exactly one fragment per decision."""
    dialogs, origin = build(cards)
    pieces, answered = [], set()
    for dialog_index, payload in pairs:
        if dialog_index < 1 or dialog_index > len(dialogs):
            raise Invalid("--dialog %d is out of range: the card renders %d dialog(s)" % (dialog_index, len(dialogs)))
        card_index = origin[dialog_index - 1]
        card, number = cards[card_index], card_index + 1
        answer = result_answer(payload, number)
        if not isinstance(answer, dict):
            raise Unusable("each answer must be an object")
        position = answer.get("questionIndex")
        if not isinstance(position, int) or isinstance(position, bool) or position != 0:
            raise Unusable("questionIndex %r is not a question of dialog %d" % (position, dialog_index))
        if card_index in answered:
            raise Unusable("decision D%d was answered more than once across the dialogs; answer one" % number)
        if answer.get("question") != dialogs[dialog_index - 1]["questions"][position]["question"]:
            raise Unusable("the returned question does not match dialog %d's card snapshot" % dialog_index)
        answered.add(card_index)
        kind = answer.get("kind")
        if kind == "option":
            label = answer.get("answer")
            if not isinstance(label, str):
                raise Unusable("an option answer must name the chosen label as a string")
            match = [n for n, option in enumerate(card["options"]) if option["label"] == label]
            if len(match) != 1:
                raise Unusable("option answer %r does not name exactly one option of dialog %d" % (label, dialog_index))
            pieces.append("d%d o%d" % (number, match[0] + 1))
        elif kind == "custom":
            text = answer.get("answer")
            if not isinstance(text, str):
                raise Unusable("a custom answer must carry the typed text as a string")
            if not text.strip() or not printable(text) or "\\" in text or '"' in text or len(text) > FREE_MAX:
                raise Unusable("free text must be 1-%d printable ASCII characters without backslashes or double quotes" % FREE_MAX)
            pieces.append('d%d o0 "%s"' % (number, text))
        else:
            raise Unusable("unsupported answer kind %r: this mapping never authors a multi-select question" % (kind,))
    return " ".join(pieces)


def canonical_check(ask, raw, *args):
    return subprocess.run([ask, *args], input=raw, stdout=subprocess.DEVNULL,
                          stderr=subprocess.PIPE)


def main():
    ask = os.path.join(sys.argv[1], "sq-ask.sh")
    mode = sys.argv[2]
    raw = sys.stdin.buffer.read()
    validation = canonical_check(ask, raw, "--validate")
    if validation.returncode:
        sys.stderr.buffer.write(validation.stderr or b"error: invalid card\n")
        sys.exit(2)
    data = json.loads(raw.decode("utf-8"))
    cards = data if isinstance(data, list) else [data]
    for card in cards:
        if len(card["options"]) < 2:
            raise Invalid("a card needs at least 2 options for a dialog question; card '%s' has %d" % (card["id"], len(card["options"])))
    if mode == "payload":
        for card in cards:
            if not card.get("allow_free_text", True):
                raise Invalid("card '%s' has allow_free_text=false; the dialog always shows a free-text row"
                              % card["id"])
            for option in card["options"]:
                description = (option.get("description") or "").rstrip()
                if not description:
                    raise Invalid("card '%s' option '%s' requires a non-blank description for the dialog"
                                  % (card["id"], option["id"]))
                for field, text in (("label", option["label"].rstrip()), ("description", description)):
                    if text.endswith(MARK):
                        raise Invalid("card '%s' option '%s' %s may not end with %s after trimming trailing whitespace"
                                      % (card["id"], option["id"], field, MARK))
        print(json.dumps(build(cards)[0]))
    elif mode in ("answer", "resolve"):
        args = sys.argv[3:]
        if not args or len(args) % 2:
            raise Invalid("--%s needs one --dialog <n> and one --result <json> per answered dialog" % mode)
        pairs = []
        for offset in range(0, len(args), 2):
            index = args[offset]
            try:
                number = int(index) if index.isascii() and index.isdigit() else 0
            except ValueError:
                number = 0
            if number < 1:
                raise Invalid("--dialog needs a positive dialog number")
            try:
                payload = json.loads(args[offset + 1])
            except ValueError:
                raise Unusable("--result is not valid JSON")
            pairs.append((number, payload))
        fragment = answer_text(cards, pairs)
        if mode == "resolve":
            sys.exit(subprocess.run([ask, "--answer", fragment], input=raw).returncode)
        validation = canonical_check(ask, raw, "--answer", fragment)
        if validation.returncode:
            message = validation.stderr.decode("utf-8", errors="replace").strip()
            if len(pairs) > 1:
                message += "\nFor oversized batches, retry with fewer dialogs per call using the same cards."
            raise Unusable(message or "the canonical parser rejected the answer")
        print(fragment)
    else:
        raise Invalid("unknown mode")


try:
    main()
except Invalid as e:
    sys.stderr.write("error: %s\n" % e)
    sys.exit(2)
except Unusable as e:
    sys.stderr.write("error: unusable result: %s\n" % e)
    sys.exit(4)
PY

run_py() { python3 -I -c "$PY_PROG" "$SCRIPT_DIR" "$@"; }

die() {
  local code=$1; shift
  echo "error: $*" >&2
  exit "$code"
}

# --- defaults ---
MODE="payload"
DIALOGS=()
RESULTS=()
POSITIONAL=()

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --payload) MODE="payload"; shift ;;
    --answer) MODE="answer"; shift ;;
    --resolve) MODE="resolve"; shift ;;
    --dialog) [[ $# -ge 2 ]] || die 2 "--dialog needs a value"; DIALOGS+=("$2"); shift 2 ;;
    --dialog=*) DIALOGS+=("${1#--dialog=}"); shift ;;
    --result) [[ $# -ge 2 ]] || die 2 "--result needs a value"; RESULTS+=("$2"); shift 2 ;;
    --result=*) RESULTS+=("${1#--result=}"); shift ;;
    --help)
      sed -n '2,/^set -eu/p' "$0" | sed '$d' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    --) shift; POSITIONAL+=("$@"); break ;;
    -*) die 2 "unknown option: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ ${#POSITIONAL[@]} -gt 1 ]]; then
  die 2 "unexpected argument: ${POSITIONAL[1]} (the card is the only positional argument)"
fi

PAIRS=()
if [[ "$MODE" == answer || "$MODE" == resolve ]]; then
  [[ ${#DIALOGS[@]} -gt 0 ]] || die 2 "--$MODE needs --dialog <n> and --result <json>"
  [[ ${#DIALOGS[@]} -eq ${#RESULTS[@]} ]] || die 2 "--$MODE needs one --result <json> for every --dialog <n>"
  for i in "${!DIALOGS[@]}"; do
    PAIRS+=("${DIALOGS[$i]}" "${RESULTS[$i]}")
  done
fi

if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  printf '%s' "${POSITIONAL[0]}" | run_py "$MODE" ${PAIRS[@]+"${PAIRS[@]}"}
elif [[ -t 0 ]]; then
  die 2 "no decision card JSON on stdin or as argument"
else
  run_py "$MODE" ${PAIRS[@]+"${PAIRS[@]}"}
fi
