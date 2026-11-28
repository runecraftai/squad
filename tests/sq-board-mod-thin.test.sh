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
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const modDir = process.env.MOD_DIR;
const manifest = JSON.parse(readFileSync(join(modDir, "mod.json"), "utf8"));
assert.equal(manifest.place, "none", "mod.json must declare place none so nothing docks into the layout");
assert.ok(Number(manifest.min_w) >= 280, "mod.json must declare a min_w of at least the 280 px panel minimum");

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
for (const m of ["id","gap","p","px","py","pl","pt","rounded","bg","border","border_color","cursor_pointer","size","flex","flex_none","flex_1","flex_wrap","mt","min_w","min_h","max_h","max_w","w","h","w_full","text_size","text_color","whitespace_normal","truncate","overflow_hidden","overflow_x_scrollbar","overflow_y_scrollbar","font_semibold","items_center","items_start","items_stretch","justify_between","size_full","aspect_square","on_size_change","track_focus","on_key_down","font_family","max_h_full","h_full"]) {
  El.prototype[m] = function (...args) { this.props[m] = args.length === 0 ? true : args.length === 1 ? args[0] : args; return this; };
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
export function run(name, args) { s.calls.push({ name, args }); return null; }
export function exec(cmd, args, opts) { return s.exec(cmd, args, opts); }
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
  timer: null,
  exec: () => {
    throw new Error("exec is not stubbed in this scenario");
  },
});
let imports = 0;
async function module() {
  const url = pathToFileURL(join(root, "main.js")).href + `?copy=${++imports}`;
  return await import(url);
}
async function load() {
  return (await module()).default;
}

// A context like the app's: spawned tasks are awaited by flush(), the timer is captured.
let pending = [];
function makeCx() {
  const cx = {
    spawn(fn) { pending.push(fn(cx)); },
    timer: { every(ms, cb) { stub.timer = { ms, cb }; } },
    notify() {},
    focus_handle() { return { focus() {} }; },
  };
  return cx;
}
async function flush() {
  while (pending.length) await pending.shift();
}

const longTitle = "Defeito: poda de cartoes de decisao ja resolvidos torna o portao de conclusao do recon insatisfativel para sempre, mesmo quando o operador ja respondeu todas as perguntas do juiz";
const fixture = [
  { id: "live", state: "in_flight", kind: "strike", repo: "squad", title: longTitle, backend: "herdr-core", endpoint_state: "", busy_elapsed: "7m", priority: "2", window: "default:t1k" },
  { id: "dead", state: "in_flight", kind: "recon", repo: "robotyard", title: longTitle, backend: "herdr-core", endpoint_state: "", busy_elapsed: "3m", priority: "", window: "default:t1x" },
  { id: "tmux", state: "in_flight", kind: "ops", repo: "squad", title: "Missao no tmux", backend: "tmux", endpoint_state: "", busy_elapsed: "1m", priority: "1", window: "work:t1k" },
  { id: "waiting", state: "queued", kind: "commander", repo: "career-coach", title: "Na fila", backend: "", endpoint_state: "", busy_elapsed: "", priority: "3", window: "" },
  { id: "parked", state: "held", kind: "docs", repo: "squad", title: "Em espera", backend: "", endpoint_state: "", busy_elapsed: "", priority: "", window: "" },
];

const taskBody = 'task:\n  id: waiting\n  title: Na fila\n  body: "linha um\\nlinha dois"';
function okExec(rows) {
  return (cmd, args, opts) => {
    stub.execs.push({ cmd, args, opts });
    const script = String(args?.[1] ?? "");
    if (script.includes("sq-tasks show")) {
      return Promise.resolve({ code: 0, stdout: taskBody, stderr: "" });
    }
    return Promise.resolve({ code: 0, stdout: JSON.stringify(rows), stderr: "" });
  };
}

