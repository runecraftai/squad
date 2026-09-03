# pi-tui-unified

A public Pi package that unifies theme-driven diff and tool rendering while making user and agent messages easy to scan.

## Install

```bash
pi install npm:pi-tui-unified
```

Try it without installing:

```bash
pi -e npm:pi-tui-unified
```

## Included

- `edit` previews render as a responsive split diff with syntax highlighting and word-level emphasis.
- `write` previews render as a compact unified diff.
- `read` output includes syntax highlighting and line numbers.
- `bash` output shows theme-colored success or error status and expanded output when requested.
- `ls` output uses Nerd Font file and directory icons.
- User messages and agent replies receive distinct theme-derived Markdown labels.
- The working indicator uses a theme-derived shimmer.
- Built-in tool execution is delegated to Pi unchanged; this package only replaces presentation.

All colors come from the active Pi theme. No global color palette or manual color configuration is required.

## Compatibility

The package uses only Pi's public extension and TUI APIs. It does not register new tools or commands, so it leaves extension-owned names such as `turnend-guard`, `pi-watch`, and `calm` available. Rendering is width-aware and uses no terminal-specific passthrough sequences, so it works in tmux with passthrough disabled and in narrow/mobile terminals.

## Development

```bash
npm install
npm run check
npm run pack:check
```

The package declares Pi SDK packages as peer dependencies so the host's versions are used at runtime.
