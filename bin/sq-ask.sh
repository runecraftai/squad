#!/usr/bin/env bash
# Decision prose renderer, prose parser, answer parser, and opt-in terminal picker.
#
# The prose block (AGENTS.md section 9) is the only shape the commander reads or
# types. The JSON decision card is the internal payload behind it; its owner is
# docs/decision-card-standard.md. This script converts between the two.
#
# Usage: echo '{"version":1,...}' | bin/sq-ask.sh [options]
#        bin/sq-ask.sh '{"version":1,...}' [options]
#
# Input is one card object or a JSON array of cards (schema version stays 1).
#
# Options:
#   --render          Print the decision prose block(s) for the card(s) and exit.
#   --parse-card      Read prose block(s) on stdin, print card JSON, exit 2 if malformed.
#   --answer <text>   Parse the commander's answer against the card(s) and print the
#   --answer=<text>   result. Needs no terminal. The text after --answer is always the
#                     value, even when it starts with a dash. An empty answer is rejected.
#   --validate        Validate the card(s) and exit.
#   --format <fmt>    Output format for results: json (default), text, id.
#   --backend <tool>  Force picker backend: fzf, whiptail, dialog, bash, default.
#   --no-interactive  Exit 3 instead of falling back when no terminal is available.
#   --help            Show this help.
#
# Answer grammar (case-insensitive; "D1 O2" means option 2 of decision 1):
#   answer := pair { sep pair }
#   pair   := D<n> O<m> | D<n> O0 "free text" | O<m> | O0 "free text"
#   sep    := whitespace | , | ; | and
#   A bare O<m> is accepted only when exactly one decision is on screen.
#   A partial answer is accepted; unanswered decisions are named on stderr.
#   Free text is quoted, printable ASCII only (no backslash), 1-200 characters.
#   Everything else is rejected whole, never guessed: unknown D or O, O0 when the
#   card has no free text, a duplicate D, a D without its O, an unclosed quote,
#   trailing tokens, leading zeros, any non-ASCII or control character other than
#   the whitespace separators (tab, CR, LF), and input over 2000 characters. A rejection prints nothing on stdout and exits 4.
#
# Result object (JSON; an array of cards in gives an array out, one per answer):
#   {"decision_id":..,"selected_option_id":..,"selected_label":..,
#    "selected_payload":..,"free_text":..,"method":"picker|prose|free_text|default"}
#   A card's option payload is returned unchanged as selected_payload (null if absent).
#
# Picker: opt-in, for a human at a shell. It runs only when stdout is a terminal and
# no --answer, --render, --validate, or --parse-card flag is present. It handles one
# card (an array exits 2) and shows the same O<m> lines as the prose. It accepts a bare
# number, o<m>, Enter for the recommended option, and free text when the card allows it.
# With no terminal it falls back to the recommended option (method "default") and
# prints one stderr notice. Backend priority: fzf > whiptail > dialog > bash.
#
# Constants (one table, "LIT" and "LIM" in the embedded program below):
#   literals  (recommended)  Your own words  Context:  (ref:
#   ceilings  title 60, label 60, description 120, question 160, context 240,
#             finding 200, free text 200, answer 2000
#
# Exit codes: 0=ok, 1=cancelled, 2=invalid card or prose, 3=no terminal, 4=answer rejected
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required but not found in PATH" >&2
  exit 2
fi

# The whole renderer/parser/validator is one fixed program. Card and prose bytes
# reach it on stdin and the answer in an environment variable; nothing from the
# input is ever interpolated into the program text or a command string.
IFS= read -r -d '' PY_PROG <<'PY' || true
import sys, os, re, json

LIT = {"rec": "(recommended)", "own": "Your own words", "ctx": "Context:", "ref": "(ref:"}
LIM = {"title": 60, "label": 60, "description": 120, "question": 160,
       "context": 240, "finding": 200, "free": 200, "answer": 2000}
NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
ACTIONS = ("approve", "fix", "skip")


class Invalid(Exception):
    pass


class Rejected(Exception):
    pass


