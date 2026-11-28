#!/usr/bin/env bash
# sq-board-mod-thin.test.sh - thin checks for `herdr-mods/squad-board`.
#
# Covers what can be proven without a person at the window:
#   - the manifest shape the app needs, and that `herdr-app check` accepts the folder;
#   - the mapping from `bin/sq-board.sh --json` rows to cards, sections and counts,
#     the click-to-focus join on the board's `window` field, the list/kanban choice
#     in `shared()`, the loading/empty/error text, and the read cadence (one read at
#     a time, never while hidden, no read from `herdr-app check`);
#   - the absence of every lifecycle verb from the mod and its installer.
#
# The behavior checks load the real `main.js` in node with stub `herdr`, `gpui-kit`
# and `gpui-base` modules, so the mod runs unmodified. `herdr-app check` runs only
# where the app is installed, because CI has no Herdr.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD="$ROOT/herdr-mods/squad-board"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '  ok %s\n' "$*"
}

[ -f "$MOD/main.js" ] || fail "missing $MOD/main.js"
[ -f "$MOD/mod.json" ] || fail "missing $MOD/mod.json"
[ -f "$MOD/README.md" ] || fail "missing $MOD/README.md"
[ -x "$MOD/install.sh" ] || fail "$MOD/install.sh is not executable"
pass "one folder with main.js, mod.json, README.md and an executable install.sh"

MOD_DIR="$MOD" node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const modDir = process.env.MOD_DIR;
const manifest = JSON.parse(readFileSync(join(modDir, "mod.json"), "utf8"));
assert.equal(manifest.place, "none", "mod.json must declare place none so nothing docks into the layout");
assert.ok(Number(manifest.min_w) >= 280, "mod.json must declare a min_w of at least the 280 px panel minimum");
assert.equal(typeof manifest.title, "string", "mod.json needs a title the app can show");
assert.ok(manifest.title.trim() !== "", "mod.json title is not empty");
assert.notEqual(manifest.focusable, true, "the mod is pointer-only, so it must not claim focusable");
console.log("  ok manifest: place none, min_w " + manifest.min_w);

// ---- stub modules: the mod runs unmodified against these ---------------------
const root = mkdtempSync(join(tmpdir(), "squad-board-mod-"));
const pkg = (name, type = "module") =>
  writeFileSync(join(root, "node_modules", name, "package.json"), JSON.stringify({ name, type, main: "index.js" }));
const file = (name, path, text) => {
  mkdirSync(join(root, "node_modules", name), { recursive: true });
  writeFileSync(join(root, "node_modules", name, path), text);
};

file(
  "gpui-kit",
  "index.js",
  `
export class El {
  constructor(kind) { this.kind = kind; this.props = {}; this.kids = []; }
  child(x) { this.kids.push(x); return this; }
  children(xs) { for (const x of xs) this.kids.push(x); return this; }
  when(cond, fn) { if (cond) fn(this); return this; }
  on_click(fn) { this.click = fn; return this; }
  hover(fn) { this.hoverFn = fn; return this; }
}
for (const m of ["id","gap","p","px","py","pl","rounded","bg","border","border_color","cursor_pointer","size","w","flex_none","mt","flex_1","min_w","text_size","text_color","whitespace_normal","font_semibold","h","flex","items_center","items_start","size_full","overflow_x_scrollbar","overflow_y_scrollbar"]) {
  El.prototype[m] = function (v) { this.props[m] = v === undefined ? true : v; return this; };
}
export function div() { return new El("div"); }
export class View {}
`,
);
file("gpui-base", "index.js", `import { El } from "gpui-kit";\nexport const v_flex = () => new El("v");\nexport const h_flex = () => new El("h");\n`);
file(
  "herdr",
  "index.js",
  `
const s = (globalThis.__herdrStub ??= {});
export function checking() { return s.checking; }
export function window() { return s.win; }
export function theme() { return Object.fromEntries(["background","surface","raised","hover","selected","border","foreground","muted","dim","accent","working","blocked","done","idle","unknown"].map((k) => [k, k])); }
export function shared(k) { return s.shared[k]; }
export function setShared(k, v) { s.shared[k] = v; return null; }
export function agents() { return s.agents; }
export function props() { return s.props; }
export function run(name, args) { s.calls.push({ name, args }); s.seen.runs.push(name); return null; }
export function exec(cmd, args, opts) { s.seen.execs.push({ cmd, args, opts }); return s.exec(cmd, args, opts); }
`,
);
pkg("gpui-kit");
pkg("gpui-base");
pkg("herdr");
writeFileSync(join(root, "mod.json"), "{}");
writeFileSync(join(root, "main.js"), readFileSync(join(modDir, "main.js")));

