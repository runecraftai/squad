#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sq-gh" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$CALL_LOG"
if [[ " $* " == *" --paginate "* ]]; then
  cat "$ISSUES_JSON"
elif [[ " $* " == *" PATCH "* ]]; then
  exit 0
elif [[ " $* " == *"/issues/17"* ]]; then
  printf 'Original issue text\n'
else
  exit 1
fi
MOCK
chmod +x "$TMP/bin/sq-gh"
export PATH="$TMP/bin:$PATH" CALL_LOG="$TMP/calls"
SHA=0123456789abcdef0123456789abcdef01234567
cat > "$TMP/issues.json" <<EOF
[{"number":17,"title":"Real recorded defect: broken output","html_url":"https://github.com/acme/app/issues/17","body":"<!-- squad-escaped-defect:v1 -->\n### Escaped defect linkage\ndiscovered_at: 2026-10-25T12:00:00Z\naffected_pr: https://github.com/acme/app/pull/8\naffected_sha: $SHA\nreproduction: run test\nregression: TestBrokenOutput\npre_merge_gate: unit tests\nmissed_gate: missing case\n"},{"number":18,"title":"Fully unknown record","html_url":"https://github.com/acme/app/issues/18","body":"<!-- squad-escaped-defect:v1 -->\n### Escaped defect linkage\n"}]
EOF
export ISSUES_JSON="$TMP/issues.json"
OUTPUT=$("$ROOT/bin/sq-verification.sh" report acme/app)
grep -F 'Defect #17: Real recorded defect: broken output' <<<"$OUTPUT"
grep -F "affected_sha: $SHA" <<<"$OUTPUT"
grep -F 'missed_gate: missing case' <<<"$OUTPUT"
grep -F 'Defect #18: Fully unknown record' <<<"$OUTPUT"
grep -F 'discovered_at: unknown (not recorded)' <<<"$OUTPUT"
grep -F 'reproduction: unknown (not recorded)' <<<"$OUTPUT"
: > "$CALL_LOG"
"$ROOT/bin/sq-verification.sh" record https://github.com/acme/app/issues/17 \
  --discovered-at 2026-10-25T12:00:00Z --pr https://github.com/acme/app/pull/8 \
  --sha "$SHA" --reproduction 'run test and observe failure' \
  --regression 'tests/output.test.sh: broken output case' --gate 'Drill CI' \
  --missed-reason 'required suite did not include this case'
grep -F 'PATCH /repos/acme/app/issues/17' "$CALL_LOG"
if "$ROOT/bin/sq-verification.sh" record https://github.com/acme/app/issues/17 \
  --discovered-at 2026-10-25T12:00:00Z --pr https://github.com/acme/app/pull/8 \
  --sha "$SHA" --regression 'tests/output.test.sh' --gate 'Drill CI' --missed-reason 'unknown' >/dev/null 2>&1; then
  echo 'record unexpectedly accepted a missing reproduction reason' >&2
  exit 1
fi
printf 'sq-verification tests passed\n'
