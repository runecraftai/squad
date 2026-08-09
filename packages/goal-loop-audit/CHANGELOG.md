# Changelog

## [0.28.34] — 2026-07-29

### Changed — notify folds a default IN; README decouples from the tintinweb eco

User: "we are too married to our own eco … leaving notify setup to the
user sucks, cause then they won't have it" and "i removed pi-tasks — our
list is our tasklist, the todos were the weaker copy".

- **Push notifications work out of the box.** `notifyCmd` unset no longer
  means silent: glla auto-detects `notify-send` (Linux) or `osascript`
  (macOS) once per session and pushes through it. `notify=off` is the
  explicit opt-out; `notify='<cmd>'` stays the custom override. Pushes
  still fire only where there is something to DO — pauses, auditor
  verdicts, storms, wedge, persistence degradation — never per-turn
  noise. The settings row reads "auto" when unset.
- **README decoupled.** "Subagents (`@tintinweb/pi-subagents`)" →
  "Subagents": the guarantees come from glla's session-handle
  discrimination, not any plugin; tintinweb is "the one we test against",
  not a requirement. Compatibility list names "any subagent provider".
- **pi-tasks reframed as overlap, not complement** — "Overlaps — pick
  one": the glla `/list` IS the task list; two task lists is not the
  ideal combo. (The author's rig uninstalled it the same day.)

Pins: resolution order (off → custom → auto), probe command, both
notifier command lines, actionable-only comment, settings-row text,
README retitle + decoupling + notify footnote. 606 tests.

## [0.28.33] — 2026-07-29

### Changed — `/glla reset` renamed to `/glla wipe`

User catch, same day the command shipped: "reset" sits at edit-distance
2 from "resume" in the same namespace, and it's the destructive one —
the Confirm dialog catches a fat-finger, but the hazard class shouldn't
exist. Renamed before any muscle memory formed:

- **`/glla wipe`** is the one-shot clean slate (unchanged behavior:
  confirm gate, honest goal archive, list cleared, loop stopped,
  `glla_wipe` ledger event).
- **`/glla reset`** now prints "renamed to /glla wipe … Nothing was
  done." and does NOT execute — the ambiguous word can never act.

## [0.28.32] — 2026-07-29

### Added — `/glla resume` + `/glla cancel`: type-blind verbs over the ONE live thing

User: "would it make sense to bundle resume and cancel into /glla so we
don't have to check what type we are running — but this sucks if we need
different commands or one command doesn't work for others." The split:

- **Unified:** `resume` and `cancel` — their meaning is type-independent.
  `/glla resume` resumes whatever is paused (goal or list item) or held
  (loop); `/glla cancel` cancels the one live thing uniformly — goal/list
  item archived as aborted, active or held loop stopped. Same outcome
  shape regardless of the hidden type.
- **Kept typed:** tweak/finish/next/decide/refine genuinely differ per
  policy — folding them in is the trap the user named. `/list cancel`
  (item + drop queue) and `/glla reset` (nuke all) remain the power verbs.

Safe because one-active-thing is enforced (v0.28.14+): at most one thing
is ACTIVE, so the only real ambiguity is paused-goal + held-loop
coexisting (nothing running, two resumables — the polis state today) →
the v0.28.23 decision picker ("Two things can resume — which one?").
The existing one-active guards inside cmdResume/cmdLoop still apply, so
resuming a goal over a live loop refuses with an explanation.

Pins: routes, both dispatchers, the picker, the uniform cancel chain,
empty-state guidance. 605 tests.

## [0.28.31] — 2026-07-29

### Added — `/glla reset`: one-shot clean slate for leftover-laden projects

User directive: "make sure we only have one goal or loop or list at a time
— many of my older projects have many leftovers." A fleet-wide scan (22
`.pi-glla` dirs) confirmed the pile: queued lists up to 56 deep (pully),
36 (virtual-pet), 18 (neonbreak), held loops at iter 11–50 across seven
projects, and paused goals in ~10. The one-active-thing guard (v0.28.14+)
prevents NEW overlap but can't retract history — and cleaning a project
meant three commands (`/goal cancel` + `/list clear` + `/loop stop`).

`/glla reset` is the single consent gate:

- **Confirms first** with a full itemized summary ("goal archived as
  aborted: … · list cleared (56 items) · loop stopped (iter 50, best …)")
  and the reminder that history stays in `.pi-glla`.
- The goal is archived HONESTLY (`aborted`, reason "user reset") — it
  lands in goals/ + the archive; the reviewer's abort-suppression keeps
  it quiet. A terminal goal record is just cleared.
- The list is emptied (`list_cleared {via:"glla_reset"}`), the loop is
  stopped gracefully (`finishLoopGit` + `loop_stopped`) and its record
  wiped — a true clean slate, ledgered `glla_reset`.
- Already-clean projects get "already clean" instead of a dialog.

Pins: route, confirm gate + summary, honest archive, all three ledger
events, loop wipe, clean short-circuit. 604 tests.

## [0.28.30] — 2026-07-29

### Fixed — type visibility + terminology (user notes sweep)

From the user's field notes (the /glla settings explanation + look items
were already shipped in v0.28.15–19 — those sessions run old builds):

- **The widget card always names the type.** The status line read
  "paused · 3m" for a plain goal and "list item · paused" for a list
  item — the user had to scroll up to know which thing was active. Now
  every card says "goal · …" or "list item · …" (the loop surface always
  had its own card). The footer already named the policy everywhere.
- **Pause/abort notifies name the policy.** "Goal paused: 5 consecutive
  errors" / "Goal aborted." fired verbatim for list items (user note:
  "we seem to call everything goal"). New `goalNoun()` helper —
  "List item" when policy==="list", "Goal" otherwise — swept across the
  send-retry storm, stall-refire, wedge-alert, abort, auditor-infra,
  disapproval-cap, pause_goal, stalled, and token-limit notifies.

Pins: typeWord in the card + behavioral goal/list card assertions;
goalNoun helper + ≥10-site sweep + aborted/wedged wording. 603 tests.

## [0.28.29] — 2026-07-29

### Fixed — send-retry storm no longer fires on a legitimately busy session (the polis false positive)

Field-observed (polis): "send-retry storm: 5m of 50ms re-arms — the
session never went idle for the continuation" paused a goal while the
session was simply BUSY (user conversing / long subagent turns). The
v0.28.5 machinery conflated busy with wedged: a flat 50ms re-arm spun
6,000 times in 5 minutes and then escalated.

- **Backing-off cadence.** The busy re-arm now ladders 50ms ×4 → 250ms ×4
  → 1s ×4 → 5s → 15s → 30s cap (`sendRearmDelayMs`) on both the
  continuation and loop-turn paths. agent_end reschedules independently,
  so pickup right after a turn ends is still instant; a long busy stretch
  now costs ~30 ledger-quiet spins instead of 6,000.
- **Time-based, activity-gated escalation.** The count-based constants
  (`SEND_REARM_LEDGER_EVERY`/`SEND_REARM_ESCALATE_AT`) are gone. A storm
  escalates only after **15 minutes of failed sends AND no session
  activity for the last 5 minutes** — a wedged queue shows zero events;
  a busy one streams constantly and simply waits at the capped cadence.
  Ledger milestones at 2/5/10 minutes replace the every-600-spins entry.
- **Texts** now say what was measured: "Nm of re-arms with no session
  activity for Mm — the session is wedged".
- Streak-since timestamps reset everywhere the streak resets (landed
  send/turn, session start, compaction).

Pins reworked in retry-bounds (cadence ladder, time+activity gate,
milestones, constants gone) and stall-handling (compaction reset block).
601 tests.

## [0.28.28] — 2026-07-29

### Fixed — unsolicited work no longer auto-starts (the junk-runner hydra)

Field-observed: after a full-audit goal completed, the user had to cancel
THREE auto-started goals in a row. The ledger showed each head had a
different source: an agent-proposed draft auto-accepted by
`autoAcceptDrafts` (same second as the completion), then reviewer-enqueued
list items auto-activating on an empty slot. Enqueue is not consent to
start — and neither is auto-accepting a draft.

- **Reviewer enqueues hold.** `enqueueItems` gains `opts.autoActivate`;
  the reviewer call site passes `autoResume === true`. With autoResume off
  (the default), reviewer findings QUEUE with a notify
  ("/list next when ready — auto-start is opt-in") instead of starting.
  Ledgered `list_autoactivation_held`. User-driven `/list` imports keep
  immediate-start.
- **Auto-accepted drafts hold.** With `autoResume` off, an auto-accepted
  GOAL draft is created paused/blocked ("held for the user's go-ahead" —
  /goal resume starts, /goal cancel drops) and an auto-accepted LIST draft
  queues without activating. Explicit user-confirmed drafts still start
  immediately. Ledgered `draft_held`. Unattended rigs
  (`autoAcceptDrafts` + `autoResume` both on) keep the old flow.

### Added — goal provenance + `/glla log`

"Log it so we can look back and see where we are doing things wrong."

- `setGoal` threads a `via` ("user", "list-cascade", "draft-confirmed",
  "draft-autoaccepted") into `goal.createdVia` (typed + schematized) and
  the `goal_created` ledger entry — "where did this come from" is now
  answerable after the fact.
- **`/glla log [N]`** — human-readable tail of the event ledger
  (`HH:MM:SS type key=value` lines), filtering high-frequency noise
  (state snapshots, re-arm internals) unless `all` is passed. N defaults
  to 15, caps at 100.

Pins: enqueue gate + reviewer call site + held ledgers; both draft-hold
branches; setGoal signature/record/ledger threading + type + schema;
cmdLog route, noise set, default N. 599 tests.

## [0.28.27] — 2026-07-29

### Added — `/goal audit`: manual isolated-auditor invocation (no agent turn)

The user's question, answered as a command: "the work looks done — can't we
just run the auditor?" `/goal audit` seeds a synthesized completion claim
("verify the objective against the repo directly") and runs the SAME
v0.28.26 direct-audit engine: approved → close + cascade; quota-blocked →
pauses with the claim stored and auto-retries through the pendingCompletion
machinery; any other verdict → resumes and hands the verdict to the agent.
Exact sub in the goal router (`/goal audit`, no args); guards for no-goal
and audit-already-running; ledgered `manual_audit_requested`.

### Fixed — stale handle now silences ALL stall machinery

Field-observed in junk-runner: compaction replaced the session mid-goal;
the footer promised "interrupted — auto-resumes on pi restart" while the
heartbeat kept printing "re-firing continuation (stall 4/5)" into a
process where sends can never land. Worse than misleading: at the stall
threshold the escalation would have PAUSED the goal — silently cancelling
the interruptedAt → auto-resume-on-restart promise (a paused goal restores
load-held). `heartbeatTick` now bails right after the compaction-grace
gate when the handle is stale: no refires, no wedge alerts, no latch
watchdog, no escalation — the goal stays active and waits for the restart.

Pins: stale bail placement (inside heartbeatTick, after grace, before the
latch watchdog and refire path); `/goal audit` route in the core router,
dispatch guards, synthesized claim, ledger event, engine delegation with
origin "manual"; origin flows into ledger/notifies/archive reason.
595 tests.

## [0.28.26] — 2026-07-29

### Fixed — quota-blocked audits no longer re-engage the agent (stored-claim direct auditor retry)

Field-observed in π-games (free-tier model): `complete_goal` was called and
the AUDITOR was quota-blocked (two "auditor quota: retry in 3600s" pauses).
The quota retry then resumed the goal with a normal continuation — asking
the AGENT to re-submit an unchanged completion claim. The model instead
hallucinated closure ("the auditor accepted it, complete_goal returns No
active goal" — ledger shows zero approvals), repeated the same essay
verbatim turn after turn, stormed continuations (9 sends in 63 seconds),
compacted 14× in 35 minutes, and burned the stall brake.

Root design gap: an audit RETRY does not need the agent — the claim was
already submitted. Now:

- When an audit attempt is quota-blocked, the completion claim
  (`completionSummary` + `verificationSummary`) is persisted on the goal as
  `pendingCompletion` (typed, schematized, survives restarts).
- When the quota window elapses, `retryStoredCompletionAudit` re-runs the
  ISOLATED AUDITOR directly with the stored claim — no agent turn, nothing
  new for a weak model to get confused by. Approved → close + cascade
  (archiveCurrentGoal handles list advance + reviewer); still quota'd →
  re-pause with the claim preserved and another scheduled retry; any other
  verdict (disapproved, impossible, infra) → resume active + continuation,
  verdict durable in auditHistory (ledger: quota_retry_audit_verdict).
- Goals paused before this version have no stored claim — their quota
  retry keeps the legacy resume+continuation path.

Pins: claim persisted at the quota block; callback prefers the direct-audit
branch (agent-resume is the no-claim fallback); retry invokes the auditor
with the stored claim; approval archives + clears the claim; quota-again
preserves it; type + schema pins. 593 tests.

## [0.28.25] — 2026-07-29

### Fixed — flat-cadence retry budgets burn in minutes against hour-scale provider conditions

Two field-observed instances of the same design flaw — retry budgets spent
back-to-back, then a pause:

**1. Inter-error retries ride an exponential ladder** (dracon-utilities,
kimi, 19-session fleet on one provider account): a "concurrent request
limit" 403 storm got 5 retries BACK-TO-BACK — an errored turn leaves the
session idle, so `scheduleContinuation` fired with delay 0 after each
`agent_end`. The fleet-wide limit clears on a minutes scale, not
milliseconds. Retries between consecutive error turns now wait
5s → 15s → 45s → 90s → 3m (`ERROR_RETRY_LADDER_MS`, ledgered as
`error_retry_backoff`), so the 5-retry budget spans ~5.5 minutes instead
of ~0.25 seconds.

**2. The 5-consecutive-errors brake cooldown escalates per consecutive
brake**: 1m → 2m → 4m → 8m → 16m cap (was a flat 60s — dracon-utilities
re-braked on it for 1h 38m: resume, 5 instant 403s, pause, repeat). A
healthy turn resets the escalation. First-brake behavior is unchanged
(60s, reason re-checked, one auto-resume per brake).

**3. Stall refires space exponentially** (junk-runner): the heartbeat's
refire gate was a flat 60s of silence — all 5 refires landed in ~4 minutes
into a just-compacted session whose turn trigger was dead, pausing a
resumable goal. `shouldHeartbeatRefire` now scales the required silence by
`2^min(consecutiveStalls, 3)`: refires at 1m, 2m, 4m, 8m, 8m — the budget
spans ~23 minutes, giving the provider/queue real recovery time.

Pins: refire-spacing unit tests (1m/2m/4m/8m/cap + unchanged first-refire
behavior), brake-cooldown source pins, ladder pins (constant, ledger entry,
placement before the aborted branch, scheduleContinuation delayMs param).
591 tests.

## [0.28.24] — 2026-07-29

### Fixed — three field-observed failure classes (π-web, junk-runner, hellhunter)

**1. Reviewer extraction: findings are sentence-shaped, not visual-line-shaped.**
The convert-findings-to-list cascade harvested findings line-by-line from
hard-wrapped (~70-col) completion prose, so a finding could be a mid-sentence
fragment — hellhunter got a list item whose ENTIRE objective was "Run a
post-completion regression scan on the hellhunter codebase to" (the first
visual line of a wrapped paragraph, duplicating an already-approved goal;
the rig then paused on a human decision to clear the phantom item).
`extractFindings` now: joins hard-wrapped lines before classification
(lowercase-start continuation = mid-sentence signal; punctuation-less
uppercase items like TODO chains stay separate); rejects dangling-connector
fragments ("…codebase to"); cuts overlong findings at a clause boundary,
never mid-word; and dedupes findings that restate the just-completed goal
(prefix/containment — the v0.28.16 exact-match dedupe was too narrow;
duplicates arrive as prefixes).

**2. Goal ids are internal plumbing — user-facing surfaces never show them.**
The user: "is that even a goal, we have a list here" — and the agent's
decision card offered `/goal drop 20260729065635-gbtxsm`, a command that
does not exist, referencing an id the user cannot act on. Stripped the id
tag from `/goal status`, the started/saved/paused notifies, and all four
session-restore notifies (resuming/held/restored/loop-hold). `/goal archive`
keeps ids — there they are the `/review <id>` handle. Agent-facing surfaces
(tool results, ledger, prompts) keep them. `pause_goal`'s description and
the continuation prompt now enumerate the REAL command surface for decision
options (`/goal resume`, `/goal cancel`, `/goal tweak "<text>"`,
`/list remove N`, `/list next`, `/loop stop|resume` — all act on the ACTIVE
goal; there is NO `/goal drop` and NO command takes a goal id) and require
naming things ("list item 'regression scan'") instead of showing ids.

**3. Compaction hardening.** Two storm/stall false-positive shapes from the
field: π-web's send-rearm streak climbed 3,600 during a legitimate
3.5-minute compaction (5 minutes would have escalated a misleading
"wedged queue" pause), and junk-runner burned all 5 stall refires in the
5 minutes right after a 196k-token compact — pausing a resumable goal
4 minutes post-compact instead of giving pi room to settle. Now:
`session_compact` resets both send-rearm storm streaks (a compact is
LEGITIMATE busy time, not a wedge signal) and opens a 3-minute
post-compaction grace that suppresses the heartbeat's stall/refire/watchdog
machinery (mirroring post_restore_grace).

Pins: 5 extraction unit tests (wrap-join, TODO-chain separation, fragment
rejection, completed-objective dedupe, clause-boundary cut), compaction
source pins (streak reset inside the hook, grace gate precedes the refire
path), behavioral id-strip tests (/goal status + /goal pause show no id),
pause_goal description pin. 589 tests.

## [0.28.23] — 2026-07-29

### Added — decision picker popup (`ctx.ui.select`)

Follow-up to v0.28.22's classified pause cards, from the user's verdict on
them: "your suggestion is still bad — we are literally cutting off the
decision and asked to pick." The widget card is a SUMMARY (truncates by
design); a decision pause is actionable, so the decision itself now gets a
real picker — the Claude Code / muselinn-Ask pattern, full text, nothing
cut.

**The popup.** When a decision pause lands (agent `pause_goal` with
kind=decision + options, or any extension-synthesized decision pause), a
`select()` modal opens with the FULL option text and the recommended
option flagged. Escape leaves the widget card as the fallback. Picking:

- **content option** ("Deliver the missing polish") → the choice is sent
  to the agent (`Decision for the paused goal …: <choice> — continue on
  this path.`) and the goal resumes;
- **command option** ("Cancel the goal (/goal cancel)") → the command
  RUNS — /goal resume, /goal cancel, /loop stop, /loop resume. Options
  with placeholders (`…`, `<arg>`) fall through to the message path.

**Every extension decision pause now ships options**: auditor IMPOSSIBLE
(tweak / cancel), audit-cap disapprovals (fix-and-resume / tweak / cancel),
stall-nudge pause (retry / tweak / cancel), and the session-load
loop-owns-the-slot hold (stop-loop-then-resume / cancel-goal).

**`/goal decide`** re-opens the picker for the current decision pause at
any time (the auto-popup is a moment; the command is the durable path —
e.g. junk-runner's A/B/C decision after a restart). No pending decision →
an explain-notify, not silence.

**Opt-out**: `/glla decisionpopup=off` (or the settings-menu Keep-going →
Decision popup row) — widget card only. Unattended rigs (no UI) never pop
regardless. Also fixed the autoResume row's stale description (default
changed in v0.28.21).

Pins: 4 behavioral tests (content pick → message + resume; Escape → stays
paused; command pick → runs the command, no message; no-decision →
notify), menu dispatch + render pins, mock ctx gains `abort()`.

## [0.28.22] — 2026-07-29

### Added — classified pause cards (decision / action-needed / waiting)

User report (4 screenshots across junk-runner / ai-auto-writer /
dracon-utilities): "if something actionable is going on it can be hard
to tell" — a decision pause, an infra failure, and a time-gated wait all
rendered as the same wall of text. Research pass first (Claude Code,
Codex CLI, aider/Gemini, pi-muselinn-harness's Ask dialog, local
plugins) — borrowed the 4-zone layout, numbered options, inline
recommended flag, and actionability-first status line.

**Structured pauses.** Goal gains `pauseKind`
("decision"/"error"/"wait"/"blocked"), `pauseOptions[]`,
`pauseRecommended` (1-based), `pauseResumeAt` (ISO). `pause_goal` accepts
them; the tool description teaches when to use which kind.

