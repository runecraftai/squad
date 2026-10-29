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
import { once } from 'node:events';
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
if(a[0]==='status') { if(d.failStatus) process.exit(1); out({runtime:{runtimeId:d.runtime,reachable:d.ready,state:d.ready?'ready':'stopped',appVersion:'FAKE'}}); }
else if(a[0]==='terminal' && a[1]==='show') { if(d.failShow) process.exit(1); const t = d.terms.find(t=>t.handle===value('--terminal')); if(t) out({terminal: d.mismatch ? {...t,handle:'term-other'}:t}); else { console.log(JSON.stringify({ok:false,error:{code:'terminal_handle_not_found'}})); process.exitCode=1; } }
else if(a[0]==='terminal' && a[1]==='list') { if(d.unreadable) process.exit(1); out({terminals:d.terms,truncated:!!d.truncated,hostScope:{omittedHostIds:d.omitted?['local']:[]}}); }
else if(a[0]==='terminal' && a[1]==='create') { const t = d.createPrimary ? d.terms.find(x=>x.handle==='term-primary') : {handle:'term-daemon-'+(++d.count),title:value('--title'),incarnationId:'daemon-inc-'+d.count,worktreeId:'repo::'+process.env.SQUAD_BASE,worktreePath:process.env.SQUAD_BASE,connected:true,writable:true,orphaned:false,executionHostId:'local'}; if(!d.createPrimary) d.terms.push(t); if(d.executeCommand) { const env={...process.env}; delete env.PI_CODING_AGENT; delete env.TMUX_PANE; delete env.TMUX; const child=require('child_process').spawn('bash',['-c',value('--command')],{detached:true,stdio:['ignore',fs.openSync(process.env.SQUAD_BASE+'/daemon-output.txt','a'),fs.openSync(process.env.SQUAD_BASE+'/daemon-output.txt','a')],env});d.spawnedPid=child.pid;child.unref(); } fs.writeFileSync(p,JSON.stringify(d)); if(d.lostCreate) process.exit(1); out({terminal:{...t,worktreePath:undefined}}); }
else if(a[0]==='terminal' && a[1]==='close') { if(d.cancelClose) {out({cancelled:true});} else {d.terms=d.terms.filter(t=>t.handle!==value('--terminal'));fs.writeFileSync(p,JSON.stringify(d));out({});} }
else { console.error('forbidden fake Orca operation '+JSON.stringify(a)); process.exit(99); }
`);
chmodSync(`${fake}/orca`, 0o700);
const realPs = ['/bin/ps', '/usr/bin/ps'].find(path => existsSync(path));
assert.ok(realPs, 'no system ps found for the fake ps shim');
writeFileSync(`${fake}/ps`, `#!/usr/bin/env bash\nif [ "\${ORCA_TEST_UNKNOWN:-}" = 1 ]; then case "$*" in *comm*) echo test ;; *ppid*) echo 1 ;; esac; else exec ${realPs} "$@"; fi\n`);
chmodSync(`${fake}/ps`, 0o700);
mkdirSync(`${fake}/nomux`);
writeFileSync(`${fake}/nomux/tmux`, '#!/usr/bin/env bash\nexit 1\n');
chmodSync(`${fake}/nomux/tmux`, 0o700);
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
const baseSelection = { backend: process.env.SQUAD_SUPERVISOR_BACKEND, target: process.env.SQUAD_SUPERVISOR_TARGET };
const runtimeIdentity = { handle: 'term-primary', worktree: `repo::${home}` };
globalThis.setInterval = fn => { const t={fn,unref(){}};timers.push(t);return t; };
globalThis.clearInterval = t => {timers=timers.filter(v=>v!==t);};
let tracked = [];
let handlers = new Map(), sent = [], idle = true, draft = '', failSend = false, consume = false, structured = false;
const emit = async (name, ...args) => { for(const handler of handlers.get(name)||[]) await handler(...args); };
const pi = {on(name,fn){handlers.set(name,[...(handlers.get(name)||[]),fn]);},async sendUserMessage(message){sent.push(message);if(consume) await emit('before_agent_start',{prompt:structured?{content:[{type:'text',text:message}]}:message});if(failSend) throw Error('accepted then connection lost');}};
const context = {mode:'tui',hasUI:true,isIdle:()=>idle,ui:{getEditorText:()=>draft}};
const tick = async () => { for(const t of [...timers]) await t.fn(); await new Promise(r=>setImmediate(r)); };
const nativeDir = (handle = 'term-primary') => script(`bash '${root}/bin/sq-supervisor-native.sh' dir '${state}' '${handle}'`).stdout.trim();
const readyPath = handle => `${nativeDir(handle)}/ready.json`;
const daemonRecord = () => {
  const record = readFileSync(`${state}/.afk-daemon-terminal`,'utf8');
  const fields = record.split('\t');
  return { backend: fields[0], extra: JSON.parse(fields[2]) };
};
const publishedReadiness = () => {
  const handoff = `${state}/.away-handoff`;
  if (!existsSync(handoff)) return [];
  return readdirSync(handoff).flatMap(name => existsSync(`${handoff}/${name}/ready.json`) ? [`${name}/ready.json`] : []);
};
// Ambient multiplexer markers would make the launcher adopt a detected supervisor
// pane instead of evaluating the runtime identity the case is proving, and a
// reachable tmux server would settle its Squad:0 fallback. Both are neutralized so
// only the runtime identity can resolve a supervisor.
const noDetectedPane = { PATH:`${fake}/nomux:${process.env.PATH}`, TMUX_PANE:'', TMUX:'', HERDR_ENV:'', HERDR_PANE_ID:'', TUIOS_ENV:'', TUIOS_SESSION:'', TUIOS_PANE_ID:'' };
const clearDetectedPane = () => { for (const key of ['TMUX_PANE','TMUX','HERDR_ENV','HERDR_PANE_ID','TUIOS_ENV','TUIOS_SESSION','TUIOS_PANE_ID']) delete process.env[key]; };
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
      assert.match(r.stderr,/SQUAD_SUPERVISOR_HARNESS=pi/,`${entry}: refusal did not name the proven selector`);
      assert.equal(existsSync(missing),false,`${entry} mutated state before refusal`);
    }
    process.title=oldTitle;
  }
  check('all unproven harnesses refuse by name before any state or Orca mutation');
  // With no selector at all, detection must name the selector and the ancestry
  // requirement instead of claiming Pi's own proof is what is missing.
  {
    const missing=`${home}/missing-detected`;
    const r=spawnSync('bash',[`${root}/bin/sq-afk-start.sh`,'start'],{encoding:'utf8',env:{...env(),PI_CODING_AGENT:'',CLAUDECODE:'',GROK_AGENT:'',SQUAD_PI_HARNESS:'',SQUAD_SUPERVISOR_HARNESS:'',SQUAD_STATE_OVERRIDE:missing,ORCA_TEST_UNKNOWN:'1'}});
    assert.notEqual(r.status,0);
    assert.match(r.stderr,/detection resolved 'unknown'/);
    assert.match(r.stderr,/ancestry/);
    assert.match(r.stderr,/SQUAD_SUPERVISOR_HARNESS=pi/);
    assert.doesNotMatch(r.stderr,/is unsupported/);
    assert.equal(existsSync(missing),false,'unresolved detection mutated state before refusal');
  }
  check('unresolved harness detection refuses with the selector and ancestry requirement');
  model.ready=false;save(); let r=cli('start'); assert.notEqual(r.status,0);assert.match(r.stderr,/reachable ready runtime/);assert.equal(count('create'),0);
  // A failing Orca CLI must name the failed command and its recovery instead of
  // exiting nonzero with only whatever the CLI happened to print.
  model.ready=true;model.failStatus=true;save();r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/orca status --json failed/);assert.match(r.stderr,/start the selected local Orca host/);assert.equal(count('create'),0);
  model.failStatus=false;model.failShow=true;save();r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/orca terminal show --terminal term-primary --json` failed/);assert.match(r.stderr,/verify that exact runtime-issued handle/);assert.equal(count('create'),0);
  model.failShow=false;save();
  check('a failing Orca CLI refuses with the failed command and its recovery');
  model.ready=true; model.mismatch=true;save();r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/mismatched/);assert.equal(count('create'),0);
  delete model.mismatch;save();r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/readiness is missing/);assert.equal(existsSync(`${state}/.afk`),false);
  check('unready runtime, target mismatch and missing native receiver refuse before mutation');
  // An owner-only handoff directory without a readiness record must name the
  // missing proof instead of exiting 1 with no output.
  const bareDir=script(`bash '${root}/bin/sq-supervisor-native.sh' dir '${state}' term-primary`).stdout.trim();
  mkdirSync(`${state}/.away-handoff`,{mode:0o700});mkdirSync(bareDir,{mode:0o700});
  r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/readiness record is missing/);assert.equal(existsSync(`${state}/.afk`),false);
  assert.match(r.stderr,/ORCA_TERMINAL_HANDLE/,'the unreadable-record refusal did not name the runtime identity route');
  assert.match(r.stderr,/SQUAD_SUPERVISOR_BACKEND=orca/,'the unreadable-record refusal did not name the explicit override route');
  rmSync(bareDir,{recursive:true,force:true});rmSync(`${state}/.away-handoff`,{recursive:true,force:true});
  check('a handoff directory without a readiness record refuses with an actionable reason');
  writeFileSync(`${state}/.lock`,String(process.pid));
  const mod=await import(pathToFileURL(`${root}/.pi/extensions/sq-primary-away-handoff.ts`).href);mod.default(pi);
  clearDetectedPane();
  // A plainly launched Orca primary should adopt its own runtime-issued identity.
  delete process.env.SQUAD_SUPERVISOR_BACKEND; delete process.env.SQUAD_SUPERVISOR_TARGET;
  process.env.ORCA_TERMINAL_HANDLE=runtimeIdentity.handle; process.env.ORCA_WORKTREE_ID=runtimeIdentity.worktree;
  await emit('session_start',{},context); await tick();
  assert.ok(existsSync(readyPath(runtimeIdentity.handle)));
  r=cli('start',noDetectedPane); assert.equal(r.status,0,r.stderr);
  assert.equal(daemonRecord().backend,'orca','launcher did not bind an Orca daemon terminal');
  assert.equal(daemonRecord().extra.parent.target,runtimeIdentity.handle,'launcher did not supervise the adopted runtime handle');
  r=cli('stop'); assert.equal(r.status,0,r.stderr);
  check('runtime-issued identity publishes readiness and permits away-mode start without overrides');
  await emit('session_shutdown');
  // The documented sample config exports both variables as empty strings.
  process.env.SQUAD_SUPERVISOR_BACKEND=''; process.env.SQUAD_SUPERVISOR_TARGET='';
  process.env.ORCA_TERMINAL_HANDLE=runtimeIdentity.handle; process.env.ORCA_WORKTREE_ID=runtimeIdentity.worktree;
  await emit('session_start',{},context); await tick();
  assert.ok(existsSync(readyPath(runtimeIdentity.handle)),'exported empty supervisor values blocked readiness');
  r=cli('start',noDetectedPane); assert.equal(r.status,0,r.stderr);
  assert.equal(daemonRecord().extra.parent.target,runtimeIdentity.handle,'launcher did not adopt with exported empty supervisor values');
  r=cli('stop'); assert.equal(r.status,0,r.stderr);
  await emit('session_shutdown');
  delete process.env.SQUAD_SUPERVISOR_BACKEND; delete process.env.SQUAD_SUPERVISOR_TARGET;
  check('exported empty supervisor values count as unset for adoption');
  // Ambient runtime evidence outranks the inherited Orca identity, so the
  // receiver must not publish Orca readiness and the launcher must keep the
  // detected non-Orca target instead of adopting Orca.
  process.env.ORCA_TERMINAL_HANDLE=runtimeIdentity.handle; process.env.ORCA_WORKTREE_ID=runtimeIdentity.worktree;
  for (const [markers, label] of [
    [{TMUX_PANE:'%1', TMUX:'/tmp/fake-tmux,1,0'}, 'tmux'],
    [{HERDR_ENV:'1', HERDR_PANE_ID:'pane-1'}, 'herdr'],
    [{TUIOS_ENV:'1', TUIOS_SESSION:'tui-session', TUIOS_PANE_ID:'tui-pane'}, 'tuios'],
  ]) {
    Object.assign(process.env, markers);
    await emit('session_start',{},context); await tick();
    assert.deepEqual(publishedReadiness(),[],`${label} pane evidence still published Orca readiness`);
    await emit('session_shutdown');
    clearDetectedPane();
  }
  const createsBeforeDetected=count('create');
  r=cli('start',{...noDetectedPane, TMUX_PANE:'%1', TMUX:'/tmp/fake-tmux,1,0'});
  assert.notEqual(r.status,0,'launcher adopted Orca over a detected tmux pane');
  assert.match(r.stderr,/TMUX_PANE target '%1'/,'launcher did not keep the detected tmux target');
  assert.doesNotMatch(r.stderr,/native readiness is missing/,'launcher kept looking at Orca readiness over a detected tmux pane');
  assert.equal(count('create'),createsBeforeDetected,'launcher created a daemon terminal over a detected tmux pane');
  assert.equal(existsSync(`${state}/.afk`),false,'launcher mutated away-mode state over a detected tmux pane');
  check('detected tmux, Herdr, and TUIOS panes outrank Orca runtime identity');
  // Explicit selection keeps precedence over a different runtime-issued handle.
  process.env.SQUAD_SUPERVISOR_BACKEND=baseSelection.backend; process.env.SQUAD_SUPERVISOR_TARGET=baseSelection.target;
  process.env.ORCA_TERMINAL_HANDLE='term-foreign'; process.env.ORCA_WORKTREE_ID=runtimeIdentity.worktree;
  await emit('session_start',{},context); await tick();
  assert.ok(existsSync(`${nativeDir()}/ready.json`));
  r=cli('start'); assert.equal(r.status,0,r.stderr);
  assert.equal(daemonRecord().backend,'orca');
  assert.equal(daemonRecord().extra.parent.target,'term-primary','launcher did not bind the explicit handle');
  r=cli('stop'); assert.equal(r.status,0,r.stderr);
  await emit('session_shutdown');
  check('explicit Orca selection wins over a different runtime-issued handle in receiver and launcher');
  const adoptionCalls=calls();
  assert.equal(adoptionCalls.some(a=>a[1]==='send'||a[0]==='worktree'||a.includes('--tab')),false,'adoption issued a send, worktree or --tab call');
  const adoptionCreates=adoptionCalls.filter(a=>a[1]==='create');
  assert.equal(adoptionCreates.length,3,'adoption did not create exactly one daemon terminal per start');
  assert.equal(adoptionCreates.every(a=>!a.includes('--focus')),true,'an adopted create requested focus');
  delete process.env.SQUAD_SUPERVISOR_BACKEND; delete process.env.SQUAD_SUPERVISOR_TARGET;
  assert.deepEqual(publishedReadiness(),[],'precondition: no readiness is published before the negative cases');
  for (const [handle, worktree, label] of [
    [runtimeIdentity.handle, 'repo::/definitely/not/the/base', 'mismatched worktree path'],
    ['malformed-handle', runtimeIdentity.worktree, 'malformed runtime handle'],
    ['', runtimeIdentity.worktree, 'missing runtime handle'],
    [runtimeIdentity.handle, '', 'missing worktree identity'],
    [runtimeIdentity.handle, 'repo::', 'empty worktree path'],
  ]) {
    process.env.ORCA_TERMINAL_HANDLE=handle; process.env.ORCA_WORKTREE_ID=worktree;
    await emit('session_start',{},context); await tick();
    assert.deepEqual(publishedReadiness(),[],`${label} published readiness`);
    const createsBefore=count('create');
    r=cli('start',noDetectedPane); assert.notEqual(r.status,0,`${label} unexpectedly allowed start`);
    assert.match(r.stderr,/could not resolve the commander supervisor pane/);
    assert.equal(existsSync(`${state}/.afk`),false,`${label} mutated away-mode state`);
    assert.equal(count('create'),createsBefore,`${label} created a daemon terminal`);
    await emit('session_shutdown');
  }
  check('mismatched path, partial identity, malformed handle and missing handle publish nothing and refuse start');
  process.env.SQUAD_SUPERVISOR_BACKEND=baseSelection.backend; process.env.SQUAD_SUPERVISOR_TARGET=baseSelection.target;
  process.env.ORCA_TERMINAL_HANDLE=runtimeIdentity.handle; process.env.ORCA_WORKTREE_ID=runtimeIdentity.worktree;
  rmSync(`${state}/.away-handoff`,{recursive:true,force:true});
  model.terms=model.terms.filter(t=>!t.handle.startsWith('term-daemon-'));model.count=0;save();writeFileSync(log,'');
  mkdirSync(`${home}/outside`);symlinkSync(`${home}/outside`,`${state}/.away-handoff`);
  await emit('session_start',{},context);await tick();assert.deepEqual(readdirSync(`${home}/outside`),[]);
  await emit('session_shutdown');assert.ok(lstatSync(`${state}/.away-handoff`).isSymbolicLink());unlinkSync(`${state}/.away-handoff`);
  check('native directory confinement refuses a symlink before creating or writing through it');
  await emit('session_start',{},context); await tick();
  const dir=nativeDir(); assert.ok(existsSync(`${dir}/ready.json`));
  // The 1s heartbeat write must not invoke the blocking Orca CLI probe.
  const statusProbes=()=>calls().filter(a=>a[0]==='status').length;
  const probesBefore=statusProbes();await tick();await tick();await tick();assert.equal(statusProbes(),probesBefore);
  check('the native heartbeat tick publishes readiness without spawning Orca probes');
  // An entry-point guard and the main path it precedes share one process, so
  // the second readiness check must reuse the first verdict instead of probing
  // again inside the launcher's startup budget.
  const onceProbeBefore=statusProbes();
  const memo=script(`. '${root}/bin/sq-supervisor-native.sh'; fm_supervisor_native_ready_once '${state}' term-primary >/dev/null && fm_supervisor_native_ready_once '${state}' term-primary >/dev/null`);
  assert.equal(memo.status,0,memo.stderr);
  assert.equal(statusProbes(),onceProbeBefore+1);
  check('a readiness guard and its main path reuse one native probe per process');
  // One failed revalidation retries in seconds instead of blanking readiness for
  // the whole slow-probe window.
  const realNow=Date.now;let clock=realNow();Date.now=()=>clock;
  const heartbeat=()=>JSON.parse(readFileSync(`${dir}/ready.json`,'utf8')).heartbeat;
  clock+=30000;model.mismatch=true;save();await tick();
  const unpublished=heartbeat();model.mismatch=false;save();
  clock+=1000;await tick();assert.equal(heartbeat(),unpublished);
  clock+=5000;await tick();assert.equal(heartbeat(),clock);
  Date.now=realNow;
  await emit('session_shutdown');await emit('session_start',{},context);await tick();
  check('a failed native revalidation retries quickly instead of blanking readiness');
  // A symlinked SQUAD_BASE passes the launcher's `pwd -P` worktree gate, so the
  // receiver must resolve the same physical path instead of dropping readiness.
  await emit('session_shutdown');assert.equal(existsSync(`${dir}/ready.json`),false);
  const link=`${home}-link`;symlinkSync(home,link);process.env.SQUAD_BASE=link;
  await emit('session_start',{},context);await tick();
  const readyViaLink=script(`. '${root}/bin/sq-supervisor-native.sh'; fm_supervisor_native_ready '${state}' term-primary`);
  assert.equal(readyViaLink.status,0,readyViaLink.stderr);
  process.env.SQUAD_BASE=home;unlinkSync(link);
  await emit('session_shutdown');await emit('session_start',{},context);await tick();
  check('a symlinked SQUAD_BASE still binds the physical worktree and publishes readiness');
  // A primary without its ownership lock is never a usable receiver.
  writeFileSync(`${state}/.lock`,'1');r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/not the primary/);writeFileSync(`${state}/.lock`,String(process.pid));
  r=cli('start');assert.equal(r.status,0,r.stderr);reload();assert.equal(model.terms.length,3);assert.equal(count('create'),1);
  const record=readFileSync(`${state}/.afk-daemon-terminal`,'utf8');assert.match(record,/^orca\tterm-daemon-1\t/);
  assert.equal(calls().find(a=>a[1]==='create').includes('--focus'),false);
  r=cli('status');assert.match(r.stdout,/active=1 terminal=alive daemon=dead/);assert.notEqual(r.status,0);
  check('public start/status bind the exact primary and create one daemon terminal whose create call requests no focus flag');
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
  // Orca ownership must come from recorded/daemon state, not the caller's
  // environment: a stop without SQUAD_SUPERVISOR_BACKEND must refuse an
  // unrecorded live daemon and an unresolved native request instead of
  // reporting torn-down cleanup.
  const scopeRecord=readFileSync(`${state}/.afk-daemon-terminal`,'utf8');
  const scopeOwner=JSON.parse(scopeRecord.split('\t').slice(2).join('\t')).owner;
  rmSync(`${state}/.afk-daemon-terminal`);
  const scopedDaemon=spawn('bash',['-c','sleep 60 & echo $!; wait'],{stdio:['ignore','pipe','ignore']});tracked.push(scopedDaemon);
  const scopedPid=Number((await once(scopedDaemon.stdout,'data'))[0].toString().trim());assert.ok(scopedPid>1);
  const scopedLock=`${state}/.supervise-daemon.lock`;mkdirSync(scopedLock);
  writeFileSync(`${scopedLock}/pid`,String(scopedPid));
  const scopedIdentity=script(`. '${root}/bin/sq-stand-to-lib.sh'; fm_pid_identity '${scopedPid}'`);assert.equal(scopedIdentity.status,0);
  writeFileSync(`${scopedLock}/pid-identity`,scopedIdentity.stdout.trim());writeFileSync(`${scopedLock}/orca-owner`,scopeOwner);
  const closesBeforeScope=count('close');
  const noRuntimeIdentity={SQUAD_SUPERVISOR_BACKEND:'',SQUAD_SUPERVISOR_TARGET:'',ORCA_TERMINAL_HANDLE:'',ORCA_WORKTREE_ID:''};
  r=cli('stop',noRuntimeIdentity);
  assert.notEqual(r.status,0);assert.match(r.stderr,/no terminal ownership record/);assert.equal(scopedDaemon.exitCode,null);assert.ok(existsSync(`${state}/.afk`));assert.equal(count('close'),closesBeforeScope);
  scopedDaemon.kill('SIGTERM');await new Promise(resolve=>scopedDaemon.once('exit',resolve));tracked=tracked.filter(child=>child!==scopedDaemon);rmSync(scopedLock,{recursive:true});
  mkdirSync(`${state}/.away-handoff/unrecorded-request`,{recursive:true,mode:0o700});writeFileSync(`${state}/.away-handoff/unrecorded-request/request.json`,'{}');
  r=cli('stop',noRuntimeIdentity);
  assert.notEqual(r.status,0);assert.match(r.stderr,/unresolved without a recorded daemon terminal/);assert.ok(existsSync(`${state}/.afk`));assert.equal(count('close'),closesBeforeScope);
  rmSync(`${state}/.away-handoff/unrecorded-request`,{recursive:true,force:true});
  writeFileSync(`${state}/.afk-daemon-terminal`,scopeRecord);
  check('stop without SQUAD_SUPERVISOR_BACKEND still refuses an unrecorded Orca daemon or unresolved request');
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
  // A delivered-but-not-yet-retired request must not strand stop when the live
  // daemon still owns buffer retirement: its SIGTERM flush retires it.
  await tick();r=cli('start');assert.equal(r.status,0,r.stderr);reload();
  const consumedRecord=JSON.parse(readFileSync(`${state}/.afk-daemon-terminal`,'utf8').split('\t').slice(2).join('\t'));
  idle=true;draft='';consume=true;structured=true;await tick();
  f=flush('signal: consumed before the next batch retire');assert.notEqual(f.status,0);await tick();
  assert.ok(existsSync(`${dir}/request.json`));assert.equal(JSON.parse(readFileSync(`${dir}/result.json`)).status,'handled');structured=false;
  const closesBefore=count('close');
  // A wrapper shell keeps and reaps the exact daemon pid, so stop observes its
  // death even while this test process is blocked inside spawnSync.
  const fakeDaemon=spawn('bash',['-c','sleep 60 & echo $!; wait'],{stdio:['ignore','pipe','ignore']});tracked.push(fakeDaemon);
  const fakeDaemonPid=Number((await once(fakeDaemon.stdout,'data'))[0].toString().trim());assert.ok(fakeDaemonPid>1);
  const liveLock=`${state}/.supervise-daemon.lock`;mkdirSync(liveLock);
  writeFileSync(`${liveLock}/pid`,String(fakeDaemonPid));
  const daemonIdentity=script(`. '${root}/bin/sq-stand-to-lib.sh'; fm_pid_identity '${fakeDaemonPid}'`);assert.equal(daemonIdentity.status,0);
  writeFileSync(`${liveLock}/pid-identity`,daemonIdentity.stdout.trim());
  writeFileSync(`${liveLock}/orca-owner`,consumedRecord.owner);
  r=cli('stop');assert.equal(r.status,0,r.stderr);
  let daemonAlive=false;try{process.kill(fakeDaemonPid,0);daemonAlive=true;}catch{daemonAlive=false;}assert.equal(daemonAlive,false);
  assert.equal(existsSync(`${dir}/request.json`),false);assert.equal(existsSync(`${state}/.afk`),false);assert.equal(existsSync(`${state}/.afk-daemon-terminal`),false);
  assert.equal(count('close'),closesBefore+1);reload();assert.equal(model.terms.length,2);
  rmSync(liveLock,{recursive:true});tracked=tracked.filter(child=>child!==fakeDaemon);
  check('stop retires an already-consumed request through the live daemon shutdown flush');
  await tick();model.lostCreate=false;model.unreadable=true;save();
  // The recorded create receipt is a started session: a prior session's
  // escalation buffer must never be rolled back into the live daemon's state.
  writeFileSync(`${state}/.subsuper-escalations`,'prior session escalation\n');
  writeFileSync(`${state}/.subsuper-inject-wedged`,'prior session wedge\n');
  r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/runtime terminal inventory could not be read/);assert.doesNotMatch(r.stderr,/integer expression expected/);assert.match(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),/^orca\tpending\t/);
  assert.equal(existsSync(`${state}/.subsuper-escalations`),false,'a recorded create receipt rolled the prior escalation buffer back');
  assert.equal(existsSync(`${state}/.subsuper-inject-wedged`),false,'a recorded create receipt rolled the prior wedge marker back');
  assert.ok(existsSync(`${state}/.afk`),'a recorded create receipt must keep the away-mode flag for its daemon');
  const n=count('create');r=cli('start');assert.notEqual(r.status,0);assert.equal(count('create'),n);
  reload();model.unreadable=false;save();
  const pendingBytes=readFileSync(`${state}/.afk-daemon-terminal`,'utf8');
  const pendingExtra=JSON.parse(pendingBytes.split('\t')[2]);
  const closesBeforeAdopt=count('close');
  assert.ok(pendingExtra.endpoint.target,'create receipt was not persisted before inventory lookup');
  // status must report the recorded handle honestly and read-only: a pending
  // target is recoverable while its exact identity is live, not dead.
  r=cli('status');assert.match(r.stdout,/active=1 terminal=recoverable daemon=dead /);assert.doesNotMatch(r.stdout,/terminal=dead/);
  assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes,'status rewrote the pending record');
  model.unreadable=true;save();
  r=cli('status');assert.match(r.stdout,/active=1 terminal=uncertain daemon=dead /);assert.doesNotMatch(r.stdout,/terminal=dead/);
  assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes,'status rewrote the pending record on an unreadable census');
  model.unreadable=false;save();
  model.terms.find(t=>t.handle===pendingExtra.endpoint.target).incarnationId='changed-identity';save();
  r=cli('status');assert.match(r.stdout,/active=1 terminal=uncertain daemon=dead /);assert.doesNotMatch(r.stdout,/terminal=dead/);
  assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes,'status rewrote the pending record on a changed identity');
  model.terms.find(t=>t.handle===pendingExtra.endpoint.target).incarnationId=pendingExtra.endpoint.incarnation;save();
  check('status reports a pending recorded identity as recoverable, uncertain when unreadable or changed, and never dead');
  // Parent binding and base identity must agree independently of the title.
  for (const overrides of [{SQUAD_SUPERVISOR_TARGET:'term-foreign'}, {SQUAD_BASE:`${home}/outside`}]) {
    r=cli('start',overrides);assert.notEqual(r.status,0);assert.equal(count('create'),n);assert.equal(count('close'),closesBeforeAdopt);
    assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes);
  }
  model.terms[0].incarnationId='changed-primary';save();
  r=cli('stop');assert.notEqual(r.status,0);assert.match(r.stderr,/pending parent identity/);
  assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes);
  model.terms[0].incarnationId='inc-term-primary';save();
  // Even one valid match cannot hide another terminal with the same identity.
  const pendingTerminal=model.terms.find(t=>t.handle===pendingExtra.endpoint.target);
  const duplicate={...pendingTerminal};
  model.terms.push(duplicate);save();
  for (const action of ['start','stop','reconcile']) {
    r=cli(action);assert.notEqual(r.status,0);assert.match(r.stderr,/identity matches multiple terminal candidates/);
    assert.equal(count('create'),n);assert.equal(count('close'),closesBeforeAdopt);
    assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes);
  }
  check('multiple matches refuse start, stop and reconciliation without creating, closing or rewriting anything');
  model.terms.pop();
  for (const field of ['incarnationId','worktreeId','worktreePath']) {
    const original=pendingTerminal[field];pendingTerminal[field]='foreign-identity';save();
    for (const action of ['start','stop']) {
      r=cli(action);assert.notEqual(r.status,0);assert.equal(count('create'),n);assert.equal(count('close'),closesBeforeAdopt);
      assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes);
    }
    pendingTerminal[field]=original;
  }
  // Explicit approved release has ONE conjunctive proof: the recorded handle
  // is absent AND no unclaimed terminal shares its recorded binding. A runtime
  // or incarnation change is never itself evidence that the daemon is gone.
  const releaseClaim=`${state}/release-task.meta`;
  const claimForeign=()=>writeFileSync(releaseClaim,`backend=orca\nwindow=sq-release-task\nendpoint_task_id=release-task\nterminal=term-foreign\nworktree=${home}\nproject=${home}\n`);
  claimForeign();save();
  const beforeReleaseCreates=count('create'),beforeReleaseCloses=count('close');
  r=cli('release-pending',{SQUAD_BASE:`${home}/outside`});assert.notEqual(r.status,0);assert.match(r.stderr,/release branch=foreign-base/);
  for (const [runtime,incarnation] of [['runtime-1',pendingExtra.endpoint.incarnation],['runtime-rebound',pendingExtra.endpoint.incarnation],['runtime-rebound','recycled-incarnation']]) {
    model.runtime=runtime;pendingTerminal.incarnationId=incarnation;save();
    r=cli('release-pending');assert.notEqual(r.status,0);assert.match(r.stderr,/release branch=live-recorded-handle/);
    assert.ok(r.stderr.includes(pendingExtra.endpoint.target),'live-handle refusal did not name the recorded handle');
    assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes);
    assert.equal(count('create'),beforeReleaseCreates);assert.equal(count('close'),beforeReleaseCloses);
  }
  check('approved release refuses a live recorded handle even across runtime and incarnation changes');
  pendingTerminal.incarnationId=pendingExtra.endpoint.incarnation;
  const originalTerms=[...model.terms];
  model.terms=model.terms.filter(t=>t.handle!==pendingExtra.endpoint.target);
  model.terms.push(endpoint('term-binding-candidate','unrelated display title'));model.runtime='runtime-1';save();await tick();
  for (const action of ['release-pending','start','stop','reconcile']) {
    r=cli(action);assert.notEqual(r.status,0);assert.match(r.stderr,/branch=candidate-binding-exists/);
    assert.ok(r.stderr.includes('term-binding-candidate'),'candidate refusal omitted its handle');
    assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes);
    assert.equal(count('create'),beforeReleaseCreates);assert.equal(count('close'),beforeReleaseCloses);
  }
  model.terms=model.terms.filter(t=>t.handle!=='term-binding-candidate');model.runtime='runtime-rebound';
  for (const field of ['worktreeId','worktreePath']) {
    const foreign=model.terms.find(t=>t.handle==='term-foreign'),original=foreign[field];
    foreign[field]='';save();
    r=cli('release-pending');assert.notEqual(r.status,0);assert.match(r.stderr,/release branch=incomplete-evidence/);
    assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes);
    foreign[field]=original;
  }
  for (const field of ['unreadable','truncated','omitted']) {
    model[field]=true;save();r=cli('release-pending');assert.notEqual(r.status,0);assert.match(r.stderr,/release branch=incomplete-evidence/);
    assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),pendingBytes);
    model[field]=false;
  }
  save();const inventoryBeforeRelease=JSON.stringify(model.terms);
  r=cli('release-pending');assert.equal(r.status,0,r.stderr);assert.match(r.stderr,/release branch=absent-handle-no-candidates/);
  assert.ok(r.stderr.includes(`absent handle=${pendingExtra.endpoint.target}`));
  assert.equal(existsSync(`${state}/.afk-daemon-terminal`),false);assert.equal(existsSync(`${state}/.afk`),false);
  reload();assert.equal(JSON.stringify(model.terms),inventoryBeforeRelease,'release mutated a live terminal');
  assert.equal(count('create'),beforeReleaseCreates);assert.equal(count('close'),beforeReleaseCloses);
  check('approved release requires absent handle and no binding candidate, and rejects empty worktree or incomplete census evidence');
  // Restore only this synthetic fixture to continue adoption coverage; no real
  // operation edits or invents a runtime identity.
  model.terms=originalTerms;model.runtime='runtime-1';save();rmSync(releaseClaim);
  writeFileSync(`${state}/.afk-daemon-terminal`,pendingBytes);writeFileSync(`${state}/.afk`,String(Math.floor(Date.now()/1000)));
  // A mutable title is neither positive nor negative ownership evidence.
  model.terms.find(t=>t.handle===pendingExtra.endpoint.target).title='zsh in squad';save();await tick();
  r=cli('start');assert.equal(r.status,0,r.stderr);assert.match(r.stderr,/adopted the exact Orca daemon terminal/);
  assert.equal(count('create'),n);assert.equal(count('close'),closesBeforeAdopt);
  r=cli('release-handle-less');assert.notEqual(r.status,0);assert.match(r.stderr,/releases only a pending Orca creation intent/);
  assert.equal(count('create'),n);assert.equal(count('close'),closesBeforeAdopt);
  assert.notEqual(readFileSync(`${state}/.afk-daemon-terminal`,'utf8').split('\t')[1],'pending');
  r=cli('stop');assert.equal(r.status,0,r.stderr);reload();assert.equal(model.terms.length,2);
  check('recorded identity adopts one renamed terminal; changed incarnation/worktree/path never permits adoption or retry');
  // An entirely lost create response has no daemon identity. Even a matching
  // title or a complete empty inventory cannot authorize adoption or a retry.
  model.lostCreate=true;save();await tick();r=cli('start');assert.notEqual(r.status,0);reload();
  const unknownBytes=readFileSync(`${state}/.afk-daemon-terminal`,'utf8');
  const unknownExtra=JSON.parse(unknownBytes.split('\t')[2]);assert.equal(unknownExtra.endpoint,undefined);
  r=cli('status');assert.match(r.stdout,/terminal=uncertain daemon=dead /);assert.doesNotMatch(r.stdout,/terminal=dead/);
  assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),unknownBytes,'status rewrote the handle-less record');
  const unknownCreates=count('create'),unknownCloses=count('close');
  for (const terms of [model.terms, model.terms.filter(t=>!t.handle.startsWith('term-daemon-'))]) {
    const previous=model.terms;model.terms=terms;save();
    for (const action of ['start','stop','reconcile']) {
      r=cli(action);assert.notEqual(r.status,0);assert.match(r.stderr,/no daemon identity was recorded/);
      assert.equal(count('create'),unknownCreates);assert.equal(count('close'),unknownCloses);
      assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),unknownBytes);
    }
    model.terms=previous;
  }
  // Guarded handle-less release: a complete census that still contains an
  // unclaimed terminal in the pending worktree is reported, never released.
  save();
  r=cli('release-handle-less');assert.notEqual(r.status,0);
  const unknownDaemon=model.terms.find(t=>t.handle.startsWith('term-daemon-'));
  assert.match(r.stderr,new RegExp(`unclaimed live terminal candidate handle=${unknownDaemon.handle}`));
  assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),unknownBytes);
  for (const field of ['unreadable','truncated','omitted']) {
    model[field]=true;save();
    r=cli('release-handle-less');assert.notEqual(r.status,0);assert.match(r.stderr,/census or the recorded task-terminal cross-check is incomplete/);
    assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),unknownBytes);
    model[field]=false;save();
  }
  const incompleteMeta=`${state}/task-incomplete.meta`;
  writeFileSync(incompleteMeta,'backend=orca\nwindow=sq-task-incomplete\nendpoint_task_id=task-incomplete\n');
  r=cli('release-handle-less');assert.notEqual(r.status,0);assert.match(r.stderr,/without exactly one terminal handle/);
  assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),unknownBytes);
  rmSync(incompleteMeta);
  // Recorded task metas claim those exact terminals, so a complete census has
  // no unclaimed candidate and only then does the approved release proceed.
  writeFileSync(`${state}/.afk`,String(Math.floor(Date.now()/1000)));
  const claimMeta=`${state}/task-claimed.meta`;
  const foreignMeta=`${state}/task-foreign.meta`;
  writeFileSync(claimMeta,`backend=orca\nwindow=sq-task-claimed\nendpoint_task_id=task-claimed\nterminal=${unknownDaemon.handle}\nworktree=${home}\nproject=${home}\n`);
  writeFileSync(foreignMeta,`backend=orca\nwindow=sq-task-foreign\nendpoint_task_id=task-foreign\nterminal=term-foreign\nworktree=${home}\nproject=${home}\n`);
  r=cli('release-handle-less');assert.equal(r.status,0,r.stderr);assert.match(r.stderr,/released the handle-less Orca creation intent/);
  assert.equal(existsSync(`${state}/.afk-daemon-terminal`),false);assert.equal(existsSync(`${state}/.afk`),false);
  assert.ok(model.terms.some(t=>t.handle===unknownDaemon.handle),'release closed a live terminal');
  assert.equal(count('close'),unknownCloses);assert.equal(count('create'),unknownCreates);
  rmSync(claimMeta);rmSync(foreignMeta);
  check('handle-less release reports unclaimed candidates and incomplete census, then releases only complete cross-checked evidence');
  // Test-only fixture supplies the fake runtime's exact receipt after proving
  // no automatic path changed the unknown record. This is not production recovery.
  const lost=model.terms.find(t=>t.handle.startsWith('term-daemon-'));
  const knownExtra={...unknownExtra,endpoint:{backend:'orca',target:lost.handle,runtime:model.runtime,incarnation:lost.incarnationId,worktree:lost.worktreeId,path:lost.worktreePath}};
  writeFileSync(`${state}/.afk-daemon-terminal`,'orca\tpending\t'+JSON.stringify(knownExtra)+'\n');
  model.lostCreate=false;model.terms=model.terms.filter(t=>t.handle!==lost.handle);save();
  // The known absent identity can be released only after every other live
  // terminal in its binding is accounted for by a recorded task.
  writeFileSync(foreignMeta,`backend=orca\nwindow=sq-task-foreign\nendpoint_task_id=task-foreign\nterminal=term-foreign\nworktree=${home}\nproject=${home}\n`);
  r=cli('stop');assert.equal(r.status,0,r.stderr);
  check('handle-less lost responses stay pending with either a matching title or zero terminals');
  // A complete inventory excluding the recorded handle permits one create,
  // even if an unrelated terminal has the old display title.
  model.unreadable=true;save();await tick();
  let beforeAbsent=count('create');r=cli('start');assert.notEqual(r.status,0);assert.equal(count('create'),beforeAbsent+1);reload();
  assert.match(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),/^orca\tpending\t/);
  const absentBytes=readFileSync(`${state}/.afk-daemon-terminal`,'utf8');
  const absentExtra=JSON.parse(absentBytes.split('\t')[2]);
  model.terms=model.terms.filter(t=>t.handle!==absentExtra.endpoint.target);
  model.terms[1].title=absentExtra.title;model.unreadable=false;save();
  r=cli('status');assert.match(r.stdout,/active=1 terminal=absent daemon=dead /);assert.doesNotMatch(r.stdout,/terminal=dead/);
  assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),absentBytes,'status rewrote the absent pending record');
  for (const field of ['unreadable','truncated','omitted']) {
    model[field]=true;save();
    for (const action of ['start','stop']) {
      r=cli(action);assert.notEqual(r.status,0);assert.match(r.stderr,/daemon identity is recorded but the runtime terminal inventory/);
      assert.doesNotMatch(r.stderr,/create outcome remains uncertain/,'a recorded daemon identity was reported as an uncertain create');
      assert.equal(count('create'),beforeAbsent+1);assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),absentBytes);
    }
    model[field]=false;save();
  }
  beforeAbsent=count('create');await tick();r=cli('start');assert.equal(r.status,0,r.stderr);assert.equal(count('create'),beforeAbsent+1);
  reload();assert.equal(model.terms.filter(t=>t.handle.startsWith('term-daemon-')).length,1);
  r=cli('stop');assert.equal(r.status,0,r.stderr);reload();assert.equal(model.terms.length,2);
  check('absent recorded identity allows exactly one retry despite an unrelated matching display title');
  model.terms[1].title='foreign';model.unreadable=true;save();await tick();
  r=cli('start');assert.notEqual(r.status,0);reload();
  const toRelease=JSON.parse(readFileSync(`${state}/.afk-daemon-terminal`,'utf8').split('\t')[2]);
  model.terms=model.terms.filter(t=>t.handle!==toRelease.endpoint.target);model.unreadable=false;save();
  r=cli('stop');assert.equal(r.status,0,r.stderr);assert.equal(existsSync(`${state}/.afk-daemon-terminal`),false);
  assert.equal(existsSync(`${state}/.afk`),false);
  await tick();r=cli('start');assert.equal(r.status,0,r.stderr);r=cli('stop');assert.equal(r.status,0,r.stderr);
  rmSync(foreignMeta);
  // A record from the previous launcher has no .owner token; its stored title
  // marker may only verify the process the exact terminal identity already binds.
  await tick();r=cli('start');assert.equal(r.status,0,r.stderr);reload();
  const legacyBound=JSON.parse(readFileSync(`${state}/.afk-daemon-terminal`,'utf8').split('\t').slice(2).join('\t'));
  const legacyRecord=`orca\t${legacyBound.endpoint.target}\t${JSON.stringify({parent:legacyBound.parent,title:legacyBound.title,endpoint:legacyBound.endpoint})}\n`;
  const untitledRecord=`orca\t${legacyBound.endpoint.target}\t${JSON.stringify({parent:legacyBound.parent,endpoint:legacyBound.endpoint})}\n`;
  writeFileSync(`${state}/.afk-daemon-terminal`,legacyRecord);
  const legacyDaemon=spawn('bash',['-c','sleep 60 & echo $!; wait'],{stdio:['ignore','pipe','ignore']});tracked.push(legacyDaemon);
  const legacyPid=Number((await once(legacyDaemon.stdout,'data'))[0].toString().trim());assert.ok(legacyPid>1);
  const legacyLock=`${state}/.supervise-daemon.lock`;mkdirSync(legacyLock);
  writeFileSync(`${legacyLock}/pid`,String(legacyPid));
  const legacyIdentity=script(`. '${root}/bin/sq-stand-to-lib.sh'; fm_pid_identity '${legacyPid}'`);assert.equal(legacyIdentity.status,0);
  writeFileSync(`${legacyLock}/pid-identity`,legacyIdentity.stdout.trim());
  const closesBeforeLegacy=count('close');
  writeFileSync(`${legacyLock}/orca-owner`,'foreign-legacy-title');
  r=cli('stop');assert.notEqual(r.status,0);assert.match(r.stderr,/legacy Orca title marker does not match/);
  assert.equal(legacyDaemon.exitCode,null);assert.ok(existsSync(`${state}/.afk`));assert.equal(count('close'),closesBeforeLegacy);
  assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),legacyRecord);
  writeFileSync(`${state}/.afk-daemon-terminal`,untitledRecord);
  r=cli('stop');assert.notEqual(r.status,0);assert.match(r.stderr,/no launch token and no legacy title marker/);
  assert.equal(legacyDaemon.exitCode,null);assert.equal(count('close'),closesBeforeLegacy);
  writeFileSync(`${state}/.afk-daemon-terminal`,legacyRecord);
  writeFileSync(`${legacyLock}/orca-owner`,legacyBound.title);
  r=cli('stop');assert.equal(r.status,0,r.stderr);
  let legacyAlive=true;try{process.kill(legacyPid,0);}catch{legacyAlive=false;}assert.equal(legacyAlive,false,'the legacy daemon process was not signalled');
  assert.equal(existsSync(`${state}/.afk-daemon-terminal`),false);assert.equal(existsSync(`${state}/.afk`),false);
  assert.equal(count('close'),closesBeforeLegacy+1);reload();assert.equal(model.terms.length,2);
  r=cli('status');assert.match(r.stdout,/active=0 terminal=absent daemon=dead/);
  rmSync(legacyLock,{recursive:true});tracked=tracked.filter(child=>child!==legacyDaemon);
  check('a pre-token legacy record stops only its exact identity with the stored legacy title marker; foreign or missing markers refuse');
  check('proven identity absence releases pending state on stop and permits subsequent start/stop');
  // A redundant start while an escalation is in flight and the daemon is alive
  // must refresh the flag instead of claiming another away session is needed: a
  // refresh creates no terminal and no delivery.
  model.lostCreate=false;save();r=cli('start');assert.equal(r.status,0,r.stderr);reload();
  const inflightRecord=JSON.parse(readFileSync(`${state}/.afk-daemon-terminal`,'utf8').split('\t').slice(2).join('\t'));
  const createsBeforeRefresh=count('create');
  idle=false;f=flush('signal: in flight while the daemon is live');assert.notEqual(f.status,0);
  assert.ok(existsSync(`${dir}/request.json`));
  const refreshDaemon=spawn('bash',['-c','sleep 60 & echo $!; wait'],{stdio:['ignore','pipe','ignore']});tracked.push(refreshDaemon);
  const refreshPid=Number((await once(refreshDaemon.stdout,'data'))[0].toString().trim());assert.ok(refreshPid>1);
  const refreshLock=`${state}/.supervise-daemon.lock`;mkdirSync(refreshLock);
  writeFileSync(`${refreshLock}/pid`,String(refreshPid));
  const refreshIdentity=script(`. '${root}/bin/sq-stand-to-lib.sh'; fm_pid_identity '${refreshPid}'`);assert.equal(refreshIdentity.status,0);
  writeFileSync(`${refreshLock}/pid-identity`,refreshIdentity.stdout.trim());
  writeFileSync(`${refreshLock}/orca-owner`,inflightRecord.owner);
  r=cli('start');assert.equal(r.status,0,r.stderr);assert.match(r.stderr,/refreshed away-mode flag/);
  assert.equal(count('create'),createsBeforeRefresh);assert.ok(existsSync(`${state}/.afk`));
  process.kill(refreshPid,'SIGTERM');await once(refreshDaemon,'exit');rmSync(refreshLock,{recursive:true});
  tracked=tracked.filter(child=>child!==refreshDaemon);
  idle=true;consume=true;await tick();f=flush();assert.equal(f.status,0,f.stderr);
  r=cli('stop');assert.equal(r.status,0,r.stderr);
  check('a redundant start refreshes a live daemon even while a native request is in flight');
  // A consumed acknowledgement retires its covered prefix; the durable wedge
  // marker from an earlier alarm must not outlive the confirmed delivery.
  r=cli('start');assert.equal(r.status,0,r.stderr);reload();
  writeFileSync(`${state}/.subsuper-inject-wedged`,'fm away-mode inject WEDGED: 4555s undelivered\n');
  f=flush('signal: wedged then consumed');assert.notEqual(f.status,0);await tick();
  assert.ok(existsSync(`${state}/.subsuper-inject-wedged`));
  f=flush();assert.equal(f.status,0,f.stderr);
  assert.equal(existsSync(`${state}/.subsuper-inject-wedged`),false);
  assert.equal(readFileSync(`${state}/.subsuper-escalations`,'utf8'),'');
  check('a consumed acknowledgement clears the stale wedge marker with the retired prefix');
  r=cli('stop');assert.equal(r.status,0,r.stderr);
  // The launcher's own confirmed retire (dead/absent daemon) is the same shared
  // boundary, so a confirmed delivery must not leave undelivered evidence.
  r=cli('start');assert.equal(r.status,0,r.stderr);reload();
  writeFileSync(`${state}/.subsuper-inject-wedged`,'fm away-mode inject WEDGED: 4555s undelivered\n');
  f=flush('signal: wedged while the daemon is dead');assert.notEqual(f.status,0);await tick();
  assert.ok(existsSync(`${dir}/request.json`));assert.equal(JSON.parse(readFileSync(`${dir}/result.json`)).status,'handled');
  assert.ok(existsSync(`${state}/.subsuper-inject-wedged`));
  r=cli('stop');assert.equal(r.status,0,r.stderr);
  assert.equal(existsSync(`${dir}/request.json`),false);
  assert.equal(existsSync(`${state}/.subsuper-inject-wedged`),false);
  assert.equal(readFileSync(`${state}/.subsuper-escalations`,'utf8'),'');
  check('a confirmed launcher retire clears the wedge marker left after the daemon died');
  // Without a terminal record the pending invariant can only be checked against
  // an exact primary handle; an unknown primary must refuse rather than report
  // a complete stop while the real request stays unresolved.
  r=cli('start');assert.equal(r.status,0,r.stderr);reload();
  const orphanRecord=readFileSync(`${state}/.afk-daemon-terminal`,'utf8');
  idle=false;f=flush('signal: unresolved without a terminal record');assert.notEqual(f.status,0);
  assert.ok(existsSync(`${dir}/request.json`));rmSync(`${state}/.afk-daemon-terminal`);
  r=cli('stop',{SQUAD_SUPERVISOR_TARGET:''});assert.notEqual(r.status,0);assert.match(r.stderr,/no exact primary terminal handle/);assert.ok(existsSync(`${state}/.afk`));
  r=cli('reconcile',{SQUAD_SUPERVISOR_TARGET:''});assert.notEqual(r.status,0);assert.match(r.stderr,/no exact primary terminal handle/);assert.ok(existsSync(`${state}/.afk`));
  check('Orca stop and reconcile without an exact primary handle refuse to report completion');
  writeFileSync(`${state}/.afk-daemon-terminal`,orphanRecord);
  idle=true;consume=true;await tick();f=flush();assert.equal(f.status,0,f.stderr);assert.equal(existsSync(`${dir}/request.json`),false);
  r=cli('stop');assert.equal(r.status,0,r.stderr);
  // A reconcile that retires an already-consumed prefix and then fails must not
  // roll that acknowledged text back into the escalation buffer on rollback.
  r=cli('start');assert.equal(r.status,0,r.stderr);reload();
  idle=true;draft='';consume=true;structured=true;await tick();
  f=flush('signal: consumed before a failing reconcile');assert.notEqual(f.status,0);await tick();structured=false;
  assert.ok(existsSync(`${dir}/request.json`));assert.equal(JSON.parse(readFileSync(`${dir}/result.json`)).status,'handled');
  assert.match(readFileSync(`${state}/.subsuper-escalations`,'utf8'),/consumed before a failing reconcile/);
  model.cancelClose=true;save();
  r=cli('start-native',{SQUAD_SUPERVISOR_BACKEND:'tmux',SQUAD_SUPERVISOR_TARGET:''});
  assert.notEqual(r.status,0);assert.match(r.stderr,/teardown is unconfirmed/);
  assert.equal(existsSync(`${dir}/request.json`),false);
  assert.doesNotMatch(readFileSync(`${state}/.subsuper-escalations`,'utf8'),/consumed before a failing reconcile/);
  assert.ok(existsSync(`${state}/.afk`));
  model.cancelClose=false;save();
  r=cli('reconcile');assert.equal(r.status,0,r.stderr);reload();
  r=cli('stop');assert.equal(r.status,0,r.stderr);
  check('a failed reconcile never rolls an already-consumed prefix back into the buffer');
  assert.equal(calls().some(a=>a[1]==='send'||a[0]==='worktree'||a.includes('--tab')),false);
  // A settle of the selected primary never accounts for a request published for
  // another Orca primary; reporting success there would let start/stop clear the
  // shared escalation buffer with that undelivered escalation still covered.
  r=cli('start');assert.equal(r.status,0,r.stderr);reload();
  idle=false;f=flush('signal: foreign primary unresolved');assert.notEqual(f.status,0);
  const primaryReq=`${dir}/request.json`;assert.ok(existsSync(primaryReq));
  const otherDir=script(`bash '${root}/bin/sq-supervisor-native.sh' dir '${state}' term-foreign`).stdout.trim();
  mkdirSync(otherDir,{recursive:true,mode:0o700});
  const otherReq=JSON.parse(readFileSync(primaryReq,'utf8'));
  otherReq.id='foreign-request';otherReq.endpoint={...otherReq.endpoint,target:'term-foreign',incarnation:'inc-term-foreign'};
  writeFileSync(`${otherDir}/request.json`,JSON.stringify(otherReq));
  rmSync(primaryReq);rmSync(`${state}/.afk-daemon-terminal`);
  const bufferBefore=readFileSync(`${state}/.subsuper-escalations`,'utf8');assert.ok(bufferBefore.length>0);
  r=cli('reconcile');assert.notEqual(r.status,0);assert.match(r.stderr,/another primary/);
  assert.equal(readFileSync(`${state}/.subsuper-escalations`,'utf8'),bufferBefore);assert.ok(existsSync(`${otherDir}/request.json`));
  r=cli('start');assert.notEqual(r.status,0);assert.match(r.stderr,/another primary/);
  assert.equal(readFileSync(`${state}/.subsuper-escalations`,'utf8'),bufferBefore);assert.ok(existsSync(`${otherDir}/request.json`));assert.ok(existsSync(`${state}/.afk`));
  r=cli('stop');assert.notEqual(r.status,0);assert.match(r.stderr,/another primary/);
  assert.equal(readFileSync(`${state}/.subsuper-escalations`,'utf8'),bufferBefore);assert.ok(existsSync(`${otherDir}/request.json`));assert.ok(existsSync(`${state}/.afk`));
  rmSync(otherDir,{recursive:true,force:true});
  check('an unresolved request for another primary blocks start/stop/reconcile and preserves the buffer');
  // A create receipt that names the primary is not a daemon identity: the
  // launcher must refuse it, never adopt it, and never close the primary.
  model.createPrimary=true;save();await tick();
  const primaryCloses=count('close');
  r=cli('start');assert.notEqual(r.status,0,r.stderr);
  assert.match(r.stderr,/Orca create receipt was rejected \(handle term-primary is the primary terminal\)/);
  assert.match(r.stderr,/returned handle=term-primary worktreeId=repo::/);
  assert.match(r.stderr,/no daemon identity was recorded/);
  assert.equal(count('close'),primaryCloses,'the primary was closed after a create receipt named it');
  assert.ok(model.terms.some(t=>t.handle==='term-primary'),'the primary terminal disappeared');
  const primaryRecord=readFileSync(`${state}/.afk-daemon-terminal`,'utf8');
  assert.equal(primaryRecord.split('\t')[1],'pending');
  assert.equal(JSON.parse(primaryRecord.split('\t')[2]).endpoint,undefined,'a primary handle was persisted as the daemon identity');
  r=cli('stop');assert.notEqual(r.status,0);
  assert.equal(count('close'),primaryCloses,'stop closed the primary named by a rejected create receipt');
  assert.equal(readFileSync(`${state}/.afk-daemon-terminal`,'utf8'),primaryRecord);
  delete model.createPrimary;save();
  check('a create receipt naming the primary is refused without adopting or closing it');
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
