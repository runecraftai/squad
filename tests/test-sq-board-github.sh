#!/usr/bin/env bash
# Tests for the opt-in GitHub board monitor.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/state" "$TMP/bin"
cat > "$TMP/WORKFLOW.md" <<'EOF'
---
schema_version: 1.0.0
tracker:
  kind: github
  provider:
    repo: acme/widgets
---
EOF
cat > "$TMP/bin/sq-gh" <<'EOF'
#!/usr/bin/env bash
cat "$SQ_BOARD_GITHUB_FIXTURE"
EOF
cat > "$TMP/bin/sq-workflow.sh" <<EOF
#!/usr/bin/env bash
exec "$ROOT/bin/sq-workflow.sh" "\$@"
EOF
chmod +x "$TMP/bin/sq-gh" "$TMP/bin/sq-workflow.sh"

fixture() {
  printf '%s\n' "${1:-1}" > "$TMP/version"
  if [ "${1:-1}" = 1 ]; then
    cat > "$TMP/issues.json" <<'JSON'
{"data":[{"number":12,"title":"Add board","state":"OPEN","updatedAt":"2025-01-01T00:00:00Z"}]}
JSON
  else
    cat > "$TMP/issues.json" <<'JSON'
{"data":[{"number":12,"title":"Add board","state":"OPEN","updatedAt":"2025-01-02T00:00:00Z"},{"number":13,"title":"New issue","state":"OPEN","updatedAt":"2025-01-02T00:00:00Z"}]}
JSON
  fi
}
run() { PATH="$TMP/bin:$PATH" SQ_BOARD_GITHUB_WORKFLOW="$TMP/WORKFLOW.md" SQUAD_BASE="$TMP" SQ_BOARD_GITHUB_FIXTURE="$TMP/issues.json" "$ROOT/bin/sq-board-github.sh" "$@"; }

fixture 1
list=$(run list)
printf '%s' "$list" | jq -e 'length == 1 and .[0].number == 12' >/dev/null
poll=$(run poll)
printf '%s' "$poll" | jq -e '.changes | (length == 1 and .[0].change == "new")' >/dev/null
run poll >/dev/null
[ "$(jq 'length' "$TMP/state/github-monitor/suggestions.json")" = 1 ]
fixture 2
poll=$(run poll)
printf '%s' "$poll" | jq -e '.changes | length == 2' >/dev/null
[ "$(jq 'length' "$TMP/state/github-monitor/suggestions.json")" = 2 ]
report=$(run report)
printf '%s' "$report" | jq -e '.total == 2 and .pending_suggestions == 2' >/dev/null
run approve 12 | jq -e '.status == "approved"' >/dev/null
[ "$(jq '[.[]|select(.status=="approved")]|length' "$TMP/state/github-monitor/suggestions.json")" = 1 ]
mkdir -p "$TMP/data"
# Approval only records intent; no backlog/provider mutation is possible.
[ ! -e "$TMP/data/backlog.md" ]

printf 'sq-board-github tests: PASS\n'
