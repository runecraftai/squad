#!/usr/bin/env bash
# Behavior tests for bin/sq-verification.sh (via bin/sq-verification.py):
# recording an escaped defect onto its existing issue, reporting every recorded
# defect, and treating unknown data as unknown rather than as success.
#
# sq-gh is stubbed in a per-test fakebin directory. The stub emulates the real
# `sq-gh api` contract: it applies the caller's `--jq` filter to real GitHub API
# fixture data (through jq, the same engine gh uses), clamps long strings the
# way sq-gh's api renderer does, and renders the result as TOON through the
# repo's vendored @toon-format/toon encoder. The command under test therefore
# decodes real TOON text with the real decoder (bin/sq-factory-collect-toon.mjs)
# instead of certifying a bare-text interface the real CLI never provides.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/sq-verification.sh"
TMP=$(fm_test_tmproot sq-verification)

command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the TOON encode/decode steps)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the sq-gh stub)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

SHA=0123456789abcdef0123456789abcdef01234567
SHA64=$(python3 -c 'print("0123456789abcdef" * 4)')
LONG_LINE=$(python3 -c 'print("x" * 2600)')
ASTRAL_RUN=$(python3 -c 'print("\U0001F642" * 1400)')

mkdir -p "$TMP/bin"
CALL_LOG="$TMP/calls"
PATCH_BODY="$TMP/patched-body"
ISSUES_JSON="$TMP/issues.json"
export CALL_LOG PATCH_BODY ISSUES_JSON
export TOON_MODULE="$ROOT/bin/vendor/toon/index.mjs"
export SQ_VERIFICATION_MOCK="$TMP/sq-gh-mock.mjs"
export PATH="$TMP/bin:$PATH"
: > "$CALL_LOG"

cat > "$TMP/bin/sq-gh" <<'SH'
#!/usr/bin/env bash
exec node "$SQ_VERIFICATION_MOCK" "$@"
SH
chmod +x "$TMP/bin/sq-gh"

cat > "$SQ_VERIFICATION_MOCK" <<'MOCK'
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const { encode } = await import(pathToFileURL(process.env.TOON_MODULE).href);

// Mirrors sq-gh api's string-value bound for caller-shaped (--jq) output.
const STRING_VALUE_TRUNCATION_LIMIT = 2000;

const argv = process.argv.slice(2);
appendFileSync(process.env.CALL_LOG, `${argv.join(" ")}\n`);

const explicitMethod = /^[A-Z]+$/.test(argv[1] ?? "");
const method = explicitMethod ? argv[1] : "GET";
const path = explicitMethod ? argv[2] : argv[1];
const jqAt = argv.indexOf("--jq");
const jqExpression = jqAt === -1 ? undefined : argv[jqAt + 1];
const fieldAt = argv.indexOf("--field");
const field = fieldAt === -1 ? undefined : argv[fieldAt + 1];

const issues = JSON.parse(readFileSync(process.env.ISSUES_JSON, "utf8"));
let data;
if (method === "PATCH") {
  writeFileSync(process.env.PATCH_BODY, String(field).replace(/^body=/, ""));
  data = { number: Number(path.split("/").pop()) };
} else if (path.includes("?")) {
  const page = Number(new URLSearchParams(path.split("?")[1]).get("page"));
  data = issues.slice((page - 1) * 100, page * 100);
} else {
  data = issues.find((issue) => issue.number === Number(path.split("/").pop()));
  if (data === undefined) {
    process.stderr.write("gh: Not Found (HTTP 404)\n");
    process.exit(1);
  }
}

const selected = jqExpression
  ? execFileSync("jq", ["-c", jqExpression], { input: JSON.stringify(data), encoding: "utf8" }).trim()
  : JSON.stringify(data);
process.stdout.write(`${encode(clamp(JSON.parse(selected)))}\n`);

function clamp(value) {
  if (Array.isArray(value)) return value.map(clamp);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, clamp(item)]));
  }
  if (typeof value === "string" && value.length > STRING_VALUE_TRUNCATION_LIMIT) {
    return `${value.slice(0, STRING_VALUE_TRUNCATION_LIMIT)}... (truncated)`;
  }
  return value;
}
MOCK

