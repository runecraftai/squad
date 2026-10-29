# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
The backend guides own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary bases, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.

## tmux

Foreground-process behavior was verified on 2026-07-07 with tmux 3.6a on macOS.

```sh
tmux new-session -d -s fmtest -n testwin
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin 'sleep 30' Enter
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin C-c
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
```

Observed output:

```text
zsh
sleep
zsh
```

A persistent parent shell waiting for a child remained reported as the parent process, while a shell that directly execed a simple command changed identity with the process itself.
Pi and pi-signed 0.82.0 were reverified on 2026-07-27 through real isolated `sq-spawn.sh` launches.

### Agent liveness name sources

The earlier record that every harness is observed under its own `#{pane_current_command}` no longer holds and has been replaced by the per-harness evidence below.
In this macOS run that reading reflected a rewritable process title rather than stable executable identity, so it is now one of two independent name sources rather than the sole basis of a verdict.

The seven primary-capable adapters were relaunched on 2026-08-03 with tmux 3.6a on macOS 26.5.2 arm64, each on a private socket in an isolated lab.

```sh
tmux -L "$socket" new-window -d -t "$session:" -n "$harness" -c "$wt" -- "$bin"
tmux -L "$socket" display-message -p -t "$session:$harness" '#{pane_current_command}'
ps -t "${tty#/dev/}" -o pgid=,tpgid=,comm=      # rows where pgid = tpgid
```

Observed identities, and the resulting verdict:

| Harness | Version | `#{pane_current_command}` | Foreground `comm` | Verdict |
| --- | --- | --- | --- | --- |
| claude | 2.1.220 | `2.1.220` | `claude` | alive |
| codex | codex-cli 0.146.0 | `codex` | `codex` | alive |
| opencode | 1.18.11 | `opencode` | `opencode` | alive |
| pi | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| pi-signed | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| grok | 0.2.118 | `grok-0.2.118-ma` | `grok` | alive |
| kimi | 0.31.1 | `kimi` | `kimi` | alive |

Claude Code is the harness whose title no longer attributes it at all; every other adapter is currently attributed by both sources.
Codex reported `codex-aarch64-a` at 0.145.0 and `codex` at 0.146.0, and Kimi Code reported `kimi-code` as its foreground `comm` at 0.29.1 and `kimi` at 0.31.1, so these identities move between ordinary patch releases in both directions.
That is the evidence for treating any single process name as a surface under vendor control rather than a stable contract.

