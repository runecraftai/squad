# Architecture

How Squad works, in depth.

The [README](../README.md) carries the high-level diagram and a short synopsis.
This document expands every part of it.
Squad's always-loaded operating contract and routing index for conditional procedures is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Event-driven supervision

A zero-token bash sentry (`bin/sq-sentry.sh`) sleeps on the unit, classifies detected wakes in bash, and wakes the sergeant at arms only when something is actionable.
Actionable wakes include commander-relevant status signals, no-verb signals whose crew is not provably working, authenticated check output such as PR merge polling or a Relay mention, stale panes whose crew is not provably working whether their status log looks terminal or non-terminal, provably-working stale panes that persist past `SQUAD_STALE_ESCALATE_SECS`, declared external waits that remain paused past `SQUAD_PAUSE_RESURFACE_SECS`, and heartbeat backstop hits.
Repeated provably-working stale escalations on the same unchanged pane add an escalation count to the wake reason and, at `SQUAD_WEDGE_DEMAND_INSPECT_COUNT`, a `demand-deep-inspection` marker.
A busy pane is otherwise exempt from staleness, but only until its latest `state/<id>.turn-ended` marker reaches `SQUAD_BUSY_TURN_MAX_SECS`, or its `state/<id>.meta` spawn record reaches that age before any turn completes; past that bound it is routed through the same wedge escalation, with the identical reason, escalation count, and `demand-deep-inspection` marker, for inspection only - never an automatic interrupt, signal, or restart.
Those actionable wakes are written to a durable local queue (`state/.stand-to-queue`) before detector state advances, so a missed process exit can be recovered by draining the queue.
When a canonical validated PR poll returns exactly `merged`, the sentry appends that durable notification before publishing a private receipt bound to the poll's registration, bytes, file identities, metadata, provider, URL, and task ID.
The receipt makes retirement safely retryable across restarts: fixed-path recovery revalidates the same evidence, removes the runnable check first, removes its registration and data sidecars, removes the receipt last, and preserves task metadata including `pr=` and `pr_head=`.
A concurrent replacement remains armed, every non-merged or invalid observation remains unchanged, and retirement never performs task or persistent-XO cleanup.
`bin/sq-pr-lib.sh` owns the receipt format and strict identity mechanics, while `bin/sq-sentry.sh` owns queue-before-retirement ordering.
No-verb wakes, such as `working:` notes and bare turn-ended signals, are benign only when `bin/sq-crew-state.sh` reports positive evidence that the operator is still working: an actively running no-mistakes step attributed to that crew's current code, or an exact busy verdict from the semantic busy-state contract.
A crew that declares `paused:` for a known external wait is separately absorbed while idle and re-surfaced only on the longer pause cadence, rather than being treated as a possible wedge.
For an ordinary crew that has stopped, the normal-mode sentry first surfaces one stale wake, then applies that same cadence to an unchanged `paused:` or durable `commander-held` endpoint only when the backend confidently reports its agent dead.
Live or inconclusive liveness remains fail-open at that initial surface, and the XO idle-endpoint exemption is unchanged.
Its initial normal-mode status signal still surfaces through the no-verb path, while away mode self-handles that routine signal and owns the later recheck.
Fresh stale panes use the same current-state read before trusting the status log, so an active run or a proven busy worker outranks an old commander-relevant status-log line left behind before validation.
No-change heartbeats are also benign.
Absorbed wakes advance their suppression markers, log to `state/.sentry-triage.log`, and keep the sentry blocking without a queue record or LLM turn.
After each drain, `sq-stand-to-drain.sh` runs the same liveness guard as the supervision scripts, so a lapsed sentry chain surfaces even on a turn that only drains and handles queued wakes.
Routine sentry polling, supervision no-ops, elapsed waiting time, and absorbed benign wakes stay silent.
A declared external wait trades that silence for one bounded recheck per pause window, so a forgotten pause cannot remain invisible indefinitely.
Crew status files are append-only wake-event logs, not current-state fields.
Because of that, a per-wake read of only the latest line can bury an earlier still-open `needs-decision`/`blocked` under later unrelated appends; `sq-stand-to-drain.sh` prints a separate, unit-wide OPEN DECISIONS section on every drain (including the empty-queue path session-start relies on), built through `sq-classify-lib.sh`'s cursor-backed incremental scan using the authoritative `status_open_decisions` fold semantics so the buried decision keeps surfacing until it is explicitly resolved while each drain reads only new status-log appends.
The explicit resolution is written by the actor that answers, not the busy worker: `sq-send`'s `--resolve-key` appends the closing `resolved` line to this home's own copy of the ledger at answer time, which covers operators, local XOs, and remote XOs identically because a remote mate's escalations reach that local copy through the parent-replies ingest and only the answer message itself crosses the transport.
`bin/sq-crew-state.sh <id>` is the cheap current-state read for an actionable heartbeat review: it attributes a no-mistakes run, active or terminal, only when it matches the operator's branch and current code identity, then keeps that run-step authoritative even if the pane has closed.
The script header owns the exact run-head ancestry rules.
During no-mistakes' `ci` monitor phase, it also reads the ci step log tail because `axi status` reports both "still waiting on checks" and "checks green, waiting on merge" as `ci,running`.
The most recent recognized ci log marker wins, so checks-green monitoring reports done while a later re-arm, failed-check, or issue marker returns the operator to working.
Only when no matching run exists does it consult semantic busy state; exact busy reports working, exact idle permits fallback to a status-log event whose verb maps to a recognized run-state, and unknown or a dead pane stays unknown instead of trusting a stale log.
Decision-only events such as `resolved` never become current state or leak their prose into the current-state detail.
In that status-log fallback, a declared external wait reports the distinct `paused` state with its reason.
The semantic branch reports working only on an exact busy verdict and names the source that produced it; an unknown verdict never becomes working, never permits the status-log fallback, and never becomes a silent idle.
For whole-unit read-only review, `bin/sq-unit-snapshot.sh --json` emits schema `sq-unit-snapshot.v1` from the backlog, task metadata, current crew state, endpoint probes, PR/report pointers, recon reports, bounded current summaries from registered XO homes, and XO return-channel guidance.
`bin/sq-unit-view.sh` renders that snapshot as Markdown for humans, while `bin/sq-sitrep-snapshot.sh` provides the bounded sitrep projection, so both views consume one structured contract instead of reparsing raw unit files.
The script header owns the exact JSON schema.

