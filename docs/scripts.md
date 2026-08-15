# The bin/ toolbelt

The sergeant at arms drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the Squad base in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared drill gate refusal for unit lifecycle entrypoints is summarized in [architecture.md](architecture.md#drill-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent session-open hook use; `sq-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `sq-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `sq-sessionstart-nudge.sh` | Print the native session-start hook nudge when the primary has not already run the digest |
| `sq-sessionstart-run.sh` | Route a native session-open hook to the full digest, a context re-emit, or the nudge |
| `sq-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `sq-bootstrap.sh`        | Detect toolchain and unit problems, run the locked session-start sweeps, and install approved tools |
| `sq-startup-network.sh`  | Run session start's network checks off its blocking path in a bounded detached worker, and publish the result inline or as a wake |
| `sq-unit-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `sq-unit-snapshot.sh`   | Print the read-only structured unit snapshot JSON (schema `sq-unit-snapshot.v1`)   |
| `sq-unit-view.sh`       | Render the unit snapshot as a human Markdown view                                   |
| `sq-web-view.sh`        | Serve or render the read-only web dashboard over a base's operator state (docs/web-view.md) |
| `sq-sitrep-snapshot.sh` | Project the unit snapshot to the compact TOON sitrep view; local-only unless `--include-prs` |
| `sq-update.sh`           | Fast-forward-only self-update of Squad and local or remote XO bases       |
| `sq-on.sh`               | Execute one tracked Squad command in a configured remote XO base, using its job worker except for the doctor bootstrap |
| `sq-remote-job-lib.sh`   | Shared bounded remote job queue, worker readiness, LaunchAgent contract, and filesystem-composed PATH |
| `sq-remote-job-worker.sh` | Long-lived remote queue worker for tracked `sq-*.sh` commands in the account runtime |
| `sq-remote-job-reap-orphans.sh` | Stop remote job workers left running by a pruned code root, never one whose checkout still exists |
| `sq-remote-doctor.sh`    | Check, and with `--fix` repair, one remote account's second-mate readiness (remote job worker, Herdr, Aqua launch agents, PATH, and required tools) |
| `sq-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into an XO base               |
| `sq-backlog-receive.sh`  | Idempotently ingest one confined remote handoff outbox through sq-tasks             |
| `sq-decision-hold.sh`    | Create, verify, complete, and resolve durable commander-held decisions                 |
| `sq-brief.sh`            | Scaffold ship (explicit `--mode`), recon, XO-charter, and Herdr-lab briefs   |
| `sq-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `sq-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `sq-install-fob.sh`| Build and install the vendored packages/fob from source for real-Herdr E2E that needs spawn worktrees |
| `sq-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `sq-lab-*` sessions in the Herdr CI lane       |
| `sq-test-run.sh`         | Behavior-test runner: selection, portable lanes, proven-isolated `--jobs`, coverage guard, timing/JSON |
| `sq-test-isolation-proof.sh` | Concurrent isolation proof and proven-isolated candidate set owner |
| `sq-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` symlink, and the canonical self-governance section |
| `sq-guard.sh`            | Warn on primary-checkout tangles, pending queued wakes, and unhealthy supervision    |
| `sq-primary-scope-lib.sh` | Shared marker-or-plain-checkout primary-base predicate for tracked hooks             |
| `sq-session-lock-lib.sh` | Shared session-lock harness identity (ancestry walk and holder liveness) for sq-lock.sh and the Claude Stop auto-arm |
| `sq-claude-stop-autoarm.sh` | Claude Stop `asyncRewake` hook owning tokenless sentry continuity with single-flight exit-2 rewake (docs/sentry-continuity.md) |
| `sq-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `sq-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `sq-kimi-turnend-hook.sh` | Surgically install or remove Kimi's guarded global crew turn-end hook                |
| `sq-arm-pretool-check.sh` | Stable PreToolUse transport for the sentry-arm command policy (docs/arm-pretool-check.md) |
| `sq-arm-command-policy.mjs` | Semantic owner of the sentry-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `sq-subagent-pretool-check.sh` | Primary-base delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `sq-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `sq-home-seed.sh`        | Transactionally provision a local XO base and maintain `data/XOs.md` |
| `sq-remote-home-seed.sh` | Register and provision a whole XO base on an SSH-reachable host              |
| `sq-remote-readiness-lib.sh` | Shared remote second-mate readiness gate: check and, when needed, repair then re-check through `sq-remote-doctor.sh` |
| [`sq-project-origin-lib.sh`](../bin/sq-project-origin-lib.sh) | Accepted origin-form owner shared by both remote provisioning boundaries |
| `sq-spawn.sh`            | Spawn operators, scouts, `id=repo` batches, and XOs on the resolved harness and runtime backend |
| `sq-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `sq-backend-hometag-lib.sh` | Shared per-installation base-tag derivation for zellij tab and cmux workspace titles |
| `sq-composer-lib.sh`     | Single unit-wide owner of composer-content classification for all backends          |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Experimental herdr session-provider adapter                                          |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `sq-config-push.sh`      | Push declared inherited local material to live local or remote XOs and send the placement-specific config reread when changed |
| `sq-project-mode.sh`     | Resolve a project's registered delivery posture from `data/projects.md` for unit sync and base seeding |
| `sq-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `sq-review-diff.sh`      | Review an operator branch or resolved PR head against the authoritative base          |
| `sq-marker-lib.sh`       | Compatibility entry point for the from-squad carrier owned by `sq-operational-input.sh` |
| `sq-pending-reply-lib.sh` | Parent-owned XO pending-reply expectations, recovery, and keyed escalation lifecycle |
| `sq-xo-report.sh` | Optional helper to append a correlated parent status or document-pointer report       |
| `sq-procevent-remote-reply.sh` | Relay the remote-XO status stream through non-destructive process-event deltas |
| `sq-gate-refuse-lib.sh`  | Shared drill gate-context refusal for unit lifecycle entrypoints               |
| `sq-sentry-arm.sh`        | Verified base-scoped sentry arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `sq-sentry-checkpoint.sh` | Run one bounded foreground sentry checkpoint for Codex-style supervision            |
| `sq-sentry.sh`            | Singleton-safe always-on sentry: absorb benign wakes, queue and exit on actionable ones |
| `sq-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `sq-afk-launch.sh`       | Own away-mode entry, exit, rollback, and any backend terminal lifecycle                 |
| `sq-afk-return.sh`       | Own deterministic return shutdown, catch-up evidence, and the Squad-actionable blocker gate |
| `sq-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `sq-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, guard injection by the detected primary harness, escalate batched digests, alert on failed delivery |
| `sq-crew-state.sh`       | Print one deterministic current-state line for an operator                                |
| `sq-sidebar.sh`          | Render the ground-truth tmux sidebar cards, toggle the sidebar pane, and focus operator windows (docs/sq-sidebar.md) |
| `sq-drill-run-lib.sh`       | Shared branch-and-code-identity attribution for drill runs                    |
| `sq-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `sq-timeout-lib.sh`      | Single owner of hard-bounded command execution and its fallback watchdog |
| `sq-timing-lib.sh`       | Single owner of the deferred network stage's per-step elapsed-time records, inert unless a run asks for them |
| `sq-supervision-lib.sh`  | Shared in-flight-work-without-fresh-sentry-beacon predicate                         |
| `sq-ff-lib.sh`           | Shared guarded fast-forward helper for origin pulls and local XO syncs       |
| `sq-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and unit-sync   |
| `sq-config-inherit-lib.sh` | Shared primary-to-XO inherited local-material propagation and config-reread delivery |
| `sq-tasks-lib.sh`    | Shared backlog-backend selector and `sq-tasks` compatibility probe                  |
| `sq-quota-lib.sh`    | Shared `sq-quota` compatibility floor for the bootstrap diagnostic                  |
| `sq-vendor-auth-probe.sh`| Run one hard-bounded, non-destructive authentication probe of a named vendor CLI and report the fact |
| `sq-stand-to-drain.sh`       | Atomically drain queued sentry wakes, emit bounded best-effort status-event annotations and a unit-wide OPEN DECISIONS section, then assert supervision health |
| `sq-stand-to-lib.sh`         | Shared durable stand-to queue, portable locks, and sentry identity/health helpers       |
| `sq-handoff-request.sh`      | Record, resolve, and list durable new-session handoff requests at milestone closes (docs/handoff-request.md) |
| `sq-handoff-surface.sh`      | Mark pending handoff requests surfaced exactly once and print the handoff card (docs/handoff-request.md) |
| `sq-classify-lib.sh`     | Shared wake-classification vocabulary and durable keyed-decision folds and scans     |
| `sq-send.sh`             | Send one verified literal line or supported key through the target's recorded backend |
| `sq-busy-lib.sh`         | Single owner of the semantic busy-state contract: verdicts, source attribution, and per-harness sources |
| `sq-busy-event.sh`       | The only writer of a task's semantic busy-state record; arms an incarnation and applies lifecycle events |
| `sq-tmux-lib.sh`         | Shared tmux pane primitives for composer capture, verified submit, and the submit-time busy check |
| `sq-peek.sh`             | Print a bounded tail of an operator endpoint                                          |
| `sq-check-register.sh`   | Bind an intentional custom sentry check to its current bytes                       |
| `sq-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `sq-pr-lib.sh`           | Own canonical task and PR validation plus private atomic PR-poll publication and identity-bound retirement |
| `sq-pr-poll.sh`          | Provide the byte-static sentry program for validated PR/MR-poll sidecars           |
| `sq-pr-check-migrate.sh` | Quarantine older task polls without execution and rebuild only canonical polls       |
| `sq-pr-check.sh`         | Record validated `pr=` and `pr_head=` values, then atomically arm a static merge poll |
| `sq-pr-merge.sh`         | Record PR metadata, then merge a task's canonical full GitHub URL                    |
| `sq-promote.sh`          | Promote a recon task in place to a protected strike task with an explicit delivery mode |
| `sq-teardown.sh`         | Fail-closed teardown: return landed ship worktrees, require completed recon deliverables, retire XO bases |
| `sq-harness.sh`          | Detect the running harness and resolve crew or XO harness, model, and effort |
| `sq-lock.sh`             | Per-base Squad session lock                                                      |
| `sq-x-lib.sh`            | Shared Relay config, relay, and reply-threading helpers                              |
| `sq-x-poll.sh`           | One bounded Relay poll: stash newly offered mentions and emit their once-only wake   |
| `sq-x-reply.sh`          | Post or dry-run preview a composed Relay reply or follow-up                          |
| `sq-x-dismiss.sh`        | Dismiss a skipped Relay mention at the relay without replying                        |
| `sq-x-link.sh`           | Link a spawned task to its originating Relay mention in task meta                    |
| `sq-x-followup.sh`       | Detect, post, and cap completion follow-ups for a Relay-linked task                  |
| `sq-public-followup-lib.sh` | Shared relay-activation gate, O(1) presence checks, and private transport paths for promised public replies |
| `sq-public-followup.sh`  | Reconcile typed terminal work results into a public commitment and deliver its final reply once |
| `sq-public-followup-emit.sh` | Report one typed terminal work result into the base that owes the public reply    |
