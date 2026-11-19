# Decision Card Pi Recipe (Optional)

How a Pi session can present a decision card as a native dialog without changing the decision format Squad owns.
The card schema has one owner, [decision-card-standard.md](decision-card-standard.md), and the prose block stays the canonical shape the commander reads and answers.
A native dialog is a presentation surface: it is optional, it never becomes the owner of the format, and every path here degrades to today's prose block when the extension is absent.

## The extension

`@juicesharp/rpiv-ask-user-question` is a Pi extension that exposes one tool, `ask_user_question`, and renders its payload as a native terminal dialog.
It is never a runtime dependency of Squad: nothing in `bin/`, the tests, or CI imports it, requires it, or installs it.

Its published payload (`docs/tool-schema.md` in the package, verified against version 2.15.0) is:

```ts
ask_user_question({
  questions: [{
    question: string,        // full question text
    header: string,          // chip label, max 16 characters
    options: [{ label: string, description: string, preview?: string }], // 2-4 options
    multiSelect?: boolean,   // default false
  }],                        // 1-4 questions per dialog
})
```

Two facts drive the mapping:

- There is no per-question `notes` field, so card context and findings travel inside the question text rather than being dropped.
- The dialog appends its own free-text row (`Type something.`), so `O0 - Your own words` stays reachable without authoring an option for it.
  The labels `Other`, `Type something.`, and `Next` are reserved and rejected, which is why a card using one of them keeps the prose block.
  That row cannot widen a card's own rule: a card with `allow_free_text: false` still shows it, and a typed answer is rejected by `bin/sq-ask.sh --answer` because the card, not the dialog, decides what it accepts.

## The offer

`bin/sq-bootstrap.sh` offers the extension to a Pi primary (`pi`, `pi-signed`) only, as one line in the session-start digest:

- installed: `BOOTSTRAP_INFO: pi extension @juicesharp/rpiv-ask-user-question installed`.
- absent: `OPTIONAL: pi extension @juicesharp/rpiv-ask-user-question not installed (offer: pi install npm:@juicesharp/rpiv-ask-user-question, then start a fresh pi session)`.

`OPTIONAL` is an offer, not a missing required tool: it never routes through the required-tool install consent path, and it never blocks dispatch.
`.agents/skills/bootstrap-diagnostics` owns how that line is handled.
Installing is the commander's explicit action.
Bootstrap reads `pi list` and nothing else: it never installs, never updates, stays silent on every other harness, and stays silent when `pi` is not on `PATH`.
Detection parses only the `User packages:` section of `pi list` and stops at `Project packages:`, so it covers exactly the user-scope install `pi install` writes; a project-scope install (`.pi/settings.json`, trust-gated) is out of scope and therefore reads as absent, never as installed, and a failed or unreadable listing is reported as nothing rather than as absence.
`SQUAD_PI_ASK_USER_OFFER=0` silences the offer for a base that does not want it.

## The mapping

`bin/sq-card-pi-dialog.sh` converts a card payload (one card object or an array) into the dialog payload and back.
It validates the card through `bin/sq-ask.sh --validate` first, so the schema keeps exactly one owner, and it needs neither `pi` nor the extension at runtime.

| Card | Dialog |
|------|--------|
| `question` | `questions[].question`, then one `F<n> - <id> <text>` line per finding and finally one `Context: <context>` line, on the first question of the card |
| `title` | `questions[].header`, cut to the 16-character limit at the last space of the retained text when it keeps one, otherwise at the limit; a split question's `k/n` marker counts inside the 16 |
| `options[].label` | `options[].label`, unchanged |
| `options[].description` | `options[].description`; the recommended option gains a trailing ` (recommended)` so the recommendation is visible on its own row |
| `allow_free_text` | not authored: the dialog's own free-text row is the `O0` escape |
| `payload`, option ids, metadata | not shown |

Splits replace truncation, because a dialog holds 1-4 questions and a question 2-4 options:

- more than four options on a card become several questions, balanced and in card order (5 -> 3+2, 6 -> 3+3, 9 -> 3+3+3), each numbered `(part k of n)` and `k/n` inside the header;
- more than four questions on a card become several dialogs, each one `ask_user_question` call;
- several cards in one reply become one dialog per card, in card order.

A card the dialog cannot represent without dropping or misrepresenting an option keeps the prose block instead, and the mapping exits 2 naming the reason: a reserved dialog label, a label shared by two options of the card, or a card with a single option.

## Answers

The dialog result is the published version 2.15.0 shape, whose field names are owned by the package's `docs/tool-schema.md` "Result" section: `details.answers[]` entries carry `questionIndex`, `question`, `kind`, and `answer`, with the optional `notes`, `selected`, and `preview`, and the result carries `details.cancelled`.
The mapping reads `questionIndex`, `kind`, and `answer` from each entry plus `details.cancelled` from the result, one entry per question with a `kind` and the chosen label or typed text.
It turns that back into the prose answer grammar, so the existing parser stays the only resolver:

```bash
bin/sq-card-pi-dialog.sh --payload < card.json
# one ask_user_question call per element of the printed array
bin/sq-card-pi-dialog.sh --answer --dialog 1 --result '<tool result json>' < card.json
# a card that needed two dialogs merges in one call, one fragment per decision:
bin/sq-card-pi-dialog.sh --answer --dialog 1 --result '<first>' --dialog 2 --result '<second>' < card.json
# -> "d1 o2", then:
bin/sq-ask.sh --answer 'd1 o2' < card.json
```

`--answer` needs the card the dialog came from, because an answer is always resolved against the JSON card and never against the text the commander saw.
It takes the whole tool result and never a bare answers array: only `details.cancelled` proves the dialog was not cancelled, so `Esc` can never become a recorded decision.
A split card keeps the card's own global option numbering across dialogs, so an option picked in the last dialog is still the card's real code and `d1 o15` stays valid.
The merge is mechanical - no fold, no renumbering, no guessed pick - and yields exactly one fragment per decision.
Two answers for the same decision, whether across the questions of one dialog or across two dialogs, exit 4 with a named error instead of choosing one, and a multi-select answer exits 4 because this mapping never authors a multi-select question.

## Fallback

With the extension absent, nothing changes:

- `bin/sq-ask.sh --render` prints the same prose block it always printed;
- `bin/sq-ask.sh --answer` resolves the typed answer exactly as before;
- the mapping script is never invoked by any existing decision path and has no runtime dependency of its own.

## Files

| File | Purpose |
|------|---------|
| `bin/sq-card-pi-dialog.sh` | Card to dialog payload, and dialog answers back to the prose answer text |
| `bin/sq-bootstrap.sh` | The Pi-only offer, including the exact install command |
| `tests/sq-card-pi-dialog.test.sh` | Mapping, split, refusal, round-trip, and fallback cases |
| `tests/sq-bootstrap.test.sh` | The offer: Pi only, exact command, never installs, silent elsewhere |
