# Squad test isolation proof

This record is the concurrent isolation proof for the portable parallel candidate set.
`bin/sq-test-isolation-proof.sh` is the authoritative harness and `docs/sq-test-isolation-proof.json` is the machine-readable result.
`bin/sq-test-run.sh` owns the production lane partition.

## Verification

- Date: 2026-11-03
- Command: `unshare -m --map-root-user` around `bin/sq-test-isolation-proof.sh --jobs 4 --json docs/sq-test-isolation-proof.json`, with `/usr/bin/herdr` hidden by an overlay mount of `/usr/bin`
- Result: `SQUAD_ISOLATION_SUMMARY total=23 failed=0 concurrency=4 duration_ms=160325`

| Field | Value |
|---|---|
| `run_id` | `sq-isolation-1793699744983-4020941` |
| `started_at` | `2026-11-03T09:55:44Z` |
| `finished_at` | `2026-11-03T09:58:25Z` |
| concurrency | 4 |
| candidates | 23 |
| failed | 0 |
| wall duration | 160325 ms |

Every candidate passed, which needs a `herdr`-free `PATH`: `tests/sq-backend-herdr.test.sh` owns a herdr-absent refusal case that cannot pass while the binary is installed.
This run therefore hid `/usr/bin/herdr` behind a `/usr/bin` overlay mount in a private mount namespace (`unshare -m --map-root-user`).
Masking the binary with `/dev/null` is not equivalent, because the adapter then reports a permission failure instead of an absent CLI.
The durations are wall-clock on a shared developer machine, so read them as conservative upper bounds rather than a quiet-machine baseline.

## Candidate set

- `tests/sq-arm-pretool-check.test.sh`
- `tests/sq-backend-herdr.test.sh`
- `tests/sq-brief.test.sh`
- `tests/sq-cd-pretool-check.test.sh`
- `tests/sq-composer-ghost.test.sh`
- `tests/sq-composer-lib.test.sh`
- `tests/sq-crew-state.test.sh`
- `tests/sq-decision-hold-lifecycle.test.sh`
- `tests/sq-ensure-agents-md.test.sh`
- `tests/sq-grok-harness.test.sh`
- `tests/sq-herdr-lab.test.sh`
- `tests/sq-lint.test.sh`
- `tests/sq-pi-primary-types.test.sh`
- `tests/sq-pr-merge.test.sh`
- `tests/sq-review-diff.test.sh`
- `tests/sq-send-popup-settle.test.sh`
- `tests/sq-send-settle.test.sh`
- `tests/sq-send-strict.test.sh`
- `tests/sq-spawn-batch.test.sh`
- `tests/sq-supervision-instructions.test.sh`
- `tests/sq-test-run.test.sh`
- `tests/sq-tmux-submit-busy.test.sh`
- `tests/sq-transition-lib.test.sh`

## Durations

| duration_ms | exit | worker | script |
|---:|---:|---:|---|
| 56122 | 0 | 8 | `tests/sq-decision-hold-lifecycle.test.sh` |
| 51141 | 0 | 1 | `tests/sq-arm-pretool-check.test.sh` |
| 34945 | 0 | 21 | `tests/sq-test-run.test.sh` |
| 32255 | 0 | 2 | `tests/sq-backend-herdr.test.sh` |
| 29727 | 0 | 4 | `tests/sq-cd-pretool-check.test.sh` |
| 28431 | 0 | 19 | `tests/sq-spawn-batch.test.sh` |
| 25426 | 0 | 7 | `tests/sq-crew-state.test.sh` |
| 14717 | 0 | 14 | `tests/sq-pr-merge.test.sh` |
| 11922 | 0 | 12 | `tests/sq-lint.test.sh` |
| 9606 | 0 | 3 | `tests/sq-brief.test.sh` |
| 9487 | 0 | 11 | `tests/sq-herdr-lab.test.sh` |
| 7930 | 0 | 10 | `tests/sq-grok-harness.test.sh` |
| 5753 | 0 | 17 | `tests/sq-send-settle.test.sh` |
| 2724 | 0 | 5 | `tests/sq-composer-ghost.test.sh` |
| 2402 | 0 | 16 | `tests/sq-send-popup-settle.test.sh` |
| 2143 | 0 | 18 | `tests/sq-send-strict.test.sh` |
| 2032 | 0 | 15 | `tests/sq-review-diff.test.sh` |
| 1750 | 0 | 22 | `tests/sq-tmux-submit-busy.test.sh` |
| 331 | 0 | 9 | `tests/sq-ensure-agents-md.test.sh` |
| 250 | 0 | 20 | `tests/sq-supervision-instructions.test.sh` |
| 153 | 0 | 23 | `tests/sq-transition-lib.test.sh` |
| 128 | 0 | 6 | `tests/sq-composer-lib.test.sh` |
| 28 | 0 | 13 | `tests/sq-pi-primary-types.test.sh` |

## Scope

Each worker used a separate mode-`0700` temporary root and private `TMPDIR` and `TMP`.
The harness cleared ambient `SQUAD_BASE`, legacy `SQUAD_HOME`, and `SQUAD_*_OVERRIDE` values for every worker and verified that global Git configuration was unchanged.
A candidate failure fails the aggregate run and requires investigation rather than a retry.

## Re-run

```sh
bin/sq-test-isolation-proof.sh --list
bin/sq-test-isolation-proof.sh --jobs 4 --json /tmp/sq-isolation-proof.json
bin/sq-test-run.sh --check-coverage
```