const stub = (globalThis.__herdrStub = {
  checking: false,
  win: { visible: true },
  shared: {},
  agents: [],
  props: null,
  calls: [],
  execs: [],
  seen: { runs: [], execs: [] },
  timer: null,
  exec: () => {
    throw new Error("exec is not stubbed in this scenario");
  },
});
let imports = 0;
async function load() {
  const url = pathToFileURL(join(root, "main.js")).href + `?copy=${++imports}`;
  return (await import(url)).default;
}

// A context like the app's: spawned tasks are awaited by flush(), the timer is captured.
let pending = [];
function makeCx() {
  const cx = {
    spawn(fn) { pending.push(fn(cx)); },
    timer: { every(ms, cb) { stub.timer = { ms, cb }; } },
    notify() {},
  };
  return cx;
}
async function flush() {
  while (pending.length) await pending.shift();
}

const fixture = [
  { id: "live", state: "in_flight", kind: "strike", repo: "squad", title: "Titulo completo da missao que precisa de varias linhas em 200 px", backend: "herdr-core", endpoint_state: "", busy_elapsed: "7m", window: "default:t1k" },
  { id: "nowin", state: "in_flight", kind: "recon", repo: "robotyard", title: "Missao sem agente vivo", backend: "herdr-core", endpoint_state: "", busy_elapsed: "3m", window: "" },
  { id: "waiting", state: "queued", kind: "commander", repo: "career-coach", title: "Na fila", backend: "herdr-core", endpoint_state: "", busy_elapsed: "", window: "" },
  { id: "parked", state: "held", kind: "docs", repo: "squad", title: "Em espera", backend: "herdr-core", endpoint_state: "", busy_elapsed: "", window: "" },
  { id: "dead", state: "held", kind: "strike", repo: "squad", title: "Terminal que ja fechou", backend: "herdr-core", endpoint_state: "", busy_elapsed: "", window: "default:tgone" },
  { id: "foreign", state: "held", kind: "strike", repo: "squad", title: "Rodando em tmux", backend: "tmux", endpoint_state: "", busy_elapsed: "", window: "work:0" },
];

function okExec(rows) {
  return (cmd, args, opts) => {
    stub.execs.push({ cmd, args, opts });
    return Promise.resolve({ code: 0, stdout: JSON.stringify(rows), stderr: "" });
  };
}

function texts(el, out = []) {
  if (typeof el === "string") out.push(el);
  else if (el && el.kids) for (const k of el.kids) texts(k, out);
  return out;
}
const allText = (el) => texts(el).join("\n");
function findAll(el, pred, out = []) {
  if (!el || typeof el === "string") return out;
  if (pred(el)) out.push(el);
  for (const k of el.kids) findAll(k, pred, out);
  return out;
}
function byId(el, id) {
  if (!el || typeof el === "string") return null;
  if (el.props?.id === id) return el;
  for (const k of el.kids) {
    const hit = byId(k, id);
    if (hit) return hit;
  }
  return null;
}
// The count rendered beside a section's label, read from that section's own
// header so the assertion cannot be satisfied by an unrelated digit.
function sectionCount(tree, label) {
  const labelEl = findAll(tree, (el) => el.kids?.length === 1 && el.kids[0] === label)[0];
  assert.ok(labelEl, `section ${label} has a header`);
  const header = findAll(tree, (el) => el.kids?.includes(labelEl))[0];
  assert.ok(header, `section ${label} has a header row`);
  const countEl = header.kids[header.kids.indexOf(labelEl) + 1];
  assert.ok(countEl, `section ${label} renders a count`);
  return countEl.kids[0];
}

