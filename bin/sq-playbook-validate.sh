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
[ "$(sed -n 's/^playbook=//p' "$META" | head -n 1)" = bug-fix ] || { echo "error: task $ID is not bug-fix@1"; exit 1; }
[ "$(sed -n 's/^playbook_version=//p' "$META" | head -n 1)" = 1 ] || { echo "error: task $ID is not bug-fix@1"; exit 1; }
CHECKLIST=
if [ -d "$ARTIFACTS" ]; then
  for candidate in "$ARTIFACTS"/*.md; do
    [ -f "$candidate" ] || continue
    grep -q '^#.*[Cc]hecklist\|^#.*bug-fix@1' "$candidate" || continue
    CHECKLIST=$candidate
    break
  done
fi
[ -n "$CHECKLIST" ] || { echo "missing: checklist artifact under $ARTIFACTS"; exit 1; }
FAIL=0
PROOF_1=
PROOF_2=
PROOF_3=
PROOF_4=
PROOF_5=
require_proof() {
  local number=$1 label=$2 pattern=$3 proof
  proof=$(awk -v n="$number" 'BEGIN{found=0} $0 ~ "^##[[:space:]]+Criterion[[:space:]]+" n {found=1; next} found && /^##[[:space:]]+Criterion[[:space:]]+/ {exit} found && /^Proof:/ {sub(/^Proof:[[:space:]]*/, ""); print; exit}' "$CHECKLIST")
  case "$number" in
    1) PROOF_1=$proof ;;
    2) PROOF_2=$proof ;;
    3) PROOF_3=$proof ;;
    4) PROOF_4=$proof ;;
    5) PROOF_5=$proof ;;
  esac
  if [ -z "$proof" ]; then echo "missing: criterion $number $label proof"; FAIL=1; return; fi
  case "$proof" in *"$pattern"*) ;; *) echo "incompatible: criterion $number $label proof"; FAIL=1 ;; esac
  case "$proof" in *"command"*|*"path:"*) ;; *) echo "incompatible: criterion $number $label proof lacks a bound command or path"; FAIL=1 ;; esac
  case "$number" in
    1) case "$proof" in *before*|*pre-fix*) ;; *) echo "incompatible: criterion 1 reproduction is not before the fix"; FAIL=1 ;; esac ;;
    2) case "$proof" in *refutable*|*observation*) ;; *) echo "incompatible: criterion 2 causal proof lacks a refutable observation"; FAIL=1 ;; esac ;;
    3) case "$proof" in *pre-fix*|*before*) ;; *) echo "incompatible: criterion 3 regression proof lacks the pre-fix failure"; FAIL=1 ;; esac
       case "$proof" in *post-fix*|*after*) ;; *) echo "incompatible: criterion 3 regression proof lacks the post-fix pass"; FAIL=1 ;; esac ;;
    4) case "$proof" in *green*|*pass*) ;; *) echo "incompatible: criterion 4 suite proof is not a passing result"; FAIL=1 ;; esac ;;
    5) case "$proof" in *same*) ;; *) echo "incompatible: criterion 5 surface proof does not match the original surface"; FAIL=1 ;; esac ;;
  esac
}
require_proof 1 "reproduction before fix" "reproduction"
require_proof 2 "causal explanation with refutable evidence" "causal"
require_proof 3 "regression test" "regression"
require_proof 4 "relevant suite" "suite"
require_proof 5 "original surface re-exercised" "surface"
if [ -n "$PROOF_1" ] && [ "$PROOF_1" = "$PROOF_2" ]; then echo "incompatible: criteria 1 and 2 reuse one generic proof"; FAIL=1; fi
if [ -n "$PROOF_2" ] && [ "$PROOF_2" = "$PROOF_3" ]; then echo "incompatible: criteria 2 and 3 reuse one generic proof"; FAIL=1; fi
if [ -n "$PROOF_3" ] && [ "$PROOF_3" = "$PROOF_4" ]; then echo "incompatible: criteria 3 and 4 reuse one generic proof"; FAIL=1; fi
if [ -n "$PROOF_4" ] && [ "$PROOF_4" = "$PROOF_5" ]; then echo "incompatible: criteria 4 and 5 reuse one generic proof"; FAIL=1; fi
[ "$FAIL" -eq 0 ] || exit 1
echo "playbook evidence valid: bug-fix@1 ($CHECKLIST)"
