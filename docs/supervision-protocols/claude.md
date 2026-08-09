Mode: Claude Stop-hook-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/sq-stand-to-drain.sh`.
2. Routine sentry arm and re-arm are owned by the Stop `asyncRewake` hook (`bin/sq-claude-stop-autoarm.sh`), never by you.
   Every turn end while supervision is needed launches or attaches one home-scoped sentry cycle with no model command and no model tokens.
   An actionable close wakes you through the hook's exit-2 rewake, delivered as a `Stop hook feedback` message.
3. On a `Stop hook feedback` wake (`signal:`, `stale:`, `check:`, or `heartbeat`), run `bin/sq-stand-to-drain.sh` first and handle the wake.
   Do not run `bin/sq-sentry-arm.sh` after an ordinary wake; the next turn end re-arms automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records, the drain's `OPEN DECISIONS` entries, or a real sentry reason line.
4. On the one `Stop hook feedback` automatic-mechanism failure notice (`Squad sentry auto-arm FAILED ...`), drain, inspect the automatic mechanism failure, and do not turn the notice into a repeating manual-arm loop.
5. If the Stop hook does not claim the home or reports an exhausted failure, inspect its registration and sentry startup path before ending blind.
   Keep the Stop-owned automatic mechanism as the only Claude arm owner.
6. Treat `sentry: started ...` and `sentry: attached ...` inside automatic arm output as proof that one live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
7. The durable stand-to queue preserves actionable events between a rewake and the next Stop-launched arm, while the bounded turn-end guard prevents a blind Stop when recovery did not start.
   No PreToolUse hook denies unit commands based on sentry status.
   [`sentry-continuity.md`](../sentry-continuity.md) owns the exact session-lock recovery boundary.
8. The turn-end guard (`bin/sq-turnend-guard.sh --claude`) remains the final backstop.
   It requires the PID-strict live-sentry and fresh-beacon predicate at the Stop boundary, while the mid-turn pull guard accepts a fresh beacon without a live process under Claude's between-turns auto-arm model.
   It allows the stop when a sentry is healthy or the role-verified auto-arm owns recovery, while fresh failure epochs advance the bounded one-time attended fail-open progression described in [`turnend-guard.md`](../turnend-guard.md).
9. Waiting on the hook-owned cycle is silent: do not send idle progress while the sentry is parked.

The sentry itself remains `bin/sq-sentry.sh`, and `bin/sq-sentry-arm.sh` remains the verified arm wrapper that the Stop hook foregrounds.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`sentry-continuity.md`](../sentry-continuity.md) for the arm-layer successor and clean-close failure contract and the Claude ownership model.
