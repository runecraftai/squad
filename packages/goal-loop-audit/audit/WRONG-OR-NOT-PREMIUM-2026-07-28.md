# Wrong-or-Not-Premium Audit — 2026-07-28

Scope: pi-goal-list-loop-audit v0.28.0. Five streams: stale-session handling (orchestrator),
post-compaction stall misfires (orchestrator), error handling (subagent),
UX polish (subagent), test gaps (subagent). Every finding: verb-phrase title, file:line evidence, severity.

Naming per `pi-discipline/naming.md`: verb phrase first, IDs/codes trailing.

---

## Stream 1 — Stale-session handling (pi 0.82.x session replacement)

Live incident: goal `20260728095607-sraaal` created in the capture-anime-girls
pi at 09:56 — the session was stale (compaction → session replacement). The
goal persisted fine (`goal_created` in that project's jsonl), but the first
continuation send threw stale, `goStaleTerminal` paused it at 0s, and the
final jsonl event is `status=active pauseReason=None` — a zombie.

Rig context (why this severity): the rig runs long-lived pi processes —
`ps -eo pid,etime,cmd` shows two `pi` processes at 6d9h and 4d uptime. pi
0.82.x compaction replaces sessions on context-full, so multi-day sessions
are near-guaranteed to go stale eventually. capture-anime-girls has NO
`.pi-glla/settings.json` → default tri-state (HOLD on human loads) + no
autoresume → S2's stall is guaranteed after every stale event on this rig.

### S1 [HIGH] — Fix the silent-zombie goal after resume-in-stale-session

`extensions/loops/goal.ts:204` — `goStaleTerminal`'s anti-spam guard
(`if (extensionApiStale) return;`) skips the state correction on the SECOND
stale failure. Sequence: `/goal resume` in a stale session → `cmdResume`
(`:950-970`) sets `status:"active"` and notifies "Resumed goal …" →
`scheduleContinuation` → `sendContinuation` → send throws stale →
`goStaleTerminal` early-returns → **no re-pause, no warning**. The goal sits
active-in-ledger, widget says active, no send can ever land. Live evidence:
sraaal's last jsonl event is exactly this state.

Premium: on repeated stale sends, still correct the state (re-pause or keep
the interrupt marker) and rate-limit the notify instead of fully suppressing
the correction. Never leave ledger-state claiming "active" when the process
provably cannot run it.

### S2 [HIGH] — Auto-resume stale-interrupted goals after restart

`extensions/loops/goal.ts:213` — `goStaleTerminal` persists
`status:"paused"`. The restore gate (`:4032-4055`) only auto-resumes
`status==="active"` goals; NO branch handles paused goals. Result: even with
`autoresume=on`, a compaction-stale goal is dead until a human types
`/goal resume`. On an unattended rig every pi compaction = goal stalled until
human intervention. This is the user's "starts paused and stuck."

Premium: a stale interruption is not a user pause. Keep `status:"active"`
with an interrupt marker (`pauseReason` = stale text + restart guidance).
`sendContinuation`'s existing guard (`:527`) already prevents retry storms in
the doomed process. Fresh session_start → restore gate sees active →
auto-resumes (autoresume=on / reload / fork) or HOLDs with a clear notify
(human loads — tri-state design preserved). Restart becomes seamless
continuation, which is the whole point of an unattended-rig plugin.

Safety check for this fix (verified 2026-07-28): `status==="paused"` readers
are `cmdResume` (`:951`, no-op for active goals — correct), the widget
(`goal-loop-display.ts:135,196,223` — needs a small addition to surface the
interrupt marker on ACTIVE goals, since pauseReason only renders for paused
ones), and the auditor-quota resume branch (`:2150`, keyed on pauseReason
prefix, unaffected). The HOLD-on-human-load branch (`:4044-4055`) still
pauses interrupted goals with "held for explicit resume" — deliberate
tri-state preserved.

### S3 [MED] — Probe staleness at command entry

`extensions/loops/goal.ts:912` — `/goal` creation notifies "created —
starting now"; `:963-969` — `/goal resume` notifies "Resumed goal …". Both
are lies in a stale session (the "starting now" → 0s-pause whiplash; the
zombie "resumed"). `extensionApiStale` only becomes true AFTER a failed
send, so a freshly-compacted session with no send yet passes the flag check.

Premium: cheap probe at entry of cmdGoal/cmdResume/cmdList/critical commands
(flag OR a try/catch on a harmless api call). If stale: "this session's
extension handle is stale — restart pi (or /reload). State is safe in
.pi-glla/; the goal auto-resumes in the fresh session." Accept the state
change (fs works) but never claim it started.

### S4 [LOW] — End the creation whiplash

"Goal … created — starting now" immediately followed by "⏸ paused · 0s —
extension api stale" is whiplash. Falls out of S2+S3: with the interrupt
marker the display reads "created — will start when pi restarts (stale
session)" in one honest step.

