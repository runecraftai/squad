---
name: figcraft-operations
description: Operate a .figcraft design document: inspect, create, edit, convert, export, render, and link design components to code through figcraft-cli or its MCP server. Use when the work touches the design file itself; not for judging a design or writing an implementation spec.
user-invocable: false
metadata:
  internal: true
---

# figcraft-operations

Use this skill when a task produces, edits, inspects, or exports a `.figcraft` design document.
The document is drawn by code: a generator script emits every page, frame, text, and icon, and `figcraft-cli` compiles it.
This records the loop a real design station used to build a 5 MB document of 11 pages, 54 vector icons, and 12 rail entries at 44-unit pitch.

## The loop that worked

Run these steps in order, and treat every correction as another pass through them.

1. Write a Python generator that emits the whole document from real data: captured screens, measurements read from the product's real theme manifest, and icon lists.
   Do not draw inside the app; the script is the source of truth for every node it creates.
2. Compile the script: `figcraft-cli run SCRIPT.json --in FILE --out FILE`.
   The script is a JSON array (or JSON lines) of `{"command": id, "params": {...}}` and runs as one all-or-nothing undo step.
3. Look at it: `figcraft-cli render FILE -o out.png --scale 0.3` for the overview.
   Crop that PNG, or render again at `--scale 1`, when you need to check alignment at detail.
4. Export the frames to hand over: `figcraft-cli export FILE --page "<page name>" --out renders --scale 1`.
5. Fix the generator and repeat from step 2.
   Never patch the document by hand between passes, because the next compile overwrites the hand edit.

## Verbs and flags observed in production

| Verb | Shape | Use it for |
| --- | --- | --- |
| `info` | `info FILE [--json]` | The cheap audit: pages, node counts, top-level frames, and style, variable, and image counts, without rendering. `--json` when the numbers must be parsed. |
| `export` | `export FILE --out OUT --scale N [--page NAME] [--node ID\|NAME]` | One file per top-level frame of the page. `--page` selects the page and defaults to the first, while a file-shaped `OUT` with an image extension or `--node` writes one file. |
| `render` | `render FILE -o out.png --scale N [--page NAME]` | The whole page with its background, as png, jpg, or webp. |
| `convert` | `convert IN OUT` | Format from the output extension: `.figcraft`, `.json`, `.svg`, `.png`, `.jpg`, `.webp`, `.pdf`, `.fig`, `.penpot`. |
| `run` | `run SCRIPT.json --in FILE --out FILE` | Compiles a command script into the document. This is the engine of the loop above. |
| `commands` | `commands [--json] [--filter TEXT]` | Discovery: every command with its label, shortcut, undoable flag, and parameters. A full listing was 645 commands. |
| `--no-system-fonts` | global flag | Lay text out with FigCraft's built-in fonts only, so a render matches on every machine. |

Scale practice: `0.22` to `0.35` gives the overview of a page carrying dozens of frames, and `1` gives the detail you can measure.

## Pitfalls

- **The friction was the generator, not the CLI.** Every CLI call answered well; the failures were Python syntax errors inside the script.
  Validate the script's syntax before rendering, so a generator bug never reads as a rendering bug.
- **`export` defaults to the first page.** Without `--page` it writes one file per top-level frame of the first page only, so a multi-page document needs `--page` named explicitly for every page you deliver, and a single image needs a file-shaped `<OUT>` with an image extension or `--node` rather than a folder.
- **`render` without an explicit `--scale`** costs time and writes a huge PNG. Always pass the scale.
- **`info` is the cheap audit.** It answers counts without rendering, so render only to judge composition.
- **Fonts are not deterministic without `--no-system-fonts`**, because otherwise installed fonts are indexed the first time text is laid out.

## Capability boundary

`mcp` and `connect` exist, and the harvest never used either in production.
Treat them as available and unverified, never as a proven path.

- `mcp` serves MCP on stdio: headless with `--automation-read-root` and `--automation-write-root`, or attached to a running app through `--attach PORT` when that app was started with `figcraft --control PORT`.
- `connect publish FILE --mappings figcraft.connect.json` links a design file's components to their code and saves the file. `--dry-run` reports what would be linked without saving.

An unverified tool must not be announced as done.
If you use `mcp` or `connect`, show the verified result in the same turn, or report the attempt as unverified.