### Registered XO current state

A registered XO's validated home is the authority for sitrep current state because it owns the child metadata inventory, each child's current-state result, endpoint observations, backlog holds and dependencies, keyed unresolved decisions, and recent Done baseline.
The original cross-home projection instead treated the XO agent as an ordinary parent task, so an idle XO's `sq-crew-state` fallback selected the latest append-only parent status event even when structured state in the registered home contradicted it.
The parent-status contract also required explicit keyed resolution for decisions and blockers but not for a material `working` phase, so a start event could remain unsuperseded after the corresponding home backlog had moved the work to Done.
Generated XO charters reject generic receipt or start acknowledgements, key only supervisor-actionable material phase reports, and close an opened phase with a same-key later state or `resolved` event, while the structured home remains authoritative even if that closure is missing.
Cross-home reads validate the seeded identity and operational-directory boundaries, use per-home time and output bounds, and classify unavailable, malformed, or inconsistent structured state as unknown rather than reviving a parent event as current work.
When only an owned child's current classification is unavailable, the home classification stays unknown while independently trustworthy structured decisions, holds, queued and landed records, endpoint identities, counts, and provenance remain available; every other invalid path stays strict and exposes none of those child-derived surfaces.
A bounded direct-report terminal tail can help diagnose a mismatch by showing that historical parent wording is still visible, but it is untrusted supplemental evidence because scrollback, prompts, copied output, idle shells, and agent prose are not durable state.
The snapshot strips control sequences, retains only capture metadata and literal event-corroboration flags, and never lets terminal evidence override a valid structured classification.
The default path remains local-only; live GitHub enrichment exists only behind the sitrep `--include-prs` opt-in.
Optional Relay integrates with the sentry only after explicit opt-in; [configuration.md](configuration.md#relay-env) owns its generated-artifact and dispatch mechanics.

At session start, `bin/sq-session-start.sh` emits exactly one primary-harness supervision block rendered by `bin/sq-supervision-instructions.sh` from `docs/supervision-protocols/`.
That block owns the live wait shape for the running primary harness: Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, and OpenCode uses its TUI plugin.
`bin/sq-sentry-arm.sh` remains the verified arm wrapper for protocols that call it; it forks the sentry as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints an honest `started`, `attached`, or nonzero `FAILED` status.
[`sentry-continuity.md`](sentry-continuity.md#arm-layer-cycle-contract) owns the arm layer's successor, terminal-delivery, and typed clean-close failure contract.
The arm layer records one bounded lifecycle row per observed cycle in `state/.watch-cycle-exits.log`; `state/.sentry-triage.log` remains exclusively the absorbed-wake debug log.
Pi and OpenCode verify session-lock ownership and launch one singleton successor from their child-close handlers before delivering an actionable wake prompt, with bounded exponential retry for failed restoration.
Claude's `bin/sq-claude-stop-autoarm.sh` hook fires on every Stop and, when the home is eligible and still needs supervision, claims one home-scoped cycle, foregrounds the arm wrapper, and translates actionable closes into exit-2 rewakes.
It suppresses failed-looking closes when the same identity-matched sentry is healthy, retries genuine failures within a bound, and coordinates exhausted failure episodes with the Claude turn-end guard as documented in [`turnend-guard.md`](turnend-guard.md).
[`sentry-continuity.md`](sentry-continuity.md) owns Claude's residual active-turn coverage and sentry-status command-gating boundary.
The existing turn-end guard remains the final backstop for all five harness-engine protocols, with pi-signed sharing Pi's protocol and the `--claude` mode cooperating with the auto-arm claim.
Its `--restart` mode signals only the sentry recorded in the current home's `state/.sentry.lock`, so restarting one home cannot kill sibling XO sentrys.
A pull-based guard (`bin/sq-guard.sh`) warns through supervision tool output if the primary checkout is tangled, if work, process-event sources, or Relay polling has an unhealthy model-aware supervision verdict, or if queued wakes are waiting to be drained.
The drain script calls that guard after emptying the queue, which avoids repeating the queued-wakes warning for records it just consumed while still warning on unhealthy supervision.
It leads with a prominent bordered tangle banner, while `bin/sq-guard.sh` owns the sentry-down banner and reminder policy so repeated guarded commands stay noisy without reprinting the full banner in the same episode.
On every verified primary harness, tracked hook integration gives the primary session a push-based backstop: when work, a process-event source, or Relay polling needs supervision and no identity-matched sentry lock with a fresh beacon is live, direct Stop hooks block and passive turn-end hooks force one bounded follow-up.
The guard covers the main primary and genuinely marked XO homes, exempts child operator/recon worktrees, is loop-safe per harness, and is documented in [turnend-guard.md](turnend-guard.md).

A presence-gated sub-supervisor (`bin/sq-supervise-daemon.sh`) extends this for walk-away supervision: the `/afk` skill starts it through the tracked foreground helper `bin/sq-afk-start.sh`, after which the sentry reverts to daemon-managed one-shot mode and the daemon self-handles routine wakes in bash.
The sentry and daemon share `bin/sq-classify-lib.sh` for commander-relevant status verbs, declared-external-wait vocabulary, and status-scan primitives.
Terminal verbs remain commander-relevant, while a nonterminal progress verb cannot become terminal merely because its prose contains a legacy free-text token such as `merged`; bare legacy free-text lines remain compatible.
The always-on sentry also uses that library's absorb classification on no-verb signals and first-sighting stale panes before status-log terminality is trusted, while the daemon maintains distinct wedge and declared-pause recheck cadences.
In away mode, seen-status dedupe does not clear possible-wedge aging for nonterminal progress, so housekeeping still re-escalates an unchanged idle pane at the configured bound.
The daemon escalates commander-relevant events, plus a bounded recheck for a declared pause that remains idle, as one batched, single-line digest using the canonical `away-supervisor` kind from `bin/sq-operational-input.sh` so Squad can distinguish it structurally from real messages.
Its supervisor injection path supports tmux and herdr panes, with `SQUAD_SUPERVISOR_BACKEND` and `SQUAD_SUPERVISOR_TARGET` resolved independently from the task-spawn backend.
Pane existence, busy checks, composer checks, capture, and verified submit route through `bin/sq-backend.sh`: tmux keeps the same submit core used by the tmux send backend, while herdr uses native busy state, native agent-state submit confirmation on idle baselines, and its ANSI-aware structural composer classifier for pending-input guards and submit fallback.
The tmux submit core (shared `fm_tmux_submit_enter_core`) treats a busy pane + retries-exhausted + composer-still-pending as a queued Enter (opencode 1.18.4 accepts Enter mid-turn and queues it for after the turn), reported as `empty` so the daemon and `sq-send` do not re-send; an idle pane keeps the `pending` verdict as a genuine swallow. The same opencode busy-queue case is a known gap on the herdr adapter and is recorded in `docs/herdr-backend.md` rather than patched here.
Composer-content classification has one shared owner, `bin/sq-composer-lib.sh`, used by tmux, herdr, Orca, and cmux after each adapter performs its own capture and composer-row recognition.
The daemon injects only into an affirmatively `empty` composer, so both `pending` and `unknown` defer and a bare dead-shell prompt cannot receive an escalation; the current boundary is in [Composer and injection safety](herdr-backend.md#composer-and-injection-safety).
Unsupported supervisor backends refuse at daemon startup.
Stalled escalation delivery writes `state/.subsuper-inject-wedged` and attempts a configured backend-independent active alert after `SQUAD_MAX_DEFER_SECS` instead of silently deferring forever.
On an unmarked return, `bin/sq-afk-return.sh` owns ordered shutdown, durable catch-up evidence, and the fail-closed gate that keeps ordinary work behind every live Squad-actionable blocker.
`sq-send.sh` selects a pre-Enter popup-settle for slash commands and for codex `$...` skill invocations using metadata-routed target `harness=` values, then adds its own `SQUAD_SEND_SETTLE` pause after successful text sends so immediate peeks catch the receiving turn starting; the sub-supervisor uses only the shared submit core and does not pay that post-submit pause.

## Busy state is semantic, per adapter

`bin/sq-busy-lib.sh` is the single owner of what "this worker is busy" means, and `bin/sq-busy-event.sh` is the only writer of the per-task records it reads.
Every classification returns a verdict of busy, idle, unknown, or dead together with the source that produced it, so a consumer or a diagnostic can never confuse semantic state with a fallback.

Each converted adapter reports its own turn lifecycle through a machine-readable contract the vendor already exposes, rather than through rendered footer text: Pi and pi-signed through the Squad-owned extension's `agent_start` and `agent_settled` confirmed by `ctx.isIdle()`, OpenCode through its plugin's semantic `session.status`, and Claude through owned `UserPromptSubmit`, `Stop`, `StopFailure`, and `SessionEnd` hooks.
Kimi behind Pi inherits Pi's lifecycle.
Codex and standalone Kimi classify unknown behind explicit probes until a semantic source is live-verified for them, and Grok keeps one clearly isolated rendered-tail fallback that can only ever classify a Grok task.

Missing, malformed, stale, untrusted, or unverified semantic state is unknown, never idle, and unknown is never promoted to busy either.
Ordinary task-state consumers act only on an exact busy verdict, so an unreadable worker surfaces for a closer look instead of being absorbed as still-working or written off as finished.
Endpoint death is the only process-level override and yields dead; child processes, CPU, process sleep state, and marker modification times are not state signals.
`state/<id>.turn-ended` files remain wake notifications, not current state.

Each record is bound to an incarnation token minted when the task's wiring is armed, so an event from a superseded incarnation is rejected rather than applied, and a record left behind by one classifies unknown.
Three rendered-text readers deliberately remain outside this contract because they answer delivery questions: the submit acknowledgement and away-mode supervisor-pane busy guard in `bin/sq-tmux-lib.sh`, and the XO delivery-confirmation observation in `bin/sq-pending-reply-lib.sh`.
All are harness-scoped rather than a global pattern union, and none is a recorded worker state source.

## Runtime session backends

The runtime backend is the session-provider layer below Squad's scripts.
It owns task endpoint creation, bounded capture, text/key sends, current-path reads for spawn-time worktree discovery when the backend does not create the worktree itself, live-window fallback lookup, agent-process liveness probes where verified, and endpoint teardown.
`bin/sq-backend.sh` centralizes backend selection, `state/<id>.meta` helpers, metadata-only cleanup identity validation, selector resolution, and operation dispatch; `bin/backends/tmux.sh` is the verified reference adapter ([`docs/tmux-backend.md`](tmux-backend.md)), and `bin/backends/herdr.sh` (P2), `bin/backends/zellij.sh` (P3), `bin/backends/orca.sh` (P4), and `bin/backends/cmux.sh` (P5) are experimental task-spawn adapters.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns new-spawn backend selection precedence and authorization.
Runtime auto-detection is innermost-first: `$TMUX` wins over `HERDR_ENV=1`, which wins over cmux's primary `CMUX_WORKSPACE_ID` marker and documented fallback signals; auto-detected herdr or cmux prints a one-time opt-out notice, auto-detected tmux stays silent, and zellij and orca are never auto-detected (only explicit selection).
Unknown backend names fail loudly.
For compatibility, default tmux tasks do not write `backend=tmux`; every reader treats a missing `backend=` field as `tmux`.
`sq-sentry.sh` decides each window's busy state through the semantic contract above rather than by polling the backend for rendered text.
Herdr's native `agent.get` verdict still participates, but only as evidence of activity: a native `busy` is accepted when the task has no record of its own, while a native `idle` is not, because `agent.get` reports generation state and reads idle while a worker blocks on its own long-running foreground tool call.
tmux, zellij, orca, and cmux expose no native busy primitive at all, so a task on those backends is classified purely from its adapter's own lifecycle record.
That poll loop is still the default event source for backends with no native push events, so this stays an extraction of the abstraction rather than a sentry rewrite.
For capable Herdr sessions, the same sentry replaces its terminal sleep with a bounded native event wait that immediately surfaces `blocked`; [Push events and polling fallback](herdr-backend.md#push-events-and-polling-fallback) owns the current mechanism and capability gates, while [runtime backend verification](verification/runtime-backends.md#native-blocked-event) owns the active evidence.
The deeper session-start agent-process liveness probe is separate from that busy-state poll: tmux and Herdr have verified classifiers for XO recovery, Zellij remains unverified, and Orca and cmux do not support XO spawns.
Herdr is experimental and can be selected explicitly or by runtime auto-detection: FOB remains its worktree provider, [`herdr-backend.md`](herdr-backend.md) owns current setup and safety limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) owns active empirical evidence.
Herdr uses one tab per task; [Watching and task containers](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, and recovery scope.
Its default-on presentation projection may place one clean new task in a disposable workspace without changing endpoint authority or lifecycle ownership; [Presentation spaces](herdr-backend.md#presentation-spaces) owns that conditional design, the Herdr version floor its unconfigured default is gated behind, and its narrow home-local restored-shell cleanup at locked session start.
Zellij is experimental and selected only explicitly: FOB remains its worktree provider, [`zellij-backend.md`](zellij-backend.md) owns current setup and limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#zellij) owns active empirical evidence.
Zellij's container shape is simpler than herdr's: one shared `Squad` session, one tab per task, with no per-home workspace split; visible tab titles are scoped by the active home label plus a short hash of the resolved `SQUAD_ROOT` path.
Orca is experimental and selected only explicitly: Orca owns both worktree and terminal lifecycle, records `orca_worktree_id=` and `terminal=`, and removes worktrees through `orca worktree rm` only after the usual Squad teardown checks pass.
[`orca-backend.md`](orca-backend.md) owns current behavior and limitations, while [`verification/runtime-backends.md`](verification/runtime-backends.md#orca) owns active smoke evidence.
cmux is experimental, GUI-first, macOS-only, and can be selected explicitly or by runtime auto-detection from its primary `CMUX_WORKSPACE_ID` marker plus documented fallback signals: FOB remains its worktree provider, [`cmux-backend.md`](cmux-backend.md) owns current setup and limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#cmux) owns active source and live evidence.
cmux's container shape is one workspace per task with one surface, no per-home container split; workspace titles are scoped by the active home label plus a short hash of the resolved `SQUAD_ROOT` path, and `--xo` spawns are refused, mirroring Orca.
Codex App support is recorded in `docs/codex-app-backend.md`; it is not selectable as a runtime backend.

## Worktrees, not branches in your checkout

Operators never intentionally touch your project clone; [fob](https://github.com/squad-org/squad/tree/main/packages/fob  # OQ-03 placeholder: Squad org at publication) pools clean worktrees for tmux, herdr, zellij, and cmux tasks, while Orca creates its own worktrees for `backend=orca`.
For ship and recon work, `sq-spawn.sh` refuses to launch unless the resolved task path is a real git worktree root that is distinct from the project primary checkout.

The Squad repo has one extra exposure because it can dispatch operators to work on itself.
Its operating checkout (`SQUAD_ROOT`) and the disposable operator worktrees are all linked git worktrees of the same repository, so the valid discriminator is branch state, not whether the checkout is linked.
The primary checkout is healthy on its default branch, and linked worktrees or XO homes are healthy at detached HEAD.
Only a named non-default branch checked out in `SQUAD_ROOT` is a worktree tangle.

`sq-tangle-lib.sh` resolves the default branch from `origin/HEAD`, then local `main` or `master`, and classifies that named non-default primary branch as the tangle.
`sq-guard.sh` prints the repair command on the next mutable unit action, while `bin/sq-session-start.sh` reports the same condition through bootstrap as a `TANGLE:` line at session start.
If another live session holds the unit lock, both surfaces keep the alarm but switch to read-only wording with no repair command.
Ship briefs also tell the operator to verify `pwd -P` and `git rev-parse --show-toplevel` before creating `fm/<id>`, then stop with a blocked status if it landed in the primary checkout.

## No-mistakes gate authority boundary

Squad's own no-mistakes gate runs agents inside a checkout that also contains the unit-commander identity in `AGENTS.md`, so gate execution needs an authority boundary separate from ordinary operator worktree isolation.
The tracked `.no-mistakes.yaml` sets `disable_project_settings: true`; no-mistakes honors that setting only from the trusted default-branch copy, so a pushed branch cannot enable its own project instructions during validation.
Independently, `sq-spawn.sh`, `sq-send.sh`, and `sq-teardown.sh` source `bin/sq-gate-refuse-lib.sh` and exit with status 3 before unit mutation when the gate environment marker is present or the current checkout matches the default no-mistakes gate-repository topology.
A normal primary checkout or operator worktree has neither signal and remains unaffected.
The helper's header owns the exact signal detection, relocated-home limitation, test-harness bypass, and relationship to no-mistakes' HEAD-continuity guard.

## Two task shapes

Strike tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); recon tasks leave standalone investigation reports at `data/<id>/report.md` and never push.
The intake and authority contract in `AGENTS.md` owns when separate recon research is warranted.

## Dispatch profiles

Operator and recon dispatch can stay on the static operator harness resolved by `config/crew-harness`, or it can use local dispatch profiles in `config/crew-dispatch.json`.
The dispatch file is intentionally judgment-based: Squad reads the natural-language rules at intake, chooses the best matching rule, resolves profile arrays itself from current quota output under the `AGENTS.md` section 4 intake boundary and the `quota-array-dispatch` selection procedure, and passes only concrete `--harness`, `--model`, and `--effort` axes to `sq-spawn.sh`.
The shell scripts validate the JSON shape and verified harness/effort combinations, but they do not parse task intent, match natural-language rules, or own array selection.
The session-start bootstrap step keeps valid dispatch configuration silent unless verbose facts are enabled and surfaces a concise invalid-config line when validation fails.
When the file exists, `sq-spawn.sh` refuses operator and recon launches without an explicit harness, so `config/crew-harness` is only automatic when no dispatch profile file is active.
XO launches are exempt because they resolve the XO harness and any optional XO model or effort tokens instead.
Unsupported effort values are still recorded in task meta when passed to `sq-spawn.sh`, but the launch template omits any effort flag that the selected harness does not accept.
That keeps spawn launch compatible across claude, codex, opencode, pi, pi-signed, grok, kimi, and muse while preserving the requested profile for later audit.

## Optional XOs

`data/XOs.md` records persistent XOs with natural-language scopes, project clone lists, and home paths.
A local route points directly at its home, while a remote route adds an SSH alias and remote Squad code root so the entire home and all of its child work stay on that host.
Remote placement pins the remote second-mate agent to Herdr while leaving the remote home's worker backend selection independent, and every non-doctor primary-to-remote `sq-on` command runs through the remote account's Squad-owned job worker rather than its SSH process or a Herdr pane.
[`remote-XOs.md`](remote-XOs.md) owns current setup, supplied-origin provisioning, transport, relay, failure, and retirement behavior.
`sq-home-seed.sh` provisions a local isolated home, clones the listed PR-based projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and `sq-spawn.sh --xo` launches it through the same session-provider and status-file path as any direct report.
For a domain whose subject is the Squad repo itself, a deliberate `--no-projects` seed creates a project-less home whose operators take pooled worktrees of that repo instead of separate clones.
The signal cannot be mixed with project names or omitted accidentally, and a populated home cannot be converted in place; the full seed contract is in [configuration.md](configuration.md#XO-routes-dataXOsmd).
Herdr XO and child placement follows the launcher-binding contract in [Watching and task containers](herdr-backend.md#watching-and-task-containers).
When seeded with `-`, the home is a durable fob lease under the XO id, so it survives with no live process and is not recycled by later `fob get` or pruning.
Retirement or seed rollback returns the leased home; normal restart/recovery keeps it leased.
If returning the lease fails during teardown, Squad leaves the route and home intact instead of hiding a still-held lease.
Seeding is transactional: if validation, cloning, initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.
`local-only` projects stay with the main sergeant at arms because they merge into the main local checkout instead of a remote-backed PR path.
The same project may appear in multiple XO homes when their scopes differ, such as issue triage versus feature development.
XOs are idle by default: after startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tasks, and they never self-initiate surveys or audits.
When called with `SQUAD_HOME=<this-Squad-home>` or when `SQUAD_HOME` is already set to the active Squad home, metadata-routed `sq-send.sh` requests to a live `kind=xo` use the live-charter-compatible `from-squad` carrier owned by `bin/sq-operational-input.sh`, so the XO returns terse answers through status lines and detailed answers through docs plus status pointers instead of replying only in its own chat.
The parent guards every marked request against a missing correlated report without reading the XO conversation; `bin/sq-pending-reply-lib.sh` owns the correlation, recovery, escalation, and retention contract.
Explicit backend-target sends and direct human typing stay unmarked, so commander intervention in an XO pane remains conversational.
After seeding an XO, `sq-backlog-handoff.sh` validates the unit-specific handoff, then atomically delegates already-judged in-scope queued item moves to `tasks-axi mv` so the domain queue starts in the right place.
Remote routes move that dependency-closed set into a non-dispatchable backlog-format outbox before transfer, then use an idempotent remote receive under the destination backlog's own lock.
The outbox is the complete retry record, so no two-phase journal or transport-level retry is needed.
An unreachable remote host is unknown rather than dead, preserves its route and durable work, and is never failed over or relaunched locally.
Idle XO panes are healthy; teardown is explicit and refuses while the XO home has in-flight work unless the commander has approved discard with `--force`.

XO homes converge conservatively to the primary's version and declared inherited local material at launch and during locked session start.
The [`xo-provisioning` skill](../.agents/skills/xo-provisioning/SKILL.md) owns the full guarded sync, propagation, nudge, and mid-session local-material push contract.

XO agents can run on a different verified harness than operators.
`config/xo-harness` controls the primary's XO launch harness and may also carry optional model and effort tokens as `<harness> [<model>] [<effort>]` on the first non-empty, non-comment line.
A bare harness line remains harness-only, so existing `config/xo-harness` files keep their previous behavior.
When the harness token is unset or `default`, launch falls back to `config/crew-harness`, then to the primary's own harness, and the model and effort tokens are ignored.
Those optional tokens are re-read on every XO spawn or respawn and are overridden by explicit per-spawn `--model` or `--effort` flags.
For a local route, an explicit per-spawn harness or raw launch command does not inherit model or effort tokens from `config/xo-harness`.
Remote routes accept verified harness adapters only and reject raw launch commands.
`config/crew-harness` remains the operator harness and is inherited into XO homes.
`config/crew-dispatch.json` is inherited too; XOs use the same natural-language dispatch profiles when spawning their own operators.
The [`xo-provisioning` skill](../.agents/skills/xo-provisioning/SKILL.md) owns the complete inherited-local-material allowlist and propagation contract.

The `data/XOs.md` line contract is owned by the [`xo-provisioning` skill](../.agents/skills/xo-provisioning/SKILL.md#routing-table), and the XO environment variables are documented in [configuration.md](configuration.md).

## Delivery modes are explicit per task

`no-mistakes` tasks run the full validation pipeline, `direct-PR` tasks open PRs without that pipeline, and `local-only` tasks stay local until Squad performs an approved fast-forward merge.
Each task's mode and `yolo` posture are Squad's decision at intake and are passed explicitly to `bin/sq-brief.sh`, `bin/sq-spawn.sh`, and `bin/sq-promote.sh`, which refuse a strike task that does not carry them.
A ship brief records its mode as a fixed machine-readable line and the spawn refuses to launch on a different one, so the worker's instructions and the recorded task delivery cannot diverge.
`data/projects.md` records each project's standing posture and optional `+yolo` flag as the commander's default and as context for that decision, including the conditional `no-mistakes-prod-only` policy; a ship spawn that drops below the registered rigor prints a deviation notice and continues.
`bin/sq-project-mode.sh` remains the one registry parser for the mechanical consumers that have no task in hand: unit sync's `local-only` skip and home seeding's refusal and no-mistakes initialization.
When a selected delivery path calls for a diff, `bin/sq-review-diff.sh` refreshes the authoritative base and, when task meta records `pr=`, always fetches and compares against `refs/pull/<n>/head` by default (recorded `pr_head=` is only an offline fallback) before falling back to the local branch with a warning.
For target project repos shipped through their own no-mistakes pipeline, commits under `.no-mistakes/evidence/` are the pipeline's PR-viewable validation evidence and are expected to stay in the operator branch until the evidence-hosting design changes.
The Squad repo itself is the exception: its `.no-mistakes/` directory is local state, stays gitignored, and is rejected by CI if tracked.
PR-based task merges go through `bin/sq-pr-merge.sh`, which records `pr=` and any available `pr_head=` through `bin/sq-pr-check.sh` before calling `gh-axi pr merge`.
The helper requires a full `https://github.com/<owner>/<repo>/pull/<n>` URL, invokes `gh-axi pr merge <n> --repo <owner>/<repo>`, defaults to `--squash`, preserves explicit merge-method flags, and rejects malformed URLs or repo override flags before recording merge state; a well-formed GitLab merge request URL (see [docs/gitlab-merge-watch.md](gitlab-merge-watch.md)) is refused too, explicitly, rather than sent to the wrong forge.
Teardown is fail-closed for ship worktrees: dirty worktrees refuse, and committed work must be landed before the worktree is returned.
[`bin/sq-teardown.sh`](../bin/sq-teardown.sh)'s header owns the landed-work proofs, PR-discovery fallback, and stale-lock recovery procedure.

## Optional Relay

Relay is opt-in presence for the shared `@mySquad` bot on both public surfaces it supports, X and Discord.
A user enables it by putting `SQX_PAIRING_TOKEN` in the Squad home's gitignored `.env`; `SQX_RELAY_URL` is optional and defaults to `https://mySquad.io`.
That token is standing authorization for Squad to answer public mentions and act autonomously on normal reversible mention requests.
Destructive, irreversible, or security-sensitive asks are escalated for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner, while parent-thread context may still include other public accounts.
On the locked session-start bootstrap step, that token creates the local polling and sentry-cadence artifacts described in the [Relay configuration reference](configuration.md#relay-env).
Without the token, the locked session-start bootstrap step removes those artifacts on opt-out and otherwise stays silent, so non-Relay users see no behavior change.
Newly offered mentions are stored as `state/x-inbox/<request_id>.json` and wake Squad once per retained request ID; the [Relay configuration reference](configuration.md#relay-env) owns the durable offer-marker and re-offer contract.
The `relay-respond` agent-only skill drains that inbox, uses `in_reply_to` parent-post context for conversational continuity, classifies each mention as an actionable request, question, or pure acknowledgment, and submits public-safe replies through `bin/sq-x-reply.sh`.
When a reply has a real visual artifact, `--image <path>` attaches one local PNG, JPEG, GIF, WebP, BMP, or TIFF to the relay's optional `{media_type,data_base64}` image object.
Actionable reversible requests run through Squad's normal intake, backlog, dispatch, investigation, or ship lifecycle.
Work that completes in the answering turn gets one outcome reply.
Work that spawns a longer-running task gets an acknowledgement reply first; `bin/sq-x-link.sh` records `x_request=`, `x_request_ts=`, `x_followups=0`, and optional reply-platform context in that task's `state/<id>.meta`, while durable per-request context preserves the original platform and budget independently of task links and inbox cleanup.
Later milestone wakes use `bin/sq-x-followup.sh` to post up to three public-safe follow-ups through the relay's `connector/followup` endpoint, ending with a `--final` one for ordinary Relay-linked work. A typed promised-final commitment owns its terminal reply through `bin/sq-public-followup.sh`; after its receipt is validated, `bin/sq-x-followup.sh --clear <task-id>` removes any legacy link without posting another reply.
The [Relay configuration reference](configuration.md#relay-env) owns the exact context retention, platform-resolution, and fail-safe posting contract.
If recovery relinks the same relay request onto a successor task, `sq-x-link.sh --carry-count <n> --carry-ts <epoch> --carry-platform <x|discord> --carry-max <n>` preserves the consumed follow-up count, original 7-day window, and reply split budget instead of granting a fresh local budget or falling back to the wrong platform.
The follow-up helper forwards `--image <path>` to the same reply client when a follow-up needs an image.
Each follow-up is bounded by a local 7-day window and a 3-post cap; a successful non-final post increments the counter and keeps the link, while `--final`, reaching the cap, the window lapsing, or the relay itself rejecting an exhausted binding all clear it, and the helper is skipped for tasks that did not originate from a Relay mention.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/sq-x-dismiss.sh`, which calls the relay's `connector/dismiss` endpoint and posts no text, then the local inbox file is cleared.
Concise replies stay single unnumbered messages; genuinely long replies are split by the client into bounded, numbered threads using the target platform's reply budget, with `texts` carrying the ordered chunks for the relay.
Splitting preserves fenced-code, paragraph, line, and word boundaries when possible.
If an image is attached to a split reply, the relay puts it on the first/opener message only and leaves later chunks text-only.
For preview testing, `SQX_DRY_RUN` makes `sq-x-reply.sh` and `sq-x-dismiss.sh` skip the public post or dismiss call and record the would-be payload under `state/x-outbox/`, including `texts` when the reply would be a thread and an `endpoint` marker when the preview is a completion follow-up or dismiss, while the rest of the poll -> compose -> would-post loop still succeeds.
Attached images are recorded as compact `{media_type, bytes, source_path}` metadata in dry-run instead of base64 bytes.
Relay remains layered on top of the existing check mechanism without changing its request-handling behavior.

A promised *final* public reply is a stronger commitment than a milestone follow-up, because forgetting it is publicly visible.
It is therefore not carried in conversation memory at all: intake turns it into a typed `kind=public-followup` obligation owned by `tasks-axi public-followup`, and every later step reads that obligation from disk.
The mechanism boundary is deliberately narrow.
`tasks-axi` owns the obligation state machine and is the only thing that validates a terminal result's source home, work id, generation, schema, outcome, and deliverables.
`state/x-context/` remains the only owner of the private full request context.
`bin/sq-x-reply.sh` remains the only thing that posts.
`bin/sq-public-followup.sh` composes those three and adds nothing of its own beyond the activation gate, a private terminal-event inbox, and the idempotent delivery sequence.
Work routed to another home reports a *typed* terminal result through `bin/sq-public-followup-emit.sh`; Squad never recovers the source home, work id, outcome, or deliverables by parsing a free-form `done:` sentence, and the child never learns the thread.
Because a terminal event's id is derived from its identity tuple rather than generated, duplicate reports and restart replay converge without coordination.
Reconciliation rides the existing relay poll and the session-start digest instead of a new sentry, daemon, or timer, and both are gated on the same `.env` activation contract so a home that never opted into the relay executes none of it.
The [Relay configuration reference](configuration.md#promised-public-replies-statepublic-followup) owns the operator-facing contract, and the `relay-respond` skill owns the procedure.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
Ship briefs prompt operators to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
Each project `AGENTS.md` carries a short `## Maintaining this file` self-governance section; `bin/sq-ensure-agents-md.sh` owns the canonical wording and injects it idempotently when creating the skeleton, promoting an existing `CLAUDE.md`, or reconciling an existing `AGENTS.md` that still lacks it.
It refuses a case-variant real memory file such as a lowercase `agents.md`, whose `CLAUDE.md` symlink would carry an uppercase literal target that dangles on a case-sensitive filesystem, and surfaces the mismatch for manual reconciliation.
The full ownership rule - what is project-intrinsic versus unit-private, and how Squad keeps the two apart without writing into project clones - is owned by [`AGENTS.md`](../AGENTS.md) (project and knowledge management).

## Operational memory routing

`/debrief` sweeps the current session for durable knowledge that only exists in conversation and routes each finding to the most specific disk home.
Home-domain commander preferences go to `data/commander.md`, cross-domain shared commander preferences go to the primary home's `data/commander-shared.md`, unit-local operational facts and gotchas go to home-local `data/learnings.md`, project-intrinsic knowledge goes through normal operator delivery into that project's committed `AGENTS.md`, and task-scoped notes or undone next steps go to the backlog.
Memory writes use inspect-then-update: read the current destination first, then rewrite or prune matching bullets or notes in place instead of appending by default.
Task-scoped notes use `tasks-axi show <id> --full` followed by `tasks-axi update <id> --body-file <path>`, adding `--archive-body` when the prior body should remain recoverable.
Generalizable Squad knowledge goes to shared tracked docs through the normal PR pipeline; the Squad-internal `/debrief` deliberately never stores findings in either skill directory.
Invoked in a primary home, `/debrief` then cascades the same sweep to every registered XO, enumerated through `bin/sq-debrief-cascade.sh`: each home is accounted and curated against its own startup-memory allowance, a live XO sweeps its own session, and a slow or unreachable home is reported as an exception rather than blocking the primary.

## Local clones stay fresh

The locked session-start deferred network stage, PR-based teardown, and merged-PR wake handling refresh remote-backed project clones when the clone is safe to move.
Wake-time refreshes can target a single clone by project name, so the primary home also catches up when an XO reports a merge from its own home.
Clean default-branch clones fast-forward to `origin/<default>`, and a clean detached HEAD that holds no unique commits is re-attached to the default branch before the same fast-forward path runs.
Dirty clones, non-default branches, detached HEADs with unique commits, diverged defaults, and default branches checked out in another worktree are reported as `STUCK:` with their behind count and left untouched.
Fetches blocked by an orphaned `.git/packed-refs.lock` use bounded retries and remove the lock only when the shared staleness proof can prove it abandoned; [configuration.md](configuration.md#toolchain) owns the recovery details and tuning knobs.
Local-only projects, clones without an origin remote, and fetch failures remain benign skips.
The refresh also prunes local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

`/updatesquad` fast-forwards the running Squad repo and registered XO homes from `origin`, then re-reads updated instructions and nudges updated XOs without touching project clones.
For a remote route, the configured code root updates from its own origin on that host before the persistent home fast-forwards to the code-root commit.
The update is fast-forward only: dirty, diverged, offline, and off-default targets are reported and left untouched.
Local homes share the guarded fast-forward helper, while remote updates delegate the same safety decision to the configured host through the generic transport.
The mechanics are owned by the `/updatesquad` skill and Squad's operating manual in [`AGENTS.md`](../AGENTS.md) (self-update).

## Restart-proof

Unit state lives in each task's session-provider backend (tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected), no-mistakes run records, status event logs, local markdown under `data/` including `data/commander.md`, `data/commander-shared.md`, and `data/learnings.md`, and persistent XO homes.
For herdr, respawning after a server-restored layout closes and replaces confirmed no-agent or dead task-tab husks instead of requiring manual tab cleanup.
At session start, confirmed-dead XO agent endpoints are closed and relaunched through the same XO spawn path, while ambiguous liveness reads are left untouched to avoid duplicate supervisors.
Use `/debrief` before an intentional reset when the conversation may hold durable knowledge that has not yet been written to disk; after that, the next Squad session can reconcile and carry on.

## Development notes

The current sentry reliability work combines always-on bash triage with a durable queue for actionable wakes, a race-proof singleton lock, duplicate self-eviction, drain-time liveness assertion, and a self-verifying tracked-child arm wrapper.
The presence-gated sub-supervisor (`bin/sq-supervise-daemon.sh`) provides walk-away supervision via the `/afk` skill while reusing the same shared wake classifier as the always-on sentry.
