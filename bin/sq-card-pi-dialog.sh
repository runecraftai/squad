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
#        echo '<card json>' | bin/sq-card-pi-dialog.sh --answer --dialog 1 --result '<tool result json>' \
#          [--dialog 2 --result '<tool result json>' ...]
#
# Input is one card object or a JSON array of cards, validated first by
# bin/sq-ask.sh --validate so the schema keeps exactly one owner.
#
# Modes:
#   --payload      Print the ask_user_question payload(s) as a JSON array, one entry
#                  per dialog, in card order; each entry is one tool call. The default.
#   --answer       Read the extension's result for the dialog named by --dialog and
#                  print the answer text for bin/sq-ask.sh --answer, such as
#                  "d1 o2" or 'd1 o0 "ship it"'. Repeat --dialog/--result to answer
#                  several dialogs of the same card in one call; the pairs are merged.
#                  --result takes the whole tool result, never a bare answers array:
#                  only details.cancelled proves the dialog was not cancelled.
#   --help         Show this help.
#
# Mapping (card -> dialog):
#   question      -> questions[].question, then one "F<n> - <id> <text>" line per finding
#                    and finally one "Context: <context>" line when the card has context.
#                    The published payload has no notes field, so context and findings
#                    ride in the question text rather than being dropped.
#   title         -> questions[].header, cut to the 16-character payload limit; a split
#                    question carries "<k>/<n>" inside the same 16 characters
#   label         -> options[].label, unchanged
#   description   -> options[].description; the recommended option gains a trailing
#                    " (recommended)", so the recommendation is visible on its own row
#   free text     -> the dialog's own free-text row; the mapping authors no option for it
#
# Splits, never truncation: a dialog carries 1-4 questions and a question 2-4 options.
# More than four options on one card become several questions, balanced and in card
# order (5 -> 3+2, 6 -> 3+3, 9 -> 3+3+3), and more than four questions on one card
# become several dialogs. Every card option is carried, in order, exactly once.
#
# Answers of a split card keep the card's own global option numbering, so a value the
# commander picks in the last dialog is still the card's real option code (d1 o15 stays
# d1 o15). Answering one dialog and answering another are therefore merged into exactly
# one fragment per decision, mechanically: no fold, no renumbering, no guessed pick.
# Two answers for the same decision across dialogs exit 4 instead of choosing one.
#
# Refused, because the dialog cannot show that card without dropping or misrepresenting
# an option: an option label that is a reserved dialog label ("Other", "Type something.",
# "Next"), a label shared by two options of the card, and a card with a single option.
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

# One fixed program. The card arrives on stdin and the result payload in an
# environment variable; nothing from either is interpolated into program text.
IFS= read -r -d '' PY_PROG <<'PY' || true
import sys, json

MAX_QUESTIONS = 4
MAX_OPTIONS = 4
HEADER_MAX = 16
MARK = " (recommended)"
CTX = "Context: "
FREE_MAX = 200
RESERVED = ("Other", "Type something.", "Next")


class Invalid(Exception):
    pass


class Unusable(Exception):
    pass


def printable(s):
    return all(0x20 <= ord(c) <= 0x7e for c in s)


def chunk_sizes(total):
    """Split <total> options into the fewest questions, balanced, 2-4 each."""
    groups = (total + MAX_OPTIONS - 1) // MAX_OPTIONS
    base, extra = divmod(total, groups)
    return [base + (1 if i < extra else 0) for i in range(groups)]


def header_for(title, part, parts):
    suffix = " %d/%d" % (part, parts) if parts > 1 else ""
    keep = HEADER_MAX - len(suffix)
    head = title[:keep].rstrip()
    if len(title) > keep and " " in head:
        head = head[:head.rfind(" ")].rstrip() or title[:keep]
    return (head or title[:1]) + suffix


def question_for(card, part, parts, findings):
    text = card["question"]
    if parts > 1:
        text = "%s (part %d of %d)" % (text, part, parts)
    lines = [text]
    for code, finding in findings:
        lines.append("F%d - %s %s" % (code, finding["id"], finding["text"]))
    if card.get("context"):
        lines.append(CTX + card["context"])
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
            description = description + MARK if description else MARK.strip()
        rows.append({"label": label, "description": description})
    return rows


def build(cards):
    """Return (dialogs, origin); origin[d][q] = (card index, first option index, size)."""
    dialogs, origin = [], []
    finding_code = 0
    for index, card in enumerate(cards):
        where = "card %d:" % (index + 1) if len(cards) > 1 else "card:"
        findings = [(finding_code + n, f) for n, f in enumerate(card.get("findings") or [], 1)]
        finding_code += len(findings)
        check_labels(card, where)
        sizes = chunk_sizes(len(card["options"]))
        questions, slots, start = [], [], 0
        for part, size in enumerate(sizes, 1):
            questions.append({
                "question": question_for(card, part, len(sizes), findings if part == 1 else []),
                "header": header_for(card["title"], part, len(sizes)),
                "options": option_rows(card["options"][start:start + size], card["default_option_id"]),
            })
            slots.append((index, start, size))
            start += size
        for offset in range(0, len(questions), MAX_QUESTIONS):
            end = min(offset + MAX_QUESTIONS, len(questions))
            dialogs.append({"questions": questions[offset:end]})
            origin.append(slots[offset:end])
    return dialogs, origin


