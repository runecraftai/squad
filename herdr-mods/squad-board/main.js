// Squad board: Squad's missions as cards, drawn in the Herdr app.
//
// One source of truth: `bin/sq-board.sh --json`, read at most once per
// READ_INTERVAL_MS, never while this copy is not visible, and never twice at the
// same time. A card's detail is read on demand with `sq-tasks show <id> --full`.
// Nothing here changes a mission: no dispatch, no teardown, no merge, no backlog
// write, no reorder and no priority. The only app command is `agent.focus`, on an
// in-flight card whose terminal is live.
//
// Open it as its own tab (`herdr-app do tab.new --mod squad-board`), close it
// like any tab (`herdr-app do tab.close --id <tab>`).

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, run, theme, checking, window, shared, setShared, agents, props } from "herdr";

// 16 s for one `--state in_flight` read and 72 s for the whole board on the
// machine this shipped on (340 items), so the board is read on a slow clock and
// never twice at once. A full read is what gives all three sections live counts.
const READ_INTERVAL_MS = 60000;
// The host kills the child at this bound, so a slow or hung command cannot keep a
// read (and this mod) busy forever. Ten minutes is the host's cap.
const READ_TIMEOUT_MS = 180000;
// A task's body is one small file read; a minute is generous and still bounded.
const TASK_TIMEOUT_MS = 60000;

const GAP = 8;
const PAD = 10;
const CARD_PAD = 10;
// List tiles are square and fixed: never narrower than 240, never wider than 280,
// so a row holds as many as the pane allows and no tile ever stretches into a bar.
const CARD_MIN = 240;
const CARD_MAX = 280;
const MAX_COLS = 5;
const SINGLE_COL_BELOW = 480; // the grid is a single column of tiles under this width
const KANBAN_MIN = 700; // kanban needs three usable columns, so it falls back below this
const KANBAN_CARD_MAX = 320; // in kanban a card fills its column up to this width
const DETAIL_MIN = 900; // below this the detail takes the pane instead of a side column
const DETAIL_W = 430;
const TITLE_FONT = 12.5;
const TITLE_LINE_H = 19;
const TITLE_MAX_LINES = 3;
const CHAR_W = 0.6; // measured: about this many font sizes per character in this UI
const BODY_FONT = 11.5;
const TITLE_MIN = 280; // below the declared pane minimum the title is dropped, so the toggle keeps its room
const SORT_MIN = 480; // below this the header drops the sort control
const READ_LINE_MIN = 560; // below this the header drops the read line instead of clipping

const SECTIONS = [
  { state: "in_flight", label: "EM VOO", empty: "nenhuma missão em voo" },
  { state: "queued", label: "FILA", empty: "nada na fila" },
  { state: "held", label: "EM ESPERA", empty: "nada em espera" },
];

const VIEWS = [
  { id: "list", label: "Lista" },
  { id: "kanban", label: "Kanban" },
];

// Display order only. Every key exists in `bin/sq-board.sh --json` today, and the
// choice is a view preference: it never writes to the backlog and never reorders
// the queue Squad owns.
const SORTS = [
  { id: "priority", label: "prioridade" },
  { id: "elapsed", label: "tempo" },
  { id: "kind", label: "tipo" },
  { id: "repo", label: "repo" },
  { id: "title", label: "titulo" },
  { id: "state", label: "estado" },
];

// The board records the agent's terminal as `default:t1k`, and the app addresses
// it by the terminal id alone, so `agent.focus` gets `t1k`.
function terminalOf(m) {
  const w = String(m?.window ?? "").trim();
  if (!w) return "";
  const at = w.lastIndexOf(":");
  return at === -1 ? w : w.slice(at + 1).trim();
}

// Where Squad lives: a tab may name it (`--props '{"base":"/path/to/squad"}'`),
// else a shared key the person set once. With neither, the command runs in the
// app's own folder and `$SQUAD_BASE` still gets its chance inside the shell.
function baseDir() {
  const fromProps = props()?.base;
  if (fromProps) return String(fromProps);
  const saved = shared("board.base");
  return saved ? String(saved) : "";
}