def printable(s):
    return all(0x20 <= ord(c) <= 0x7e for c in s)


def text_ok(name, s, limit, required=False):
    if not isinstance(s, str):
        raise Invalid("%s must be a string" % name)
    if required and not s.strip():
        raise Invalid("missing required field: %s" % name)
    if not printable(s):
        raise Invalid("%s must be one line of printable ASCII" % name)
    if len(s) > limit:
        raise Invalid("%s is over %d characters" % (name, limit))


def payload_walk(v, where):
    if isinstance(v, str):
        if not printable(v):
            raise Invalid("%s has a non-printable or non-ASCII character" % where)
    elif isinstance(v, dict):
        for k, x in v.items():
            payload_walk(k, where)
            payload_walk(x, where)
    elif isinstance(v, list):
        for x in v:
            payload_walk(x, where)


def check_card(c, where):
    if not isinstance(c, dict):
        raise Invalid("%scard must be a JSON object" % where)
    ver = c.get("version", 0)
    if isinstance(ver, bool) or ver != 1:
        raise Invalid("%sunsupported schema version: %s (expected 1)" % (where, ver))
    for f in ("id", "title", "question", "default_option_id"):
        if not c.get(f):
            raise Invalid("%smissing required field: %s" % (where, f))
    if not isinstance(c["id"], str) or not NAME_RE.match(c["id"]):
        raise Invalid("%sid must match [A-Za-z0-9._-] and be at most 64 characters" % where)
    text_ok("title", c["title"], LIM["title"], True)
    text_ok("question", c["question"], LIM["question"], True)
    if "(ref:" in c["title"]:
        raise Invalid("%stitle may not contain %s" % (where, LIT["ref"]))
    if c["question"].startswith(LIT["ctx"] + " "):
        raise Invalid("%squestion may not start with %s" % (where, LIT["ctx"]))
    if re.match(r"^[DOF][0-9]+ - ", c["question"]):
        raise Invalid("%squestion may not look like a prose code line" % where)
    if c.get("context") is not None:
        text_ok("context", c["context"], LIM["context"])
    if "allow_free_text" in c and not isinstance(c["allow_free_text"], bool):
        raise Invalid("%sallow_free_text must be a boolean" % where)
    meta = c.get("metadata") or {}
    if not isinstance(meta, dict):
        raise Invalid("%smetadata must be an object" % where)
    key = meta.get("key")
    if key is not None:
        if not isinstance(key, str) or not NAME_RE.match(key):
            raise Invalid("%smetadata.key must match [A-Za-z0-9._-] and be 1-64 characters" % where)
        if key == "default":
            raise Invalid("%smetadata.key 'default' is reserved" % where)
        if c["id"] != key:
            raise Invalid("%sid must equal metadata.key for a keyed decision" % where)
    fl = c.get("findings")
    if fl is not None:
        if not isinstance(fl, list):
            raise Invalid("%sfindings must be an array" % where)
        fids = []
        for f in fl:
            if not isinstance(f, dict) or not isinstance(f.get("id"), str) or not NAME_RE.match(f["id"]):
                raise Invalid("%seach finding needs an id matching [A-Za-z0-9._-]" % where)
            text_ok("finding text", f.get("text", ""), LIM["finding"], True)
            fids.append(f["id"])
        if len(fids) != len(set(fids)):
            raise Invalid("%sfinding ids must be unique" % where)
    opts = c.get("options")
    if not isinstance(opts, list) or len(opts) < 1:
        raise Invalid("%smust have at least 1 option" % where)
    ids = []
    for i, o in enumerate(opts, 1):
        if not isinstance(o, dict):
            raise Invalid("%soption %d must be an object" % (where, i))
        oid = o.get("id")
        if not isinstance(oid, str) or not NAME_RE.match(oid):
            raise Invalid("%soption %d id must match [A-Za-z0-9._-]" % (where, i))
        ids.append(oid)
        lab = o.get("label", "")
        if not lab:
            raise Invalid("%sall options must have non-empty labels" % where)
        text_ok("option %d label" % i, lab, LIM["label"], True)
        if "|" in lab or ": " in lab or "[key=" in lab or re.search(r"[A-Za-z][A-Za-z0-9_-]*:", lab):
            raise Invalid("%soption %d label may not contain '|', ': ', '[key=', or a 'word:' pattern" % (where, i))
        if lab.endswith(LIT["rec"]):
            raise Invalid("%soption %d label may not end with %s" % (where, i, LIT["rec"]))
        if o.get("description") is not None:
            text_ok("option %d description" % i, o["description"], LIM["description"])
            if o["description"].endswith(LIT["rec"]):
                raise Invalid("%soption %d description may not end with %s" % (where, i, LIT["rec"]))
        if "recommended" in o and not isinstance(o["recommended"], bool):
            raise Invalid("%soption %d recommended must be a boolean" % (where, i))
        if o.get("recommended") and oid != c["default_option_id"]:
            raise Invalid("%srecommended is allowed only on the default option" % where)
        if "payload" in o:
            check_payload(o["payload"], "%soption %d payload" % (where, i), c)
    if len(ids) != len(set(ids)):
        raise Invalid("%soption ids must be unique" % where)
    if c["default_option_id"] not in ids:
        raise Invalid("%sdefault_option_id '%s' not found in options" % (where, c["default_option_id"]))


