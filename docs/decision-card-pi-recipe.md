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
  The built-in row cannot be hidden, so `--payload` refuses a card with `allow_free_text: false` with exit 2 and a named reason, without emitting a payload; use the canonical prose block instead.

## The offer

`bin/sq-bootstrap.sh` offers the extension to a Pi primary (`pi`, `pi-signed`) only, as one line in the session-start digest:

- installed: `BOOTSTRAP_INFO: pi extension @juicesharp/rpiv-ask-user-question installed`.
- absent: `OPTIONAL: pi extension @juicesharp/rpiv-ask-user-question not installed (offer: pi install npm:@juicesharp/rpiv-ask-user-question, then start a fresh pi session)`.

`OPTIONAL` is an offer, not a missing required tool: it never routes through the required-tool install consent path, and it never blocks dispatch.
`.agents/skills/bootstrap-diagnostics` owns how that line is handled.
Installing is the commander's explicit action.
Bootstrap reads the user-scope `settings.json` in `PI_CODING_AGENT_DIR` (default `~/.pi/agent`) without starting Pi or invoking a package manager. It checks for the exact npm source and its module directory under that same agent directory's `npm/node_modules`. It never reads project settings. A missing source or missing module directory produces the offer; unreadable or malformed settings leave it silent.
The source can be unsuffixed or use an `@` suffix with an exact version triple (such as `2.15.0`, with optional prerelease and build metadata) or a plain dist-tag (letters, digits, dots, dashes, and underscores, starting with a letter or digit). Range suffixes are inconclusive: bootstrap stays silent even if the extension is installed, so follow the install line above when setting up the extension.
Bootstrap also stays silent when `pi` is not on `PATH` or the harness is detected as non-Pi. An inherited `PI_CODING_AGENT=true` marker can cause a non-Pi session to be detected as Pi and see the offer.
The shared timeout helper's Perl fallback can lose the child's signal status, but a probe that does not emit a recognized result stays silent.
`SQUAD_PI_ASK_USER_OFFER=0` silences the offer for a base that does not want it.

## The mapping

`bin/sq-card-pi-dialog.sh` converts a card payload (one card object or an array) into the dialog payload and back.
It validates the card through `bin/sq-ask.sh --validate` first, so the schema keeps exactly one owner, and it needs neither `pi` nor the extension at runtime.

| Card | Dialog |
|------|--------|
| `question` | `questions[].question`, then one `F<n> - <id> <text>` line per finding and finally one `Context: <context>` line when the card has context |
| `title` | `questions[].header`, with leading whitespace removed before cutting to the 16-character limit at a word boundary when possible |
| `options[].label` | `options[].label`, unchanged |
| `options[].description` | `options[].description`; the recommended option gains a trailing ` (recommended)` so the recommendation is visible on its own row |
| `allow_free_text` | not authored: the dialog's own free-text row is the `O0` escape |
| `payload`, option ids, metadata | not shown |

One card is one dialog question, because a question holds 2-4 options:

- an eligible card with 2-4 options becomes exactly one `ask_user_question` question, with every option on its own row and the recommended one marked;
- several cards in one reply become one dialog per card, in card order, each rendered as its own `ask_user_question` call;
- a card with more than four options keeps the prose block: the mapping exits 2 naming the reason, so no option is ever dropped, folded, or truncated.

A split mapping is not used for the payload path: the extension answers one entry per question, so a card spread over two or more questions would come back as several answers for the same decision and could only be recorded by guessing a pick.
Refusing the card keeps the prose block authoritative for exactly the cards that need more than one question, instead of leaving them with a dialog whose answer cannot be merged.

A card the dialog cannot represent without dropping or misrepresenting an option keeps the prose block instead, and the mapping exits 2 naming the reason: a reserved dialog label, a label shared by two options of the card, a card with a single option, a card with more than four options, any missing, null, or blank option description, or any option label or description ending in `(recommended)` after trimming trailing whitespace, including on the recommended option itself. The marker check is lowercase-only; a lookalike such as `(Recommended)` still renders and is not rejected.

The dialog heading (question, findings, context, and snapshot line) is limited to 6 lines and 600 characters including line breaks. A heading over either limit is refused with exit 2 (`dialog heading exceeds`); use the prose block instead.

## Answers

