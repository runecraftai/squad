# Squad portable test shards

`bin/sq-test-run.sh` owns portable lane composition and execution.
`bin/sq-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-11-03 concurrent proof recorded in [sq-test-isolation-proof.md](sq-test-isolation-proof.md).
The proof ran 23 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 56122 | `tests/sq-decision-hold-lifecycle.test.sh` |
| 51141 | `tests/sq-arm-pretool-check.test.sh` |
| 34945 | `tests/sq-test-run.test.sh` |
| 32255 | `tests/sq-backend-herdr.test.sh` |
| 29727 | `tests/sq-cd-pretool-check.test.sh` |
| 28431 | `tests/sq-spawn-batch.test.sh` |
| 25426 | `tests/sq-crew-state.test.sh` |
| 14717 | `tests/sq-pr-merge.test.sh` |
| 11922 | `tests/sq-lint.test.sh` |
| 9606 | `tests/sq-brief.test.sh` |
| 9487 | `tests/sq-herdr-lab.test.sh` |
| 7930 | `tests/sq-grok-harness.test.sh` |
| 5753 | `tests/sq-send-settle.test.sh` |
| 2724 | `tests/sq-composer-ghost.test.sh` |
| 2402 | `tests/sq-send-popup-settle.test.sh` |
| 2143 | `tests/sq-send-strict.test.sh` |
| 2032 | `tests/sq-review-diff.test.sh` |
| 1750 | `tests/sq-tmux-submit-busy.test.sh` |
| 331 | `tests/sq-ensure-agents-md.test.sh` |
| 250 | `tests/sq-supervision-instructions.test.sh` |
| 153 | `tests/sq-transition-lib.test.sh` |
| 128 | `tests/sq-composer-lib.test.sh` |
| 28 | `tests/sq-pi-primary-types.test.sh` |

## Parallel lanes

Both parallel lanes hold a fixed partition of that proven set, so a lane's estimate is the sum of its measured scripts rather than a freshly re-balanced longest-processing-time split.
The table below records the sums of the current memberships.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 10 | 155189 ms (~155.2 s) |
| `portable-parallel-2` | 13 | 174214 ms (~174.2 s) |
| imbalance | | 19025 ms (~19.0 s) |

`bin/sq-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps sentry, lock, AFK, real tmux, daemon, XO lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On a green CI run of the inherited suite, that remainder accumulated about 19 minutes of script time against a 20-minute job timeout (measured on the fork's CI; the Squad repository re-measures its own shard durations at M4).
The serial remainder can approach the job timeout, which is exactly why the split below exists.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/sq-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/sq-test-run.sh`.
The hints came from that run's `sq-test-timing-portable-serial` artifact on 2026-08-02, where the lane ran 69 scripts in 1143762 ms of serial work.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of4` | 15 | 285945 ms (~285.9 s) |
| `portable-serial-2of4` | 18 | 285944 ms (~285.9 s) |
| `portable-serial-3of4` | 17 | 285929 ms (~285.9 s) |
| `portable-serial-4of4` | 19 | 285944 ms (~285.9 s) |
| imbalance | | 16 ms |

The single longest script, `tests/sq-pr-check-security.test.sh` at 199573 ms, is the floor for any shard count.

Refresh the hints by downloading the per-shard timing artifacts from a green CI run, replacing the `portable_serial_weight_hints` table in `bin/sq-test-run.sh` with the measured `path`/`duration_ms` pairs, and updating the table above:

```sh
gh run download <run-id> -R runecraftai/squad --pattern 'sq-test-timing-portable-serial-*' -D /tmp/sq-serial  # OQ-03 placeholder
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/sq-serial/*.json | LC_ALL=C sort
bin/sq-test-run.sh --check-coverage
```

## Coverage guard

`bin/sq-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/sq-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/sq-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-4 | 15 | Each balanced shard is about five minutes, leaving roughly 3x hang-tripwire margin. |
| Herdr | 40 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