def check_payload(p, where, card):
    if not isinstance(p, dict):
        raise Invalid("%s must be an object" % where)
    payload_walk(p, where)
    if "action" in p and p["action"] not in ACTIONS:
        raise Invalid("%s.action must be one of approve, fix, skip" % where)
    if "step" in p and (not isinstance(p["step"], str) or not NAME_RE.match(p["step"])):
        raise Invalid("%s.step must match [A-Za-z0-9._-]" % where)
    if "findings" in p:
        fl = p["findings"]
        known = [f.get("id") for f in (card.get("findings") or []) if isinstance(f, dict)]
        if not isinstance(fl, list):
            raise Invalid("%s.findings must be an array" % where)
        for fid in fl:
            if not isinstance(fid, str) or not NAME_RE.match(fid):
                raise Invalid("%s.findings ids must match [A-Za-z0-9._-]" % where)
            if fid not in known:
                raise Invalid("%s.findings id '%s' is not in the card's findings" % (where, fid))


def load_cards(raw):
    try:
        data = json.loads(raw)
    except ValueError:
        raise Invalid("invalid JSON")
    is_array = isinstance(data, list)
    cards = data if is_array else [data]
    if not cards:
        raise Invalid("empty array: need at least one card")
    for n, c in enumerate(cards, 1):
        check_card(c, ("card %d: " % n) if is_array else "")
    check_unique(cards)
    return cards, is_array


def check_unique(cards):
    ids = [c["id"] for c in cards]
    keys = [(c.get("metadata") or {}).get("key") for c in cards if (c.get("metadata") or {}).get("key")]
    if len(ids) != len(set(ids)):
        raise Invalid("card ids must be unique across the array")
    if len(keys) != len(set(keys)):
        raise Invalid("card keys must be unique across the array")


def key_of(c):
    return (c.get("metadata") or {}).get("key")


def option_line(m, o, default_id):
    line = "  O%d - %s" % (m, o["label"])
    if o.get("description"):
        line += ": " + o["description"]
    if o["id"] == default_id:
        line += " " + LIT["rec"]
    return line


def render(cards):
    out = []
    fn = 0
    for n, c in enumerate(cards, 1):
        if n > 1:
            out.append("")
        fl = c.get("findings") or []
        for f in fl:
            fn += 1
            out.append("F%d - %s %s" % (fn, f["id"], f["text"]))
        if fl:
            out.append("")
        head = "D%d - %s" % (n, c["title"])
        if key_of(c):
            head += " %s %s)" % (LIT["ref"], key_of(c))
        out.append(head)
        if c["question"] != c["title"]:
            out.append("  " + c["question"])
        if c.get("context"):
            out.append("  %s %s" % (LIT["ctx"], c["context"]))
        for m, o in enumerate(c["options"], 1):
            out.append(option_line(m, o, c["default_option_id"]))
        if c.get("allow_free_text", True):
            out.append("  O0 - " + LIT["own"])
    return out


