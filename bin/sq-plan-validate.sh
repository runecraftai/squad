#!/usr/bin/env bash
# Deterministic pre-dispatch structural gate for a brief's execution plan.
# Usage: sq-plan-validate.sh <task-id>
#
# Reads data/<id>/brief.md, bounds its `## Execution plan` section, and refuses
# when a required field is absent or structurally empty. Required fields and
# shapes (label line, then its entries as a list; short fields may carry inline
# content after the label):
#   - Files to touch, with at least one path-like entry
#   - Ordered steps, with at least one numbered step
#   - Acceptance criteria
#   - Verification command(s)
#   - Out of scope
# The check is structural only: it never judges plan quality, correctness, or
# feasibility. It is the dispatch-time companion to bin/sq-playbook-validate.sh,
# which owns the post-work checklist evidence for the plan-execute@1 playbook.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE="${SQUAD_BASE:-${SQUAD_HOME:-$ROOT}}"
DATA="${SQUAD_DATA_OVERRIDE:-$BASE/data}"
ID=${1:-}
[ -n "$ID" ] || { echo "error: task id is required" >&2; exit 2; }
BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] || { echo "missing: $BRIEF"; exit 1; }

awk -v id="$ID" '
function label_text(l) {
  sub(/^[[:space:]]+/, "", l)
  sub(/^[*_]+/, "", l)
  sub(/[*_]+[[:space:]]*$/, "", l)
  return l
}
function field(l) {
  if (l ~ /^[Ff]iles[[:space:]]+to[[:space:]]+touch/) return "files"
  if (l ~ /^([Oo]rdered[[:space:]]+)?[Ss]teps/) return "steps"
  if (l ~ /^[Aa]cceptance[[:space:]]+criteria/) return "acceptance"
  if (l ~ /^[Vv]erification[[:space:]]+commands?/) return "verification"
  if (l ~ /^[Oo]ut[[:space:]]+of[[:space:]]+scope/) return "out-of-scope"
  return ""
}
function flush() {
  if (cur != "") { seen[cur] = 1; body[cur] = body[cur] "\n" text }
}
BEGIN { inplan = 0; heading = 0; cur = ""; text = "" }
/^##[[:space:]]+[Ee]xecution[[:space:]]+[Pp]lan[[:space:]]*$/ { inplan = 1; heading = 1; next }
inplan && /^#[[:space:]]/ { inplan = 0; next }
inplan && /^##[[:space:]]/ { inplan = 0; next }
!inplan { next }
{
  l = label_text($0)
  f = field(l)
  if (f != "") {
    flush()
    cur = f; text = ""; inline[cur] = ""
    if (l ~ /:/) {
      sub(/^[^:]*:/, "", l)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", l)
      inline[cur] = l
    }
    next
  }
  if (cur != "") {
    text = text "\n" $0
    item = $0
    sub(/^[[:space:]]+/, "", item)
    if (item ~ /^[-*+][[:space:]]/ || item ~ /^[0-9]+[.)]/) has_item[cur] = 1
    if (item ~ /^[0-9]+[.)]/) has_step[cur] = 1
  }
}
END {
  flush()
  if (!heading) { print "missing: execution plan section (## Execution plan)"; exit 1 }
  labels["files"] = "files to touch (exact paths)"
  labels["steps"] = "ordered steps"
  labels["acceptance"] = "acceptance criteria"
  labels["verification"] = "verification command"
  labels["out-of-scope"] = "out of scope"
  split("files steps acceptance verification out-of-scope", keys, " ")
  bad = 0
  for (i = 1; i <= 5; i++) {
    k = keys[i]
    if (!(k in seen)) {
      printf "missing: execution plan field \"%s\"\n", labels[k]
      bad = 1
      continue
    }
    combined = inline[k] "\n" body[k]
    if (inline[k] == "" && has_item[k] != 1) {
      printf "empty: execution plan field \"%s\"\n", labels[k]
      bad = 1
      continue
    }
    if (k == "files" && combined !~ /\/|[A-Za-z0-9_-]+\.[A-Za-z0-9]+/) {
      printf "invalid: execution plan field \"%s\" has no path-like entry\n", labels[k]
      bad = 1
    }
    if (k == "steps" && has_step[k] != 1 && inline[k] !~ /^[0-9]+[.)]/) {
      printf "invalid: execution plan field \"%s\" has no numbered step\n", labels[k]
      bad = 1
    }
  }
  if (bad) exit 1
  printf "execution plan structurally valid: %s\n", id
}
' "$BRIEF"
