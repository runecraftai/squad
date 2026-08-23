# Decision Card Text Format

The canonical textual rendering of a decision card for keyed-decision workflows.
Reserved for drill ask-user findings and pipeline-gated decisions that need explicit option sets.
For general multi-item responses, use the reference code format defined in `AGENTS.md` section 9.

## Chat/Card Format

This format is used when presenting decisions to the commander in chat or terminal:

```
━━━ DECISION: {title} ━━━
{question}

{context paragraph, if present}

Options:
  1. {label} - {description}  ← recommended
  2. {label} - {description}
  3. {label} - {description}

Your call [{default_label}]: _
```

### Rules

1. **Title line**: Always starts with `━━━ DECISION:` and ends with `━━━`
2. **Question**: On its own line, no prefix
3. **Context**: Optional, blank line before and after
4. **Options header**: Always `Options:` on its own line
5. **Option numbering**: 1-indexed, each on its own line with 2-space indent
6. **Recommended marker**: `  ← recommended` appended to the recommended option
7. **Free text hint**: If `allow_free_text: true`, add after options:
   `  0. Type something (free text)`
8. **Your call line**: Always ends with the default option label in brackets
9. **Terminal cursor**: `_` at end to indicate input expected

## Status Line Format

For appending to `state/<id>.status` files:

```
needs-decision [key={key}]: {title} | options: {label1}|{label2}|{label3} | default: {default_label}
```

### Status Line Rules

1. Uses the existing `needs-decision [key=<slug>]:` prefix
2. Title follows the colon
3. Options are pipe-separated after `options:`
4. Default label follows `default:`
5. Keep under 200 characters total

### Example Status Line

```
needs-decision [key=merge-strategy]: Merge Strategy | options: Squash|Rebase|Merge-commit | default: Squash
```

## Inline Chat Format

For quick inline decisions in chat (when full card is too verbose):

```
[{title}] {question}? Options: {label1}, {label2}, {label3} [default: {default_label}]
```

### Example Inline

```
[Merge Strategy] How to merge PR #42? Options: Squash, Rebase, Merge-commit [default: Squash]
```

## JSON Output (from picker)

The picker tool outputs the selected option as JSON:

```json
{
  "decision_id": "<card id>",
  "selected_option_id": "<option id>",
  "selected_label": "<option label>",
  "free_text": null,
  "method": "picker"
}
```

When free text is entered:

```json
{
  "decision_id": "<card id>",
  "selected_option_id": null,
  "selected_label": null,
  "free_text": "user's custom input",
  "method": "free_text"
}
```

## Integration with sq-send

When answering a decision card through sq-send:

```bash
sq-send.sh <target> --resolve-key <key> "answer: squash"
```

The answer format is:
- Option selection: `answer: <option_label>`
- Free text: `answer: <custom_text>`

This allows sq-send's --resolve-key to close the decision in the status ledger.