---

## Stream 2 — Error handling (subagent)

Clean categories (keep): auditor-session failure handling is genuinely
strong (stall watchdog → error-never-verdict, no-output/no-marker guards,
tool-call floor, bounded single infra retry); quota/403 pauses with upstream
Retry-After + notify; ~50 bare `catch {}` sites are justified probes.

### E1 [HIGH] — Guard ledger/state writes against disk failures

`goal-loop-core.ts:470-477` (appendLedger), `goal.ts:627-630` (persistState),
`:644-651` (updateGoal/writeGoalMd), `:652-660` (archiveCurrentGoal). Every
lifecycle transition calls these unguarded; disk-full/EACCES throws through
~25 call sites AFTER in-memory `state.goal` was already mutated — RAM and
ledger diverge silently, and readState (`core.ts:488-495`) silently drops the
malformed trailing line on reload. State loss is undetectable after the fact.
Premium: try/catch persist, loud notify on first failure, "persistence
degraded" flag surfaced in TUI, never mutate in-memory before the write
succeeds (or mark dirty).

### E2 [HIGH] — Cap consecutive non-quota auditor infra errors

`goal.ts:2167-2186`. A permanently broken auditor model (401, unknown
provider, misconfigured `/glla model=`) returns infra-error → goal stays
active → the tool result tells the agent "fix the model with /glla and call
complete_goal again" — but /glla is a USER-only command; an unattended agent
re-calls complete_goal forever. `countTrailingDisapprovals` treats infra as
transparent; the 5-error brake (`:4190`) only watches `stopReason:"error"`
turns. No brake ever fires. Premium: count trailing infra errors in
auditHistory; pause loudly after ~3 with restart guidance.

### E3 [HIGH] — Bound the 50ms send-retry timers; make them watchdog-visible

`goal.ts:512-525` (sendContinuation no-ctx/busy retry), `:1416-1422`
(sendLoopTurn). If lastCtx never refreshes or hasPendingMessages() latches
true, the timer re-arms every 50ms FOREVER with zero ledger events — and the
pending-latch watchdog + heartbeat refire are suppressed precisely because
timerPending is true. The hegemon shape, still reachable on this path.
Premium: count retries, ledger them, escalate via escalateStallNow past a
threshold.

### E4 [MED] — Don't report reviewer proposals that never sent

`goal.ts:728-735` + reviewer.ts cascade. proposeGoal's
`catch { /* best-effort */ }` drops sendUserMessage failures, yet runReviewer
still counts `proposed++` → user notified "1 proposed as /goal" — a phantom.
Premium: return success from the callback; count/notify confirmed sends only.

### E5 [MED] — Distinguish "measure broke" from "plateau"

`goal.ts:1345-1350` (runMeasure catch → null) + goal-loop-forever.ts:176-183,
201-204. A measure command that starts failing mid-loop increments stallCount
→ loop stops with "plateau — no improvement", misdiagnosing infra failure as
stagnation. Premium: track consecutive null-measure iterations separately;
stop with "measure command broken" + notify.

