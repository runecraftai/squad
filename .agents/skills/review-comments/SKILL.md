---
name: review-comments
description: >-
  Write and reply to code-review comments in the Conventional Comments format.
  Carries the label table (meaning and when to use each), decoration rules ((blocking), (non-blocking), (if-minor)), and the grammar label [decorations]: subject plus a discussion block.
  Covers writing NEW review comments and REPLACING or CLOSING replies on existing threads, plus the close-the-loop pattern for answered follow-ups.
  Use when drafting or replying to MR or PR review comments, choosing a Conventional Comments label, calibrating to the author's voice, humanizing a draft, scanning for client-visible internal terms, or building the review-thread board with sq-report.
  EN triggers: write a review comment, reply to review comments, resolve a review thread, review thread board.
  PT triggers: responder comentário de review, responder code review, resolver thread de review, quadro de review.
  Do NOT use for: PR descriptions, release notes, commit messages, or general prose editing without a review-thread context (use humanizer).
user-invocable: false
metadata:
  internal: true
  version: 1.0.0
---

# review-comments

Write and reply to code-review comments on MRs and PRs in Conventional Comments format, in a voice calibrated to the thread's author, and produce the visual review-thread board for the commander.
Load this skill before writing or replying to any code-review thread, before choosing a Conventional Comments label, and before building the thread board.

## Workflow

1. **Gather thread context.** Read the review comment, the full thread history, the code at the referenced file:line, and the commits that changed it. For a reply, know exactly what changed since the comment was written.
2. **Classify.** Map the reviewer's comment to the closest Conventional Comments label using the table below. Replies in the wild use free-form labels (dúvida, detalhe, sugestão, problema, elogio); classify to the closest CC label instead of reproducing them.
3. **Draft.** New comments use the full grammar. Replies answer the question directly, name what changed, and cite the commit or test evidence.
4. **Humanize.** Load the humanizer skill and run it in embedded mode over the draft, calibrating to the author's writing sample (see Humanize every reply).
5. **Scan.** Run the client-visible guard scan over the final text.
6. **Post or update.** Post the comment, or replace and resolve the thread, and update the board state.
7. **Board.** Build the visual thread board and open it with sq-report when the commander needs to review or track the threads.

## Conventional Comments format

Grammar, in this exact shape:

```text
<label> [<decorations>]: <subject>

<discussion block, optional>
```

- Label is one of the CC vocabulary below, always in English even when the subject is in the thread's language.
- Decorations are zero or more parenthesized tags after the label, comma-separated: `suggestion (non-blocking): ...`.
- Subject is a short sentence-case phrase, imperative for suggestions and issues, with no trailing period.
- Discussion block starts after one blank line and carries the context, rationale, or examples. Use it only when the subject line cannot stand alone.

Valid decorations: `(blocking)`, `(non-blocking)`, `(if-minor)`, plus org-specific ones when the repo uses them. `(blocking)` marks a must-fix before merge, `(non-blocking)` marks a point that can merge as is, `(if-minor)` means "apply only if it is a minor change". Do not invent decorations beyond these unless the repo's own conventions define them.

### Label table

| label | meaning | when to use |
|---|---|---|
| praise | highlights something done well | the code does something right; also for acknowledgments and thanks in replies |
| nitpick | trivial preference | a small, optional point that does not block |
| suggestion | concrete improvement proposal | you have a better alternative to propose |
| issue | must be addressed | the point blocks the merge or needs discussion before it |
| todo | follow-up task | an action needed later, tracked outside the thread |
| question | request for information | you need an answer, not a change |
| thought | idea or observation | exploratory remark with no required action |
| chore | maintenance | housekeeping with no behavior change |
| note | non-critical information | context, caveats, or references worth recording |
| typo / polish / quibble | trivial optional labels | spelling, wording, or fine style points |

### PT reviewer labels seen in the wild

| reviewer wrote | closest CC label |
|---|---|
| dúvida | question |
| detalhe | nitpick |
| sugestão | suggestion |
| problema | issue |
| elogio | praise |

## Writing a new review comment

- Pick the label from the table, then add decorations only when they add signal. A bare label without decorations is the default.
- Keep the subject imperative and concrete: `suggestion: extract the thumbnail helper and reuse it in both sections`.
- Add the discussion block only when context is needed: why the change matters, an example, a reference.
- One comment per point. A second independent point gets its own thread, never a paragraph inside an existing one.
- Reviewers classify replies by label too: `question: ...` when you ask back, `praise: ...` when you confirm their point.

## Replying to, replacing, or closing a thread

Before replying, decide which action the thread needs.

- **Reply**: the reviewer asked something or made a point; you answer it.
- **Replace**: an earlier reply of yours is superseded; edit the thread's reply text instead of stacking a second reply.
- **Close**: the point is addressed; resolve the thread on the forge (GitLab: resolve discussion, GitHub: mark as resolved).
- A reply carries a CC label only when the label helps the reviewer scan it. Plain informal acknowledgments are fine and often better (see the samples in Examples).
- Close only threads whose point is actually addressed. If the thread exposes a real new problem, open a new thread instead of closing.