function texts(el, out = []) {
  if (typeof el === "string") out.push(el);
  else if (el && el.kids) for (const k of el.kids) texts(k, out);
  return out;
}
const allText = (el) => texts(el).join("\n");
function walk(el, out = []) {
  if (!el || typeof el === "string") return out;
  out.push(el);
  for (const k of el.kids) walk(k, out);
  return out;
}
function byId(el, id) {
  return walk(el).find((e) => e.props?.id === id) ?? null;
}
const cards = (el) => walk(el).filter((e) => String(e.props?.id ?? "").startsWith("card-"));
function headerFor(el, label) {
  return (
    walk(el).find(
      (e) =>
        e &&
        Array.isArray(e.kids) &&
        e.kids.length === 2 &&
        e.kids[0]?.kids?.length === 1 &&
        e.kids[0].kids[0] === label &&
        e.kids[1]?.kids?.length === 1,
    ) ?? null
  );
}

async function boot({ rows = fixture, win = { visible: true }, checking = false, exec = null, props = null, width = 1446 } = {}) {
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
  const mod = await module();
  const view = new mod.default();
  const cx = makeCx();
  view.init(null, cx);
  view.width = width; // the app reports this on layout; the tests set it directly
  return { view, cx, mod };
}

// ---- manifest ---------------------------------------------------------------
assert.deepEqual(Object.keys(manifest).sort(), ["focusable", "min_w", "place", "title"]);
assert.equal(manifest.focusable, true, "Escape needs the keyboard, so the mod opts in");
console.log("  ok manifest: place none, focusable true, min_w " + manifest.min_w);

// ---- tile geometry, straight from the exported functions --------------------
{
  const { mod } = await boot();
  assert.equal(mod.columnsFor(1446), 5, "five tiles per row at a full-width pane");
  assert.equal(mod.columnsFor(700), 2, "two tiles per row at 700 px");
  assert.equal(mod.columnsFor(420), 1, "one column below 480 px");
  assert.equal(mod.columnsFor(200), 1, "one column at 200 px");
  assert.equal(mod.tileWidth(1446, 5), 278, "tile edge inside the 240..280 window at full width");
  assert.equal(mod.tileWidth(700, 2), 280, "tile edge capped at 280");
  assert.equal(mod.tileWidth(200, 1), 180, "a narrow pane gets a tile as wide as it can hold");

  // 258 px of inner tile is about 34 columns a line, so the three-line box holds ~91.
  const BOX_COLS = 91;
  // An independent width model, written from the documented three-rule policy and
  // never calling the mod's own function: printable ASCII is one column, a
  // combining mark, variation selector or zero-width joiner none, and every other
  // code point two. Charging a cluster the sum of its code points can over-count
  // (a ZWJ sequence, an accented letter) and so shorten a title early, but it can
  // never under-count a glyph the renderer draws wider than ASCII.
  const segmenter = new Intl.Segmenter("pt-BR", { granularity: "grapheme" });
  const glyphs = (s) => [...segmenter.segment(s)].map((part) => part.segment);
  const mark = (ch) => {
    const point = ch.codePointAt(0);
    return (
      point === 0x200d ||
      (point >= 0x0300 && point <= 0x036f) ||
      (point >= 0x1ab0 && point <= 0x1aff) ||
      (point >= 0x1dc0 && point <= 0x1dff) ||
      (point >= 0x20d0 && point <= 0x20ff) ||
      (point >= 0xfe00 && point <= 0xfe0f) ||
      (point >= 0xfe20 && point <= 0xfe2f)
    );
  };
  const textCols = (s) =>
    Array.from(s).reduce((n, ch) => {
      const point = ch.codePointAt(0);
      if (point >= 0x20 && point <= 0x7e) return n + 1;
      return n + (mark(ch) ? 0 : 2);
    }, 0);

  const clamped = mod.clampTitle(longTitle, 258);
  assert.ok(clamped.endsWith("…"), "a title longer than three lines ends with an ellipsis");
  assert.ok(
    textCols(clamped.slice(0, -1)) <= BOX_COLS,
    `the ellipsis lands inside the three-line box, got ${textCols(clamped)} columns`,
  );
  assert.equal(mod.clampTitle("Curto", 258), "Curto", "a short title is left alone");
  assert.equal(mod.clampTitle("😀".repeat(10), 258), "😀".repeat(10), "a wide-glyph title that fits is left unclamped");
  const narrow = mod.clampTitle(longTitle, 160);
  assert.ok(narrow.endsWith("…") && narrow.length < clamped.length, "a narrower tile truncates sooner");

  // Six glyph shapes, all longer than the box, each cut inside it and at a whole
  // cluster: no trailing joiner or selector, no lone surrogate, ellipsis after a
  // complete glyph. BMP emoji and CJK are the classes a Unicode table priced
  // wrong before; the three-rule policy prices them at two without a table.
  const shapes = [
    ["plain", longTitle],
    ["astral", "😀".repeat(120)],
    ["presentation", "\u2764\ufe0f".repeat(100)],
    ["joined", "👩\u200d💻".repeat(80)],
    ["bmp-emoji", "\u2705".repeat(120)],
    ["cjk", "\u6f22".repeat(120)],
  ];
  for (const [name, source] of shapes) {
    const out = mod.clampTitle(source, 258);
    const body = out.slice(0, -1);
    assert.ok(out.endsWith("…"), `${name}: the title ends with an ellipsis`);
    assert.ok(
      textCols(body) <= BOX_COLS,
      `${name}: the retained title fits the three-line column budget, got ${textCols(body)} columns`,
    );
    assert.ok(!body.endsWith("\u200d"), `${name}: the cut never leaves a dangling zero-width joiner`);
    assert.ok(
      glyphs(body).length > 0 && !Array.from(glyphs(body).at(-1)).every(mark),
      `${name}: the last retained glyph is a whole cluster, not a stray mark or selector`,
    );
    assert.ok(
      Array.from(body).every((ch) => {
        const point = ch.codePointAt(0);
        return point < 0xd800 || point > 0xdfff;
      }),
      `${name}: truncation never leaves a lone surrogate`,
    );
    assert.equal(glyphs(out).at(-1), "…", `${name}: the ellipsis directly follows a whole cluster`);
  }

  // Anchors that do not go through any width table: a glyph priced at two columns
  // keeps about half the glyphs a plain ASCII one does, for astral and for BMP
  // emoji alike. A table that priced a BMP emoji at one column fails this.
  const plainRun = mod.clampTitle("a".repeat(200), 258);
  const wideRun = mod.clampTitle("😀".repeat(120), 258);
  const bmpRun = mod.clampTitle("\u2705".repeat(120), 258);
  assert.ok(
    glyphs(wideRun).length <= glyphs(plainRun).length * 0.6 + 2,
    `an astral glyph keeps about half the glyphs of a plain one (${glyphs(wideRun).length} vs ${glyphs(plainRun).length})`,
  );
  assert.ok(
    glyphs(bmpRun).length <= glyphs(plainRun).length * 0.6 + 2,
    `a BMP emoji keeps about half the glyphs of a plain one (${glyphs(bmpRun).length} vs ${glyphs(plainRun).length})`,
  );
  assert.equal(
    mod.clampTitle("a".repeat(BOX_COLS) + "\u0301" + "b".repeat(50), 258),
    "a".repeat(BOX_COLS) + "\u0301…",
    "a combining mark past the cut stays with its base glyph instead of being orphaned",
  );
  console.log("  ok tile geometry: 5 x 278 at full width, 2 x 280 at 700, 1 x 180 at 200, ellipsis inside the tile");
}