async function boot({ rows = fixture, win = { visible: true }, checking = false, exec = null, props = null } = {}) {
  stub.checking = checking;
  stub.win = win;
  stub.shared = {};
  stub.calls = [];
  stub.execs = [];
  stub.agents = [{ address: "t1k", status: "working" }];
  stub.props = props;
  stub.timer = null;
  pending = [];
  stub.exec = exec ?? okExec(rows);
  const Mod = await load();
  const view = new Mod();
  const cx = makeCx();
  view.init(null, cx);
  return { view, cx };
}

// ---- the three sections, their live counts, and the card fields --------------
{
  const { view, cx } = await boot({ props: { base: "/repo" } });
  await flush();
  assert.equal(stub.execs.length, 1, "one board read per poll");
  const call = stub.execs[0];
  assert.equal(call.cmd, "/bin/bash");
  assert.match(call.args[1], /bin\/sq-board\.sh --json/);
  assert.doesNotMatch(call.args[1], /--state/, "one read of the whole board supplies all three sections");
  assert.equal(call.opts.timeout, 180000, "the read is bounded by an explicit timeout");
  assert.equal(call.opts.cwd, undefined, "the read never depends on the host honouring exec's cwd option");
  assert.match(
    call.args[1],
    /^cd '\/repo' && SQUAD_BASE='\/repo' exec bin\/sq-board\.sh --json$/,
    "the chosen base is cd-ed to and exported as SQUAD_BASE inside the command itself",
  );
  assert.equal(stub.timer.ms, 60000, "at most one read per minute, never tighter than 15 s");

  const tree = view.render(cx);
  const text = allText(tree);
  for (const label of ["EM VOO", "FILA", "EM ESPERA"]) assert.ok(text.includes(label), `section ${label}`);
  for (const [label, count] of [["EM VOO", "2"], ["FILA", "1"], ["EM ESPERA", "3"]]) {
    assert.equal(sectionCount(tree, label), count, `${label} shows its live count`);
  }
  for (const field of [fixture[0].title, "strike", "squad", "7m", "working"]) assert.ok(text.includes(field), `card field ${field}`);

  // Click-to-focus needs a herdr-core row whose terminal agents() still lists.
  // A recorded window alone is not enough: a closed terminal's address is
  // recycled, and a tmux row records session:window, not an app terminal id.
  const liveCard = byId(tree, "card-live");
  assert.equal(liveCard.props.cursor_pointer, true, "a live herdr-core card offers a pointer cursor");
  liveCard.click({}, cx);
  assert.deepEqual(stub.calls, [{ name: "agent.focus", args: { terminal: "t1k" } }]);
  assert.equal(byId(tree, "card-nowin").click, undefined, "a card with no window is not clickable");
  assert.equal(byId(tree, "card-nowin").props.cursor_pointer, undefined, "a dead card shows no pointer cursor");
  assert.equal(byId(tree, "card-waiting").click, undefined, "queued cards carry no window either");
  assert.equal(byId(tree, "card-dead").click, undefined, "a recorded window whose terminal is gone is not clickable");
  assert.equal(byId(tree, "card-foreign").click, undefined, "a tmux row carrying session:window is not clickable");
  console.log("  ok three sections with live counts, card fields, click only with a live herdr-core window");
}

// ---- the kanban divides the pane and never sizes itself to its content ------
{
  const { view, cx } = await boot();
  await flush();
  stub.shared["board.view"] = "kanban";
  const tree = view.render(cx);
  // No floor above the 200 px the layout must wrap at, and the toggle stays
  // reachable in the header whatever the width.
  assert.equal(tree.props.min_w, undefined, "the surface must not enforce a 280 px floor on a 200 px pane");
  assert.equal(byId(tree, "view-kanban")?.props.cursor_pointer, true, "Lista/Kanban stays reachable");
  const columns = findAll(tree, (el) => el.props.min_w === 200);
  assert.equal(columns.length, 3, "kanban has one 200 px-minimum column per section");
  for (const col of columns) {
    assert.equal(col.props.w, 0, "each column starts at width 0 so it grows into an equal share");
    assert.equal(col.props.flex_1, true, "each column grows to its share of the pane");
  }
  const scroller = findAll(tree, (el) => el.props.overflow_x_scrollbar !== undefined);
  assert.equal(scroller.length, 1, "only the kanban row scrolls sideways");
  assert.equal(scroller[0].kids.length, 3, "the three columns sit in the scrolling row");
  assert.equal(byId(tree, "card-live").props.min_w, 0, "a card does not size itself to its title");
  console.log("  ok kanban columns divide the width, only scroll below three 200 px columns");
}