### E6 [MED] — Surface drafting-seed send failures (stale-session shape)

`goal.ts:843-847`. `catch { draftingTarget = null; }` silently cancels
drafting when the seed sendUserMessage throws (stale api): user typed /goal,
gets NOTHING, goStaleTerminal never consulted. Belongs with S3's entry probe.
Premium: notify + stale-api check in the catch.

### E7 [LOW] — Report settings-save failures in the reviewer menu

`goal.ts:3298-3310` — saveSettings throws swallowed as "non-fatal"; the user
believes the toggle landed.

### E8 [MED] — Make the consecutive-errors brake informative and recover from transient flakes

`goal.ts:4190-4200` — `pauseReason: \`5 consecutive errors: ${stopReason}\``
renders literally "5 consecutive errors: error" — the actual provider error
is never surfaced, so the user can't tell rate-limit from auth failure from
network. And a transient 5-flap burst permanently pauses the goal until
manual /goal resume — no backoff-retry, no transient/persistent distinction.
User-aborted turns (stopReason "aborted") count toward the same error
counter. LIVE EVIDENCE: this audit's own goal (20260728100228-vgwfqd) paused
at 10:07:49 during a provider hiccup; the session recovered minutes later and
worked fine for 1.5h, but the goal sat paused and complete_goal was refused
("No active goal"). Premium: include the real error text (truncated) +
provider/model in the reason; auto-resume with capped backoff (~3 retries
over ~10 min) before the permanent brake; don't count user-aborted turns as
errors.

---

## Stream 3 — UX / premium polish (subagent)

Clean categories (keep): pause reasons/suggested actions consistently name a
concrete next command; settings table, widget pause card, drafting hints are
genuinely premium; prompts otherwise in sync with v0.28.0. LIST-PHILOSOPHY.md
spelling is correct.

### U1 [HIGH] — Fix /review help advertising modes the code rejects

`extensions/loops/goal.ts:3800` — registered description says `/review
<goal-id> [auto|report|default]` but `cmdReview` (`:3143`) only accepts
`off|on|auto|aggressive`. Following built-in help → `Unknown mode "report"`.

### U2 [HIGH] — Rewrite INSTALL.md's dead reviewer-mode table

INSTALL.md "Reviewer (v0.26.0)" lists `default | auto | report`; `report` was
dropped and `default`→`on` in 0.27.9. Rewrite around off/on/auto/aggressive.

### U3 [MED] — Update README's command surface

README.md:32 — "Four top-level commands, that's all" is false (`/review`
exists); config block lacks `/glla stats|audits|tooloverride|reviewer|
postaudit`, `/loop finish`, `/list resume`, `/list depth`.

### U4 [MED] — Fix README quick-start fence swallowing prose

README.md:32-70 — the code fence swallows "(Or just say it…)", the bold
"Order is the default" paragraph and a duplicated /list batch — visible `**`
and backticks on GitHub.

### U5 [MED] — Reorder CHANGELOG newest-first

CHANGELOG.md — the 0.28.0 entry (a headline feature) sits at the file END
(~line 2326); the top reads 0.27.9.

### U6 [MED] — Make tool-override confirmations speak outcomes

`goal.ts:3210-3250` — `toolOverrides.allow += bash` echoes internal paths.
Premium: "bash is now always visible to the agent (project override saved)."

### U7 [MED] — Humanize reviewer suppression reasons

`extensions/reviewer.ts:225-245`, surfaced at `goal.ts:739` — `Reviewer
suppressed: doNotFireOn: goal-complete` leaks raw config keys. Premium:
"Suppressed: this event type is excluded in /glla postaudit → fire-on."

### U8 [MED] — Gate the dracon-sync section in the continuation prompt