def slug(s, taken, fallback):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40].strip("-") or fallback
    base, n = s, 1
    while s in taken:
        n += 1
        s = "%s-%d" % (base, n)
    taken.add(s)
    return s


def parse_prose(text):
    cards, findings = [], []
    cur = None
    state = None
    taken_ids = set()
    expect_d, expect_f = 1, 1

    def finish():
        if cur is None:
            return
        if not cur["options"]:
            raise Invalid("decision D%d has no options" % cur["_n"])
        if cur["_rec"] is None:
            raise Invalid("decision D%d needs exactly one %s option" % (cur["_n"], LIT["rec"]))
        cur.pop("_n")
        cur.pop("_rec")
        cards.append(cur)

    for ln, line in enumerate(text.split("\n"), 1):
        line = line.rstrip("\r")
        if not line.strip():
            continue
        m = re.match(r"^F([1-9][0-9]*) - (\S+) (.+)$", line)
        if m:
            if int(m.group(1)) != expect_f:
                raise Invalid("line %d: finding codes must be consecutive from F1" % ln)
            expect_f += 1
            findings.append({"id": m.group(2), "text": m.group(3)})
            continue
        m = re.match(r"^D([1-9][0-9]*) - (.+)$", line)
        if m:
            finish()
            if int(m.group(1)) != expect_d:
                raise Invalid("line %d: decision codes must be consecutive from D1" % ln)
            expect_d += 1
            title, key = m.group(2), None
            r = re.match(r"^(.*) \(ref: ([A-Za-z0-9._-]{1,64})\)$", title)
            if r:
                title, key = r.group(1), r.group(2)
            cid = key or slug(title, taken_ids, "decision")
            taken_ids.add(cid)
            cur = {"version": 1, "id": cid, "title": title, "question": title,
                   "options": [], "default_option_id": None, "allow_free_text": False,
                   "_n": int(m.group(1)), "_rec": None}
            if key:
                cur["metadata"] = {"key": key}
            if findings:
                cur["findings"] = findings
                findings = []
            state = "head"
            continue
        if cur is None or not line.startswith("  "):
            raise Invalid("line %d: not part of a decision block" % ln)
        body = line[2:]
        if body.startswith(LIT["ctx"] + " "):
            if state != "head" and state != "question":
                raise Invalid("line %d: context must follow the title or question" % ln)
            cur["context"] = body[len(LIT["ctx"]) + 1:]
            state = "context"
            continue
        m = re.match(r"^O(0|[1-9][0-9]*) - (.+)$", body)
        if m:
            if state == "own":
                raise Invalid("line %d: nothing may follow the free-text line" % ln)
            if m.group(1) == "0":
                if m.group(2) != LIT["own"]:
                    raise Invalid("line %d: O0 must read '%s'" % (ln, LIT["own"]))
                cur["allow_free_text"] = True
                state = "own"
                continue
            if int(m.group(1)) != len(cur["options"]) + 1:
                raise Invalid("line %d: option codes must be consecutive from O1" % ln)
            rest, rec = m.group(2), False
            if rest.endswith(" " + LIT["rec"]):
                rest, rec = rest[: -len(LIT["rec"]) - 1], True
            label, _, desc = rest.partition(": ")
            oid = slug(label, {o["id"] for o in cur["options"]}, "option")
            o = {"id": oid, "label": label}
            if desc:
                o["description"] = desc
            cur["options"].append(o)
            if rec:
                if cur["_rec"] is not None:
                    raise Invalid("line %d: more than one %s option" % (ln, LIT["rec"]))
                cur["_rec"] = oid
                cur["default_option_id"] = oid
            state = "options"
            continue
        if state != "head":
            raise Invalid("line %d: unexpected line inside a decision block" % ln)
        cur["question"] = body
        state = "question"
    finish()
    if not cards:
        raise Invalid("no decision block found")
    if findings:
        raise Invalid("findings without a following decision block")
    for c in cards:
        if c["default_option_id"] is None:
            raise Invalid("a decision has no %s option" % LIT["rec"])
    return cards