// ---- the three sections, live counts, and list-mode squares ------------------
{
  const { view, cx } = await boot({ props: { base: "/repo" } });
  await flush();
  assert.equal(stub.execs.length, 1, "one board read per poll");
  const call = stub.execs[0];
  assert.equal(call.cmd, "/bin/bash");
  assert.match(call.args[1], /bin\/sq-board\.sh --json/);
  assert.match(call.args[1], /cd '\/repo' && SQUAD_BASE='\/repo'/, "the props base is authoritative for the read");
  assert.doesNotMatch(call.args[1], /--state/, "one read of the whole board supplies all three sections");
  assert.equal(call.opts.timeout, 180000, "the read is bounded by an explicit timeout");
  assert.equal(stub.timer.ms, 60000, "at most one read per minute, never tighter than 15 s");

  const tree = view.render(cx);
  const text = allText(tree);
  for (const label of ["EM VOO", "FILA", "EM ESPERA"]) assert.ok(text.includes(label), `section ${label}`);
  for (const [label, count] of Object.entries({ "EM VOO": "3", FILA: "1", "EM ESPERA": "1" })) {
    const header = headerFor(tree, label);
    assert.ok(header, `section ${label} has its own header`);
    assert.equal(texts(header.kids[1]).join(""), count, `section ${label} shows its own count`);
  }

  const tiles = cards(tree);
  assert.equal(tiles.length, 5, "one card per mission");
  for (const tile of tiles) {
    assert.equal(tile.props.w, 278, "every list tile has the fixed width");
    assert.equal(tile.props.h, 278, "every list tile is square by construction");
    assert.ok(!tile.props.flex_1, "no tile stretches with flex_1");
  }
  assert.ok(walk(tree).some((e) => e.props?.flex_wrap), "the tiles wrap into rows");
  assert.ok(!walk(tree).some((e) => e.props?.overflow_x_scrollbar), "list mode never scrolls sideways");

  // The clamped title inside the tile, with its ellipsis.
  const titleText = allText(byId(tree, "card-live"));
  assert.ok(titleText.includes("…"), "the long title is ellipsized inside its tile");
  assert.ok(titleText.includes("strike · squad"), "kind and repo sit on the meta line");
  assert.ok(titleText.includes("working"), "the live agent status is the card's status label");
  assert.ok(titleText.includes("7m"), "elapsed is on the card");
  console.log("  ok three sections with live counts, 278 px square tiles that wrap, no sideways scroll");
}

