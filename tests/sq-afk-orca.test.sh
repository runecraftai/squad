#!/usr/bin/env bash
# Fake Orca CLI + real native receiver module + public AFK helper regressions.
# This is NOT a real Orca runtime, Pi provider, or Android acceptance test.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
node --experimental-strip-types --disable-warning=MODULE_TYPELESS_PACKAGE_JSON --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync, readdirSync, symlinkSync, unlinkSync, lstatSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawnSync, spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
const root = process.env.ROOT;
const home = mkdtempSync(resolve(tmpdir(), 'sq-afk-orca-'));
const state = `${home}/state`, fake = `${home}/fake`;
mkdirSync(state); mkdirSync(fake);
const db = `${home}/orca.json`, log = `${home}/calls.jsonl`;
const endpoint = (handle, title = 'primary') => ({ handle, title, incarnationId: `inc-${handle}`, worktreeId: 'repo::' + home, worktreePath: home, connected: true, writable: true, orphaned: false, executionHostId: 'local' });
let model = { runtime: 'runtime-1', ready: true, terms: [endpoint('term-primary'), endpoint('term-foreign')], count: 0 };
const save = () => writeFileSync(db, JSON.stringify(model));
const reload = () => model = JSON.parse(readFileSync(db));
save();
writeFileSync(`${fake}/orca`, `#!/usr/bin/env node
const fs = require('fs'); const p = process.env.ORCA_TEST_DB; const d = JSON.parse(fs.readFileSync(p)); const a = process.argv.slice(2);
fs.appendFileSync(process.env.ORCA_TEST_LOG, JSON.stringify(a)+'\\n');
const value = k => a[a.indexOf(k)+1]; const out = result => console.log(JSON.stringify({ok:true,result,_meta:{runtimeId:d.runtime}}));
if(a[0]==='status') { out({runtime:{runtimeId:d.runtime,reachable:d.ready,state:d.ready?'ready':'stopped',appVersion:'FAKE'}}); }
else if(a[0]==='terminal' && a[1]==='show') { const t = d.terms.find(t=>t.handle===value('--terminal')); if(t) out({terminal: d.mismatch ? {...t,handle:'term-other'}:t}); else { console.log(JSON.stringify({ok:false,error:{code:'terminal_handle_not_found'}})); process.exitCode=1; } }
else if(a[0]==='terminal' && a[1]==='list') { if(d.unreadable) process.exit(1); out({terminals:d.terms,truncated:false}); }
else if(a[0]==='terminal' && a[1]==='create') { const t = {handle:'term-daemon-'+(++d.count),title:value('--title'),incarnationId:'daemon-inc-'+d.count,worktreeId:'repo::'+process.env.SQUAD_BASE,worktreePath:process.env.SQUAD_BASE,connected:true,writable:true,orphaned:false,executionHostId:'local'}; d.terms.push(t); if(d.executeCommand) { const env={...process.env}; delete env.PI_CODING_AGENT; delete env.TMUX_PANE; delete env.TMUX; const child=require('child_process').spawn('bash',['-c',value('--command')],{detached:true,stdio:['ignore',fs.openSync(process.env.SQUAD_BASE+'/daemon-output.txt','a'),fs.openSync(process.env.SQUAD_BASE+'/daemon-output.txt','a')],env});d.spawnedPid=child.pid;child.unref(); } fs.writeFileSync(p,JSON.stringify(d)); if(d.lostCreate) process.exit(1); out({terminal:t}); }
else if(a[0]==='terminal' && a[1]==='close') { if(d.cancelClose) {out({cancelled:true});} else {d.terms=d.terms.filter(t=>t.handle!==value('--terminal'));fs.writeFileSync(p,JSON.stringify(d));out({});} }
else { console.error('forbidden fake Orca operation '+JSON.stringify(a)); process.exit(99); }
`);
chmodSync(`${fake}/orca`, 0o700);
writeFileSync(`${fake}/ps`, '#!/usr/bin/env bash\nif [ "${ORCA_TEST_UNKNOWN:-}" = 1 ]; then case "$*" in *comm*) echo test ;; *ppid*) echo 1 ;; esac; else exec /usr/bin/ps "$@"; fi\n');
chmodSync(`${fake}/ps`, 0o700);
Object.assign(process.env, { SQUAD_BASE:home, SQUAD_STATE_OVERRIDE:state, SQUAD_SUPERVISOR_BACKEND:'orca', SQUAD_SUPERVISOR_TARGET:'term-primary', PI_CODING_AGENT:'true', ORCA_TEST_DB:db, ORCA_TEST_LOG:log, PATH:`${fake}:${process.env.PATH}` });
delete process.env.CLAUDECODE; delete process.env.SQUAD_PI_HARNESS; delete process.env.ORCA_ENVIRONMENT; delete process.env.ORCA_PAIRING_CODE;
const env = () => ({...process.env, SQUAD_AFK_LAUNCH_ENTRY:'/bin/true'});
const cli = (action, overrides = {}) => spawnSync('bash', [`${root}/bin/sq-afk-launch.sh`, action], {env:{...env(),...overrides},encoding:'utf8'});
const calls = () => readFileSync(log,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const count = command => calls().filter(a=>a[1]===command).length;
const check = name => console.log('ok - '+name);
const script = code => spawnSync('bash', ['-c', code], {env:env(),encoding:'utf8'});
let timers = [];
const oldSet = globalThis.setInterval, oldClear = globalThis.clearInterval;
globalThis.setInterval = fn => { const t={fn,unref(){}};timers.push(t);return t; };
globalThis.clearInterval = t => {timers=timers.filter(v=>v!==t);};
let tracked = [];
let handlers = new Map(), sent = [], idle = true, draft = '', failSend = false, consume = false;
const emit = async (name, ...args) => { for(const handler of handlers.get(name)||[]) await handler(...args); };
const pi = {on(name,fn){handlers.set(name,[...(handlers.get(name)||[]),fn]);},async sendUserMessage(message){sent.push(message);if(consume) await emit('before_agent_start',{prompt:message});if(failSend) throw Error('accepted then connection lost');}};
const context = {mode:'tui',hasUI:true,isIdle:()=>idle,ui:{getEditorText:()=>draft}};
const tick = async () => { for(const t of [...timers]) await t.fn(); await new Promise(r=>setImmediate(r)); };
const nativeDir = () => script(`bash '${root}/bin/sq-supervisor-native.sh' dir '${state}' term-primary`).stdout.trim();
const flush = (item = '') => script(`. '${root}/bin/sq-supervise-daemon.sh'; ${item ? `escalate_add '${state}' '${item}';` : ''} escalate_flush '${state}'`);
try {
  // Every non-Pi adapter is refused by name before creating even its state dir.
  for(const harness of ['claude','codex','opencode','grok','kimi','muse','pi-signed','unknown']) {
    const oldTitle=process.title; process.title=harness==='unknown'?'test':harness;
    const missing=`${home}/missing-${harness}`;
    const overrides={PI_CODING_AGENT:'',CLAUDECODE:'',GROK_AGENT:'',SQUAD_PI_HARNESS:'',SQUAD_SUPERVISOR_HARNESS:harness,SQUAD_STATE_OVERRIDE:missing};
    if(harness==='unknown') overrides.ORCA_TEST_UNKNOWN='1';
    if(harness==='claude') overrides.CLAUDECODE='1';
    if(harness==='grok') overrides.GROK_AGENT='1';
    if(harness==='pi-signed') Object.assign(overrides,{PI_CODING_AGENT:'true',SQUAD_PI_HARNESS:'pi-signed'});
    for(const entry of ['sq-afk-launch.sh','sq-afk-start.sh','sq-supervise-daemon.sh']) {
      const r=spawnSync('bash',[`${root}/bin/${entry}`,'start'],{encoding:'utf8',env:{...env(),...overrides}});
      assert.notEqual(r.status,0,`${entry}: ${harness} unexpectedly supported`);
      // direct starter takes no positional start; the other entries exercise native preflight.
      assert.match(r.stderr,new RegExp(`harness '${harness}' is unsupported`));
      assert.equal(existsSync(missing),false,`${entry} mutated state before refusal`);
    }
    process.title=oldTitle;
  }
  check('all unproven harnesses refuse by name before any state or Orca mutation');
  model.ready=false;save(); let r=cli('start'); assert.notEqual(r.status,0);assert.match(r.stderr,/reachable ready runtime/);assert.equal(count('create'),0);
  model.ready=true; model.mismatch=true;save();r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/mismatched/);assert.equal(count('create'),0);
  delete model.mismatch;save();r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/readiness is missing/);assert.equal(existsSync(`${state}/.afk`),false);
  check('unready runtime, target mismatch and missing native receiver refuse before mutation');
  writeFileSync(`${state}/.lock`,String(process.pid));
  const mod=await import(pathToFileURL(`${root}/.pi/extensions/sq-primary-away-handoff.ts`).href);mod.default(pi);
  mkdirSync(`${home}/outside`);symlinkSync(`${home}/outside`,`${state}/.away-handoff`);
  await emit('session_start',{},context);await tick();assert.deepEqual(readdirSync(`${home}/outside`),[]);
  await emit('session_shutdown');assert.ok(lstatSync(`${state}/.away-handoff`).isSymbolicLink());unlinkSync(`${state}/.away-handoff`);
  check('native directory confinement refuses a symlink before creating or writing through it');
  await emit('session_start',{},context); await tick();
  const dir=nativeDir(); assert.ok(existsSync(`${dir}/ready.json`));
  // A primary without its ownership lock is never a usable receiver.
  writeFileSync(`${state}/.lock`,'1');r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/not the primary/);writeFileSync(`${state}/.lock`,String(process.pid));
  r=cli('start');assert.equal(r.status,0,r.stderr);reload();assert.equal(model.terms.length,3);assert.equal(count('create'),1);
  const record=readFileSync(`${state}/.afk-daemon-terminal`,'utf8');assert.match(record,/^orca\tterm-daemon-1\t/);
  assert.equal(calls().find(a=>a[1]==='create').includes('--focus'),false);
  r=cli('status');assert.match(r.stdout,/active=1 terminal=alive daemon=dead/);assert.notEqual(r.status,0);
  check('public start/status bind the exact primary and create one unfocused daemon terminal');
  // The shell guard must apply the receiver's owner-only rule (any group/other
  // bit refuses), not a '-perm -077' all-bits test that accepts 0755.
  chmodSync(dir,0o755);let permissive=flush('signal: permissive receiver directory');assert.notEqual(permissive.status,0);assert.equal(existsSync(`${dir}/request.json`),false);chmodSync(dir,0o700);
  chmodSync(`${state}/.away-handoff`,0o750);permissive=flush('signal: permissive handoff directory');assert.notEqual(permissive.status,0);assert.equal(existsSync(`${dir}/request.json`),false);chmodSync(`${state}/.away-handoff`,0o700);
  rmSync(`${state}/.subsuper-escalations`,{force:true});rmSync(`${state}/.subsuper-escalations.since`,{force:true});
  check('group/other-accessible replacement directories are refused before publishing');
  let f=flush('signal: bounded test');assert.notEqual(f.status,0);assert.ok(existsSync(`${dir}/request.json`));assert.equal(sent.length,0);
  idle=false;await tick();assert.equal(sent.length,0);idle=true;draft='do not touch';await tick();assert.equal(sent.length,0);draft='';await emit('ui_prompt_start');await tick();assert.equal(sent.length,0);
  await emit('ui_prompt_end');consume=true;await tick();assert.equal(sent.length,1);assert.equal(JSON.parse(readFileSync(`${dir}/result.json`)).status,'handled');
  f=flush();assert.equal(f.status,0,f.stderr);assert.equal(readFileSync(`${state}/.subsuper-escalations`,'utf8'),'');assert.equal(sent.length,1);
  check('busy, draft and open prompt defer; native consumption retires only the acknowledged escalation');
  consume=false; failSend=true;f=flush('signal: uncertain send');await tick();assert.equal(sent.length,2);assert.equal(JSON.parse(readFileSync(`${dir}/result.json`)).status,'uncertain');
  await tick();flush();await tick();assert.equal(sent.length,2);
  r=cli('stop');assert.notEqual(r.status,0);assert.match(r.stderr,/stop is not complete/);assert.ok(existsSync(`${state}/.afk`));assert.equal(count('close'),0);
  model.terms[0].connected=false;save();await tick();assert.notEqual(cli('start').status,0);assert.equal(sent.length,2);
  model.terms[0].connected=true;save();await tick();flush();await tick();assert.equal(sent.length,2);
  const req=JSON.parse(readFileSync(`${dir}/request.json`));
  for(const status of ['submitting','queued','uncertain']) {
    writeFileSync(`${dir}/result.json`,JSON.stringify({id:req.id,status,endpoint:req.endpoint,receiver:req.receiver}));
    await tick();flush();await tick();assert.equal(sent.length,2,`${status} was replayed`);
  }
  await emit('before_agent_start',{prompt:`Quoted marker: [SQUAD_NATIVE_AWAY:${req.id}]`});assert.notEqual(JSON.parse(readFileSync(`${dir}/result.json`)).status,'handled');
  await emit('session_shutdown');assert.notEqual(cli('start').status,0); // same terminal, now without a live native receiver
  await emit('session_start',{},context);await tick();flush();await tick();assert.equal(sent.length,2);
  model.runtime='runtime-2';save();await tick();assert.notEqual(cli('start').status,0);assert.equal(sent.length,2);model.runtime='runtime-1';save();
  check('uncertain send, reconnect, receiver restart and runtime restart never replay or complete stop');
  // Exact old acknowledgement can settle uncertainty; a wrong one cannot.
  writeFileSync(`${dir}/result.json`,JSON.stringify({id:req.id,status:'handled',endpoint:req.endpoint,receiver:{...req.receiver,pid:1}}));
  assert.notEqual(cli('stop').status,0);
  writeFileSync(`${dir}/result.json`,JSON.stringify({id:req.id,status:'handled',endpoint:req.endpoint,receiver:req.receiver}));
  r=cli('stop');assert.equal(r.status,0,r.stderr);reload();assert.equal(model.terms.length,2);assert.ok(model.terms.some(t=>t.handle==='term-foreign'));assert.equal(existsSync(`${state}/.afk`),false);
  check('only exact consumed ack releases stop; cleanup preserves foreign terminal and worktree');
  failSend=false;await tick();r=cli('start');assert.equal(r.status,0,r.stderr);reload();const daemon=model.terms.find(t=>t.title.startsWith('sq-afk-'));
  const sleeper=spawn('sleep',['60']);tracked.push(sleeper);
  const lock=`${state}/.supervise-daemon.lock`;mkdirSync(lock);
  writeFileSync(`${lock}/pid`,String(sleeper.pid));
  const identity=script(`. '${root}/bin/sq-stand-to-lib.sh'; fm_pid_identity '${sleeper.pid}'`);
  assert.equal(identity.status,0);writeFileSync(`${lock}/pid-identity`,identity.stdout.trim());writeFileSync(`${lock}/orca-owner`,'different-owner');
  r=cli('stop');assert.notEqual(r.status,0);assert.match(r.stderr,/process ownership does not match/);assert.equal(sleeper.exitCode,null);assert.equal(count('close'),1);
  sleeper.kill('SIGTERM');await new Promise(resolve=>sleeper.once('exit',resolve));tracked=[];rmSync(lock,{recursive:true});
  check('stop refuses to signal a live process whose exact ownership token differs');
  daemon.incarnationId='foreign-incarnation';save();r=cli('stop');assert.notEqual(r.status,0);assert.ok(existsSync(`${state}/.afk`));assert.equal(count('close'),1);
  daemon.incarnationId='daemon-inc-'+model.count;save();model.cancelClose=true;save();r=cli('stop');assert.notEqual(r.status,0);assert.ok(existsSync(`${state}/.afk`));assert.ok(existsSync(`${state}/.afk-daemon-terminal`));
  model.cancelClose=false;save();r=cli('reconcile');assert.equal(r.status,0,r.stderr);reload();assert.equal(model.terms.length,2);assert.equal(existsSync(`${state}/.afk-daemon-terminal`),false);
  check('changed endpoint and cancelled close preserve lifecycle; dead-daemon reconcile closes only owned endpoint');
  await tick();model.executeCommand=true;save();r=cli('start',{SQUAD_AFK_LAUNCH_ENTRY:''});assert.equal(r.status,0,r.stderr+'\n'+readFileSync(`${home}/daemon-output.txt`,'utf8'));reload();
  r=cli('status');assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/active=1 terminal=alive daemon=alive/);
  const createdWhileAlive=count('create');const foreignDir=script(`bash '${root}/bin/sq-supervisor-native.sh' dir '${state}' term-foreign`).stdout.trim();
  const foreignEndpoint=JSON.parse(script(`bash '${root}/bin/sq-supervisor-native.sh' endpoint orca term-foreign`).stdout);
  mkdirSync(foreignDir,{recursive:true,mode:0o700});writeFileSync(`${foreignDir}/ready.json`,JSON.stringify({...JSON.parse(readFileSync(`${dir}/ready.json`)),endpoint:foreignEndpoint,heartbeat:Date.now()}));
  r=cli('start',{SQUAD_SUPERVISOR_TARGET:'term-foreign'});assert.notEqual(r.status,0);assert.match(r.stderr,/already bound to primary handle 'term-primary'/);assert.equal(count('create'),createdWhileAlive);assert.ok(existsSync(`${state}/.afk`));
  rmSync(foreignDir,{recursive:true,force:true});
  check('an already running daemon refuses another ready primary with an actionable refusal');
  model.terms[0].incarnationId='inc-term-primary-rebound';save();
  const reboundEndpoint=JSON.parse(script(`bash '${root}/bin/sq-supervisor-native.sh' endpoint orca term-primary`).stdout);
  writeFileSync(`${dir}/ready.json`,JSON.stringify({...JSON.parse(readFileSync(`${dir}/ready.json`)),endpoint:reboundEndpoint,heartbeat:Date.now()}));
  r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/changed identity since this daemon was launched \(recorded runtime=runtime-1 incarnation=inc-term-primary; current runtime=runtime-1 incarnation=inc-term-primary-rebound\)/);assert.equal(count('create'),createdWhileAlive);assert.ok(existsSync(`${state}/.afk`));
  model.terms[0].incarnationId='inc-term-primary';save();await tick();
  check('a same-handle primary rebind refuses naming recorded and current identities, not a primary switch');
  r=cli('stop');assert.equal(r.status,0,r.stderr);reload();assert.equal(model.terms.length,2);delete model.executeCommand;delete model.spawnedPid;save();
  check('public helpers start and stop the real daemon process inside a fake Orca terminal without inherited Pi environment');
  await tick();model.lostCreate=true;model.unreadable=true;save();r=cli('start');assert.notEqual(r.status,0);assert.match(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),/^orca\tpending\t/);const n=count('create');r=cli('start');assert.notEqual(r.status,0);assert.equal(count('create'),n);
  reload();model.unreadable=false;save();r=cli('reconcile');assert.equal(r.status,0,r.stderr);reload();assert.equal(model.terms.length,2);
  check('lost create response persists intent, refuses duplicate create, and recovers exact title/identity only');
  assert.equal(calls().some(a=>a[1]==='send'||a[0]==='worktree'||a.includes('--tab')),false);
  await emit('session_shutdown');
} finally {
  globalThis.setInterval=oldSet;globalThis.clearInterval=oldClear;
  for(const child of tracked) child.kill('SIGTERM');
  reload();
  if(model.spawnedPid) {
    try { const cmd=readFileSync(`/proc/${model.spawnedPid}/cmdline`,'utf8');if(cmd.includes('sq-supervise-daemon.sh')) process.kill(model.spawnedPid,'SIGTERM'); } catch {}
  }
  rmSync(home,{recursive:true,force:true});
}
JS
