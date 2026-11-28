// Squad board: Squad's missions as cards, drawn in the Herdr app.
//
// One source of truth: `bin/sq-board.sh --json`. The board is read at most once
// per READ_INTERVAL_MS, never while this copy is not visible, and never twice at
// the same time. Nothing here changes a mission: no dispatch, no teardown, no
// merge, and no `hc` write. The only command this mod ever runs besides the
// board read is `agent.focus`, on a herdr-core card whose terminal the app still
// lists as live.
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
// The host kills the child at this bound, so a slow or hung board cannot keep a
// read (and this mod) busy forever. Ten minutes is the host's cap.
const READ_TIMEOUT_MS = 180000;
const SECTIONS = [
  { state: "in_flight", label: "EM VOO", empty: "nenhuma missão em voo" },
  { state: "queued", label: "FILA", empty: "nada na fila" },
  { state: "held", label: "EM ESPERA", empty: "nada em espera" },
];

const VIEWS = [
  { id: "list", label: "Lista" },
  { id: "kanban", label: "Kanban" },
];

// The board records the agent's terminal as `default:t1k`, and the app addresses
// it by the terminal id alone, so `agent.focus` gets `t1k`.
function terminalOf(m) {
  const w = String(m?.window ?? "").trim();
  if (!w) return "";
  const at = w.lastIndexOf(":");
  return at === -1 ? w : w.slice(at + 1).trim();
}

// A card is clickable only when its row is a herdr-core terminal the app still
// lists: a core recycles an address as soon as its terminal closes, and two rows
// can then record the same session:address, so a recorded window alone could
// open a dead terminal or another mission's. A tmux or zellij row stores
// session:window, which is not an app terminal id at all.
function focusAddress(m, live) {
  if (String(m?.backend ?? "") !== "herdr-core") return "";
  const address = terminalOf(m);
  return address && live.has(address) ? address : "";
}

// Where Squad lives: a tab may name it (`--props '{"base":"/path/to/squad"}'`),
// else a shared key the person set once. A chosen base is handed to the read as
// `SQUAD_BASE`, because that is what the board script consults first: an ambient
// value from the app's environment must not win over the base that was chosen.
// With neither, the command runs in the app's own folder and `$SQUAD_BASE` still
// gets its chance inside the shell.
function baseDir() {
  const fromProps = props()?.base;
  if (fromProps) return String(fromProps);
  const saved = shared("board.base");
  return saved ? String(saved) : "";
}

function firstLine(text) {
  return String(text ?? "").trim().split("\n")[0].trim();
}

// One shell word, safe for a path with spaces or quotes in it.
function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