def result_answers(payload):
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
    return answers


def answer_text(cards, pairs):
    """Merge one or more dialogs of the same card into exactly one fragment per decision."""
    dialogs, origin = build(cards)
    pieces, answered = [], set()
    for dialog_index, payload in pairs:
        if dialog_index < 1 or dialog_index > len(dialogs):
            raise Invalid("--dialog %d is out of range: the card renders %d dialog(s)" % (dialog_index, len(dialogs)))
        slots = origin[dialog_index - 1]
        for answer in result_answers(payload):
            if not isinstance(answer, dict):
                raise Unusable("each answer must be an object")
            position = answer.get("questionIndex")
            if not isinstance(position, int) or isinstance(position, bool) or not 0 <= position < len(slots):
                raise Unusable("questionIndex %r is not a question of dialog %d" % (position, dialog_index))
            card_index, start, size = slots[position]
            card, number = cards[card_index], card_index + 1
            if card_index in answered:
                raise Unusable("decision D%d was answered more than once across the dialogs; answer one" % number)
            answered.add(card_index)
            kind = answer.get("kind")
            if kind == "option":
                label = answer.get("answer")
                if not isinstance(label, str):
                    raise Unusable("an option answer must name the chosen label as a string")
                match = [n for n, option in enumerate(card["options"]) if option["label"] == label]
                if len(match) != 1 or not start <= match[0] < start + size:
                    raise Unusable("option answer %r does not name exactly one option of dialog question %d" % (label, position + 1))
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
    if not answered:
        raise Unusable("the result carries no answer")
    return " ".join(pieces)


def main():
    mode = sys.argv[1]
    try:
        raw = sys.stdin.buffer.read().decode("utf-8")
    except UnicodeDecodeError:
        raise Invalid("the card is not valid UTF-8")
    try:
        data = json.loads(raw)
    except ValueError:
        raise Invalid("invalid card JSON")
    cards = data if isinstance(data, list) else [data]
    if not cards:
        raise Invalid("empty card array: need at least one card")
    for card in cards:
        if len(card["options"]) < 2:
            raise Invalid("a card needs at least 2 options for a dialog question; card '%s' has %d" % (card["id"], len(card["options"])))
    if mode == "payload":
        print(json.dumps(build(cards)[0]))
    elif mode == "answer":
        args = sys.argv[2:]
        if not args or len(args) % 2:
            raise Invalid("--answer needs one --dialog <n> and one --result <json> per answered dialog")
        pairs = []
        for offset in range(0, len(args), 2):
            index = args[offset]
            if not index.isdigit() or int(index) < 1:
                raise Invalid("--dialog needs a positive dialog number")
            try:
                payload = json.loads(args[offset + 1])
            except ValueError:
                raise Unusable("--result is not valid JSON")
            pairs.append((int(index), payload))
        print(answer_text(cards, pairs))
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

run_py() { python3 -I -c "$PY_PROG" "$@"; }

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
    --dialog) [[ $# -ge 2 ]] || die 2 "--dialog needs a value"; DIALOGS+=("$2"); shift 2 ;;
    --dialog=*) DIALOGS+=("${1#--dialog=}"); shift ;;
    --result) [[ $# -ge 2 ]] || die 2 "--result needs a value"; RESULTS+=("$2"); shift 2 ;;
    --result=*) RESULTS+=("${1#--result=}"); shift ;;
    --help)
      sed -n '2,/^set -eu/p' "$0" | head -n -1 | sed 's/^# //' | sed 's/^#//'
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

# --- read the card from the positional argument or stdin ---
if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
  CARD="${POSITIONAL[0]}"
elif [[ -t 0 ]]; then
  die 2 "no decision card JSON on stdin or as argument"
else
  CARD=$(cat)
fi
[[ -n "$CARD" ]] || die 2 "the card JSON is empty"

# The card schema has one owner: validate through its renderer/parser first.
if ! VALIDATION=$(printf '%s' "$CARD" | "$SCRIPT_DIR/sq-ask.sh" --validate 2>&1 >/dev/null); then
  printf '%s\n' "${VALIDATION:-error: invalid card}" >&2
  exit 2
fi

case "$MODE" in
  payload)
    printf '%s' "$CARD" | run_py payload
    ;;
  answer)
    [[ ${#DIALOGS[@]} -gt 0 ]] || die 2 "--answer needs --dialog <n> and --result <json>"
    [[ ${#DIALOGS[@]} -eq ${#RESULTS[@]} ]] || die 2 "--answer needs one --result <json> for every --dialog <n>"
    PAIRS=()
    for i in "${!DIALOGS[@]}"; do
      PAIRS+=("${DIALOGS[$i]}" "${RESULTS[$i]}")
    done
    printf '%s' "$CARD" | run_py answer "${PAIRS[@]}"
    ;;
esac