def tokenize(s):
    if not s.strip():
        raise Rejected("empty answer")
    if len(s) > LIM["answer"]:
        raise Rejected("answer is over %d characters" % LIM["answer"])
    for c in s:
        if not (printable(c) or c in "\t\r\n"):
            raise Rejected("non-ASCII or control character in the answer")
    toks, i, n = [], 0, len(s)
    word = re.compile(r"[A-Za-z0-9]+")
    while i < n:
        ch = s[i]
        if ch in " \t\r\n,;":
            i += 1
        elif ch == '"':
            j = s.find('"', i + 1)
            if j < 0:
                raise Rejected("unterminated quote")
            body = s[i + 1:j]
            if not printable(body) or "\\" in body:
                raise Rejected("free text must be printable ASCII without backslashes")
            if not body.strip():
                raise Rejected("empty free text")
            if len(body) > LIM["free"]:
                raise Rejected("free text is over %d characters" % LIM["free"])
            toks.append(("q", body))
            i = j + 1
        else:
            m = word.match(s, i)
            if not m:
                raise Rejected("unexpected character '%s'" % ch)
            toks.append(("w", m.group(0).lower()))
            i = m.end()
    return toks


def parse_answer(s, cards):
    toks = tokenize(s)
    pairs, k = [], 0
    while k < len(toks):
        kind, val = toks[k]
        if kind == "q":
            raise Rejected("quoted text without an O0 before it")
        if val == "and":
            if not pairs or k + 1 >= len(toks) or toks[k + 1] == ("w", "and"):
                raise Rejected("misplaced 'and'")
            k += 1
            continue
        d = None
        m = re.fullmatch(r"d([1-9][0-9]*)", val)
        if m:
            d = int(m.group(1))
            k += 1
            if k >= len(toks) or toks[k][0] != "w" or not re.fullmatch(r"o[0-9]+", toks[k][1]):
                raise Rejected("decision D%d has no option" % d)
            val = toks[k][1]
        mo = re.fullmatch(r"o(0|[1-9][0-9]*)", val)
        if not mo:
            raise Rejected("unknown token '%s'" % val)
        o = int(mo.group(1))
        k += 1
        text = None
        if o == 0:
            if k >= len(toks) or toks[k][0] != "q":
                raise Rejected("O0 needs the free text in double quotes")
            text = toks[k][1]
            k += 1
        pairs.append((d, o, text))
    if not pairs:
        raise Rejected("the answer names no decision or option")
    if any(d is None for d, _, _ in pairs):
        if len(cards) != 1 or len(pairs) != 1:
            raise Rejected("a bare option needs exactly one decision on screen")
        pairs = [(1, pairs[0][1], pairs[0][2])]
    seen = set()
    for d, o, text in pairs:
        if d in seen:
            raise Rejected("decision D%d answered twice" % d)
        seen.add(d)
        if d > len(cards):
            raise Rejected("unknown decision D%d" % d)
        c = cards[d - 1]
        if o == 0:
            if not c.get("allow_free_text", True):
                raise Rejected("decision D%d does not take free text" % d)
        elif o > len(c["options"]):
            raise Rejected("decision D%d has no option O%d" % (d, o))
    return sorted(pairs, key=lambda p: p[0])


def result(c, o, text, method):
    if o == 0:
        return {"decision_id": key_of(c) or c["id"], "selected_option_id": None,
                "selected_label": None, "selected_payload": None,
                "free_text": text, "method": "free_text"}
    opt = c["options"][o - 1]
    return {"decision_id": key_of(c) or c["id"], "selected_option_id": opt["id"],
            "selected_label": opt["label"], "selected_payload": opt.get("payload"),
            "free_text": None, "method": method}


def default_index(c):
    for m, o in enumerate(c["options"], 1):
        if o["id"] == c["default_option_id"]:
            return m
    return 1