# Writes the fixture issue set. #17 carries a 2600-character line before its
# recorded section so a clamped or envelope-wrapped body read cannot reach the
# section at all; #20 carries human prose after the recorded section.
write_issues() {
  python3 - "$1" <<'PY'
import json
import sys

marker = "<!-- squad-escaped-defect:v1 -->"
sha = "0123456789abcdef0123456789abcdef01234567"
section = "\n".join([
    marker,
    "### Escaped defect linkage",
    "discovered_at: 2026-10-25T12:00:00Z",
    "affected_pr: https://github.com/acme/app/pull/8",
    f"affected_sha: {sha}",
    "reproduction: run test",
    "regression: TestBrokenOutput",
    "pre_merge_gate: unit tests",
    "missed_gate: missing case",
])
unknown = "\n".join([marker, "### Escaped defect linkage"])
issues = [
    {
        "number": 17,
        "title": "Real recorded defect: broken output",
        "html_url": "https://github.com/acme/app/issues/17",
        "body": "Original issue text\n" + ("x" * 2600) + "\n\n" + section + "\n",
    },
    {
        "number": 18,
        "title": "Fully unknown record",
        "html_url": "https://github.com/acme/app/issues/18",
        "body": "Original unknown issue text\n\n" + unknown + "\n",
    },
    {
        "number": 19,
        "title": "Unrelated defect with no linkage",
        "html_url": "https://github.com/acme/app/issues/19",
        "body": "no linkage here",
    },
    {
        "number": 20,
        "title": "Recorded then annotated by a human",
        "html_url": "https://github.com/acme/app/issues/20",
        "body": section + "\nA human note about the defect\nregression: not-a-field-here\n",
    },
    {
        "number": 21,
        "title": "Recorded defect behind astral text",
        "html_url": "https://github.com/acme/app/issues/21",
        "body": ("\U0001F642" * 1400) + ("x" * 200) + "\n\n" + section + "\n",
    },
    {
        "number": 99,
        "title": "A pull request, not a defect",
        "html_url": "https://github.com/acme/app/pull/99",
        "pull_request": {"url": "https://api.github.com/repos/acme/app/pulls/99"},
    },
]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(issues, handle)
PY
}

replace_issue_body() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

path, number, body_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(path, encoding="utf-8") as handle:
    issues = json.load(handle)
with open(body_path, encoding="utf-8") as handle:
    body = handle.read()
for issue in issues:
    if issue.get("number") == number:
        issue["body"] = body
with open(path, "w", encoding="utf-8") as handle:
    json.dump(issues, handle)
PY
}

write_issues "$ISSUES_JSON"

# --- report ------------------------------------------------------------------

out=$("$VERIFY" report acme/app) || fail "report failed on the recorded-defect fixture"
assert_contains "$out" "Defect #17: Real recorded defect: broken output" "report omits the recorded defect title"
assert_contains "$out" "Issue: https://github.com/acme/app/issues/17" "report omits the recorded defect issue URL"
assert_contains "$out" "  affected_pr: https://github.com/acme/app/pull/8" "report omits the affected PR"
assert_contains "$out" "  affected_sha: $SHA" "report omits the affected SHA"
assert_contains "$out" "  reproduction: run test" "report omits the reproduction"
assert_contains "$out" "  regression: TestBrokenOutput" "report omits the regression scenario"
assert_contains "$out" "  pre_merge_gate: unit tests" "report omits the missed gate"
assert_contains "$out" "  missed_gate: missing case" "report omits the missed-gate reason"
assert_contains "$out" "Defect #18: Fully unknown record" "report omits the fully unknown record"
assert_contains "$out" "  discovered_at: unknown (not recorded)" "a genuinely absent field must read as unknown"
assert_contains "$out" "  reproduction: unknown (not recorded)" "a genuinely absent reproduction must read as unknown"
assert_contains "$out" "  regression: unknown (not recorded)" "a genuinely absent regression must read as unknown"
assert_contains "$out" "Defect #20: Recorded then annotated by a human" "report omits the annotated record"
expected_astral_record=$'Defect #21: Recorded defect behind astral text\nIssue: https://github.com/acme/app/issues/21\n  discovered_at: 2026-10-25T12:00:00Z\n  affected_pr: https://github.com/acme/app/pull/8\n  affected_sha: '"$SHA"$'\n  reproduction: run test\n  regression: TestBrokenOutput\n  pre_merge_gate: unit tests\n  missed_gate: missing case'
assert_contains "$out" "$expected_astral_record" \
  "report lost the recorded section behind non-BMP body text"
assert_not_contains "$out" "not-a-field-here" "report consumed human prose after the recorded section"
assert_not_contains "$out" "A pull request, not a defect" "report listed a pull request as an escaped defect"
assert_not_contains "$out" "Unrelated defect with no linkage" "report listed an issue with no linkage"
pass "report renders recorded defects and names unknown data as unknown"

