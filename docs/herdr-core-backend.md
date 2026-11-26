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

```text
error: herdr-core is not running for session 'default' (no core listening at /run/user/1000/herdr-core/default.sock); Squad never starts the core - start Herdr or run 'hc server start' yourself
```

A socket file alone is not a core: after an unclean core death the file survives while nothing accepts on it, and the next `hc` call would start a core with Squad's environment.
The listener probe is a unix-socket connect by a client that cannot start anything - `python3`, then `curl --unix-socket`, then `nc -U -z` - so a stale socket refuses exactly like an absent one, and when none of those clients can prove it the adapter fails closed and names what to install.
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
The base label is the readable base directory name plus a short hash of the physical resolved base path, for example `squad-1a2b3c4d`, so two bases whose directory name matches (the ordinary `squad` clone name) never share one label.
The terminal name is `sq-<task-id>` for a clean short task id that carries no `sq-` prefix.
Every other id - a longer one, an already-prefixed one such as `sq-demo`, or one whose sanitized slug differs from it - is truncated and disambiguated by a hash of the full id, so two task ids never share one name and every name fits the product's 32-character limit of a-z 0-9 - _.

## Commands this backend runs

Every command is addressed to one opaque terminal; `<s>` is the recorded session and `<t>` the recorded address.

| Why | Exact command |
| --- | --- |
| Is the core listening (before anything else) | a socket test on `$XDG_RUNTIME_DIR/herdr-core/<s>.sock`, or `$HC_SOCKET`, then a unix-socket connect by `python3`, `curl --unix-socket` or `nc -U -z` |
| Protocol handshake | `printf '{"jsonrpc":"2.0","id":1,"method":"hello","params":{"generation":1}}\n' \| hc connect` (bounded by `fm_run_timed`) |
| Method and parameter contract | `hc schema --json` |
| Core identity | `hc server status --json` (read only after the socket test) |
| Inventory for the duplicate check | `hc ls --json --label squad.task=<id> --label squad.base=<base>` (live terminals) |
| Inventory for a failed-create recovery | `hc ls --all --json --label squad.task=<id> --label squad.base=<base>` (live and finished) |
| One record read (every identity and state check) | `hc get --json <t>` |
| Screen and history | `hc read --json --lines <n> <t>` |
| Complete rendered viewport (busy hashing) | `hc read --json --lines 0 <t>`, accepted only when `.complete` is true, `.how` is `screen`, and the text is non-empty |
| Create a task terminal | `hc run --bg --json --no-parent --name <name> --cwd <project> --label squad.task=<id> --label squad.base=<base>` |
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
Only an endpoint that is confidently without an agent is retired - a read that is ambiguous or unreadable, or that still sees a live agent, refuses the relaunch rather than killing a program that may still be working.

## Address-exact operations only

Every write names one opaque address that Squad created:

- **No sweep.** `server stop`, `server restart`, `machine *`, and `update` are never called, and no destructive call ever takes `--all`. The only `--all` reads are the label-filtered failed-create inventory and the lab's tripwire; both are read-only, and the inventory authorizes nothing until the address's own `squad.task` and `squad.base` labels agree.
- **No name selectors.** A recorded address is used verbatim, and this adapter resolves no bare terminal name of its own; ad hoc use passes an exact `<session>:<address>`.
- **No foreign terminal.** `kill` and `rm` require the cleanup identity triple to agree, checked immediately before `kill` and again before `rm`:

  1. the recorded address,
  2. the terminal's own `squad.task=<id>` label (plus `squad.base=<base>` on the failed-create recovery, which has no task record to fall back on),
  3. the recorded `hc_core_id=` against the live core's identity.

  A mismatch refuses and keeps the task metadata, so a later rerun can retry once the identity agrees. Teardown then confirms the exact address is authoritatively gone before it retires any record; a still-present address refuses the whole teardown.

One address belongs to one core's registry, so an address is only meaningful inside the core that issued it. The recorded core id and the recorded session are both re-checked, and a task whose recorded session or core no longer matches refuses every write rather than resolving against whatever is running.

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
| `no_agent` | The core authoritatively reports the address finished or gone, or it carries another task's label. Nothing was typed. |
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
`fm_backend_agent_state` reports `alive` for a verified harness, `dead` for a finished address or a live shell, `missing` for an absent address or a foreign task label, `ambiguous` for an unattributable program, and `unreadable` for a failed or contradictory read.

## Shared-core rules

The core serves the person's own terminals, the desktop app, and their phone.

- Never `kill`, `rm`, or restart anything Squad did not create.
- Every inventory is filtered by `squad.task` **and** `squad.base`, so a second Squad base on the same core is neither counted as a duplicate nor closed by this base's recovery. The base label carries a short hash of the physical base path, so two bases with the same directory name are still distinguished.
- Never a `--all` sweep, a server-global verb, or a name selector on a destructive call.
- Never change the person's app settings, telemetry, or core configuration.
- The adapter only writes the two Squad labels it owns, on terminals it created.
- Mobile access is SSH into this machine: anyone holding that key can type into Squad's operators. That is a person-side security decision, not something Squad can bound.

## Recovery when the core is absent

1. Start the core - open the desktop app, or run `hc server start` in a normal terminal. Squad will not do it.
2. Re-run the operation (`bin/sq-spawn.sh`, `bin/sq-send.sh`, `bin/sq-peek.sh`, `bin/sq-crew-state.sh`).
3. A task whose terminal was lost (`reason: holder_lost`, or `finished` after the core came back) is closed by a normal `bin/sq-teardown.sh <id>`, which closes the exact recorded address when it still exists and confirms its absence otherwise.

If the core reports a protocol generation, version, method, or parameter this adapter does not support, the operation refuses by name. Upgrade `hc`, or choose another backend for that task; do not lower the guard.

## Lab

`SQUAD_HC_LAB=1 bin/sq-herdr-core-lab.sh` drives a real spawn, send, peek, crew-state, and teardown against a **private** core created by the lab itself, then proves the commander's default core is byte-identical afterwards.
It is the only supported way to exercise this backend on a real core, and it never addresses the shared one.