// ---- the chosen base wins over an ambient SQUAD_BASE -----------------------
{
  const realExec = (cmd, args, opts) =>
    new Promise((resolve) => {
      execFile(cmd, args, { cwd: opts.cwd, timeout: opts.timeout }, (err, stdout, stderr) => {
        resolve({ code: err ? (typeof err.code === "number" ? err.code : 1) : 0, stdout, stderr });
      });
    });
  const makeBase = (name) => {
    const dir = join(root, "bases", name);
    mkdirSync(join(dir, "bin"), { recursive: true });
    writeFileSync(
      join(dir, "bin", "sq-board.sh"),
      `#!/usr/bin/env bash\nprintf '[{"id":"%s","state":"in_flight","window":""}]\\n' "$(basename "$SQUAD_BASE")"\n`,
      { mode: 0o755 },
    );
    return dir;
  };
  const chosen = makeBase("chosen");
  const ambient = makeBase("ambient");
  const saved = process.env.SQUAD_BASE;
  process.env.SQUAD_BASE = ambient;
  try {
    const { view } = await boot({ exec: realExec, props: { base: chosen } });
    await flush();
    const ids = view.items.map((m) => m.id);
    assert.ok(ids.includes("chosen"), `the props base is what the board reads, saw ${JSON.stringify(ids)}`);
    assert.ok(!ids.includes("ambient"), "an ambient SQUAD_BASE must not override the chosen base");

    // A base path with a space proves the command quotes it instead of
    // splitting it into extra shell words.
    const spaced = makeBase("chosen base");
    const { view: spacedView } = await boot({ exec: realExec, props: { base: spaced } });
    await flush();
    assert.deepEqual(
      spacedView.items.map((m) => m.id),
      ["chosen base"],
      "a chosen base with a space in its path is passed as one shell word",
    );
  } finally {
    if (saved === undefined) delete process.env.SQUAD_BASE;
    else process.env.SQUAD_BASE = saved;
  }
  console.log("  ok the chosen base wins over an ambient SQUAD_BASE");
}

// ---- the read budget: one at a time, never while hidden ----------------------
{
  const { view, cx } = await boot();
  await flush();
  assert.equal(stub.execs.length, 1, "first paint reads once");
  stub.timer.cb(cx);
  stub.timer.cb(cx);
  await flush();
  assert.equal(stub.execs.length, 1, "no second read inside the 60 s floor");

  stub.win = { visible: false };
  view.at = Date.now() - 120000;
  stub.timer.cb(cx);
  await flush();
  assert.equal(stub.execs.length, 1, "no read while the pane is not visible");

  stub.win = { visible: true };
  let release;
  stub.exec = () => {
    stub.execs.push({});
    return new Promise((resolve) => (release = resolve));
  };
  view.at = Date.now() - 120000;
  stub.timer.cb(cx);
  stub.timer.cb(cx);
  view.at = Date.now() - 120000;
  view.render(cx);
  await Promise.resolve();
  assert.equal(stub.execs.length, 2, "a slow read never stacks a second one");
  release({ code: 0, stdout: "[]", stderr: "" });
  await flush();
  console.log("  ok one read at a time, none while hidden, 60 s floor");
}

