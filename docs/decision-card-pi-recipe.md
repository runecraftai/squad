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
- absent: `MISSING: pi extension @juicesharp/rpiv-ask-user-question (install: pi install npm:@juicesharp/rpiv-ask-user-question, then start a fresh pi session)`.

Installing is the commander's explicit action.
Bootstrap reads `pi list` and nothing else: it never installs, never updates, stays silent on every other harness, and stays silent when `pi` is not on `PATH`.
`SQUAD_PI_ASK_USER_OFFER=0` silences the offer for a base that does not want it.

## The mapping

`bin/sq-card-pi-dialog.sh` converts a card payload (one card object or an array) into the dialog payload and back.
It validates the card through `bin/sq-ask.sh --validate` first, so the schema keeps exactly one owner, and it needs neither `pi` nor the extension at runtime.

| Card | Dialog |
|------|--------|
| `question` | `questions[].question`, then one `Context: <context>` line and one `F<n> - <id> <text>` line per finding, on the first question of the card |
| `title` | `questions[].header`, cut to the 16-character limit at a word boundary |
| `options[].label` | `options[].label`, unchanged |
| `options[].description` | `options[].description`; the recommended option gains a trailing ` (recommended)` so the recommendation is visible on its own row |
| `allow_free_text` | not authored: the dialog's own free-text row is the `O0` escape |
| `payload`, option ids, metadata | not shown |

Splits replace truncation, because a dialog holds 1-4 questions and a question 2-4 options:

- more than four options on a card become several questions, balanced and in card order (5 -> 3+2, 6 -> 3+3, 9 -> 3+3+3), each numbered `(part k of n)` and `k/n` inside the header;
- more than four questions on a card become several dialogs, each one `ask_user_question` call;
- several cards in one reply become one dialog per card, in card order.

A card the dialog cannot represent without dropping or misrepresenting an option keeps the prose block instead, and the mapping exits 2 naming the reason: a reserved dialog label, a label shared by two options of one dialog question, or a card with a single option.

## Answers

The dialog's answers come back as `details.answers`, one entry per question with a `kind` and the chosen label or typed text.
The mapping turns that back into the prose answer grammar, so the existing parser stays the only resolver:

```bash
bin/sq-card-pi-dialog.sh --payload < card.json
# one ask_user_question call per element of the printed array
bin/sq-card-pi-dialog.sh --answer --dialog 1 --result '<tool result json>' < card.json
# -> "d1 o2", then:
bin/sq-ask.sh --answer 'd1 o2' < card.json
```

`--answer` needs the card the dialog came from, because an answer is always resolved against the JSON card and never against the text the commander saw.
A card split across questions of one dialog can be answered once; two answers for the same card exit 4 instead of guessing, and a multi-select answer exits 4 because this mapping never authors a multi-select question.

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
