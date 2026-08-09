# Squad test isolation proof

This record is the concurrent isolation proof for the portable parallel candidate set.
`bin/sq-test-isolation-proof.sh` is the authoritative harness and `docs/sq-test-isolation-proof.json` is the machine-readable result.
`bin/sq-test-run.sh` owns the production lane partition.

## Verification

- Date: 2026-07-29
- Command: `bin/sq-test-isolation-proof.sh --jobs 4 --json /tmp/sq-source-content-test-cleanup-r1-isolation.json`
- Result: `SQUAD_ISOLATION_SUMMARY total=24 failed=0 concurrency=4 duration_ms=149010`

| Field | Value |
|---|---|
| `run_id` | `sq-isolation-1785367157179-18165` |
| `started_at` | `2026-07-29T23:19:17Z` |
| `finished_at` | `2026-07-29T23:21:46Z` |
| concurrency | 4 |
| candidates | 24 |
| failed | 0 |
| wall duration | 149010 ms |

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
- `tests/sq-x-mode.test.sh`

## Durations

| duration_ms | exit | worker | script |
|---:|---:|---:|---|
| 52939 | 0 | 24 | `tests/sq-x-mode.test.sh` |
| 48294 | 0 | 2 | `tests/sq-backend-herdr.test.sh` |
| 46788 | 0 | 1 | `tests/sq-arm-pretool-check.test.sh` |
| 34207 | 0 | 4 | `tests/sq-cd-pretool-check.test.sh` |
| 30771 | 0 | 8 | `tests/sq-decision-hold-lifecycle.test.sh` |
| 25365 | 0 | 7 | `tests/sq-crew-state.test.sh` |
| 15674 | 0 | 21 | `tests/sq-test-run.test.sh` |
| 15422 | 0 | 11 | `tests/sq-herdr-lab.test.sh` |
| 9065 | 0 | 5 | `tests/sq-composer-ghost.test.sh` |
| 8564 | 0 | 14 | `tests/sq-pr-merge.test.sh` |
| 6251 | 0 | 10 | `tests/sq-grok-harness.test.sh` |
| 5644 | 0 | 16 | `tests/sq-send-popup-settle.test.sh` |
| 5237 | 0 | 12 | `tests/sq-lint.test.sh` |
| 4816 | 0 | 22 | `tests/sq-tmux-submit-busy.test.sh` |
| 2945 | 0 | 13 | `tests/sq-pi-primary-types.test.sh` |
| 2911 | 0 | 17 | `tests/sq-send-settle.test.sh` |
| 2875 | 0 | 15 | `tests/sq-review-diff.test.sh` |
| 2747 | 0 | 18 | `tests/sq-send-strict.test.sh` |
| 2224 | 0 | 3 | `tests/sq-brief.test.sh` |
| 855 | 0 | 19 | `tests/sq-spawn-batch.test.sh` |
| 703 | 0 | 20 | `tests/sq-supervision-instructions.test.sh` |
| 581 | 0 | 9 | `tests/sq-ensure-agents-md.test.sh` |
| 248 | 0 | 23 | `tests/sq-transition-lib.test.sh` |
| 64 | 0 | 6 | `tests/sq-composer-lib.test.sh` |

## Scope

Each worker used a separate mode-`0700` temporary root and private `TMPDIR` and `TMP`.
The harness cleared ambient `SQUAD_HOME` and `SQUAD_*_OVERRIDE` values for every worker and verified that global Git configuration was unchanged.
A candidate failure fails the aggregate run and requires investigation rather than a retry.

## Re-run

```sh
bin/sq-test-isolation-proof.sh --list
bin/sq-test-isolation-proof.sh --jobs 4 --json /tmp/sq-isolation-proof.json
bin/sq-test-run.sh --check-coverage
```
