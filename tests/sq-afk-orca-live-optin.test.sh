#!/usr/bin/env bash
# Real interactive Pi receiver on a private PTY; Orca identity CLI is FAKE.
# This proves native editor/modal APIs and consumption, NOT real Orca/mobile E2E.
set -eu
if [ "${SQUAD_ORCA_PI_LIVE:-0}" != 1 ]; then
  echo 'skip: set SQUAD_ORCA_PI_LIVE=1 and SQUAD_ORCA_PI_MODEL for credentialed real-Pi native delivery (fake Orca identity)'
  exit 0
fi
: "${SQUAD_ORCA_PI_MODEL:?set an authorized Pi model for the live receiver test}"
command -v pi >/dev/null || { echo 'not ok - Pi is not installed' >&2; exit 1; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
python3 <<'PY'
import os, pty, subprocess, tempfile, json, pathlib, time, select, signal, shutil
root = pathlib.Path(os.environ['ROOT'])
lab = pathlib.Path(tempfile.mkdtemp(prefix='orca-native-live-')).resolve()
state = lab/'state'; state.mkdir(); fake = lab/'fake'; fake.mkdir()
version = subprocess.check_output(['pi','--version'],text=True).strip()
(fake/'orca').write_text('''#!/usr/bin/env python3
import os,json,sys
h=os.environ['SQUAD_BASE'];a=sys.argv[1:]
if a[0]=='status': r={'runtime':{'runtimeId':'FAKE-native-live','reachable':True,'state':'ready'}}
elif a[:2]==['terminal','show']: r={'terminal':{'handle':'term-live','incarnationId':'FAKE-incarnation','worktreeId':'FAKE::'+h,'worktreePath':h,'connected':True,'writable':True,'orphaned':False,'executionHostId':'local'}}
else: sys.exit('forbidden fake Orca operation')
print(json.dumps({'ok':True,'result':r,'_meta':{'runtimeId':'FAKE-native-live'}}))
'''); (fake/'orca').chmod(0o700)
fixture = lab/'fixture.ts'
fixture.write_text('''import {writeFileSync} from 'node:fs';
export default function(pi) {
 pi.on('session_start',()=>writeFileSync(process.env.SQUAD_STATE_OVERRIDE+'/.lock',String(process.pid)));
 pi.registerCommand('native-draft',{description:'Test native draft',handler:async(_,ctx)=>{ctx.ui.setEditorText('DO_NOT_SUBMIT_THIS_DRAFT');}});
 pi.registerCommand('native-modal',{description:'Test native modal',handler:async(_,ctx)=>{await ctx.ui.confirm('Native modal guard','Dismiss with Escape');}});
}
''')
env = {**os.environ,'SQUAD_BASE':str(lab),'SQUAD_STATE_OVERRIDE':str(state),'SQUAD_SUPERVISOR_BACKEND':'orca','SQUAD_SUPERVISOR_TARGET':'term-live','PI_CODING_AGENT':'true','PATH':str(fake)+':'+os.environ['PATH'],'TERM':'xterm-256color'}
for key in ['ORCA_ENVIRONMENT','ORCA_PAIRING_CODE','CLAUDECODE','SQUAD_PI_HARNESS','DRILL_GATE','NO_MISTAKES_GATE']: env.pop(key,None)
pid, master = pty.fork()
if pid == 0:
 os.chdir(lab)
 os.execvpe('pi',['pi','--no-session','--no-context-files','--no-skills','--no-extensions','-e',str(root/'.pi/extensions/sq-primary-away-handoff.ts'),'-e',str(fixture),'--model',env['SQUAD_ORCA_PI_MODEL'],'--thinking','low','--tools','read'],env)
output = bytearray()
def drain():
 while select.select([master],[],[],0)[0]:
  try: output.extend(os.read(master,65536))
  except OSError: break
def wait(predicate, label, timeout=100):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  drain()
  if predicate(): return
  done,_=os.waitpid(pid,os.WNOHANG)
  if done: raise AssertionError('Pi exited before '+label+'\n'+output.decode(errors='replace')[-3000:])
  time.sleep(.1)
 raise AssertionError('timeout: '+label+'\n'+output.decode(errors='replace')[-3000:])
def read(path):
 try: return json.loads(path.read_text())
 except (OSError,ValueError): return {}
dir = pathlib.Path(subprocess.check_output(['bash',str(root/'bin/sq-supervisor-native.sh'),'dir',str(state),'term-live'],env=env,text=True).strip())
def ready(): return read(dir/'ready.json')
def command(text): os.write(master,text.encode()+b'\r')
def flush(item=''):
 code=f". '{root}/bin/sq-supervise-daemon.sh'; "
 if item: code+=f"escalate_add '{state}' '{item}'; "
 return subprocess.run(['bash','-c',code+f"escalate_flush '{state}'"],env=env,capture_output=True,text=True)
def handled():
 req=read(dir/'request.json'); result=read(dir/'result.json')
 return bool(req.get('id') and result.get('id')==req['id'] and result.get('status')=='handled')
try:
 wait(lambda:bool(ready()),'native readiness')
 (state/'.afk').write_text(str(time.time()))
 command('/native-draft')
 wait(lambda:ready().get('draft') is True,'real native editor draft')
 assert flush('Reply exactly NATIVE_ORCA_DRAFT_OK. Do not use tools.').returncode != 0
 time.sleep(2);drain();assert not handled(),'draft was submitted'
 os.write(master,b'\x15') # user clears their own draft on this private PTY
 wait(handled,'draft-cleared native consumption')
 assert flush().returncode==0
 wait(lambda:ready().get('idle') is True,'agent idle after native message')
 command('/native-modal')
 wait(lambda:ready().get('prompts',0)>0,'real built-in modal event')
 assert flush('Reply exactly NATIVE_ORCA_MODAL_OK. Do not use tools.').returncode != 0
 time.sleep(2);drain();assert not handled(),'modal was bypassed'
 os.write(master,b'\x1b')
 wait(handled,'modal-cleared native consumption')
 assert flush().returncode==0
 print('ok - Pi '+version+' real interactive editor and built-in modal defer native delivery until safe; exact consumed acknowledgements retire both requests')
 print('limit - Orca CLI identity was fake; no real Orca runtime, daemon terminal lifecycle, or Android acceptance claimed')
finally:
 try: os.kill(pid,signal.SIGTERM)
 except ProcessLookupError: pass
 try: os.waitpid(pid,0)
 except ChildProcessError: pass
 os.close(master)
 shutil.rmtree(lab)
PY
