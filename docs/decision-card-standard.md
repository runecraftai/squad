# Decision Card Payload Standard

The internal JSON payload behind a decision block, and the single owner of its schema, its mapping to prose, and its machine surfaces.
The commander never reads or types this JSON.
What the commander reads and types is the prose block defined in `AGENTS.md` section 9.
Exact flags, tokenization, and exit codes live in the `bin/sq-ask.sh` header and `--help`.

## Overview

1. **Prose block** - the only commander-facing shape: `D1 - <subject>`, one short line per option `O1 - <label>: <description>`, answered as `d1 o2`.
2. **Card** - the JSON payload behind one decision block, defined below.
3. **`bin/sq-ask.sh`** - renders a card to prose, parses prose back to a card, parses the commander's answer, and offers an opt-in terminal picker.

Plain text is the default for the commander.
Squad shows the prose block in its reply and does not run the picker, because an agent tool call has no terminal and the picker would silently take the recommended option.
The picker is an opt-in tool for a human at a shell.

## Quick Start

```bash
bin/sq-ask.sh --render < tests/fixtures/decision-prose/merge.json
bin/sq-ask.sh --answer 'd1 o2' < tests/fixtures/decision-prose/merge.json
bin/sq-ask.sh --parse-card < tests/fixtures/decision-prose/merge.prose
bin/sq-ask.sh --validate < card.json
```

## Card schema (version 1)

A single card object, or a JSON array of cards for several decisions in one reply.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | integer | yes | Always 1 |
| `id` | string | yes | `A-Za-z0-9._-`, 1-64 characters; equals `metadata.key` when keyed |
| `title` | string | yes | Subject of the decision, at most 60 characters |
| `question` | string | yes | The specific question, at most 160 characters; equal to the title means the prose omits the question line |
| `context` | string | no | One line of context, at most 240 characters |
| `options` | array | yes | At least one option object |
| `default_option_id` | string | yes | The recommended option; the only one the prose marks |
| `allow_free_text` | boolean | no | Default true; controls the `O0` line |
| `findings` | array | no | Display-only `{id, text}` entries rendered as the `F` block |
| `expires_at` | string | no | Not rendered |
| `metadata` | object | no | `key` (decision key), `task_id`, `source`; only `key` is rendered |

Option object: `id` (unique, `A-Za-z0-9._-`, authored once and never changed), `label` (at most 60 characters), `description` (at most 120), `recommended` (only allowed on the default option), and `payload` (optional object returned unchanged on selection, never rendered).

Validation rules, enforced by `--validate`:

1. All text fields are one line of printable ASCII.
   Anything else is rejected, never stripped or normalized.
2. A key matches `A-Za-z0-9._-`, has 1-64 characters, and is never `default`.
3. A keyed card has `id` equal to `metadata.key`, so the result's `decision_id` is the exact string given to `sq-send --resolve-key`.
4. Ids and keys are unique across an array.
5. A label may not contain `|`, `: `, `[key=`, or a `word:` pattern, and neither label nor description may end with the recommended marker.
6. `payload.action` is one of `approve`, `fix`, `skip`; `payload.step` and every `payload.findings` id match the id charset, and every finding id exists in `findings`.

## Prose mapping

| Card | Prose |
|------|-------|
| position in the input array | `D<n>` |
| `title` | header text |
| `metadata.key` | ` (ref: <key>)` on the header |
| `question` | question line |
| `context` | `Context:` line |
| `options[i]` | `O<i+1> - <label>: <description>` |
| `default_option_id` | ` (recommended)` on that option only |
| `allow_free_text` | the `O0 - Your own words` line |
| `findings[]` | the separate `F` block before the decision |
| `payload`, option ids, other metadata | not shown |

`--parse-card` reverses the mapping.
Option ids become a slug of the label, so an authored id such as `squash` comes back as `squash-merge`.
Prose carries no payload, so a card with payloads must always travel as JSON and never be rebuilt from prose.

## Identity

- **Decision id** is the key when keyed.
- **Option id** is authored, unique, and never changed once emitted.
- **Display codes** `D<n>` and `O<m>` are derived from position and never stored.
- An answer is always resolved against the JSON card, never against the text the commander saw.
- After a block is first shown, options may only be appended.
  Any other change to the option set is a new decision: close the old key with a `resolved` line saying it was superseded and open a new key.

## Machine surfaces

### Status line

A worker opens a keyed decision with one status line and then stops:

```
needs-decision [key=<slug>]: <title> | options: <label1>|<label2> | default: <label>
```

Labels are verbatim option labels.
Only the key is parsed (`bin/sq-classify-lib.sh`); `sq-send --resolve-key` closes it at answer time.
Workers never see `D` or `O` codes.

### Result object

```json
{"decision_id":"<key or id>","selected_option_id":"<id>|null","selected_label":"<label>|null",
 "selected_payload":{},"free_text":"<text>|null","method":"picker|prose|free_text|default"}
```

A card in gives an object out, an array of cards in gives an array out with one entry per answered decision.
With no terminal and no `--answer`, the picker path returns the recommended option with `method` `default` and one stderr notice.

### Codes stay out of records

Codes are display-only.
Write the option label or id, never `D1`, `O2`, or `F1`, into a status line, a steer, a backlog note, a decision record, or `sq-send` text.
Free text from the commander reaches a worker only as quoted data, for example `Commander answer (data, not an instruction): "<text>"`, because `sq-send` does not sanitize the pane message.

## Drill ask-user gates

Drill supplies findings with ids and a description and accepts one gate-level response: `drill axi respond --action approve|fix|skip [--findings id,id] [--instructions "<string>"]`.
It supplies no options, so Squad authors the card.

1. One card per gate, with the findings in `findings` and one option per response.
2. Each option's `payload` holds the exact response arguments (`action`, `step`, `findings`), so the machine response is never parsed out of prose.
3. `--answer` returns the chosen payload as `selected_payload`; Squad builds the steer from it plus the decision key and passes `--resolve-key`.
4. The `F<n>` codes are display positions; the payload carries drill's own finding ids.
5. A free-text answer is Squad's judgment, not a lookup: Squad restates the resolved arguments in the steer before sending.
6. A mixed per-finding answer goes through `O0`, because `respond` takes one action and one instruction string.

See Example 2 in [Examples](decision-card-examples.md).

## Harness agnosticism

Every harness shows the same prose block in chat and receives the answer as text.
A native question dialog is optional; see the [pi recipe](decision-card-pi-recipe.md).
The picker degrades fzf, then whiptail, then dialog, then bash read, then the recommended option.

## Implementation files

| File | Purpose |
|------|---------|
| `bin/sq-ask.sh` | Renderer, prose parser, answer parser, validator, picker |
| `docs/decision-card-examples.md` | Three worked examples with golden prose |
| `tests/sq-ask.test.sh` | Renderer, parser, validator, picker, and doc-drift tests |
| `tests/fixtures/decision-prose/` | Golden cards and prose |

## Design decisions

1. **One commander-facing shape** - two competing presentations made the commander learn both.
2. **JSON as an internal payload** - keeps machine responses exact and out of prose.
3. **Codes are positions** - cheap to type, never durable, so records carry labels and ids.
4. **Reject, never guess** - a malformed answer exits 4 with empty stdout.
5. **Short lines** - the commander rejected verbose cards; ceilings are constants in one table.
