# squad-board - Squad's missions as cards, in the Herdr app

A Herdr mod that draws Squad's own mission board as cards: one card per mission, three sections with their real counts, a list view and a kanban view, and a click that focuses a mission's agent or opens its task body.
It is a read-only view.
It opens as its own tab and closes like any tab, and it never docks a copy into anyone's layout on its own (`"place": "none"` in `mod.json`).

## Install

The app loads a mod by name from its own mods folder, so the folder has to live at `${HERDR_APP_HOME:-$HOME/.config/herdr-app}/mods/squad-board`.

```sh
herdr-mods/squad-board/install.sh          # copy main.js and mod.json there
herdr-mods/squad-board/install.sh --link   # or link the folder, so edits here reload live
```

`--link` is untested on herdr-app 0.1.18: prefer `--copy` unless you are changing the mod and want the app's own hot reload.
The script is idempotent, touches nothing under the app home beyond `mods/` (created when missing) and `mods/squad-board`, and proves ownership with a marker file, `.squad-board-install`, that it writes last so an interrupted copy carries none.
The requested mode wins over what the target already is: the default run or `--copy` replaces a link this script created with a copy, and `--link` replaces its own copy.
Installing over an existing folder and `--uninstall` both require that marker, and both refuse a folder holding any other entry; the refusal names the manual removal (delete the folder, then install) and deletes nothing.
On a copy, `--uninstall` removes this mod's `main.js`, `mod.json` and marker plus the `gpui-kit.d.ts` and `jsconfig.json` editor files `herdr-app check` regenerates beside it, and never anything else.
On a `--link` install it removes only the link, and any editor files stay in this repository's folder.

## Open and close it

```sh
herdr-app ls                                                     # take a space id
herdr-app do tab.new --space <space-id> --mod squad-board --name "Squad board"
herdr-app do tab.close --id <tab-id>                             # closes it like any tab
```

The board reads `bin/sq-board.sh --json` from a Squad base.
A tab can name that base itself:

```sh
herdr-app do tab.new --space <space-id> --mod squad-board --props '{"base":"/path/to/squad"}'
```

A `base` in `props` is authoritative: the read runs in that folder with `SQUAD_BASE` set to it, so an ambient `SQUAD_BASE` in the app's environment cannot override it.
Without `props`, the mod uses a `board.base` value in the app's shared state, then `$SQUAD_BASE` from the environment the app was started in, then the app's own working folder.
When none of them finds `bin/sq-board.sh`, the board says so in the pane and names the two ways to point at the base.

The pane is whatever the app gives it and the layout adapts to it: nothing in the view forces a
minimum on the pane.
`mod.json` declares `"min_w": 280` - the shipped panel minimum - for readers and for this mod's own
checks; with `"place": "none"` the mod emits no layout block, so the app opens the tab at whatever
width the tab gives it, and this repository records no evidence that the app applies `min_w` itself.
What the board can show is that the view stays readable down to a single square tile: the 200 px
readability claim rests on the measured captures and on the thresholds asserted in
`tests/sq-board-mod-thin.test.sh`, not on the app honouring `min_w`.

## What it draws

- `EM VOO`, `FILA` and `EM ESPERA`, one section per board state, each with the count the board reported.
- `Lista` draws a grid of square cards: every tile has a fixed 240 to 280 px edge (`279 px` at a
  1450 px pane, which fits five per row; `280 px` at a narrower one, where four fit), and the rows
  wrap, so a wide pane shows a grid and a narrow one shows fewer columns.
  Nothing stretches, so no card can become a full-width bar.
  Under 480 px the grid is a single column of the same squares, and a pane narrower than 240 px still
  gets one tile as wide as it can hold.
- `Kanban` draws the same three sections as equal-width columns that fill the pane, each scrolling on
  its own, and every card capped at 320 px so a wide column never stretches a card into a bar.
  Kanban needs three usable columns, so under 700 px it falls back to the list grid instead of
  squeezing them.