def emit(results, is_array, fmt):
    if fmt == "json":
        print(json.dumps(results if is_array else results[0]))
    else:
        for r in results:
            if r["free_text"] is not None:
                print(r["free_text"])
            elif fmt == "text":
                print(r["selected_label"])
            else:
                print(r["selected_option_id"])


def pick_free(text):
    if not text.strip() or not printable(text) or "\\" in text or len(text) > LIM["free"]:
        raise Rejected("free text must be 1-%d printable ASCII characters without backslashes" % LIM["free"])
    return text


def main():
    mode = sys.argv[1]
    fmt = os.environ.get("SQ_ASK_FORMAT", "json")
    try:
        raw = sys.stdin.buffer.read().decode("utf-8")
    except UnicodeDecodeError:
        raise Invalid("input is not valid UTF-8")
    if mode == "parse-card":
        cards = parse_prose(raw)
        for n, c in enumerate(cards, 1):
            check_card(c, "D%d: " % n)
        check_unique(cards)
        print(json.dumps(cards if len(cards) > 1 else cards[0]))
        return
    cards, is_array = load_cards(raw)
    if mode == "validate":
        print("valid")
    elif mode == "render":
        print("\n".join(render(cards)))
    elif mode == "answer":
        pairs = parse_answer(os.environ.get("SQ_ASK_ANSWER", ""), cards)
        emit([result(cards[d - 1], o, t, "prose") for d, o, t in pairs], is_array, fmt)
        left = [("D%d" % n) for n in range(1, len(cards) + 1) if n not in [p[0] for p in pairs]]
        if left:
            sys.stderr.write("notice: unanswered decisions stay open: %s\n" % ", ".join(left))
    elif mode == "defaults":
        emit([result(c, default_index(c), None, "default") for c in cards], is_array, fmt)
    elif mode == "pick-info":
        if is_array:
            raise Invalid("the picker handles one card; use --render and --answer for several")
        c = cards[0]
        lines = render(cards)
        opts = [option_line(m, o, c["default_option_id"]).strip() for m, o in enumerate(c["options"], 1)]
        info = [c["title"], c["question"], c.get("context") or "",
                "1" if c.get("allow_free_text", True) else "0",
                str(default_index(c)), str(len(opts))]
        print("\n".join(info + opts + [o["label"] for o in c["options"]] + lines))
    elif mode == "pick-result":
        c = cards[0]
        kind, val = os.environ.get("SQ_ASK_KIND", ""), os.environ.get("SQ_ASK_VALUE", "")
        if kind == "default":
            emit([result(c, default_index(c), None, "default")], False, fmt)
        elif kind == "index":
            o = int(val)
            if o < 1 or o > len(c["options"]):
                raise Rejected("no option O%s" % val)
            emit([result(c, o, None, "picker")], False, fmt)
        elif kind == "free":
            if not c.get("allow_free_text", True):
                raise Rejected("decision does not take free text")
            if not val.strip():
                emit([result(c, default_index(c), None, "picker")], False, fmt)
            else:
                emit([result(c, 0, pick_free(val), "picker")], False, fmt)
        elif kind == "line":
            try:
                pairs = parse_answer(val, cards)
                d, o, t = pairs[0]
                emit([result(c, o, t, "picker")], False, fmt)
            except Rejected:
                if not c.get("allow_free_text", True):
                    raise
                emit([result(c, 0, pick_free(val), "picker")], False, fmt)
        else:
            raise Invalid("unknown pick kind")
    else:
        raise Invalid("unknown mode")


try:
    main()
except Invalid as e:
    sys.stderr.write("error: %s\n" % e)
    sys.exit(2)
except Rejected as e:
    sys.stderr.write("error: answer rejected: %s\n" % e)
    sys.exit(4)
PY

run_py() { python3 -I -c "$PY_PROG" "$@"; }

die() {
  local code=$1; shift
  echo "error: $*" >&2
  exit "$code"
}