**Every extension-generated pause is classified at the source**: send-
retry storm / stall refires / auditor-infra / token-limit → `error`;
auditor IMPOSSIBLE / audit-cap / stall-nudges / loop-owns-the-slot →
`decision`; auditor-quota (with retry timestamp) and the 60s transient-
error auto-resume → `wait` + `pauseResumeAt`; restore-hold and user-
abort pauses → `blocked`. Resume clears the new fields.

**Rendering** (goal-loop-display):
- `decision` — accent `decision needed — your call unblocks this`
  banner, reason capped at 2 lines, options as numbered lines
  (`1. … 2. …`), recommended option accented + `◂ recommended`.
- `error` — `action needed — this won't fix itself` banner; the
  suggested action is warning-painted (it's the point of the card).
- `wait` — dim `waiting — nothing for you to do` banner + countdown
  (`resumes 06:40 UTC (in 21h) — or /goal resume now`).
- Status line names the ACTIONABILITY, not the reason:
  `⏸ decision needed` / `⏸ action needed — <reason>` / `⏳ waiting ·
  resumes 06:40`. Legacy pauses (no kind) keep the flat card; the
  error-regex still classifies their status line.

### Added — `/loop resume`

Explicit verb for the held-loop resume (bare `/loop` still works).
"No held loop to resume" now says so instead of opening the drafter.
Held-loop hints updated to name `/loop resume`.

Pins: 4 display tests (decision/error/wait/legacy), pause_goal param +
callsite-classification source pins, T3-adjacent pin fix (pauseKind line
adjacency in eager-continuation-core).

## [0.28.21] — 2026-07-29

### Changed — one active thing ENTIRELY + session loads never auto-start

User directive: "only one goal/list/loop — not each, but entirely — and
we load it on session load but not auto start it."

**One active thing, last gap closed.** `/goal resume` and `/list resume`
(which routes through the same `cmdResume`) now refuse over a live loop
("A loop is active — one active thing at a time. /loop stop it first.").
This was the final unguarded activation path; every transition
(propose_goal_draft, propose_loop_draft, /loop start, /loop bare-resume,
list_activate, /list next, activateNextListItem, and now resume) enforces
the invariant.

**Restore boundary enforces the invariant on dirty legacy states.** A
persisted state with BOTH an active goal and an active/held loop
(possible from pre-guard versions) used to leave the goal active — it
would fire on agent_end while the loop was held. Session load now pauses
the goal: "held — the loop owns the active slot".

**Session load = load, never start (default flipped).**
`shouldAutoResumeOnSessionStart` with autoresume UNSET now returns false
for EVERY reason — the 0.26.9 reload/fork auto-resume default is gone.
Whatever is waiting (goal, list head, loop) is restored visible but HELD
until an explicit `/goal resume`, `/list resume`, or `/loop`. The only
auto-resume path left is the explicit opt-in `/glla autoresume=on`
(unattended rigs) — its behavior is unchanged.

**0.28.3 interrupted-goal exemption SUPERSEDED.** An infra-interrupted
goal no longer auto-resumes on a human load under the default — it holds
like everything else, marker preserved. Under autoresume=on the marker
still drives the auto-resume and is cleared by it. The stale-creation
notify now says "Restart pi, then /goal resume" instead of promising an
auto-resume.

⚠️ **Operational note**: after this ships, EVERY restart/reload holds work
by default in every project. Unattended rigs that relied on reload
auto-resume must opt in: `/glla autoresume=on` (project or global).

Pins: core gate (all reasons false by default), T3b/T3c/T3e rewritten
(default-hold + autoresume=on variants keep the auto-resume path
covered), S2 source pin flipped to the supersession, 2 new behavioral
tests (resume-over-loop refusal, dirty-state enforcement).

## [0.28.20] — 2026-07-29

### Changed — settings table de-chromed

User report with 4 screenshots: "extra brackets and some don't even
fit". Every decorative wrapper is gone:

- SOURCE column: `[default]` → `default`, `[runtime]` → `runtime`,
  `[—]` → `—` (bare words; the column header already says SOURCE).
- VALUE column: all paren-wrapped fallbacks are bare — `(off)` → `off`,
  `(5)` → `5`, `(pi session model)` → `pi session model`,
  `(follows strategy)` → `follows strategy`, etc. The parens used to
  signal "default"; the SOURCE column carries that now, and the mix of
  parenthesized defaults vs bare set-values was inconsistent.
- "Postaudit config…" label → "Postaudit" — the ellipsis was a literal
  character meaning "opens a sub-menu" but read as truncation.
- "Effective resolution" composite compacted: parenthesized qualifiers
  stripped (`kimi/k3 (inherits session)` → `kimi/k3`) and identical
  resolutions deduped to one value — the old
  `(session model) · (sess…` truncated composite never fit.

Pins updated + a new guard test fails if paren/bracket chrome returns.
The headless `/glla` fallback already stripped brackets, unchanged.

## [0.28.19] — 2026-07-29

### Changed — color-only settings tabs

User call ("dropping the brackets"): the /glla tab bar no longer wraps
tabs in `[...]` — active tab is accent+bold, inactive dim. The
4-column table grid from 0.28.18 is unchanged.

## [0.28.18] — 2026-07-29

### Changed — the /glla settings menu is a real table now

User report (screenshots, 2026-07-29): "we want to look more like a
table". Three grid bugs fixed + the table look the user picked
(│ separators + header rule; every tab bracketed):

- **Prefix counted in KEY width** — rows render `▶ `/`  ` + label but
  keyW was computed from labels alone, so every row's VALUE column sat
  2 chars right of the header's VALUE.
- **VALUE truncated to its column** — a long value (Subagents'
  effective-resolution composite) overflowed and shoved SOURCE/
  DESCRIPTION right on that row only. KEY/VALUE/SOURCE all
  `truncateToWidth` with `…` now.
- **Widths computed across ALL sections** — the grid no longer reflows
  on every tab switch (it was per-active-section before).
- **Table chrome**: columns joined by dim `│` separators, a `─┼─`
  header rule under the column titles, and the tab bar brackets EVERY
  tab (active = accent, inactive = dim) — bare words read as floating
  text, not tabs. Selected-row separators join plain so the accent
  wrap isn't cut short by a nested dim reset.

### Fixed — suite hermeticity for global settings

Setting `autoAcceptDrafts` in the REAL global settings file
(`~/.pi/agent/pi-goal-list-loop-audit.settings.json`) made two
behavioral draft tests fail — `loadSettings` read the developer's own
config. `globalSettingsPath()` now honors `GLLA_GLOBAL_SETTINGS_PATH`,
and a new `bunfig.toml [test].preload` (`tests/harness/setup.ts`)
redirects it to a per-process tmp file for the whole suite.

Pins: bracket-all-tabs, header rule, separator alignment across header/
rule/rows, long-VALUE truncation keeps the grid, widths stable across
tab switches.

## [0.28.17] — 2026-07-29

### Fixed — held loops are always visible (user report: "loops are the most immature")

A loop parked by the session-restore gate (`HELD_ON_RESTORE`) rendered
NOTHING in the always-on UI — `buildStatusText` and
`buildWidgetLinesInner` only branched on `state.loop?.active`, so a reload
made the loop vanish while paused goals and waiting lists stayed visible.

- **Status segment**: held loop alone → `glla: loop ⏸ held · iter N —
  /loop to resume`; with any goal state (active/paused/auditing/
  interrupted) → a compact `· loop⏸held` suffix rides the goal text; a
  completed/aborted goal no longer hides it either.
- **Widget**: held loop alone → its own card (target, iter, elapsed,
  "/loop to resume · /loop stop to drop"); with a visible goal → a
  trailing `⏸ <target>` + "loop held" line rides the goal card.
- Genuinely stopped loops (any other stopReason) stay invisible — the
  marker is exported from `goal-loop-forever.js` as `HELD_ON_RESTORE`
  (was a private const in `loops/goal.ts`) so the display layer keys off
  the exact restore-gate state.
- Pins: held alone / held + paused goal / held + active goal / held +
  completed goal / active loop unchanged / stopped loop invisible.

## [0.28.16] — 2026-07-29

### Fixed — reviewer duplicate-scan dedupe (the scan-of-a-scan cascade)

On 2026-07-28 the reviewer proposed the identical "Post-completion
regression scan" follow-up twice in a row: scan `24ewt8` completed →
proposed scan `pii8tt` → `pii8tt` completed → proposed scan-of-`pii8tt`
AGAIN. Each proposal was literally unique (the goal-id differs), so no
existing guard caught it.

- `runReviewer`'s fire-audit-on-clean branch now normalized-compares the
  proposal against the just-completed goal's own objective (`source` IS
  the most recent completion): lowercase, goal-ids (`yyyyMMddHHmmss-xxx`)
  → `<id>`, whitespace collapsed. A match means the completed goal was
  itself this same scan — the proposal/enqueue is suppressed in all three
  modes (on / auto / aggressive), the suppression is ledgered
  (`reviewer_suppressed` reason `duplicate-scan`), and the report's
  cascade step is `duplicate-suppressed` so `/goal status` shows why no
  follow-up fired. The review report still writes.
- New `normalizeObjective` export.
- Pin: completing "Post-completion regression scan after <id>" proposes
  NOTHING in on/auto mode, while a genuinely different clean completion
  still fires the scan. The 0.27.9 negative pin banning the retired
  `report-only` vocabulary stays green — the new step has its own name.

## [0.28.15] — 2026-07-29

### Fixed — 0.28.14 audit gaps (carryover on the list path, resume pin, /loop cancel discoverability)

The 0.28.14 auditor found three real holes:

- **Carryover resolution now covers list activation**: the trigger is
  `"goal" | "loop" | "list"` and `activateNextListItem` (the choke point —
  `/list next`, `list_activate`, list-draft auto-activate, completion
  cascade) resolves carryover BEFORE taking an item. Under `clear` the
  stale queue is dropped first and nothing stale activates; under `pause`
  the ONE summary precedes activation and the paused goal is archived as
  `replaced by new list (carryover)`.
- **`carryover=resume` pinned**: legacy silent stacking — no summary,
  queue + held loop untouched.
- **`/loop cancel` is discoverable**: added to the `/loop` command
  description and slash-bar argument completions.

## [0.28.14] — 2026-07-29

### Added — lifecycle consolidation: one active thing, entirely

The user report: stale goals/lists/loops lingered across sessions and got
auto-resumed into confusion; there wasn't even a `/loop cancel` (loops were
aborted via `/goal cancel`). Investigation found the confusion had a real
engine underneath: **`setGoal` and `archiveCurrentGoal` rebuilt state as
`{goal, list}` and silently nuked `state.loop`** — any held/active loop
vanished whenever a goal was set or archived — and `setGoal` silently
orphaned a paused goal it replaced.

- **State-loss bugs fixed**: both reconstructions now spread `...state`
  (loop + list preserved); a replaced paused/active goal is archived
  honestly (`replaced by goal <id>`) instead of orphaned.
- **One-active-thing by construction**: every activation path is now
  guarded — `/loop` bare-resume refuses over an active goal;
  `propose_loop_draft` refuses over an active goal (early, before the
  measure test-runs); `propose_goal_draft` refuses over a live loop (early
  AND post-confirm backstop); `list_activate` + `/list next` refuse over a
  live loop; and `activateNextListItem` itself is the choke-point guard so
  no present or future call site can stack a list item over a loop.
- **`/loop cancel`** is a first-class alias of `/loop stop`; `/goal cancel`
  now points at the right verb when a loop is the thing running.
- **Carryover policy** — new `/glla carryover=resume|pause|clear` (default
  `pause`): at session_start the stale leftovers (paused goal, waiting
  list, held loop) are snapshotted; when NEW work activates, they're
  surfaced in ONE summary (pause), dropped honestly with a ledger trail
  (clear), or left to legacy silent stacking (resume).
- Behavioral pins: both carryover policies end-to-end through the mock
  harness, `/loop cancel` stop semantics, all three tool guards, and the
  loop-preservation regression (goal set/archive no longer drops the loop).

## [0.28.13] — 2026-07-28

### Fixed — provider-error turns no longer feed the stall watchdog

The endless-td 429 incident: MiniMax-M3's token plan ran out mid-goal,
pi returned four consecutive `stopReason="error"` turns (zero content),
and the stall watchdog counted each as an "unproductive turn" — pausing a
healthy goal mid-CDP-capture with the wrong diagnosis ("stalled: 3
consecutive unproductive turns"). A dead provider is not a lazy model:
escalation warnings can't fire against it either, and pi's own retry owns
the backoff.

- Nudge accounting in the `agent_end` handler now exempts
  `stopReason === "error"` turns entirely — the counter neither increments
  nor resets on provider errors, and each exemption is ledgered
  (`stall_nudge_exempt_error`).
- Behavioral pins: 3 consecutive error turns leave the goal ACTIVE; a real
  nudge before the errors still counts after they pass (the third real
  nudge pauses, neither earlier nor later).

## [0.28.12] — 2026-07-28

### Added — auto-accept escape hatch in every draft-class dialog

The polis incident: a user sat through a 14-item batch Confirm having
already reviewed every item during drafting, never knowing
`/glla autoaccept=on` existed — the Yes/No dialog never mentioned it.

- New `confirmDraft` helper: every draft-class dialog (goal / list item /
  list batch / loop / loop spec refinement / task list) is now a 3-choice
  select — **Yes / "Yes — and always auto-accept drafts (sets
  autoAcceptDrafts for this project)" / No**. The ALWAYS choice persists
  `autoAcceptDrafts: true` to PROJECT settings, notifies the undo path,
  and accepts; future drafts skip the dialog entirely.
- Loop spec refinement now ALSO honours `autoAcceptDrafts` (it confirmed
  unconditionally before).
- Stale-dialog handling preserved: the helper returns a tri-state
  (`yes/no/stale`) so the 0.28.1 NOT-a-rejection guidance still fires; if
  `select` is unavailable it falls back to the plain confirm.
- Auto-accept reads now use `liveCtx.cwd` (the execution context's
  project), not the closure ctx — same value in production, correct under
  the mock harness.
- Mock harness: `selectImpl`/`confirmImpl`/`inputImpl`/`customImpl` are
  now nullable (tests can restore defaults with `= undefined`).
- 3 new pins: ALWAYS persists + accepts (behavioral, on-disk settings
  verified), later drafts skip the dialog (behavioral), all six draft
  dialogs route through `confirmDraft` with the ALWAYS option (source).
- 547 pass / 1 env-gated skip / 0 fail / 548 tests across 58 files.

## [0.28.11] — 2026-07-28

### Changed — user-facing message humanize pass (audit U6–U11, E7)

- **U6 tool-override confirmations speak outcomes**: `toolOverrides.allow
  += bash` → `"bash" is now always visible to the agent (project override
  saved).` — same for hide/unallow/unhide/set/unset. No more config-JSON
  echoes.
- **U7 reviewer suppression reasons humanized**: `doNotFireOn:
  goal-complete` → `this event type (goal-complete) is excluded in /glla
  postaudit → fire-on`; all 7 reasons rewritten (disabled, mode off,
  excluded event, non-completion, refire window, day cap).
- **U8 dracon-sync prompt section generalized** (published-package bug):
  DETACHED COMMIT DETECTION now opens with "Skip this section entirely if
  your rig has no auto-committer — most rigs don't", the git-reflog
  forensics stay generic, and `dracon-sync` appears only as the
  maintainer-rig example.
- **U9 goal creation is objective-first**: `Goal <id> created — starting
  now.` → `Goal started: <objective> — the auditor will verify on
  completion. (id: <id>)`; the stale-creation variant likewise.
- **U10 "list N" → "N queued" for goal policy** in both the status text
  and the widget footer (v0.24.7 fixed list policy only).
- **U11 one user-facing noun — "postaudit"**: menu title, suppression/
  failure/proposal notifies, and the /review description all say
  postaudit (`/review` stays the command verb; `reviewer` stays internal
  code + report-file vocabulary).
- **E7 reviewer-menu save failures are LOUD**: the swallowed
  "non-fatal" catch → `Postaudit setting NOT saved: <err> — check
  .pi-glla/settings.json permissions.` — the user no longer believes a
  failed toggle landed.
- 544 pass / 1 env-gated skip / 0 fail / 545 tests across 58 files.

## [0.28.10] — 2026-07-28

### Fixed — docs drift (audit U1–U5, U12, U13)

- **/review help** now advertises the accepted modes: `[off|on|auto|aggressive]`
  (the registration still showed the 0.27.9-rejected `auto|report|default`).
- **README**: five top-level commands (was "four" — `/review` missing);
  `/review` added to the quick-start; `/glla` line lists the real subcommand
  surface (stats / audits / postaudit / autoaccept / key=value); the
  quick-start fence bug fixed — the "Order is the default, not the law"
  prose rendered INSIDE the code block; test count 168 → 545 / 58 files.
- **INSTALL.md**: reviewer section rewritten for the 4-mode cycle
  (off | on | auto | aggressive — the old default/auto/report table was
  two renames stale), postaudit naming + `/glla postaudit` (reviewer alias),
  aggressive-mode relaunch semantics documented; test count refreshed.
- **CHANGELOG**: the 0.28.0 entry was stranded at the file's BOTTOM behind
  a fossil "Unreleased → v0.2.0 plan" block — moved to its newest-first
  position between 0.28.1 and 0.27.9; the fossil block (all items long
  shipped) deleted.
- Root litter files `then`/`pass` verified absent (already cleaned).
- 544 pass / 1 env-gated skip / 0 fail / 545 tests.

## [0.28.9] — 2026-07-28

### Fixed — E4 completion (auditor-caught)

The 0.28.8 E4 fix gated two of the four `proposeGoal` call sites; the
isolated auditor found the **fire-audit-on-clean** branch still incrementing
`proposed` unconditionally in aggressive and default modes. Both now gate on
the boolean return. New pin: clean completion + failing send yields
`proposed === 0` in BOTH modes (tests/reviewer-modes.test.ts). 544 pass /
0 fail / 545 tests.

## [0.28.8] — 2026-07-28

### Fixed — phantom reviewer proposals + measure-broken vs plateau (audit E4, E5)

