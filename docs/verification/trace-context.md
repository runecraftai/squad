# Trace-context propagation verification

Repeatable evidence for the default-off native W3C trace-context capability.
Current behavior and rationale are owned by [`../trace-context.md`](../trace-context.md) and the configuration schema by [`../configuration.md`](../configuration.md) ("Trace context propagation"); this page records evidence only.

Date: 2026-08-03.
Shell: GNU bash 3.2.57 (macOS).
Comparison base: `main` at `976d97f`.

The colocated unit suite `tests/sq-trace-context-lib.test.sh` (26 assertions) exercises validation (valid accepted; malformed, wrong-length, uppercase, all-zero, `ff` version, and shell-metacharacter values rejected), root minting with every mint a distinct sampled root and no parent-adoption input, the recovery reuse path with the recorded carrier winning over the ambient environment, default-off omission, the enable precedence of `SQUAD_TRACE_CONTEXT` over `config/trace-context` with unset or empty deferring to the file, normalized home-session state, atomic replacement of a read-only prior record, stale-session rejection after failed publication, missing or invalid state defaulting off, the XO home-session boundary with later file state plus the per-task trace boundary (two resolves under one persistent ambient `TRACEPARENT` root two distinct traces and adopt neither), forced entropy failure omitting safely, and the minted-root fixed-shape check.

The spawn-path integration suite `tests/sq-trace-context-spawn.test.sh` (12 assertions), hermetic against an ambient `SQUAD_TRACE_CONTEXT`, drives `bin/sq-spawn.sh` end to end with a fake tmux pane and a real isolated git worktree: enabled, one resolved carrier is recorded as `traceparent=` in the meta only after the identical `TRACEPARENT` export is sent before the launch literal; disabled, neither is written nor sent (only `GOTMPDIR` is); a failed carrier delivery leaves no `traceparent=` claim while the source task still launches; an unsafe delivery whose partial input cannot be cleared stops before appending the launch command; a failed metadata append removes the carrier from the launched task without aborting it; duplicate XO preflight leaves inherited trace configuration unchanged; a relaunch reuses the recorded carrier verbatim; and spawns ignore later config and environment edits in favor of the frozen home-session decision.
The per-task boundary regression models the reviewed XO scenario exactly: two unrelated tasks spawned sequentially from one home while the same fixed `TRACEPARENT` sits in the spawning environment (a persistent XO's launch-time carrier) record and inject valid carriers whose trace ids differ from each other and from the ambient carrier, and a relaunch of the first task reuses its original carrier verbatim for both the meta record and the injected export.
Two further assertions drive a genuine two-level primary -> XO -> worker chain, running `bin/sq-spawn.sh` twice with the exact environment the primary injects into the XO, and prove the primary's effective override governs the nested worker both ways: env-on with no config file keeps the nested worker enabled while it roots its own per-task trace distinct from the XO's carrier, and env-off with the file present keeps the nested worker disabled even though the `config/trace-context` file was copied into the XO home.
A final assertion drives the file-decided path (`SQUAD_TRACE_CONTEXT` unset) and proves the XO's recorded/injected carrier and its delivered `SQUAD_TRACE_CONTEXT=on|off` snapshot are always derived from one frozen decision, so a carrier is never paired with the opposite enable state.
The suite touches no real harness or live unit.
`tests/sq-session-start.test.sh` additionally proves only a lock-owning session start writes the effective state and a lock-refused read-only start leaves it unchanged.

The remote-route suite `tests/sq-remote-XO-trace-context.test.sh` (6 assertions) covers the XO path that never reaches the local export site, driving the real chain - the parent's `bin/sq-spawn.sh`, `bin/sq-on.sh`, the real remote entrypoint, `bin/sq-remote-xo-control.sh`, and the remote host's own `bin/sq-spawn.sh` - over the deterministic SSH boundary with a stateful fake Herdr CLI, the backend a remote second mate always runs on, so the carrier the remote pane receives is read back from that pane's own log: disabled, the parent records no `traceparent=`, the remote pane receives no export, the remote home inherits no enablement flag, and the delivered snapshot is `SQUAD_TRACE_CONTEXT=off` while `GOTMPDIR` still ships; enabled, the parent's recorded carrier, the remote endpoint's own record, and the exported pane value are one identical valid carrier sent after `GOTMPDIR` and before the launch command, with `SQUAD_TRACE_CONTEXT=on` and the inherited flag delivered; a relaunch keeps that carrier verbatim in both the parent record and the pane export; a second remote route resolved from an environment holding a fixed ambient `TRACEPARENT` roots a trace id distinct from both that ambient carrier and the first route; the remote receiver accepts `config/trace-context` as ordinary declared inherited material while refusing `config/xo-harness`, which the primary deliberately does not propagate; and the delivery argument that carries a parent's carrier to a remote host is refused on a ship spawn, on a shell-metacharacter value, on an all-zero trace id, and on an empty value, so nothing but a strict W3C carrier on an XO launch can reach a pane export.

```console
$ bash tests/sq-trace-context-lib.test.sh | tail -1
# sq-trace-context-lib.test.sh: all assertions passed
$ bash tests/sq-trace-context-spawn.test.sh | tail -1
# all sq-trace-context-spawn tests passed
$ bash tests/sq-remote-XO-trace-context.test.sh | tail -1
ALL TESTS PASSED
```

Run all three trace-context suites from the repo root; each prints one `ok - ...` per assertion.
A single live-backend end-to-end check - a real spawn confirming the pane received the `TRACEPARENT` export before the launch line, with nothing left after teardown - is a bounded manual step, deferred here because a live agent spawn disrupts a running unit.
