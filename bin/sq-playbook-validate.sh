#!/usr/bin/env bash
# Validate structural evidence for a materialized execution playbook.
# Usage: sq-playbook-validate.sh <task-id>
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE="${SQUAD_BASE:-${SQUAD_HOME:-$ROOT}}"
DATA="${SQUAD_DATA_OVERRIDE:-$BASE/data}"
STATE="${SQUAD_STATE_OVERRIDE:-$BASE/state}"
ID=${1:-}
[ -n "$ID" ] || { echo "error: task id is required" >&2; exit 2; }
META="$STATE/$ID.meta"
ARTIFACTS="$DATA/$ID/artifacts"
[ -f "$META" ] || { echo "missing: $META"; exit 1; }
PLAYBOOK=$(sed -n 's/^playbook=//p' "$META" | head -n 1)
VERSION=$(sed -n 's/^playbook_version=//p' "$META" | head -n 1)
case "$PLAYBOOK@$VERSION" in
  bug-fix@1|investigation@1|feature@1|refactoring@1|prototype@1) ;;
  *) echo "error: task $ID has unsupported execution playbook identity"; exit 1 ;;
esac
CHECKLIST=
if [ -d "$ARTIFACTS" ]; then
  for candidate in "$ARTIFACTS"/*.md; do
    [ -f "$candidate" ] || continue
    grep -q '^#.*[Cc]hecklist\|^#.*@1' "$candidate" || continue
    CHECKLIST=$candidate
    break
  done
fi
[ -n "$CHECKLIST" ] || { echo "missing: checklist artifact under $ARTIFACTS"; exit 1; }
FAIL=0
proof_for() {
  local number=$1 proof
  proof=$(awk -v n="$number" 'BEGIN{found=0} $0 ~ "^##[[:space:]]+Criterion[[:space:]]+" n {found=1; next} found && /^##[[:space:]]+Criterion[[:space:]]+/ {exit} found && /^Proof:/ {sub(/^Proof:[[:space:]]*/, ""); print; exit}' "$CHECKLIST")
  printf '%s' "$proof"
}
require_proof() {
  local number=$1 label=$2 pattern=$3 proof
  proof=$(proof_for "$number")
  if [ -z "$proof" ]; then
    echo "missing: criterion $number $label proof"
    FAIL=1
    return
  fi
  case "$proof" in *"$pattern"*) ;; *) echo "incompatible: criterion $number $label proof"; FAIL=1 ;; esac
  case "$proof" in *command*|*path:*) ;; *) echo "incompatible: criterion $number proof lacks a bound command or path"; FAIL=1 ;; esac
}
case "$PLAYBOOK@$VERSION" in
  bug-fix@1)
    require_proof 1 "reproduction before fix" reproduction
    require_proof 2 "causal explanation" causal
    require_proof 3 "regression test" regression
    require_proof 4 "relevant suite" suite
    require_proof 5 "original surface" surface
    ;;
  investigation@1)
    require_proof 1 "facts and inferences" facts
    require_proof 2 "sources" source
    require_proof 3 "uncertainties" uncertainty
    require_proof 4 "practical implication and decision hold" implication
    ;;
  feature@1)
    require_proof 1 "behavior contract" behavior
    require_proof 2 "data shape and boundaries" data
    require_proof 3 "vertical implementation" vertical
    require_proof 4 "real surface and test" surface
    ;;
  refactoring@1)
    require_proof 1 "characterization" characterization
    require_proof 2 "invariants" invariant
    require_proof 3 "bounded transformation" bounded
    require_proof 4 "equivalence" equivalence
    ;;
  prototype@1)
    require_proof 1 "decision question" question
    require_proof 2 "alternatives" alternatives
    require_proof 3 "timebox and observations" timebox
    require_proof 4 "cited decision" decision
    ;;
esac
[ "$FAIL" -eq 0 ] || exit 1
echo "playbook evidence valid: $PLAYBOOK@$VERSION ($CHECKLIST)"
