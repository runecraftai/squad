# Configuration

The files and environment variables you set to operate Squad.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the unit is empty, or dispatch shared-repo edits to an operator while tasks are in flight.

## Operational base layout and state

This section is the single owner of the top-level operational-base layout; producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains the shared instruction, skill, documentation, workflow, and `bin/` surfaces, while each effective `SQUAD_BASE` contains private operational directories.
`data/` holds durable private unit records such as the project and XO registries, commander preferences, optional shared commander preferences, learnings, backlog, briefs, and recon reports.
`state/` holds volatile runtime records such as task metadata, append-only status events, endpoint signals, sentry and stand-to queue coordination, away-mode state, generated Relay artifacts, private XO config-reread generations with their retry and quarantine state, and parent-owned XO pending-reply records under `state/pending-replies/` (`bin/sq-pending-reply-lib.sh`).
`state/window-states` is the derived per-window tmux sidebar truth published by `bin/sq-window-state.sh`; that script's header owns the file contract, and `bin/sq-crew-state.sh` remains the owner of the current-state reconciliation it publishes.
`config/` holds local gitignored operating choices, and `projects/` holds the local project clones that Squad reads but changes only through the narrow guarded and concrete commander-approved exceptions in `AGENTS.md`.

`bin/sq-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.
The producing PR and Relay helpers own the fields they append, `bin/sq-classify-lib.sh` owns status-event vocabulary, and `bin/sq-crew-state.sh` owns current-state reconciliation.
Wake, sentry, away-mode, and Relay-specific state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

`bin/sq-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.
`bin/sq-startup-network.sh`'s header owns the deferred network stage that keeps every external-network call off that digest's blocking path, including its state files and the safety argument for running them later.
`docs/sessionstart-nudge.md` owns the native session-open adapter tiers that run or nudge the digest command, and the source routing between them.
`AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.
Ordinary dead-direct-report recovery is owned by `stuck-operator-recovery`, while persistent-XO recovery is owned by `xo-provisioning`.

## Pi Calm preference (config/calm)

The Pi Calm extension stores the commander's base-local presentation choice in gitignored `config/calm` under the effective Squad base, resolved from `SQUAD_BASE`, then legacy `SQUAD_HOME`, then `SQUAD_ROOT_OVERRIDE`, then the tracked code root derived from the extension path, or under `SQUAD_CONFIG_OVERRIDE` when that test and specialized-setup override is present.
The only values it writes are `on` and `off`, each followed by one newline; an absent, unreadable, or unrecognized value defaults to off.
The `/calm` command replaces the file atomically before changing live presentation, so a failed write leaves the current choice unchanged rather than claiming persistence.
The extension reloads this preference on every Pi `session_start`, including startup, new, resume, fork, and reload reasons.
This preference is local to each Squad base and is not part of XO inherited configuration.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `sq-tasks` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `sq-tasks` is on `PATH`, Squad uses its verbs for routine backlog mutations.
XO handoffs are separate and unconditional: `sq-backlog-handoff.sh` keeps only its own unit-level validation and always delegates the item move to `sq-tasks mv`, the single owner of the backlog format.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their base for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `sq-tasks` on `PATH` on every profile, that delegation works unit-wide, and the `config/backlog-backend=manual` knob governs Squad's own hand-editing of its backlog, not this validated helper.
Compatible means the installed build passes the shared version and feature probe owned by [`bin/sq-tasks-lib.sh`](../bin/sq-tasks-lib.sh), including the atomic multi-ID move required by handoff delegation.
Bootstrap requires compatible `sq-tasks` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: sq-tasks available` fact, not missing-tool reporting.
Absent (or any non-manual value) selects the default sq-tasks backend.
The file format is unchanged in both modes; sq-tasks and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

## Runtime backend (config/backend / SQUAD_BACKEND)