// ---- loading, empty and error are text --------------------------------------
{
  // A read that has not answered yet: the board must say so, not paint blank.
  const { view, cx } = await boot({ exec: () => new Promise(() => {}) });
  assert.ok(allText(view.render(cx)).includes("lendo o board…"), "loading state");
  console.log("  ok loading is text");
}
{
  const { view, cx } = await boot({ rows: [] });
  await flush();
  const text = allText(view.render(cx));
  for (const line of ["nenhuma missão em voo", "nada na fila", "nada em espera"]) assert.ok(text.includes(line), `empty line ${line}`);
  console.log("  ok empty is text");
}
{
  const { view, cx } = await boot({
    exec: () => Promise.resolve({ code: 1, stderr: "bin/sq-board.sh boom\nsecond line", stdout: "" }),
  });
  await flush();
  const text = allText(view.render(cx));
  assert.ok(text.includes("bin/sq-board.sh boom"), "the command's own error is painted");
  assert.ok(!text.includes("second line"), "only the first error line is painted");
  assert.ok(text.includes("FILA"), "sections stay under the error");
  console.log("  ok error is text");
}
{
  const { view, cx } = await boot({ exec: () => Promise.resolve({ code: 127, stderr: "/bin/bash: bin/sq-board.sh: No such file or directory", stdout: "" }) });
  await flush();
  assert.ok(allText(view.render(cx)).includes("SQUAD_BASE"), "a missing base names the two ways to point at it");
  console.log("  ok a missing board names how to point at it");
}

// ---- list/kanban choice survives a restart through shared() ------------------
{
  const { view, cx } = await boot();
  await flush();
  const list = view.render(cx);
  assert.equal(byId(list, "view-list").props.bg, "raised", "list is the default view");
  byId(list, "view-kanban").click({}, cx);
  assert.equal(stub.shared["board.view"], "kanban", "the choice is written to shared()");

  const again = await load();
  const restarted = new again();
  restarted.init(null, makeCx());
  await flush();
  const kanban = restarted.render(makeCx());
  const text = allText(kanban);
  for (const label of ["EM VOO", "FILA", "EM ESPERA"]) assert.ok(text.includes(label), `kanban keeps section ${label}`);
  assert.ok(text.includes(fixture[0].title), "kanban keeps the cards");
  assert.equal(byId(kanban, "view-kanban").props.bg, "raised", "the restart comes back in kanban");
  console.log("  ok list/kanban toggle, remembered through shared()");
}

// ---- herdr-app check renders once and never reads ---------------------------
{
  const { view, cx } = await boot({ checking: true });
  await flush();
  assert.equal(stub.execs.length, 0, "a check never runs the board");
  const text = allText(view.render(cx));
  for (const line of ["EM VOO", "nenhuma missão em voo"]) assert.ok(text.includes(line), `check renders ${line}`);
  assert.equal(stub.timer, null, "a check arms no timer");
  console.log("  ok herdr-app check renders the empty board without reading anything");
}

// ---- the whole surface only ever runs the board read and agent.focus --------
{
  const runs = [...new Set(stub.seen.runs)];
  assert.deepEqual(runs, ["agent.focus"], `only agent.focus is ever run, saw: ${runs.join(", ") || "nothing"}`);
  assert.ok(stub.seen.execs.length > 0, "the board read actually ran");
  for (const e of stub.seen.execs) {
    assert.equal(e.cmd, "/bin/bash", "the board is read through bash");
    assert.match(e.args[1], /bin\/sq-board\.sh --json$/, "every process launch is the one board read");
    assert.doesNotMatch(e.args[1], /--state/, "no filtered read");
  }
  console.log(`  ok only agent.focus and bin/sq-board.sh --json ever run (${stub.seen.execs.length} reads)`);
}

rmSync(root, { recursive: true, force: true });
JS
pass "behavior: sections, cards, click, budget, states, toggle, check"

# ---- no lifecycle verb anywhere in the mod or its installer -------------------
for verb in sq-tasks sq-spawn sq-teardown; do
  if grep -q -- "$verb" "$MOD/main.js" "$MOD/install.sh"; then
    fail "$verb must never appear in the mod or its installer"
  fi
done
if grep -Eq '\bhc[[:space:]]+(run|kill|rm|label|start|stop|exec|file|send|spawn)\b' "$MOD/main.js" "$MOD/install.sh"; then
  fail "no hc write verb may appear in the mod or its installer"
