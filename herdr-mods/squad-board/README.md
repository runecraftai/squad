# squad-board - Squad's missions as cards, in the Herdr app

A Herdr mod that draws Squad's own mission board as cards: one card per mission, three sections with their real counts, a list view and a kanban view, and a click that shows the mission's agent.
It is a read-only view.
It opens as its own tab and closes like any tab, and it never docks a copy into anyone's layout on its own (`"place": "none"` in `mod.json`).

## Install

The app loads a mod by name from its own mods folder, so the folder has to live at `${HERDR_APP_HOME:-$HOME/.config/herdr-app}/mods/squad-board`.

```sh
herdr-mods/squad-board/install.sh          # copy main.js and mod.json there
herdr-mods/squad-board/install.sh --link   # or link the folder, so edits here reload live
```

`--link` is untested on herdr-app 0.1.18: prefer `--copy` unless you are changing the mod and want the app's own hot reload.
The script is idempotent, touches only `mods/squad-board`, and proves ownership with a marker file, `.squad-board-install`, that it writes last so an interrupted copy carries none.
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

The pane opens at 280 px, which is the shipped panel minimum, and `mod.json` declares that as `"min_w": 280`; the app itself does not read that key, it sizes panes from the layout block's `min`, so the declaration is for readers and for this mod's own checks.
The layout itself sets no such floor: the card layout stays readable down to 200 px, where the mission title wraps instead of being cut, the header keeps `Lista`/`Kanban` reachable, and its read line wraps onto its own row.

## What it draws

- `EM VOO`, `FILA` and `EM ESPERA`, one section per board state, each with the count the board reported.
- One card per mission: the status dot, the whole mission title, the elapsed time, then `kind · repo · state`.
  A mission whose title is long wraps onto more lines rather than being truncated.
- `Lista` and `Kanban` in the header.
  Kanban draws the same three sections as equal-width columns that divide the pane at full width; every title wraps inside its own card, and the row only scrolls sideways when the pane is narrower than three 200 px columns.
  The choice is stored through the app's `shared()` as `board.view`, so it survives a restart.
- Loading (`lendo o board…`), empty (`nenhuma missão em voo`, `nada na fila`, `nada em espera`) and a failed read are drawn as text, so the pane is never a blank board; the last good cards stay under the error line.

Clicking a card runs `agent.focus` for that mission's terminal, taken from the board's own `window` field (`default:t1k` means terminal `t1k`), but only when the row's `backend` is `herdr-core` and that terminal is still in the app's `agents()` list.
A mission with no recorded window, a mission recorded on tmux or zellij (whose `window` is `session:window`, not an app terminal id), or a herdr-core mission whose terminal has ended is not clickable at all: a core recycles a closed terminal's address, and two rows can record the same `session:address`, so a recorded window alone could open a dead terminal or another mission's.

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

The header shows the last read's own measured milliseconds and item count, for example `[16312ms · 340]`.

## Keyboard

The surface is **pointer-only**.
`mod.json` does not declare `"focusable": true` and the mod has no `on_key_down` handler, so the view toggle and the cards are reached with the mouse or trackpad.
The app's UI layer exposes no roles or labels to a mod either, so there is no screen-reader story to claim here.

## No lifecycle action

The board can only show and focus.
It contains no `sq-tasks`, no `sq-spawn`, no `sq-teardown`, no `hc` write, no `push`, and no merge: its only app command is `agent.focus`, and the only program it runs is `bin/sq-board.sh`.
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
The app's shared state keeps the `board.view` value the board last wrote: nothing reads it once the mod is gone and the app leaves it in place, so removal is not literally traceless, but it is harmless.

## Evidence

This folder was validated with `herdr-app check herdr-mods/squad-board` (it loads and renders the empty board without reading anything) and with `tests/sq-board-mod-thin.test.sh`, which runs the unmodified `main.js` against stub `herdr`, `gpui-kit` and `gpui-base` modules and checks the board-to-card mapping, the click join, the two views, the three text states and the read budget.
It was not installed into a real app home by the change that added it, so no capture of it in a live window exists yet; the shape it follows was measured earlier with a probe mod.
