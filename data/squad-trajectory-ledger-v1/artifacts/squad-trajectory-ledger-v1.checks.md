# H1 trajectory ledger v1 — acceptance checks

Private task evidence for `squad-trajectory-ledger-v1`; the projection remains non-authoritative.
Run `tests/sq-trajectory.test.sh` from the repository root.

| # | Proof | Check |
|---|---|---|
| 1 | Test asserts schema v1, task id, attempts, duration and terminal outcome from `.meta`, `.exec` and status. | `task alpha --json` |
| 2 | Test asserts absent token usage is `null`, `unknown`, with a non-empty reason. | `task alpha --json` |
| 3 | Test asserts private status text is absent from JSON. CLI builds output from explicit metadata fields only. | `task alpha --json` |
| 4 | Test asserts snapshot mode `0600` and identical SHA-256 on repeat. Writer uses same-directory temp and rename. | `snapshot alpha` twice |
| 5 | Test asserts three source entries; each has base-relative path, byte size and observed mtime. Build path never reads the existing snapshot. | inspect `.sources` in JSON |
| 6 | Test asserts missing task and malformed `.exec` exit `2`; malformed regeneration leaves prior artifact bytes unchanged. | negative CLI cases |
| 7 | Test asserts completed task IDs are distinct, limited, and coverage has known/unknown/not-applicable counts. | `coverage --limit 20 --json` |
| 8 | Test asserts human report includes the top-unknown-reasons section; output is aggregate metadata only. | `coverage --limit 20` |

Ownership proof: task state is read from existing sidecars/status, and usage is requested from `sq-cost task --json`; this CLI writes only its private projection.