fi
pass "no lifecycle verb: no sq-tasks, no sq-spawn, no sq-teardown, no hc write"

# ---- install and uninstall, in a throwaway app home -------------------------
tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home"' EXIT
target="$tmp_home/mods/squad-board"
marker="$target/.squad-board-install"

# A fresh install copies the shipped files and writes its marker last.
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null
[ -f "$target/main.js" ] || fail "install must copy main.js under mods/squad-board"
[ -f "$target/mod.json" ] || fail "install must copy mod.json under mods/squad-board"
[ -f "$marker" ] || fail "install must write its marker so an installed copy is provably its own"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null
[ "$(find "$tmp_home/mods" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ] || fail "install must be idempotent"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall >/dev/null
[ ! -e "$target" ] || fail "--uninstall must remove what it installed"

# The editor aids `herdr-app check` writes must not block removal.
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null
printf 'declare const x: number;\n' >"$target/gpui-kit.d.ts"
printf '{}\n' >"$target/jsconfig.json"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall >/dev/null
[ ! -e "$target" ] || fail "--uninstall must remove the editor files herdr-app check wrote"

# Ownership is the marker, not byte-identity: an installed copy that is older
# than this checkout can still be updated and removed.
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null
printf '// an older build of this mod\n' >"$target/main.js"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null || fail "a second install must update a stale copy it owns"
cmp -s "$MOD/main.js" "$target/main.js" || fail "install must refresh a stale copy"
[ -f "$marker" ] || fail "an updated copy keeps its marker"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall >/dev/null || fail "--uninstall must remove a stale copy it owns"
[ ! -e "$target" ] || fail "a stale copy must still be removable"

# A marker plus any other entry refuses both modes and deletes nothing.
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null
printf 'my notes\n' >"$target/notes.txt"
printf 'finder junk\n' >"$target/.DS_Store"
if HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null 2>&1; then
  fail "install must refuse a marked folder that also holds a file it did not write"
fi
if HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall >/dev/null 2>&1; then
  fail "--uninstall must refuse a marked folder that also holds a file it did not write"
fi
[ -f "$target/notes.txt" ] || fail "a refused install or uninstall must never delete a person's file"
[ -f "$target/.DS_Store" ] || fail "a refused install or uninstall must never delete an entry it did not write"
[ -f "$target/main.js" ] || fail "a refused install or uninstall must leave the mod in place"
rm -rf "$target"

# A folder with no marker is refused by both modes, naming the manual removal.
mkdir -p "$target"
cp "$MOD/main.js" "$MOD/mod.json" "$target/"
if out=$(HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" 2>&1); then
  fail "install must refuse a copy it cannot prove it wrote"
fi
case "$out" in
  *"delete the folder"*) : ;;
  *) fail "install refusal must name the manual removal, got: $out" ;;
esac
if out=$(HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall 2>&1); then
  fail "--uninstall must refuse a copy it cannot prove it wrote"
fi
case "$out" in
  *"delete the folder"*) : ;;
  *) fail "--uninstall refusal must name the manual removal, got: $out" ;;
esac
[ -f "$target/main.js" ] || fail "a refused uninstall must not delete anything"
rm -rf "$target"

# A partial copy carries no marker, because the marker is written last, and it
# is refused with the same manual-removal route.
mkdir -p "$target"
cp "$MOD/mod.json" "$target/"
if out=$(HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" 2>&1); then
  fail "install must refuse a partial copy that carries no marker"
fi
case "$out" in
  *"delete the folder"*) : ;;
  *) fail "a partial copy's refusal must name the manual removal, got: $out" ;;
esac
[ -f "$target/mod.json" ] || fail "a refused install must not delete a partial copy"
rm -rf "$target"

# A path that is not a folder at all (someone's file, a fifo, a hardlink) is
# refused with the manual removal instead of a raw mkdir/ln error, in both modes
# and on --uninstall, and nothing is overwritten.
printf 'not a folder\n' >"$target"
if out=$(HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" 2>&1); then
  fail "install must refuse a path that is not a folder"
fi
case "$out" in
  *"delete it by hand"*) : ;;
  *) fail "install refusal of a non-folder must name the manual removal, got: $out" ;;
