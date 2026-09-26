#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/base" "$TMP/isolated"; export SQUAD_BASE="$TMP/base"
printf 'baseline policy\n' > "$TMP/base.txt"; printf 'candidate policy\n' > "$TMP/candidate.txt"
b=$(sha256sum "$TMP/base.txt"|cut -d' ' -f1); c=$(sha256sum "$TMP/candidate.txt"|cut -d' ' -f1)
python3 - "$TMP/experiment.yaml" "$TMP/base.txt" "$TMP/candidate.txt" "$b" "$c" "$TMP/isolated" <<'PY'
import sys,yaml
p,b,c,bh,ch,wt=sys.argv[1:]
d={'version':1,'id':'test-policy','baseline':{'path':b,'sha256':bh},'candidate':{'path':c,'sha256':ch},'primary_metric':'score','capability_floor':0.8,'max_budget':10,'harness':'test','model':'test-model','configuration':{},'worktree':wt,'runner':'/does/not/exist','public_cases':[{'id':f'p{i}','seed':i} for i in range(6)],'reserved_cases':[{'id':f'r{i}','seed':i} for i in range(4)],'rules':{'minimum_improvement':0.1,'promote':'literal','reject':'literal'}}
open(p,'w').write(yaml.safe_dump(d))
PY
CLI="$ROOT/bin/sq-policy-lab.sh"
"$CLI" validate "$TMP/experiment.yaml" >/dev/null
[[ -f "$TMP/base/data/policy-lab/test-policy/inputs/baseline" ]]
[[ $(stat -c %a "$TMP/base/data/policy-lab/test-policy/inputs/baseline") == 400 ]]
# 1: duplicate/cross-set id rejected.
python3 - "$TMP/experiment.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p)); d['reserved_cases'][0]['id']='p0'; open(p,'w').write(yaml.safe_dump(d))
PY
if "$CLI" validate "$TMP/experiment.yaml" >/dev/null 2>&1; then echo 'duplicate case accepted' >&2; exit 1; fi
# 3: unprovable runner isolation fails closed with exit 2 before any trajectory.
python3 - "$TMP/experiment.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p)); d['reserved_cases'][0]['id']='r0'; open(p,'w').write(yaml.safe_dump(d))
PY
set +e; "$CLI" run "$TMP/experiment.yaml" >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 2 && ! -d "$TMP/base/data/policy-lab/test-policy/trajectories" ]]
echo 'ok - policy lab validation, private immutable input and fail-closed runner isolation'