For spawn-capable adapters, the runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.
`tmux` is the verified reference backend (see [`docs/tmux-backend.md`](tmux-backend.md)); `herdr`, `zellij`, `orca`, and `cmux` are experimental spawn backends (see [`docs/herdr-backend.md`](herdr-backend.md), [`docs/zellij-backend.md`](zellij-backend.md), [`docs/orca-backend.md`](orca-backend.md), and [`docs/cmux-backend.md`](cmux-backend.md)).
FOB remains the worktree provider for tmux, herdr, zellij, and cmux, since herdr, zellij, and cmux are session providers only; Orca provides both the task worktree and terminal endpoint.
New spawns choose the backend in this order: an explicit `--backend` flag that current authority for that exact task alone has authorized (a present commander instruction or the task's own accepted brief; never later-task precedent by analogy), then `SQUAD_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux or herdr started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is always checked last.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent.
Auto-detected herdr or cmux prints a stderr notice naming `config/backend` and `--backend tmux` as opt-outs; auto-detected tmux stays silent to preserve existing default behavior.
Zellij and Orca are never auto-detected; select them by putting the name in a local `config/backend` file, by exporting `SQUAD_BACKEND=<name>`, or by telling the sergeant at arms in chat.
Any value other than `tmux`, `herdr`, `zellij`, `orca`, or `cmux` is rejected until another adapter is implemented and verified.
`sq-spawn.sh` accepts `tmux`, `herdr`, `zellij`, `orca`, and `cmux` for ship and recon tasks; `backend=orca` and `backend=cmux` both still refuse `--xo` until XO launch semantics are designed for each.
`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](codex-app-backend.md) owns the Codex App boundary.
The session-start XO liveness sweep uses the recovery-grade `fm_backend_agent_state` classifier where verified.
The comment above that function in `bin/sq-backend.sh` is the single owner of its detailed state contract and recovery authorization.
The compatibility helper `fm_backend_agent_alive` continues to collapse those detailed results to `alive`, `dead`, or `unknown` for older callers.
A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.
A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.
A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.
A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; Squad surfaces it as a blocker instead of silently retrying another backend.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.
Every new task records `endpoint_task_id=` as the cleanup binding between the metadata filename and its opaque runtime endpoint.
A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.
A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
An Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=sq-<id>` kept as the shared Squad alias.
A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.
Task selectors for `sq-peek.sh`, `sq-send.sh`, and `sq-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `sq-<id>` label fallback, so task ids that themselves start with `sq-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.
Only metadata-routed task selectors carry XO-marker and Codex-harness context; explicit endpoint escape hatches do not.
These five sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`sq-teardown.sh <id>` takes a task id directly and validates the complete metadata-only endpoint identity before any runtime dispatch or cleanup mutation.
Missing, empty, duplicate, malformed, backend-inconsistent, or task-mismatched endpoint records are preserved and refused.
Legacy tmux metadata remains cleanup-compatible when its exact window name is `sq-<id>`; opaque non-tmux endpoints require their recorded `endpoint_task_id=` binding.
`SQUAD_BASE` determines Herdr's base label: the primary base uses `Squad`, and an XO base marked by `.sq-xo-home` uses `xo-<XO-id>`.
[`herdr-backend.md`](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, collision handling, and recovery behavior.
The local `config/herdr-presentation-spaces` file instead opts a base out of, or explicitly in to, Herdr's default-on disposable single-task visual projection; [Presentation spaces](herdr-backend.md#presentation-spaces) owns its accepted values, default, Herdr version floor, migration, behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
The setting is inherited into XO bases under the primary-authoritative contract owned by [`xo-provisioning`](../.agents/skills/xo-provisioning/SKILL.md).
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.
For normal zellij operations, `SQUAD_ZELLIJ_SESSION` selects the named session and defaults to `Squad`.
Zellij has no per-base workspace split: primary and XO tasks share that one session, and visible tab titles are scoped by the active `SQUAD_BASE` readable label plus a short hash of the resolved `SQUAD_ROOT` path as `sq-<base-label>-<id>`.
Use the guarded cleanup path described in [`docs/zellij-backend.md`](zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.
cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `sq-<id>`, but the actual cmux workspace title is scoped by the active `SQUAD_BASE` readable label plus a short hash of the resolved `SQUAD_ROOT` path as `sq-<base-label>-<id>`.
Test cleanup must use the guarded path in [`docs/cmux-backend.md`](cmux-backend.md#current-operation-and-safety), never enumerate-and-close every workspace.
`config/backend` is inherited into XO bases under the primary-authoritative contract owned by [`xo-provisioning`](../.agents/skills/xo-provisioning/SKILL.md).

## Away-mode supervisor backend (SQUAD_SUPERVISOR_BACKEND / SQUAD_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into Squad's own pane independently of where new task endpoints are spawned.
It currently supports only `tmux` and `herdr` supervisor panes.
Set `SQUAD_SUPERVISOR_BACKEND=tmux|herdr` and `SQUAD_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.
That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `SQUAD_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the legacy `Squad:0` tmux fallback with a warning.
Selecting any other supervisor backend, including `zellij`, `orca`, or `cmux`, refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `SQUAD_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the commander even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`SQUAD_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the current channel reference, [`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) for active evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Trace context propagation (config/trace-context / SQUAD_TRACE_CONTEXT)

The optional local, gitignored `config/trace-context` presence flag enables default-off native W3C trace-context propagation.
`SQUAD_TRACE_CONTEXT` overrides the file: `1`/`on`/`true`/`yes` enables, any other non-empty value disables, and unset or empty defers to the file.
Each locked base session resolves those inputs once, and all spawns from that base use the frozen decision until a new session starts.
When launching an XO, the primary copies the presence flag into its base and passes the primary session's frozen decision as a non-empty `SQUAD_TRACE_CONTEXT=on|off` override for the XO's own session start.
An XO on a remote route is covered the same way: the primary resolves and records that task's carrier, and the configured host exports it and receives the same enablement snapshot.
The presence flag is session-scoped enablement, so it transfers at launch and is left unchanged by live convergence into a running base.
See [`trace-context.md`](trace-context.md) for carrier semantics, supported routes, the manual unit-restart requirement, the session boundary, and safety limits; `bin/sq-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](verification/trace-context.md) records repeatable evidence.

## Gate defaults (.drill.yaml)

The tracked `.drill.yaml` keeps test evidence outside the repo and pins `commands.lint` to `bin/sq-lint.sh` so local lint matches CI.
That evidence policy is specific to the Squad repo: target projects may legitimately commit `.drill/evidence/` from their own drill pipeline, but Squad keeps `.drill/` local and CI rejects tracked entries under that path.
It does not set `commands.test` to a complete `tests/*.test.sh` walk.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the Squad-specific local test policy and entry points.
Portable shard evidence and coverage rules are in [sq-test-portable-shards.md](sq-test-portable-shards.md); [herdr-backend.md](herdr-backend.md#destructive-lab-safety) owns the real-Herdr lane's isolation boundary, and [runtime-backends.md](verification/runtime-backends.md#herdr) owns active evidence.

## Commander Preferences (data/commander.md / data/commander-shared.md)

Domain-local preferences for one commander's unit live locally in each base's `data/commander.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/XOs.md`.
Before changing it, inspect the current file and rewrite or prune the matching bullet in place; add a new bullet only for a genuinely new durable preference.
Shared commander preferences that apply across XO domains live only in the primary base's optional `data/commander-shared.md`.
`xo-provisioning` owns its propagation contract, including the required header, read-only XO copies, quarantine diagnostics, and the rollout rule that existing bases trim `data/commander.md` by hand after first propagation rather than deleting private content automatically.

## Operational learnings (data/learnings.md)

Unit-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the commander-preference files in the session-start context digest.
The file is created lazily on first learning and follows the same dated, evidence-backed, curated style as `data/commander.md`: inspect the current file first, then rewrite or prune stale entries instead of appending forever.
There is no shared learnings file by commander decision.

## Startup memory budget (config/startup-memory-budget)

`config/startup-memory-budget` is the primary-authoritative per-base allowance for the startup prompt-memory surface: `data/commander.md`, `data/commander-shared.md`, and `data/learnings.md` together.
The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary base when the file is absent.
To select another allowance, replace the primary base's file with one valid positive value in the exact format below; the next locked bootstrap convergence or `bin/sq-config-push.sh` propagates it to registered XOs.
An XO does not create an independent default and instead receives the primary value through the inherited-local-material contract in [`xo-provisioning`](../.agents/skills/xo-provisioning/SKILL.md).
The file must be one positive base-10 integer followed by exactly one newline in a regular, single-linked file beneath a non-symlinked `config/` directory.
Malformed, multi-line, symlinked, hardlinked, special, or otherwise unsafe values are rejected rather than treated as a default.
Use `bin/sq-startup-memory-budget.sh read` to validate and print the effective value, or `bin/sq-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.
An inherited `data/commander-shared.md` counts in an XO's total but remains primary-owned and read-only there.
The internal [`/debrief` skill](../.agents/skills/debrief/SKILL.md) owns curation and its automatic XO cascade, which accounts every base against this same per-base allowance separately rather than against a unit total.
The helper's header owns exact parsing, publication, and report output mechanics.

## XO routes (data/XOs.md)

Persistent XO routes live locally in `data/XOs.md`.
The concise single-line route contract is owned by the [`xo-provisioning` skill](../.agents/skills/xo-provisioning/SKILL.md#routing-table), including the parser-compatible fields, one-sentence summary requirement, `home:` pointer to the seeded charter, and limit on extra registry prose.
A remote route adds `host:` and `root:` before the existing fields and places the whole XO base on that SSH host; it does not make ordinary workers remotely placeable.
[`remote-XOs.md`](remote-XOs.md) owns current remote setup, operation, and safety behavior.
Use `sq-home-seed.sh validate` to check the complete operational registry contract documented by the command itself.
The main sergeant at arms routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `sq-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh local Squad worktree for the XO base.
For remote provisioning, including supplied project origins, follow [Remote second mates](remote-XOs.md#provision-a-route).
Use the deliberate `--no-projects` signal only for a Squad-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.
A project-less seed requires no existing project clones or `data/projects.md` entries in the base, so it refuses a populated-base conversion without changing that base.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.
The lease is held under the XO id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the base.
Teardown of a leased base fails closed if `fob return` cannot release the lease; plain-clone bases with no fob pool slot are removed directly.
XO routes cover `drill` and `direct-PR` projects; `local-only` projects remain main-Squad work.
For `drill` projects, seeding initializes only projects newly cloned into an XO base and refuses to mutate a preexisting clone that is not already initialized.
After creating an XO, move existing main-backlog queued items that you have judged in-scope with `sq-backlog-handoff.sh <XO-id> <item-key>...`; it is idempotent and refuses In flight, Done, or non-XO bases.
Set `SQUAD_XO_CHARTER` to seed from inline charter text when no filled charter brief exists; set `SQUAD_XO_SCOPE` when the routing scope should differ from the charter text.
The seeded base's `data/charter.md` owns the standard XO lifecycle and escalation contract; the route file points to it through the existing `home:` field instead of adding another pointer.
Each seed writes an `.sq-xo-home` identity marker at the base root, alongside a durable `.sq-xo-parent` record of the base's route to its parent (see "Provision a route" in [`docs/remote-XOs.md`](remote-XOs.md)).
The tracked root `.gitignore` ignores both markers, so validation can read them without making a freshly seeded base appear dirty to porcelain-based safety checks.
This does not relax protection for any other untracked file.
An existing linked-worktree base that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.
A standalone-clone base cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updatesquad`'s origin refresh instead.

## SQUAD_BASE

`SQUAD_BASE` selects the operational base for one Squad instance.
When it is unset, most scripts use the repo root as the base; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$SQUAD_BASE`.
`SQUAD_HOME` remains accepted as a permanent legacy read fallback: when `SQUAD_BASE` is unset or empty, scripts resolve `SQUAD_HOME` instead, and `SQUAD_BASE` always takes precedence when both are set.
`SQUAD_ROOT_OVERRIDE` overrides the Squad repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When neither `SQUAD_BASE` nor `SQUAD_HOME` is set, `SQUAD_ROOT_OVERRIDE` behaves as the old whole-root override.
`bin/sq-send.sh` is intentionally stricter than that general fallback: it requires `SQUAD_BASE` (or legacy `SQUAD_HOME`) to be set before resolving a target, so operator steers cannot silently resolve against the wrong base.
`SQUAD_STATE_OVERRIDE`, `SQUAD_DATA_OVERRIDE`, `SQUAD_PROJECTS_OVERRIDE`, and `SQUAD_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
Before `sq-brief.sh`, `sq-spawn.sh`, or `sq-afk-launch.sh` persists a path or passes it to another process, it resolves each applicable relative `SQUAD_BASE` (or legacy `SQUAD_HOME`), `SQUAD_STATE_OVERRIDE`, or `SQUAD_DATA_OVERRIDE` directory against the caller's working directory, preserves absolute spellings unchanged, and rejects an unresolvable relative directory with the offending variable named.
Bootstrap applies the same relative `SQUAD_BASE` resolution only when embedding that base in the generated Relay poll shim; other transient consumers retain their existing shell-relative behavior.
For the herdr backend, `SQUAD_BASE` also determines the workspace label used by the adapter.
For the zellij backend, `SQUAD_BASE` does not split containers, but it determines the readable base prefix embedded in visible tab titles; use `SQUAD_ZELLIJ_SESSION` when a separate zellij session is needed.
The full zellij base label also includes a short hash of the resolved `SQUAD_ROOT` path.
For the cmux backend, `SQUAD_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read from, while `SQUAD_BASE` determines the default config path and readable base prefix embedded in workspace titles.
The full cmux base label also includes a short hash of the resolved `SQUAD_ROOT` path, and there is no per-base container split.

## Harness support

claude, codex, opencode, pi, pi-signed, grok, and kimi are empirically verified for operator and XO launches; [README requirements](../README.md#requirements) own the set supported for the primary session.
muse is verified for operator and recon launches ONLY, and `sq-spawn.sh` refuses it for an XO, because muse ships no usable hook surface for a primary session's turn-end supervision; [`docs/verification/muse.md`](verification/muse.md) owns that evidence.
muse also needs a worker-reachable credential before spawning, and the portable unit path is the `<config>/muse/auth.json` credential stored by `muse login`, because a caller-only `META_API_KEY` does not cross a long-lived backend daemon.
New harnesses get verified through a supervised trial task before joining the set.
The verified adapter knowledge - each harness's busy-state source, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
Launch mechanics, including the verified command templates, live in [`bin/sq-spawn.sh`](../bin/sq-spawn.sh).
Enabled primary-session turn-end guard integrations are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
Kimi remains outside the primary turn-end guard integrations; [`docs/turnend-guard.md`](turnend-guard.md#compatibility-limits) owns its separate commander-approved crew wake hook.
Primary-session sentry wake protocols are rendered at session start by [`bin/sq-supervision-instructions.sh`](../bin/sq-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, and OpenCode uses its TUI plugin.
`config/crew-harness` is a local, gitignored file containing one adapter name for operator and recon launches.
When pi-signed is selected, Squad launches the executable named `pi-signed` from `PATH` with `SQUAD_PI_HARNESS=pi-signed` and refuses the launch if it is unavailable rather than falling back to pi.
Plain Pi launches set `SQUAD_PI_HARNESS=pi`, so a signed primary's environment cannot relabel a plain Pi worker.
When it is absent or contains `default`, operators mirror the Squad's own harness.
`config/xo-harness` is a separate local, gitignored file containing the adapter the primary uses to launch XO agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, XO launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`sq-harness.sh XO-model` and `sq-harness.sh XO-effort` expose only the optional tokens from `config/xo-harness`; `config/crew-harness` remains a bare adapter-name file.
An explicit harness argument to `sq-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/xo-harness`; for a local route, an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
Remote XO routes accept verified harness adapters only and reject raw launch commands.
When `config/crew-dispatch.json` exists, operator and recon spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
The inherited-local-material contract is owned by [`xo-provisioning`](../.agents/skills/xo-provisioning/SKILL.md); its harness-relevant consequence is that an XO's own operators use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `sq-spawn` still permits a consciously chosen explicit runtime outside the config.
`config/xo-harness` is not inherited because XOs do not launch XOs.
For grok, `sq-spawn.sh` installs one Squad-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.sq-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Kimi operators, `sq-spawn.sh` runs `sq-kimi-turnend-hook.sh install`, drops a per-task `.sq-kimi-turnend` pointer in the worktree, and records the matching private registry token for teardown.
Kimi continues to use the commander's normal Kimi home, including the existing config, skills, and memory; Squad does not create an isolated Kimi home.
The Kimi installer requires an existing regular non-symlink `~/.kimi-code/config.toml`, `python3` with `tomllib`, and `jq`; it validates but never serializes the commander's TOML and refuses before writing when the config is missing, malformed, or surprising or when either tool requirement is unavailable.
Its `remove` action excises only the marker-delimited Squad region and removes Squad's hook files.
For Pi and pi-signed XO launches, `sq-spawn.sh` starts the selected executable with `-e` pointed at the XO base's own tracked `.pi/extensions/sq-primary-pi-watch.ts` and `.pi/extensions/sq-primary-turnend-guard.ts`, both already present from the XO base's git worktree.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that Squad reads before dispatching an operator or recon.
The shell scripts do not match those rules; Squad chooses the best matching rule with judgment, resolves its profile object or array under the operating contract in `AGENTS.md` section 4 and `quota-array-dispatch`, and passes only concrete `--harness`, `--model`, and `--effort` flags to `sq-spawn.sh`.
When the file exists, `sq-spawn.sh` enforces that contract by refusing operator and recon spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
XO spawns are exempt and still resolve through `config/xo-harness` and its optional model and effort tokens.
This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `quota-array-dispatch` owns the completion-aware profile-array selection procedure.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" }
      ],
      "why": "<optional rationale that helps Squad choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

Per rule, `when` and `use` are required.
Both `use` and the optional top-level `default` accept either one profile object or a non-empty array of profile objects.
The single-object form stays fully backward-compatible, and every profile needs `harness`.
Profile `model` and `effort` fields and rule `why` are optional.
An omitted model or effort means the selected harness uses its own default for that axis.
Every profile array is an implicit quota-aware choice resolved through `quota-array-dispatch`.
If no dispatch rule fits, Squad resolves `default` through the same object-or-array path before falling back to `config/crew-harness`.
If a selected profile carries an effort value the chosen harness does not accept, `sq-spawn.sh` records the requested `effort=` in task meta for traceability but omits the launch flag, and bootstrap reports the invalid harness/effort pair as a `CREW_DISPATCH` diagnostic when it is visible in the file.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `SQUAD_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
Malformed JSON, an empty or malformed rule/default array, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
Additionally, for pi-family harnesses (pi, pi-signed, opencode), bootstrap resolves every configured `model` id against the harness's own `--list-models` output and reports `CREW_DISPATCH: model existence:` when the id matches zero models or more than one model.
A probe that cannot run surfaces explicit uncertainty rather than a hard failure.
While the file remains present, no operator or recon spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.
XO bases inherit this file from the primary, so an XO's own operators apply the same dispatch profile behavior.

## Toolchain

On session start the sergeant at arms detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every base needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this base.
The universal toolchain is node, git, gh with GitHub auth via `gh auth login`, drill v1.31.2 or newer, compatible sq-gh, sq-browser, compatible sq-report, compatible sq-tasks per "Backlog backend" above, and compatible sq-quota.
[`bin/sq-bootstrap.sh`](../bin/sq-bootstrap.sh) owns the axi-family floor policy and the sq-gh and sq-report floors, while [`bin/sq-tasks-lib.sh`](../bin/sq-tasks-lib.sh) and [`bin/sq-quota-lib.sh`](../bin/sq-quota-lib.sh) hold their own tools' floor constants.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, drill runs the validation pipeline, sq-gh, sq-browser, and sq-report cover GitHub, browser, and rich-review operations, and sq-tasks plus sq-quota back backlog mutations and quota-aware array dispatch.
Frontend validation tooling - Playwright MCP, the Playwright CLI, and the automatic PR visual-validation pattern - is covered in [playwright-validation.md](playwright-validation.md).
The per-backend delta is required only for the backend resolved from `SQUAD_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a base is never told to install a tool an inactive backend or feature would need.
That delta is owned in code by `fm_backend_required_tools` in `bin/sq-backend.sh`: the resolved backend's own session-provider CLI (`tmux`, `herdr`, `zellij`, `orca`, or `cmux`), `jq` for the JSON-emitting experimental adapters (`herdr`, `zellij`, `cmux`) whose spawn and liveness paths parse the backend's JSON output, and the `fob` worktree provider for every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`).
Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.
Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `fob` and every other backend's session CLI.
A herdr, zellij, or cmux base is therefore never told `tmux` is missing, and the `fob` durable-lease upgrade check runs only for the backends that actually use fob.
When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
When Relay is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
`sq-tasks` and `sq-quota` are required bootstrap tools in every profile, the same class as `sq-report`.
An absent or incompatible `sq-tasks` reports `MISSING: sq-tasks (install: (cd packages/sq-tasks && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build) && npm install -g ./packages/sq-tasks)`; when `config/backlog-backend` is not `manual` and compatible `sq-tasks` is on `PATH`, bootstrap stays silent and Squad uses its verbs for routine backlog mutations, otherwise it hand-edits `data/backlog.md` until installation is approved and completed.
An absent or incompatible `sq-gh` reports `MISSING: sq-gh (install: (cd packages/sq-gh && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build) && npm install -g ./packages/sq-gh && sq-gh setup hooks)`.
An absent or incompatible `sq-report` reports `MISSING: sq-report (install: (cd packages/sq-report && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build) && npm install -g ./packages/sq-report && sq-report setup hooks)`.
An absent or too-old `sq-quota` reports `MISSING: sq-quota (install: (cd packages/sq-quota && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build) && npm install -g ./packages/sq-quota)`; Squad cannot resolve a profile array without a compatible binary.
Bootstrap also reports a `TANGLE:` line when `SQUAD_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the unit lock, the same line is advisory and omits the checkout command.
The locked session-start deferred network stage runs bootstrap's best-effort project clone refresh through `sq-unit-sync.sh`.
It emits `UNIT_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Normal completed runs keep local-only and no-origin skips silent.
If bootstrap kills a timed-out refresh, it replays any completed `sq-unit-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `sq-unit-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `sq-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The same deferred network stage runs bootstrap's guarded XO sync for recorded live bases, then propagates declared inherited local material into each validated live base.
Local routes use direct guarded filesystem operations, while remote routes delegate sync and allowlisted transfer through their configured SSH host without probing any unconfigured unit.
It emits `XO_SYNC:` only when a base was skipped for an actionable sync reason, inheritance failed, or a divergent shared commander-preference copy was quarantined.
When a running base advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `sq-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_XOS:` with the failure reason.
The same bootstrap run emits `XO_LIVENESS:` only when a registered XO is skipped or its relaunch fails; already-live and successfully relaunched XOs are handled silently.
For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/sq-config-push.sh`.
It uses the same live XO discovery and propagation helper as bootstrap, prints each live base's `crew-dispatch.json`, `crew-harness`, `backlog-backend`, `backend`, `herdr-presentation-spaces`, `startup-memory-budget`, `trace-context`, and `data/commander-shared.md` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero for real propagation errors or config-reread send failures.
When an allowlisted config item changes for an already-running local base, it sends the literal-content reread pointer described in [`xo-provisioning`](../.agents/skills/xo-provisioning/SKILL.md); unchanged allowlisted config sends no pointer unless a previous delivery is pending.
A changed remote base instead receives one durably recorded marked re-read instruction after the allowlisted bytes have transferred because primary-local generation paths are not meaningful on another host.
The locked bootstrap inheritance pass uses the same placement-specific behavior; see `xo-provisioning` for the single contract owner.
That live discovery starts from `state/*.meta` records with `kind=xo`; `data/XOs.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## Relay (.env)

Relay lets a Squad instance answer public mentions and act on normal reversible mention requests through Squad's normal lifecycle.
It covers both public surfaces the relay supports: `@mySquad` mentions on X, and mentions of the mySquad bot in a Discord server where it is installed.
Both surfaces are the same opt-in and the same machinery - one pairing token, one relay poll, and one reply path - so everything below applies to Discord mentions unless a line names a platform explicitly.
It is off unless the Squad base's gitignored `.env` contains a non-empty `SQX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a base is from that base's owner/commander, while parent-thread context may still include other public accounts.
`SQX_RELAY_URL` is optional and defaults to `https://mySquad.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so sentry artifacts are explicit local opt-in state.
`SQX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

To turn it on:

1. Sign in at [mySquad.io](https://mySquad.io) with X or Discord.
2. For the Discord surface, use the dashboard's install link to add the mySquad bot to a server you administer; the X surface needs no install step.
3. Copy the pairing token from the dashboard into this Squad base's gitignored `.env` as `SQX_PAIRING_TOKEN=<token>`.
4. Start a new Squad session so bootstrap picks the token up, then mention `@mySquad` on X or mention the bot in a server where it is installed.

The dashboard owns account creation, identity linking, bot installation, and token issuance; this document owns only what the local Squad base does with the token once it is in `.env`.

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-sentry.check.sh`, a byte-static identity shim for `bin/sq-x-poll.sh`, and `config/x-mode.env`, which exports `SQUAD_CHECK_INTERVAL=30` for sentry processes in that base.
The sentry accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section is the single owner of the Relay cadence contract: a Relay instance polls every 30 seconds instead of the default 300, only a Relay instance speeds up because a non-Relay base has no `config/x-mode.env`, and the session-start supervision operating block includes the cadence instruction when that file exists.
The active primary-harness supervision protocol owns how that sourced cadence reaches the sentry process.
Because `bin/sq-sentry.sh` reads `SQUAD_CHECK_INTERVAL` only at process start, a cadence transition - opt-in while a sentry is already running, or opt-out - is applied by restarting the base-scoped sentry through the emitted harness protocol; bootstrap deliberately never restarts the sentry itself.
While away mode is active the daemon owns the sentry and its default cadence applies; away-mode Relay cadence is a deferred follow-up.
When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.
Relay remains additive to non-Relay lifecycle behavior: bases without the generated artifacts keep the default sentry cadence and do not run the Relay poll.
Its request handling remains in Relay-specific `bin/` scripts and the `relay-respond` skill, while the sentry owns authenticated dispatch from the generated local identity shim.

`bin/sq-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <SQX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A newly offered pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes Squad exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before emitting that wake, and subsequent offers of the same request stay silent even after the inbox is drained following an answer or dismiss.
Offer markers share the context registry's bounded seven-day retention, so losing or expiring the local marker lets a relay offer wake Squad again.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
At the same time the poll records a durable per-request reply context at `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`) from the same authoritative relay payload, best-effort and keyed by `request_id` so concurrent requests never overwrite each other; it survives the inbox cleanup that follows the acknowledgement, so a delayed follow-up can recover the original platform and split budget even with no task link.
`recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.
The `relay-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, Squad posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/sq-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, finishing with a `--final` one for ordinary Relay-linked work. When a typed promised-final commitment is registered, `bin/sq-public-followup.sh` owns the terminal reply and clears the legacy link after its receipt is validated.
That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.
Platform/budget resolution is layered and independent of the task link: a per-axis `SQX_REPLY_PLATFORM` / `SQX_REPLY_MAX_CHARS` override (how `bin/sq-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/sq-x-lib.sh:fmx_resolve_reply_context` owns the source order: the durable per-request registry is consulted first, then the still-present inbox payload, then - for a follow-up posted live by request_id - an authoritative relay lookup via `POST /connector/request-context` (`{request_id}` in, `{platform, reply_max_chars}` back).
This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.
`bin/sq-x-link.sh` follows the same ordering when recording a fresh link's context and requires `jq`; its request-context lookup is best-effort: no token or `curl`; a non-2xx response; an unresolved response; or a relay version without that endpoint leaves the context unknown.
In that case the link is still recorded but `bin/sq-x-link.sh` prints a loud warning; and when either a follow-up's platform or explicit budget cannot be authoritatively resolved from any source, `bin/sq-x-reply.sh` refuses it (fail-safe exit 8) rather than posting with a local default - Squad holds and retries it once both values are recoverable.
Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/sq-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it clears that request's durable reply-context record, while the separate offer marker remains for its bounded retention so a brief relay re-offer stays silent.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
A failed durable offer claim is likewise reported once as `x-mode-error cannot record mention offer` and remains deduplicated through quiet no-pending polls until a later offer confirms an existing valid marker or claims a new one.
Live replies are posted by `bin/sq-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
Completion follow-ups use `bin/sq-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/sq-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.
A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
`sq-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
It treats `sq-x-reply.sh`'s fail-safe refusal (exit 8: platform or explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once both values can be recovered, never posted with a local default.
Past-window relay rejections are only guaranteed while the expired binding row still exists on the relay side; after its cleanup sweep, a very-late follow-up call may instead see a benign no-op 200, which is why the local window and cap pruning remains the primary guard.
Reply splitting is platform-aware: an explicit relay platform field (`reply_platform`, `platform`, `target_platform`, `source_platform`, or `provider`) wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric `tweet_id` selects X.
An explicit relay limit field (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit`, or `max_chars`) wins over the platform defaults.
If the reply exceeds the selected budget, the client splits it into a numbered thread on fenced-code, paragraph, line, and word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
When `--image <path>` is present on a split reply, the image rides the first/opener message and later chunks stay text-only.
`SQX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `SQX_DISCORD_REPLY_MAX_CHARS` defaults to 1900, clamps to a minimum of 50, and resets values above Discord's 2000-character limit back to 1900.
`SQX_X_THREAD_MAX` defaults to 25 and caps oversized reply threads for every platform, marking the last retained message with an ellipsis when truncation is needed.
`SQX_FOLLOWUP_MAX_AGE_SECS` defaults to 604800 (7 days) and controls the local completion follow-up window; `SQX_FOLLOWUP_MAX_COUNT` defaults to 3 and controls the local follow-up cap.

Set `SQX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `sq-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
In dry-run, `sq-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `SQX_PAIRING_TOKEN` nor `curl`.

### Promised public replies (state/public-followup)

A relay request that spawns real work can leave Squad owing a specific public reply in a specific thread.
That promise is a typed `kind=public-followup` obligation owned entirely by `sq-tasks public-followup`, with the full private request context staying in `state/x-context/`; Squad keeps no parallel copy of either.
`bin/sq-public-followup.sh` is Squad's side: it registers a commitment, reconciles typed terminal work results into it, and posts the final reply through `bin/sq-x-reply.sh --followup`.
Run `bin/sq-public-followup.sh --help` for the exact subcommands and flags.

Registration is what creates this base's private transport under `state/public-followup/` (mode 0700): `registry/` for the bounded public-safe binding of each live commitment, `events/` for typed terminal results awaiting reconciliation, `consumed/` for the accepted-event ledger, `rejected/` for refusals kept with a one-line reason, and `surfaced` for the poll's last-surfaced signature.
The base that owns the commitment also owns the outward post, because only it holds the relay consent, the request context, and the opaque thread binding.
Work routed elsewhere reports a typed terminal result with `bin/sq-public-followup-emit.sh` and never looks for the thread; that emitter refuses to write into a base with no registration for the named obligation.
A terminal event's id is derived from its identity tuple, so a duplicate report, a retry, or a replay after restart resolves to the same event and changes nothing.

Activation is the same `.env` `SQX_PAIRING_TOKEN` contract as the rest of Relay, with no second flag.
A base without that token runs one file test and stops: no `sq-tasks` call, no backlog or request-context scan, and no `state/public-followup/` directory.
Ordinary startup, polling, cleanup, and silent read-side subcommands also produce no output; commands that require an active relay report that configuration error after the same gate.
A relay-enabled base with no registered commitment stops at an O(1) directory presence check, so the empty state costs no CLI call and adds no periodic scan.
Unreconciled terminal results ride the existing 30-second relay poll rather than a new process or timer: `bin/sq-x-poll.sh` compares the pending-event signature against `surfaced` and wakes Squad once per new result set.
The session-start digest separately prints an "Public commitments awaiting delivery" subsection from disk when, and only when, this base is relay-active and still owes a reply, so compaction and restart are non-events.
`bin/sq-teardown.sh` refuses to clean up a task while this base still owes a public reply for exactly that work, unless `--force` carries explicit discard approval.
`SQUAD_PF_RETRY_BACKOFF_SECS` (default 900) sets the next-attempt time recorded with a retryable delivery error.
See [verification/public-followup.md](verification/public-followup.md) for the current maintainer evidence behind the restart end-to-end and the relay-disabled zero-overhead guarantee.

## Telegram bridge (config/telegram-bridge.env)

The Telegram bridge is an optional local relay that implements the connector contract of the Relay section above and translates it to the Telegram Bot API.
It is the "local relay" `SQX_RELAY_URL` can point at: the base's `.env` needs only `SQX_RELAY_URL=http://127.0.0.1:8787` next to the existing `SQX_PAIRING_TOKEN`, and the running Squad base needs no code changes.
Only the commander's Telegram user id is accepted as a mention author, and the connector listens on 127.0.0.1 by default.

To set it up:

1. Create a bot with @BotFather and copy its token.
2. Write the token and the commander's Telegram user id to this base's gitignored `config/telegram-bridge.env`:
   `TG_BOT_TOKEN=<bot token>`
   `TG_ALLOWED_CHAT_IDS=<commander Telegram user id>`
3. Put `SQX_PAIRING_TOKEN=<token>` in the base's gitignored `.env` (the same token already there when Relay is on) and set `SQX_RELAY_URL=http://127.0.0.1:8787`.

Run the bridge as the shipped user service so it starts at boot and restarts when it crashes:

1. Copy `systemd/sq-tg-bridge.service` to `~/.config/systemd/user/`, adjusting the `SQUAD_BASE` path inside it when this base lives outside the standard `~/Projects/squad` layout.
2. `systemctl --user daemon-reload`
3. `systemctl --user enable --now sq-tg-bridge`
4. `loginctl enable-linger "$USER"` so the user manager (and therefore the bridge) starts at boot, not only after login.

Verify with `systemctl --user status sq-tg-bridge` (active, restarts recorded) and `journalctl --user -u sq-tg-bridge` (the bridge logs each start to stderr).
Remove the service with `systemctl --user disable --now sq-tg-bridge`, then delete the copied unit file and run `systemctl --user daemon-reload`.
The bridge needs only the Python 3 standard library, binds 127.0.0.1, and logs to stderr (the script header and `--help` own the exact flags and config keys).
A restart is non-lossy: runtime request state (the pending queue, follow-up bindings, and the Telegram update offset) lives in `state/telegram-bridge/state.json` (gitignored) and survives bridge restarts, so a restart never re-ingests an already-offered message and never re-answers an answered request.

### Dual channel (chat to chat + Telegram)

When the commander wants chat replies to also arrive on Telegram, Squad mirrors each commander-facing reply with `bin/sq-tg-notify.sh <text-or-'-'>` (`-` reads the message from stdin).
The mirror is a proactive ping, not a relay request: it calls the Telegram Bot API directly (`sendMessage`) against the same `config/telegram-bridge.env`, targets the first `TG_ALLOWED_CHAT_IDS` entry, and works even when the bridge is down.
It prints one `telegram HTTP <code>` line so a caller can tell a delivered mirror from a failed one, and fails closed (exit 1, nothing sent) when the config file, token, or chat id is missing.
The base home resolves like the other `sq-*` scripts: `$SQUAD_BASE`, then legacy `$SQUAD_HOME`, then this repo root.
The bridge reports the client-resolved `discord` platform with an explicit `reply_max_chars` of 4096.
The Squad relay client resolves only the `x` and `discord` platforms for its follow-up fail-safe, and an explicit limit always wins over the platform default, so replies still split at Telegram's 4096-character message budget and completion follow-ups pass the fail-safe.

## Process-to-event sources (state/procevent)

A long-polling external process is registered as a *source* through its adapter, whose header and `--help` own the commands and flags.
`bin/sq-procevent.sh` owns the generic contract; `bin/sq-procevent-sq-report.sh` is the first adapter and wraps only the currently published `sq-report poll` interface.

This section is the single owner of the runner's operating contract.
Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before it is published.
Results are published as ordinary `check` wakes carrying the source id and committed result sequence through the existing durable stand-to queue, so the runner adds no second notification control plane.
The sentry delivers a queued result on its ordinary cycle by reporting it as an actionable `check` wake, so a captured result reaches Squad through the same rewake path every other wake uses and never waits for a manual drain.
Delivery is reported at most once per captured source and sequence while any records for that key remain queued.
A durable handled acknowledgement stops future re-announcement, while a record already queued remains under the durable queue's authority until the ordinary drain consumes it.

Discovery is never a timer.
Each registered source has its own child process blocking on that source, and the sentry's per-cycle `reconcile` republishes every captured result with no durable handled acknowledgement yet - regardless of any earlier publication - restarts a source whose owner is gone, and stops this base's runner when reconciliation runs after its registration disappeared unexpectedly.
In supported steady state, a base with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

Whether a captured result ends its source is adapter knowledge, never the runner's.
After attempting publication the runner calls `bin/sq-procevent-<adapter>.sh terminal <result-file>` and retires the registration on exit 0 alone, dropping only the exact registration generation captured by its claim and releasing that claim only after removal succeeds under one source boundary; a missing command, an error, or any other exit keeps the source armed, so an adapter with no notion of ending needs no change.
A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives and becomes independently runnable after the old claim releases.
A source that has ended therefore captures at most one terminal result, is never restarted, and leaves no recurring poll work, while explicit `retire` stays the supported and idempotent path afterwards.
For sq-report that verdict covers an ended session, a missing session, and the final feedback of a `Send & End` review, which the published poll marks with `session_ended` before it returns only empty ended sessions.

Applying a captured result is adapter knowledge too, and some results carry no judgement at all: they must simply be applied idempotently to this base's own durable state.
Leaving that to a handler means it can silently not happen, so immediately after the terminal check above the runner calls `bin/sq-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>` only when this capture's own wake was successfully appended to the durable queue, then lets the adapter apply and acknowledge its own result.
That call runs strictly after terminal retirement, because a handling adapter re-arms its own next source and retiring afterwards would drop that fresh registration and leave the source silently dead.
Failed publication skips the call, and exit 0 means the adapter fully applied and acknowledged the result; failed publication, a missing command, an error, or any other exit is not a capture failure but leaves the result unacknowledged and therefore still eligible for re-announcement, so a handler receives it exactly as before and an adapter with no such command needs no change.
The remote-XO reply adapter implements it, so a captured reply reaches its local status mirror and settles its correlated pending-reply expectation without any handler step; the published wake still reaches Squad, and handling that wake through the adapter again is idempotent.

Ownership is machine-wide per canonical source, because separate bases can share one underlying source store.
Claims live under `$XDG_STATE_HOME/Squad/procevent-claims` (override with `SQUAD_PROCEVENT_CLAIM_ROOT`).
Each claim binds its base and runner PID to a process identity, unique claim generation, and exact registration-file generation.
Registration, acquisition, replacement, retirement, and generation-bound release are serialized at one machine-wide boundary per source.
A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.
Retirement and orphan reconciliation signal a runner process group only while its recorded process identity still matches, or when the recorded leader is gone and only its own owned group survives.
A runner leads its own process group, so a claim counts as reclaimable only when that whole generation is gone: a crashed leader whose group still has members is not stale, and reconcile stops that surviving group and releases its generation before starting any replacement.
If identity cannot be established for a live PID, or a surviving owned group cannot be proved stopped, the operation preserves the registration and claim for safe retry rather than adding a second owner.
A live PID whose identity no longer matches is a reused PID, so it is treated as stale and its process group is never signalled.

Supported XO retirement preflights each target base's bounded `sweep-home` command before destructive teardown, snapshots its registrations outside the target, then runs the sweep at that base's final deletion or return boundary.
If deletion or return fails, teardown restores those registrations and reconciles them before returning the refusal.
If restoration or rearming also fails, teardown returns a distinct status and reports the retained registration backup path for manual recovery instead of hiding the retired waits.
The sweep retires local registrations and machine-wide claims physically owned by that base through the same identity-checked, generation-bound retirement path, and leaves foreign-base claims untouched.
Teardown refuses with the base, lease, routing evidence, registrations, claims, and runners retained when identity is uncertain, ownership is unreadable or unreleased, or relevant state exists without a sweep-capable child script.
Raw manual deletion of a Squad base is unsupported because it can orphan a blocking child.
To recover, restore that base's tracked `bin/sq-procevent.sh`, run `SQUAD_BASE=<base> <base>/bin/sq-procevent.sh sweep-home`, then rerun the supported teardown.

`SQUAD_PROCEVENT_MAX_OUTPUT_BYTES` (default 1048576) bounds a single captured result while the source runs; oversized output is drained but truncated with a stderr notice rather than staged or published whole or dropped.

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no durable handled acknowledgement remains eligible for bounded re-announcement across any number of drains and restarts, not only the crash window right after capture.
`bin/sq-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement: a generation-keyed, private, path-safe, durable, and idempotent acknowledgement that atomically checks and deduplicates by the exact source and sequence, so a paired effect gated on its first-time-vs-repeat report is never authorized twice.
Wake publication itself is still best-effort, so the same source and sequence can repeat even before any restart; handlers deduplicate that identity rather than assuming a wake is unique.
The runner proves nothing about the source side, and the handled acknowledgement proves nothing about a paired external effect performed before it: a crash between that effect and the acknowledgement call can still repeat the effect on replay, so this is never a generic exactly-once guarantee.
The published `sq-report poll` clears feedback destructively before returning it, so a result lost between that clearing and the runner reading process output is unrecoverable.
Never describe this path as at-least-once, no-loss, or lossless.
`docs/verification/process-event-sources.md` holds the measurements and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
SQUAD_BASE=                 # optional operational base for most scripts, unset falls back to legacy SQUAD_HOME, then this repo root; sq-send requires it explicitly
SQUAD_HOME=                 # legacy alias for SQUAD_BASE, accepted when SQUAD_BASE is unset
SQUAD_ROOT_OVERRIDE=        # override Squad repo root, tangle-guard target, and zellij/cmux base-title hash; also legacy whole-root override when SQUAD_BASE is unset
SQUAD_STATE_OVERRIDE=       # alternate state dir, mainly for tests
SQUAD_DATA_OVERRIDE=        # alternate data dir, mainly for tests
SQUAD_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
SQUAD_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
SQUAD_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity reads in sq-stand-to-lib.sh and sq-teardown.sh, mainly for tests
SQUAD_BACKEND=             # optional runtime backend override for new spawns; tmux/herdr/zellij/orca/cmux support ship/recon spawns, codex-app is not accepted
SQUAD_TRACE_CONTEXT=       # optional trace-context override; see "Trace context propagation"
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
SQUAD_BACKEND_HERDR_COMPOSER_LINES=20  # herdr-only: tail lines scanned by composer-state guard/fallback paths; idle-baseline submit confirmation uses agent-state
SQUAD_BACKEND_HERDR_IDLE_RE='^Type a message\.\.\.$'  # herdr-only: empty-composer placeholder regex after shared ghost extraction plus border and prompt stripping
SQUAD_BACKEND_HERDR_BARE_PROMPT_RE='^(❯|›)'  # herdr-only: verified agent glyphs recognized as an UNBORDERED (bare) composer row, e.g. Claude's ❯ or Codex's ›; an alternation, not a `[...]` bracket expression, so a C-locale byte-decomposed match can never misfire on an unrelated multibyte glyph; shell glyphs remain unknown rather than empty, and de-emphasised ghost/placeholder text reads empty through shared fm_composer_strip_ghost (docs/herdr-backend.md "Composer and injection safety")
SQUAD_BACKEND_HERDR_PI_COMPOSER_MAX_LINES=8  # herdr-only: maximum rows admitted between Pi's native-identity-corroborated separator pair; taller or ambiguous candidates stay unknown (docs/herdr-backend.md "Composer and injection safety")
SQUAD_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Current transport behavior")
SQUAD_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
SQUAD_BACKEND_ORCA_COMPOSER_LINES=200  # orca-only: terminal-read lines scanned to locate the composer row for submit verification
SQUAD_BACKEND_ORCA_IDLE_RE='^Type a message\.\.\.$'  # orca-only: empty-composer placeholder regex after border/prompt stripping
SQUAD_ZELLIJ_SESSION=Squad  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
SQUAD_BACKEND_CMUX_COMPOSER_LINES=20  # cmux-only: tail lines scanned to locate the composer row for submit verification
SQUAD_BACKEND_CMUX_IDLE_RE='^Type a message\.\.\.$'  # cmux-only: empty-composer placeholder regex after border/prompt stripping
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
SQUAD_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest; each line is capped by bin/sq-line-cap-lib.sh
SQUAD_SESSION_START_QUEUED_LIMIT=20   # plain queued backlog rows in the session-start digest; in-flight, held, and blocked rows are never bounded and done rows are never listed
SQUAD_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
SQUAD_BOOTSTRAP_NETWORK=all   # internal session-start phase split: all, skip (local steps only), or only (network steps only); see bin/sq-bootstrap.sh
SQUAD_STARTUP_NETWORK_TIMEOUT=120   # seconds bounding the whole deferred network stage; hitting it prints an actionable NETWORK_CHECKS line
SQUAD_TASKS_AXI_COMPATIBLE=   # internal one-hop handoff of an already-computed sq-tasks compatibility verdict (0 or 1); consumed when bin/sq-tasks-lib.sh is sourced
SQUAD_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
SQUAD_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; sq-send.sh overrides it to name the requested message specifically
SQUAD_POLL=15              # seconds between sentry poll cycles
SQUAD_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
SQUAD_HEARTBEAT_MAX=7200   # heartbeat backoff cap
SQUAD_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or Relay dispatch)
SQUAD_CHECK_TIMEOUT=30     # seconds allowed per slow check script
SQUAD_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # bound on one captured process-to-event result
SQUAD_PROCEVENT_CLAIM_ROOT=                # machine-wide source claim root; default $XDG_STATE_HOME/Squad/procevent-claims
SQUAD_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground sentry checkpoint in Codex primary supervision
SQUAD_CREW_STATE_DRILL_TIMEOUT=10   # seconds allowed per drill query inside sq-crew-state.sh
SQUAD_TEARDOWN_DRILL_TIMEOUT=10    # seconds allowed per drill query or abort inside sq-teardown.sh
SQUAD_CREW_STATE_RUNS_LIMIT=200  # recent drill run rows scanned when axi status cannot be attributed to the current code
SQUAD_CREW_STATE_BIN=bin/sq-crew-state.sh   # test override for the current-state reader used by working/paused sentry triage
SQX_PAIRING_TOKEN=      # Relay pairing token; .env opt-in authorizes replies and eligible lifecycle actions
SQX_RELAY_URL=https://mySquad.io   # optional Relay endpoint override, mainly for local relay development
SQX_ENV_FILE=           # optional alternate .env file for direct Relay client invocations; bootstrap still checks $SQUAD_BASE/.env
SQX_DRY_RUN=            # truthy previews Relay replies and dismissals to state/x-outbox/ without posting or requiring a token
SQX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
SQX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
SQX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
SQX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting Relay completion follow-ups (7 days)
SQX_FOLLOWUP_MAX_COUNT=3   # local cap on Relay completion follow-ups per linked mention
TG_BOT_TOKEN=            # Telegram bridge: bot token from @BotFather (config/telegram-bridge.env)
TG_ALLOWED_CHAT_IDS=     # Telegram bridge: comma-separated commander Telegram user ids allowed to send requests
TG_BRIDGE_BIND=127.0.0.1   # Telegram bridge: connector listen address
TG_BRIDGE_PORT=8787     # Telegram bridge: connector listen port (0 = ephemeral)
TG_BRIDGE_CONFIG=        # Telegram bridge: alternate env file (default <SQUAD_BASE>/config/telegram-bridge.env)
TG_BRIDGE_STATE_FILE=    # Telegram bridge: alternate runtime state file (default <SQUAD_BASE>/state/telegram-bridge/state.json)
TG_BRIDGE_SEND_TIMEOUT=8   # Telegram bridge: per-send HTTP cap in seconds (default 8; must be positive)
SQUAD_PF_RETRY_BACKOFF_SECS=900   # seconds before the next attempt after a retryable promised-public-reply delivery error
SQUAD_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
SQUAD_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a sentry beacon as stale
SQUAD_CLAUDE_AUTOARM_ATTEMPTS=2   # bounded Stop-owned arm attempts per Claude auto-arm cycle; accepted values are 1, 2, or 3
SQUAD_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milliseconds the --claude turn-end guard waits for sentry health, a role-verified Stop auto-arm claim, or a fresh epoch before deciding recovery ownership or failure progression
SQUAD_CLAUDE_AUTOARM_EPOCH_FRESH=15   # seconds a recorded auto-arm outcome remains eligible for the current event epoch's recovery or failure decision
SQUAD_CLAUDE_TURNEND_BLOCK_BUDGET=3   # consecutive --claude guard re-blocks before the verified one-time attended fail-open; safely below Claude Code's 8-block override
SQUAD_ARM_CONFIRM_TIMEOUT=10   # seconds sq-sentry-arm waits to confirm a fresh sentry before reporting FAILED; default 30 on Git Bash/MSYS
SQUAD_ARM_ATTACH_POLL=0.5  # seconds between checks while sq-sentry-arm is attached to an existing healthy sentry cycle
SQUAD_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary sentry plugin waits for an arm attempt to report started, healthy, wake, or failure; default 35000 on Windows to stay above the MSYS confirm budget
SQUAD_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi sentry extension waits for a successor arm to report started or attached; default 35000 on Windows to stay above the MSYS confirm budget
SQUAD_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
SQUAD_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
SQUAD_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
SQUAD_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
SQUAD_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned sentry lifecycle ledger
SQUAD_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
SQUAD_SENTRY_STALE_GRACE=300   # defaults to SQUAD_GUARD_GRACE; seconds a live sentry lock may have a stale beacon before re-arm errors
SQUAD_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
SQUAD_COMMANDER_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # commander-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
SQUAD_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from SQUAD_COMMANDER_RE and distinct from blocked
SQUAD_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates; stale panes whose crew is not provably working surface immediately unless they declare the pause verb
SQUAD_BUSY_TURN_MAX_SECS=3600         # maximum age of a busy pane's latest state/<id>.turn-ended marker, or its state/<id>.meta spawn record before any turn completes, before the same wedge escalation used for a provably-working non-busy stale takes over; inspection-only, never an automatic interrupt or restart
SQUAD_PAUSE_RESURFACE_SECS=3600       # seconds before an idle declared external wait re-surfaces for a recheck in the sentry or away-mode daemon
SQUAD_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
SQUAD_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the sentry's absorbed-wake debug log
SQUAD_UNIT_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
SQUAD_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
SQUAD_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before sq-teardown.sh treats a leftover worktree git index.lock as provably stale
SQUAD_FOB_RETURN_LOCK_RETRIES=3        # retries after a fob return fails on the transient git index.lock signature
SQUAD_FOB_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds sq-teardown.sh waits before each retry after that signature
SQUAD_TREEHOUSE_RETURN_LOCK_RETRIES=   # legacy alias for SQUAD_FOB_RETURN_LOCK_RETRIES when the new variable is unset
SQUAD_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS= # legacy alias for SQUAD_FOB_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
SQUAD_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for SQUAD_FOB_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after sq-unit-sync.sh hits the orphaned .git/packed-refs.lock signature
SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds sq-unit-sync.sh waits before each of those retries
SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before sq-unit-sync.sh treats a leftover packed-refs.lock as provably stale
SQUAD_BUSY_REGEX=          # optional override for rendered delivery guards and Grok's isolated task-state fallback; converted worker state ignores it
SQUAD_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after ghost and border stripping
SQUAD_COMPOSER_GHOST_LUMA_MAX=128   # unit-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/sq-composer-lib.sh's fm_composer_strip_ghost, shared by the tmux and herdr composer readers)
GROK_HOME=              # optional Grok config home for Squad's global grok turn-end hook; defaults to ~/.grok
SQUAD_SEND_RETRIES=3       # sq-send Enter-retry attempts after typing the line once
SQUAD_SEND_SLEEP=0.4       # seconds between sq-send submit checks
SQUAD_SEND_SETTLE=1        # seconds sq-send waits after a successful text submit; 0 disables
SQUAD_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
# sub-supervisor (bin/sq-supervise-daemon.sh); presence-gated via /afk
SQUAD_SUPERVISOR_BACKEND=             # optional supervisor pane backend override; tmux/herdr only, otherwise detects $TMUX_PANE then HERDR_ENV/HERDR_PANE_ID before tmux fallback
SQUAD_SUPERVISOR_TARGET=              # optional supervisor pane target override; tmux target or herdr <session>:<pane-id>, otherwise auto-detected
SQUAD_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
SQUAD_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
SQUAD_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
SQUAD_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|herdr|command:<cmd>; absent = auto (macOS -> an OS notification)
SQUAD_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, herdr, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
SQUAD_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
SQUAD_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
SQUAD_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
SQUAD_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
SQUAD_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed commander verbs
SQUAD_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
SQUAD_CRASH_THRESHOLD=10              # sentry crashes allowed inside SQUAD_CRASH_WINDOW before daemon backoff
SQUAD_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
SQUAD_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
SQUAD_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated sentry crash
SQUAD_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
SQUAD_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```

`sq-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `SQUAD_FOB_RETURN_LOCK_RETRIES` times.
`SQUAD_FOB_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an invalid value uses the default of 3.
`SQUAD_FOB_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `SQUAD_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, then `SQUAD_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS`, and a blank fallback uses the 1-second default.
When `SQUAD_FOB_RETURN_LOCK_RETRIES` is unset or blank, `SQUAD_TREEHOUSE_RETURN_LOCK_RETRIES` remains a compatible fallback, and a blank fallback uses the default of 3.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`sq-unit-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards unit-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/sq-lock-lib.sh`, which both `sq-teardown.sh` and `sq-unit-sync.sh` use.
