# herdr-core runtime backend

herdr-core is an experimental terminal-endpoint backend.
It owns terminal endpoints only; Squad and fob keep task identity, task state, and the isolated git worktree, exactly as on every other session-provider backend.
Shared backend selection and metadata semantics are documented in [`configuration.md`](configuration.md#runtime-backend-configbackend--squad_backend); [`verification/runtime-backends.md`](verification/runtime-backends.md#herdr-core) owns the live evidence and states what is not yet established.

The adapter is `bin/backends/herdr-core.sh`.
It drives the commander's already-running `herdr-core` core through its `hc` CLI, so the desktop app and the phone see the same terminals Squad creates.

## Setup

Requirements: herdr-core 0.1.22 or newer with an API compatible with protocol generation 1, `jq`, and `fob` for the worktree.
The `hc` binary (or its `herdr-core` name) must be on `PATH`; `SQUAD_HC_BIN` overrides the resolved command.

A core must already be running: started by the desktop app, by systemd, or by the person with `hc server start`.
Squad never starts one - see "Never starts a core" below.

Select the backend explicitly with a local `config/backend` containing `herdr-core`, by exporting `SQUAD_BACKEND=herdr-core`, or per task with `--backend herdr-core`.
It is never auto-detected: an `hc`-managed terminal carries no marker this layer may trust, and guessing would let one bad marker move every new task onto a shared daemon.

The core's session is `HC_SESSION`, and unset means the `default` core - the one the desktop app and the phone attach to.
A task records the session it was created in, and every later operation refuses that task if the process no longer resolves the same session.
`HC_SOCKET` is honored as the product's own socket override.

## Never starts a core

Any `hc` call starts a core when none is running, and a core started that way inherits the caller's whole environment - including credentials and other backends' markers.
So the adapter refuses to run `hc` at all unless the session's socket exists **and** a probe proves a listener answers on it:
The socket is the one `hc` itself uses: `${XDG_RUNTIME_DIR}/herdr-core/<s>.sock` when `XDG_RUNTIME_DIR` is set and non-empty, otherwise `${XDG_STATE_HOME:-~/.local/state}/herdr-core/<s>/<s>.sock` - a host without a runtime directory, such as a container or a bare ssh session, keeps the core only in the state directory, and `/run/user/<uid>` is not a fallback `hc` ever used.
`HC_SOCKET` overrides both.

```text
error: herdr-core is not running for session 'default' (no core listening at /run/user/1000/herdr-core/default.sock); Squad never starts the core - start Herdr or run 'hc server start' yourself
```

A socket file alone is not a core: after an unclean core death the file survives while nothing accepts on it, and the next `hc` call would start a core with Squad's environment.
The listener probe is a unix-socket connect by a client that cannot start anything - `python3`, then `curl --http0.9 --unix-socket`, then `nc -U -z` - so a stale socket refuses exactly like an absent one, and when none of those clients can prove it - including a client that fails before it ever connects, such as a `curl` build without `--unix-socket` or `--http0.9` - the adapter fails closed and names what to install.
`hc` answers in HTTP/0.9 - raw JSON-RPC lines, no HTTP framing - and keeps the connection open afterwards, so the curl probe asks for HTTP/0.9 and accepts the exchange when any response bytes arrive, not when curl exits 0.
A reply-less exit, a connect timeout, or a refused connection therefore proves nothing and refuses.
That check runs before the version handshake, before the first `get`, and before every write, so no path in this backend can start a core.
When the core is absent, the task is a blocker: bring the core up and retry, or spawn on another backend.
`tests/sq-backend-herdr-core.test.sh` pins the rule by asserting zero `hc` invocations on a session with no socket and on a session whose socket file is stale, and the lab proves the same against a real missing core.

## The version and protocol guard

Before a task endpoint is created, `fm_backend_herdr_core_protocol_check` refuses - loudly, by name - every core it has not verified:

- **handshake**: one `hello` for protocol generation 1 over `hc connect`. A core that answers `unsupported_generation` is refused with the core's own hint.
- **floor**: version 0.1.22 or newer, the measured build. A lower or unparsable version is refused with the version named.
- **features**: `status` and `events` must be advertised by the handshake.
- **methods**: `terminal.run`, `terminal.get`, `terminal.list`, `terminal.read`, `terminal.send`, `terminal.keys`, `terminal.kill`, `terminal.rm`, and `events.subscribe` must all be present.
- **parameters**: from `hc schema --json`, `terminal.run` must accept `no_parent`, `labels`, `cwd` and `name`, `terminal.send` must accept `if` and `force`, and `events.subscribe` must accept `labels`.
- **core identity**: `server status` must report a core id. It is recorded per task as `hc_core_id=`.

A missing method, parameter, or feature refuses that core by name; nothing degrades silently and nothing is guessed.
A newer build of generation 1 is accepted by design, so a semantic change inside the generation would only appear as a broken read; `docs/verification/runtime-backends.md#herdr-core` records the tested version.

## Targets and task metadata

Each task endpoint is `hc_address=`, an opaque address such as `t1` or `t1b`.
It is stored verbatim and never parsed, derived, or assumed numeric: after a registry empties, the next address is not necessarily the next number.
The shared target a reader sees is `<hc_session>:<hc_address>`, with `hc_session=default` for the default core.

Task metadata therefore carries `backend=herdr-core`, `endpoint_task_id=`, `hc_session=`, `hc_address=`, and `hc_core_id=`.
Every created terminal carries two labels: `squad.task=<task-id>` (the identity a destructive step checks) and `squad.base=<base-label>` (Squad's grouping, since herdr-core has no workspace or session layer).
A third, optional placement - `herdr.space` plus `herdr.tab` - puts the terminal in the person's desktop app - see "Desktop and phone presentation" below.
The base label is the readable base directory name plus a short hash of the physical resolved base path, for example `squad-1a2b3c4d`, so two bases whose directory name matches (the ordinary `squad` clone name) never share one label.
The terminal name is derived from the base identity as well as the task id, because the product's name registry is core-global while every base numbers its tasks from the same start.
It is `sq-<base-hash>-<task-id>` when the id survives slugification unchanged and the whole name fits, so task `1` in two bases becomes `sq-1a2b3c4d-1` and `sq-9f8e7d6c-1`.
Every other id - a longer one, or one whose sanitized slug differs from it - is truncated and disambiguated by a hash of the full id, so `demo` and `sq-demo` cannot share one name inside a base either, and every name fits the product's 32-character limit of a-z 0-9 - _.

## Desktop and phone presentation

An unlabeled terminal shows in `hc ls` and on the phone, but not in the desktop app's spaces.
To have Squad's tasks appear there, put one space id in the local file `config/herdr-core-space`:

```text
sp7b9a496a3b6da2d94d5341c408030af3
```

It is one positive identifier, read once per create from the effective config dir (`$SQUAD_CONFIG_OVERRIDE`, otherwise `$SQUAD_BASE/config`) on its first non-empty line, with surrounding whitespace stripped - the same convention `config/backend` and `config/crew-harness` already use.
Nothing is inferred: the file names the space, and an id the app does not know becomes a new space under the app's own name.
Space ids are local to this machine's app, exactly as the product's own labels are, and `herdr-app ls` prints them.

With the setting present, every terminal the adapter creates also carries two labels, written right after the create returned its address so they can only ever name that one terminal:

- `herdr.space=<configured id>` - the space the task belongs to.
- `herdr.tab=sq-<base-hash>-<slug>` - the tab inside that space: the same base-scoped, collision-safe name the terminal is created with (for example `sq-1a2b3c4d-demo`, or that name with the id hashed when its slug is long or lossy), so one mission owns one tab and a relaunch returns to that tab instead of stacking a second one.

That pair is all the product needs.
Measured on the live core: a terminal created exactly as Squad creates it - `hc run --bg --no-parent` - has no pane, but writing those two labels makes the app show it as its own tab in the configured space, leaving the tab the person was using untouched.
Neither `--keep`, nor `attach`ing after the create, nor creating without `--bg` was needed.
The full transcript, including the reversal, is recorded in [`verification/runtime-backends.md`](verification/runtime-backends.md#herdr-core).

The write is best-effort and never changes a task's outcome:

- **Absent, unreadable, or blank setting** - no label is written and nothing else changes. This is the default, and it is exactly the behavior before this setting existed.
- **A failed write** - the spawn keeps the terminal it created and prints a warning naming the exact address and the command that sets the labels by hand. Placement is deliberately outside the version and protocol guard: a core whose CLI lacks the label command warns and keeps the task, because a missing display preference must never block real work.
- **Idempotent** - it is a plain label set, so repeating it leaves exactly one value per label.

Adoption has two product-side consequences worth knowing.
A terminal adopted into a space is kept by the core, so a terminal lost with the core comes back as a shell in its last folder instead of disappearing.
Adoption is also one-way on the app's side: clearing the labels does not take the pane off the person's screen - the app owns that binding - which is why the reversal below has two steps.

### Reversal

The adapter's half clears both labels on one exact terminal:

```text
. bin/backends/herdr-core.sh
fm_backend_herdr_core_clear_presentation_space <session>:<address> [sq-<task-id>]
```

It runs the same identity check every other write runs - this base's `squad.base` label, this task's `squad.task` label, and the recorded core id - so it can only ever reach one of this base's own terminals, and it removes or relabels nothing else.
The equivalent by hand is `hc label <address> herdr.space= herdr.tab=`.

Clearing the labels is not enough to undo the presentation, so the reversal is completed in the app, which takes the pane away and disables core keep:

```text
herdr-app do terminal.park --terminal <address>
```

A task that is torn down needs neither step for its pane: a terminal that ends closes its pane.
Removing `config/herdr-core-space` stops new terminals from being labeled; terminals already created keep their labels until they are cleared that way.

## Commands this backend runs

Every command is addressed to one opaque terminal; `<s>` is the recorded session and `<t>` the recorded address.

| Why | Exact command |
| --- | --- |
| Is the core listening (before anything else) | a socket test on `${XDG_RUNTIME_DIR}/herdr-core/<s>.sock`, or `${XDG_STATE_HOME:-~/.local/state}/herdr-core/<s>/<s>.sock` when `XDG_RUNTIME_DIR` is unset or empty, or `$HC_SOCKET`, then a unix-socket connect by `python3`, `curl --http0.9 --unix-socket` or `nc -U -z` |
| Protocol handshake | `printf '{"jsonrpc":"2.0","id":1,"method":"hello","params":{"generation":1}}\n' \| hc connect` (bounded by `fm_run_timed`) |
| Method and parameter contract | `hc schema --json` |
| Core identity | `hc server status --json` (read only after the socket test) |
| Inventory for the duplicate check | `hc ls --json --label squad.task=<id> --label squad.base=<base>` (live terminals) |
| Inventory for a failed-create recovery | `hc ls --all --json --label squad.task=<id> --label squad.base=<base>` (live and finished) |
| One record read (every identity and state check) | `hc get --json <t>` |
| Screen and history | `hc read --json --lines <n> <t>` |
| Complete rendered viewport (busy hashing) | `hc read --json --lines 0 <t>`, accepted only when `.complete` is true, `.how` is `screen`, and the text is non-empty |
| Create a task terminal | `hc run --bg --json --no-parent --name <name> --cwd <project> --label squad.task=<id> --label squad.base=<base>` |
| Place the terminal in the configured desktop space, as its own tab | `hc label <t> herdr.space=<id> herdr.tab=sq-<base-hash>-<slug>` |
| Clear that placement (the app's `terminal.park` takes the pane away) | `hc label <t> herdr.space= herdr.tab=` |
| Deliver text | `hc send --json --if idle <t> <text>` (a program reporting `idle`), `hc send --json <t> <text>` (a program reporting `done`, or a silent one) |
| Press one named key | `hc keys --json <t> <key>` |
| Close | `hc kill --json <t>`, confirm `.state == finished`, then `hc rm --json <t>`, confirm `.removed == <t>` |

`<project>` is the project directory recorded for the task; the isolated worktree is entered later inside the terminal by the ordinary `fob get` sequence, exactly as on the other session-provider backends.

Not used, by design: `server stop`, `server restart`, `machine *`, `update`, `hc attach`, and every name-addressed write.

Create is the only step that makes a terminal, so it is also the only step that may have to undo one.
When `hc run` fails, or succeeds without a usable address, the adapter reads back the terminals carrying this task's `squad.task` label **and this base's** `squad.base` label - live and finished, because a failed run may already have run to completion - and closes exactly that address, after re-checking both of those labels on the address itself, before it refuses.
Both labels are checked because two bases on one core both number their tasks from 1: without the base scope, a second base's terminal would be refused as a duplicate or, worse, closed by this base's recovery.
The product documents that a failed `hc run` may still have run the program, so the alternative would be an unrecorded terminal that the next spawn then refuses as a duplicate endpoint.
Nothing outside those labels is touched, and a close that cannot be confirmed prints the exact address and the `hc kill`/`hc rm` commands to retire it by hand.

A relaunch makes a replacement terminal, so it first retires the exact address the task still records.
A task whose harness exited on its own leaves a live but agentless shell; a core restart leaves a `finished` record.
Both still carry this task's labels, so the relaunch closes that one address through the same identity-checked path before it creates the replacement: without it the live shell would refuse the replacement as a duplicate and the finished record would stay behind as an unmanaged terminal in the person's registry.
This retirement runs through the recorded backend before any new terminal exists, including when the relaunch resolves to a different backend: a task moved to `tmux` still closes its exact recorded herdr-core address rather than orphaning it on the shared core.
Only an endpoint that is confidently without an agent is retired - a read that is ambiguous or unreadable, or that still sees a live agent, refuses the relaunch rather than killing a program that may still be working.
Retirement runs only once the relaunch is no longer refusable, so a relaunch refused for any other reason - a released task, or an execution that cannot be requeued - leaves the recorded endpoint and its terminal exactly as they were.

## Address-exact operations only

Every write names one opaque address that Squad created:

- **No sweep.** `server stop`, `server restart`, `machine *`, and `update` are never called, and no destructive call ever takes `--all`. The only `--all` reads are the label-filtered failed-create inventory and the lab's tripwire; both are read-only, and the inventory authorizes nothing until the address's own `squad.task` and `squad.base` labels agree.
- **No name selectors.** A recorded address is used verbatim, and this adapter resolves no bare terminal name of its own; ad hoc use passes an exact `<session>:<address>` whose terminal carries this base's own two labels, because an unlabelled or foreign terminal is not one this base may read or close.
- **No foreign terminal.** `kill` and `rm` require the cleanup identity to agree, checked immediately before `kill` and again before `rm`:

  1. the recorded address,
  2. the terminal's own `squad.task=<id>` label **and** its own `squad.base=<base>` label - the task label alone is not unique across bases, so the base label is required on every close, and the caller's own base label is the one used when no explicit one is passed,
  3. the recorded `hc_core_id=` against the live core's identity.

  The same base label is required by every read and write this backend performs, so a recycled address that now carries another base's terminal is refused rather than projected or closed.
  A mismatch refuses and keeps the task metadata, so a later rerun can retry once the identity agrees. Teardown then confirms the exact address is authoritatively gone before it retires any record; a still-present address refuses the whole teardown.
  That confirmation is ownership-aware: a core recycles an address as soon as its terminal is closed, so a readable record at the recorded address is not proof that this task's endpoint is still there.
  The endpoint counts as gone when the core authoritatively lacks the address, and also when the record now carries another task's or another base's labels, or another core id - a stranger owns that address, so the terminal is never touched and the task's records may be retired.
  It refuses only while the record still carries this task's and this base's labels, or when the read cannot verify the identity at all (unreachable core, unreadable or inconsistent record), so a recycled address never wedges teardown and a transient failure never erases a record that still points at a live endpoint.
  A relaunch applies the same rule before it replaces an endpoint: it retires the exact address it still owns, and proceeds past an address the core no longer has or that a stranger now owns, without closing the stranger.
  Forced teardown of an XO closes each herdr-core child under that child home's own base label, because the child was spawned with `SQUAD_BASE` pointing at its home, and it retains the child record unless the exact address is confirmed gone.

One address belongs to one core's registry, so an address is only meaningful inside the core that issued it. The recorded core id and the recorded session are both re-checked, and a task whose recorded session or core no longer matches refuses every write rather than resolving against whatever is running.

The recorded identity is read from the task's own metadata file (`<task-id>.meta`), never by matching the recyclable `<session>:<address>` alone: two tasks can record the same address after a recycle, and resolving that by the address would hand one task the other's recorded core id and labels. A read that names no task and finds several recorded owners refuses as unverifiable instead of picking one.

`hc kill` ends the terminal's own program and its foreground job. A process a program deliberately detached can survive it, exactly as on every other backend; this is not a process-tree sweep.

## Delivery

Delivery types text and submits it in one product call, so the tmux-shaped retry loop has no counterpart here.

- A program that reports `idle` is sent with `--if idle`. The product itself refuses rather than typing over a running turn or into a blocked dialog.
- A program that reports `done` is sent once without `--if`: its turn finished and it is at rest, but the product's `--if` vocabulary has no `done`, so gating on `idle` would refuse every steer to it forever.
- A program reporting `working`, `error`, `blocked`, or any other reported state is refused before anything is typed - `working` because a steer must not land mid-turn, `blocked` and `error` because a person is needed first.
- A program that reports no status is sent once, without `--if`. Its composer is read first, and only positive evidence of unsent text (`pending`) refuses the send.

Verdicts reach `bin/sq-send.sh` unchanged:

| Verdict | Meaning |
| --- | --- |
| `empty` | The text was pasted and submitted. |
| `agent_blocked` | The program is blocked, so typing would answer its dialog. Nothing was typed. |
| `not_ready` | The program's own report says it is not at rest, or its composer positively holds unsent text. Nothing was typed. |
| `no_agent` | The core authoritatively reports the address finished or gone, or it carries another task's or base's label, or another core id. Nothing was typed. |
| `uncertain-delivery` | The call failed without a stable refusal kind, so bytes may have landed. Never retype; read the pane. |
| `send-failed` | A local failure before typing: an unreadable read, a core identity this process cannot verify, or no temporary file for the product's error envelope. Nothing was typed, and a transient read is never reported as an absent agent. |

Nothing is ever retyped. A send has one attempt, and the product owns its own draft settling (a person's unfinished draft holds a send for up to 60 seconds since their last key; nobody typing in a Squad terminal means the ordinary short quiet pause).

## State, prompts, and blocked escalation

`hc get` reports the program's own OSC 7501 status, and the adapter maps it without guessing:

| Native status | Squad busy state |
| --- | --- |
| `working` | `busy` |
| `blocked`, `error` | `blocked` (a person is needed) |
| `idle`, `done` | `idle` |
| absent (a program that reports nothing) | `unknown`, which falls back to the harness-scoped detection the other backends use |

The sentry hashes a complete rendered viewport to expire a busy claim and to compare pane signatures, so `fm_backend_capture_rendered` accepts `hc read --json --lines 0` only when the product's own envelope proves a complete screen read: `.complete` true, `.how` equal to `screen`, and non-empty text.
A history-shaped read, a partial read, an empty screen, a failed read, or a malformed record refuses and prints nothing, so static-busy expiry and the pane-signature check simply do not run for this backend rather than hashing unproven text.

A blocked report also carries the prompt the program wrote - `kind` and a decoded `msg` - so `bin/sq-crew-state.sh` renders `state: blocked ... harness waiting on a prompt (permission: Allow rm?)` without reading the screen.

The supervision producer is the sentry's ordinary poll (`fm_backend_herdr_core_poll_transition`), because native event push is a later unit.
One read per cycle is normalized into the shared transition record and routed through the shared policy table.
The dedupe identity of a blocked condition is the program's own `kind` and `msg`, not `status_ms`: measured live, two consecutive different prompts arrived with the same `status_ms`.
A read that cannot produce a prompt keeps the existing markers, so one transient failure cannot duplicate a wake, and a positively-read non-blocked status clears them so the next block wakes again.

Answering a blocked operator prompt is not implemented in this backend: `hc` has no answer bound to a prompt id, so an answer is keys typed after re-reading the blocked record, and Squad does not yet do that on herdr-core. A blocked task is surfaced to a person, who answers it in the terminal from the desktop app or the phone.

## Worktree acquisition

`fob get` runs inside the task's own terminal, and the spawn polls the terminal's foreground cwd until it settles on a non-project path, exactly as the tmux path does.
`hc` reports the foreground process group leader's cwd, so the shell that ran `fob get` is what the poll follows.
The recorded `worktree=` is the lease path, and the lab asserts the terminal's foreground cwd equals it.
The durable lease is returned at teardown, exactly as on every other session-provider backend.

## Harness note

`codex` must run with `--no-daemon` under herdr-core, or the commands it runs execute outside the terminal and disappear from its record.
`bin/sq-spawn.sh` applies that flag on this backend only, so every other backend's codex launch is unchanged.

## Composer and busy-state reads for other consumers

`fm_backend_composer_state` answers `unknown` for a reporting program, because `--if idle` replaces the question; for a silent program it reads the composer row and defers to the shared classifier in `bin/sq-composer-lib.sh`.
`fm_backend_target_exists` is a cheap read-only presence check that never starts a core.
`fm_backend_agent_state` reports `alive` for a verified harness, `dead` for a finished address or a live shell, `missing` for an absent address or a foreign identity, `ambiguous` for an unattributable program, and `unreadable` for a failed or contradictory read.

## Shared-core rules

The core serves the person's own terminals, the desktop app, and their phone.

- Never `kill`, `rm`, or restart anything Squad did not create.
- Every inventory is filtered by `squad.task` **and** `squad.base`, so a second Squad base on the same core is neither counted as a duplicate nor closed by this base's recovery. The base label carries a short hash of the physical base path, so two bases with the same directory name are still distinguished.
- The product's terminal name is base-scoped for the same reason: the name registry is core-global, so `sq-<base-hash>-<task-id>` keeps task `1` in two bases from colliding on `name_taken`.
- Never a `--all` sweep, a server-global verb, or a name selector on a destructive call.
- Never change the person's app settings, telemetry, or core configuration.
- The adapter only writes its own labels, and only on terminals it created: the two Squad identity labels, plus the optional `herdr.space`/`herdr.tab` placement from `config/herdr-core-space`.
- Mobile access is SSH into this machine: anyone holding that key can type into Squad's operators. That is a person-side security decision, not something Squad can bound.

## Recovery when the core is absent

1. Start the core - open the desktop app, or run `hc server start` in a normal terminal. Squad will not do it.
2. Re-run the operation (`bin/sq-spawn.sh`, `bin/sq-send.sh`, `bin/sq-peek.sh`, `bin/sq-crew-state.sh`).
3. A task whose terminal was lost (`reason: holder_lost`, or `finished` after the core came back) is closed by a normal `bin/sq-teardown.sh <id>`, which closes the exact recorded address when it still exists and confirms its absence otherwise.

If the core reports a protocol generation, version, method, or parameter this adapter does not support, the operation refuses by name. Upgrade `hc`, or choose another backend for that task; do not lower the guard.

## Lab

`SQUAD_HC_LAB=1 bin/sq-herdr-core-lab.sh` drives a real spawn, send, peek, crew-state, and teardown against a **private** core created by the lab itself, then proves the commander's default core is byte-identical afterwards.
Before any tripwire read it runs the adapter's own unix-socket listener probe against the ambient `default` socket, so a socket file left behind by a dead core is a hard stop rather than the call that starts a core with the lab's environment.
It is the only supported way to exercise this backend on a real core, and it never mutates the shared one.