function firstLine(text) {
  return String(text ?? "").trim().split("\n")[0].trim();
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

// A board command line against the resolved base. The base is set in the
// environment for that one call as well as by `cd`, because `bin/sq-board.sh` and
// `sq-tasks` both prefer an ambient $SQUAD_BASE over their own folder.
function inBase(command) {
  const base = baseDir();
  return base
    ? `cd ${shellQuote(base)} && SQUAD_BASE=${shellQuote(base)} exec ${command}`
    : `cd "\${SQUAD_BASE:-.}" && exec ${command}`;
}

// Columns the grid can hold at this width: one column under SINGLE_COL_BELOW,
// then as many 240 px tiles as fit, capped at five.
export function columnsFor(width) {
  if (!(width > 0) || width < SINGLE_COL_BELOW) return 1;
  const usable = width - PAD * 2;
  const fit = Math.floor((usable + GAP) / (CARD_MIN + GAP));
  return Math.max(1, Math.min(MAX_COLS, fit));
}

// The fixed tile edge, in px: the pane minus its padding split across the columns,
// clamped to 240..280 so a tile is square by construction and never a full-width
// bar. A pane too narrow for 240 px still gets one tile as wide as it can be.
export function tileWidth(width, cols) {
  const usable = Math.max(0, width - PAD * 2);
  const each = Math.floor((usable - GAP * (cols - 1)) / cols);
  return Math.max(0, Math.min(CARD_MAX, each));
}

// Code points that draw nothing on their own: combining marks, variation
// selectors, and the zero-width joiner that binds two glyphs into one cluster.
function zeroWidth(point) {
  return (
    point === 0x200d ||
    (point >= 0x0300 && point <= 0x036f) ||
    (point >= 0x1ab0 && point <= 0x1aff) ||
    (point >= 0x1dc0 && point <= 0x1dff) ||
    (point >= 0x20d0 && point <= 0x20ff) ||
    (point >= 0xfe00 && point <= 0xfe0f) ||
    (point >= 0xfe20 && point <= 0xfe2f)
  );
}

// Display columns one code point takes in this UI: astral and East Asian wide
// glyphs take two, a combining mark or a joiner takes none, everything else one.
function glyphColumns(ch) {
  const point = ch.codePointAt(0);
  if (zeroWidth(point)) return 0;
  if (
    point >= 0x1100 &&
    (point <= 0x115f ||
      (point >= 0x2e80 && point <= 0xa4cf) ||
      (point >= 0xac00 && point <= 0xd7a3) ||
      (point >= 0xf900 && point <= 0xfaff) ||
      (point >= 0xfe10 && point <= 0xfe19) ||
      (point >= 0xfe30 && point <= 0xfe6f) ||
      (point >= 0xff00 && point <= 0xff60) ||
      (point >= 0xffe0 && point <= 0xffe6) ||
      (point >= 0x1f000 && point <= 0x1faff) ||
      (point >= 0x20000 && point <= 0x3fffd))
  )
    return 2;
  return 1;
}

// The glyph clusters a title really renders as: a base code point with its
// combining marks and emoji-presentation selector, plus any ZWJ chain. A cluster
// is wide (two columns) when any member is astral or wide, or when it carries
// U+FE0F, which is what turns `❤` into one wide `❤️`; everything else is one
// column. Clusters, not code points, are the unit a cut may fall between.
function titleClusters(text) {
  const points = Array.from(String(text ?? ""));
  const clusters = [];
  let i = 0;
  while (i < points.length) {
    const members = [points[i]];
    let wide = glyphColumns(points[i]) === 2;
    i += 1;
    for (;;) {
      while (i < points.length && zeroWidth(points[i].codePointAt(0)) && points[i].codePointAt(0) !== 0x200d) {
        if (points[i].codePointAt(0) === 0xfe0f) wide = true;
        members.push(points[i]);
        i += 1;
      }
      if (i + 1 < points.length && points[i].codePointAt(0) === 0x200d) {
        members.push(points[i], points[i + 1]);
        if (glyphColumns(points[i + 1]) === 2) wide = true;
        i += 2;
        continue;
      }
      break;
    }
    clusters.push({ text: members.join(""), width: wide ? 2 : 1 });
  }
  return clusters;
}

const clusterColumns = (clusters) => clusters.reduce((n, cluster) => n + cluster.width, 0);

// This UI layer has no line clamp, so the three-line budget is spent here: a
// column estimate from the tile's inner width, spent one cluster at a time (a
// wide glyph or an FE0F cluster costs two columns, a combining mark none), cut at
// a cluster and then at a word boundary, with an ellipsis that always lands
// inside the tile. The card also caps the text block's height, but that cap is
// only a backstop: the text itself already fits, so no glyph is ever sliced by
// the card boundary.
export function clampTitle(title, innerWidth, lines = TITLE_MAX_LINES) {
  const text = String(title ?? "")
    .replace(/\s+/g, " ")
    .trim();
  if (!text) return "";
  const perLine = Math.max(8, Math.floor(innerWidth / (TITLE_FONT * CHAR_W)));
  // Two and a bit lines of columns for a three-line box: word wrapping loses a
  // few columns per line, and this margin is what keeps the ellipsis inside.
  const budget = Math.max(8, Math.floor(perLine * lines * 0.9));
  const clusters = titleClusters(text);
  if (clusterColumns(clusters) <= budget) return text;
  let used = 0;
  let end = 0;
  while (end < clusters.length && used + clusters[end].width <= budget) {
    used += clusters[end].width;
    end += 1;
  }
  const cut = clusters.slice(0, end).map((cluster) => cluster.text).join("");
  const space = cut.lastIndexOf(" ");
  const head = space > 0 ? cut.slice(0, space) : "";
  const kept = (head && clusterColumns(titleClusters(head)) > budget * 0.5 ? head : cut).replace(
    /[\s,;:.\-\u200d]+$/,
    "",
  );
  return kept ? `${kept}…` : "…";
}

// Seconds behind the board's `busy_elapsed` (`7m`, `1h20m`, `3h4m`, `<1m`), so the
// elapsed sort is numeric instead of alphabetical. Unknown sorts last.
export function elapsedSeconds(text) {
  const value = String(text ?? "").trim();
  if (!value) return Number.POSITIVE_INFINITY;
  if (value.startsWith("<")) return 0;
  let total = 0;
  let found = false;
  const pattern = /(\d+)\s*([dhms])/g;
  let match = pattern.exec(value);
  while (match) {
    found = true;
    const n = Number(match[1]);
    const unit = match[2];
    total += unit === "d" ? n * 86400 : unit === "h" ? n * 3600 : unit === "m" ? n * 60 : n;
    match = pattern.exec(value);
  }
  return found ? total : Number.POSITIVE_INFINITY;
}

const byText = (a, b, field) => String(a[field] ?? "").localeCompare(String(b[field] ?? ""), "pt-BR");

// The backlog's own priority number, lower first, and unset sorted last so an
// unprioritised task never pretends to be urgent.
export function priorityRank(m) {
  const value = Number.parseInt(String(m?.priority ?? "").trim(), 10);
  return Number.isFinite(value) ? value : Number.POSITIVE_INFINITY;
}

// The drawing order for one section. `state` is the section's own grouping, so it
// keeps the board's order; every other key sorts the cards inside the section.
export function sortRows(rows, key) {
  const list = [...rows];
  if (key === "state") return list;
  const tie = (a, b) => byText(a, b, "title");
  if (key === "priority")
    return list.sort(
      (a, b) =>
        priorityRank(a) - priorityRank(b) ||
        elapsedSeconds(a.busy_elapsed) - elapsedSeconds(b.busy_elapsed) ||
        tie(a, b),
    );
  if (key === "elapsed") return list.sort((a, b) => elapsedSeconds(a.busy_elapsed) - elapsedSeconds(b.busy_elapsed) || tie(a, b));
  if (key === "kind") return list.sort((a, b) => byText(a, b, "kind") || tie(a, b));
  if (key === "repo") return list.sort((a, b) => byText(a, b, "repo") || tie(a, b));
  return list.sort(tie);
}

// `sq-tasks show <id> --full` prints a small YAML block whose `body` is a quoted
// one-liner when it has newlines. This returns just the body, readable.
export function parseBody(stdout) {
  const lines = String(stdout ?? "").split("\n");
  const at = lines.findIndex((line) => /^\s{0,4}body:/.test(line));
  if (at === -1) return String(stdout ?? "").trim();
  const end = lines.findIndex((line, i) => i > at && /^help\[/.test(line));
  const kept = lines.slice(at, end === -1 ? undefined : end);
  const rest = kept[0].replace(/^\s{0,4}body:\s?/, "");
  if (rest.startsWith('"')) {
    try {
      return JSON.parse(rest);
    } catch {
      // An unterminated or non-JSON quote falls through to the plain text.
    }
  }
  return [rest, ...kept.slice(1)].join("\n").trim();
}

export default class SquadBoard extends View {
  init(_props, cx) {
    this.items = [];
    this.loaded = false; // a read has finished, so the board is either cards or an error
    this.reading = false; // the overlap guard: one read at a time
    this.at = 0; // when the last read finished, for the 60 s floor
    this.ms = null; // how long that read took, shown in the header
    this.error = null;
    this.width = 0; // last laid-out pane width, in logical px
    this.handle = cx.focus_handle(); // Escape needs the keyboard
    this.detailId = null; // the task whose body is open
    this.detail = null; // { loading, body, error } for that task
    // A deep link for a person who wants one task open on first paint.
    const wanted = props()?.detail;
    if (typeof wanted === "string" && wanted) {
      this.detailId = wanted;
      this.detail = { loading: !checking(), body: "", error: null };
    }
    // `herdr-app check` renders this view once; a read there would only warn.
    if (checking()) {
      this.loaded = true;
      return;
    }
    if (this.detailId) this.loadDetail(this.detailId, cx);
    this.reload(cx);
    cx.timer.every(READ_INTERVAL_MS, (cx) => this.reload(cx));
  }

  reload(cx) {
    if (checking()) return; // never read during `herdr-app check`
    if (this.reading) return; // a slow board never stacks a second read
    if (window()?.visible === false) return; // nothing is on screen, so nothing to paint
    // The floor lives here, not in the timer, so no caller can beat it: one read
    // per READ_INTERVAL_MS per copy however often a paint or a tick asks.
    if (this.loaded && Date.now() - this.at < READ_INTERVAL_MS) return;
    this.reading = true;
    cx.spawn(async (cx) => {
      const started = Date.now();
      try {
        const r = await exec("/bin/bash", ["-c", inBase("bin/sq-board.sh --json")], { timeout: READ_TIMEOUT_MS });
        if (r.code !== 0) {
          const why = firstLine(r.stderr);
          throw new Error(
            r.code === 127 || /No such file|not found/i.test(why)
              ? "não achei bin/sq-board.sh: abra a aba com --props '{\"base\":\"/caminho/do/squad\"}' ou defina SQUAD_BASE"
              : `bin/sq-board.sh falhou (código ${r.code}): ${why || "sem saída de erro"}`,
          );
        }
        const rows = JSON.parse(r.stdout);
        if (!Array.isArray(rows)) throw new Error("bin/sq-board.sh --json não devolveu uma lista");
        this.items = rows;
        this.error = null;
      } catch (e) {
        // A failing or slow command still paints text: the last good cards stay
        // under the error line instead of an empty board.
        this.error = String(e?.message ?? e);
      }
      this.ms = Date.now() - started;
      this.at = Date.now();
      this.reading = false;
      this.loaded = true;
      cx.notify();
    });
  }

  // The body is read on demand, once per open, with the read-only `show` verb.
  loadDetail(id, cx) {
    if (checking()) return;
    this.detailId = id;
    this.detail = { loading: true, body: "", error: null };
    this.handle?.focus(); // so Escape reaches the board
    cx.spawn(async (cx) => {
      try {
        const r = await exec("/bin/bash", ["-c", inBase(`sq-tasks show ${shellQuote(id)} --full`)], {
          timeout: TASK_TIMEOUT_MS,
        });
        if (r.code !== 0) throw new Error(firstLine(r.stderr) || `sq-tasks show saiu com código ${r.code}`);
        if (this.detailId !== id) return; // a newer card won the panel
        this.detail = { loading: false, body: parseBody(r.stdout), error: null };
      } catch (e) {
        if (this.detailId !== id) return;
        this.detail = { loading: false, body: "", error: String(e?.message ?? e) };
      }
      cx.notify();
    });
  }

  closeDetail(cx) {
    this.detailId = null;
    this.detail = null;
    cx.notify();
  }

  // A tab can pin its view with `--props '{"view":"kanban"}'`; without a pin the
  // toggle's choice in shared() governs, which is what survives a restart.
  pinnedView() {
    const pinned = props()?.view;
    return pinned === "list" || pinned === "kanban" ? pinned : "";
  }

  view() {
    return this.pinnedView() || (shared("board.view") === "kanban" ? "kanban" : "list");
  }

  // Display order from shared(): a preference of this person's, not a write.
  // Priority leads the list, so it is also the default order.
  sort() {
    const saved = shared("board.sort");
    return SORTS.some((s) => s.id === saved) ? saved : "priority";
  }

  // Kanban needs three columns of usable width, so it falls back to the grid
  // instead of squeezing them.
  kanban() {
    return this.view() === "kanban" && this.width >= KANBAN_MIN;
  }

  // A card is focusable only when the board recorded a window for it, the row was
  // recorded on the herdr-core backend, and that terminal is live in the app's own
  // agent list. A core recycles an address when a terminal closes and two rows can
  // share `<session>:<address>`, so a recorded window alone would sometimes open a
  // dead terminal or another mission's - the live list is what makes it safe.
  //
  // The live bare address is the strongest identity the app's API allows: it
  // exposes no session or core name (the agent list carries only address, pane,
  // space, tab and title), so the recorded `session:` prefix cannot be compared
  // with the core attached here. A row recorded against another core could only
  // mis-target if that exact address were simultaneously live in this core; the
  // adapter's own session refusal guards its own commands, not `agent.focus`.
  addressFor(m, live) {
    if (String(m?.backend ?? "") !== "herdr-core") return "";
    const address = terminalOf(m);
    return address && live.has(address) ? address : "";
  }

  statusLabel(m, address, live) {
    return m.endpoint_state || live.get(address) || (address ? "live" : "sem agente");
  }

  // IN FLIGHT shows the mission's agent; a mission in the queue or on hold has no
  // terminal to show, so its card opens the task body instead. Nothing here ever
  // moves a card, writes a priority, or touches the backlog.
  wanted(m, address) {
    if (m.state === "in_flight") return address ? "focus" : "";
    return "detail";
  }

  text(value, t, size = 10.5) {
    return div().text_size(size).text_color(t.dim).child(value);
  }

  // One tile. In list mode `box` is the fixed square edge, so width and height are
  // the same number by construction; in kanban the card fills its column up to
  // KANBAN_CARD_MAX so a wide column never turns it into a bar either.
  card(m, t, live, { box, mode, inner }) {
    const address = this.addressFor(m, live);
    const status = this.statusLabel(m, address, live);
    const tone = t[m.endpoint_state || live.get(address)] ?? t.unknown;
    const action = this.wanted(m, address);
    const open = this.detailId === m.id;
    return v_flex()
      .id(`card-${m.id}`)
      .flex_none()
      .min_w(0)
      .when(mode === "list", (el) => el.w(box).h(box))
      .when(mode === "kanban", (el) => el.w_full().max_w(KANBAN_CARD_MAX))
      .p(CARD_PAD)
      .gap(3)
      .rounded(8)
      .bg(open ? t.selected : t.surface)
      .border(1)
      .border_color(open ? t.accent : t.border)
      .when(Boolean(action), (el) =>
        el
          .cursor_pointer()
          .hover((s) => s.bg(t.raised))
          .on_click((_e, cx) => (action === "focus" ? run("agent.focus", { terminal: address }) : this.loadDetail(m.id, cx))),
      )
      // Elapsed, top-right on its own row so it never fights the title.
      .child(h_flex().items_center().child(div().flex_1()).child(this.text(m.busy_elapsed || "—", t, 10)))
      .child(
        h_flex()
          .gap(5)
          .items_start()
          .child(div().size(7).flex_none().mt(5).rounded(4).bg(tone))
          .child(
            div()
              .flex_1()
              .min_w(0)
              .text_size(TITLE_FONT)
              .font_semibold()
              .text_color(t.foreground)
              .whitespace_normal()
              .max_h(TITLE_LINE_H * TITLE_MAX_LINES)
              .overflow_hidden()
              .child(clampTitle(m.title || m.id, inner)),
          ),
      )
      .child(div().flex_1())
      .child(div().text_size(10.5).text_color(t.muted).truncate().child(`${m.kind || "—"} · ${m.repo || "—"}`))
      .child(
        h_flex()
          .gap(5)
          .items_center()
          .min_w(0)
          .child(div().size(6).flex_none().rounded(3).bg(tone))
          .child(div().text_size(10).text_color(t.muted).truncate().child(status)),
      );
  }

  sectionHeader(s, count, t) {
    return h_flex()
      .gap(6)
      .items_center()
      .pl(1)
      .child(div().text_size(11).font_semibold().text_color(t.dim).child(s.label))
      .child(div().text_size(10).text_color(t.dim).child(String(count)));
  }

  rowsFor(state) {
    return sortRows(
      this.items.filter((m) => m.state === state),
      this.sort(),
    );
  }

  // List: square tiles of one fixed edge, wrapping into as many columns as the
  // pane holds. Nothing here stretches, so no card can become a bar.
  listBody(t, live) {
    const cols = columnsFor(this.width);
    const box = tileWidth(this.width, cols);
    const inner = box - CARD_PAD * 2;
    return SECTIONS.flatMap((s) => {
      const rows = this.rowsFor(s.state);
      return [
        this.sectionHeader(s, rows.length, t),
        rows.length
          ? h_flex()
              .flex_wrap()
              .gap(GAP)
              .items_start()
              .children(rows.map((m) => this.card(m, t, live, { box, mode: "list", inner })))
          : this.text(s.empty, t),
      ];
    });
  }

  // Kanban: three equal columns filling the pane, each scrolling on its own, and
  // every card capped at KANBAN_CARD_MAX so a wide column keeps a card's shape.
  kanbanBody(t, live) {
    const cols = SECTIONS.length;
    const columnInner = Math.floor((this.width - PAD * 2 - GAP * (cols - 1)) / cols);
    const inner = Math.min(KANBAN_CARD_MAX, columnInner) - CARD_PAD * 2;
    return h_flex().flex_1().min_h(0).gap(GAP).items_stretch().children(
      SECTIONS.map((s) => {
        const rows = this.rowsFor(s.state);
        return v_flex()
          .flex_1()
          .min_w(0)
          .gap(6)
          .child(this.sectionHeader(s, rows.length, t))
          .child(
            v_flex()
              .flex_1()
              .min_h(0)
              .gap(6)
              .overflow_y_scrollbar()
              .children(
                rows.length
                  ? rows.map((m) => this.card(m, t, live, { box: 0, mode: "kanban", inner }))
                  : [this.text(s.empty, t)],
              ),
          );
      }),
    );
  }

  // The task body, read on demand. Monospace, scrollable, and dismissable with the
  // close control or Escape; the title is never clamped here.
  detailPanel(t, cx) {
    const row = this.items.find((m) => m.id === this.detailId);
    const detail = this.detail ?? { loading: true, body: "", error: null };
    const title = row?.title || this.detailId || "";
    return v_flex()
      .id("detail")
      .flex_none()
      .when(this.width >= DETAIL_MIN, (el) => el.w(DETAIL_W))
      .when(this.width < DETAIL_MIN, (el) => el.flex_1())
      .min_h(0)
      .h_full()
      .p(12)
      .gap(6)
      .rounded(8)
      .bg(t.surface)
      .border(1)
      .border_color(t.accent)
      .child(
        h_flex()
          .items_center()
          .gap(6)
          .child(div().text_size(10).font_semibold().text_color(t.dim).child("TAREFA"))
          .child(div().flex_1())
          .child(
            div()
              .id("detail-close")
              .px(6)
              .py(2)
              .rounded(5)
              .text_size(10.5)
              .text_color(t.dim)
              .cursor_pointer()
              .hover((s) => s.bg(t.hover).text_color(t.foreground))
              .on_click((_e, cx) => this.closeDetail(cx))
              .child("fechar (Esc)"),
          ),
      )
      .child(div().text_size(13).font_semibold().text_color(t.foreground).whitespace_normal().child(title))
      .child(
        this.text(
          [row?.kind, row?.repo, row?.state, row?.busy_elapsed].filter(Boolean).join(" · ") || this.detailId || "",
          t,
          10,
        ),
      )
      .child(div().text_size(10).text_color(t.dim).child("somente leitura · sq-tasks show --full"))
      .child(
        v_flex()
          .flex_1()
          .min_h(0)
          .overflow_y_scrollbar()
          .gap(4)
          .when(detail.loading, (el) => el.child(this.text("lendo a tarefa…", t, BODY_FONT)))
          .when(Boolean(detail.error), (el) =>
            el.child(div().text_size(BODY_FONT).text_color(t.blocked).whitespace_normal().child(detail.error)),
          )
          .when(!detail.loading && !detail.error, (el) =>
            el.child(
              div()
                .text_size(BODY_FONT)
                .font_family("monospace")
                .text_color(t.muted)
                .whitespace_normal()
                .child(detail.body || "(sem corpo)"),
            ),
          ),
      );
  }

  toggle(entry, t) {
    const active = this.view() === entry.id;
    return div()
      .id(`view-${entry.id}`)
      .px(8)
      .h(20)
      .flex()
      .items_center()
      .rounded(5)
      .cursor_pointer()
      .bg(active ? t.raised : t.background)
      .text_size(10.5)
      .text_color(active ? t.accent : t.dim)
      .when(!active, (el) => el.hover((s) => s.bg(t.hover)))
      .on_click((_e, cx) => {
        // shared() outlives this copy, so the choice survives a restart.
        setShared("board.view", entry.id);
        cx.notify();
      })
      .child(entry.label);
  }

  // The sort control cycles the display keys. It writes one shared preference and
  // nothing else: the backlog's order belongs to Squad.
  sortControl(t) {
    const current = SORTS.find((s) => s.id === this.sort()) ?? SORTS[0];
    const next = SORTS[(SORTS.indexOf(current) + 1) % SORTS.length];
    return div()
      .id("sort")
      .px(8)
      .h(20)
      .flex()
      .items_center()
      .rounded(5)
      .flex_none()
      .border(1)
      .border_color(t.border)
      .bg(t.surface)
      .text_size(10.5)
      .text_color(t.dim)
      .cursor_pointer()
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => {
        setShared("board.sort", next.id);
        cx.notify();
      })
      .child(`ordem: ${current.label}`);
  }

  header(t) {
    const shown = this.ms === null ? "lendo…" : `[${this.ms}ms · ${this.items.length}]`;
    return h_flex()
      .gap(8)
      .items_center()
      .px(PAD)
      .py(6)
      .flex_none()
      .min_w(0)
      .when(this.width >= TITLE_MIN, (el) =>
        el.child(div().flex_none().text_size(13).font_semibold().text_color(t.foreground).child("Missões")),
      )
      .child(div().flex_1())
      // A pinned tab has nothing to toggle, so the control is not drawn. It comes
      // before the other controls, so a narrow pane can never push it out.
      .when(!this.pinnedView(), (el) =>
        el.child(
          h_flex()
            .gap(2)
            .p(2)
            .rounded(6)
            .flex_none()
            .bg(t.surface)
            .border(1)
            .border_color(t.border)
            .children(VIEWS.map((v) => this.toggle(v, t))),
        ),
      )
      .when(this.width >= SORT_MIN, (el) => el.child(this.sortControl(t)))
      // Below READ_LINE_MIN the read line is dropped rather than clipped: the
      // toggle is the only control, so it keeps its room.
      .when(this.width >= READ_LINE_MIN, (el) => el.child(div().flex_none().child(this.text(shown, t, 10))));
  }

  board(t, live) {
    if (!this.loaded) {
      return v_flex().flex_1().min_w(0).p(PAD).child(this.text("lendo o board…", t));
    }
    const error = this.error
      ? div().text_size(10.5).text_color(t.blocked).whitespace_normal().child(this.error)
      : null;
    if (this.kanban()) {
      return v_flex()
        .flex_1()
        .min_h(0)
        .min_w(0)
        .p(PAD)
        .gap(GAP)
        .when(Boolean(error), (el) => el.child(error))
        .child(this.kanbanBody(t, live));
    }
    return v_flex()
      .flex_1()
      .min_h(0)
      .min_w(0)
      .p(PAD)
      .gap(GAP)
      .overflow_y_scrollbar()
      .when(Boolean(error), (el) => el.child(error))
      .children(this.listBody(t, live));
  }

  render(cx) {
    const t = theme();
    // The app's contract for a hidden window: stop polling, then re-read on the
    // first paint after it is visible again. Without this a copy that was hidden
    // through a whole interval would stay stale until the next tick; reload()
    // owns the visibility, overlap and interval guards.
    this.reload(cx);
    const live = new Map(agents().map((a) => [a.address, a.status]));
    const body = this.board(t, live);
    return v_flex()
      .size_full()
      .min_w(0)
      .bg(t.background)
      .track_focus(this.handle)
      // Escape closes the task body and does nothing else; the board has no
      // other keyboard action.
      .on_key_down((e, cx) => {
        if (e.key === "escape" && this.detailId) this.closeDetail(cx);
      })
      .child(this.header(t))
      .when(!this.detailId, (el) => el.child(body))
      .when(Boolean(this.detailId), (el) =>
        el.child(
          h_flex()
            .flex_1()
            .min_h(0)
            .min_w(0)
            .gap(GAP)
            // Narrow: the panel takes the pane. Wide: it sits beside the board,
            // and only the panel carries the pane padding so the board keeps its own.
            .when(this.width < DETAIL_MIN, (row) =>
              row.child(div().flex_1().min_w(0).h_full().p(PAD).child(this.detailPanel(t, cx))),
            )
            .when(this.width >= DETAIL_MIN, (row) =>
              row
                .child(div().flex_1().min_w(0).h_full().child(body))
                .child(div().flex_none().h_full().p(PAD).child(this.detailPanel(t, cx))),
            ),
        ),
      )
      // Width drives the column count and the tile edge. Sizes are window px, so
      // a zoom other than 1 shifts them; the column thresholds carry margin.
      .on_size_change((size, cx) => {
        if (Math.abs(size.width - this.width) < 1) return;
        this.width = size.width;
        cx.notify();
      });
  }
}