out=$("$VERIFY" report acme/app 2>&1) || fail "report failed on the second run"
assert_not_contains "$out" "api_response" "report never reached the recorded data (envelope leaked into output)"

# --- record ------------------------------------------------------------------

: > "$CALL_LOG"
"$VERIFY" record https://github.com/acme/app/issues/17 \
  --discovered-at 2026-11-02T09:30:00Z --pr https://github.com/acme/app/pull/8 \
  --sha "$SHA" --reproduction $'run test\nobserve the failure' \
  --regression 'tests/output.test.sh: broken output case' --gate 'Drill CI' \
  --missed-reason 'required suite did not include this case' >/dev/null \
  || fail "record failed on an existing issue"
assert_grep "PATCH /repos/acme/app/issues/17" "$CALL_LOG" "record did not patch the issue body"
[ -s "$PATCH_BODY" ] || fail "record wrote no issue body"
written=$(cat "$PATCH_BODY")
assert_contains "$written" "Original issue text" "record discarded the pre-existing issue body"
assert_contains "$written" "$LONG_LINE" "record truncated the pre-existing issue body"
assert_contains "$written" "discovered_at: 2026-11-02T09:30:00Z" "record omitted the discovery time"
assert_contains "$written" "affected_pr: https://github.com/acme/app/pull/8" "record omitted the affected PR"
assert_contains "$written" "affected_sha: $SHA" "record omitted the affected SHA"
assert_contains "$written" "reproduction: run test" "record omitted the reproduction"
assert_contains "$written" $'  observe the failure' "record lost the continuation of a multi-line reproduction"
assert_contains "$written" "regression: tests/output.test.sh: broken output case" "record omitted the regression scenario"
assert_contains "$written" "pre_merge_gate: Drill CI" "record omitted the pre-merge gate"
assert_contains "$written" "missed_gate: required suite did not include this case" "record omitted the missed-gate reason"
assert_not_contains "$written" "api_response" "record wrote the sq-gh envelope instead of the issue body"
[ "$(grep -cF '<!-- squad-escaped-defect:v1 -->' "$PATCH_BODY")" = 1 ] \
  || fail "record wrote more than one linkage section"
pass "record preserves the issue body and writes every required field"

replace_issue_body "$ISSUES_JSON" 17 "$PATCH_BODY"
out=$("$VERIFY" report acme/app) || fail "report failed after recording"
assert_contains "$out" "  discovered_at: 2026-11-02T09:30:00Z" "record/report round trip lost the discovery time"
assert_contains "$out" "  affected_sha: $SHA" "record/report round trip lost the affected SHA"
assert_contains "$out" $'  reproduction: run test\nobserve the failure' "record/report round trip lost multi-line values"
assert_contains "$out" "  regression: tests/output.test.sh: broken output case" "record/report round trip lost the regression scenario"
assert_contains "$out" "  missed_gate: required suite did not include this case" "record/report round trip lost the missed-gate reason"
pass "record then report round-trips every field, including multi-line values"

# --- unknown data must name its reason ---------------------------------------

: > "$CALL_LOG"
"$VERIFY" record https://github.com/acme/app/issues/18 \
  --discovered-at 2026-11-03T00:00:00Z --pr https://github.com/acme/app/pull/9 \
  --sha "$SHA" --no-reproduction-reason 'no reproduction path could be established' \
  --no-regression-reason 'no automated scenario exists yet' --gate 'Drill CI' \
  --missed-reason 'gate has no case for this path' >/dev/null \
  || fail "record rejected an explicit unknown reason"
assert_grep "PATCH /repos/acme/app/issues/18" "$CALL_LOG" "record did not patch the unknown-reason issue"
replace_issue_body "$ISSUES_JSON" 18 "$PATCH_BODY"
out=$("$VERIFY" report acme/app) || fail "report failed on the unknown-reason record"
assert_contains "$out" "  reproduction: unknown: no reproduction path could be established" \
  "report does not carry the recorded unknown reproduction reason"
assert_contains "$out" "  regression: unknown: no automated scenario exists yet" \
  "report does not carry the recorded unknown regression reason"
pass "an unknown field records and reports its explicit reason"

assert_no_linkage_fixture="$TMP/no-linkage.json"
printf '[{"number":5,"title":"Unrecorded","html_url":"https://github.com/acme/app/issues/5","body":"plain body"}]' \
  > "$assert_no_linkage_fixture"
