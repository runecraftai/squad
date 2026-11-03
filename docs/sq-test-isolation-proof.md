# Squad test isolation proof

This record is the concurrent isolation proof for the portable parallel candidate set.
`bin/sq-test-isolation-proof.sh` is the authoritative harness and `docs/sq-test-isolation-proof.json` is the machine-readable result.
`bin/sq-test-run.sh` owns the production lane partition.

## Verification

- Date: 2026-11-03
- Command: `bin/sq-test-isolation-proof.sh --jobs 4 --json docs/sq-test-isolation-proof.json`
- Result: `SQUAD_ISOLATION_SUMMARY total=23 failed=1 concurrency=4 duration_ms=100049`

| Field | Value |
|---|---|
| `run_id` | `sq-isolation-1793669267812-3667561` |
| `started_at` | `2026-11-03T01:27:47Z` |
| `finished_at` | `2026-11-03T01:29:27Z` |
| concurrency | 4 |
| candidates | 23 |
| failed | 1 |
| wall duration | 100049 ms |

The single failure is `tests/sq-backend-herdr.test.sh`, whose herdr-absent refusal case cannot pass on a host that has `herdr` on `PATH` (the recording host had `/usr/bin/herdr 0.9.1`); every other candidate passed.

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
| 43689 | 0 | 1 | `tests/sq-arm-pretool-check.test.sh` |
| 31331 | 0 | 8 | `tests/sq-decision-hold-lifecycle.test.sh` |
| 18245 | 0 | 4 | `tests/sq-cd-pretool-check.test.sh` |
| 18231 | 0 | 21 | `tests/sq-test-run.test.sh` |
| 16854 | 0 | 7 | `tests/sq-crew-state.test.sh` |
| 15733 | 0 | 3 | `tests/sq-brief.test.sh` |
| 11633 | 0 | 10 | `tests/sq-grok-harness.test.sh` |
| 6568 | 0 | 14 | `tests/sq-pr-merge.test.sh` |
| 6404 | 0 | 11 | `tests/sq-herdr-lab.test.sh` |
| 4709 | 0 | 17 | `tests/sq-send-settle.test.sh` |
| 1706 | 0 | 5 | `tests/sq-composer-ghost.test.sh` |
| 1450 | 0 | 12 | `tests/sq-lint.test.sh` |
| 1229 | 0 | 22 | `tests/sq-tmux-submit-busy.test.sh` |
| 1086 | 0 | 16 | `tests/sq-send-popup-settle.test.sh` |
| 1064 | 0 | 15 | `tests/sq-review-diff.test.sh` |
| 1048 | 0 | 18 | `tests/sq-send-strict.test.sh` |
| 1036 | 0 | 19 | `tests/sq-spawn-batch.test.sh` |
| 381 | 0 | 9 | `tests/sq-ensure-agents-md.test.sh` |
| 224 | 1 | 2 | `tests/sq-backend-herdr.test.sh` |
| 149 | 0 | 20 | `tests/sq-supervision-instructions.test.sh` |
| 74 | 0 | 6 | `tests/sq-composer-lib.test.sh` |
| 65 | 0 | 23 | `tests/sq-transition-lib.test.sh` |
| 15 | 0 | 13 | `tests/sq-pi-primary-types.test.sh` |

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