`prompts/goal-loop-continuation.md:93-106` — "DETACHED COMMIT DETECTION"
tells EVERY user's model to run `dracon-sync pause` and grep for a daemon
that exists only on the maintainer's rig; burns tokens and misleads elsewhere.
Published-package bug. Gate it or generalize it.

### U9 [MED] — Lead goal creation with the objective, not the ID

`goal.ts:912` — `Goal 20260728143012-a1b2c3 created — starting now.` leads
with the opaque ID and never echoes the objective. The plugin's own
convention elsewhere (cmdResume `:965`) is objective-first, ID trailing —
and the rig's naming discipline (pi-discipline/naming.md) demands it.

### U10 [LOW] — Fix the cryptic "list N" suffix for goal policy

`goal-loop-display.ts:147` — `glla: goal ● 3m 19s · list 29`; v0.24.7 fixed
this to "29 queued" for list policy but left "list 29" for goal policy.

### U11 [LOW] — Pick one name for reviewer/postaudit/review

`goal.ts:3264` menu title "Reviewer", settings row "Postaudit config…",
command /review. Three names, one thing.

### U12 [LOW] — Refresh stale doc numbers

README.md:311 "168 unit tests across 12 files" (actual: 496/53); INSTALL.md
title still "Install & try v0.1.0".

### U13 [LOW] — Delete repo-root litter files `then` and `pass`

Untracked 194B/106B files from botched shell redirects. Not in the npm
tarball, not (yet) committed — but the auto-commit daemon may pick them up.

---

## Stream 4 — Test coverage gaps (subagent)

Context: 53 test files split into (1) true unit tests of pure functions
(goal-loop-core/-backoff/-shield/-forever/-repetition/-display/reviewer/
settings-menu) and (2) source-grep tests that regex-match goal.ts text.
**No test constructs a mock ExtensionContext/ExtensionAPI and behaviorally
drives goal.ts's handlers.** Well-covered: auditor verdict parsing,
regression_shield (22 tests), backoff/heartbeat/pending-latch math, list
queue restore, loop-forever measurement.

### T1 [HIGH] — Pin stale-session goal persistence on BOTH entry paths

`extensions/loops/goal.ts:2408,2464-2470` (propose_goal_draft execute) and
`:882-913` (cmdSet). Two distinct stale-session failure shapes, neither
pinned: (a) tool path — stale `liveCtx.ui.confirm()` throws → caught →
`confirmed = false` → tool returns "Draft rejected by the user" — goal
silently never created, misleading tool result; (b) command path — `setGoal`
persists (sync fs; `refreshUI` try/caught at `:302-313`) but `ctx.ui.notify`
at `:912` can throw uncaught AFTER persist. Note the asymmetry with the
sraaal incident: command ctx is fresh (ui works), only the captured factory
`extensionApi` is stale (sendMessage dies) — which path throws depends on
WHICH handle the entry point captured. No test asserts goal state lands in
`.pi-glla/active.jsonl` when ctx UI methods throw.

### T2 [HIGH] — Behaviorally test stale-detect → pause → notify

`goal.ts:203-217` (goStaleTerminal), sends at `:539/:558/:1473`.
tests/stale-api-terminal.test.ts only regex-matches source text; nothing
executes the pause. The `sendLengthContinue` stale check (`:558`) isn't even
grep-pinned. Regression = goal keeps "running" into a dead handle (the S1
zombie) with all tests green.

### T3 [HIGH] — Pin session_start restore/activate wiring

`goal.ts:3960-4076`. Only `shouldAutoResumeOnSessionStart` is unit-tested;
the handler's branches are not: auto-activate-head via `activateNextListItem`
(`:4063-4068`, smoke.sh only), loop HOLD with HELD_ON_RESTORE persist (`:4026`,
zero tests), held-goal resume hints (`:4041-4053`), unconditional `refreshUI`
(`:4075`). Regression = unattended rigs restart with a queue and nothing runs.

### T4 [MED] — Test handleSettingChoice per-key editors, not just the table