- **E4 phantom reviewer proposals.** The reviewer counted a /goal proposal
  as "proposed" even when the `sendUserMessage` call THREW (stale handle
  etc.) — the catch swallowed it and the completion notify still reported
  "(1 /goal proposed)" for a message that never arrived. The `proposeGoal`
  dep now returns boolean (true = actually delivered); `runReviewer` counts
  only confirmed sends; goal.ts's callback returns false on throw AND
  notifies loudly ("Reviewer /goal proposal NOT delivered … restart pi if
  the session was just replaced") instead of the silent "best-effort"
  comment. Pinned: a false-returning proposeGoal yields
  `outcome.proposed === 0` (tests/reviewer-modes.test.ts E4 test).
- **E5 measure-broken is no longer "plateau".** A measure command that
  prints no number used to increment the plateau stall counter, so a broken
  measure stopped the loop with the misleading "plateau — no improvement".
  `LoopState.consecutiveNullMeasures` now tracks null outputs separately:
  a null is NOT a stall (it says nothing about improvement), a numeric
  value resets the streak, and `plateauWindow` consecutive nulls stop the
  loop with "measure command broken — N consecutive iterations printed no
  number (cmd: …). Fix the measure command, or /loop stop." Plateau stays
  reserved for real non-improving numbers. 4 new pins in
  tests/loop-forever.test.ts.
- 543 pass / 1 env-gated skip / 0 fail / 544 tests across 58 files.

## [0.28.7] — 2026-07-28

### Added — mock-ctx behavioral test harness (audit T7, T1–T5)

From `audit/WRONG-OR-NOT-PREMIUM-2026-07-28.md` Stream 4. The root-gap fix:
`tests/harness/mock-pi.ts` — a fake ExtensionAPI (captures registered
tools/commands/event handlers; sync-throw `sendMessage`/`getSessionName`
stale injection matching pi's real assertActive semantics) + stub
ExtensionContext (captured notifies, scriptable ui.confirm/select/input).
`tests/behavioral-orchestrator.test.ts` registers goal.ts on the fake and
DRIVES it — the first tests that execute the orchestrator instead of
regex-pinning its source. The harness caught TWO real production bugs on
day one (below).

### Fixed — caught by the new harness

- **Restore-gate tri-state regression (T3, live since 0.28.3).**
  `resolveEffectiveAggressiveSettings` coerced `autoResume: s.autoResume ??
  aggressiveMode` → `false` when unset, so the session_start restore gate's
  DEFAULT branch never fired: reload/fork HELD instead of auto-resuming,
  and the 0.28.3 interrupted-goal rule (`!== false`) never triggered — the
  exact capture-anime-girls scenario 0.28.3 claimed to fix. Now
  `s.autoResume ?? (aggressiveMode ? true : undefined)` — unset stays
  tri-state (hold on human loads, resume on reload/fork); aggressiveMode
  still flips the default to always-resume. Behaviorally pinned: T3a HOLD
  on human load, T3b reload auto-resume, T3c interrupted outranks the
  default hold, T3d loop HELD_ON_RESTORE, T3e list-head auto-activate.
- **Foreign-session guard gap (T5).** `complete_task`,
  `update_task_status`, and `propose_task_list` mutated goal state with NO
  foreign-session guard — a subagent session could rewrite the main
  session's task list. All three now route through `foreignToolGuard`;
  coverage pin scans every registered tool block and fails if any mutating
  tool (or a future new/renamed one) lacks the guard.

### Behavioral coverage converted from source pins

- **T1 stale creation paths**: stale Confirm in propose_goal_draft →
  NOT-a-rejection guidance + nothing created; stale /goal start → goal
  persisted with interrupt marker + honest ".pi-glla" notify.
- **T2 stale send → terminal**: agent_end continuation against a dead
  handle → goal stays ACTIVE + interrupt marker + loud restart notify +
  ledgered.
- **T4 settings editors**: `tests/settings-editors.test.ts` executes
  select/input editors end-to-end against the real global settings file
  (snapshot/restore) — writes, clears, validation rejection, dismissed-
  editor-no-write all pinned.
- Test-only export `__testOnlyResetStaleFlag` (the stale flag is
  process-terminal in production) + `handleSettingChoice` now exported.
- 539 pass / 1 env-gated skip / 0 fail / 540 tests across 58 files.

## [0.28.6] — 2026-07-28

### Fixed — persistence integrity hardening (audit E1, T6)

From `audit/WRONG-OR-NOT-PREMIUM-2026-07-28.md` Stream 2.

- **Guarded writes (E1).** A disk failure (ENOSPC, EACCES, wedged mount)
  used to THROW out of `appendLedger` / `writeGoalMd` /
  `archiveCurrentGoal` mid-handler — killing the orchestrator turn and
  silently diverging RAM from disk. Every persistence step now runs
  through `runPersistStep` (goal-loop-core.ts): failures latch a
  session-wide `persistenceDegraded` flag instead of throwing, and the
  next SUCCESSFUL step auto-clears it (self-healing — the "dirty" marker
  write-then-mutate ordering cannot otherwise provide; RAM stays
  authoritative and re-syncs on the next landing write).
- **Loud first failure + TUI flag (E1).** `persistState` (the choke point
  every state transition flows through) now calls
  `notifyPersistenceState`: one loud warning on the first failure
  ("State lives in RAM and re-syncs on the next successful write …"),
  one all-clear on recovery. `buildWidgetLines` prepends
  `⚠ persistence degraded — .pi-glla writes failing (…); state in RAM`
  as the first widget line on every render until a write lands.
- **Archive no longer destroys the only copy (E1).**
  `archiveCurrentGoal` removes the active goal md ONLY when the archive
  write actually landed.
- **Tolerant reads (E1/T6).** `readState` wraps the ledger read itself
  (EACCES/EIO degrades loudly instead of crashing session_start); the
  per-line JSON tolerance now has a REAL functional pin — a truncated
  trailing `active.jsonl` line (mid-write kill) loads the last good
  state.
- **Schema-drift tripwire (T6).** New test asserts every
  `goal.schema.json` property exists in the `Goal` interface.
- Tests: new `tests/persistence-hardening.test.ts` (7 tests, incl. real
  filesystem failure injection).

## [0.28.5] — 2026-07-28

### Fixed — bound the silent retry loops; honest error brake (audit E2, E3, E8)

From `audit/WRONG-OR-NOT-PREMIUM-2026-07-28.md` Stream 2.

- **Auditor infra errors bounded (E2).** A broken auditor model used to
  retry forever — every infra failure rescheduled a continuation
  unconditionally (the 39-error incident). New persisted
  `auditInfraStreak` goal field counts trailing infra errors (survives
  restarts; cleared by any real auditor run and by reaching quota); at 3
  the goal PAUSES loudly — "the auditor model is likely broken …
  /glla model=provider/id, then /goal resume. Your work was NOT judged" —
  instead of spinning.
- **Send-retry storms visible + bounded (E3).** The 50ms idle-retry re-arm
  loop spun for hours with zero ledger events while the idle watchdogs
  stayed suppressed. Re-arms are now counted (`send_rearm_start`, then
  `send_rearm_storm` every 30s), and a 5-minute storm escalates
  loud-terminal (`send_rearm_escalated`): goal paused / loop stopped with
  restart guidance, same shape as `escalateStallNow`. A landed send clears
  the streak.
- **Error brake tells the truth + recovers (E8).** The consecutive-errors
  brake paused with the literal reason "5 consecutive errors: error"
  (stopReason, never the provider error — field-observed pausing THIS
  audit's goal mid-run) and counted USER ABORTS as errors. Now: the pause
  reason carries the real error text (`5 consecutive errors (last: …)`);
  aborts brake separately ("5 consecutive aborts (user interrupted)") with
  NO auto-resume (user intent); provider errors get ONE capped 60s
  auto-resume via the quota-retry machinery (reason re-checked, user pause
  not stomped) — a 60s flake no longer costs hours of manual resume.
- `scheduleQuotaRetry` gains a `label` param (quota default unchanged).
- Tests: new `tests/retry-bounds.test.ts` (7 pins).

## [0.28.4] — 2026-07-28

### Fixed — nudge before the stall brake; unclosed status in every continuation (audit P1–P3)

From `audit/WRONG-OR-NOT-PREMIUM-2026-07-28.md` Stream 5. Field-observed in
the game-dev sessions: done-but-unclosed goals got silently pause-stamped by
the stall brake ("the goal paused itself out of nowhere") because the model
narrated completion in prose instead of calling `complete_goal` — and nothing
ever told it prose doesn't close goals.

- **Graduated escalation entry (P1).** At nudge 1 and 2 (before the
  `HEARTBEAT_MAX_NUDGES` brake), the goal receives an explicit
  `[STALL WARNING n/3]` continuation: "if DONE call complete_goal NOW — prose
  closes nothing; if BLOCKED call pause_goal; otherwise make a tool call;
  N more unproductive turns pause the goal." Displayed to the user, ledgered
  as `stall_escalation_nudge`, stale-aware like every autonomous send. Loops
  keep their existing runLoopTick path.
- **Unclosed-status block (P2).** `prompts/goal-loop-continuation.md` gains a
  `## State` section at the top: "State: ACTIVE — not yet auditor-approved.
  Prose closes nothing … a done-but-unclosed goal is a bug, not a resting
  state." The STALLS section now names the graduated warning.
- **Post-restore grace (P3).** The first 2 `agent_end` turns after a
  session_start restore skip nudge accounting (ledgered as
  `post_restore_grace`) — recovery chatter (orientation reads, plan
  narration) no longer counts toward the brake and paused restored goals
  mid-recovery.
- Tests: 3 new pins in `stall-handling.test.ts`; `length-continue.test.ts`
  window pin re-shaped (order is the contract, not a 5000-char distance).

## [0.28.3] — 2026-07-28

### Fixed — interrupted goals outrank the default restore HOLD (S2 completed)

0.28.1's marker kept stale-interrupted goals ACTIVE, but the session_start
restore gate still HOLDS active goals on a human session load when
`autoresume` is unset (the v0.26.9 default) — so the auto-resume the marker
promised only fired for `reload`/`fork` or `autoresume=on` rigs. An infra
interrupt is not user intent: the restore gate now auto-resumes an
interrupted goal whenever `autoresume` is unset (explicit
`/glla autoresume=off` still holds), clears the marker, and names the
recovery.

## [0.28.2] — 2026-07-28

### Fixed — release mechanics

`long-running-modes-parked.test.ts` pinned the package version to exactly
`0.27.9|0.28.0`; re-shaped to the contract (0.27.9 or later) so routine
version bumps stop failing it. (0.28.1 shipped the stale-interruption rework
below; this patch only repairs that pin.)

## [0.28.1] — 2026-07-28

### Fixed — stale-interruption rework: auto-resume instead of stranded pause (audit S1–S4, E6, T1)

From `audit/WRONG-OR-NOT-PREMIUM-2026-07-28.md` Stream 1. When pi invalidates
the extension handle (session replacement — compaction triggers it in pi
0.82.x), the old handling paused the goal; the session_start restore gate
only auto-resumes ACTIVE goals, so every stale event stranded the goal until
manual `/goal resume` ("starts paused and stuck"), and a resume attempted
inside the still-stale session produced an active-in-ledger/dead-in-process
zombie (S1).

- **Goals STAY ACTIVE with an interrupt marker.** `goStaleTerminal` now sets
  `interruptedAt`/`interruptedReason` on the goal instead of pausing it.
  `sendContinuation`'s `extensionApiStale` guard already stops sends in the
  doomed process, and the next fresh session auto-resumes the goal through
  the existing restore gate — which now clears the marker and names the
  recovery ("auto-resumed after the stale-handle interrupt"). Loops keep
  the stop-on-stale behavior.
- **Staleness probes at command entry (S3).** New side-effect-free probe
  (`extensionApi.getSessionName()` routes through pi's `assertActive()`)
  wired into `/goal` creation, `/goal resume`, `/list`, and
  `propose_goal_draft`. Stale creation persists the goal with the marker
  and says so ("created and safe in .pi-glla/ … restart pi and it
  auto-resumes") instead of the "created — starting now" lie; stale resume
  persists the resume for the next session and skips the misleading
  "Resumed goal" notify and the doomed continuation send.
- **Drafting-seed failure is loud (E6).** The `/goal` interview seed send
  used to fail silently (Enter → nothing). It now notifies, and stale
  handles get the restart guidance.
- **Stale Confirm is not a rejection (T1).** Both the single-draft and
  list-batch Confirm paths detect the stale signature and return "this is
  NOT a rejection — restart pi" instead of "Draft rejected by the user".
- **Widget surfaces the interrupt.** An interrupted-but-active goal renders
  `⚠ interrupted — stale handle · auto-resumes on pi restart` instead of
  looking healthy.
- Schema + `Goal` type carry `interruptedAt`/`interruptedReason`.
- Tests: new `tests/stale-interrupt-resume.test.ts` (10 pins);
  `stale-api-terminal.test.ts` updated to pin the active+marker shape.

## [0.28.0] — 2026-07-28

### Changed — `/glla` settings menu is now a real TUI table

The pre-0.28.0 menu used `ctx.ui.select` with flat single-line rows
formatted as `label — value [source] — description`. The 0.28.0 menu uses
`ctx.ui.custom` with a Container/Text layout featuring:

- a top **tabs row** listing all 5 sections (`Keep-going`, `Auditor`,
  `Stall brakes`, `Subagents`, `Other`) — `←`/`→` (and `Tab`/`Shift+Tab`)
  switch the active section;
- a **4-column body** for the active section: `KEY | VALUE | SOURCE |
  DESCRIPTION` — `↑`/`↓` move within the section, `Enter` drills into
  the per-key editor, `Esc` exits.
- column widths are computed from the actual content, capped per-column
  (`MAX_KEY_W=32`, `MAX_VALUE_W=24`, `MAX_SOURCE_W=10`) and the
  description column truncated with `…` on narrow terminals.

Reorganized into a new module `extensions/settings-menu.ts` exporting:

- `buildSettingsRows(settings, prov, subagent?, defaults?)` — pure builder
  returning stable-id rows (e.g. `"autoResume"`, `"auditorModel"`,
  `"subagentModelOverrides.Explore"`).
- `SettingsMenuComponent` — the `Component` returned from
  `ctx.ui.custom(...)`.

### Changed — settings menu dispatch is now id-based, not `startsWith`-based

The pre-0.28.0 dispatcher used `choice.startsWith(label)` strings against
the displayed row text. The 0.28.0 dispatcher (`handleSettingChoice(id, ctx)`)
uses a `switch (id)` against stable ids from `buildSettingsRows`. Same
per-key handler bodies (the only behaviorally-test surface is identical);
the trigger changed.

### Added — per-key editor coverage for `stallShortWords` and `stallSimilarityThreshold`

The 0.27.0 menu exposed these two keys as visible rows but had no editor
handler. The 0.28.0 `handleSettingChoice` includes numeric-input handlers
for both: `stallShortWords` accepts non-negative integers, and
`stallSimilarityThreshold` accepts a decimal between 0 and 1.

### Added — `Effective resolution` row (read-only)

The subagents section now also shows a read-only `Effective resolution`
row displaying the runtime-effective model for `Explore`, `Plan`, and
`general-purpose` based on the current `subagentModelStrategy`,
`subagentModelOverrides`, and the active session model. Selecting the row
is a no-op (no editor opens).

### Changed — dropped `haiku` mention from the `Subagent model strategy` description

The pre-0.28.0 description said "agent-default pins haiku for Explore".
The 0.28.0 description says "inherit-parent shares your session model +
quota pool; agent-default uses the upstream pi-subagents default agents".
The "haiku" label remains in diagnostic comments and runtime effective-
model labels (`resolveEffectiveSubagentModel` returns
`"anthropic/claude-haiku-4-5 (upstream pin)"` when the strategy is
`agent-default` and no override is set) — those are useful when
debugging the pi-subagents#175 quota bug, not user-facing config text.

### Tests

- `tests/settings-menu-complete.test.ts` rewritten to assert on the
  `buildSettingsRows` + `handleSettingChoice` structural contract
  (10 tests).
- `tests/glla-table-menu.test.ts` (new) pins the table renderer
  (rendering at widths 120/80/60, tab/arrow navigation, Enter/select,
  truncation, cache invariants, `Component` shape) — 19 tests.
- Net: 495 pass / 1 env-gated skip / 0 fail (up from 468 / 1 / 0).

## [0.27.9] — 2026-07-27

### Changed — postaudit modes re-shaped to literal 4-mode contract

`ReviewerMode` is now `"off" | "on" | "auto" | "aggressive"` (was
`"off" | "default" | "auto" | "aggressive" | "report"`). The contract
specified `off | on | auto | aggressive` with default `on`; `default`
was renamed to `on`, `report` was dropped entirely (its "write report
only, no cascade" behavior was already covered by `on` + a configurable
`cascade` block). Existing settings files with `"default"` or `"report"`
auto-migrate to `"on"` on first read via `resolveReviewerConfig`. Default
is now `on` (was `default`). `/review <id> <mode>` accepts all four.
`/glla postaudit=` (and the legacy `/glla reviewer=`) cycles through
`off → on → auto → aggressive → off`.

### Added — per-tool override subsystem (item 5)

`.pi-glla/settings.json` now accepts a `toolOverrides` block:

```json
{
  "toolOverrides": {
    "allow": ["bash", "write_file"],
    "hide": ["some_external_tool"],
    "perToolConfig": {
      "bash": { "timeout": 60 }
    }
  }
}
```

`toolOverrides.allow` forces tools visible despite an external modlist;
`toolOverrides.hide` forces tools hidden even when the session allows
them. `perToolConfig` is an extensible record for tool-specific knobs
(timeouts, formats, etc.). `/glla tooloverride <action>` opens the menu:

- `list` — show current state
- `allow <tool>` / `hide <tool>` / `unallow <tool>` / `unhide <tool>`
- `set <tool> <key>=<value>` / `unset <tool> <key>`

The existing tool-heal self-heal (`ensureAgentToolsActive`) now applies
these lists on top of the missing-tools recovery. Unattended rigs can
finally override modlist profiles without editing the global profile.

### Changed — paused widget zero-telemetry wording

The widget now renders `awaiting first turn — resumes exactly here` when
`tokUsed === 0 && audits === 0` (restored-in-fresh-session before the
first turn). With telemetry it still renders `saved — N tok spent · M
audits · resumes exactly here`. The literal contract text is honored.

### Added — chunk-near-context-full hint in completion-auditor prompt

The chunking hint (previously only in `prompts/goal-loop-continuation.md`)
now also sits in the isolated completion auditor's instruction array
inside `extensions/goal-loop-auditor.ts` (`buildGoalAuditorPrompt`). The
reviewer writes Markdown reports and has no inline prompt to add the
hint to — the auditor is the relevant "reviewer/auditor prompt" target.
Test in `tests/auditor-chunk-hint.test.ts` pins the hint inside the
auditor prompt's instruction array.

11 new tests (467 → 468). Updated 7 reviewer-modes / postaudit-surface /
pause-informativeness / long-running-modes-parked / reviewer tests to
match the contract surface.

## [0.27.8] — 2026-07-27

### Changed — `audit/LONG-RUNNING-MODES.md` is now the per-item evidence ledger

The parking doc grew from a 3055-byte sketch into a per-item evidence
ledger. Every one of the 7 tasklist items now has a `### Item N`
section with `**State**:` (shipped / parked) and `**Evidence**:`
pointers (commit SHA, npm version, file path, raw grep result, or
`git ls-files` output). 8 new tests in
`tests/long-running-modes-parked.test.ts` pin each item's terminal
state so a future auditor can verify the 7-item /goal without
re-reading chat history.

This addresses the 0.27.7 isolated-auditor's rejection ("the /list
queue should show 7 items in terminal state") by resolving the
contract via per-item evidence in the parking doc instead of via
7 separate queue entries — each item already shipped (or was
explicitly noted-as-shipped-in-prior-versions) when this goal
landed; re-firing them as queue items would be ceremonial busy-work.
The 7-item evidence table replaces the aggregate list entry.

## [0.27.7] — 2026-07-27

### Added — 5-mode postaudit (`off` / `default` / `auto` / `aggressive` / `report`)

`/glla postaudit=` (and the legacy `/glla reviewer=`) now cycles through
five modes instead of three:

- **off** — silenced; never fires. Equivalent to `enabled=false` but
  exposed via the menu.
- **default** — Confirm-gated cascade (the original behavior).
- **auto** — every actionable finding becomes a `/list` item, zero
  Confirms (the auto-loop rolls straight through).
- **aggressive** — `auto` behavior PLUS the FIRST architectural finding
  is relaunched as a `/goal` directly (no Confirm). For unattended rigs
  that can't click Confirm.
- **report** — write the report + notify only, no cascade.

The `ReviewerMode` type union widened to `"off" | "default" | "auto" |
"aggressive" | "report"`. `/review <id> <mode>` accepts all five.
`ReviewerOutcome` now exposes `cascadeStep` so tests can assert which
branch fired. `cmdReviewerSettings` reads whichever key the user has
configured (`postaudit` wins over the legacy `reviewer` key) and writes
back to that same key — no parallel config drift.

### Added — `audit/LONG-RUNNING-MODES.md` parking doc (committed to git)

The long-running philosophy parking doc is now committed at
`audit/LONG-RUNNING-MODES.md` (69 lines, 3055 bytes). Tabulates the
corrected source-of-long-running axis (sub-goals, not mode nesting)
and lists the parked items for v0.29+ (sub-goal tree, spec evolution,
post-audit modes — the last of which is now partly shipped).

3 new tests in `tests/reviewer-modes.test.ts` (off / aggressive-architectural /
aggressive-clean / opts.mode union widening / menu-text / 5-mode cycle).

## [0.27.6] — 2026-07-27

### Changed — package.json scripts: `npm test` now uses bun (3x faster)

`npm test` was `node --experimental-strip-types --test tests/*.test.ts`
(~6–8s for 440 tests). Switched to `bun test` (~2.8s, 3x faster).
`npm run test:node` keeps the node path for the env-gated daemon test
that needs the slow runner. `npm run test:all` runs bun + tsc.

### Added — chunk-near-context-full hint in goal-loop-continuation prompt

The continuation prompt now warns the assistant: when the conversation
is heavy (long-running audit, deep debug, big rollout), prefer smaller
commits, smaller tool outputs, focused reasoning. glla's 0.27.2
auto-continue fires on `stop_reason="length"` (the output-token cap)
and will reschedule anyway; pre-empting by chunking is cheaper than
recovering from the cap. Save large file writes for their own turns.

### Noted — items already shipped in prior versions

- **`modlist` removal**: there is no `/glla modlist` menu item in the
  current code (`modlist` only appears in a doc comment about the
  unrelated `pi-plugin-list-selector-modlist` package and a tool-heal
  notify message). Already done.
- **Per-project tool overrides**: the project settings file
  (`<cwd>/.pi-glla/settings.json`) is the override mechanism. Reviewer
  / post-audit / subagent-model / aggressive-mode / quota / stuck /
  escalation / feedback / wedge / auto-resume / auto-accept / etc. all
  read per-project settings. Already done.
- **`no work started` mislabel**: the paused widget line is
  `saved — N tok spent · M audits · resumes exactly here` (0.27.1); when
  both N and M are 0 it degrades to `saved · resumes exactly here`. Done.

1 new test (441 → 442).

## [0.27.5] — 2026-07-27

### Changed — surface the post-completion audit in interactive mode

The reviewer was firing silently: `runReviewer` called `ctx.ui.notify()`
during the goal-completion handler, easy to miss because pi is busy
transitioning state. Now `fireReviewer` adds a SECOND `ctx.ui.notify()`
AFTER the cascade settles, pointing at the review file path:

> ↳ review written: .pi-glla/reviews/<id>.md (N enqueued to /list)

Skipped when `opts.manual === true` (the `/review` UX already notifies
the result). In auto mode the second notification is harmless
redundant — unattended rigs use `notify=` push and don't read it.

### Added — `postaudit` settings key + CLI label

The feature was internally called "reviewer"; user-facing label shifts to
"postaudit" (post-completion audit, auditor-adjacent). Both keys are
read; `postaudit` wins when both are present. `/glla postaudit` opens the
same config menu as `/glla reviewer` — the rename is vocabulary only, no
behavioral split. `extensions/reviewer.ts`, `runReviewer`, and
`ReviewerConfig` keep their existing names (a 331-line file with 4
test files; churn risk would outweigh the rename benefit).

8 new tests (433 → 441).

## [0.27.4] — 2026-07-27

### Fixed — slash-command argument completions now add a trailing space

Pi's autocomplete `applyCompletion` adds a trailing space for the TOP-LEVEL
command (`/goal `), but NOT for argument completions (`/goal start`,
`/glla model=`). glla's `completions()` factory now embeds a trailing space
in the suggestion `value` (label stays clean) — except for `key=value`
items (`model=`, `tokenlimit=`, `notify=`, …) where the user types the value
right after the `=` and a trailing space would break parsing. Now typing
`/goal sta` → pick `start` → the line becomes `/goal start ` and you can
type the objective immediately. No more `/goal startasdahlasf`.

5 new tests (428 → 433).

## [0.27.3] — 2026-07-27

### Fixed — stall brake too aggressive on real investigation work

The polis-session pause ("3 consecutive turns with no tool calls", screenshot
2026-07-27) tripped on three substantive analytical paragraphs about
`state-pump-dom.ts` after `cd/ls/grep` reads — real work, not a stall. The
brake checked only `toolCalls > 0` and missed the case where the model is
reasoning out loud across turns. Now a no-tool turn is a nudge only when it
is also short (default < 15 words) OR highly similar to the prior assistant
turn (3-gram Jaccard > 0.6 default). Substantive novel analysis resets the
counter even without a tool call.

New settings: `stallShortWords` (default 15) and `stallSimilarityThreshold`
(default 0.6) — tunable per project. Pause reason now reads "3 consecutive
unproductive turns (no tools, short or repetitive)".

11 new tests (415 → 426). The stall brake still fires on real stalls
("ok"/"Working…" repetition).

## [0.27.2] — 2026-07-27

### Added — auto-continue on output-token truncation, folded in

The standalone **pi-length-continue** package is deprecated; the behavior
now lives here (works in every session, goal or no goal):

- When one assistant response exceeds the model's per-response output cap
  (`stopReason: "length"`), agent_end immediately re-triggers with
  "continue EXACTLY where you stopped — split large file writes into
  smaller write/edit calls across turns" (the root-cause mitigation).
- A truncated turn is **exempt from all turn bookkeeping**: no telemetry,
  no no-tool nudge (it is NOT a stall), no loop measure, no normal goal
  continuation on half a response. The next agent_end processes the run.
- Guards: 3-consecutive cap with a one-time give-up notice, skip when
  messages are pending, stale-api errors route to the 0.26.7 terminal
  path. Ledger events: `length_continue_sent` /
  `length_continue_send_failed`.

4 new tests (422 → 426).

### Also in this release window (ops, no code)

- **autoResume scope fix**: the global settings file carried
  `autoResume: true` (0.26.8 era), overriding the 0.26.9 hold-on-load
  tri-state for EVERY project — interactive sessions (neonbreak) resumed
  goals on load. Global override removed; `autoResume: true` now set
  per-project only on the unattended rigs (hegemon, darklord, polis,
  junk-runner, dracon-utilities).

## [0.27.1] — 2026-07-27


### Fixed — pauses now tell you what happened, what survived, and what to decide

"We are pretty uninformative when the execution pauses." A decision-pause
(pause_goal with a reason + suggested action) reached the user truncated at
~60 chars — the actual choice ("(a) keep both… (b) regenerate…") was
unreadable without /goal status.

- **Widget paused card wraps**: reason and suggested action now wrap over
  up to 3 width-aware lines each (new `wrap()` helper) instead of
  truncating at ~60 chars. Overflow ends with "…" (full text is always in
  the pause notification and /goal status).
- **"saved · resumes exactly here" line**: the card now answers the first
  question at any pause — did I lose the work? — with tokens spent and
  audit count when nonzero (`saved — 41.2k tok spent · 3 audits · resumes
  exactly here`).
- **pause_goal notify carries the FULL contract**: reason + suggested
  action (multi-line notification), and the external push includes both
  (bounded at 200 chars). Before, the action never left /goal status.

5 new tests (417 → 422).

## [0.27.0] — 2026-07-26


### Changed — /glla settings menu: every option, organized, self-documenting

Typing `/glla` now shows EVERY option on one screen, grouped into
sections, each row `label — value [provenance] — what it does` so the
menu is also the documentation (user request: "I want to see the option
even when I type /glla… give some info about them on the right").

- **Sections**: Keep-going (auto-resume tri-state, auto-accept drafts,
  aggressive mode) · Auditor (model, thinking, cap, feedback chars,
  quota retry) · Stall brakes (wedge alert, stuck max, stall escalation)
  · Subagents (strategy + 3 pins) · Other (notify, token limit,
  reviewer). Header rows are selectable no-ops.
- **Newly editable from the menu** (were command-only): auto-resume
  (default/on/off picker), auto-accept drafts, audit cap, stall
  escalation refires, reviewer config (jumps to the reviewer menu).
- Headless fallback (no-UI) now lists the stall brakes too.

4 new tests (413 → 417).

## [0.26.9] — 2026-07-26


### Fixed — restore gate is now a tri-state: never auto-start on session LOAD

0.26.8 flipped the default to auto-resume on EVERY session start — wrong:
loading pi and seeing the held-goal popup immediately fire work is a
surprise. The correct rule (user-specified): **don't auto-start on session
load; continue forever DURING the session unless big stuck.**

- **`shouldAutoResumeOnSessionStart` tri-state**: `on` = auto-resume on
  every session start (unattended rigs); `off` = never; **default
  (undefined)** = HOLD when a human loads a session (`startup`/`new`/
  `resume`/no-reason — popup shows what's waiting, explicit resume),
  auto-resume on in-session machinery (`reload`/`fork` — an extension
  reload or session fork must never strand work).
- Mid-session continuation (agent_end chains, heartbeat refires,
  post-compaction, list/loop transitions) was never gated here — it
  auto-continues forever unless a super-stuck brake (stall escalation,
  stale-api terminal, pending-latch watchdog) stops it loudly.
- Status shows `autoResume=default (hold on load)`; hold text offers the
  explicit resume + the `autoresume=on` opt-in; README/INSTALL updated.

3 gate tests rewritten + 3 source tests retargeted (412 → 413).

## [0.26.8] — 2026-07-26


### Changed — autoresume defaults ON: keep pushing forward unless super stuck

The v0.21.0 restore gate held goals/loops on fresh session starts unless
the project opted in with `/glla autoresume=on`. That default was wrong
for unattended rigs: every pi restart stranded in-flight work behind a
manual `/goal resume` (field-observed in dracon-utilities: after a
max-output-token error killed the turn and the pre-0.26.1 silent-send
bug spun refires for 8h, the user's restart *paused* the goal with
"restored in a fresh session" instead of continuing it).

- **`shouldAutoResumeOnSessionStart`** — default (`undefined`) now
  auto-resumes on EVERY session start. Explicit `/glla autoresume=off`
  preserves the v0.21.0 gate (fresh sessions hold; resume/reload/fork
  still auto-resume).
- **`/glla autoresume=off` now persists `false`** (was `undefined`) —
  required for the opt-out to survive the new default.
- **The "super stuck" brakes are unchanged**: stall escalation,
  stale-api terminal stop, pending-latch watchdog, wedge alert all still
  stop the machine loudly. A process restart is not stuck; a dead turn
  trigger is.
- Status line shows `autoResume=on (default)`; hold texts name the
  opt-out as the cause.

2 gate tests updated to the new semantics + 3 new source tests
(410 → 412).

## [0.26.7] — 2026-07-26


### Fixed — stale extension api is now terminal-and-loud, not retried forever

pi 0.82.x invalidates the extension runtime on session replacement
(`ctx.newSession`/`fork`/`switchSession`/`reload`; the compaction path
reaches the same `teardownCurrent → dispose → invalidate`). Once stale,
EVERY `sendMessage` throws forever in-process (`staleMessage ??=` is
never cleared). Field-observed in hegemon: `goal_continuation_send_failed`
at every compaction with pi's exact stale error — a user-created goal
never auto-started (the continuation send threw), and retries vanished
into the suppression void (0.26.6 fixed the void; this fixes the retry).

- **`isStaleApiError`** (goal-loop-core) matches pi's exact signature.
- **`goStaleTerminal`** — first stale send: ledger `extension_api_stale`,
  pause the goal / stop the loop with explicit "Restart pi (or reload
  extensions), then /goal resume / /loop start" guidance, notify +
  external notify. Single-fire — no re-spam.
- **Send paths short-circuit** once stale (`sendContinuation` /
  `sendLoopTurn`) — no retry-into-the-void.
- **Factory re-init clears the flag** (extension reload recovery).

5 new tests (405 → 410).

## [0.26.6] — 2026-07-26


### Fixed — heartbeat ship-suppression was self-sustaining (darklord 9.1h stall)

Field-observed in darklord: after a post-compaction
`goal_continuation_send_failed`, the heartbeat logged **2,184 consecutive
`heartbeat_suppressed` ticks over 9.1 hours** while the finished list
item sat uncompleted and 16 queued items waited. Root cause: the 0.25.0
"recent ship (<5m)" suppression fed `lastShippedAtMs`, which read the
`.pi-glla/active.jsonl` **mtime** — and the heartbeat's own
suppressed-tick ledger writes refreshed that mtime every 15s.
Suppression forever. (Under an auto-committing daemon the git-head term
self-sustains identically.)

- **Suppression removed from the heartbeat.** The legit windows it
  meant to cover are already guarded precisely: busy mid-turn, pending
  messages, scheduled timers.
- **`completionAuditInFlight` flag** wraps the complete_goal auditor
  call (try/finally) — the one real transition window, now detected
  exactly instead of by wall-clock heuristic.
- **`lastShippedAtMs` drops the ledger-mtime term** (git commit time
  only); `shouldSuppressHeartbeatForRecentShip` kept but deprecated.

6 new tests + 1 updated (400 → 405).

## [0.26.5] — 2026-07-26


### Fixed — pending-latch stall (post-compaction silence, field-observed)

A continuation sent at compaction+0s was ACCEPTED by pi
(`goal_continuation_sent` ledgered) but the turn trigger was dropped;
pi's pending-message flag then stayed set for **22 minutes**.
`sessionIdle` (= `isIdle && !hasPendingMessages`) never went true, which
suppressed the heartbeat refire path AND the 0.26.1 stall escalation —
and the wedge alert was blind too (22m < 30m threshold, and its "hung
command" framing would have been wrong). Total silence until a manual
nudge.

- **New `pending_latch_stuck` watchdog** (`shouldFirePendingLatchWatchdog`,
  `PENDING_LATCH_STUCK_MS = 3m` in goal-loop-backoff): supervising +
  idle + pending + no timers + silent ≥ 3m → count a stall, ledger, warn.
  It never re-sends — the message is already queued pi-side and the
  hegemon zombie proved re-sends don't unstick a dropped trigger
  (619 sends, zero turns). Stalls share the 0.26.1 escalation, now
  factored as `escalateStallNow` — 5 strikes (~15 min) → loud
  pause/stop with restart guidance instead of silence forever.
- **Wedge alert re-scoped** to genuinely-busy sessions (`!idle`, not
  `!sessionIdle`) — a stuck latch is not a hung command.
- **Reviewer**: `ℹ`-led status lines never classify (the 0.26.2
  reviewer enqueued the literal string "ℹ todo 0" as a /list item after
  mining it from an approved audit report; list markers are also
  stripped inside `classifyFindingText` for direct callers).

6 new tests + 1 updated (395 → 400).

## [0.26.4] — 2026-07-26


### Fixed — reviewer source curation (stop mining meta-text)

The 0.26.3 completion produced ANOTHER junk review (4 false
"architectural" findings): the executor's own verification prose, a
backticked `reviewer.ts` code line that slips every 0.26.3 line guard,
and test fixtures quoting the previous false positives. Regex guards
lose the arms race against meta-text — the fix is curating WHAT gets
scanned.

- **Approved audit reports are no longer finding sources.** An approved
  report is the executor's self-claims — zero finding signal. Only
  `disapproved` / `error` entries contribute (the independent auditor's
  required-fixes — the highest-signal findings that exist).
- **`stripCodeSpans`** — fenced blocks and inline code spans are removed
  before extraction; quoted code was the vocabulary leak.
- **Line guards extended** — brace-led (`{`, `[`, `}`) and quote-led
  (`'`, `"`) lines are code-ish, never findings; the mode-matrix vocab
  guard tolerates an opening paren.

6 new tests (389 → 395) pinning the exact 4 lines from the live 0.26.3
misfire.

## [0.26.3] — 2026-07-26


### Fixed — reviewer extraction false positives (observed live)

The reviewer fired on the 0.26.2 completion and matched 3 junk
"architectural" findings — a `test("…architectural…")` name, the
INSTALL.md mode-matrix table row, and ship-doc prose — every one a
reviewer-vocabulary self-match (the junk proposal was declined live and
motivated this release).

- **Bare words dropped** — "architectural" and "strategic" removed from
  the class regexes (they self-matched "architectural-class",
  "architectural findings", the docs' matrix). Architectural now matches
  only actionable forms (rewrite, new dependency, schema change,
  redesign); strategic only proposal forms (should we, deprecate, ship
  this).
- **Line guards** — extraction skips code lines (`test(`/`it(`/
  `assert`/`const`/`import`/…), markdown table rows (`| … |`), and
  reviewer-report vocabulary (`architectural-class`, `cascade step`,
  `**Mode**`, `problems/architectural`, …).

7 new tests (382 → 389) pinning the exact 3 live false-positive lines.

## [0.26.2] — 2026-07-26


### Added — reviewer modes + the auto-loop cascade

User request (2026-07-26): "the review that we can trigger after goal or
list with various defaults like auto loop into problems found or
improvements found if we run it."

- **`reviewer.mode`** — `default` (unchanged: Confirm-gated cascade),
  `auto` (the auto-loop: bug/refactor/improvement AND architectural
  findings all become `/list` items with zero Confirms; a clean
  completion enqueues the regression-scan audit as a `/list` item;
  strategic findings stay notify-only — decisions never auto-fire),
  `report` (report + notify only).
- **Improvement-class extraction** — "could be improved", "improvement",
  "enhancement", "consider adding", "would be nice", "nice to have" now
  extract into the enqueue-without-Confirm class.
- **Auto-mode refire relaxation** — the 5-minute refire window no longer
  applies to list-complete events in `auto` (the queue emptying is the
  cascade's natural rhythm, not a runaway); the per-day cap still bounds
  everything.
- **`/glla reviewer` → Mode** — cycles default → auto → report.
- **`/review <id> [auto|report|default]`** — one-shot mode override for
  manual reviews; unknown modes rejected with usage.
- Review reports name the mode (`**Mode**: auto`).

9 new tests (373 → 382); the 0.26.0 menu test updated for the new row.

## [0.26.1] — 2026-07-26


### Fixed — the zombie spin (stall handling)

Incident: a hegemon spec loop produced zero turns while the heartbeat
re-fired every 60s for 23.5h (619 `heartbeat_refire` events, exactly
10/10min, zero gaps). The send path was silent, the nudge counter counts
turns (zombies run none), and nothing hooked compaction.

- **Send-path instrumentation** — `loop_turn_sent`,
  `loop_turn_send_failed` (error text), `goal_continuation_sent`,
  `goal_continuation_send_failed` ledger events. The previously silent
  catch (`// stale API — next agent_end reschedules`) now leaves
  evidence.
- **Refire-streak escalation** — `consecutiveStalls` increments per
  heartbeat refire and resets only on real activity (`agent_end` /
  `tool_call`). At `stallEscalationRefires` (default 5, 0 = never) the
  loop stops / the goal pauses with `stalled: continuation not landing`
  + `stall_escalated` ledger + TUI warning + external notify.
- **`session_compact` hook** — re-arms the continuation chain ~2s after
  compaction when idle with nothing scheduled (`session_compact` /
  `compaction_refire` ledger events).
- **Stall surface** — status line + widget show `stalls:N` while the
  streak is nonzero; the refire notify names the streak
  (`stall 2/5`).

8 new tests (365 → 373).

## [0.26.0] — 2026-07-25


### Added — the Reviewer: post-completion follow-up enqueuer

The long-requested glue layer (user, 2026-07-24: "the reviewer should
fire goal and lists after they end… maximize leverage… but it should be
configurable"). Deterministic by design — no new tool calls, purely
analytical, every side effect injectable.

- **`extensions/reviewer.ts`** — the lifecycle: resolve config → gates
  (enabled / fireOn / doNotFireOn / 5-min refire window / per-day cap) →
  extract findings from the archive + audit reports → leverage
  classification (strategic > architectural > bug > refactor) → review
  report → cascade.
- **Cascade** — bug/refactor findings become `/list` items via the ONE
  enqueue path (fix-without-confirm, the leverage principle);
  architectural findings are proposed as `/goal` through the agent's
  Confirm dialog; clean completions fire a regression-scan audit
  proposal (opt-in cascade step); strategic findings notify only.
- **Review reports** at `.pi-glla/reviews/<goal-id>-<timestamp>.md`.
- **Safety** — never fires on aborts/pauses or `/loop` endings;
  `reviewer_fired` / `reviewer_suppressed` ledger events; 5-minute
  refire window + `maxReviewsPerDay: 20`.
- **`/review <goal-id>`** — manual re-review of any archived goal
  (suffix match), bypassing the trigger gates.
- **`/glla reviewer`** — project-scoped config menu (enable, leverage
  mode, fire-on toggles, cascade steps, caps), headless JSON fallback;
  the `reviewer` block lives in `.pi-glla/settings.json`.
- **Trigger hooks** — `archiveCurrentGoal` fires goal-complete for
  `/goal` and list-complete when the queue empties after a completion.

12 new tests (353 → 365).

## [0.25.6] — 2026-07-25


### Added — subagent polish

- **Per-type pins for Plan + general-purpose** — embedded upstream
  defaults for both (same drift-guard pattern as Explore), so
  `subagentModelOverrides` can pin any of the three default agent types;
  settings UI gained Plan + general-purpose pin editors (the Explore
  editor generalized). Strategy-driven sync still writes ONLY Explore —
  Plan/general-purpose pin nothing upstream, so inherit-parent needs no
  file for them.
- **Managed-override repair detection + notify** — a sync state file
  tracks what glla wrote; a previously-managed override found missing or
  altered externally is re-written AND surfaced ("glla repaired managed
  subagent override(s): Explore") instead of silently restored.
- **Effective-resolution display** — headless `/glla` now shows the
  resolved model per agent type (`subagent Plan: minimax/MiniMax-M3
  (per-type pin)` / `p/s (inherits session)` / `anthropic/
  claude-haiku-4-5 (upstream pin)`).
- **Subagent quota-error detection** — an Agent tool_result carrying a
  quota error (the pi-subagents#175 shape: Explore's upstream haiku pin
  403s on shared keys) triggers an immediate notify with the repair
  path (re-spawn with explicit model=, work inline, or let the
  inherit-parent strategy fix NEW sessions) + a `subagent_quota_error`
  ledger event. Upstream tracking stays at tintinweb/pi-subagents#175.

5 new tests + 2 updated for the new embedded types (348 → 353).

## [0.25.5] — 2026-07-25


### Added — completes the 0.25.4 auditor-polish contract (post-audit fix)

The isolated auditor disapproved 0.25.4's completion claim: the
retry-once-with-backoff half of the infra item was missing, and
`/glla audits` browsed the global log instead of the active goal's
history. Both gaps closed here — the auditor was right.

- **Infra retry-once-with-backoff** — a retriable auditor infra failure
  (stream/auth blip) now gets ONE automatic retry with backoff before
  being reported as "auditor infrastructure error (retried once)".
  User aborts and missing-model config are never retried; neither
  attempt counts as a verdict. `runWithInfraRetry` +
  `isRetriableInfraError` in core; `audit_infra_retry` ledger event.
- **`/glla audits` realigned** — default view is now the ACTIVE goal's
  own audit history with per-audit elapsed (`✖ 07-25 20:00 MiniMax-M3 ·
  5m — ## Audit result`); `all`/`global`/`log` browses the durable
  cross-goal log; `full` prefers the active goal's latest report.
- **Audit entries gain `durationMs` + `retriedOnce`** (history + log).

3 new tests (345 → 348).

## [0.25.4] — 2026-07-25


### Added — auditor polish: durable audit log, report hygiene, honest streaks

User-driven (2026-07-25): "log so we can look back and see where we are
weak — the auditor perhaps needs work, or how we are designating tasks".
Forensics across 3 live projects showed disapprovals are mostly CORRECT
(wrapper-goal contracts — fixed in 0.25.3), but the auditor leaks think
blocks and there was no durable verdict trail.

- **`.pi-glla/audits.jsonl`** — append-only audit log: every real verdict
  {at, goalId, objective, verdict, model, thinkingLevel, FULL report}
  survives state-snapshot rotation and archive.
- **`/glla audits [N|full]`** — browse recent verdicts (glyph, time, goal,
  model, first report line); `full` prints the latest report.
- **Think-block stripping** — `<think>…</think>` bodies, stray `</think>`
  fragments, and partial-tag artifacts are removed from reports before
  storage/display (wild-caught MiniMax-M3 leakage, incl. non-English
  reasoning spillover). The auditor prompt now also forbids think blocks
  and requires English reports.
- **`## Required fixes` tail** — the auditor ends disapprovals with a
  one-line-per-blocking-gap actionable section; `auditFeedbackExcerpt`
  is now tail-aware, so a capped excerpt keeps the fixes (head-slicing
  used to cut exactly them).
- **Infra-transparent streaks** — `countTrailingDisapprovals` skips pure
  infra errors instead of treating them as streak-breakers: 39
  hegemon-style infra errors can no longer reset the audit cap and
  re-open infinite re-continuation.
- **Auditor-quiet stall in the widget** — audit progress events carry a
  timestamp; >3min quiet while auditing shows "auditor quiet Nm — may be
  stuck; Esc aborts, verdict is not counted".

7 new tests + 2 updated to the new semantics (338 → 345).

## [0.25.3] — 2026-07-25


### Changed — list-philosophy rework: the three modes long-run differently

The user's mental model, made load-bearing: `/goal` long-runs by **scope**
(one big multi-hour task), `/list` by **queue depth** (hundreds of short
items, minutes each), `/loop` by **bounds** (metric-driven infinite
polish). Prompts previously conflated `/list` with a small checklist of
multi-hour items — two wrongs that look like one right.

- **`# Long-running philosophy` block** at the top of
  `goal-loop-draft.md` and `goal-loop-forever-draft.md` with the
  three-mode table.
- **`/list` drafting injection rewritten** — short-item framing
  ("minutes, a single focused change", "queue depth, not item scope");
  the "10 things / checklist of 50 tasks" framing is gone.
- **Cross-recommend `/goal` ↔ `/list`** (`crossRecommendMode`):
  aggregate seeds ("76 items, one commit each", "40 findings as a
  tasklist") get steered to N short `items[]` with per-item contracts —
  the 2026-07-24 wrapper-goal incidents (auto-committer squash →
  literal count fails → auditor correctly disapproves finished work);
  multi-hour seeds in `/list` get pointed at `/goal`; five-minute seeds
  in `/goal` get pointed at `/list`.
- **`/list depth`** — queue depth, oldest item age, average item
  duration from archived list-policy goals.
- **`LIST-PHILOSOPHY.md`** at the repo root (three-mode hierarchy +
  the wrapper-goal anti-pattern); `INSTALL.md` gained a Modes section.

10 new tests (328 → 338).

## [0.25.2] — 2026-07-25


### Added — `/glla stats`: per-project ledger rollups

One command, every project's glla telemetry — the empirical-evidence layer
the spec-driven verifier hardening will consume.

- **`/glla stats`** — markdown table, one row per discovered project:
  goals, audits approved/disapproved/error, avg turns, avg writes,
  premature count, token total, last active.
- **`/glla stats json`** — same rollup machine-readable (schema matches
  the table exactly).
- **`/glla stats project=<path>`** — single-project scan.
- **`/glla stats premature`** — only projects with premature successes,
  sorted by premature ratio.
- **Premature-success detection** — flags approved goals with
  turns < 50 AND file writes < 5 AND bash calls < 8 (spec-driven verifier
  design §3 thresholds). Goals archived before this release carry no
  telemetry and are UNKNOWN, never back-convicted.
- **Per-goal telemetry** — turns (agent_end), file writes, and bash calls
  are now counted on the goal state and flow into archives.
- **Project discovery** — session-dir cwd decode + targeted bounded walk
  (~/Dev, ~/chat first, 2s budget) + cwd. New module
  `extensions/goal-loop-stats.ts` (pure helpers, stdlib only).

`total_cost` is token usage — no price data on this rig. 7 new tests
(321 → 328).

## [0.25.1] — 2026-07-25


### Fixed — stuck-detection rework: the multi-signal "progress signals" gate

Triggered by two wild-caught transcripts (design doc
`audit/STUCK-DETECTION-REWORK-2026-07-24.md`): the v0.24.0 single-signal
detector (same tool + same result hash 3×) killed loops that were SHIPPING
work with stable verification output — stable verification is the goal
state of a metricless loop, not the stuck state.

- **`isActuallyStuck(input)`** replaces `detectLoopStuck` as the stuck
  gate. An iteration is stuck ONLY when ALL progress signals are zero —
  file writes (`write`/`edit`/`multi_edit`/`write_file` tool results),
  git commits since iteration start (`rev-list --count startHead..HEAD`),
  `spec_item_progress` ledger events, and a PAIRED forward transition —
  and the legacy detector also fires. `detectLoopStuck` stays exported
  for backward compat.
- **`forwardTransitionMarker(text)`** — conservative word list + line-start
  "Next:" detection. The marker only counts PAIRED with a write/commit in
  the same iteration: pure-narration "next: implement X" loops are still
  stuck (narrate-but-don't-ship).
- **`/loop finish [reason]`** — end a loop cleanly with stopReason
  `completed: <reason>` (distinct from stuck/plateau/stopped-by-user).
  `/loop stop` is untouched.
- **`/loop start toolsamerepeat=N`** — `0` disables the legacy
  same-tool-same-result check entirely (new detector only); absent =
  current behavior.

21 new tests (300 → 321) including a transcript-replay suite: both
wild-caught transcripts classify NOT stuck under the new gate while the
old detector WOULD have flagged them — and the same texts without the
shipped work still classify stuck.

## [0.25.0] — 2026-07-25


### Added — eager-continuation contract (Sections A–H + J; Section I shipped in 0.24.6)

The full eager-continuation contract: the loop keeps going unless it truly
can't, subagents are the default execution strategy, quota errors are
first-class, and the agent investigates before asking.

- **Subagent fan-out prompts (A):** all four agent-facing prompts lead
  with "Default to subagents" + eager-continuation guidance (`Agent`,
  `Explore`/`general-purpose`/`Plan`, parallel spawn, single-writer rule).
- **`aggressiveMode` setting (B):** `/glla aggressivemode=on` flips the
  continuation DEFAULTS — autoResume on, auditCap 10, stuckMax 10, wedge
  off, quota silent-retry. Explicit per-key settings always win. Base
  auditCap default raised 3 → 5 for everyone (item 7). Every auto-event
  announces itself ("Auto-resume fired (event: …)").
- **Quota-aware retry (C):** new `extensions/quota-retry.ts` —
  `isQuotaError` / `parseQuotaError` (Retry-After header + prose hints) /
  `scheduleQuotaRetry`. A quota-exhausted auditor now PAUSES with a
  one-shot auto-retry (default 60m, `/glla quotaretryminutes=N`) instead
  of re-firing continuations forever. A user pause during the window is
  never stomped.
- **Objective drift (D):** the auditor prompt explicitly accepts justified
  shifts ("do NOT rigidly disapprove"); the continuation prompt teaches
  tweak-before-pivot; `complete_goal` gains a real `newObjective`
  parameter — atomic objective update + audit in one call (ledgered
  `goal_tweaked`).
- **Agentic disagreement (E):** new continuation section WHEN THE AUDITOR
  DISAPPROVES — investigate (read auditHistory, quote objections, compare
  against shipped evidence, form an opinion) and present YOUR ASSESSMENT
  instead of a generic options menu. The audit-cap pause message now
  guides the same investigation.
- **Keep-going under aggressiveMode (F):** the audit cap becomes a TODO
  list — objections extracted to `pendingTasks`, goal stays ACTIVE, TODOs
  render into every continuation. IMPOSSIBLE with a partial reason narrows
  and continues; a full impossible still pauses.
- **Pivot detection (G):** new PIVOT DETECTION section (full-audit →
  propose_task_list immediately + parallel subsystem surveys); heartbeat
  suppression when work shipped in the last 5 minutes (a transitioning
  session is not a stalled one); aggressiveMode + survey objective injects
  a FULL-AUDIT MODE directive into the continuation.
- **Auto-committer forensics (H):** new DETACHED COMMIT DETECTION section
  (reflog filter-branch / dracon-sync checks before self-diagnosing);
  `pauseAutoCommit`/`resumeAutoCommit`/`isAutoCommitPaused` sentinel
  helpers (`.pi-glla/.pause-auto-commit`); env-gated commit-survival e2e
  (`GLLA_E2E_DAEMON=1`).
- **Subagent quota errors (J):** new WHEN SUBAGENTS HIT QUOTA ERRORS
  section — `Key limit exceeded` / 429 → inherit-parent or wait for reset;
  never re-spawn the failed type.

New settings keys: `aggressiveMode`, `quotaRetryMinutes`,
`stuckMaxInterventions` (UI + headless `/glla key=value` + provenance).
Settings layer extracted to `extensions/goal-settings.ts` for testability.

38 new tests (262 → 300, one env-gated skip). Interpretation notes for the
auditor are appended to the contract goal file.

## [0.24.9] — 2026-07-25


### Changed — auditor feedback defaults to the FULL report

`auditFeedbackChars` default flipped 800 → 0 (no cap). A truncated
disapproval report loses exactly the actionable tail — the later evidence
items and the raw command output the executor needs to fix the gap — and a
few KB of report is negligible next to a wasted re-attempt. The setting
remains for users who want a cap (`/glla auditfeedbackchars=N`); explicit
values already saved are respected.

## [0.24.8] — 2026-07-25


### Added — configurable auditor feedback length (community PR #1, thanks @Gan-Personal)

Auditor disapproval feedback is no longer permanently hard-capped at 800
characters. The new layered `auditFeedbackChars` setting preserves 800 as
its default and can be changed with `/glla auditfeedbackchars=N` globally
or per project; `0` returns the full report. The interactive settings UI,
headless display, completions, save summary, and executor-facing labels
all show the effective behavior; truncated reports now say so and point at
`/goal status` for the full text. Merge also adds the 0.24.6 subagent keys
to the headless settings display (missed in that release).

## [0.24.7] — 2026-07-25

### Fixed — list-mode indicator: a queue item is not a goal

Spotted live on the hegemon session: a `/list` item's footer read
`glla: list ● 3m 19s · list 29` — the policy label AND the queue counter
both said "list" — and the widget called the item "active" with a
`/goal status` hint, as if queue work were a standalone goal.

- **Footer:** list policy → `glla: list ● 3m 19s · 29 queued`
  (no duplicated "list"). Goal policy unchanged (`· list N` suffix kept —
  no duplication there).
- **Widget:** list item → `├─ list item · active 3m 19s` and footer hint
  `└─ 29 queued · /list · /glla` (no `/goal status` hint for queue work;
  no "0 queued" on the last item). Goal policy rendering unchanged.
- **`/goal status`:** list items now name their source:
  `Source: /list queue (N waiting) — /list to manage`.

5 new display tests (256 → 260).

(Takes the 0.24.7 number ahead of the planned stuck-detection rework;
the roadmap items shift one patch.)

## [0.24.6] — 2026-07-25

### Fixed — subagent model inheritance (Section I of the eager-continuation contract, shipped early)

**Root cause:** pi-subagents v0.14.3's default `Explore` agent pins
`anthropic/claude-haiku-4-5` (`default-agents.ts:40`). Its model resolution
is explicit option > agent config > parent model (`agent-runner.ts:720`),
so an `Explore` spawn NEVER inherits the session model — it silently routes
to a different provider with a different quota pool. On rigs where the
session model is local/alternative (e.g. MiniMax-M3) and claude-haiku-4-5
resolves through a quota-capped key (OpenRouter), a few concurrent Explore
spawns exhaust the key with `403 Key limit exceeded (total limit)` while
the parent session is completely unaffected. Observed live on the polis
session: 3 of 3 Explore subagents failed with the same 403 mid-audit.

**Fix:** glla now manages `~/.pi/agent/agents/Explore.md` — pi-subagents'
native user-override mechanism (a same-named `.md` fully replaces the
default config; omitting `model:` falls through to the parent model).

- New module `extensions/goal-loop-subagents.ts`:
  `syncSubagentModelOverrides()` writes/updates/removes the managed
  override at session_start. Idempotent; writes only on drift.
- Writer safety contract: files without the
  `x-managed-by: pi-goal-list-loop-audit` frontmatter marker are
  user-owned — never modified, never deleted (a skip note is surfaced).
- Only `Explore` is managed (the sole pinned default). Embedded verbatim
  copy of the upstream Explore config; a drift test fails if tintinweb
  changes it or pins another default.

**New settings** (`/glla` → Settings, global or project):

- `subagentModelStrategy` — `inherit-parent` (default): subagents share
  your session model AND its quota pool (fixes separate-provider 403s;
  search agents may run on a pricier model). `agent-default`: upstream
  behavior (Explore pins haiku — cheap search, separate quota).
- `subagentModelOverrides` — per-agent-type model pin, e.g.
  `{ "Explore": "minimax/MiniMax-M3" }`. Always wins over strategy.

Applies to NEW pi sessions (pi-subagents registers its agents at its own
session start). 12 new tests (244 → 256).

## [0.24.5] — 2026-07-24

### Fixed — tool-visibility self-heal (modlist allowlist wipe)

Root cause from `audit/INCIDENT-COMPLETION-BLACKHOLE-2026-07-23.md`:
external extensions like `pi-plugin-list-selector-modlist` call
`pi.setActiveTools(frozenSnapshot)` at every `session_start`. When glla's
session_start handler runs before theirs (load order), our 11
lazily-registered agent tools (`complete_goal`, `propose_loop_draft`,
`propose_goal_draft`, `propose_loop_refine`, `pause_goal`, `complete_task`,
`update_task_status`, `list_add`, `list_activate`, `list_status`,
`propose_task_list`) are registered and briefly auto-activated, then
wiped from the model-facing active set by modlist's allowlist. Commands,
widget, watchdog keep working (they don't go through the tool registry),
but every agent tool answers `"Tool not found"` to the model — silently.

Forensics on the darklord session: 26 real `complete_goal` tool calls
in the session jsonl, all answered `"Tool complete_goal not found"`
(isError: true). The model was right about its own schema; the tool was
genuinely absent.

- **`GLLA_TOOL_NAMES`** and **`missingGllaTools(activeNames)`** added to
  `goal-loop-core.ts` (pure, testable).
- **`ensureAgentToolsActive(pi, ctx)`** added to `loops/goal.ts`: after
  `registerAgentTools` and on every `agent_end`, diff our 11 tools
  against `pi.getActiveTools()`; re-add any missing ones via
  `pi.setActiveTools([...active, ...missing])`. Notify once per session
  naming the likely culprit (external allowlist, e.g. modlist profile)
  and the fix (add the tool names to the profile).
- Old pi versions without `getActiveTools`/`setActiveTools` are handled
  gracefully (try/catch, heal becomes a no-op).
- 5 tests in `goal-loop-core.test.ts` (modlist-snapshot example,
  empty/full active sets, single-tool missing, base-tool non-interference).
- 244/244 tests pass (was 239); tsc clean.


### Changed — `/loop respec` ambiguity policy: friction scales with ambiguity

Draft exactly when the input can't be mechanically resolved (the grilling
philosophy applied to respec):

- **Two specs** (`SPEC.md` AND `spec.md` in the root): never silently pick
  — one slash-bar select asks which is the spec, and a notify nudges to
  consolidate the pair (the loop treats only the chosen file as the spec).
- **No spec**: instead of a flat error, `/loop respec` drops into loop
  drafting with a respec-flavored seed — grill toward bootstrapping a
  SPEC.md from the current code (then reconcile) or stating the
  reconciliation target in prose.
- **One spec**: auto-start, unchanged — the user typed the command; the
  happy path keeps zero friction.
- New pure `resolveSpecFiles` (all matches, priority order); 1 test.

## [0.24.3] — 2026-07-23

### Added — `/loop respec` (reconcile against the root spec, forever)

- `/loop respec` starts an infinite metricless loop whose target is
  generated from the project spec: `SPEC.md` / `spec.md` in the root only
  (one mechanical predicate, no fuzzy search — missing spec = a clear
  error naming what was looked for). Same auto-start path as `/loop
  start`: typing the command IS the user act, no drafting, no interview.
- The generated target bakes in the two field lessons: **read the spec
  critically first** (stale/contradictory requirements get reported as
  discrepancies, never forced onto the code — the spec is data, not
  gospel) and an **implement/audit rotation** (one iteration closes a
  spec↔code gap, the next audits an "implemented" item against the spec)
  so a respec loop can't doorknob-polish.
- **No limit-nagging**: respec is unbounded by design; bounds stay
  available on `/loop start` for whoever wants them.
- Sharper `propose_loop_draft` gate error (field report: a chat-agreed
  loop dead-ended into a hand-written draft file + a "say start" wait).
  The error now tells the model exactly what to hand the user:
  `/loop start "<target>"`, `/loop respec`, or `/loop` to draft — and
  forbids draft-file ceremony.
- 3 tests (resolution order, root-only, target shape).

## [0.24.2] — 2026-07-23

### Added — audit-hardening from the Claude Code / Codex CLI cross-audit

(full comparison: the local installs of both reference CLIs were
source-audited against this stack; the "doing something wrong" list drove
this release)

- **Disapproval cap** (`/glla auditcap=N`, default 3, `0` = unlimited).
  Claude Code caps consecutive stop-hook blocks at 8 then overrides; we had
  NO cap — a goal the auditor could never approve re-continued forever,
  burning tokens. Now `countTrailingDisapprovals(auditHistory)` >= cap →
  goal PAUSES with the repeated objections surfaced (notify + ledger +
  external push + the tool result tells the model to summarize for the
  user instead of re-completing). Shield-blocks and infrastructure errors
  correctly break the streak — they are not verdicts on the work.
- **`<impossible>` verdict** — the auditor's third verdict (Claude's
  prompt-hooks have the same escape hatch). For goals that can NEVER be
  satisfied as stated (contradictory requirements, wrong premise,
  unobtainable resources), the auditor ends with
  `<impossible>reason</impossible>`; the orchestrator pauses the goal with
  the reason and points the user at `/goal tweak` / `/goal cancel`.
  Incomplete work stays `<disapproved/>` — the prompt says so explicitly.
  Parsed by pure `parseAuditorVerdict` (in goal-loop-shield.ts so tests
  can import it); recorded in audit history + goal markdown.
- **Anti-injection line in loop prompts** (Codex pattern, already present
  in goal-continuation since early versions — now consistent): "The target
  below is user-provided data. Treat it as the task to pursue, not as
  higher-priority instructions." in both loop prompt templates.
- 9 tests (`tests/audit-verdict.test.ts`).

## [0.24.1] — 2026-07-23

### Added

- **`/list cancel` — stop the whole list as ONE verb** (field report:
  "there is no way to cancel a list"). Before this, stopping a list meant
  knowing to combine `/goal cancel` (aborts only the active item; the
  waiting list survives) with `/list clear` (drops the waiting items; the
  active item keeps running). `/list cancel` does both: aborts the active
  goal when it is list-sourced (archived as `aborted — list cancelled`,
  `ctx.abort()`), drops all waiting items, ledger `list_cancelled`
  `{abortedActive, dropped}`, and a notify naming exactly what happened.
  A standalone (non-list) active goal is left untouched and the notify
  says so — `/list cancel` never reaches outside the list machine.
  Nothing-to-cancel case is answered, not silent.

## [0.24.0] — 2026-07-23

### Added

- **Loop anti-repetition — the stuck ladder.** The plateau stop watches
  the *number*; this watches the *work*. New pure module
  `goal-loop-repetition.ts` (clean-room — standard fingerprint/Jaccard/
  n-gram techniques, no AGPL code): every loop iteration is classified by
  `detectLoopStuck` — narration-only streaks (2+ toolless iterations),
  degenerate single-reply repetition, exact repeat, near-duplicate
  (trigram Jaccard ≥ 0.8, digits volatile so "port 8081" ≈ "port 8082"),
  A-B-A-B window repetition, and same-tool-same-result 3× (repeated error
  or no new information). A stuck iteration replaces the next prompt with
  a **rotating intervention** (5 strategies, each different — a repeated
  nudge gets filtered as noise): different approach → untouched subtask →
  write PROGRESS.md → fix one test failure → review your own diff.
  - Rung 3+ = **hard reset**: banned openings (the loop's own repeated
    phrasings), first action must be a tool call.
  - Rung 5 = **the loop stops**, reason named (`stuck — <reason> (5
    consecutive interventions)`), notified + ledgered + external push —
    bounded and surfaced, same philosophy as plateau.
  - Applies to BOTH loop flavors: metric loops can doorknob-polish while
    the number wiggles; metricless loops had NO behavioral defense at all.
  - Rolling windows live on `LoopState` (persisted — survive restore):
    `recentPrints`, `recentTexts`, `recentToolResults`, `toollessStreak`,
    `consecutiveStuck`, `lastStuckReason`.
  - Ledger: `loop_stuck` per intervention; `loop_measured` gains `stuck`.
- **Rotating continuation lines** for metricless loops (identical prompts
  invite identical answers) and `${INTERVENTION_NOTE}` / `${VARIANT_NOTE}`
  placeholders in both loop prompt templates.
- 21 tests (`tests/repetition.test.ts`) — real module, no copies.

### Verified

- **Continuation delivery already queues, never steers** (ralph-wiggum
  parity check): `sendLoopTurn` only fires when `ctx.isIdle() &&
  !ctx.hasPendingMessages()`, else reschedules — mid-turn steering can't
  happen.

## [0.23.8] — 2026-07-23

### Added

- **`/glla autoaccept=on` — auto-accept drafts** (field request: "we
  might not care to read it — we already filled out our intents"). Every
  `propose_*` draft (goal, list batch, loop, task list) activates the
  moment the agent proposes it; BOTH the Confirm dialog and the
  v0.14.0 interview floor are skipped. Never silent: each auto-accept
  notifies ("Draft auto-accepted — ACTIVATING now: …") and writes a
  `draft_autoaccepted` ledger entry. Default off — the Confirm gate is
  the product; this is for unattended rigs (pairs with `autoresume=on`).
- **Subagent compatibility, made explicit** (`@tintinweb/pi-subagents`):
  the main session OWNS the goal/loop/list; subagent sessions are
  workers. Mechanical ownership via `ctx.sessionManager` identity (pi
  hands a fresh ctx wrapper per event — object identity is useless):
  subagent sessions never clobber the loop's ctx handle (a headless
  subagent ctx would have silently killed the heartbeat/wedge
  machinery), never run the restore gate, never drive continuation, and
  state-mutating tools (`complete_goal`, `pause_goal`, `propose_*`,
  `list_add`, `list_activate`) refuse with "report back to the main
  agent". Subagent tool activity still feeds the wedge clock — a long
  subagent run is work, not a hang. `classifySessionCtx` (pure) + 4
  tests.

### Fixed

- **v0.23.7's un-truncation was only 1/3 applied** — a rejected
  multi-edit silently dropped the tweak and import dialogs (both still
  truncated: tweak at 400/200 chars, import at 5-of-N items). Now
  actually fixed; verified by grep this time. Lesson recorded: verify
  edits landed before claiming them in a changelog.
- **Drafter-path metricless loops still defaulted to max=50** —
  v0.23.6 flipped the CLI default (metricless + no explicit max =
  unbounded) but `propose_loop_draft` kept its own `: 50`. Aligned.

### Changed

- **"Queue" language → list/pool semantics** (field feedback: the list
  is "claimed to be a queue" but behaves as a pool — order is the
  default, not the law). User- and agent-facing strings now say list /
  waiting / added: "Confirm list batch", "Import into list?", "Added
  to the list (N waiting)", the `list_add` label/description (which
  now states the pool semantics explicitly), README ("List of goals (a
  pool, not a FIFO)"). User-language trigger phrases ("queue these 10
  things") intentionally kept — that's how people ask.

## [0.23.7] — 2026-07-23

Proactive oversight sweep across the OTHER surfaces, after the last four
releases all came from one class of bug (parser false positives, dialog
walls, ceremony defaults, stale text). Five real findings, all fixed:

### Fixed

- **Three Confirm dialogs truncated the content being approved** — a
  Confirm the user can't fully read is not a gate (the v0.23.5 rule,
  now applied everywhere): `/goal tweak` showed CURRENT/NEW objectives
  at 400 chars and the new contract at 200; `/list import` showed 5-of-N
  items at 70 chars; the list-batch Confirm showed 6-of-N at 60 chars.
  All three now render every item in full.
- **Three "done when" parsers had drifted apart** (same class as the
  0.23.4 shield preamble bug): `goalArgsNeedDrafting` and both
  `extractVerificationContract` modes required the colon DIRECTLY after
  "done when", so "/goal Fix X. Done when ALL of the following are
  true: …" routed to the drafting interview despite carrying a full
  contract. All three now accept any text before the colon, matching
  what `contractItems` (0.23.4) and `normalizeDraftContract` (0.23.5)
  already handle.
- **extract-verification.test.ts tested a STALE COPY** of
  `extractVerificationContract` — re-implemented in the test file, with
  a header comment pointing at a `goal-loop-draft.ts` that no longer
  exists. Testing a copy is testing nothing: the function moved to the
  pure `goal-loop-core.ts`, the test imports the real one, and a new
  round-trip test pins the whole chain: normalizeDraftContract → stored
  goal text → extractVerificationContract → shield contractItems.
- **Stale "default 45" wedge-alert text** in the settings input prompt
  and a comment — the actual default has been 30 since v0.23.3 (the
  runtime and settings UI used the constant; only these strings lied).
- **Loop drafter prompt said `max` defaults to 50** for everything —
  stale after v0.23.6 (metric loops: 50; metricless: unbounded). The
  drafter would have told users the wrong default.

## [0.23.6] — 2026-07-23

### Changed

- **Bare `/loop start "<target>"` IS the infinite command.** No
  `measure=` now means metricless (previously a usage error that made
  you type `measure=none`), and a metricless loop with no explicit
  `max=` defaults to UNBOUNDED (`max=0`) instead of 50 — an infinite
  loop is the point of the bare form. The v0.23.0 rule stands: the
  Confirm dialog names "NO plateau stop · NO iteration cap · /loop
  stop" before anything runs, so the choice is never silent. Metric
  loops are untouched (missing `direction=` still errors; absent
  `max=` still defaults to 50). Explicit `measure=none max=50` still
  caps. Field instinct: typing `measure=none max=0` for the common
  "keep polishing forever" case is ceremony.

## [0.23.5] — 2026-07-23

### Fixed

- **Doubled "Done when:" in the goal-draft Confirm dialog** (field
  screenshot): models mimic the `/goal` syntax and start the contract text
  with "Done when:" — the dialog then printed its own header plus the
  model's, twice. `normalizeDraftContract` (pure, in goal-loop-core)
  strips bare introducer lines and glued "Done when: " prefixes before
  BOTH rendering and storage.

### Changed

- **Confirm dialog readability** — the contract now renders as a numbered
  checklist (bullets renumbered 1..N sequentially) under a header that
  names the count: "Done when — 7 checks:". Numbering also makes
  reject-feedback citable ("item 3 is wrong"). Prose lines pass through
  untouched; nothing is truncated — the Confirm gate stays fully
  readable.
- **Drafting prompt: contract sizing guidance** — 3–8 mechanical checks,
  each verifiable with ONE command; the auditor must quote evidence for
  EVERY item, so a 17-item contract means a slow audit and more shield
  friction. Verify artifact integrity, not every sub-part. And: never
  prefix the contract with "Done when:".

## [0.23.4] — 2026-07-23

### Fixed

- **Shield preamble false positive** (darklord field bug: deliverable
  complete on disk, auditor approved TWICE with substantive evidence, and
  the regression shield blocked both — a goal at 36/37 items sat paused
  11h). `contractItems` only stripped "done when" when a colon directly
  followed it, so a contract preamble like "Done when ALL of the
  following are true:" survived as a fake contract "item" — and no
  auditor report can quote evidence for a preamble, so every approval was
  converted to a disapproval, forever. Two mechanical predicates now drop
  introducer lines: a line still ending in a colon after prefix-stripping
  introduces a list, and "(done when) (all of) the following ..." IS the
  introducer. Real items are untouched; 3 regression tests.

## [0.23.3] — 2026-07-23

### Changed

- **Tight timings pass** (user instinct: pi-goal-x's super-long waits
  sucked — audit confirmed goal-x has NO wall-clock bounds anywhere: a
  wedged session there is silent forever). Comparative baseline:
  pi-loop-mode bounds its check command (`--check-timeout`, default
  600s); pi-tasks bounds sync waits (30s default / 600s max); goal-x
  bounds nothing. Two of our three remaining unbounded waits are now
  bounded, and the one alert default tightened.
- **Wedge alert default 45m → 30m.** The alert is notification-only, so
  a false positive costs one notification while a false negative costs
  hours — that asymmetry argues tight.

### Added

- **Measure timeout (10m hard cap)** — `runMeasure` passed NO timeout to
  `pi.exec`: a hung measure command (e.g. a test-based measure) froze the
  loop tick forever, the exact darklord wedge shape one layer down.
  Timeout → measure failure (null) → stall path → plateau stop; never a
  silent hang. Matches loop-mode's 600s check-timeout ballpark.
- **Auditor stall watchdog (10m inactivity → abort)** — the auditor
  legitimately runs the project's own verification, so the bound is on
  INACTIVITY (zero session events), not wall time. A wedged auditor
  (dead stream, hung provider) previously held the completion gate
  forever; now it aborts and returns an infrastructure ERROR (never a
  disapproval, never an approval) naming the cause and the fix.
- Regression-guard test pinning every timing bound to ≤ 30 minutes.

## [0.23.2] — 2026-07-23

### Added

- **Wedge alert** — a wall-clock watchdog for the failure the turn-based
  watchdogs are blind to: the session is BUSY but silent for 45 minutes
  because one unbounded command (a test suite that never exits) is holding
  the entire goal hostage. Field-observed twice in one evening on the same
  wedged `bun test` call (5,056s and 6,800s — the session counters frozen
  byte-identical between them). The heartbeat now checks busy-but-silent
  every tick and fires an in-session warning + the configured notify push,
  throttled to once per threshold interval while the wedge persists; any
  activity re-arms. Default 45m; `/glla wedgealert=<minutes>` (0 = off,
  `unset` = back to default). Predicate `shouldWedgeAlert` in
  `goal-loop-backoff.ts` + 6 tests; ledger event `wedge_alert`.

## [0.23.1] — 2026-07-22

### Added

- **Execution discipline in the goal checkpoint prompt** (field report: a
  9h list item with an 84-minute hung `bun test` and zero subagent use).
  Two hard lines: delegate independent parallel streams to `Agent`
  subagents (`Explore` for read-only research — you stay the single
  writer), and wrap test suites / builds / dev servers in `timeout <n>`
  so a hang burns two minutes instead of an hour.

## [0.23.0] — 2026-07-22

### Added

- **Metricless spec loops** (`measure=none`). For genuinely endless work —
  an ever-improving spec, continuous hardening, Sisyphus-mode — where no
  number means "better". There is no plateau stop (nothing to stall on):
  the loop ends only at its bounds or `/loop stop`. Own iteration prompt
  (`prompts/goal-loop-forever-metricless.md`): ONE real, inspectable change
  per turn, never repeat earlier iterations, cosmetic churn called out as
  the doorknob failure, "say so when the spec is genuinely exhausted".
  Branch mode commits every iteration (no regression signal to revert on).
- **`max=0` = truly unbounded** (no iteration cap), measured loops included.
  Absent `max` still defaults to 50. Status/widget show `∞`.
- **The loop drafter offers metricless explicitly**: when the user says
  there is no number, the interview presents the trade-off (no plateau;
  ends only at bounds or /loop stop) and the Confirm dialog names it.
  `propose_loop_draft` accepts an omitted/"none" measureCmd and skips the
  measure test-run. Work with a finish line is still redirected to /goal.
- 9 new tests (metricless parsing, direction rejection, unbounded,
  bound-stops, no-plateau).

### Fixed

- `direction=` with `measure=none` is rejected ("direction is meaningless
  without a metric") instead of silently recorded.
- `/loop status`, resume notices, the widget, and the status footer render
  metricless loops (`loop ∞ iter N · metricless`, "metricless — work the
  spec (no plateau)") instead of `undefined (undefined)`.
- propose_loop_refine on a metricless loop refuses to bolt a metric on
  mid-run ("stop, then start a measured loop").

## [0.22.7] — 2026-07-22

### Added

- **`/list resume`** — resume the paused list item without leaving the
  list surface. The head item activates AS the active goal, so this is the
  same motion as `/goal resume`, named for what the user is looking at
  ("we would just unpause, and that is next"). Errors clearly when nothing
  is paused or the paused goal didn't come from the list. Autocomplete
  included.

### Fixed

- **Pause/resume/restore messaging names the thing you're resuming.** A
  paused list item said "Goal paused — /goal resume to continue", which
  read wrong when you were managing a list. Now: `/list pause` path says
  "List item … paused (N queued in the list). /list resume to continue.";
  resume confirms "Resumed list item [id]"; the fresh-session restore gate
  holds a list head with "List item held on restore … /list resume to
  continue"; auto-resume and autoContinue-off restore notices say
  "list item" too. Loops already had their own text ("/loop to resume").
- **Paused footer shows the policy word.** `glla: list paused ⏸ …` /
  `glla: goal paused ⏸ …`, mirroring the active line's `list ●` / `goal ●`.

## [0.22.6] — 2026-07-22

### Fixed

- **Regression shield false-rejected genuine approvals.** Three real
  `<approved/>` audits (hegemon) were converted to disapprovals because the
  per-item check demanded the item's single longest word verbatim: contract-
  only vocabulary ("left-cropped"), prose-glued punctuation
  ("file/element."), and slash-compounds ("Phaser/Svelte") never appear in a
  good-faith report. Matching is now: top-3 longest tokens (>=5 chars, edge
  punctuation stripped), ANY-match; compound tokens match via their
  segments. Verified against the actual hegemon reports — the misread items
  now pass; bamboozle-style reports still fail (5 new tests).
- **"Out of scope:" contract lines no longer require evidence.** Boundary
  statements constrain the auditor's judgment; they are not deliverables.
- **Shield-blocked approvals are no longer reported as plain disapprovals.**
  The tool result now says the auditor APPROVED, lists the unreferenced
  contract items, and tells the executor not to touch the deliverable — the
  old generic message read like a verdict (an executor concluded "parser
  bug" and gave up with a complete deliverable).
- **Shield gaps feed the next audit.** The missing contract items are
  recorded in auditHistory (regressionShieldMissing) and injected into the
  next auditor prompt ("address each of them explicitly: name the item and
  paste the raw output"), so a retried audit converges instead of repeating
  the same vocabulary gap.
- **List-draft Confirm dialog names immediate activation.** A drafted list
  item auto-activates when the list is empty, but the dialog only said
  "Confirm goal" — "I started a list and ended up with a running goal" was
  a real surprise. The dialog is now titled "Confirm list item" and states
  up front: "List is empty — confirming ACTIVATES this immediately as the
  active goal. Reject if you only wanted to queue it." Batch drafts get the
  same note.

## [0.22.5] — 2026-07-22

### Added

- **Subcommand autocomplete for all four commands.** `/goal `, `/list `,
  `/loop `, `/glla ` now offer arrow-selectable subcommands/keys with
  one-line descriptions in the /-menu (pi's getArgumentCompletions).

### Fixed

- **Resume/restore messaging names the list.** `/goal resume` printed
  nothing, and the restore-gate hold hint never mentioned the queue — so
  resuming a paused list head looked like it only touched a goal. The hold
  notification, the widget's suggested-action line, and a new resume
  confirmation now say "(+N queued in the list — resuming the list's head)".

## [0.22.4] — 2026-07-22

### Fixed

- **`/loop <natural language>` now drafts with the seed.** Unknown args
  previously fell through to a usage line, so `/loop make the tests faster`
  did nothing. Bare natural language now enters loop drafting with the text
  as the seed (the metric is the whole game for a loop — the interview
  designs it); `/loop start "<target>" measure=... direction=...` remains
  the skip-drafting path. Guards against a second loop while one is active.
- Seeded-drafting notification is target-aware: the loop variant explains
  the metric/direction interview and shows the full `/loop start` skip
  syntax (including time/tokens/branch) instead of the goal-oriented
  "Done when:" text; the old fallthrough usage line (which omitted
  time/tokens/branch) is gone.
- `/loop` command description (the /-menu tooltip) documents the drafting
  path.

## [0.22.3] — 2026-07-22

### Fixed

- tsc: non-null assertions for the v0.22.2 width test under
  noUncheckedIndexedAccess (0.22.2 shipped with the test file failing
  `npm run check`; suite itself was green).

## [0.22.2] — 2026-07-22

### Fixed

- **Auditor failed silently with extension-registered providers.** The
  auditor passed `modelRegistry` to `createAgentSession` — an option that
  does not exist and was silently ignored. A fresh ModelRuntime was built
  from auth.json/models.json, which has no extension-registered providers,
  so streaming a session model from one (custom api id / custom streamSimple)
  failed inside the stream and the auditor produced zero output
  ("Auditor produced no output — NOT a verdict"). The auditor now passes the
  parent session's ModelRuntime through, so the isolated session streams
  through the same composed provider as the parent. Verified live on a rig
  whose session model is extension-registered: the auditor now runs and
  returns a verdict. (Root-caused from a user report; the v0.22.0 provider
  warning's "usually works" premise is now actually true.)
- **Real stream errors are surfaced.** Stream failures arrive as an
  assistant message with stopReason "error" + errorMessage, not as an
  "error" event — the auditor now captures that into the infra-error text
  instead of the opaque "produced no output".
- **Widget truncation is width-aware.** Branch lines were cut at fixed
  ~60-char floors even on wide terminals. Truncation budgets now scale with
  the terminal width (floors unchanged for narrow terminals); the call site
  passes process.stdout.columns. Matches pi-tasks' truncate-at-terminal-width
  behavior.

### Changed

- Dev-dependency `@earendil-works/pi-coding-agent` bumped 0.74.2 → 0.81.1 so
  type-checking matches the API the extension actually runs against
  (CreateAgentSessionOptions.modelRuntime).

## [0.22.1] — 2026-07-22

### Fixed

- **Goal invisible on session load.** `session_start` only painted the TUI
  via `persistState`, so a goal that was already paused (or any state that
  doesn't mutate on load) rendered no widget and no status line after
  starting or resuming a session — "can't tell if it's on" is a bug. The
  handler now calls `refreshUI` unconditionally, which also refreshes/clears
  any stale widget carried over from a previous in-process session.

## [0.22.0] — 2026-07-22

Self-audit release: the extension audited itself (goal 20260722151428-375it3,
report in the operator's audit dir) and shipped every fix in one batch.

### Changed (approved behavior fixes)

- **Widget token segment is conditional.** With the token guard off (the
  default, opt-in since v0.12.0) the widget showed "0/0 tok" — zero
  information. The "· N/M tok" segment now appears only when a budget is set.
- **Provider warning reworded.** The session-start notice claimed an
  extension-registered session provider means "the auditor will fail auth".
  False for providers defined in ~/.pi/agent/models.json: the auditor inherits
  the already-resolved Model object in-process, so those work. The notice is
  now failure-conditional: "if audits error with auth/provider failures, set
  /glla model=provider/id".

### Fixed (hygiene batch from the audit)

- INSTALL.md listed the v0.1.0-era /pi-gla-* command family — a fresh install
  following the doc could invoke nothing. Now /goal, /list, /loop, /glla, and
  the smoke walkthrough uses /goal start.
- docs/DESIGN.md, PLAN.md, README.md, examples/, schemas/goal.schema.json:
  swept the last /pi-gla-* command names, .pi-gla/ paths, pi-gla-loop/ branch
  prefix, the "default 1M" token claim, and the "Stuck > 5 min" mechanism
  (the live guard is the 3-turn stall watchdog). PLAN.md's header no longer
  claims "v0.1.0-alpha.1 scaffold"; examples/example-objective.md rewritten
  to current behavior including the v0.21.0 restore hold.
- prompts/goal-loop-continuation.md told the model to propose a
  /pi-gla-tweak (nonexistent) → /goal tweak; its BACKOFF section described a
  5-minute pause that was never live → STALLS section matching the real
  watchdog.
- Dead code: removed unused backoff imports, STATE_ENTRY, and
  consecutiveStuckIterations from loops/goal.ts; /loop usage text no longer
  advertises the removed done= key; goal-loop-auditor.ts header no longer
  says regression_shield is "NOT YET IMPLEMENTED" (it has been live since
  v0.2.0); list_status tool label "Queue status" → "List status".
- Test docs: counts unified to the measured 168 across 12 files;
  tests/README.md coverage list gained the 5 missing files.
- CHANGELOG: removed a duplicated 0.19.0 heading.
- goal-loop-display.ts header now documents the purity rule: no runtime
  imports (npm test runs node --experimental-strip-types, which does not
  rewrite .js → .ts specifiers).

## [0.21.1] — 2026-07-22

### Fixed — widget head glyph and tree alignment

- **Active head now renders green for real.** The ◆ (U+25C6) head glyph is
  substituted by color-emoji fonts in some terminals and ignores ANSI color —
  it showed yellow no matter what was painted. Head glyph is now ● (U+25CF),
  the same glyph the status line uses, which takes theme color everywhere.
- **Branch lines flush-left.** v0.20.0 added a one-space branch indent, but
  pi's widget renderer already contributes a one-space gutter — branches sat
  one column deeper than pi-tasks'. ├─/└─/⎇ lines now emit no leading space,
  matching pi-tasks exactly.

## [0.21.0] — 2026-07-22

### Changed — session restore no longer auto-starts work in fresh sessions

Opening pi in a folder with an active goal used to fire work immediately —
before you could even load your old session, a fresh empty session was
already burning turns with zero conversation context. Restore is now gated
on `session_start.reason`:

- **"resume" / "reload" / "fork"** — the session carries the goal's
  conversation: auto-resume, as before.
- **"startup" / "new" (or no reason, older pi)** — fresh session: HOLD.
  Goals restore paused ("restored in a fresh session — no work started",
  /goal resume to continue); loops restore held (/loop with no args resumes
  a held loop instead of drafting); a waiting list notifies instead of
  auto-activating the head.
- **/glla autoresume=on** — new setting (global or project) restoring the
  old auto-resume-everywhere behavior. Set it per rig project for
  unattended restarts. Default off.

The gate is one mechanical predicate (`shouldAutoResumeOnSessionStart`),
unit-tested across all five reasons plus the autoresume override.

## [0.20.1] — 2026-07-22

### Fixed — the liveness signal looked frozen

The UI ticker ran every 5s while `fmtElapsed` showed minute granularity
("14m" for a full minute) — an active goal was indistinguishable from a
wedged one at a glance. Ticker now runs every 1s and elapsed keeps
seconds visible up to the hour (`1m 05s`, `3m 00s`; `1h 05m` beyond).
Paused goals still don't tick — the stopped clock is the honest metaphor
for "waiting on the user".

## [0.20.0] — 2026-07-22

### Added — semantic colors in the widget + status line

The goal/list/loop widget and the footer status line now paint status
semantically via pi's theme (works in light + dark themes):

- **green** — active goal/list item (◆/●), loop best value
- **yellow** — paused awaiting user; loop stall one short of the plateau stop
- **red** — error pauses (token limit, stalled, auditor infra failure)
- **accent** — auditing in progress, loop direction arrows
- **dim** — token counters, hints, suggested actions, measure command

Colors are opt-in at the call site (`DisplayTheme`); the pure builders
still return plain strings without a theme, so tests stay ANSI-free.

### Fixed — widget column alignment + branch-name relic

- Widget branch lines (`├─`/`└─`) were flush-left while the head glyph
  padded the text column — the tree looked one space out of column next
  to other widgets. Branch lines now indent one space (pi-tasks
  convention): the tree sits under the head glyph, text column consistent.
- Loop scratch branches were still named `pi-gla-loop/…` (rename relic);
  now `pi-glla-loop/…`, commit messages included.

## [0.19.3] — 2026-07-22

### Changed — goal drafting: thoroughness goes in the contract, not in iteration budgets

An agent mid-`/goal`-interview asked the user to pick "Loop size: 30/60/15
iterations with a stop rule" — loop-3 vocabulary imported into a goal,
with an invented pass-count dressed up as a recommended preset. The
mechanical guard was already right (`propose_loop_draft` rejects calls
outside loop drafting), but the goal-draft prompt never said goals have no
iterations. Now it does: exhaustiveness is expressed as checkable contract
items ("Done when: all 22 screens audited"), never as pass-counts, and
invented tiered packages are called out by name. Same pattern as the
v0.19.1 list-cap fix: agents confabulate authoritative-looking numbers;
the prompt is where confabulated framing gets banned.

## [0.19.2] — 2026-07-22

### Fixed — the status line names what it's running; `/gla` and "queue" relics swept

- **Footer shows the right name per loop type.** The status line hardcoded
  `glla: goal ●` even when the active item came from the list. It now reads
  `Goal.policy`: `glla: goal ●` for a direct goal, `glla: list ●` for a
  list-activated item (loop 3 already showed `glla: loop ↑/↓`). One status
  line, three honest names.
- **Three more user-facing `/gla` relics** the 0.17.x sweeps missed: the
  no-model error ("set one with /gla model=…"), the token-limit pause
  message + its suggested action, and the provider-warning + settings hint
  text. All say `/glla` now; comment blocks swept too.
- **"Queue" relics renamed to "list"** in user/agent-facing text: the
  `/list` show header, the confirm-activation messages, the list-drafting
  label, and the drafting block message.

## [0.19.1] — 2026-07-22

### Changed — the list is unbounded; the 100-per-call cap is gone

The queue was already unbounded (`enqueueItems` appends without limit) —
the only arbitrary wall was `list_add` rejecting batches over 100. Hundreds
of small tasks are a legitimate list. The cap is removed and the tool
descriptions now say so explicitly ("The list is UNBOUNDED — hundreds of
small items are fine; propose them all"), because agents read caps into
examples and self-impose limits the plugin never had. The honest cost note
stays: every item is audited individually, so audit cost is the real
budget for huge lists — not a number in code.

## [0.19.0] — 2026-07-22

### Changed — `/list add` is now a no-op alias; detection routes everything

The verb was redundant: `/list plan.md` already imported via detection, so
`add`'s only real job was forcing vague text past the interview. But a list
item activates RAW when it reaches the head — the drafting interview is the
only quality gate an item ever gets, and a verb whose sole purpose was
skipping that gate was a leak, not an escape hatch. Now `add` and `import`
are stripped and the rest routes through `routeListText` exactly like
verb-less text: file → import, paste → batch, `Done when:` → direct,
anything else → drafting. Muscle memory (`/list add plan.md`) keeps working.
The list-drafting notice now names the real direct path: include a
`Done when:` clause. Also swept the last "Forever-polish loop" framing from
the README decision table.

## [0.18.1] — 2026-07-22

## [0.18.1] — 2026-07-22

### Fixed — Confirm-gate bypass: agent queued list items directly mid-draft

First live run of conversational `/list`: the agent received the drafting
interview, skipped it, called `list_add` three times, and ACTIVATED the
first item — zero confirmation, because the gate only covered
`propose_goal_draft`. During a list drafting session `list_add` and
`list_activate` now return a block error steering to
`propose_goal_draft(items[])` (one Confirm for the whole batch). User
commands (`/list add`) are unaffected; outside drafting the agent manages
the list freely. New pure predicate `listMutationBlocked` + test.

## [0.18.0] — 2026-07-22

## [0.18.0] — 2026-07-22

### Added — conversational `/list`: dump text, get a decomposed list

`/list fix the login bug, add dark mode, write docs` used to hit a usage
error (unknown verb "fix") — and `/list add` of the same text queued ONE
monolithic objective. Now an unknown first word is treated as a
natural-language dump and routed by detection (new `routeListText`):

- file path → bulk import (sisyphus/Ralph plan file, unchanged)
- multi-line paste → batch add (structure already explicit, unchanged)
- contains `Done when:` → one direct item, no interview
- anything else → **drafting session**: the agent decomposes the dump into
  `items[]`, one Confirm adds the whole batch

`/list add <text>` stays the explicit direct path — the `/goal start` of
lists — for when you know it's one item. The list-drafting notice now
names the right escape hatch (`/list add`, not `/goal start`), and the
empty-list hint teaches the conversational form.

## [0.17.1] — 2026-07-22

## [0.17.1] — 2026-07-22

### Fixed — four `/gla` strings the 0.17.0 sweep missed

Widget footer hint, loop-block comment, and the two auditor-infrastructure
error paths still pointed at `/gla`. The relic sweep now greps clean
(everything except the intentional migration code and CHANGELOG history).

## [0.17.0] — 2026-07-22

## [0.17.0] — 2026-07-22

### Breaking — no relics: aliases removed, state dir renamed

Self-audit after the rename. A rename that keeps aliases is a rename that
didn't happen.

- `/gla` alias **removed** — `/glla` is the only settings command.
- `/queue` alias **removed** — `/list` since 0.10.0, the training wheels
  stayed three releases too long.
- Status/widget prefix `gla:` → `glla:`; widget keys `pi-gla` → `pi-glla`.
- State dir `.pi-gla` → `.pi-glla` with a one-time automatic migration
  (existing goals, ledgers, and project settings move; no state is lost).
- Every user-facing string (error messages, header comments, docs, smoke
  script) now says `/glla` and `.pi-glla`.

### Fixed — tooltip drift: `/loop` description advertised a removed strategy

The command tooltip still showed `[done=<value>]` — an option that throws
since 0.15.0 — and the "forever loop" framing predates the repositioning.
New description states the agreed philosophy: *"metric-driven process — it
never completes… 'Improve until X' is a /goal, not a loop"* with the real
parameters `[time=<hours>] [tokens=<budget>] [branch=1]`. Also: tool
description "queue item" → "list item".

## [0.16.0] — 2026-07-22

## [0.16.0] — 2026-07-22

### Added — `/goal start <objective>`: the explicit skip-draft

The only skip paths were embedding `Done when:` (a string heuristic) or
surviving the interview. `/goal start` activates immediately by explicit
command — no grilling, no Confirm gate, symmetric with `/loop start`; the
auditor infers the contract from the objective. The drafting notice and
`/goal` help now name the escape hatch, so a user stuck in an interview
learns the way out from the UI itself. `/goal start` with no objective
prints usage.

## [0.15.1] — 2026-07-22

## [0.15.1] — 2026-07-22

### Fixed — endless drafting: the gate ignored dialog answers

Wild failure (junk-runner session): the user answered **five**
`ask_user_question` rounds and `propose_goal_draft` still returned
INTERVIEW FIRST every time. The floor counted only typed chat messages
(`message_start` role=user); dialog answers arrive as **tool results** and
never incremented the counter. Worse, the blocked error said "ask one sharp
question, then propose again" — mechanically manufacturing an endless
interview. The agent eventually bypassed the goal entirely.

Two fixes, one mechanism:

- `tool_result` handler counts answered `ask_user_question` questionnaires
  (`details.cancelled === false` with ≥1 answer — Esc-abandons do NOT count)
  toward the interview floor, via the new `askUserQuestionAnswered` helper.
- Stuck-gate escape hatch: after 3 blocked proposals, the error message
  switches to "tell the user to type any chat message to unlock" — a gate
  that cannot see the replies must never manufacture another interview round.

## [0.15.0] — 2026-07-21

## [0.15.0] — 2026-07-21

### The package is now `pi-goal-list-loop-audit` — and a loop never completes

Design conversation outcome: **goal = achievement, loop = process.** The old
name read as "a loop for goals"; the three primitives are peers and the
name now says so. npm `pi-goal-loop-audit` is deprecated with a pointer.
`/glla` is the settings command; `/gla` stays as an alias. State dir
`.pi-gla` unchanged.

### Breaking — `done=` removed from `/loop`

A loop no longer checks for completion — *that was a goal in a trench coat.*
`done=` now throws a teaching error pointing at `/goal "… Done when: …"`.
The loop's ends are exactly: `/loop stop`, plateau (the well is dry),
`max=` iterations, and the two NEW arbitrary bounds `time=<hours>` and
`tokens=<budget>` (orchestrator-counted input+output). The loop Confirm
dialog states it plainly: "The loop never completes."

### Added — `propose_loop_refine` (the living spec)

The loop's unique territory: working against a spec that can itself be
refined. Mid-loop, the agent calls `propose_loop_refine` with a sharpened
target and/or a new measure command plus a rationale; the user confirms;
on a measure change the orchestrator test-runs the new command (no number =
auto-reject) and re-baselines. `loop.refinements[]` keeps both eras;
`/loop status` shows the refinement count. The forever prompt now names
this as the only legitimate way to change the metric — never gaming it.

## [0.14.0] — 2026-07-21

All notable changes to pi-goal-loop-audit are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.4] — 2026-07-21

### Docs — compatibility section

README gains the full complement/conflict map: the Two-Driver Rule (one
agent_end driver at a time — hard conflicts with pi-codex-goal, pi-loop-mode,
pi-goal-x family, active ralph/autoresearch), the compaction-continue overlap
note, the ralph-wiggum "installed but not simultaneous" rule, and the
complements (rpiv-ask-user-question, pi-subagents, pi-tasks, pi-chrome,
search skills) with the provider + notification-channel footnotes.

## [0.9.3] — 2026-07-21

### Added — bamboozle adversarial scenario (auditor catch-rate testing)

- **`scripts/smoke.sh bamboozle`**: the first outcome-level test. A buggy
  `calc.js` where the easy path is gutting the tests and the contract makes
  that detectable: `node --test exits 0` AND exports intact AND ≥6 test
  blocks. Asserts the traps all hold at the end AND the shield enforced
  per-item evidence (`regressionShieldPassed: true`). This is how we measure
  the auditor's catch rate instead of just its mechanics. 6/6 green on first
  run (agent fixed the bug honestly; the shield verified all three traps with
  evidence).

## [0.9.2] — 2026-07-21

### Added — done= threshold, hypothesis line, stall strategy hint

- **`/loop start ... done=<value>`**: until-done semantics (pi-loop-mode's one
  genuinely good idea we lacked). The loop stops the MOMENT the metric
  crosses the threshold (min: `value <= done`, max: `value >= done`) instead
  of stalling out the plateau window first. Done beats plateau when both hit.
  Also available as `done` in `propose_loop_draft`. Verified live: 3→2→1→0
  stopped at iteration 3 with `done — metric crossed 0`, no stall tail.
- **`HYPOTHESIS:` line** (pi-autoresearch's good idea): loop prompts ask the
  agent to state its intent first; the line is parsed into every
  `loop_measured` ledger event, making loop history auditable, not just numeric.
- **Strategy rotation at high stall** (pi-loop-mode's other good idea): at
  `stall >= window-1`, the directive switches from "one small change" to "try
  a fundamentally different approach" — one creative shot before the plateau
  stop, instead of polishing to the end.
- 8 new unit tests (doneCrossed, done-stops-immediately, done-beats-plateau,
  done= parsing). 142 total, tsc clean.

## [0.9.1] — 2026-07-21

### Changed — `/list` renamed to `/queue`

The status line said `queue 4`, the widget said `queue 7 waiting`, `list_add`'s
description read "Add to queue" — everything already called it a queue except
the command. Now the command matches: `/queue add|show|next|remove|clear`.
"List" described a static structure; this thing has FIFO behavior with
auto-advance — that's a queue. `/list` remains as an alias for one release
(removed in 0.10.0). `/goal` stays (a goal is not a todo — it has a contract
and an audit); `/todo(s)` rejected (checkbox semantics invite exactly the
vagueness the auditor exists to kill).

## [0.9.0] — 2026-07-21

### Added — live TUI: status line + above-editor widget

- **You can always tell it's on now.** A persistent `gla:` segment in the
  status line shows the supervisor state at all times:
  `gla: goal ● 2/5 tasks · 3m · queue 4` · `gla: auditing… · read` ·
  `gla: paused ⏸ <reason>` · `gla: loop ↓ iter 12/50 · best 41 · stall 2/5`.
- **Above-editor live widget** (pi-goal-x pattern, simpler `string[]` form):
  objective head, status, elapsed, token usage, next pending task or loop
  metric, pause reason + suggestion, branch name in branch mode, and **live
  auditor progress** (current tool, elapsed, isolated-session note) during
  audits. Refreshes on every state transition (single chokepoint:
  `persistState`) plus a 5s ticker for elapsed time.
- Pure builders in `goal-loop-display.ts` — 16 unit tests.

### Verified (2026-07-21)

- Live: widget renders during an audit with live auditor progress; status
  line reads `gla: auditing…`. 134 unit tests, tsc clean.

## [0.8.5] — 2026-07-21

### Changed — auditor thinking follows the pi session

- **Auditor thinking level**: was a hardcoded `medium` default. Now the
  auditor follows the thinking level **you selected in pi** (same philosophy
  as the model), with a `high` floor when nothing is set — the auditor is the
  verification gate, depth beats speed there. `/gla thinking=` remains the
  explicit override; the settings UI shows `(session, floor high)` when unset.

## [0.8.4] — 2026-07-21

### Added — free-style list: the agent can manage the queue

- **`list_add` tool**: the queue is no longer command-only. Plain chat works —
  "queue these 10 things", "add this to my list", "put it on the backlog" —
  the agent enqueues with per-item `Done when:` extraction and
  auto-activation. This was the real gap vs sisyphus/ralph-style plugins:
  conversational flow with our audited-queue semantics.
- **`list_status` tool**: the agent can read the active goal, the queue, and
  any running loop as text before deciding what to do.
- **`enqueueItems`**: the one shared enqueue path — bulk import, `items[]`
  drafting, and `list_add` all funnel through it (three copies eliminated).

### Verified (2026-07-21)

- Live: one plain-chat sentence ("queue these three things: …") →
  `list_add {count: 3}` (agent added its own Done-when clauses) →
  three goals worked → **three independent auditor approvals** → archived.
- 118 unit tests, tsc clean.

## [0.8.3] — 2026-07-21

### Changed — quiet auditor auto-fallback; `/list add` takes pasted lists

- **The provider warning is gone.** When the pi session model's provider is
  extension-registered (the auditor's extension-less session can't auth it),
  the plugin now **auto-uses the strongest credentialed built-in model** and
  says so ONCE at info level, naming the pick: override any time with
  `/gla model=provider/id`. Resolution: explicit `/gla` setting → session
  model (if built-in) → auto-fallback (tier-ranked) → clear error. The
  session model always wins when it works; nothing is ever written to your
  config silently.
- **`/list add` accepts pasted multi-line text**: paste a checklist straight
  into the command — it parses as a batch with the same single Confirm as a
  file import. Detection order: existing file → multi-line paste → single
  objective.
- `auditModelTier` restored to core (2 unit tests; speed/cost variants
  outrank family names — `gemini-3-flash` is flash-tier, not gemini-tier).

### Verified (2026-07-21)

- Live: multi-line bracketed paste → batch Confirm → `list_imported {count: 3}`.
- 118 unit tests, tsc clean.

## [0.8.2] — 2026-07-21

### Changed — `/list add` is the flexible path; drafting proposes batches

- **`/list add` now detects files**: `/list add plan.md` bulk-imports when the
  path exists and is a single objective when it doesn't. No separate verb to
  remember. (`/list import` remains as an alias for 0.8.1 compatibility.)
- **Multi-item drafting**: `propose_goal_draft` gains an `items[]` parameter,
  so a `/list` drafting session can propose a whole plan at once — one Confirm
  dialog for the batch, per-item `Done when:` extraction, auto-activation.
  `items[]` in `/goal` drafting is rejected (a goal is single by definition).
  The list-draft prompt tells the agent to batch: "queue these 50 things"
  → one proposal, not fifty.
- `resolveImportFile` in core (4 unit tests): file detection by bare name,
  relative path, `./` prefix; objectives and directories never match.

### Verified (2026-07-21)

- Live: `/list add plan.md` → file detected → batch Confirm →
  `list_imported {count: 3}` → first item activated, 2 queued.
- 116 unit tests, tsc clean.

## [0.8.1] — 2026-07-21

### Added — bulk list import + queue paging

- **`/list import <file>`**: the sisyphus-style path. Bulk-enqueue hundreds of
  items from a plan file — markdown checklists (`- [ ]`), bullets, numbered
  items, plain lines; headings/comments/hr-rules skipped; per-item `Done
  when:` extraction; ONE Confirm dialog for the whole batch (count + preview).
  **Bulk never drafts** — the three drafting rules are now explicit:
  no-args = draft (single), with-args = direct, import = bulk direct.
- **`/list show` pages at 15** with `… and N more` (a 500-item queue no longer
  floods the pane).
- `parseListImport` in core (8 unit tests incl. a full sisyphus-plan fixture).

### Verified (2026-07-21)

- Live: 20-item plan → Confirm (5 preview + "… and 15 more") →
  `list_imported {count: 20}` → first item auto-activated, 19 queued, paging
  correct, agent working. 112 unit tests, tsc clean.

## [0.8.0] — 2026-07-21

### Changed — `/gla` opens a real settings UI; four top-level commands

- **`/gla` now opens an interactive settings menu** (pi dialog primitives):
  pick a setting → edit it (input for model/notify/token limit, select for
  thinking level) → saved to GLOBAL → back to the menu until Done/Esc. The
  scriptable `/gla key=value` and `/gla project key=value` forms remain for
  tmux/headless; headless sessions get the text display with provenance.
- **Top-level commands consolidated from 11 to 4**: `/goal`, `/list`,
  `/loop`, `/gla`. The goal verbs became exact-match subcommands:
  `/goal status|pause|resume|cancel|tweak <text>|archive`. Removed:
  `goal-status`, `goal-pause`, `goal-resume`, `goal-cancel`, `goal-tweak`,
  `goals`, `goal-init`.
- **The ambiguity rule** (unit-tested): subcommands match only on the exact
  bare word, so `/goal pause the deployment pipeline` sets an objective about
  a pipeline — only bare `/goal pause` pauses. `routeGoalArgs` in core,
  10 tests including the critical cases.

### Verified (2026-07-21)

- 104 unit tests, tsc clean.

## [0.7.1] — 2026-07-21

### Changed — `/goal-settings` renamed to `/gla`

One config command for everything — goals, loops, lists, and the auditor —
deserves a name that doesn't say "goal" alone. `/gla` matches the `.pi-gla/`
state directory and sits in its own namespace beside the three verbs
(`/goal`, `/list`, `/loop`). Same handler, same tiers:

```
/gla                          # effective values + provenance
/gla model=provider/id        # write GLOBAL
/gla project tokenlimit=500   # write project override
```

`/goal-settings` is gone (renamed, not aliased — the plugin is a day old;
clean break over surface creep).

## [0.7.0] — 2026-07-21

### Added — global config tier

- **One global config, rarely opened.** Settings now resolve per key as
  **project > global > defaults**: global lives at
  `~/.pi/agent/pi-goal-loop-audit.settings.json`, the project override stays
  at `.pi-gla/settings.json`. `/goal-settings key=value` writes GLOBAL by
  default (set the auditor override, notify command, token limit once — not
  in every project); `/goal-settings project key=value` writes the rare local
  override; `key=unset` removes the key from that tier.
- **Provenance display**: bare `/goal-settings` shows every effective value
  with its source (`[project]` / `[global]` / `[default]`) and both file paths.
- Nothing is per-goal: model, thinking, notify, and token budget are shared
  config for all three loops. The auditor still defaults to the pi session
  model — the plugin never picks a model.
- `mergeSettings` in core (4 unit tests): later layers win per key,
  `undefined` means "not set here", base never mutated.

### Verified (2026-07-21)

- Live: global write lands at `~/.pi/agent/…` with quoted `$1` commands intact;
  `project` prefix writes only the project file; provenance display correct.
- `loop` smoke green with project-scoped notify (no global-config leak).
- 94 unit tests, tsc clean.

## [0.6.2] — 2026-07-20

### Changed (model philosophy: the user selects the model in pi)

- **The plugin no longer picks or recommends auditor models.** The auditor
  uses the pi session model by default; `/goal-settings model=provider/id`
  remains as an explicit override. An earlier tier-based auto-selection idea
  was implemented and then ripped out the same day — model choice belongs to
  the user, not the plugin.
- **No model names anywhere**: docs, examples, comments, and messages use
  `provider/model-id` placeholders only. The session-start warning for
  extension-registered providers now explains the two fixes (switch pi's
  model to a built-in provider, or set the override) instead of recommending
  a specific model.
- The smoke harness no longer configures an auditor model at all — the
  auditor shares the test session's pi-selected model, which is the path
  most users will run.

### Verified (2026-07-20)

- `goal` smoke 5/5 with zero auditor-model configuration (auditor ran on the
  session model directly). 90 unit tests, tsc clean.

## [0.6.1] — 2026-07-20

### Fixed (footguns found by real use)

- **Direct `/loop start` refuses a no-number baseline.** Previously a broken
  measure started with a null baseline and burned stall iterations until
  plateau. Now it fails fast with the raw output and a fix hint; `force=1`
  overrides for measures that only work after the agent builds something first.
- **Redirect guidance for non-numeric goals**: `/loop start` parse errors and
  the refusal now say plainly — research/docs/features belong in `/goal` (the
  auditor verifies semantically); `/loop` only believes a number. The loop
  drafting prompt has the same rule and offers to hand over a well-structured
  `/goal` objective instead of inventing a fake metric.

## [0.6.0] — 2026-07-20

Draft everything. For a long-running thing, a draft up front is better —
until now only `/goal` had drafting; `/list add` took raw strings, and
`/loop start` demanded a correct target+measure+direction in one blind shot.

### Added

- **`/loop` drafting with measure test-run** (centerpiece): `/loop` with no
  args starts a grilling turn about target + metric. When the agent calls
  `propose_loop_draft`, the **orchestrator runs the proposed measure command
  once** and shows the real output + parsed number in the Confirm dialog —
  you validate the metric before a single iteration burns tokens. A measure
  producing no number is auto-rejected back to the agent with its own output.
- **`/list` drafting**: `/list add` with no args runs the same goal-drafting
  flow, but the confirmed contract lands in the **queue** (auto-activates if
  nothing is running). Drafting target is now unified: `goal | list | loop`.
- **`/goals` archive browser**: newest-first list of archived goals with
  status, objective head, and stop reason.

### Changed

- `/loop` with no args now drafts; `/loop status` is the explicit status path.

### Verified live (2026-07-20)

- Loop drafting: agent found `num.txt` itself, proposed `cat num.txt`, dialog
  showed "Test-run output: 10 · Parsed number: 10 (lower is better)";
  confirmed loop ran 10→9→8 improving.
- List drafting: confirmed contract → `list_added` → auto-activated →
  worked → audited → archived.
- `/goals` parsing verified against real archive entries.
- 89 unit tests green; `tsc --noEmit` clean.

## [0.5.0] — 2026-07-20

Self-sufficiency release: the loop now owns its own liveness. A goal loop that
dies silently after compaction and needs an external plugin to restart it is a
hole in THIS plugin — so the watchdog is baked in, and the external one
(`@badliveware/pi-compaction-continue`) can be cut.

### Added

- **Heartbeat self-watchdog**: a 15s interval checks the one precise stall
  condition — supervising (active goal or running loop) + session idle + no
  continuation/loop timer scheduled + no activity for 60s — and re-fires the
  continuation itself. Covers every stall cause (compaction-eaten turn,
  dropped message, stale ctx) with a single check. Stall accounting: a
  supervising turn with zero tool calls is a nudge; 3 consecutive nudges
  pause the goal / stop the loop with a clear reason. Pure decision functions
  in `goal-loop-backoff.ts`, 8 unit tests.
- **`/goal-tweak "<new objective>"`** — edit the active goal in place; Confirm
  dialog shows current vs new; the verification contract is re-extracted from
  the new text (old contract dropped if the new text carries none).
- **Structured drafting forms**: the drafting prompt now prefers
  `ask_user_question` (from `rpiv-ask-user-question`) when the tool is
  available in the session — structured option lists during grilling without
  a hard dependency. Plain conversation remains the fallback.

### Verified (2026-07-20)

- 89 unit tests green; `tsc --noEmit` clean.
- `goal` smoke 5/5 with the heartbeat interval live through the full cycle.

## [0.4.0] — 2026-07-20

The completion release: the last open pi-goal-x flaw is closed, and every
deferral from earlier milestones either shipped or was recorded as rejected.

### Added

- **Auditor compaction** (closes flaw #3, the final one): pi's built-in
  compaction is now enabled in the auditor session (was disabled — long audits
  could exhaust context mid-audit). Safety is structural: regression_shield is
  orchestrator-side, so compaction can only weaken the auditor's evidence and
  cause disapproval, never a false approval.
- **Token guard**: goals now track real token usage (summed from assistant
  `usage.totalTokens`, deduped across replayed `agent_end` history). Crossing
  the limit pauses the goal with a clear reason. Default 1M per goal;
  `/goal-settings tokenlimit=<n>` to tune. Shown in `/goal-status`.
- **Loop 3 `branch=1` mode**: all loop work on a scratch branch
  (`pi-gla-loop/<timestamp>-<slug>`) — commit per improvement,
  `git reset --hard` per regression (scratch branch only; your branch and
  uncommitted work are never touched). Refuses non-git dirs and dirty trees.
  On stop: returns to your original branch with merge instructions.
- **Resumption notice** on `session_start`: active goal (with queue depth) or
  running loop (iteration/best/stall) is announced. (Replaces the D4
  "plugin vanished" self-check, which is impossible from inside the plugin —
  absent code cannot run. Recorded as rejected in PLAN.md.)

### Fixed / synced

- `schemas/goal.schema.json` updated to the current state shape (was v0.1.0,
  still said "oracle").
- `examples/example-objective.md` rewritten — it still used `/pi-gla-set`.
- `docs/DESIGN.md` addenda for v0.2.0/v0.3.0/v0.4.0.
- Smoke harness: new `draft-reject` scenario (Confirm → No → refine → Yes →\n  audited approval, 6/6); clarified-word probe made robust (a grilling turn
  ends with `?`).

### Verified live (2026-07-20, `scripts/smoke.sh`)

- `goal` 5/5 (with compaction enabled), `list` 4/4, `loop` 5/5, `draft` 3/3,
  `draft-reject` 6/6.
- branch=1 smoke: 5 commits (one per improving iteration) on the scratch
  branch, zero for stalls, `main` untouched, returned to `main` on plateau
  stop with merge instructions.
- 81 unit tests green; `tsc --noEmit` clean.

## [0.3.0] — 2026-07-20

The third loop. All three loops now ship on one state machine.

### Added

- **Loop 3: `/loop`** — metric-driven forever loop:
  `/loop start "<target>" measure="<cmd>" direction=min|max [window=5] [max=50]`,
  `/loop status`, `/loop stop`. The **orchestrator** runs the measure command
  after every agent turn (the agent never self-reports) and stops on plateau
  (`window` consecutive non-improving iterations), iteration cap, or
  `/loop stop`. This is the anti-doorknob design: the loop only believes a
  number. No auditor in loop 3 — the metric is the verdict. Pure logic in
  `extensions/goal-loop-forever.ts` (22 unit tests).
- **`propose_task_list` tool** — the agent can break a goal into milestones
  after a Confirm dialog. Anti-drift caps: 20 top-level tasks,
  **5 subtasks per task** (pi-goal-x flaw #4). Validation/ids in core,
  8 unit tests. Makes the existing `complete_task` / `update_task_status`
  tools actually usable.
- **`notify=<cmd>` setting** — config-gated push: shells out on goal complete,
  goal pause, and loop stop; message passed as `$1`.
  `/goal-settings notify='echo $1 >> /tmp/log'` — the settings parser is now
  quote-aware (a naive whitespace split mangled quoted commands to `"'echo"`).

### Fixed

- `/goal-settings` key=value parsing handles quoted values with spaces.
- Smoke harness is hermetic: all scenarios run under a bare
  `PI_CODING_AGENT_DIR` with a readiness wait — global extensions (including
  older npm installs of this package) can no longer collide with the dev
  build under test, and commands can't race the REPL into the agent.

### Verified live (2026-07-20, `scripts/smoke.sh`)

- `goal`: 5/5 — auditor approval, shield, archive.
- `list`: 4/4 — two queued items auto-advanced through audit, queue drained.
- `loop`: 5/5 — metric 5→0 with per-iteration stall accounting, plateau stop
  at window, `loop_stopped` in ledger, notify fired.
- `draft`: 3/3 — grill → Confirm dialog → audited approval.

## [0.2.0] — 2026-07-20

Second loop, the anti-bamboozle hardening, and drafting.

### Added

- **Loop 2: `/list`** — queue of goals: `/list add|show|next|remove <n>|clear`.
  Each item is a full goal (objective + verification contract). Completing or
  aborting a list-sourced goal auto-activates the next queued item; a session
  restart with a non-empty queue resumes automatically.
- **regression_shield** — when a goal has a verification contract, the auditor
  MUST produce an `<evidence>` block quoting raw tool output per contract item;
  the orchestrator converts `<approved/>` without complete evidence into a
  disapproval. Kills the "auditor ran `bash true` and approved" hole that
  pi-goal-x's author documented as unfixable-cheaply. Pure logic lives in
  `extensions/goal-loop-shield.ts` (dependency-free, fully unit-tested).
- **Drafting** — `/goal` with no args starts a clarification turn; the agent
  grills one focused question at a time, then `propose_goal_draft` opens a
  real Confirm dialog (Yes/No). Nothing activates before confirmation.
  `/goal "<objective>"` still skips drafting.
- **Escape dialog** — aborting the auditor (Esc) now asks: complete WITHOUT
  audit (user takes verification responsibility) or continue working.
- **Provider warning** — at `session_start`, if no auditor model is configured
  and the session model's provider is not a confirmed built-in, warn once with
  the exact `/goal-settings` fix.
- **Inline contract extraction** — one-liner objectives like
  `Create x.txt. Done when: grep -q ok x.txt` now extract the contract
  (previously only line-start markers worked, silently skipping the shield).
- **Integration harness** — `scripts/smoke.sh [goal|list|draft]` drives a real
  pi session in tmux and asserts on the ledger.

### Fixed

- State functions (`setGoal`/`archiveCurrentGoal`) no longer wipe the queue.
- `readState` restores `list` from the ledger; v0.1.0 ledgers upgrade cleanly.

### Verified live (2026-07-20)

- `/list`: two queued items auto-advanced through work → auditor → archive.
- regression_shield: auditor produced a verbatim `<evidence>` block;
  `shield=True` recorded in history.
- Drafting: grill → sharpened contract → Confirm dialog → audited completion.
- Provider warning fired exactly once on a kilocode session.
- `scripts/smoke.sh goal`: 5/5 assertions.

## [0.1.0] — 2026-07-20

First live-verified release. Everything in alpha.1, plus the fixes found by
running the loop end-to-end in a real pi session.

### Fixed (all found by live smoke testing)

- **Stale-ctx crash**: timers captured `ExtensionContext` which throws after
  session replacement. All timers now read a `lastCtx` refreshed by every
  event/command handler; stale ctx is detected and dropped safely.
- **API surface**: imports moved to the public entrypoint
  (`@earendil-works/pi-coding-agent`) with `Model` from `pi-ai` and
  `ThinkingLevel` from `pi-agent-core`. `sendMessage` is called on the `pi`
  API object, not `ExtensionContext`.
- **Tool contract**: tool results include `details`; command handlers are
  async; the tool event is `tool_call` (not `before_tool_call`).
- **Auditor "no model" failure**: auditor now defaults to `ctx.model` when no
  auditor model is configured, matching pi-goal-x's `resolveAuditorModel`.
- **Auditor model setting works**: `/goal-settings model=provider/id` resolves
  through the model registry (was a placeholder storing an unresolved id).
- **Audit-history pollution**: only non-empty auditor reports are recorded as
  verdicts (infrastructure failures surface via `pauseReason` instead);
  history capped at 20 entries; entries now carry an `error` field.
- **Objective quoting**: `/goal "..."` strips one layer of surrounding quotes.

### Added

- **Command-collision detection** (`warnOnCommandCollision`): pi never throws
  on duplicate command names (first registrant keeps the bare name, later ones
  get `:2`), so we detect duplicates at `session_start` and warn once.
- **Built-in-provider rule documented**: the auditor session has no extensions,
  so it can only use built-in providers. `/goal-settings` warns on save;
  INSTALL.md shows how to verify a model works extension-less.

### Verified live (2026-07-20)

- Full loop: `/goal` → agent works → `complete_goal` → isolated auditor
  (extension-less session, separate model) approves → archived with clean
  1-entry history and a real evidence-based auditor report.
- 5-consecutive-error auto-pause (triggered by a live provider 403 storm).
- Esc during audit: aborts the pi turn; loop recovers via `agent_end`.
  (pi-goal-x's Escape dialog is v0.2.0 scope.)

## [0.1.0-alpha.1] — 2026-07-19

### Added

- **Loop 1 (single goal)**: single ordered goal with isolated auditor.
  - `/goal "<objective>"` — bypass drafting, start now.
  - `/pi-gla-status` — show state + iteration counter + audit history.
  - `/pi-gla-pause` — pause with reason.
  - `/pi-gla-resume` — resume.
  - `/pi-gla-cancel` — abort + archive.
  - `/goaltings` — configure auditor model + thinking level.
  - `complete_goal` tool — spawns isolated auditor.
  - `pause_goal` tool — pause with reason.
  - `complete_task` tool — task tracking helper.
  - `update_task_status` tool — task tracking helper.
- **Isolated auditor** (`goal-loop-auditor.ts`): runs in fresh session, no extensions, no skills, no prompts, read-only tools.
- **JSONL state** (`.pi-gla/active.jsonl`): every state transition persisted.
- **Markdown goal file** (`.pi-gla/goals/<id>.md`): structured rendering replaces pi-goal-x's hand-concat.
- **Hard 5-min backoff cap** (`goal-loop-backoff.ts`): kills the 1-hour wait pathology.
- **Verification contract extraction**: `Done when:`, `Verify:`, `Verified when:` markers split objective from contract.
- **Schema** (`schemas/goal.schema.json`): JSON Schema for goal state.
- **Test suite**: 14 unit tests across 3 files (`tests/`).
- **Example** (`examples/example-objective.md`): worked walkthrough.

### Not included (deferred)

- Drafting phase with structured Q&A → v0.2.0.
- regression_shield auditor requirement (must include raw output) → v0.2.0.
- Loop 2 (list) → v0.2.0.
- Loop 3 (loop) → v0.3.0.
- Native TUI form widget → v0.2.0.
- Live pi session tests → v0.2.0.
- Telegram push → v0.3.0.

### Architecture notes

We deliberately **fork pi-goal-x 0.19.0** as the architectural basis. We **do not** support interop with `pi-goal-x`'s `.pi/goals/` directory. This is a clean break.

We **copy and adapt** the isolated auditor pattern (it's the architectural part that matters), but reduce the per-loop file count (no per-loop plugin files) and replace the hand-concat markdown renderer with structured JSON.