export default class SquadBoard extends View {
  init(_props, cx) {
    this.items = [];
    this.loaded = false; // a read has finished, so the board is either cards or an error
    this.reading = false; // the overlap guard: one read at a time
    this.at = 0; // when the last read finished, for the 60 s floor
    this.ms = null; // how long that read took, shown in the header
    this.error = null;
    // `herdr-app check` renders this view once; a read there would only warn.
    if (checking()) {
      this.loaded = true;
      return;
    }
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
    const base = baseDir();
    // `SQUAD_BASE` is set to the base that was chosen here, so the board script
    // reads it and not a stale one from the app's environment. A chosen base is
    // `cd`-ed to inside the command itself, so the read never depends on the
    // host honouring an exec working-directory option. Without a base, the
    // board is looked for at `$SQUAD_BASE` or where the app was started.
    const script = base
      ? `cd ${shellQuote(base)} && SQUAD_BASE=${shellQuote(base)} exec bin/sq-board.sh --json`
      : 'cd "${SQUAD_BASE:-.}" && SQUAD_BASE="$(pwd -P)" exec bin/sq-board.sh --json';
    cx.spawn(async (cx) => {
      const started = Date.now();
      try {
        const r = await exec("/bin/bash", ["-c", script], { timeout: READ_TIMEOUT_MS });
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

  view() {
    return shared("board.view") === "kanban" ? "kanban" : "list";
  }

  text(value, t, size = 10.5) {
    return div().text_size(size).text_color(t.dim).child(value);
  }

  card(m, t, live) {
    const recorded = terminalOf(m);
    // A card is clickable only when the mission is on herdr-core and its
    // terminal is still in the app's agents() list; focusAddress owns that rule
    // and explains why a recorded window alone is not enough.
    const address = focusAddress(m, live);
    const liveState = live.get(recorded);
    const tone = t[m.endpoint_state || liveState] ?? t.unknown;
    return v_flex()
      .id(`card-${m.id}`)
      .min_w(0)
      .gap(3)
      .p(8)
      .rounded(7)
      .bg(t.surface)
      .border(1)
      .border_color(t.border)
      .when(Boolean(address), (el) =>
        el
          .cursor_pointer()
          .hover((s) => s.bg(t.raised))
          .on_click(() => run("agent.focus", { terminal: address })),
      )
      .child(
        h_flex().gap(6).items_start().min_w(0).child(div().size(7).flex_none().mt(5).rounded(4).bg(tone)).child(
          // The title is never cut by this mod: it wraps inside the column
          // instead, so a long mission name stays whole at 200 px and at full
          // width, and it never widens its own column.
          div()
            .flex_1()
            .min_w(0)
            .text_size(12.5)
            .text_color(t.foreground)
            .whitespace_normal()
            .child(m.title || m.id),
        ).child(div().flex_none().text_size(10.5).text_color(t.dim).child(m.busy_elapsed || "—")),
      )
      .child(
        // One wrapping line, not a row of fixed children, so `kind · repo ·
        // state` reflows with the card instead of sizing it to its content.
        div()
          .min_w(0)
          .text_size(10.5)
          .text_color(t.muted)
          .whitespace_normal()
          .child(
            [m.kind || "—", m.repo || "—", m.endpoint_state || liveState || "—"].join(" · "),
          ),
      );
  }

  section(s, t, live) {
    const rows = this.items.filter((m) => m.state === s.state);
    const cards = rows.length
      ? rows.map((m) => this.card(m, t, live))
      : [this.text(s.empty, t)];
    return v_flex()
      .min_w(0)
      .gap(5)
      .child(
        h_flex()
          .gap(6)
          .items_center()
          .pl(1)
          .child(div().text_size(11).font_semibold().text_color(t.dim).child(s.label))
          .child(div().text_size(10).text_color(t.dim).child(String(rows.length))),
      )
      .children(cards);
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

  header(t) {
    const shown = this.ms === null ? "lendo…" : `[${this.ms}ms · ${this.items.length}]`;
    // Two rows: the title shrinks and wraps so the Lista/Kanban control stays
    // reachable at 200 px, and the read line wraps on its own row instead of
    // being clipped beside the toggle.
    return v_flex()
      .min_w(0)
      .gap(4)
      .px(10)
      .py(6)
      .flex_none()
      .child(
        h_flex()
          .min_w(0)
          .gap(8)
          .items_center()
          .child(
            div()
              .flex_1()
              .min_w(0)
              .text_size(13)
              .font_semibold()
              .text_color(t.foreground)
              .whitespace_normal()
              .child("Missões"),
          )
          .child(
            h_flex()
              .flex_none()
              .gap(2)
              .p(2)
              .rounded(6)
              .bg(t.surface)
              .border(1)
              .border_color(t.border)
              .children(VIEWS.map((v) => this.toggle(v, t))),
          ),
      )
      .child(div().min_w(0).text_size(10).text_color(t.dim).whitespace_normal().child(shown));
  }

  body(t, live) {
    if (!this.loaded) return [this.text("lendo o board…", t)];
    const sections = SECTIONS.map((s) => this.section(s, t, live));
    if (this.view() === "kanban") {
      return [
        // One column per section, the same cards, read left to right. Each
        // column starts at width 0 and grows into an equal share of the pane,
        // so the three always divide the available width at full width and only
        // scroll sideways below three 200 px columns; no column, card or title
        // is ever sized by its content.
        h_flex()
          .min_w(0)
          .items_start()
          .gap(8)
          .overflow_x_scrollbar()
          .children(
            SECTIONS.map((s, i) =>
              v_flex().w(0).flex_1().min_w(200).gap(5).children([sections[i]]),
            ),
          ),
      ];
    }
    return sections;
  }

  render(cx) {
    const t = theme();
    // The app's contract for a hidden window: stop polling, then re-read on the
    // first paint after it is visible again. Without this a copy that was hidden
    // through a whole interval would stay stale until the next tick; reload()
    // owns the visibility, overlap and interval guards.
    this.reload(cx);
    const live = new Map(agents().map((a) => [a.address, a.status]));
    return v_flex()
      .size_full()
      .bg(t.background)
      .child(this.header(t))
      .child(
        v_flex()
          .flex_1()
          .min_w(0)
          .p(10)
          .gap(8)
          .overflow_y_scrollbar()
          .when(Boolean(this.error), (el) =>
            el.child(div().text_size(10.5).text_color(t.blocked).whitespace_normal().child(this.error)),
          )
          .children(this.body(t, live)),
      );
  }
}