`goal.ts:2960-3130` (21-case switch). v0.28.0 tests cover render/nav/cache
and row/id completeness only; no test executes an editor (select/input/
confirm → saveSettings with right scope/key/value). Regression = menu renders
and navigates perfectly while edits silently don't save.

### T5 [MED] — Pin the foreign-session tool guard on every mutating tool

`goal.ts:250-256`, called at 8 tool sites. Only pure `classifySessionCtx` is
tested. A new/renamed tool that forgets the guard lets a subagent session
mutate goal state — no test would catch it.

### T6 [MED] — Pin readState corruption tolerance

`extensions/goal-loop-core.ts:491-510`. Malformed-line skipping is tested for
the audit log and parseLedgerEntries but NOT for readState itself: a truncated
final line in active.jsonl after crash-mid-append throws on session_start →
goal/list/loop state lost on restart. Real data-loss-on-restart shape.

### T7 [LOW] — Build a thin mock-ctx test harness (the enabler)

~10 test files assert on goal.ts text. One harness (register tools on a fake
`pi`, fire events with a stub ctx) converts T1-T3 and T5 into real behavioral
pins and makes the regex tests redundant. Root-gap fix; do this FIRST among
the test items.

---

## Stream 5 — Post-compaction stall misfires (user-reported 2026-07-28)

