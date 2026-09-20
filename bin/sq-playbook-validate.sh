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
# Catalogue-driven criteria definitions.
# Format: CRITERIA_LABELS, CRITERIA_PATTERNS, CRITERIA_CHECKS are indexed arrays.
# CRITERIA_CHECKS[i] is a semicolon-separated list of keyword groups.
# Each group is pipe-separated (OR). All groups must match (AND).
# Example: "before|pre-fix;refutable|observation" means:
#   - Must contain (before OR pre-fix) AND
#   - Must contain (refutable OR observation)
declare -a CRITERIA_LABELS=()
declare -a CRITERIA_PATTERNS=()
declare -a CRITERIA_CHECKS=()
case "$PLAYBOOK@$VERSION" in
  bug-fix@1)
    CRITERIA_LABELS=("reproduction before fix" "causal explanation with refutable evidence" "regression test" "relevant suite" "original surface re-exercised")
    CRITERIA_PATTERNS=("reproduction" "causal" "regression" "suite" "surface")
    CRITERIA_CHECKS=(
      "before|pre-fix"
      "refutable|observation"
      "pre-fix|before;post-fix|after"
      "green|pass"
      "same"
    )
    ;;
  investigation@1)
    CRITERIA_LABELS=("facts and inferences" "sources" "uncertainties" "practical implication and decision hold")
    CRITERIA_PATTERNS=("facts" "source" "uncertainty" "implication")
    CRITERIA_CHECKS=(
      "facts;inferences"
      "source|citation|artifact"
      "uncertainty|gap"
      "implication|decision"
    )
    ;;
  feature@1)
    CRITERIA_LABELS=("behavior contract" "data shape and boundaries" "vertical implementation" "real surface and test")
    CRITERIA_PATTERNS=("behavior" "data" "vertical" "surface")
    CRITERIA_CHECKS=(
      "behavior|contract|expected|rejected"
      "data|shape|boundary|caller"
      "vertical|slice|implementation"
      "surface|test|command"
    )
    ;;
  refactoring@1)
    CRITERIA_LABELS=("characterization" "invariants" "bounded transformation" "equivalence")
    CRITERIA_PATTERNS=("characterization" "invariant" "bounded" "equivalence")
    CRITERIA_CHECKS=(
      "characterization|capture|before"
      "invariant|target|shape"
      "bounded|transformation|subtract"
      "equivalence|preserve|behavior"
    )
    ;;
  prototype@1)
    CRITERIA_LABELS=("decision question" "alternatives" "timebox and observations" "cited decision")
    CRITERIA_PATTERNS=("question" "alternatives" "timebox" "decision")
    CRITERIA_CHECKS=(
      "question|scope|decision"
      "alternative|reference|gather"
      "timebox|observation|start|end"
      "decision|cite|recommendation|throwaway"
    )
    ;;
esac
COUNT=${#CRITERIA_LABELS[@]}
# Collect all proofs first for duplicate detection.
declare -a PROOFS=()
for (( i=0; i<COUNT; i++ )); do
  NUM=$((i+1))
  PROOF=$(proof_for "$NUM")
  PROOFS+=("$PROOF")
done
# Validate each criterion: presence, pattern, bound command/path, and quality checks.
for (( i=0; i<COUNT; i++ )); do
  NUM=$((i+1))
  LABEL="${CRITERIA_LABELS[$i]}"
  PATTERN="${CRITERIA_PATTERNS[$i]}"
  CHECKS="${CRITERIA_CHECKS[$i]}"
  PROOF="${PROOFS[$i]}"
  if [ -z "$PROOF" ]; then
    echo "missing: criterion $NUM $LABEL proof"
    FAIL=1
    continue
  fi
  case "$PROOF" in *"$PATTERN"*) ;; *) echo "incompatible: criterion $NUM $LABEL proof"; FAIL=1 ;; esac
  case "$PROOF" in *command*|*path:*) ;; *) echo "incompatible: criterion $NUM proof lacks a bound command or path"; FAIL=1 ;; esac
  # Apply criterion-specific quality checks (all groups must match).
  REST="$CHECKS"
  while [ -n "$REST" ]; do
    if case "$REST" in *";"*) true ;; *) false ;; esac; then
      group="${REST%%;*}"
      REST="${REST#*;}"
    else
      group="$REST"
      REST=""
    fi
    FOUND=0
    KREST="$group"
    while [ -n "$KREST" ]; do
      if case "$KREST" in *"|"*) true ;; *) false ;; esac; then
        kwd="${KREST%%|*}"
        KREST="${KREST#*|}"
      else
        kwd="$KREST"
        KREST=""
      fi
      case "$PROOF" in *"$kwd"*) FOUND=1; break ;; esac
    done
    if [ "$FOUND" -eq 0 ]; then
      echo "incompatible: criterion $NUM $LABEL proof quality: expected one of $group"
      FAIL=1
    fi
  done
done
# Duplicate-proof detection: adjacent criteria must not share identical proof text.
for (( i=0; i<COUNT-1; i++ )); do
  A="${PROOFS[$i]}"
  B="${PROOFS[$i+1]}"
  if [ -n "$A" ] && [ "$A" = "$B" ]; then
    echo "incompatible: criteria $((i+1)) and $((i+2)) reuse one generic proof"
    FAIL=1
  fi
done
[ "$FAIL" -eq 0 ] || exit 1
echo "playbook evidence valid: $PLAYBOOK@$VERSION ($CHECKLIST)"