The dialog result is the published version 2.15.0 shape, whose field names are owned by the package's `docs/tool-schema.md` "Result" section: `details.answers[]` entries carry `questionIndex`, `question`, `kind`, and `answer`, with the optional `notes`, `selected`, and `preview`, and the result carries `details.cancelled`.
The mapping checks `questionIndex` and the returned `question` against the dialog addressed by `--dialog` before resolving `kind` and `answer`. Every question ends with the card ID and a deterministic fingerprint of the full validated card. A returned question that does not match that snapshot exits 4, even if the card ID and chosen label are unchanged.

To recover a result, use Pi's `/session` command to find the current session's JSONL file. In the current conversation branch, pass the assistant's entire saved `toolCall` content entry for the corresponding `ask_user_question` call as `--call`, keeping its `id` and `arguments` unchanged. Find the session entry with `type: "message"`, `message.role: "toolResult"`, `message.toolName: "ask_user_question"`, and `message.toolCallId` equal to that ID. Pass the entire `message` object, including `details`, as `--result`; do not pass the enclosing session entry. The model-facing `content` alone is not sufficient and must not be used to reconstruct `details`. If the saved call or matching structured result is unavailable (for example, the session was not saved), use the canonical prose path below.

Use `--resolve` to record the decision in one command. After checking the echoed question against the card snapshot, it matches the result's `toolCallId` against the saved call's ID. A missing or different result ID exits 4 with a named reason; use the canonical prose path instead. Once the IDs match, it regenerates the dialog payload and compares it to the saved arguments as JSON: key order and formatting do not matter, but all fields and array entries must match. A mismatch exits 2 with `--call arguments do not match`; use the canonical prose path instead. On a match, it runs `bin/sq-ask.sh --answer` with the exact card bytes that passed the checks, returning the parser's output and exit code unchanged:

```bash
bin/sq-card-pi-dialog.sh --payload < card.json
# one ask_user_question call per element of the printed array
bin/sq-card-pi-dialog.sh --resolve --dialog 1 --call '<saved tool-call JSON>' --result '<tool result>' < card.json
# several cards answered in one call:
bin/sq-card-pi-dialog.sh --resolve \
  --dialog 1 --call '<first saved tool-call JSON>' --result '<first result>' \
  --dialog 2 --call '<second saved tool-call JSON>' --result '<second result>' < card.json
```

`--answer` on the mapping script only prints the code fragment (such as `d1 o2`); do not resolve that fragment against a separately read card file.
Both modes take the whole tool result, never a bare answers array: only `details.cancelled` proves the dialog was not cancelled, so `Esc` can never become a recorded decision.
Either mode rejects a result carrying `details.answers[].notes` or `details.globalNote` with exit 4 (`dialog notes cannot be recorded`). It also rejects a result with `isError: true` or a `details.error` field with exit 4. Keep the decision open and confirm it through the canonical prose path rather than recording the selection without its note.
Answering several cards in one call merges their dialogs into exactly one fragment per decision, mechanically - no fold, no renumbering, no guessed pick.
Each submitted result must contain exactly one answer. An empty result or two answers for the same decision exit 4 without emitting a fragment, and a multi-select answer also exits 4 because this mapping never authors a multi-select question.
A malformed answer, such as a non-string chosen label or typed text, exits 4 with a named error and never a traceback.
The extension cannot pre-validate its built-in text row against the prose grammar. Typed text containing a double quote, backslash, or newline exits 4 with the `free text must be …` error; use the canonical prose block to answer instead. Cards with `allow_free_text: false` are refused before presentation.
If the canonical parser rejects a batch for exceeding the answer length limit, retry with fewer dialogs per call against the same card array so the `D` codes stay the same.
A whole tool result that exceeds the system's per-argument limit fails with `Argument list too long` (`E2BIG`) before it reaches the parser. Use the canonical prose path; do not truncate the result or reconstruct it from model-facing text.

## Fallback

When the extension is absent, a card is refused, or a matching structured result cannot be recovered or used, use the unchanged prose path:

- `bin/sq-ask.sh --render` prints the same prose block it always printed;
- `bin/sq-ask.sh --answer` resolves the typed answer exactly as before;
- the mapping script is never invoked by any existing decision path and has no runtime dependency of its own.

## Files

| File | Purpose |
|------|---------|
| `bin/sq-card-pi-dialog.sh` | Card to dialog payload, and dialog answers back through the canonical parser |
| `bin/sq-bootstrap.sh` | The Pi-only offer, including the exact install command |
| `tests/sq-card-pi-dialog.test.sh` | Mapping, refusal, round-trip, and fallback cases |
| `tests/sq-bootstrap.test.sh` | The offer: Pi only, exact command, never installs, silent elsewhere |