### Close-the-loop pattern

When the reviewer answered your follow-up question, close the loop in one reply: confirm the reviewer's answer, state the change made, resolve the thread.
The reply names the concrete consequence of their answer, not a generic thanks.
Post the confirmation, then resolve the thread, then mark the board state `resolved`.

## Humanize every reply (mandatory)

Load the humanizer skill at `/home/rehem/.agents/skills/humanizer/SKILL.md` (installed user-level skill, reference it by path, never vendor it) and apply it to every drafted reply in embedded mode: run the draft to audit to final loop internally and output only the final text.

1. Humanize every drafted reply. Never post a draft that has not passed the humanizer loop.
2. Calibrate to the author's writing sample when one is available, for example previous comments by the same reviewer in the thread. Match sentence length, vocabulary, contractions, punctuation, and emoji use. A sample outranks the generic style rules, including the em-dash rule: if the author writes with em dashes, keep them at the author's frequency.
3. Forbid robotic tells unless the author's own sample uses them: perfectly parallel triads, em-dash overuse, "feel free", "let's dive in", filler politeness ("let me know if you need anything", "I hope this helps"), rule-of-three padding, and AI vocabulary (delve, leverage, seamless, robust, enhance).
4. Keep replies short and concrete. Answer the question, name what changed, cite the commit or test evidence, stop. No greeting, no sign-off, no summary of the thread, unless the author's sample does that.

Default register for this base: short, informal, direct PT-BR, "tu" style with implicit subjects, matching the commander's samples below.
Do not translate the reviewer's language. Reply in the thread's language.

## Client-visible guard

For client-visible repos (Globo rule), replies must never mention internal tooling, "commander", "Squad", agent names, or orchestration.
This includes: squad-internal tool names (sq-report, sq-gh, sq-browser, sq-tasks, sq-quota, drill), agent or worker concepts (operator, spawn, brief, harness, sentry), and process words (worktree, orchestration).
When in doubt about a repo's visibility, apply the guard anyway.

Final scan, before posting every reply:

```bash
grep -inE '\b(commander|squad|operator|worktree|sentry|drill|harness|agent|spawn|brief|orchestrat|lavish|axi|mcp|skill)\b' <<'EOF'
<paste the drafted reply here>
EOF
```

Any hit means the reply is not ready: rewrite the offending phrase, then scan again.
The scan runs on the exact text that will be posted, after humanizing.

## Visual thread board

Build the board when the commander wants to review suggested replies before they are posted, or to track thread states across MRs.
Copy the template at [assets/thread-board.template.html](assets/thread-board.template.html), fill its `DATA` object, and save the result as a `.html` file under `.lavish/` in the current working directory (sq-report's default location).

The board shows, per MR: the MR title, the full MR link, branch and commit chips, and one card per thread with location (file:line), state badge, the reviewer's comment verbatim, and the suggested reply with a copy button.
States are `pending` (no reply posted yet), `replied` (reply posted), and `resolved` (thread resolved on the forge).
The template is fully self-contained: inline CSS and JS, no external assets, copy button uses the clipboard API with a textarea fallback, badges are color-coded.

Open and collect feedback:

```bash
sq-report .lavish/thread-board.html
sq-report poll .lavish/thread-board.html
```

`sq-report poll` long-polls and stays silent until the commander sends feedback, so leave it running. If the poll is killed or times out, re-run it; queued feedback is never lost.
Apply the feedback to the replies, then post them, update the board states (`replied` or `resolved`), and reopen the board with `sq-report <file>` for a final look.

## Examples

The samples below are preserved verbatim from the real workflow that shaped this skill. They are calibration material: do not "clean up" an author's sample when calibrating to it.

### Sample replies (informal PT-BR, "tu" register)

Thread: reviewer noted an unused constructor argument that never reached the logic.
Reply:

```text
isso, não era — removi do destructure, do log e da chamada do Utils (o construtor nem recebe argumento, então nunca chegava na lógica).
```

Thread: reviewer asked the cover image to go through the thumbnail service.
Reply:

```text
feito — a cover agora passa pelo thumborize (getThumbnail, fit-in 640x360, mesmo padrão do show-playlist-section). em produção a url sai assinada pelo THUMBOR_KEY; sem ele (nos testes) cai no /unsafe/ determinístico.
```

Thread: reviewer noted the image must always be sent, with or without summaryBlocks.
Reply:

```text
verdade — desacoplei. a imagem sai sempre, com ou sem summaryBlocks.
```

Thread: reviewer's point is fully addressed and the exchange is done.
Reply:

```text
valeu! 🙏
```

### Close-the-loop example

Reviewer asked "tu sabe me dizer o que o app realmente precisa consumir?", you answered, and the reviewer confirmed the answer.
Reply that closes the loop, then resolve the thread:

```text
isso — o app consome só o campo X. ajustei o contrato pra expor ele e removi o resto. resolvendo a thread.
```

## Final checklist

Before posting any comment or reply: classified to a CC label, drafted in the thread's language, humanized and calibrated, guard scan clean, exact final text scanned.
After posting: thread state updated on the forge, board state updated, MR link and branch or commit recorded on the board.