// ---- click: in-flight focuses its pane, queue and held open the body --------
{
  const { view, cx } = await boot();
  await flush();
  const tree = view.render(cx);
  byId(tree, "card-live").click({}, cx);
  assert.deepEqual(stub.calls, [{ name: "agent.focus", args: { terminal: "t1k" } }], "an in-flight card with a live agent focuses it");
  // The tmux row carries the very same live address as the herdr-core card (t1k),
  // so its inertness can only come from the backend gate.
  assert.ok(stub.agents.some((a) => a.address === "t1k"), "the address both rows point at is live");
  assert.ok(byId(tree, "card-live").props.cursor_pointer, "an actionable card looks clickable");
  assert.equal(byId(tree, "card-tmux").click, undefined, "the same address on a tmux row is not actionable");
  assert.equal(byId(tree, "card-tmux").props.cursor_pointer, undefined, "and it does not look clickable");
  assert.equal(byId(tree, "card-dead").click, undefined, "a recorded window whose terminal is gone is not actionable");
  assert.equal(byId(tree, "card-dead").props.cursor_pointer, undefined, "and it does not look clickable");
  assert.ok(byId(tree, "card-waiting").props.cursor_pointer, "a queue card is a control: it opens the body");
  assert.equal(stub.calls.length, 1, "no other app command runs");

  const before = stub.execs.length;
  byId(tree, "card-waiting").click({}, cx);
  const show = stub.execs[before];
  assert.equal(show.cmd, "/bin/bash");
  assert.match(show.args[1], /sq-tasks show 'waiting' --full/, "the body is read on demand with the read-only show verb");
  assert.equal(show.opts.timeout, 60000, "the body read is bounded too");
  await flush();
  const panel = view.render(cx);
  const panelText = allText(byId(panel, "detail"));
  assert.ok(panelText.includes("Na fila"), "the panel shows the task");
  assert.ok(panelText.includes("linha um") && panelText.includes("linha dois"), "the panel shows the whole body, not a summary");
  assert.ok(panelText.includes("fechar (Esc)"), "the panel has a close control");
  assert.ok(!panelText.includes("…"), "the title is not clamped inside the panel");
  assert.equal(stub.calls.length, 1, "opening a card runs no app command at all");

  const keyed = walk(panel).find((e) => typeof e.props?.on_key_down === "function");
  assert.ok(keyed, "the board holds the keyboard so Escape can reach it");
  keyed.props.on_key_down({ key: "escape" }, cx);
  assert.equal(byId(view.render(cx), "detail"), null, "Escape closes the task body");

  byId(view.render(cx), "card-parked").click({}, cx);
  await flush();
  byId(view.render(cx), "detail-close").click({}, cx);
  assert.equal(byId(view.render(cx), "detail"), null, "the close control closes the task body");
  console.log("  ok in-flight cards focus their pane; queue and held cards open a read-only body panel that Escape and its control close");
}