# --- defaults ---
FORMAT="json"
BACKEND=""
NO_INTERACTIVE=false
MODE="pick"
ANSWER=""

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) [[ $# -ge 2 ]] || die 2 "--format needs a value"; FORMAT="$2"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    --backend) [[ $# -ge 2 ]] || die 2 "--backend needs a value"; BACKEND="$2"; shift 2 ;;
    --no-interactive) NO_INTERACTIVE=true; shift ;;
    --validate) MODE="validate"; shift ;;
    --render) MODE="render"; shift ;;
    --parse-card) MODE="parse-card"; shift ;;
    --answer) [[ $# -ge 2 ]] || die 2 "--answer needs a value"; ANSWER="$2"; MODE="answer"; shift 2 ;;
    --answer=*) ANSWER="${1#--answer=}"; MODE="answer"; shift ;;
    --help)
      sed -n '2,/^set -eu/p' "$0" | head -n -1 | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    --) shift; break ;;
    *) break ;;
  esac
done

case "$FORMAT" in
  json|text|id) ;;
  *) die 2 "unknown --format '$FORMAT' (expected json, text, or id)" ;;
esac
export SQ_ASK_FORMAT="$FORMAT"

# --- read stdin or positional argument ---
CARD_JSON=""
if [[ $# -gt 0 ]]; then
  CARD_JSON="$1"
elif [[ -t 0 ]]; then
  echo "error: no decision card JSON on stdin or as argument" >&2
  exit 2
else
  CARD_JSON="$(cat)"
fi

case "$MODE" in
  validate|render|parse-card)
    printf '%s' "$CARD_JSON" | run_py "$MODE"
    exit 0
    ;;
  answer)
    export SQ_ASK_ANSWER="$ANSWER"
    printf '%s' "$CARD_JSON" | run_py answer
    exit 0
    ;;
esac

# --- picker path: validate first so a bad card is always exit 2 ---
printf '%s' "$CARD_JSON" | run_py validate >/dev/null

detect_backend() {
  if [[ -n "$BACKEND" ]]; then
    echo "$BACKEND"
    return
  fi

  if [[ -t 1 ]] && command -v fzf >/dev/null 2>&1; then
    echo "fzf"
  elif [[ -t 1 ]] && command -v whiptail >/dev/null 2>&1; then
    echo "whiptail"
  elif [[ -t 1 ]] && command -v dialog >/dev/null 2>&1; then
    echo "dialog"
  elif [[ -t 1 ]]; then
    echo "bash"
  else
    echo "none"
  fi
}

DETECTED_BACKEND=$(detect_backend)

if [[ "$DETECTED_BACKEND" == "none" ]]; then
  if $NO_INTERACTIVE; then
    echo "error: no interactive terminal available" >&2
    exit 3
  fi
  DETECTED_BACKEND="default"
fi

if [[ "$DETECTED_BACKEND" == "default" ]]; then
  echo "notice: no terminal, using the recommended option" >&2
  printf '%s' "$CARD_JSON" | run_py defaults
  exit 0
fi

case "$DETECTED_BACKEND" in
  fzf|whiptail|dialog|bash) ;;
  *) die 2 "unknown backend $DETECTED_BACKEND" ;;
esac

# --- picker data: title, question, context, free-text flag, default, n, n option lines, n labels, prose block ---
INFO=$(printf '%s' "$CARD_JSON" | run_py pick-info)
INFO_LINES=()
while IFS= read -r line; do
  INFO_LINES+=("$line")
done <<<"$INFO"

TITLE="${INFO_LINES[0]}"
QUESTION="${INFO_LINES[1]}"
CONTEXT="${INFO_LINES[2]}"
ALLOW_FREE_TEXT="${INFO_LINES[3]}"
DEFAULT_IDX="${INFO_LINES[4]}"
OPT_COUNT="${INFO_LINES[5]}"
OPTION_LINES=("${INFO_LINES[@]:6:OPT_COUNT}")
OPTION_LABELS=("${INFO_LINES[@]:$((6 + OPT_COUNT)):OPT_COUNT}")
PROSE_BLOCK=("${INFO_LINES[@]:$((6 + 2 * OPT_COUNT))}")
OWN_LINE="O0 - Your own words"

