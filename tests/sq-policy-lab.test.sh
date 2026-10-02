#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CLI="${POLICY_LAB_CLI:-$ROOT/bin/sq-policy-lab.sh}"
mkdir -p "$TMP/isolated" "$TMP/fixture"
printf 'baseline policy\n' > "$TMP/base.txt"
printf 'candidate policy\n' > "$TMP/candidate.txt"
cat > "$TMP/runner" <<'PY'
#!/usr/bin/env python3
import json,sys
from pathlib import Path
args=sys.argv[1:]
def arg(k): return args[args.index(k)+1]
case=json.load(sys.stdin); policy='baseline' if 'baseline' in Path(arg('--policy')).read_text() else 'candidate'
with open(Path(__file__).with_name('calls.jsonl'),'a') as f:
 f.write(json.dumps({'arm':policy,'case':case['id'],'budget':float(arg('--budget'))})+'\n')
settings=json.load(open(Path(__file__).with_name('settings.json')))
if settings.get('overrun') and case['id']==settings['overrun_case'] and policy==settings.get('overrun_arm','baseline'):
 cost=settings['overrun']
else: cost=settings.get('candidate_cost',settings.get('cost',0.1)) if policy=='candidate' else settings.get('baseline_cost',settings.get('cost',0.1))
cap=settings.get('capability',0.95)
if settings.get('low_reserved') and case['id'].startswith('r') and policy=='candidate': cap=0.1
metric=(0.9 if policy=='candidate' else 0.5) if settings.get('improve',True) else 0.5
print(json.dumps({'result':'ok','checks':{'passed':True},'metric':metric,'capability':cap,'cost':cost,'tokens':1}))
PY
chmod +x "$TMP/runner"
export TMP CLI
run_exp() {
 local id=$1 budget=$2 improve=$3 low=$4 overrun=${5:-0} overrun_case=${6:-none} capability=${7:-} candidate_cost=${8:-} overrun_arm=${9:-baseline}
 export SQUAD_BASE="$TMP/base-$id"; mkdir -p "$SQUAD_BASE"
 python3 - "$TMP" "$id" "$budget" "$improve" "$low" "$overrun" "$overrun_case" "$capability" "$candidate_cost" "$overrun_arm" <<'PY'
import hashlib,json,sys,yaml
from pathlib import Path
p=Path(sys.argv[1]); ident,budget,improve,low,overrun,overcase,capability,candidate_cost,overrun_arm=sys.argv[2:]
b,c=p/'base.txt',p/'candidate.txt'
d={'version':1,'id':ident,'baseline':{'path':str(b),'sha256':hashlib.sha256(b.read_bytes()).hexdigest()},'candidate':{'path':str(c),'sha256':hashlib.sha256(c.read_bytes()).hexdigest()},'primary_metric':'score','capability_floor':0.8,'max_budget':float(budget),'harness':'test','model':'test-model','configuration':{},'worktree':str(p/'isolated'),'runner':str(p/'runner'),'public_cases':[{'id':f'p{i}','seed':i} for i in range(6)],'reserved_cases':[{'id':f'r{i}','seed':i} for i in range(4)],'rules':{'minimum_improvement':0.1,'promote':'literal','reject':'literal'}}
(p/f'{ident}.yaml').write_text(yaml.safe_dump(d))
settings={'improve':improve=='yes','low_reserved':low=='yes'}
if float(overrun): settings.update(overrun=float(overrun),overrun_case=overcase,overrun_arm=overrun_arm)
if capability: settings['capability']=float(capability)
if candidate_cost: settings['candidate_cost']=float(candidate_cost)
(p/'settings.json').write_text(json.dumps(settings)); (p/'calls.jsonl').write_text('')
PY
 "$CLI" validate "$TMP/$id.yaml" >/dev/null
}
report() { "$CLI" report "$1" --json; }
# Paired complete runs establish both decisive outcomes through the public CLI.
run_exp promote 10 yes no
"$CLI" run "$TMP/promote.yaml" >/dev/null
[[ $(report promote | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == promote ]]
run_exp reject 10 no no
"$CLI" run "$TMP/reject.yaml" >/dev/null
[[ $(report reject | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == reject ]]
# Reserved candidate capability below the floor rejects a complete comparison.
run_exp floor 10 yes yes
"$CLI" run "$TMP/floor.yaml" >/dev/null
[[ $(report floor | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == reject ]]
# A demonstrated public candidate floor failure rejects early and stops before reserved cases.
run_exp publicfloor 10 yes no 0 none 0.5
"$CLI" run "$TMP/publicfloor.yaml" >/dev/null
[[ $(wc -l < "$TMP/calls.jsonl") == 12 ]]
[[ $(report publicfloor | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == reject ]]
# The same demonstrated failure is inconclusive once coverage is incomplete.
rm "$SQUAD_BASE/data/policy-lab/publicfloor/trajectories/candidate.p0.json"
[[ $(report publicfloor | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == inconclusive ]]
# A public floor failure is not decisive when baseline paired coverage is missing.
run_exp publicfloorbase 10 yes no 0 none 0.5
"$CLI" run "$TMP/publicfloorbase.yaml" >/dev/null
rm "$SQUAD_BASE/data/policy-lab/publicfloorbase/trajectories/baseline.p0.json"
[[ $(report publicfloorbase | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == inconclusive ]]
# Exhaustion on resume is cumulative; persisted results are neither rerun nor recounted.
run_exp resume 0.15 yes no
"$CLI" run "$TMP/resume.yaml" >/dev/null
first=$(wc -l < "$TMP/calls.jsonl")
[[ $first == 2 ]]
"$CLI" run "$TMP/resume.yaml" >/dev/null
[[ $(wc -l < "$TMP/calls.jsonl") == "$first" ]]
[[ $(report resume | python3 -c 'import json,sys;print(json.load(sys.stdin)["cost"]["baseline"])') == 0.2 ]]
[[ $(report resume | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == inconclusive ]]
# Public-stage spending carries into reserved stage; the per-call budget is the remainder.
run_exp accumulation 0.65 yes no 0.1 r0
"$CLI" run "$TMP/accumulation.yaml" >/dev/null
python3 - "$TMP/calls.jsonl" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1])]
assert len(rows)==13,rows
assert rows[-1]['arm']=='baseline' and rows[-1]['case']=='r0' and abs(rows[-1]['budget']-0.05)<1e-8,rows[-1]
PY
report accumulation | python3 -c 'import json,sys; assert abs(json.load(sys.stdin)["cost"]["baseline"]-0.7)<1e-8'
"$CLI" run "$TMP/accumulation.yaml" >/dev/null
[[ $(wc -l < "$TMP/calls.jsonl") == 13 ]]
# Complete coverage with actual cumulative candidate spend above budget stays inconclusive.
run_exp completedoverrun 1.0 yes no 0 none '' 0.11
[[ $("$CLI" run "$TMP/completedoverrun.yaml") == completed ]]
[[ $(wc -l < "$TMP/calls.jsonl") == 20 ]]
report completedoverrun | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["verdict"]=="inconclusive" and abs(d["cost"]["candidate"]-1.1)<1e-8 and abs(d["cost"]["baseline"]-1.0)<1e-8'
# Incomplete and contradictory result identities cannot produce a decisive verdict.
run_exp invalid 10 yes no
"$CLI" run "$TMP/invalid.yaml" >/dev/null
python3 - "$SQUAD_BASE/data/policy-lab/invalid/trajectories/baseline.p0.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['arm']='candidate'; open(p,'w').write(json.dumps(d))
PY
invalid_calls=$(wc -l < "$TMP/calls.jsonl")
"$CLI" run "$TMP/invalid.yaml" >/dev/null
[[ $(wc -l < "$TMP/calls.jsonl") == "$invalid_calls" ]]
[[ $(report invalid | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == inconclusive ]]
run_exp incomplete 10 yes no
"$CLI" run "$TMP/incomplete.yaml" >/dev/null
rm "$SQUAD_BASE/data/policy-lab/incomplete/trajectories/baseline.r3.json"
[[ $(report incomplete | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == inconclusive ]]
# Non-hashable persisted identity is malformed, not a crash: run stays alive and report is inconclusive.
run_exp malformed 10 yes no
"$CLI" run "$TMP/malformed.yaml" >/dev/null
python3 - "$SQUAD_BASE/data/policy-lab/malformed/trajectories/baseline.p0.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['arm']=['candidate']; open(p,'w').write(json.dumps(d))
PY
malformed_calls=$(wc -l < "$TMP/calls.jsonl")
set +e; "$CLI" run "$TMP/malformed.yaml" >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 0 ]]
[[ $(wc -l < "$TMP/calls.jsonl") == "$malformed_calls" ]]
[[ $(report malformed | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == inconclusive ]]
# Out-of-range persisted numbers are malformed evidence, not a crash: run stays alive and report is inconclusive.
run_exp bignum 10 yes no
"$CLI" run "$TMP/bignum.yaml" >/dev/null
python3 - "$SQUAD_BASE/data/policy-lab/bignum/trajectories/baseline.p0.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['result']['cost']=10**400; open(p,'w').write(json.dumps(d))
PY
bignum_calls=$(wc -l < "$TMP/calls.jsonl")
set +e; "$CLI" run "$TMP/bignum.yaml" >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 0 ]]
[[ $(wc -l < "$TMP/calls.jsonl") == "$bignum_calls" ]]
[[ $(report bignum | python3 -c 'import json,sys;print(json.load(sys.stdin)["verdict"])') == inconclusive ]]
# Non-finite allowances and thresholds are rejected at validation instead of silently disabling checks.
for variant in budget floor improvement; do
python3 - "$TMP" "$variant" <<'PY'
import hashlib,yaml,sys
from pathlib import Path
p=Path(sys.argv[1]); variant=sys.argv[2]; b,c=p/'base.txt',p/'candidate.txt'
d={'version':1,'id':'nan'+variant,'baseline':{'path':str(b),'sha256':hashlib.sha256(b.read_bytes()).hexdigest()},'candidate':{'path':str(c),'sha256':hashlib.sha256(c.read_bytes()).hexdigest()},'primary_metric':'score','capability_floor':0.8,'max_budget':10.0,'harness':'test','model':'test-model','configuration':{},'worktree':str(p/'isolated'),'runner':str(p/'runner'),'public_cases':[{'id':f'p{i}','seed':i} for i in range(6)],'reserved_cases':[{'id':f'r{i}','seed':i} for i in range(4)],'rules':{'minimum_improvement':0.1,'promote':'literal','reject':'literal'}}
if variant=='budget': d['max_budget']=float('nan')
elif variant=='floor': d['capability_floor']=float('nan')
else: d['rules']['minimum_improvement']=float('nan')
(p/f'nan{variant}.yaml').write_text(yaml.safe_dump(d))
PY
export SQUAD_BASE="$TMP/base-nan$variant"; mkdir -p "$SQUAD_BASE"
set +e; "$CLI" validate "$TMP/nan$variant.yaml" >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 2 ]]
done
# Existing lightweight input immutability and fail-closed isolation coverage.
python3 - "$TMP/experiment.yaml" "$TMP/base.txt" "$TMP/candidate.txt" "$TMP/isolated" <<'PY'
import hashlib,sys,yaml
from pathlib import Path
p,b,c,wt=sys.argv[1:]; b=Path(b); c=Path(c)
d={'version':1,'id':'isolated','baseline':{'path':str(b),'sha256':hashlib.sha256(b.read_bytes()).hexdigest()},'candidate':{'path':str(c),'sha256':hashlib.sha256(c.read_bytes()).hexdigest()},'primary_metric':'score','capability_floor':0.8,'max_budget':10,'harness':'test','model':'test-model','configuration':{},'worktree':wt,'runner':'/does/not/exist','public_cases':[{'id':f'p{i}'} for i in range(6)],'reserved_cases':[{'id':f'r{i}'} for i in range(4)],'rules':{'minimum_improvement':0.1,'promote':'literal','reject':'literal'}}
open(p,'w').write(yaml.safe_dump(d))
PY
export SQUAD_BASE="$TMP/basic"
"$CLI" validate "$TMP/experiment.yaml" >/dev/null
[[ -f "$TMP/basic/data/policy-lab/isolated/inputs/baseline" ]]
[[ $(stat -c %a "$TMP/basic/data/policy-lab/isolated/inputs/baseline") == 400 ]]
set +e; "$CLI" run "$TMP/experiment.yaml" >/dev/null 2>&1; rc=$?; set -e
[[ $rc == 2 && ! -d "$TMP/basic/data/policy-lab/isolated/trajectories" ]]
echo 'ok - policy lab paired verdicts, coverage integrity, cumulative budgets, resume and isolation'