// ---- the panel body stops before sq-tasks' own help block -------------------
{
  const plainBody = [
    "task:",
    "  id: waiting",
    "  title: Na fila",
    "  body: current status only",
    "help[2]:",
    "- Run sq-tasks show <id> for the whole task",
    "- Run sq-tasks update <id> to change it",
  ].join("\n");
  const withBody = (rows) => {
    const base = okExec(rows);
    return (cmd, args, opts) => {
      if (String(args?.[1] ?? "").includes("sq-tasks show")) {
        stub.execs.push({ cmd, args, opts });
        return Promise.resolve({ code: 0, stdout: plainBody, stderr: "" });
      }
      return base(cmd, args, opts);
    };
  };
  const { view, cx } = await boot({ exec: withBody(fixture) });
  await flush();
  byId(view.render(cx), "card-waiting").click({}, cx);
  await flush();
  const panelText = allText(byId(view.render(cx), "detail"));
  assert.ok(panelText.includes("current status only"), "a plain single-line body is shown in full");
  assert.ok(!panelText.includes("help["), "the panel stops before sq-tasks' help header");
  assert.ok(!panelText.includes("Run sq-tasks"), "sq-tasks' suggestions never become part of the task body");
  console.log("  ok the panel body stops before sq-tasks' help block");
}

// ---- the sort control: display order only, remembered in shared() -----------
{
  const { view, cx } = await boot();
  await flush();
  view.width = 1446;
  const order = (tree) => cards(tree).map((c) => String(c.props.id));
  assert.equal(view.sort(), "priority", "priority leads the keys, so it is the default order");
  assert.deepEqual(order(view.render(cx)), ["card-tmux", "card-live", "card-dead", "card-waiting", "card-parked"], "priority 1 first, then 2, then unset last");

  const cycle = ["elapsed", "kind", "repo", "title", "state", "priority"];
  for (const expected of cycle) {
    byId(view.render(cx), "sort").click({}, cx);
    assert.equal(stub.shared["board.view"] ?? null, null, "sorting never touches the view choice");
    assert.equal(view.sort(), expected, `the control advances to ${expected}`);
  }

  const repo = await boot();
  await flush();
  repo.view.width = 1446;
  stub.shared["board.sort"] = "elapsed";
  assert.deepEqual(order(repo.view.render(repo.cx)), ["card-tmux", "card-dead", "card-live", "card-waiting", "card-parked"], "elapsed sorts the cards inside each section, fastest first");
  stub.shared["board.sort"] = "repo";
  assert.deepEqual(order(repo.view.render(repo.cx)), ["card-dead", "card-live", "card-tmux", "card-waiting", "card-parked"], "repo sorts the cards inside each section");
  stub.shared["board.sort"] = "state";
  assert.deepEqual(order(repo.view.render(repo.cx)), ["card-live", "card-dead", "card-tmux", "card-waiting", "card-parked"], "state keeps the board's own order");
  assert.equal(stub.execs.length, 1, "sorting reads nothing");
  assert.equal(stub.calls.length, 0, "sorting runs no app command and writes no backlog");

  const again = await load();
  const restarted = new again();
  restarted.init(null, makeCx());
  await flush();
  restarted.width = 1446;
  stub.shared["board.sort"] = "repo";
  assert.equal(restarted.sort(), "repo", "the chosen key survives a restart through shared()");
  console.log("  ok sort control cycles the display keys, persists in shared(), and never writes or reorders the backlog");
}

// ---- kanban: equal columns, capped cards, and its fallback ------------------
{
  const { view, cx } = await boot();
  stub.shared["board.view"] = "kanban";
  await flush();
  view.width = 1446;
  const tree = view.render(makeCx());
  assert.ok(!walk(tree).some((e) => e.props?.flex_wrap), "kanban draws columns, not a wrapping grid");
  const columns = walk(tree).filter((e) => e.props?.overflow_y_scrollbar);
  assert.equal(columns.length, 3, "one scrolling column per section");
  for (const column of columns) assert.equal(column.props.flex_1, true, "kanban columns share the width equally");
  const kanbanCards = cards(tree);
  assert.ok(kanbanCards.length > 0, "kanban keeps the cards");
  for (const tile of kanbanCards) {
    assert.equal(tile.props.max_w, 320, "a kanban card never stretches past 320 px");
    assert.equal(tile.props.w, undefined, "a kanban card is not a fixed square");
  }
  assert.ok(!walk(tree).some((e) => e.props?.overflow_x_scrollbar), "kanban never clips sideways");

  // Below 700 px there is no room for three columns, so kanban falls back.
  view.width = 600;
  const narrow = view.render(makeCx());
  assert.ok(walk(narrow).some((e) => e.props?.flex_wrap), "below 700 px kanban falls back to the grid");
  for (const tile of cards(narrow)) {
    assert.equal(tile.props.w, 280, "the fallback keeps the fixed square tile");
    assert.equal(tile.props.max_w, undefined, "the fallback draws no column-capped card");
  }
  console.log("  ok kanban: three equal scrolling columns, cards capped at 320 px, grid fallback below 700 px");
}

