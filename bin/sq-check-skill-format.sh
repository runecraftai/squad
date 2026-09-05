#!/usr/bin/env bash
# Check that a skill has SKILL.md front matter and required headings.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <skill-directory>" >&2
  exit 2
fi

skill_file="$1/SKILL.md"
[[ -f "$skill_file" ]] || { echo "missing SKILL.md" >&2; exit 1; }
grep -Eq '^name:[[:space:]]*[^[:space:]].*$' "$skill_file" || { echo "missing name" >&2; exit 1; }
grep -Eq '^description:[[:space:]]*[^[:space:]].*$' "$skill_file" || { echo "missing description" >&2; exit 1; }
grep -Eq '^##[[:space:]]+Triggers[[:space:]]*$|^Triggers:[[:space:]]*[^[:space:]].*$' "$skill_file" || { echo "missing Triggers" >&2; exit 1; }
grep -Eq '^##[[:space:]]+Do NOT use for[[:space:]]*$|^Do NOT use for:[[:space:]]*[^[:space:]].*$' "$skill_file" || { echo "missing Do NOT use for" >&2; exit 1; }
