# Decision Card Standard

A harness-agnostic standard for presenting commander decisions in Squad.
Ensures every decision arrives as a structured card with typed options, an explicit default, and a recommendation.

## Overview

The decision card standard defines:

1. **Schema** - Machine-readable JSON format for decision cards
2. **Text Format** - Canonical rendering for chat and terminal display
3. **Picker Tool** - Interactive terminal picker any harness can invoke
4. **Integration Points** - How cards flow through Squad's decision surfaces

## Quick Start

### Render a Decision Card

```bash
echo '{"version":1,"id":"test","title":"Test","question":"Pick one?","options":[{"id":"a","label":"Option A"},{"id":"b","label":"Option B"}],"default_option_id":"a"}' | bin/sq-ask.sh --render
```

### Validate a Decision Card

```bash
cat card.json | bin/sq-ask.sh --validate
```

### Interactive Picker (non-interactive uses default)

```bash
cat card.json | bin/sq-ask.sh --format id
```

## Documentation

- [Schema Reference](decision-card-schema.md) - JSON schema and validation rules
- [Text Format](decision-card-format.md) - Canonical rendering specifications
- [Examples](decision-card-examples.md) - Three real-world decision examples

## Integration with Squad Decision Surfaces

### 1. Status Lines (state/<id>.status)

When a worker needs a decision, append a status line following the keyed-decision format:

```
needs-decision [key=<slug>]: <title> | options: <label1>|<label2>|<label3> | default: <default_label>
```

This integrates with the existing decision lifecycle:
- `sq-classify-lib.sh` recognizes `needs-decision [key=<slug>]:` as opening a keyed decision
- `sq-send.sh --resolve-key` closes the decision at answer time
- `decision-hold-lifecycle` manages durable backlog holds for unresolved decisions

### 2. Commander Chat Presentations

When presenting decisions to the commander in chat, use the card format:

```
━━━ DECISION: <title> ━━━
<question>

<context>

Options:
  1. <label> - <description>  ← recommended
  2. <label> - <description>
  3. <label> - <description>

Your call [<default_label>]: _
```

### 3. Drill Ask-User Findings

When drill surfaces an ask-user finding, present it as a decision card:

1. Include the decision card JSON in the finding
2. Render using `sq-ask.sh --render` for chat
3. Commander answers through normal flow
4. Answer fed back via `drill axi respond`

The drill pipeline handles the mechanics; this standard defines the presentation format.

## Harness Agnosticism

The decision card standard works across all Squad harnesses:

- **pi**: Can use the rpiv extension for native interactive dialogs, or fall back to sq-ask.sh
- **claude**: Renders cards in chat, commander answers via text
- **codex**: Same as claude - renders and receives answers as text
- **opencode**: Same as claude/codex
- **grok**: Same as claude/codex/opencode

The picker tool (`sq-ask.sh`) detects available terminal tools and degrades gracefully:
- fzf (preferred) → whiptail → dialog → bash read → default (non-interactive)

## Implementation Files

| File | Purpose |
|------|---------|
| `bin/sq-ask.sh` | Interactive picker tool |
| `docs/decision-card-schema.md` | JSON schema reference |
| `docs/decision-card-format.md` | Text format specifications |
| `docs/decision-card-examples.md` | Real-world examples |
| `docs/decision-card-standard.md` | This file - overview and integration |
| `tests/sq-ask.test.sh` | Validation and rendering tests |

## Backward Compatibility

This standard is additive and does not break existing decision flows:

- Existing `needs-decision: <summary>` lines without options still work
- Existing `resolved [key=<slug>]:` closure still works
- The card format is a presentation layer on top of existing semantics
- `sq-classify-lib.sh` key parsing is unchanged

## Design Decisions

1. **JSON schema for machine readability** - Enables tooling, validation, and future automation
2. **Text format for human readability** - Consistent, terse, ends with clear "your call" prompt
3. **Always allow free text** - Preserves commander flexibility; never locks into authored options only
4. **Default option always visible** - Makes the recommendation explicit, reduces cognitive load
5. **Harness-agnostic picker** - Works from any shell, degrades gracefully, no harness-specific bindings
6. **Integrate with existing lifecycle** - Uses sq-send --resolve-key, decision-hold-lifecycle, sq-classify-lib.sh

## Future Extensions (Out of Scope)

These are noted for completeness but not part of this standard:

- **pi native dialog** - The rpiv extension can provide richer interactive UX for pi sessions
- **Web UI picker** - A browser-based picker for non-terminal environments
- **Decision history** - Tracking decision patterns over time
- **Auto-expiry** - Automatic resolution when cards expire