// ---- a pinned view, and the toggle that survives a restart -------------------
{
  const { view, cx } = await boot({ props: { base: "/repo", view: "kanban" } });
  await flush();
  view.width = 1446;
  const tree = view.render(cx);
  assert.equal(byId(tree, "view-list"), null, "a pinned tab draws no toggle, so the control cannot lie");
  assert.ok(walk(tree).some((e) => e.props?.overflow_y_scrollbar), "a pinned kanban tab renders kanban");
}
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
  restarted.width = 1446;
  await flush();
  const kanban = restarted.render(makeCx());
  assert.ok(walk(kanban).some((e) => e.props?.overflow_y_scrollbar), "the restart comes back in kanban");
  console.log("  ok pinned view draws no toggle, and the toggle's choice survives a restart");
}

// ---- the header gates its controls so the view toggle is always reachable --
{
  const { view, cx } = await boot();
  await flush();
  const at = (width) => {
    view.width = width;
    return view.render(cx);
  };

  const at280 = at(280);
  assert.ok(byId(at280, "view-list"), "the list toggle stays reachable at the declared 280 px minimum");
  assert.ok(byId(at280, "view-kanban"), "the kanban toggle stays reachable too");
  assert.equal(byId(at280, "sort"), null, "below 480 px the sort control is not drawn");
  assert.ok(allText(at280).includes("Missões"), "the short title is drawn beside the toggle at 280 px");
  assert.ok(!allText(at280).includes("ms ·"), "below 560 px the read line is not drawn");

  const at200 = at(200);
  assert.ok(byId(at200, "view-list"), "the toggle stays reachable at the 200 px readable minimum");
  assert.ok(!allText(at200).includes("Missões"), "below TITLE_MIN the title is dropped, so it cannot crowd the toggle");

  const at479 = at(479);
  assert.equal(byId(at479, "sort"), null, "the sort control stays out below 480 px");

  const at480 = at(480);
  assert.ok(byId(at480, "sort"), "the sort control appears at 480 px");
  assert.ok(!allText(at480).includes("ms ·"), "the read line stays gated at 480 px");

  const at559 = at(559);
  assert.ok(!allText(at559).includes("ms ·"), "the read line stays gated below 560 px");

  const at560 = at(560);
  assert.ok(allText(at560).includes("ms ·"), "the read line appears at 560 px");
  assert.ok(byId(at560, "sort"), "the sort control stays drawn above its threshold");
  console.log("  ok the header gates title, sort and read line, so the view toggle is reachable at 280 px");
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

// ---- every control runs only agent.focus and stores only the two views ------
{
  const { view, cx } = await boot();
  await flush();
  view.width = 1446;
  const controls = [
    "card-live",
    "card-waiting",
    "detail-close",
    "card-parked",
    "detail-close",
    "view-kanban",
    "sort",
    "view-list",
    "sort",
  ];
  for (const id of controls) {
    const control = byId(view.render(cx), id);
    if (control?.click) control.click({}, cx);
    await flush();
  }
  assert.ok(stub.calls.length > 0, "a card ran the one focus command");
  for (const call of stub.calls) assert.equal(call.name, "agent.focus", "the board runs no app command but agent.focus");
  assert.deepEqual(
    Object.keys(stub.shared).sort(),
    ["board.sort", "board.view"],
    "the board stores exactly its two view preferences",
  );
  console.log("  ok every control runs only agent.focus and stores only board.view and board.sort");
}

rmSync(root, { recursive: true, force: true });
JS
pass "behavior: sections, cards, click, budget, states, toggle, check"

# ---- read-only by contract: no lifecycle verb and no backlog write ----------
for verb in sq-spawn sq-teardown; do
  if grep -q -- "$verb" "$MOD/main.js" "$MOD/install.sh"; then
    fail "$verb must never appear in the mod or its installer"
  fi
done
if grep -Eq '\bhc[[:space:]]+(run|kill|rm|label|start|stop|exec|file|send|spawn)\b' "$MOD/main.js" "$MOD/install.sh"; then
  fail "no hc write verb may appear in the mod or its installer"
fi
# `sq-tasks show` is the one allowed verb: it only reads a task.
verbs="$(grep -oE 'sq-tasks[[:space:]]+[a-z-]+' "$MOD/main.js" | sed -E 's/sq-tasks[[:space:]]+//' | sort -u)"
if [ -n "$verbs" ] && [ "$verbs" != "show" ]; then
  fail "the only sq-tasks verb allowed is show (reads a task); found: $verbs"
fi
for write in update hold unhold start stop add remove rm mv move set edit "done" close reopen block unblock new create import export sync; do
  if grep -Eq "sq-tasks[[:space:]]+$write\b" "$MOD/main.js" "$MOD/install.sh"; then
    fail "sq-tasks $write writes the backlog and must never appear here"
  fi
done
if grep -Eq '\.on_drag\(|\.on_drop\(|draggable\(|drag_handle|set_priority|setPriority' "$MOD/main.js"; then
  fail "no drag, drop or priority path may exist in the board"
fi
pass "read-only by contract: only sq-tasks show and agent.focus, only the two view preferences, no write verb"

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
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall >/dev/null || fail "--uninstall must be idempotent: a second run with nothing to remove exits 0"
[ ! -e "$target" ] || fail "a second --uninstall must leave nothing behind"

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

# The requested mode wins: a copy run replaces a link this script created, and a
# second identical invocation changes nothing.
physical_mod="$(cd -P "$MOD" && pwd -P)"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --link >/dev/null
[ -L "$target" ] || fail "--link must create a link"
[ "$(readlink "$target")" = "$physical_mod" ] || fail "--link must point at this folder"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --link >/dev/null
[ "$(readlink "$target")" = "$physical_mod" ] || fail "a second identical --link must change nothing"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null || fail "the default run must replace an owned link with a copy"
[ ! -L "$target" ] || fail "the default run over an owned link must leave a real folder, not a link"
cmp -s "$MOD/main.js" "$target/main.js" || fail "a copy made from an owned link must hold this folder's main.js"
cmp -s "$MOD/mod.json" "$target/mod.json" || fail "a copy made from an owned link must hold this folder's mod.json"
[ -f "$marker" ] || fail "a copy made from an owned link must carry the marker"
[ -f "$MOD/main.js" ] || fail "converting an owned link to a copy must never touch the checkout"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall >/dev/null
[ ! -e "$target" ] || fail "--uninstall must remove a copy made from an owned link"

# --copy names the same conversion explicitly.
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --link >/dev/null
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --copy >/dev/null || fail "--copy must replace an owned link with a copy"
[ ! -L "$target" ] || fail "--copy over an owned link must leave a real folder, not a link"
[ -f "$marker" ] || fail "--copy over an owned link must write the marker"
cmp -s "$MOD/main.js" "$target/main.js" || fail "--copy over an owned link must hold this folder's main.js"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall >/dev/null

# A second identical copy install changes nothing.
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null
before_install="$(cksum "$target/main.js" "$target/mod.json" "$marker")"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" >/dev/null
[ "$(cksum "$target/main.js" "$target/mod.json" "$marker")" = "$before_install" ] || fail "a second identical copy install must change nothing"
[ ! -L "$target" ] || fail "a second identical copy install must leave the copy a real folder"
HERDR_APP_HOME="$tmp_home" "$MOD/install.sh" --uninstall >/dev/null

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
pass "install keeps a marker, updates and removes stale copies, converts between modes, and refuses anything it cannot prove it wrote"

# ---- the app's own validator, where the app is installed ---------------------
if command -v herdr-app >/dev/null 2>&1; then
  out="$(herdr-app check "$MOD" 2>&1)" || fail "herdr-app check: $out"
  pass "herdr-app check: $out"
else
  printf '  skip herdr-app check (herdr-app is not installed here)\n'
fi

printf 'PASS: sq-board-mod-thin\n'