out=$(ISSUES_JSON="$assert_no_linkage_fixture" "$VERIFY" report acme/app) \
  || fail "report failed on a repo with no recorded defects"
assert_contains "$out" "no escaped defects recorded (this is not evidence that none exist)" \
  "an empty report must not read as success"
pass "a report with no recorded defects refuses to read as success"

# --- rejected operator input -------------------------------------------------

rejects() {
  local label=$1
  shift
  : > "$CALL_LOG"
  if "$VERIFY" record "$@" >/dev/null 2>"$TMP/err"; then
    fail "record accepted $label"
  fi
  assert_not_contains "$(cat "$CALL_LOG")" "PATCH" "record patched the issue despite rejecting $label"
}

rejects "an empty reproduction with no reason" \
  https://github.com/acme/app/issues/17 --discovered-at 2026-11-02T09:30:00Z \
  --pr https://github.com/acme/app/pull/8 --sha "$SHA" --reproduction '' \
  --regression 'tests/output.test.sh' --gate 'Drill CI' --missed-reason 'case missing'
assert_contains "$(cat "$TMP/err")" "reproduction must have a value or an explicit unknown reason" \
  "empty reproduction did not name the missing reason"

rejects "an empty unknown reason" \
  https://github.com/acme/app/issues/17 --discovered-at 2026-11-02T09:30:00Z \
  --pr https://github.com/acme/app/pull/8 --sha "$SHA" --no-reproduction-reason '' \
  --regression 'tests/output.test.sh' --gate 'Drill CI' --missed-reason 'case missing'
assert_contains "$(cat "$TMP/err")" "reproduction must have a value or an explicit unknown reason" \
  "empty unknown reason did not name the missing reason"

rejects "a truncated SHA" \
  https://github.com/acme/app/issues/17 --discovered-at 2026-11-02T09:30:00Z \
  --pr https://github.com/acme/app/pull/8 --sha "${SHA}0123456789abc" \
  --reproduction 'run test' --regression 'tests/output.test.sh' --gate 'Drill CI' \
  --missed-reason 'case missing'
assert_contains "$(cat "$TMP/err")" "affected SHA must be a full 40- or 64-character lowercase" \
  "truncated SHA did not name the SHA requirement"

rejects "an uppercase SHA" \
  https://github.com/acme/app/issues/17 --discovered-at 2026-11-02T09:30:00Z \
  --pr https://github.com/acme/app/pull/8 --sha "${SHA^^}" \
  --reproduction 'run test' --regression 'tests/output.test.sh' --gate 'Drill CI' \
  --missed-reason 'case missing'

rejects "an empty pre-merge gate" \
  https://github.com/acme/app/issues/17 --discovered-at 2026-11-02T09:30:00Z \
  --pr https://github.com/acme/app/pull/8 --sha "$SHA" \
  --reproduction 'run test' --regression 'tests/output.test.sh' --gate '' \
  --missed-reason 'case missing'
pass "record rejects empty values, empty reasons, and non-full SHAs without patching"

: > "$CALL_LOG"
"$VERIFY" record https://github.com/acme/app/issues/17 \
  --discovered-at 2026-11-02T09:30:00Z --pr https://github.com/acme/app/pull/8 \
  --sha "$SHA64" --reproduction 'run test' --regression 'tests/output.test.sh' \
  --gate 'Drill CI' --missed-reason 'case missing' >/dev/null \
  || fail "record rejected a full 64-character SHA"
assert_grep "affected_sha: $SHA64" "$PATCH_BODY" "record did not write a 64-character SHA"
pass "record accepts a full 64-character SHA"

: > "$CALL_LOG"
"$VERIFY" record https://github.com/acme/app/issues/21 \
  --discovered-at 2026-11-04T00:00:00Z --pr https://github.com/acme/app/pull/9 \
  --sha "$SHA" --reproduction 'run astral case' --regression 'tests/output.test.sh' \
  --gate 'Drill CI' --missed-reason 'case missing' >/dev/null \
  || fail "record failed on an issue whose body contains non-BMP text"
assert_grep "PATCH /repos/acme/app/issues/21" "$CALL_LOG" "record did not patch the astral-body issue"
written=$(cat "$PATCH_BODY")
assert_contains "$written" "$ASTRAL_RUN" \
  "record truncated a pre-existing body that contains non-BMP text"
assert_contains "$written" "reproduction: run astral case" \
  "record omitted the astral-body issue's reproduction"
pass "record preserves a body containing non-BMP text"

printf 'sq-verification tests passed\n'