- Inside a tile: the elapsed time at the top right, then the mission title on at most three lines
  ending in an ellipsis, then `kind · repo`, then a status dot with its label (`working`, `blocked`,
  the board's own endpoint state, or `sem agente`).
  Text is cut only by an ellipsis inside the tile; the height cap on that block is the backstop for
  any cluster the estimate still under-counts, not a promise that a card edge never touches a glyph.
  The three-line budget prices a whole glyph cluster by three rules only: a cluster carrying a
  variation selector, a zero-width joiner or the keycap mark costs two columns whatever its base;
  a cluster of printable ASCII and combining marks costs one; every other cluster costs two.
  There is no per-script table, so accented Latin, BMP and astral emoji, CJK and fullwidth text all
  cost two. The price is deliberately coarse and can over-count (an accented letter paid as two
  columns, a joined emoji paid as two), which only shortens a title a little earlier than strictly
  needed, while a full title never costs more than two columns per cluster.
- Loading (`lendo o board…`), empty (`nenhuma missão em voo`, `nada na fila`, `nada em espera`) and a
  failed read are drawn as text, so the pane is never a blank board; the last good cards stay under
  the error line.

## Clicking a card

An `EM VOO` card focuses that mission's agent: it runs `agent.focus` on the terminal the board
recorded, and only when the row is on `herdr-core` and that terminal is still in the app's `agents()`
list.
A recorded window alone would not be safe to focus: a core recycles a closed terminal's address, and
two rows can record the same `session:address`, so the live list is what decides.
An in-flight card with no live terminal offers no action.
The live bare address is the strongest identity a mod can compare: the app's API exposes no session or
core name on `agents()`, `terminals()`, `panes()` or `window()`, so the recorded `session:` prefix
cannot be checked against the core attached here.
A row recorded against another core could only mis-target if that exact address were simultaneously
live in this app; the adapter's own session refusal guards its own commands, not `agent.focus`.

A `FILA` or `EM ESPERA` card opens a detail panel with the task's whole body, read on demand with
`sq-tasks show <id> --full` - the read-only verb that prints one task.
The panel shows the title unclamped, then `kind · repo · state · elapsed`, then the body in a
monospace block that scrolls on its own.
It closes with the `fechar (Esc)` control or with Escape, and it never offers to focus anything,
because a queued or held mission has no terminal.
A tab can also open with one task already on show: `--props '{"base":"/path/to/squad","detail":"<task-id>"}'`.

## Sorting is a view preference

A small control in the header reads `ordem: prioridade` and cycles through the display keys the board
already carries: priority, elapsed time, kind, repo, title and state.
The header drops the sort control below 480 px, the read line below 560 px and the title below the
280 px pane minimum, so the view toggle is never pushed out at any width.
Priority sorts by the backlog's own number, lowest first, with an unprioritised task last, and it
leads the list, so it is also the default order.
Every key comes from the board's JSON, including the `priority` that `bin/sq-board.sh --json`
carries for every state (empty when the task records none).
The chosen key is stored through the app's `shared()` as `board.sort`, so it survives a restart, and
it changes only the order the cards are drawn in, inside each section.
`estado` keeps the board's own order, because the sections already group by state.

## Read-only by contract

The board is a view and never an editor: it reads `bin/sq-board.sh --json` and `sq-tasks show`, runs
`agent.focus`, and stores exactly two preferences (`board.view` and `board.sort`).
It has no drag and drop, no reorder, no priority write, and no backlog write of any kind.
Reordering the queue, changing a hold, and moving a task between states are Squad operations, not
board operations.
The test proves it by behaviour, not by reading the source: it replaces every Squad command, `sq-tasks`, `hc`, `herdr`, `herdr-app`, `git`, `gh`, `sq-gh` and `drill` with a shim that records each call, runs the board's own command requests against a staged Squad base built from those shims, and replaces node's process API with a recorder.
Across the first read, a card click, the panel opening and closing, every sort key, both views and a timed re-read, it asserts that the only commands recorded are `bin/sq-board.sh --json` and `sq-tasks show <id> --full`, that the only app command is `agent.focus`, that only `board.view` and `board.sort` are stored, and that no drag, drop or press handler is ever registered.
It runs every installer mode the same way, in place and from a copy inside the staged base, and asserts that the installer runs none of those commands at all.
The one case no shim can observe is a hard-coded absolute path to a program outside PATH and the base, and the test names it beside the installer proof.

## Pinned view

A tab can pin its view with `--props '{"base":"/path/to/squad","view":"kanban"}'` (or `"view":"list"`).
A pinned tab draws no toggle, because the pin wins.
Without a pin, the toggle's choice is stored in the app's `shared()` as `board.view` and survives a
restart.

## Read budget

The board is read from one command only, `bin/sq-board.sh --json`, with no state filter, because a filtered read cannot supply the other two sections' counts.
The SSH-free numbers measured on the machine this shipped from, with 340 items on the board:

| read | wall clock |
|---|---|
| `bin/sq-board.sh --json --state in_flight` (4 items) | 16 s |
| `bin/sq-board.sh --json` (340 items, what the board does) | 72 s |

So the read is bounded and paced:

- at most one read per 60 s per copy, enforced in the read itself rather than only by the timer;
- never a second read while one is running;
- never a read while the pane is not visible, and the board re-reads on the first paint after it is visible again;
- an explicit 180 s `exec` timeout, so a hung board is killed instead of holding the read open.

At 560 px and wider, the header shows the last read's own measured milliseconds and item count, for example `[16312ms · 340]`.

## Keyboard

Escape closes the detail panel, and that is the board's only key: `mod.json` declares
`"focusable": true`, the view takes a focus handle, and `on_key_down` handles Escape.
Opening a task focuses the board, so Escape reaches it straight away.
Reaching the board with `pane.go` is the app's own navigation and works because of that opt-in.
Everything else - the view toggle, the sort control, a card - is pointer-only: there are no arrow
keys, no shortcuts, and no focus ring.
The app's UI layer exposes no roles or labels to a mod either, so there is no screen-reader story to
claim here.

## No lifecycle action

The board can only show and focus.
It runs no `sq-tasks` write verb (only the read-only `sq-tasks show`), no `sq-spawn`, no `sq-teardown`, no `hc` write, no `push`, and no merge: its only app command is `agent.focus`, and the only programs it runs are `bin/sq-board.sh` and `sq-tasks show`.
Dispatching, cleaning up, and merging stay Squad's, exactly as before this mod existed.

## Removing it

Close the board tab first, with `herdr-app do tab.close --id <tab-id>`: a board tab still open on a removed folder makes `herdr-app status` report the missing mod until that tab closes.
Then remove the install:

```sh
herdr-mods/squad-board/install.sh --uninstall
```

That removes the copy or the link it created, plus the two editor files the app regenerates beside a copy, and nothing else.
If the folder holds any other file, or has no install marker, the script refuses and names the manual removal: delete `mods/squad-board` by hand, which removes the same files.
Deleting `mods/squad-board` by hand has the same effect; no layout, key binding, or app setting was ever changed, so nothing else needs undoing.
The app's shared state keeps the `board.view` and `board.sort` values the board last wrote: nothing reads them once the mod is gone and the app leaves them in place, so removal is not literally traceless, but it is harmless.

## Evidence

This folder was validated with `herdr-app check herdr-mods/squad-board` (it loads and renders the empty board without reading anything) and with `tests/sq-board-mod-thin.test.sh`, which runs the unmodified `main.js` against stub `herdr`, `gpui-kit` and `gpui-base` modules and checks the board-to-card mapping, the click join, the two views, the three text states, the read budget, and the recorded read-only proof above.
It was not installed into a real app home by the change that added it, so no capture of it in a live window exists yet; the shape it follows was measured earlier with a probe mod.