esac
if out=$(HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --link 2>&1); then
  fail "--link must refuse a path that is not a folder"
fi
case "$out" in
  *"delete it by hand"*) : ;;
  *) fail "--link refusal of a non-folder must name the manual removal, got: $out" ;;
esac
if out=$(HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall 2>&1); then
  fail "--uninstall must refuse a path that is not a folder"
fi
case "$out" in
  *"delete it by hand"*) : ;;
  *) fail "--uninstall refusal of a non-folder must name the manual removal, got: $out" ;;
esac
[ -f "$target" ] && [ ! -L "$target" ] || fail "a refused install must leave a non-folder path as it was"
[ "$(cat "$target")" = "not a folder" ] || fail "a refused install must never overwrite a non-folder path"
rm -f "$target"

# --link works from a checkout reached through a symlink, is idempotent there,
# and --uninstall removes only the link, never the checkout.
checkout_link="$tmp_home/checkout-link"
ln -s "$MOD" "$checkout_link"
HERDR_APP_HOME="$tmp_home" "$checkout_link/install.sh" --link >/dev/null
[ -L "$target" ] || fail "--link must create a link at the app's mods path"
[ "$(readlink "$target")" = "$(cd -P "$MOD" && pwd -P)" ] || fail "--link must point at this checkout's physical folder"
HERDR_APP_HOME="$tmp_home" "$checkout_link/install.sh" --link >/dev/null || fail "a second --link through a symlinked checkout must be idempotent"
HERDR_APP_HOME="$tmp_home" "$checkout_link/install.sh" --uninstall >/dev/null || fail "--uninstall must remove the link it created through a symlinked checkout"
[ ! -e "$target" ] && [ ! -L "$target" ] || fail "--uninstall must remove only the link"
[ -f "$MOD/main.js" ] || fail "--uninstall of a link must never touch the checkout"
rm -f "$checkout_link"

# --link replaces its own copy, and refuses a copy without a marker.
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --link >/dev/null || fail "--link must replace a copy this script owns"
[ -L "$target" ] || fail "--link over an owned copy must leave a link"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall >/dev/null
mkdir -p "$target"
cp "$MOD/main.js" "$MOD/mod.json" "$target/"
if HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --link >/dev/null 2>&1; then
  fail "--link must refuse a copy that carries no marker"
fi
[ -f "$target/main.js" ] || fail "a refused --link must leave the copy in place"
rm -rf "$target"

# --link refuses to replace a marked copy that also holds someone else's file.
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null
printf 'my notes\n' >"$target/notes.txt"
if HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --link >/dev/null 2>&1; then
  fail "--link must refuse to replace a copy that holds files it did not write"
fi
[ -f "$target/notes.txt" ] || fail "--link must never delete a person's file"
[ -f "$target/main.js" ] || fail "a refused --link must leave the copy in place"
rm -rf "$target"

# --uninstall never writes through a link this folder did not create.
other="$tmp_home/other-copy"
mkdir -p "$other"
cp "$MOD/main.js" "$MOD/mod.json" "$other/"
ln -s "$other" "$target"
if HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall >/dev/null 2>&1; then
  fail "--uninstall must refuse a link it did not create"
fi
[ -f "$other/main.js" ] || fail "--uninstall must never write through a foreign link"
[ -f "$other/mod.json" ] || fail "--uninstall must never write through a foreign link"
if HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --link >/dev/null 2>&1; then
  fail "--link must refuse a foreign link"
fi
rm -f "$target"
pass "install keeps a marker, updates and removes stale copies, and refuses anything it cannot prove it wrote"

# ---- the app's own validator, where the app is installed ---------------------
if command -v herdr-app >/dev/null 2>&1; then
  out="$(herdr-app check "$MOD" 2>&1)" || fail "herdr-app check: $out"
  pass "herdr-app check: $out"
else
  printf '  skip herdr-app check (herdr-app is not installed here)\n'
fi

printf 'PASS: sq-board-mod-thin\n'