The operator-only Muse Code 0.1.0-R708.1 adapter was verified separately on 2026-08-05 against tmux on macOS arm64.
Its installed `muse-bin-0.1.0-R708.1` foreground identity classified `alive`, while `musescore`, `amuse`, `muse-binary`, and `muse-bind` remained ambiguous in the portable regression.
[`muse.md`](muse.md#process-identity) owns the artifact identity and launcher evidence for that verification.

Bounded observed output:

```text
foreground comms:
  zsh
  .../instbin/muse-bin-0.1.0-R708.1
classify each:
  zsh                            -> shell
  muse-bin-0.1.0-R708.1          -> agent
fm_backend_agent_state tmux museliv:zsh
alive
```

`#{pane_current_command}` and foreground `ps -o comm=` read different name fields, but which one preserves executable identity is platform-dependent.
On macOS the pane command reflected the rewritable title while the full install path could survive in `ps -o comm=`; in the Linux portable regression those roles reversed for the version-named native executable, with the identifying path retained in argv[0].
The classifier therefore accepts a harness basename first, then an exact harness path component in the full executable path, then the same component in argv[0], without depending on which field carries it on a given platform.

The portable regression is CI-enforced, while the real-harness drift guard is opt-in under the policy in `.agents/skills/squad-coding-guidelines/SKILL.md`.
Run the live guard after any harness upgrade and before trusting or refreshing the table above:

```sh
SQUAD_HARNESS_LIVENESS_DRIFT=1 bin/sq-test-run.sh tests/sq-harness-liveness-drift-live-e2e.test.sh
```

Bounded output from the run that produced the table:

```text
ok - harness liveness: claude 2.1.220 (Claude Code) classifies alive
# claude 2.1.220 (Claude Code): title='2.1.220' foreground=[claude ]
# checked 7 installed harness(es)
```

Installed-wrapper checks:

```sh
basename "$(command -v pi-signed)"
pi-signed --version
pi --version
```

Observed bounded output:

```text
pi-signed
0.82.0
0.82.0
```

The isolated process and endpoint checks used:

```sh
tmux display-message -p -t "$target" '#{pane_current_command}'
ps -o comm= -p "$wrapper_pid"
ps -o comm= -p "$engine_pid"
SQUAD_BASE="$fixture_home" bin/sq-crew-state.sh "$task_id"
```

Observed bounded shapes:

```text
pi-launcher
.../pi-signed
.../Pi Launcher.app/Contents/Resources/pi/pi
state: done ...
```

Both launches executed a submitted tool instruction and touched the generated `turn_end` marker.
The pi-signed launch retained `harness=pi-signed`, while the plain comparison retained `harness=pi`.
The exact wrapper ancestry was `pi-signed` parent to Pi engine child, and the plain Pi Launcher path also traversed the signed wrapper on this installation.
That shared plain-Pi path is retained as disconfirming evidence against using ancestry as runtime-selection authority.
Squad therefore sets the exact `SQUAD_PI_HARNESS` selection marker on both worker launch paths, while an unmarked Pi-family process remains `pi`.
Both recorded runtime identities now classify the exact `pi-launcher` foreground command as `alive`.

Backend applicability was reviewed across every spawn adapter.
Tmux needs the exact `pi-launcher`, `pi-signed`, `pi`, and `Pi` process identities for recovery-grade liveness.
Herdr uses native registered-agent state and needs no process-name branch.
Zellij has no verified recovery-grade agent process probe, while Orca and cmux do not support XO spawns, so those three retain their existing generic ordinary-launch semantics without a new liveness matcher. TUIOS also refuses XO spawns but adds a recovery-grade classifier that corroborates the exact window against agent inventory.

The structural multi-row composer reader, Kimi pointer-delivery path, and OpenCode 1.18.4 busy-queue behavior are pinned by:

```sh
tests/sq-composer-ghost.test.sh
tests/sq-kimi-harness.test.sh
tests/sq-tmux-submit-busy.test.sh
```

Expected structural matrix: real text on any content row is pending; all-empty complete boxes are empty; unreadable, incomplete, or unsafe boxes are unknown; and non-bordered panes retain cursor-row compatibility.
Expected submit matrix: proven pending plus busy is accepted as queued; proven pending plus idle remains pending; ambiguous pending is never converted by the busy exception; and only a proven empty composer succeeds directly.

### Cleanup endpoint identity

The cleanup identity boundary was validated on 2026-07-28 with tmux 3.6a and metadata fixtures for every supported backend.

```sh
tests/sq-teardown-endpoint-safety.test.sh
tests/sq-teardown.test.sh
tests/sq-backend-herdr.test.sh
tests/sq-backend-zellij.test.sh
tests/sq-backend-orca.test.sh
tests/sq-backend-cmux.test.sh
```

Bounded output from the incident regression:

```text
ok - sq-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call
ok - cleanup identity: valid tmux, Herdr, Zellij, Orca, cmux, and TUIOS records validate while every empty backend target refuses
ok - tmux backend: direct empty target returns nonzero without invoking tmux
ok - process cleanup: creation-time PID identity removes only the exact child and preserves the control child
ok - sq-teardown: dedicated-socket invalid cleanup preserves target/control and valid cleanup removes only the exact target
```

The dedicated tmux cell removed ambient tmux variables, required a socket-bound wrapper, kept one target and one independent control window, and proved the wrapper was not called for invalid metadata or a direct empty target.
Valid cleanup removed only the exact task-bound target and left the control window live.
The metadata-only validation covers tmux, Herdr, Zellij, Orca, cmux, and TUIOS before backend dispatch.
Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, and Muse share that backend cleanup boundary; their harness-specific hook files, tokens, and session-log sidecars are cleaned only after it, so no harness needs a separate endpoint parser.

## Herdr

The compatibility floor is protocol 14.
The whole real-Herdr lane's latest active verification uses both Herdr 0.7.4 protocol 16 and Herdr 0.8.0 protocol 19 on macOS aarch64, while focused Herdr 0.7.5 protocol 17, earlier protocol-16, protocol-14, and 0.7.3 evidence is retained where it defines current behavior or fallbacks.
Protocol 17 keeps every protocol-16 feature gate satisfied; the event and workspace-move floors remain 16.
Default-on presentation projection has its own floor at Herdr 0.8.0, protocol 19, verified below.

Core read-only probes:

```sh
herdr --version
herdr status --json | jq -c '{client:.client.protocol,server:.server.protocol}'
herdr api schema --json | jq -c '.schemas.subscription_event["$defs"].SubscriptionEventKind.enum'
```

Observed protocol-16 compatibility shapes:

```text
herdr 0.7.5
{"client":17,"server":17}
["pane.output_matched","pane.agent_status_changed","pane.scroll_changed"]
```

The CLI matrix was checked directly:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Explicit session routing | `herdr <verb> ... --session <name>` | Reached the named session even while another server was running. |
| Literal send | `herdr pane send-text <pane> <text> --session <name>` | Left text unsubmitted until Enter. |
| Keys | `herdr pane send-keys <pane> enter|escape|ctrl+c --session <name>` | Enter and Escape worked; Ctrl-C interrupted foreground work. |
| Capture | `herdr pane read <pane> --source recent --lines N` | Small N could return empty below viewport height; a 200-line request plus local trim was stable. |
| Native state | `herdr agent get <pane>` | Working and done transitions were visible; native `busy` remains positive activity evidence, while native `idle` cannot close a turn and the adapter's semantic lifecycle decides worker state. |
| Restart | guarded named-session stop then start | Workspace, tab, pane, and labels persisted; the agent process and registration did not. |
| Close | `herdr pane close <pane> --session <name>` | The exact one-pane task tab closed; closing a final tab could remove the workspace. |

All destructive verification used `bin/sq-herdr-lab.sh` with a non-default `sq-lab-` name and a byte-identical default-session tripwire.
No ambient `herdr server stop` command is a supported test operation.

### Prune and respawn

The real label-collision reproduction is owned by:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-backend-herdr-prune-safety-e2e.test.sh
```

Observed guarantee: a pre-existing commander-owned workspace with a seed-shaped tab was adopted for routing but its tab was never eligible for prune because the current create call did not return that seed id.

Restart-husk replacement is owned by:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-backend-herdr-respawn-idem-e2e.test.sh
```

Observed guarantee: a restored no-agent tab was replaced create-before-close, while a registered live agent caused refusal.

### Launcher workspace placement

Herdr exports its pane identity into every process it manages, checked on 2026-07-30 against Herdr 0.7.5 protocol 17 inside a guarded lab pane:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh
"$HERDR_LAB_HELPER" run "$LAB" pane run "$PANE" "sh -c 'env | grep ^HERDR | sort > /tmp/env.txt'"
```

```text
HERDR_ENV=1
HERDR_PANE_ID=w1:p1
HERDR_SESSION=sq-lab-sq-herdr-env-pro-65961-25535
HERDR_SOCKET_PATH=/Users/kunchen/.config/herdr/sessions/sq-lab-sq-herdr-env-pro-65961-25535/herdr.sock
HERDR_TAB_ID=w1:t1
HERDR_WORKSPACE_ID=w1
```

This complete injection shape is verified only for Herdr 0.7.5.
Squad requires both `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` before accepting claimed launcher ancestry.

`pane get` reports the pane's current owning tab and workspace, which is what placement resolves from; the injected `HERDR_TAB_ID` and `HERDR_WORKSPACE_ID` are creation-time snapshots and are not read as current identity:

```sh
"$HERDR_LAB_HELPER" run "$LAB" pane get w1:p1 | jq -c '.result.pane | {pane_id,tab_id,workspace_id}'
```

```text
{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}
```

Placement is owned by:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-backend-herdr-launcher-workspace-e2e.test.sh
```

Observed guarantees on 2026-07-30 against Herdr 0.7.5 protocol 17:

```text
ok - real herdr E2E: with one 'Squad' workspace and no herdr parent, an operator still lands in this home's own workspace without stealing focus
ok - real herdr E2E: the normal unique-label path is unchanged when the launcher's own pane identifies the workspace
ok - real herdr E2E: presentation spaces still create the isolated child workspace and bind it under the launcher's exact parent, without stealing focus
ok - real herdr E2E: with two 'Squad' workspaces, a worker spawned from inside the second one lands in that exact workspace
ok - real herdr E2E: the duplicate-labeled sibling workspace is left entirely untouched and focus is preserved
ok - real herdr E2E: with a duplicated home label, a projected worker still hangs off the launcher's exact workspace and the sibling stays untouched
ok - real herdr E2E: an ambiguous home label with no launcher identity refuses before any worker endpoint exists
ok - real herdr E2E: a launcher pane that no longer exists refuses before any worker endpoint exists
ok - real herdr E2E: an XO launching its own worker gets the same exact-workspace guarantee, and its same-labeled sibling is untouched
ok - real herdr E2E: a --xo launch still stands up that XO's own workspace instead of inheriting the launcher's
ok - real herdr E2E: teardown closes only the worker's own pane and leaves the launcher, its workspace, and the same-labeled sibling intact
```

That suite's headline case runs `bin/sq-spawn.sh` inside a real Herdr pane, so the parent identity comes from Herdr's own injection rather than a composed environment.
Cross-session and contradictory bindings are covered deterministically in `tests/sq-backend-herdr.test.sh`, which can script a second server's socket without provisioning one.

### Per-base and presentation topology

Per-base behavior is owned by:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-backend-herdr-workspace-per-home-e2e.test.sh
```

Observed guarantee: the primary and XO used distinct base workspaces, a child launched by the XO stayed in that XO workspace, list-live remained base-scoped, and exact cleanup did not affect sibling bases.

The complete projection suite ran on 2026-07-21 against Herdr 0.7.4 protocol 16:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-backend-herdr-presentation-e2e.test.sh
```

Observed guarantees included:

```text
ok - real Herdr lab: primary and two XO homes each own a top-level contiguous child block
ok - real Herdr lab: concurrent primary/A/B spawns stay session-locked with zero focus drift
ok - real Herdr lab: session lock contention from an XO home falls back flat with no journal
ok - real Herdr lab: legacy projection labels and flat XO tabs are left unmigrated
ok - real Herdr lab: multi-home exact-pane teardowns restore commander focus without workspace close authority
ok - real Herdr lab validation completed on Herdr 0.7.4 with the default-session tripwire intact
```

The suite also covers lost or failed move responses, active-tab refusal, restart husks, missing and duplicate tokens, manual renames, concurrent cleanup, and exact focus restoration.

The mandatory projection suite ran again on 2026-07-24 against Herdr 0.7.5 protocol 16:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-backend-herdr-presentation-e2e.test.sh
```

Observed restart-reclaim guarantees:

```text
ok - real Herdr lab: Hi Bit and Wheelhouse-style same-identity restarts reclaim one nested space with exact focus and idempotence
ok - real Herdr lab: XO restart binding and reclaim stay isolated to the exact child home and parent
ok - real Herdr lab: concurrent cross-home recoveries replace exact husks under one session lock with no focus drift
ok - real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch
ok - real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact
```

The projection suite ran again on 2026-08-04 against Herdr 0.8.0 protocol 19 for the default-on flip, where an absent `config/herdr-presentation-spaces` enables the projection and the value `off` opts out; since 2026-08-05 an absent file enables the projection only at or above the 0.8.0 floor recorded under "Presentation version floor" below, and `on` is the explicit opt-in that survives the floor:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-backend-herdr-presentation-e2e.test.sh
```

Observed default and opt-out guarantees:

```text
ok - real Herdr lab: an opted-out spawn retains the Stage 1 Herdr command sequence with zero ordering calls
ok - real Herdr lab: a home that configured nothing is projected by default
ok - real Herdr lab: the primary presentation setting inherits into real XO homes
ok - real Herdr lab validation completed on Herdr 0.8.0 with the default-session tripwire intact
```

The projected spawn in that run used the historical empty opt-in file, so a base that had already enabled the projection keeps it without any migration step.
One concurrent cross-base recovery case refused under contention on a loaded machine and passed on an immediate rerun; recovery-path presentation lock contention is a deliberate hard refusal rather than a flat fallback, which default-on now makes reachable from any Herdr base.
That run measured the default-on projection on Herdr 0.8.0 only, while the focus-flash regression below was last run on 0.7.5 before the flip, so neither run covered a defective release under default-on projection; the version floor and the focus-flash suite's Part C close that gap.

The restored-shell session-start cleanup ran on 2026-07-24 against Herdr 0.7.5 protocol 17:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-herdr-session-cleanup-e2e.test.sh
```

Observed guarantee: one exact base-local, journal-correlated, one-tab and one-pane childless idle shell was closed after restoration while the exact non-target focus and default unit session remained unchanged, and a repeat run was a no-op.

### Workspace-removal focus safety

The focus-flash regression ran on 2026-08-05 against both Herdr 0.7.5 protocol 17 and Herdr 0.8.0 protocol 19 on macOS aarch64, with the 0.7.5 run using the pinned upstream release binary first on `PATH`:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-backend-herdr-focus-flash-e2e.test.sh
```

Observed output on Herdr 0.7.5:

```text
ok - old path: the explicit last-pane close of a non-focused workspace stole focus (w3	w3:t1 -> w2	w2:t1)
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - mitigation: no explicit close and no corrective focus were needed on the defective release
ok - fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close
ok - fallback on a defective release: a bounded wrong-focus window of 4 samples was fully restored to the anchor
ok - version floor: herdr 0.7.5 protocol 17 remains conservatively below the floor with steal_live=1
ok - version floor: an unconfigured home falls back flat on herdr 0.7.5 and the explicit opt-in still projects
evidence: herdr=0.7.5 protocol=17 steal_live=1 floor_verdict=1 default-session-tripwire=armed
```

Observed output on Herdr 0.8.0:

```text
ok - old path note: this Herdr release preserves focus across the explicit close; continuing with outcome-only assertions
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close
ok - fallback on a focus-preserving release: the plain explicit close preserved exact focus throughout
ok - version floor: herdr 0.8.0 protocol 19 is at or above the floor and preserves focus
ok - version floor: an unconfigured home stays projected on herdr 0.8.0 and the explicit opt-in agrees
evidence: herdr=0.8.0 protocol=19 steal_live=0 floor_verdict=0 default-session-tripwire=armed
```

Part C is the case the suite could not reach before: a doomed pane whose shell holds a persistent background child fails the lone-idle-shell proof on every sample, so the plan takes the plain explicit close, in the geometry where the closing workspace's right neighbour is a spacer rather than the focused anchor.
On 0.7.5 that fallback exposed a bounded four-sample wrong-focus window and restored the anchor exactly; on 0.8.0 the same fallback exposed none, which is why default-on projection is floored at 0.8.0 rather than mitigated further below it.
The suite also cross-checks its own Part A measurement against the floor classifier on whatever release it runs, so a drifted protocol-to-release mapping fails there rather than silently gating on the wrong thing.

### Presentation version floor

Default-on presentation projection is floored at Herdr 0.8.0.
The floor's structural signal is the selected running server's protocol number, falling back to the client protocol only when that selected session positively reports no running server, and the release mapping was measured on 2026-08-05 by running each pinned upstream macOS aarch64 release asset's own `status --json` through the guarded lab helper:

| Release | Reported version | Protocol | Carries both upstream focus fixes | Floor verdict |
|---|---|---|---|---|
| v0.7.3 | 0.7.3 | 16 | no | below |
| v0.7.4 | 0.7.4 | 16 | no | below |
| v0.7.5 | 0.7.5 | 17 | no | below |
| preview-2026-07-21-0f10e1453a7f | 0.7.5-preview.2026-07-21-0f10e1453a7f | 17 | no | below |
| preview-2026-07-29-44b3adb12552 | 0.7.5-preview.2026-07-29-44b3adb12552 | 18 | yes | below |
| preview-2026-08-04-d78e3d3b5126 | 0.8.0-preview.2026-08-04-d78e3d3b5126 | 19 | yes | above |
| v0.8.0 | 0.8.0 | 19 | yes | above |

No build lacking both fixes reaches protocol 19, and every pre-fix build tops out at 17, so protocol 19 is a safe structural expression of the 0.8.0 floor.
The one post-fix build below it is a preview that still reports a 0.7.5 version, so it is conservatively treated as below the floor, which costs a preview build its projection and never lets an unfixed build through.
The 2026-08-05 named-lab cross-version probe started a server from Herdr 0.7.5 and queried it with the installed 0.8.0 client; status reported client version 0.8.0 protocol 19, server version 0.7.5 protocol 17, server running true, and server compatible false.
That ordinary post-upgrade shape proves the running server owns the focus behavior, so the unconfigured default composes client and selected-server verdicts conservatively and rechecks after server ensure before publishing a journal or creating a workspace.

Refresh this table with the opt-in guard, which re-downloads the pinned assets, verifies their digests, and fails naming any release whose reported version, protocol, or verdict has moved:

```sh
SQUAD_HERDR_VERSION_FLOOR_LIVE_E2E=1 tests/sq-herdr-version-floor-live-e2e.test.sh
```

The classifier itself, the config preference it composes with, and the one-warning-per-release behavior are pinned portably with no Herdr installed:

```sh
tests/sq-backend-herdr.test.sh
```

Observed guarantees: every measured release classifies as the table records; either the protocol or the version signal alone carries an at-or-above verdict, and each divergent pair flips once the carrying signal is removed; client and running selected-session server verdicts compose conservatively, an unreadable server-running state and losing both release signals report indeterminate and fall back flat, the default is rechecked after server ensure before projection publication, an unconfigured base is projected only at or above the floor, an explicit `on`, including the historical empty opt-in file, is honored below it, and the below-floor warning is emitted once per base per detected release rather than once per spawn.

The whole real-Herdr lane was run on 2026-08-05 against both the CI-pinned Herdr 0.7.4 protocol 16, which is below the floor, and Herdr 0.8.0 protocol 19, which is at it:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh bin/sq-test-run.sh --lane real-herdr-gated
```

Both runs reported `family=real-herdr-gated count=11 failed=0`.
The projection suite's unconfigured-base case is release-aware rather than pinned to one outcome, so it proves the projected default on 0.8.0 and the flat fallback with its naming warning on 0.7.4:

```text
ok - real Herdr lab: a home that configured nothing is projected by default on herdr 0.8.0
ok - real Herdr lab: a home that configured nothing falls back flat on below-floor herdr 0.7.4 with one naming warning
```

Every other case in that suite uses an explicit opt-in or opt-out, so the floor leaves them unchanged on both releases.

Direct lab probes on 2026-07-28 established the removal rules the emptying-close plan relies on, each verified with `workspace list` focus reads around one mutation in a guarded `sq-lab-` session:

- An explicit `pane close` that emptied a non-focused workspace moved focus off the focused workspace in both before-focus and after-focus geometries.
- Ending a workspace's lone shell preserved the focused workspace exactly when the dying workspace sat behind it or the focused workspace was last, and moved focus to the focused workspace's right neighbor otherwise.
- The production focus-preserving close in the dangerous geometry repositioned the doomed workspace, ended its proved shell, and left every concurrent focus sample on the exact anchor with no corrective `tab focus` issued.

Two real-hardware conditions were required for the pane-death path to engage and are now encoded in the adapter and its unit fixtures: BSD `ps` reports a login shell's `comm` as `-zsh`, and an idle shell transiently hosts a prompt helper (starship) as a second foreground process immediately after a `workspace.move` relayout, which the bounded settle window absorbs.

The rules match the v0.7.5 tag source (`close_selected_workspace` reassigns focus from the closing workspace's index; `handle_pane_died` only clamps the stale focused index), and the upstream default branch resolves both paths by workspace id (PR #1877, commit `165dca45`, for the explicit close; PR #1912, commit `a979916`, for pane death), so the plan degrades to a harmless reorder-then-remove once a release carries them.

The full projection and restored-shell suites were re-run on 2026-07-28 on Herdr 0.7.5 with the updated close path; the presentation suite completed with `real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact`, and the restored-shell cleanup guarantee above was unchanged.

The teardown-level record-retention gate was verified on 2026-07-28 with metadata fixtures and a live contending lock holder:

```sh
tests/sq-teardown.test.sh
tests/sq-backend-herdr.test.sh
```

Observed guarantees: a contended presentation lock refused the teardown before the isolated copy was returned, with the task branch, every durable record, and the endpoint intact and no pane close attempted; the retry after the contention cleared returned the copy, closed the pane under the lock, and removed the records; an unknown structured-presence result after an attempted projected close retained the journal and every record with a nonzero exit; and every presence-gate mode accepted only a structured not-found as gone.

The same fixtures verified three further boundaries on 2026-07-29: missing or malformed endpoint identity and an unparseable pane presence refused record removal with everything retained; the SIGKILL escalation re-read the exact pane's process information and refused to signal when a different shell pid owned the pane, falling back to the plain close with the original process untouched; and a reposition whose removal then failed on every path restored the exact original workspace order through a second verified move and reported the close as failed.

The teardown fixture was re-run on 2026-07-31 after extending the same fail-closed boundary through forced XO cleanup, including recursive cleanup of a nested XO whose Herdr grandchild close remains unconfirmed.

Observed output:

```text
ok - forced XO teardown preflights every Herdr child before cleanup mutation
ok - forced XO teardown retains Herdr child identity until exact pane disappearance
ok - forced teardown retains a nested XO home and its grandchild's Herdr identity when the grandchild close is unconfirmed
```

### Composer and operational input

Real captures verified these active distinctions:

- Claude and Codex use bare `❯` and `›` agent composers.
- Pi uses content between complete separator rows and requires exact native Pi identity.
- Dim or faint suggestion text is ghost content, while normally styled text is pending input.
- Grok dark truecolor placeholders are ghost content, while bright truecolor typed input remains pending.
- A bare shell prompt has no safe agent-composer container and is unknown.

`tests/sq-composer-ghost.test.sh`, `tests/sq-composer-lib.test.sh`, and the Herdr composer cases pin the exact captured ANSI bytes.
The U+2063 operational and routed-request separators were exercised through a real Pi-on-Herdr path; the byte-exact active regression is:

```sh
SQUAD_SEND_MARKER_HERDR_E2E=1 \
  tests/sq-send-XO-marker-herdr-e2e.test.sh
```

### Native blocked event

The protocol-16 event path was measured on 2026-07-11 with Herdr 0.7.3 and Python 3.13:

```sh
HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-backend-herdr-eventwait-smoke.test.sh
```

Observed output:

```text
ok - real herdr: events.subscribe capability gate passes
ok - real herdr: a driven idle->blocked transition returns the blocked record in 0.129s
ok - real herdr: the sentry fast-path enqueues a stale wake naming the task window
```

Polling remained active and is covered as the fallback for capability, connect, subscribe, and repeated reader failure.

### Away-mode transport

The Pi/Herdr return and injection path was reverified on Herdr 0.7.3 and Pi 0.80.7:

```sh
SQUAD_AFK_PI_HERDR_E2E=1 HERDR_LAB_HELPER=bin/sq-herdr-lab.sh \
  tests/sq-afk-pi-herdr-return-e2e.test.sh
```

Observed guarantees: pending composer input refused injection and raised one alert; idle Pi accepted one marked escalation; the return gate refused ordinary work while a live blocker remained; resolving the blocker allowed the return flow.
The dedicated Herdr daemon workspace topology is covered by `tests/sq-afk-launch.test.sh` and preserves the commander tab's pane count.

## Zellij

The current compatibility floor and latest verification are Zellij 0.44.0 with `jq` on macOS aarch64.
All real tests use a uniquely named session and `tests/zellij-test-safety.sh`; they never touch a session named `Squad` or call all-session deletion.

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Headless session | `zellij attach -b <name>` without a TTY | Created a persistent background session and returned. |
| Session list | `zellij list-sessions --short --no-formatting` | Returned one plain name per line without starting a session. |
| Create tab | `zellij action new-tab --cwd <dir> --name <title>` | Returned a numeric tab id and focused the new tab when a client was attached. |
| Pane discovery | `zellij action list-panes --json` | Included terminal pane id, tab id, plugin flag, and top-level `pane_cwd`. |
| Literal send | `zellij action paste --pane-id <id> -- <text>` | Left text unsubmitted. |
| Keys | `send-keys --pane-id <id> Enter`, `Esc`, and one argument `Ctrl c` | All three shared operations worked. |
| Capture | `dump-screen --pane-id <id>` or `--full` | Worked with no attached client; no line-bound flag exists. |
| Close | `close-tab-by-id <id>` | Removed the live task pane and tab together. |
| Failure exit | actions against missing targets | Returned exit 0, requiring structural preflight and output-shape validation. |

`pane_cwd` stayed frozen when a foreground subshell changed directory.
The marker-delimited `pwd` probe returned the live nested cwd and is covered by the real smoke.
The focus mitigation restored the previously active tab after `new-tab`, with the unavoidable narrow race documented in the operator guide.

```sh
tests/sq-backend-zellij.test.sh
tests/sq-backend-zellij-smoke.test.sh
```

The real lifecycle smoke proved spawn, metadata, nested-subshell worktree discovery, send, capture, unlanded-work refusal, approved local landing, exact tab cleanup, and session cleanup without retaining task-specific ids or branch names here.

## Orca

Real readiness was verified against `/usr/local/bin/orca` with `/Applications/Orca.app` bundle version 1.4.116.

On Linux, readiness and the full task lifecycle were verified live on 2026-08-22 against the AppImage release v1.4.188 (`~/.local/bin/orca`) on Arch x86_64.
`orca serve --port <port> --json` satisfied the same readiness gate without the desktop app.
`orca worktree create` returned the composite id `<repo-id>::<absolute-path>` in `result.worktrees[].id`, which endpoint validation and teardown now accept alongside bare macOS ids.
A scratch recon spawn through `bin/sq-spawn.sh --recon --harness pi --backend orca` passed peek, a mid-turn steer delivered and queued by pi, and a clean `bin/sq-teardown.sh` run that removed every Orca worktree with no manual CLI cleanup.
That run predates the terminal-retirement records and the fail-closed exact-handle close described below, so it is not evidence for them.

```sh
orca status --json
```

Observed fields:

```text
result.runtime.reachable=true
result.runtime.state=ready
```

`orca terminal create --json` returned `result.terminal.handle`. The strict visible-tab gate now shipped was not in place for that build; the [live 1.4.243 creation observation](#2026-10-28---live-orca-14243-terminal-create-observation) below records the response shape it requires.
`orca worktree create` returned `result.worktree.id` and `result.worktree.path`.
Speculative bare ids and nested terminal fields were deliberately rejected.

```sh
tests/sq-backend-orca.test.sh
tests/sq-backend.test.sh
tests/sq-bootstrap.test.sh
tests/sq-retired-missions.test.sh
```

The fake-Orca suite covers readiness, registration, create response parsing, metadata routing, popup-safe submit, path-matched release refusal, and the managed Pi status extension's inclusion, absent-file launch, default `$HOME` path, and unset-`HOME` cases.
That last group proves the exact argv Squad sends and this repository's own behavior, not Orca's own rendering of the extension, so no end-to-end status display is claimed.
The suite also covers the mission-tab lifecycle: hosting-workspace resolution and refusal before allocation, the strict visible-tab creation gate and hidden-handle refusal, the guarded launch that never starts the agent in the base checkout, both recorded identities under the exact `sq-<id>` title, a single close on `done`, `failed`, or a finished sync with only a confirmed receipt, refusal to close a tab outside the hosting workspace, the absence proof for an already-closed tab, the refusal to treat an incomplete inventory as proof, preserving the record when a close is unconfirmed, and the terminal-less abort record released without `--force`.
The fake-Orca retirement fixture covers the durable terminal record written before task metadata can disappear, the exact-handle close and its retained record across a failed or ambiguous close, and the locked-bootstrap sweep that preserves every still-owned, dirty, or unreachable worktree.

No live Orca rerun was performed for that retirement change, so fixture coverage is the whole current evidence for it and proves nothing about real Orca behavior.
The fixture establishes only this repository's own command shapes, record ordering, and fail-closed refusals against a fake CLI.
A live Orca rerun would additionally prove that real Orca matches those shapes: that spawn and teardown still work on a real runtime, that `orca terminal close` on a recorded exact handle makes that handle absent in real inventory, that a real refused or ambiguous close leaves the handle observable so the recorded retry closes the same terminal, and that the locked-bootstrap sweep resolves real fob worktrees and their git registrations the way the fixture models them.

### Launch-script shell regression

Verified on 2026-10-29 with GNU Bash 5.3.20 (`sh`) and zsh 5.9.2 on Linux, using the fake-Orca CLI to capture the command emitted by the real spawn executable:

```sh
bin/sq-test-run.sh tests/sq-backend-orca.test.sh
```

```text
ok - Orca launch: real shells run short and long commands in the mission directory and refuse both guard failures
ok - Orca launch: script write failure stops spawn before delivering a harness command
ok - Orca launch: a task temp root this user does not control is refused before launch
```

The tests execute the delivered command with `sh -c` and, when installed, `zsh -c`, recording harness arguments and its physical working directory.
They cover quoted paths, a trailing-semicolon launch, missing and physically substituted mission directories, invariant terminal-command length with 20KB harness arguments, an unwritable launch script whose failed attempt is left queued for retry, and a task temp root this user does not control, which spawn refuses instead of writing an executable script there.
A task temp root owned by another user is refused even for a privileged spawn, because a privileged `chmod` would otherwise appear to succeed; that case runs only as root and is reported as skipped elsewhere.
This proves shell execution and this repository's launch protocol, not Orca's GUI transport or a real harness session.

### Native away-mode supervisor verification

Verified on 2026-10-24 with Linux Orca 1.4.188 and Pi 1.1.0, with separate proof boundaries rather than a combined real-runtime claim.
The real host was inspected read-only:

```sh
orca status --json | jq -c '{version:.result.runtime.appVersion,ready:(.result.runtime.reachable == true and .result.runtime.state == "ready"),runtimeIdentity:(.result.runtime.runtimeId | type == "string")}'
```

```text
{"version":"1.4.188","ready":true,"runtimeIdentity":true}
```

An existing shell endpoint's `terminal show --terminal <handle> --json` also supplied handle, incarnation, worktree/path, connected/writable and local-host fields, with `agentWait=null`.
No non-null `agentWait` record has been observed, so the blocked-prompt poll's record shape, its semantics, and whether presence alone means a human must answer remain UNVERIFIED and are covered only by `tests/sq-backend-orca.test.sh` and `tests/sq-sentry-triage.test.sh` against a fake CLI, which establish call shape and this repository's own behavior rather than end-to-end Orca behavior.
That identity schema is not proof of draft/modal safety or message consumption.
Two read-only shapes the Orca launcher depends on - the complete terminal inventory `orca terminal list --limit 10000 --json` response including `result.truncated`, `result.hostScope.omittedHostIds` and `result.terminals[].handle/incarnationId/worktreeId/worktreePath`, and the `orca terminal create --worktree/--command/--title --json` receipt - were observed read-only on 2026-10-25 (as a worktree-filtered list) and then exercised in the identity-bound lifecycle below.
That single shape observation leaves the worktree-filtered form's filter semantics UNVERIFIED and claims no real create or cleanup path; an unexpected or unreadable inventory still keeps the recorded creation intent uncertain instead of recovering an endpoint.
No terminal input, creation, close, worktree operation, host restart, or configuration change was performed on the shared real Orca runtime.
An independent user-data/profile boundary could not be established from the installed host's documented `serve` options, so the real-runtime lifecycle probe was not attempted.

Portable public-helper tests use a fake Orca CLI and the shipped Pi receiver:

```sh
bash tests/sq-afk-orca.test.sh
```

They cover named refusal for every unproven harness before mutation, unavailable readiness, mismatched targets, runtime-identity adoption that publishes readiness and permits a start with no supervisor variables, explicit-override precedence, no publication or start when the runtime identity is missing, malformed, partial or path-mismatched, real process-identity/launch-token refusal, native busy/draft/modal deferral, exact consumed acknowledgements, submitting/queued/uncertain replay refusal, reconnect/session/runtime replacement, cancelled cleanup, exact terminal preservation, and lost-create-response reconciliation.
The currently supported tmux, Herdr and TUIOS paths remain covered by `tests/sq-afk-launch.test.sh` and `tests/sq-daemon.test.sh`; real Herdr lifecycle is separately gated by the test's explicit opt-out and requires the normal isolated lab authorization.

The real-Pi guard is registered in the `live-harness-optin` family and was run with:

```sh
SQUAD_ORCA_PI_LIVE=1 SQUAD_ORCA_PI_MODEL=openai-codex/gpt-6.1-sol bash tests/sq-afk-orca-live-optin.test.sh
```

```text
ok - Pi 1.1.0 real interactive editor and built-in modal defer native delivery until safe; exact consumed acknowledgements retire both requests
limit - Orca CLI identity was fake; no real Orca runtime, daemon terminal lifecycle, or Android acceptance claimed
```

Only Pi is enabled for the new native receiver contract.
Pi-signed and every other harness refuse until individually proven; the existing TUIOS-native Pi path is unchanged.
The combined real Orca + Pi daemon lifecycle was subsequently verified below; combined real-host message consumption, macOS supervisor behavior, Chat UI support, and physical Android acceptance remain unverified.
[`orca-backend.md`](../orca-backend.md#away-mode-supervision) owns current selection, lifecycle, recovery and delivery limits.

### 2026-10-25 - read-only Orca host observation

On 2026-10-25, read-only observation of the installed Orca 1.4.188 host returned, for the worktree-filtered terminal list, ok=true, exactly one terminal matching the recorded worktree, totalCount=1, truncated=false, local host scope with no omitted host ids, and the same runtime identity as the earlier host.
That observation used the worktree-filtered `--worktree id:<worktree>` form; the shipped launcher instead reads the complete inventory with `orca terminal list --limit 10000 --json` and requires its `truncated`, `hostScope.omittedHostIds` and per-terminal `handle`/`worktreeId`/`worktreePath` fields, exercised in the lifecycle below.
The installed create help advertises worktree, title, command, focus and json flags and qualifies no-focus behaviour with 'when possible'.
Filter semantics, real terminal creation, cleanup, focus behaviour and Android operation remain UNVERIFIED.
No real lifecycle test was executed in that read-only observation.

### 2026-10-29 - identity-bound daemon lifecycle

Linux Orca 1.4.243 and interactive Pi 1.4.0 passed the actual launcher lifecycle in an authorized disposable task copy, using private lifecycle state and an exact lab-owned primary terminal.
The primary loaded the shipped `.pi/extensions/sq-primary-away-handoff.ts`; a lab fixture recorded that real Pi process's PID as its private session owner, and no model prompt was sent.
Only the lab primary and launcher-created daemon terminals were created/closed; no shared configuration, worktree lifecycle, host restart, or unrelated terminal was touched.

With `SQUAD_BASE` set to the disposable copy, `SQUAD_STATE_OVERRIDE` to its private state, `SQUAD_SUPERVISOR_BACKEND=orca`, `SQUAD_SUPERVISOR_TARGET` to the exact lab-primary handle, and `SQUAD_SUPERVISOR_HARNESS=pi`, the commands were:

```sh
bin/sq-afk-launch.sh start
bin/sq-afk-launch.sh status
orca terminal list --limit 10000 --json
bin/sq-afk-launch.sh start
orca terminal list --limit 10000 --json
bin/sq-afk-launch.sh stop
bin/sq-afk-launch.sh status
```

The `orca terminal list --limit 10000 --json` calls are the exact complete-inventory probe the launcher itself issues for pending recovery and absence proof, so the census around the repeated start describes the shipped contract rather than a worktree-filtered view.
Recovery accepts an inventory only when it has `ok=true`, `_meta.runtimeId` equal to the recorded parent runtime, `result.truncated=false`, an empty `result.hostScope.omittedHostIds`, and `handle`/`worktreeId`/`worktreePath` on every returned terminal.
The create receipt exercised on this host carried `_meta.runtimeId` plus `result.terminal.handle`, `result.terminal.incarnationId` and `result.terminal.worktreeId`, and omitted `result.terminal.worktreePath`; the launcher therefore binds the receipt's worktree id to the requested worktree id and the recorded base path when it persists the endpoint.
The complete sequence passed twice; the two inventories around the repeated start had identical handle sets, including exactly one recorded daemon identity.
The shell changed both daemon display titles to `zsh in sq-afk-orca-daemon-terminal-create` during startup, without preventing identity-based ownership, refresh, or cleanup.
Relevant exact output:

```text
sq-afk-launch: daemon already running; refreshed away-mode flag (no new terminal)
active=1 terminal=alive daemon=alive housekeeping_age=na scan_age=na
sq-afk-launch: away mode stopped; daemon terminal torn down and .afk cleared
active=0 terminal=absent daemon=dead housekeeping_age=16 scan_age=16
PASS: real Orca + real Pi start/status/idempotent start/stop, twice; active=0
```

Inactive `status` intentionally returned 1; successful start/refresh/stop returned 0, and the complete assertion driver exited 0.
The final cleanup confirmed no daemon record or away flag remained and closed only the exact lab primary.
A second real-host run also injected one unavailable inventory response after the real create receipt was persisted and the real daemon started.
The failed call retained `pending` plus the exact daemon identity; the next `start` adopted it, and the before/after inventory handle sets were identical.
No Orca identity response was faked, and no replacement terminal was created.
The assertion driver reported:

```text
PASS: real Orca + real Pi pending-identity adoption without replacement, start/status/idempotent start/stop, twice; active=0
```

Focus behavior, a fully lost real create receipt, and combined real-host message consumption were not tested.

Refresh the portable recovery proof with `bash tests/sq-afk-orca.test.sh`: it covers a renamed identity match, one create after recorded-identity absence despite an unrelated matching title, duplicate-identity refusal without terminal mutation, changed parent/base/incarnation/worktree refusal, incomplete inventory refusal, and preservation of handle-less lost responses with either zero or matching-title terminals.
The launcher's `bin/sq-afk-orca-launch.sh` owns the identity-recovery contract; a handle-less legacy record needs separately authorized live verification, never title-based automatic adoption or retry.

### 2026-10-28 - live Orca 1.4.243 terminal create observation

Observed live on Orca 1.4.243 (Linux) on 2026-10-28.
`orca terminal create --worktree id:<hosting-workspace-id> --title sq-<task-id> --json` returned `ok=true` with `result.terminal` carrying:

```text
result.terminal.executionHostId=<host id>
result.terminal.handle=<terminal handle>
result.terminal.hostPlatform=linux
result.terminal.incarnationId=<incarnation id>
result.terminal.paneKey=<pane key>
result.terminal.processId=<process id>
result.terminal.ptyId=<pty id>
result.terminal.surface=visible
result.terminal.tabId=<tab id>
result.terminal.title=sq-<task-id>
result.terminal.worktreeId=<hosting-workspace-id>
```

This observation is the evidence of record for the strict creation gate in `bin/backends/orca.sh`: a creation is accepted only when `result.terminal.surface` is `visible`, `result.terminal.tabId` is present, and `result.terminal.worktreeId` is exactly the hosting workspace that was requested, and any other handle is closed and refused.
Only this create response was observed live. Terminal input, close, worktree lifecycle, relaunch, and Android operation remain unverified against this host and are covered by the fake-Orca suite rather than by a real-runtime claim; Orca relaunch is refused on purpose until it has its own design.

## cmux

The current compatibility floor is cmux 0.64, and the active live evidence uses 0.64.17 build 97 on macOS aarch64.
Real tests use only exact `sq-test-` workspaces guarded by `tests/cmux-test-safety.sh` and never quit or relaunch the commander's app.

```sh
cmux version
cmux ping
```

Observed version:

```text
cmux 0.64.17 (97) [9ed29d81a]
```

Source and live checks established the five control modes:

- `off` starts no listener.
- `cmuxOnly` rejects an external Squad process by ancestry.
- `automation` uses an owner-only 0600 socket with no handshake.
- `password` uses the same 0600 socket plus `auth <password>`.
- `allowAll` uses a 0666 socket with no authentication.

The live default rejection was `Access denied - only processes started inside cmux can connect`.
The live password challenge was `Authentication required - send auth <password> first`.
The app configuration writer did not retain a hand-added socket password, which is why the operator guide requires Settings and a local Squad password source.

Current active CLI findings:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Create | `new-workspace --name <title> --cwd <dir> --focus false --id-format uuids` | Created one workspace with one surface without focusing it. |
| Fresh readiness | `list-panes --workspace <id> --json --id-format uuids` | Found a brand-new surface before content existed. |
| Fresh read counterexample | `read-screen` before any write | Returned `internal_error: Failed to read terminal text`. |
| Literal send | `send --workspace <id> --surface <id> -- <text>` | Left text unsubmitted. |
| Keys | `send-key ... enter|escape|ctrl-c` | All shared key operations worked. |
| Nested cwd | `current_directory` plus foreground subshell | Structured cwd froze; the marker-delimited `pwd` probe found the live cwd. |
| Last surface | `close-surface` on the only surface | Refused with `invalid_state: Cannot close the last surface`. |
| Last workspace | `close-workspace` on the only workspace in a window | Printed success but left the workspace present. |

The last-workspace workaround was reverified on 2026-07-10 in Automation mode.
After creating one unfocused unnamed sibling in the same window, `close-workspace` removed the exact task workspace and left only cmux's default sibling.
A selected non-last workspace closed directly, proving that window cardinality rather than selection is the trigger.

Source inspection confirmed each workspace constructor creates a new UUID with no restored-id input.
Recovery therefore remains title-based.
The bundled Claude wrapper was observed stripping `CMUX_*` variables on its failed socket-probe path while retaining the app bundle id, supporting the macOS-only bundle-id and ancestry fallbacks.

```sh
tests/sq-backend-cmux.test.sh
tests/sq-backend-cmux-smoke.test.sh
```

The real smoke proves socket access, fresh readiness, current-path probing, send and keys, bounded capture, title identity, and guarded exact cleanup.

## Codex App host tools

A reusable Desktop host-tool smoke ran on 2026-07-06 against Codex Desktop bundle version 26.623.101652, build 4674, bundle id `com.openai.codex`.
Local paths and task-specific ids are intentionally not retained here.

The host-tool sequence was:

1. list a saved project;
2. create a Desktop-owned worktree thread;
3. recover and read the thread while active and after completion;
4. verify the thread appended a Squad status line and wrote its report;
5. send a follow-up to the same thread;
6. read the completed follow-up;
7. archive the exact thread;
8. read the archived transcript with state `notLoaded`.

Observed guarantee: a Desktop-owned thread can write Squad lifecycle files when the prompt provides an authorized absolute path, and create, send, read, and archive work at the Desktop host-tool layer.
The missing guarantee remains a supported shell-callable bridge that lets Squad perform those operations against the same visible Desktop endpoint.
App-server partial methods and raw socket experiments do not satisfy that bridge contract.

## TUIOS

The current shared runtime is `tuios version 0.9.1 [pure-Go backend]`, commit `a9e96db81607bc0ed42ccd02d2fb5a564c35b808`; earlier live scenarios below retain the version used for each run.
Mechanisms are validated against the installed binary's own `--version`, `list-verbs`, and `--help` surfaces.
Portable regression coverage (fake CLIs, no live daemon):

```sh
tests/sq-backend-tuios.test.sh
tests/sq-spawn-tuios-worktree.test.sh
tests/sq-afk-launch.test.sh   # fake-CLI TUIOS detached-session lifecycle, attached-session protection, and created-session rollback
tests/sq-daemon.test.sh       # Pi handoff durability, v3 ready-schema, busy/draft/open-prompt deferral, acknowledged-prefix retirement, and abandoned-request republication
```

Live evidence was collected on 2026-09-29 against one disposable session (`sq-tuios-b3-probe`) on the shared daemon, created for the run and destroyed at the end.
The shared daemon was never restarted, reconfigured, or killed (its boot id stayed `563ac0d7c9eb50f8` throughout), `session-0` and `squad-tuios-live-check` were never read, written, attached to, retitled, or closed (their window counts stayed 0 and 4), and the private daemon used for the restart case had its own fresh `XDG_RUNTIME_DIR`, `XDG_STATE_HOME`, and `XDG_CONFIG_HOME` under `/tmp`, removed afterwards.

Established live:

- **Spawn completes and records the exact worktree.** `bin/sq-spawn.sh sq-tuios-b3-spawn <project> --recon --backend tuios --harness pi` with an isolated base and `SQUAD_TUIOS_SESSION` set printed `spawned sq-tuios-b3-spawn harness=pi kind=recon window=sq-tuios-b3-probe:1e6e2289-... worktree=/home/rehem/.fob/squad-b4752b/6/squad`, rc=0. The recorded `worktree=` equalled the `fob get --lease` path, the live window's reported `cwd` equalled it too, and the metadata carried `backend=tuios`, `tuios_session=`, `tuios_window_id=`, and `tuios_boot_id=`. The window only ever received `cd -- '<lease>'`; the nested-shell `fob get` sequence was never sent.
- **Delivery reports the truth.** Against a real Pi pane the adapter's queue path returned success (`bin/sq-send.sh` exit 0) and the agent answered; the queue entry was taken (empty `tuios queue ls`). A pane on `needs_input` returned `verdict=agent_blocked` with "nothing was typed" and exit 1, and no keystroke reached it. A pane TUIOS believed was at rest but which never took the prompt returned `verdict=stalled` after 5s, exit 1, with the message that the text was typed and must not be resent; `tuios queue ls` showed the entry `stalled`. A full queue returned `verdict=queue_full`, exit 1. A pane with no attributable agent fell back to the literal write and returned `verdict=uncertain-delivery`, exit 1; that fallback was removed afterwards, so the current adapter reports the daemon's no-attributed-agent refusal as `verdict=no_agent` with nothing typed, which `tests/sq-backend-tuios.test.sh` covers portably but which has not been re-run live since the change.
- **State and prompts are real.** `bin/sq-crew-state.sh` reported `state: working ... harness busy (pi-ext)` for the running Pi task instead of a hard-coded unknown. For a pane reported at `needs_input` with a Claude Code approval screen, `tuios peek-prompt` returned `found=true`, `message="Do you want to proceed?"`, numbered options, and a prompt id, and `sq-crew-state` rendered `state: blocked ... harness waiting on a prompt (approval: Do you want to proceed?)`. The adapter's own verdicts on that pane were `agent=alive busy=blocked`.
- **Restart recovery is classified, not degraded.** On the private daemon a window was recorded with a Claude Code conversation id; the daemon was then killed (boot id `2744b70b81779419`) and restarted (boot id `fdae56582011edb7`). The restored pane kept its window id and label but ran a fresh shell (`-- tuios: session restored, fresh shell in /tmp --`), reported `state=none` with no attribution, and kept its recorded `agent_session_id`. Against that pane the adapter returned `agent_state=dead`, `busy_state=unknown`, `reuse_restored_task=<window>` only with the changed boot id (a same-boot call and an agent-owned window were both refused), `resume_agent` = `resumed` for Claude Code (the typed `claude --resume <id>` was visible in the pane), and `resume_agent` = `unsupported` for Pi. The branch's pre-change classifier, sourced from the committed adapter, returned `ambiguous` on the same live target.
- **A finished agent whose program exited is classified, not degraded.** On 2026-10-05 the shared daemon (boot id `4232f14bf45b083a`) was read through the adapter with `fm_backend_tuios_agent_report_json` and `fm_backend_tuios_agent_state`; only `list-windows` and `list-agents` reads were issued, and no window, session, or daemon state changed. The exited Pi task `sq-runecraft-warroom-discovery` (`squad:e58cdaa8-...`) reported `state=done`, `harness_id=pi`, `confidence=certain`, and `foreground=""`, and the adapter returned `agent_state=dead`. Two live Pi tasks in the same session, `sq-eihwaz-frontend-redesign` (`foreground=pi`, `state=done`) and `π - squad` (`foreground=pi`, `state=done`), both returned `agent_state=alive`.
- **Cleanup closes only the task window.** `bin/sq-teardown.sh sq-tuios-b3-spawn` reported `teardown ... complete (window sq-tuios-b3-probe:1e6e2289-...)`; only that window disappeared, the session's other windows survived, every other session's window count was unchanged, and the leased worktree returned to the pool (`fob status` showed it `available`).
- **Protocol discovery refuses a narrower daemon.** The catalogue check rejects a missing required verb, a missing required parameter, an unreadable catalogue, and a malformed catalogue before any task window is created; the portable test pins each refusal.
- **Per-task workspace allocation is portable-tested.** `tests/sq-backend-tuios.test.sh` verifies preferred-workspace selection, occupied/named/leased exclusions, explicit `--workspace` placement, exact-ID verification, and guarded release after the task window is gone. Invalid inventory and mismatched placement refuse rather than selecting a shared destination.
- **Per-task placement preserves the live private layout.** Against the already-running isolated nine-workspace TUIOS lab, two sequential task-window creations landed in different non-current workspaces (2 and 3). The original window record, its focused state, and the current workspace remained unchanged. Both exact probe windows were then closed, both task-owned workspace names were cleared, and the lab returned to one original window with every other workspace empty and unnamed. This check used only the private lab session; no shared daemon or non-lab session was addressed.
- **Away-mode supervision delivered natively, with no keystroke into the pane.** On 2026-10-05, `SQUAD_TUIOS_AFK_LIVE=1 bin/sq-afk-tuios-lab.sh lifecycle` ran against a private TUIOS 0.8.0 daemon with fresh `XDG_RUNTIME_DIR`, `XDG_STATE_HOME`, and `XDG_CONFIG_HOME` under `/tmp` (removed afterwards), a temporary Squad base, and installed Pi 0.99.0 with a loopback-only mock OpenAI-compatible provider. The production `inject_msg` path published a durable handoff request, `.pi/extensions/sq-primary-away-handoff.ts` queued it with `sendUserMessage(..., { deliverAs: "followUp" })`, Pi acknowledged consumption at `before_agent_start`, and the mock provider recorded exactly one request. No text or keystroke was sent into the pane.
- **An open Pi prompt holds delivery until it closes.** In the same run a real `ctx.ui.confirm` dialog was opened while the primary was idle (the probe recorded `isIdle()` as `true` at open). The version-3 `ready.json` reported `prompts=1`, the queued escalation stayed unacknowledged with no model request for the whole 3-second hold window, and releasing the hold closed the dialog and delivered that escalation on the next model request. Recording `isIdle()` at open isolates the prompt guard from the idle guard.
- **Post-review fixes are portable-covered and live-reverified.** A failed launch now closes the exact TUIOS session it created (fake-CLI regression), and an acknowledged handoff retires exactly the buffer prefix it covered while a definitively failed or abandoned request is republished without ever replacing a live in-flight send (daemon regressions). The guarded lab was rerun after those changes on 2026-10-05 and reported the same start, status, prompt-hold, and clean stop result.
- **Readiness is per target and the composer is readable (2026-10-19).** The 2026-10-06 overnight wedge (`inject deferred: supervisor composer not confirmed-empty (state=unknown ...)` for roughly nine hours) had two causes found on the live base: the shared `state/.pi-away-handoff/ready.json` was being overwritten by Pi workers running in Squad worktrees (they inherit `SQUAD_BASE` and the TUIOS pane variables and load the same project extension), so the primary's record was never the one on file, and the TUIOS adapter's composer state was a fixed `unknown`. `SQUAD_TUIOS_AFK_LIVE=1 bin/sq-afk-tuios-lab.sh lifecycle` was rerun against a private TUIOS 0.9.1 daemon with installed Pi 1.1.0: the extension published `ready.<session>.<window>.json` and no shared `ready.json`, the production `inject_msg` delivered through it, the open-prompt hold still held, and the real Pi composer read `empty` when idle and `pending` once an unsent draft was typed. That run also showed stock Pi 1.1.0 draws rules above and below its editor instead of a box, which the first classifier missed and the guard caught. The composer-path delivery itself (queue-prompt after an `empty` read) was exercised only against stubs, not a live Pi. Refresh with `bin/sq-afk-tuios-lab.sh lifecycle` after every Pi or TUIOS upgrade.
- **Launcher lifecycle is exact and unattached.** The guarded lab ran `start`, `status` (`active=1 terminal=alive daemon=alive`), and `stop` to completion, the recorded detached daemon session was removed, and `.afk` plus `.afk-daemon-terminal` were cleared while the test-owned target session's exact window inventory stayed unchanged.
- **Stop allows a full default sentry poll.** With the real default `SQUAD_POLL=15`, stop previously declared a healthy shutdown stuck after roughly 10 seconds. The launcher now waits through one full poll interval, and the portable `stop poll` regression pins it.
- **`respond` belongs to the pane that types the answer (2026-10-20).** Verified against TUIOS 0.9.1, commit `a9e96db81607bc0ed42ccd02d2fb5a564c35b808`, on one disposable session and one private daemon with fresh `XDG_RUNTIME_DIR` and `XDG_STATE_HOME` under `/tmp` (both destroyed afterwards); the shared daemon was only read through `pane-grants` and `list-windows`. With a pane reported `needs_input` (`tuios set-agent-state needs_input -w <window> --kind approval`), `tuios send-keys -w <blocked> Enter` from a pane holding `admin` returned rc=1 and `send-keys is refused for this pane: window <id> is waiting on a prompt, and what is typed now would answer it, which needs the respond grant`, whose hint named the caller's own pane; after the same pane held `admin,respond` the identical command returned rc=0 and printed `sent 1 key`. `tuios set-pane-grants -w <self> --grants admin,respond`, the same call for another pane, and `tuios new-window --grants read,write,fan,respond` were all refused from inside a pane with `set-pane-grants is refused for this pane: a pane cannot give more than it holds`, while the same grant from a caller running in no pane succeeded and read back as `{"grants":["respond","admin"]}`, and `--reset` restored `grants: null`. A pane that already held `respond` was allowed to give another pane `admin,respond`, so one outside-pane delegation is enough to seed the rest. `bin/sq-pane-grants.sh` and `tests/sq-pane-grants.test.sh` cover the wrapper and the `sq-send` remedy hint portably, and the portable tests drive `show <target>`, `grant respond`, and `verify` from the outside-pane payload below, which is the only caller TUIOS accepts for the first grant.
The payload shapes that wrapper reads were captured from that daemon: `tuios list-windows --json` returns `{"success":true,"windows":[{"window_id":"<uuid>","display_name":"<label>","agent_state":"...","grants":["respond","admin"]}]}` with `grants` absent for a pane holding the daemon default, and `tuios pane-grants --json` returns `{"success":true,"pane":true,"session":"squad","window":"<uuid>","explicit":true,"mode":"open","default_grants":["admin"],"grants":["admin"]}` from inside a pane, and `{"success":true,"pane":false,"mode":"open","default_grants":["admin"],"message":"command executed","note":"The caller runs in no pane of this daemon, so no pane grants apply to it."}` from a caller outside every pane, re-read with `tuios pane-grants --json` from the person's own shell. The outside-pane payload carries no `session`/`window` but still reports the daemon's `default_grants`, which is what lets the add-only read resolve a default-granted pane from that placement. The daemon's own verb catalogue (`tuios list-verbs --json`, `daemon_version 0.9.1`) lists `pane-grants` with those returns and `set-pane-grants` with the params `session`, `window`, `grants`, and `reset`, so the wrapper's `set-pane-grants --session <session> --window <uuid> --grants <csv>` and its re-read are the daemon's documented parameter set rather than a guessed one.

Native event subscription was checked read-only on 2026-10-25 against the current shared TUIOS 0.9.1 daemon; the shared session was subscribed to for one second and only the probe process was terminated at timeout.

```sh
python3 bin/backends/tuios-eventwait.py tuios squad 1 d1828f70-56fb-4251-bdbd-eaeaca1d8df6
tuios list-verbs --json | jq -e '.verbs[] | select(.verb=="subscribe") | {verb,params:[.params[].name],returns:[.returns[].name]}'
```

Observed output:

```text
@subscribed
reader_rc=0
{"verb":"subscribe","params":["session","window","types","queue","after_seq","boot_id","hosts"],"returns":["seq","boot_id","replayed"]}
```

This proves the current CLI can establish a session-scoped event stream.
On its own it does not prove a blocked-agent event, supervisor wake, answer, or resume; the isolated lab below does.
`tests/sq-backend-tuios.test.sh` pins what the fake CLI can prove: the baseline reconcile alone does not satisfy the wait, the consumed event line triggers its own authoritative re-read, the reader keeps its full budget after a non-actionable event, and SIGTERM terminates the subscription child. None of that is a substitute for the isolated real-runtime scenario below.

### The blocked-operator answer path in an isolated lab (2026-10-25)

`SQUAD_TUIOS_AFK_LIVE=1 bin/sq-afk-tuios-lab.sh respond` (driven by `tests/sq-tuios-respond-live-optin.test.sh`) ran the whole answer path against a private TUIOS 0.9.1 daemon: `tuios daemon --no-restore` with fresh `XDG_RUNTIME_DIR`, `XDG_CONFIG_HOME`, and `XDG_STATE_HOME` under `/tmp`, one disposable session (its boot window plus the operator and unauthorized-answer windows), all removed at the end. The private `config.toml` carried `[daemon] respond_from_shell = true`, so the caller outside every pane - the person's own shell - is an authorized actor on that daemon. The shared daemon, its sessions, its config, the pane grants, and the installed TUIOS binary were not touched, and no watched session was addressed.

The operator pane is a scripted harness, not a vendor CLI: it draws the Claude Code approval form the daemon's own bundled `claude-code` manifest reads, reports `needs_input --harness claude-code --kind approval` the way an installed hook reports, then consumes the pressed digit and reports `working`.
Everything else in the cycle is the production path: the daemon's own screen rule and `peek-prompt` read, the adapter's `subscribe`-based native event wait, `handle_push_transition`'s wake, `bin/sq-send.sh --respond`, and the adapter's `fm_backend_tuios_respond`.

Observed output:

```text
respond-lab: tuios=tuios version 0.9.1 [pure-Go backend] lab_session=sq-afk-lab-2397900315-348316-30139 operator_window=sq-afk-lab-2397900315-348316-30139:fa6c7a1f-b21f-4363-b1b3-c16eda37e672
respond-lab: native_event_wait_rc=0 record=fa6c7a1f-b21f-4363-b1b3-c16eda37e672			blocked
respond-lab: supervisor_wake=stale: sq-afk-lab-2397900315-348316-30139:fa6c7a1f-b21f-4363-b1b3-c16eda37e672 (tuios: agent blocked - approval: Do you want to proceed? [1) Yes 2) Yes, and don't ask again for similar commands 3) No, and tell Claude what to do differently (esc)] - waiting on human, escalated immediately, not via wedge timer)
respond-lab: prompt_id=9f5b19446fb8b12d option_numbers=1 2 3
respond-lab: unauthorized_answer_rc=1 output=●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
respond-lab: authorized_answer_rc=0 answer={
  "action": "approve",
  "message": "approved; running the command",
  "prompt_id": "9f5b19446fb8b12d",
  "sent": "1",
  "session": "sq-afk-lab-2397900315-348316-30139",
  "settled_by": "state",
  "state": "working",
  "success": true,
  "window": "fa6c7a1f-b21f-4363-b1b3-c16eda37e672"
}
respond-lab: resume_key=1 resume_line=Approval received for the exact prompt; resuming the tool call.
respond-lab: pane_busy_after=busy duplicate_answer_rc=1 duplicate_output=WARNING: sentry still down (same stale episode; last beat: never, grace 86400s) - full banner already printed this episode.
respond-lab: replay_event_wait_rc=1 replay_record=
```

Both refusals were produced by `sq-send`, which prints its supervisor-guard banner first; the run echoed the first captured line of the in-pane attempt and the first line of the duplicate's stderr, so those two excerpts are the banner rather than the refusal itself.
The evidence for those steps is the exit codes and the untouched key file, and the lab now echoes the in-pane attempt's last captured line and the duplicate's `nothing was answered` line instead.

The runner asserted each step and exited 0. Step by step:

- **The blocked prompt is detected natively.** The adapter subscribed before the prompt existed, its baseline reconcile saw no prompt (the wait had not returned), and the record it returned after the pane reported `needs_input` was a `blocked` transition - so it came from the daemon's agent-state event, not from the post-handshake reconcile.
- **The question reaches the authorized actor.** `handle_push_transition` produced the supervisor wake naming the exact window, the operator's question, and all three numbered options, and durably enqueued it in `.stand-to-queue` for the supervisor.
  The wake line shown above was recorded before the prompt summary also named the exact prompt id; the current summary appends `prompt_id=<id>` after the numbered options, the same line is what `bin/sq-crew-state.sh` renders for a blocked operator, `tests/sq-sentry-triage.test.sh` pins the queued wake carrying it, and the lab asserts the wake names the id it later answers.
- **Only an authorized actor can answer.** `sq-send --respond approve <prompt-id>` run from an ordinary agent pane (the daemon's default `admin` grant, no `respond`) exited 1 and pressed nothing: the operator pane's key file stayed empty. The daemon answers `respond` only for an attached client, a pane holding `respond`, or, with `respond_from_shell`, a caller outside every pane.
- **The exact prompt is answered and the operator resumes.** The same command from the lab's own shell (outside every pane) answered prompt `9f5b19446fb8b12d`, the daemon confirmed `sent: "1"` for that prompt id and `settled_by: state` after the pane left `needs_input`, the operator pane recorded exactly the digit `1` and printed its resume line, its busy state read `busy`, and `peek-prompt` no longer reported a blocking prompt.
- **No duplicate after an uncertain or reconnected state.** A second `--respond` for the same prompt id was refused (`rc=1`, `nothing was answered`) and pressed no second key; a second native wait on reconnect returned `rc=1` with no record; and the poll producer returned no fresh blocked edge for the settled pane.

The daemon's own `peek-prompt` payload from that run (preserved by the lab's first attempt, same binary and scenario, before a transcript-assertion fix) is the shape the adapter reads:

```json
{"blocked":true,"found":true,"kind":"approval","message":"Do you want to proceed?","options":[{"label":"Yes","n":1},{"label":"Yes, and don't ask again for similar commands","n":2},{"label":"No, and tell Claude what to do differently (esc)","n":3}],"prompt_id":"0fa61f2c552b7108","actions":["approve","approve_always","deny","choose"],"reason":""}
```

The scenario was started twice in total. The first start reached the native event and the wake but the lab's transcript assertion expected the pane's reported `-m` text instead of the question the daemon's screen rule read; that is a defect in the assertion, not in the path, and its preserved evidence supplies the payload above. The second start passed every assertion. No third start was attempted.

Not established:

- `not_ready` and `prompt_stalled` were not observed live. They are mapped from the daemon's documented refusal codes and covered by the fake-CLI test, but the asynchronous queue path does not raise them; they belong to the synchronous ask path, which Squad does not currently call.
- A live `queue-prompt` refusal reason other than `queue_full` and the no-attributed-agent refusal was not produced.
- The bounded queue observation window (10s by default) proved wide enough for the observed 5s stall gate; a slower daemon configuration could close the window while an entry is still being typed, in which case the adapter reports the entry as safely queued and the daemon's Inbox question is the durable signal.
- An isolated real-runtime run in which a vendor harness (Claude Code, Codex, or Pi) drives its own approval dialog and resumes after `respond` has not been run; the isolated lab above draws that dialog's screen from a scripted operator process and reports the state the way an installed hook reports it.
  The lab therefore proves the daemon's prompt parsing, the native blocked event, the production wake, the authorization boundary, the exact-prompt answer, and the observed resume - not a vendor CLI's rendering or a model turn, and not the Inbox hold path.
- Only the `approve` action was answered live. `choose -- <n>` and `text -- <value>` value handling, the refusal of a value on an action that takes none, and the fail-closed refusal when a prompt read carries no `actions` array or an action absent from its list, are covered by the fake-CLI test; a prompt with no readable `actions` keeps the older `--key` path available.
- Simultaneous allocations across separate Squad bases sharing one TUIOS session have not been exercised live. The adapter uses one per-session lock under the user's shared `XDG_RUNTIME_DIR` when available, then rechecks authoritative session inventory before each creation.
- The finished-and-foreground-less recovery rule is derived from one daemon build (TUIOS 0.8.0): every live agent observed reported a `foreground` program, and the one exited agent reported none. A build or harness that reports `state=done` without a `foreground` program while its agent is still running has not been observed; `docs/tuios-backend.md` "Finished-agent recovery" names that as the unproven case.
- The away-mode live path was verified against one Pi version (0.99.0) and one TUIOS build (0.8.0). Its open-prompt guard reads Pi's `ui_prompt_start`/`ui_prompt_end` events, which are not a documented public API, so a Pi upgrade must re-verify that they are still emitted before the guard is trusted.
- The away-mode lab replaces the model with a loopback stub, so the verified claim is delivery into Pi's own queue and the start of a real agent turn, not any particular model's response or the content of a completed turn.

Never use the commander's watched sessions as a test fixture. A live TUIOS run creates and destroys its own disposable session, and a restart experiment uses a private daemon with fresh `XDG_RUNTIME_DIR`/`XDG_STATE_HOME`/`XDG_CONFIG_HOME` as the installed product skill documents.
