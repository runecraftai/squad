# Away-mode supervision: durable artifacts and external calls

Inventory of what the away-mode lifecycle writes and what it calls outward,
measured against the tree as of the `sq/squad-supervisor-implementation` branch.
It exists so the state-owner steps of the
[`squad-supervision-out-of-shell`](../data/squad-supervision-out-of-shell/report.md)
migration convert every writer and every call, rather than the ones that were
easy to find.

Line references are the ones this inventory was measured on. Re-measure them
before changing the code they point at; a stale reference is a wrong reference.

## Durable artifacts

`STATE` is the base's `state/` directory.

| Artifact | Writer | Reader | Mutation | Loss class it can cause |
| --- | --- | --- | --- | --- |
| `$STATE/.subsuper-routine` | `ledger_add` in `bin/sq-supervise-daemon.sh:846` via `routine_add` | `bin/sq-afk-return.sh:270` | append, no cap, no deduplication outside the retained rows searched at `:872` | L2: unbounded repetition crowds out the real notice; the summary counts the retained window, not the absence |
| `$STATE/.subsuper-escalations` | the same `ledger_add` with class `escalation` | `bin/sq-afk-return.sh:271`, the max-defer check at `bin/sq-supervise-daemon.sh:1261` | append, no cap | L2, and a slow fold makes the max-defer notice late |
| `$STATE/.subsuper-escalations.since` | `bin/sq-supervise-daemon.sh:853` | the max-defer check | created once when the buffer is empty | none alone; it is the age anchor for the buffer |
| `$STATE/.subsuper-parked-notified` | `bin/sq-supervise-daemon.sh` | `bin/sq-afk-return.sh:229` | append/truncate | L2 if it is cleared without the notice reaching the summary |
| `$STATE/.subsuper-inject-wedged` | `bin/sq-supervise-daemon.sh` | `bin/sq-afk-return.sh:266` | append/truncate | L2: a drained record and a marker line can describe the same notice, which the summary has to reconcile by identity |
| `$STATE/.stand-to-queue` | `fm_wake_append` in `bin/sq-stand-to-lib.sh:522`, under `$SQUAD_WAKE_QUEUE_LOCK` (`:9`) | `bin/sq-stand-to-drain.sh` | append; the drain swaps it for an empty file at `:186` | L1 and L3: transport success is not durable consumer acknowledgement, and batch identity is a path prefix rather than an owned UUID |
| `$STATE/.stand-to-queue.drain.<pid>` | `bin/sq-stand-to-drain.sh:185` | nothing | created, printed, then deleted at `:205` | L1: a drain killed between the swap and the delete leaves the only copy of the batch in a file no code reads |
| `$STATE/.afk-return-catchup` | `write_pending_seed` at `bin/sq-afk-return.sh:79`, `write_gate` at `:99` | `return_guard`, `print_blockers` | whole-file replace from a temp file | none by itself; the phase is written before the mutation it describes |
| `$STATE/.afk` | `bin/sq-afk-start.sh:139`, `bin/sq-afk-launch.sh:219` | every away-mode reader | create, and removal only at the end of a stop (`bin/sq-afk-launch.sh:898`) | L2 if cleared before the daemon's shutdown flush |
| `$STATE/<id>.status` | operators and Squad, never the daemon | `scan_open_blockers`, `sq-classify-lib.sh` | append-only by contract | L4: an append during the final fold is invisible to a fold that accepted an older size |

## External calls in the away lifecycle

"Bounded" means a deadline the caller can rely on. "Contained" means the
operation's descendants cannot escape the bound by changing session or process
group. Both columns describe this branch, not the intended end state.

| Call site | Bounded | Contained | Note |
| --- | --- | --- | --- |
| `bin/sq-afk-launch.sh:301` herdr pane close | no | no | a forked helper can hold the caller open |
| `bin/sq-afk-launch.sh:311` tuios `kill-session` | no | no | same |
| `bin/sq-afk-launch.sh:334`, `:433` herdr pane get | no | no | a census probe that hangs blocks the stop decision entirely |
| `bin/sq-afk-launch.sh:485`, `:496` herdr workspace/pane list | no | no | feeds the live census |
| `bin/sq-afk-launch.sh:604`, `:634` herdr workspace create, pane run | no | no | launch side |
| `bin/sq-afk-launch.sh:977` daemon SIGTERM then a 100x0.25s poll | partially | no | the poll is bounded; the preflight queries before it are not |
| `bin/sq-supervise-daemon.sh:1801` cleanup `wait "$WATCHER_PID"` | no | no | waits for a direct child only; it is not proof that the tree is gone |
| `bin/sq-afk-return.sh:255` `sq-stand-to-drain.sh` | no | no | the drain consumes the queue; a bound without a batch-recovery owner would convert a hang into a loss |
| `bin/sq-afk-return.sh:181` summary formatting | no | not applicable | spawns `sed`, `sort`, `grep` per row |
| `bin/sq-backend.sh` and `bin/backends/*.sh` | per call site | no | the shared adapters every backend operation goes through |

## What this change does and does not do

`bin/sq-op-contain.sh` and `packages/sq-supervisor` are the containment owner.
`bin/sq-timeout-lib.sh` is the single seam for bounded execution, and with
`SQUAD_OP_CONTAINMENT=systemd` every existing `fm_run_timed` call site gains both
a deadline and a kernel-owned containment domain without a call-site change: the
operation runs in the caller's working directory, with the caller's environment,
and with its stdout and stderr relayed, so a per-command assignment, a `$(...)`
capture and a stderr read all keep working. `fm_run_timed` still answers with the
command's own status or 124; the richer outcomes are `fm_run_contained`'s own
contract. A user manager older than systemd 254 cannot disable argument
expansion, so on those hosts `$` text inside a command's own arguments is
expanded before the command sees it; newer managers get
`--expand-environment=no`.

That covers the rows in the second table that go through `fm_run_timed`. It does
not cover the away-lifecycle rows above, because those calls are unbounded today
and adding a deadline to them is only safe once the batch and gate have an owner
that can recover what a deadline interrupts. That owner is recon steps 2 to 5.