User paste: three incidents across game-project sessions where goals whose
compaction summaries claim closure ("Goal closed: P1 stats panel…", "Goal
completed. F-01 fixed and approved.") ended `paused` with `stalled: 3
consecutive unproductive turns` at 9m32s / 1h17m / 8m37s. User: "not sure
its a stall really cause it was complete so perhaps we just forgot to close
it." Both halves confirmed in code.

Mechanism: work completes → model writes prose instead of calling
complete_goal → compaction → session replacement → extension re-hydrates →
continuations resume → model (now believing the summary's "closed" claim)
replies with short tool-less "awaiting next goal" prose →
`isNudgeTurn` (goal-loop-backoff.ts:229: 0 tools AND <15 words OR trigram
>0.6 vs prior turn — defaults at `:200-201`) counts each → 3 strikes → brake.

### P1 [HIGH] — Nudge the model before the stall brake fires

`extensions/loops/goal.ts:4125-4129` — `heartbeatNudges` increments silently;
NOTHING is sent to the model at strike 1 or 2. The first and only feedback is
the brake itself (`HEARTBEAT_MAX_NUDGES = 3`, goal-loop-backoff.ts:70). The
model never gets a course-correction chance.

Premium: graduated escalation — at strike ≥1 send a visible entry (same
customType channel as length-continue): "N no-tool turns. If the goal's work
is DONE call complete_goal now; if blocked call pause_goal with a reason;
otherwise act with tools. One more unproductive turn pauses the goal." Brake
stays as the final backstop.

### P2 [HIGH] — State "goal is ACTIVE and unclosed" in every continuation

`prompts/goal-loop-continuation.md` + `continuationPrompt`
(`extensions/loops/goal.ts:565+`) carry objective/contract/tasks/directives
but never state the goal's lifecycle status. Post-compaction the model trusts
the compaction summary's "Goal closed/completed" prose and answers the
continuation with "awaiting next goal" instead of closing — strikes accrue
on a done-but-unclosed goal. The prompt explains HOW to complete
(`:122-140`, good) but not THAT completion has not happened.

Premium: an explicit status block in every continuation: "State: ACTIVE —
not yet auditor-approved. Prose claims of completion close nothing; only an
approved complete_goal does. If the work is done, call complete_goal NOW."

### P3 [MED] — Grace turns after session re-hydration before stall counting

`heartbeatNudges` (`goal.ts:273`) is in-memory — it resets on re-hydration,
but then immediately counts the post-compaction re-orientation prose turns
that pi's own compaction flow produces. Premium: skip nudge accounting for
the first 1-2 agent_end events after a session_start restore (re-orientation
turns are tool-light by nature). Belt-and-braces behind P1.

### P4 [LOW] — Distinguish "stalled" from "done-but-unclosed" in pause reason

When the brake fires right after completion-signal text ("approved",
"committed", "awaiting next goal"), `stalled:` misleads the user about a
done goal. Premium: scan the last turn's text for completion signals → pause
reason "appears complete but never closed — /goal resume then complete_goal,
or /goal cancel". Mostly falls out of P1.

---

## Queue plan

Actionable findings → `list_add` items, verb-phrase titles, severity-ordered.
Live-pain fixes first, then the silent-retry and persistence hardening, then
the test enabler that protects them all, then polish. Each item gets its own
goal with a verification contract when activated.

1. **Auto-resume stale-interrupted goals; probe staleness at command entry —
   HIGH · S1–S4, E6.** Keep status="active" + interrupt marker in
   goStaleTerminal (goal.ts:204-217); surface marker in the widget for active
   goals; probe extensionApi in cmdGoal/cmdResume/cmdList/propose_goal_draft
   execute with honest "restart pi — state is safe" messaging; fix the
   tool-path "Draft rejected by the user" lie (goal.ts:2466-2471); notify on
   drafting-seed send failure (goal.ts:843-847). Fixes the sraaal incident
   class.
2. **Nudge before the stall brake; mark goals unclosed in continuations —
   HIGH · P1–P3.** Graduated escalation entry at strike ≥1 (goal.ts:4125);
   status block in prompts/goal-loop-continuation.md ("ACTIVE — not yet
   auditor-approved; prose closes nothing"); 1-2 grace turns after
   session_start restore. Fixes the three post-compaction stall incidents.
3. **Bound silent retry loops; make error brakes informative and
   self-recovering — HIGH · E2, E3, E8.** Count trailing auditor infra errors
   in auditHistory and pause loudly after ~3 (goal.ts:2167-2186); count +
   ledger the 50ms send-retry re-arms and escalate via escalateStallNow past
   a threshold (goal.ts:512-525, 1416-1422); consecutive-errors brake carries
   the real error text + auto-resumes with capped backoff before pausing
   permanently (goal.ts:4190-4200).
4. **Harden persistence integrity: guarded writes, degraded flag, tolerant
   readState — HIGH · E1, T6.** try/catch around ledger/state writes with a
   loud first-failure notify + TUI "persistence degraded" flag; never mutate
   in-memory state before the write succeeds; readState skips malformed
   trailing lines instead of throwing (goal-loop-core.ts:491-510) — with
   corruption-tolerance tests.
5. **Build mock-ctx harness for behavioral goal.ts tests — HIGH · T1–T5,
   T7.** Fake pi + stub ctx harness; convert stale paths, restore gate, tool
   guards, settings editors from regex-pins to behavioral pins. Retrofits
   real tests onto items 1-4.
6. **Fix phantom reviewer proposals; distinguish measure-broken from
   plateau — MED · E4, E5.** Only count/notify confirmed reviewer sends
   (goal.ts:728-735); track consecutive null-measure iterations and stop with
   "measure command broken" instead of "plateau" (goal-loop-forever.ts).
7. **Fix docs drift: /review help, INSTALL, README, CHANGELOG — MED ·
   U1–U5, U12, U13.** /review description → off|on|auto|aggressive; INSTALL
   reviewer section rewrite; README command surface + quick-start fence +
   test counts; CHANGELOG 0.28.0 entry to top; delete root litter
   `then`/`pass`.
8. **Humanize user-facing messages; gate rig-specific prompt section — MED ·
   U6–U11, E7.** tooloverride outcome language; reviewer suppression reasons;
   objective-first creation message; "N queued" suffix for goal policy; one
   reviewer vocabulary; gate the dracon-sync section in the continuation
   prompt; report reviewer-menu settings-save failures.

Totals: 36 findings — 12 HIGH, 16 MED, 8 LOW. Items 1-2 fix live incident
classes observed on this rig within the last 24h.
