#!/usr/bin/env bash
# Private, non-promoting comparison laboratory for policy candidates.
#
# Comparison verdicts require unique, valid paired baseline and candidate results for every configured case, while a candidate with a demonstrated public capability-floor failure may be rejected early after complete valid paired public coverage.
# Promote requires sufficient improvement in the primary metric and a candidate at or above the reserved capability floor; insufficient improvement or a candidate below that floor rejects.
# Missing or invalid necessary public evidence stays inconclusive.
# max_budget is cumulative per arm across public and reserved cases and across resumes: each retained valid result counts once, already completed valid cases are skipped, and only the remaining allowance is passed to the runner.
# Actual cumulative spend above either arm's total allowance reports inconclusive and can never promote, including after a complete improved comparison, while requested costs stay truthful when an external runner overspends an allowance this lab cannot enforce.
# Malformed, duplicate, or identity-contradictory evidence is handled conservatively and never counts toward coverage or spending.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${SQUAD_BASE:-${SQUAD_HOME:-$ROOT}}"
usage() { printf '%s\n' 'Usage: sq-policy-lab.sh validate <experiment.yaml>' '       sq-policy-lab.sh run <experiment.yaml>' '       sq-policy-lab.sh report <experiment-id> [--json]'; }
error() { printf 'error: %s\n' "$*" >&2; exit 2; }
[[ $# -ge 1 ]] || { usage >&2; exit 2; }
cmd=$1; shift
exec python3 - "$ROOT" "$BASE" "$cmd" "$@" <<'PY'
import sys, os, json, hashlib, shutil, subprocess, time, tempfile
from pathlib import Path
try:
 import yaml
except Exception as e:
 print(f'error: PyYAML required: {e}', file=sys.stderr); sys.exit(2)
root, base, cmd, *args = sys.argv[1:]
base=Path(base).resolve(); root=Path(root).resolve(); data=base/'data/policy-lab'
def die(msg): print('error: '+msg,file=sys.stderr); sys.exit(2)
def safe_id(s): return isinstance(s,str) and __import__('re').fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*',s) is not None
def finite_num(v):
 if not isinstance(v,(int,float)) or isinstance(v,bool): return False
 try: return __import__('math').isfinite(float(v))
 except (OverflowError,ValueError): return False
def load(path):
 try:
  obj=yaml.safe_load(Path(path).read_text())
  if not isinstance(obj,dict): raise ValueError('manifest must be a mapping')
  return obj
 except Exception as e: die(f'cannot read manifest: {e}')
def validate(m):
 required=['version','id','baseline','candidate','primary_metric','capability_floor','max_budget','harness','model','configuration','public_cases','reserved_cases','rules']
 missing=[k for k in required if k not in m]
 if missing: die('missing fields: '+', '.join(missing))
 if m['version']!=1 or not safe_id(m['id']): die('version must be 1 and id must be safe')
 for arm in ['baseline','candidate']:
  a=m[arm]
  if not isinstance(a,dict) or not isinstance(a.get('path'),str) or not isinstance(a.get('sha256'),str) or not __import__('re').fullmatch('[0-9a-f]{64}',a['sha256']): die(f'invalid {arm} path/hash')
 if not isinstance(m['primary_metric'],str) or not finite_num(m['capability_floor']): die('invalid metric or capability floor')
 if not finite_num(m['max_budget']) or m['max_budget']<=0: die('max_budget must be positive')
 for key,n in [('public_cases',6),('reserved_cases',4)]:
  xs=m[key]
  if not isinstance(xs,list) or len(xs)<n: die(f'{key} requires at least {n} cases')
  if any(not isinstance(x,dict) or not safe_id(x.get('id')) for x in xs): die(f'{key} cases require safe ids')
 ids=[x['id'] for x in m['public_cases']+m['reserved_cases']]
 if len(ids)!=len(set(ids)): die('duplicate case id or case present in both sets')
 if not isinstance(m['rules'],dict) or not all(k in m['rules'] for k in ('minimum_improvement','promote','reject')) or not finite_num(m['rules'].get('minimum_improvement')): die('rules requires minimum_improvement, promote, reject')
 for a in ('harness','model'):
  if not isinstance(m[a],str) or not m[a]: die(f'{a} must be explicit and identical for both arms')
 return True
def copy_inputs(m, exp):
 inputs=exp/'inputs'; inputs.mkdir(parents=True,exist_ok=True,mode=0o700)
 for arm in ('baseline','candidate'):
  src=Path(m[arm]['path']).resolve()
  if not src.is_file(): die(f'{arm} source is not a file')
  digest=hashlib.sha256(src.read_bytes()).hexdigest()
  if digest!=m[arm]['sha256']: die(f'{arm} hash mismatch')
  dst=inputs/arm
  if dst.exists() and hashlib.sha256(dst.read_bytes()).hexdigest()!=digest: die(f'immutable input conflict: {arm}')
  if not dst.exists(): shutil.copyfile(src,dst); dst.chmod(0o400)
 return inputs

def snapshot(m, exp, arm, case, result):
 p=exp/'trajectories'; p.mkdir(parents=True,exist_ok=True,mode=0o700)
 (p/f'{arm}.{case["id"]}.json').write_text(json.dumps({'schema_version':1,'experiment':m['id'],'arm':arm,'case_id':case['id'],'seed':case.get('seed'),'configuration':m['configuration'],'harness':m['harness'],'model':m['model'],'tokens':result.get('tokens'),'cost':result.get('cost'),'duration_seconds':result.get('duration_seconds'),'checks':result.get('checks'),'result':result},sort_keys=True)+'\n')

def valid_snapshot(x, m, arm, case):
 if not isinstance(x,dict) or x.get('schema_version')!=1 or x.get('experiment')!=m['id'] or x.get('arm')!=arm or x.get('case_id')!=case['id']:
  return False
 if x.get('seed')!=case.get('seed') or x.get('configuration')!=m['configuration'] or x.get('harness')!=m['harness'] or x.get('model')!=m['model']:
  return False
 r=x.get('result')
 if not isinstance(r,dict) or not isinstance(r.get('result'),str) or not isinstance(r.get('checks'),dict): return False
 for k in ('cost','metric','capability'):
  if not finite_num(r.get(k)): return False
 for k in ('cost','tokens','duration_seconds'):
  v=r.get(k)
  if v is not None and (not finite_num(v) or v<0): return False
 return True

def evidence(m, exp):
 expected={(arm,c['id']):(arm,c) for arm in ('baseline','candidate') for c in m['public_cases']+m['reserved_cases']}
 found={}; invalid=[]
 for p in sorted((exp/'trajectories').glob('*.json')):
  try: x=json.loads(p.read_text())
  except Exception: invalid.append(p.name); continue
  key=(x.get('arm'),x.get('case_id')) if isinstance(x,dict) and isinstance(x.get('arm'),str) and isinstance(x.get('case_id'),str) else None
  item=expected.get(key)
  if item is None or key in found or p.name!=f'{key[0]}.{key[1]}.json' or not valid_snapshot(x,m,*item): invalid.append(p.name); continue
  found[key]=x
 return found,invalid

def run(m, exp):
 # A single configured executable, exact same inputs/arguments/environment. Refuse to run if isolation cannot be proven.
 runner=m.get('runner'); worktree=m.get('worktree')
 if not isinstance(runner,str) or not os.path.isfile(runner) or not os.access(runner,os.X_OK) or not isinstance(worktree,str) or not Path(worktree).is_dir(): die('cannot prove isolated worktree/profile/model/budget equivalence; no case run')
 if Path(worktree).resolve()==root or root in Path(worktree).resolve().parents: die('runner worktree must be isolated')
 inputs=copy_inputs(m,exp)
 (exp/'trajectories').mkdir(parents=True,exist_ok=True,mode=0o700)
 found,invalid=evidence(m,exp)
 if invalid:
  (exp/'state').write_text('inconclusive_invalid\n'); return
 budget=float(m['max_budget'])
 state='public_running'; (exp/'state').write_text(state+'\n')
 for label,cases in [('public',m['public_cases']),('reserved',m['reserved_cases'])]:
  if label=='reserved':
   public=[found.get(('candidate',c['id'])) for c in m['public_cases']]
   floor=float(m['capability_floor'])
   if any(x is None for x in public):
    (exp/'state').write_text('inconclusive_invalid\n'); return
   if any(not isinstance(x['result'].get('capability'),(int,float)) or x['result']['capability']<floor for x in public):
    (exp/'state').write_text('reject\n'); return
   (exp/'state').write_text('reserved_running\n')
  for arm in ('baseline','candidate'):
   spent=sum(float(x['result']['cost']) for (a,_),x in found.items() if a==arm and isinstance(x['result'].get('cost'),(int,float)))
   for case in cases:
    if (arm,case['id']) in found: continue
    remaining=budget-spent
    if remaining<=0:
     (exp/'state').write_text('inconclusive_budget\n'); return
    started=time.monotonic()
    try:
     # JSON stdin keeps reserved case text out of command-line arguments and reports.
     proc=subprocess.run([runner,'--policy',str(inputs/arm),'--case-json','--harness',m['harness'],'--model',m['model'],'--budget',str(remaining),'--configuration-json',json.dumps(m['configuration'],sort_keys=True)],input=json.dumps(case),text=True,capture_output=True,cwd=worktree,timeout=float(m.get('timeout_seconds',600)),env={'PATH':os.environ.get('PATH',''),'HOME':str(Path.home())})
     r=json.loads(proc.stdout) if proc.returncode==0 else {'result':'harness_failure','detail':'nonzero runner exit'}
     if not isinstance(r,dict) or not isinstance(r.get('checks'),dict): r={'result':'invalid_check','detail':'runner output lacks checks object'}
     elif not isinstance(r.get('result'),str): r['result']='invalid_check'
    except subprocess.TimeoutExpired: r={'result':'timeout'}
    except Exception: r={'result':'harness_failure'}
    r['duration_seconds']=r.get('duration_seconds',round(time.monotonic()-started,6))
    snapshot(m,exp,arm,case,r)
    saved=json.loads((exp/'trajectories'/f'{arm}.{case["id"]}.json').read_text())
    if not valid_snapshot(saved,m,arm,case):
     (exp/'state').write_text('inconclusive_invalid\n'); return
    found[(arm,case['id'])]=saved
    cost=r.get('cost')
    if finite_num(cost) and cost>=0: spent+=float(cost)
 (exp/'state').write_text('completed\n')

def report(i, asjson):
 if not safe_id(i): die('invalid experiment id')
 exp=data/i
 try:
  m=load(exp/'manifest.yaml'); validate(m)
  state=(exp/'state').read_text().strip()
  found,invalid=evidence(m,exp)
  results=list(found.values())
 except Exception as e: die(f'experiment not reportable: {e}')
 public_ids={c['id'] for c in m['public_cases']}; reserved_ids={c['id'] for c in m['reserved_cases']}
 pub=[x for x in results if x['case_id'] in public_ids]
 res=[x for x in results if x['case_id'] in reserved_ids]
 def avg(xs,key):
  vals=[x['result'].get(key) for x in xs if isinstance(x['result'].get(key),(int,float))]
  return sum(vals)/len(vals) if vals else None
 b=[x for x in pub if x['arm']=='baseline']; c=[x for x in pub if x['arm']=='candidate']
 delta=None if avg(c,'metric') is None or avg(b,'metric') is None else avg(c,'metric')-avg(b,'metric')
 floor=float(m['capability_floor']); verdict='inconclusive'
 budget=float(m['max_budget'])
 costs={a:sum(x['result']['cost'] for x in results if x['arm']==a) for a in ('baseline','candidate')}
 over_budget=any(cost>budget for cost in costs.values())
 complete=not invalid and all((arm,c['id']) in found for arm in ('baseline','candidate') for c in m['public_cases']+m['reserved_cases'])
 public_pair_complete=not invalid and all((arm,c['id']) in found for arm in ('baseline','candidate') for c in m['public_cases'])
 public_candidates=[found.get(('candidate',c['id'])) for c in m['public_cases']]
 public_floor_failure=public_pair_complete and any(x['result']['capability']<floor for x in public_candidates)
 if state in ('inconclusive_budget','inconclusive_invalid') or invalid or over_budget: verdict='inconclusive'
 elif state=='reject' and public_floor_failure: verdict='reject'
 elif complete:
  if any(found[('candidate',c['id'])]['result']['capability']<floor for c in m['reserved_cases']): verdict='reject'
  elif delta is not None and delta>=float(m['rules']['minimum_improvement']): verdict='promote'
  elif delta is not None: verdict='reject'
 doc={'experiment_id':i,'verdict':verdict,'primary_metric':m['primary_metric'],'delta':delta,'quality':{'baseline':avg(b,'capability'),'candidate':avg(c,'capability')},'cost':costs,'tokens':{a:sum(x['result'].get('tokens',0) for x in results if x['arm']==a and isinstance(x['result'].get('tokens'),(int,float))) for a in ('baseline','candidate')},'duration_seconds':{a:sum(x['result'].get('duration_seconds',0) for x in results if x['arm']==a and isinstance(x['result'].get('duration_seconds'),(int,float))) for a in ('baseline','candidate')},'failures':[{'arm':x['arm'],'case_id':x['case_id'],'result':x['result'].get('result')} for x in results if x['result'].get('result') not in ('ok','pass','passed')], 'invalid_evidence':invalid,'case_intervals':[],'human_action':'A human must review and promote the candidate through the normal policy change process; this laboratory does not promote it.'}
 for case in m['public_cases']:
  vals=[x['result'].get('metric') for x in results if x['case_id']==case['id'] and isinstance(x['result'].get('metric'),(int,float))]
  doc['case_intervals'].append({'case_id':case['id'],'type':'public','low':min(vals) if vals else None,'high':max(vals) if vals else None})
 for case in m['reserved_cases']:
  vals=[x['result'].get('metric') for x in results if x['case_id']==case['id'] and isinstance(x['result'].get('metric'),(int,float))]
  doc['case_intervals'].append({'case_id':case['id'],'type':'reserved','low':min(vals) if vals else None,'high':max(vals) if vals else None})
 if asjson: print(json.dumps(doc,sort_keys=True)); return
 print(f'# Policy experiment {i}\n\nVerdict: **{verdict}**\n\n- Primary metric: {m["primary_metric"]}\n- Delta: {delta}\n- Quality: {doc["quality"]}\n- Cost: {doc["cost"]}\n- Tokens: {doc["tokens"]}\n- Duration (seconds): {doc["duration_seconds"]}\n- Failures: {len(doc["failures"])}\n- Per-case intervals: {doc["case_intervals"]}\n\nHuman action: '+doc['human_action'])

if cmd=='validate' or cmd=='run':
 if len(args)!=1: die(f'{cmd} requires <experiment.yaml>')
 m=load(args[0]); validate(m)
 exp=data/m['id']
 if cmd=='validate':
  # Validate all immutable inputs without modifying source policy.
  copy_inputs(m,exp)
  (exp/'manifest.yaml').write_text(Path(args[0]).read_text()); (exp/'manifest.yaml').chmod(0o600)
  (exp/'state').write_text('validated\n'); print('validated'); sys.exit(0)
 if not (exp/'manifest.yaml').is_file(): die('validate the experiment before run')
 if (exp/'manifest.yaml').read_bytes()!=Path(args[0]).read_bytes(): die('manifest differs from validated manifest')
 run(m,exp)
 print((exp/'state').read_text().strip())
elif cmd=='report':
 if len(args) not in (1,2) or (len(args)==2 and args[1]!='--json'): die('report requires <experiment-id> [--json]')
 report(args[0],len(args)==2)
else: usage(); sys.exit(2)
PY