# A pick prints one of: CANCELLED, FREE, INDEX:<n>, LINE:<text>, DEFAULT
parse_menu_choice() {  # <selected text beginning O<m> - ...>
  local n="${1#O}"
  n="${n%% *}"
  if [[ "$n" == "0" ]]; then
    echo "FREE"
  elif [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= OPT_COUNT)); then
    echo "INDEX:$n"
  else
    echo "CANCELLED"
    return 1
  fi
}

pick_fzf() {
  local selected input=""
  for line in "${OPTION_LINES[@]}"; do
    input+="$line"$'\n'
  done
  if [[ "$ALLOW_FREE_TEXT" == "1" ]]; then
    input+="$OWN_LINE"$'\n'
  fi

  selected=$(printf '%s' "$input" | fzf \
    --prompt="$QUESTION > " \
    --height=40% \
    --layout=reverse \
    --border \
    --header="$TITLE${CONTEXT:+ - $CONTEXT}" \
    --pointer=">" \
    --marker="*" \
    2>/dev/null) || true

  if [[ -z "$selected" ]]; then
    echo "CANCELLED"
    return 1
  fi
  parse_menu_choice "$selected"
}

pick_dialog_like() {  # <whiptail|dialog>
  local tool=$1 menu_items=() i choice
  for i in "${!OPTION_LABELS[@]}"; do
    menu_items+=("O$((i + 1))" "${OPTION_LABELS[$i]}")
  done
  if [[ "$ALLOW_FREE_TEXT" == "1" ]]; then
    menu_items+=("O0" "Your own words")
  fi

  choice=$("$tool" --title "$TITLE" \
    --menu "$QUESTION\n\n$CONTEXT" \
    20 70 10 \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || true

  if [[ -z "$choice" ]]; then
    echo "CANCELLED"
    return 1
  fi
  parse_menu_choice "$choice"
}

pick_bash() {
  local line
  printf '%s\n' "${PROSE_BLOCK[@]}" >&2
  echo "" >&2
  echo -n "Answer (Enter = O$DEFAULT_IDX): " >&2
  local _read_fd=0
  if [[ ! -t 0 ]]; then
    _read_fd=3
    exec 3<>/dev/tty
  fi
  read -r line <&"$_read_fd"
  if [[ "$_read_fd" == "3" ]]; then
    exec 3<&-
  fi
  echo "" >&2

  if [[ -z "$line" ]]; then
    echo "DEFAULT"
  elif [[ "$line" =~ ^[oO]?0$ && "$ALLOW_FREE_TEXT" == "1" ]]; then
    echo "FREE"
  elif [[ "$line" =~ ^[oO]?([1-9][0-9]*)$ ]]; then
    echo "INDEX:${BASH_REMATCH[1]}"
  else
    echo "LINE:$line"
  fi
}

# --- execute picker ---
RESULT=""
case "$DETECTED_BACKEND" in
  fzf) RESULT=$(pick_fzf) ;;
  whiptail) RESULT=$(pick_dialog_like whiptail) ;;
  dialog) RESULT=$(pick_dialog_like dialog) ;;
  bash) RESULT=$(pick_bash) ;;
esac

KIND="" VALUE=""
case "$RESULT" in
  CANCELLED) exit 1 ;;
  DEFAULT) KIND="default" ;;
  INDEX:*) KIND="index"; VALUE="${RESULT#INDEX:}" ;;
  LINE:*) KIND="line"; VALUE="${RESULT#LINE:}" ;;
  FREE)
    echo -n "Enter your answer: " >&2
    _read_fd=0
    if [[ ! -t 0 ]]; then
      _read_fd=3
      exec 3<>/dev/tty
    fi
    read -r VALUE <&"$_read_fd"
    if [[ "$_read_fd" == "3" ]]; then
      exec 3<&-
    fi
    echo "" >&2
    KIND="free"
    ;;
  *) die 2 "unexpected result: $RESULT" ;;
esac

export SQ_ASK_KIND="$KIND" SQ_ASK_VALUE="$VALUE"
printf '%s' "$CARD_JSON" | run_py pick-result
