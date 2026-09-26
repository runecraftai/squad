# Retry cannot re-engage completed work

- [x] Verify the `retry_run_claim` code path in `bin/sq-stall-detect.sh`; confirmed it claimed retry-queued tasks and could append a retry-limit `failed:` event without first rechecking the latest terminal status.
- [x] Before claiming a retry, release it if the latest status event is paused or terminal.
- [x] If the locked claim loses a race with a terminal status, release rather than append a blocked event.
- [x] Add an executable regression for a completed task queued at the retry limit; assert no attempt bump and no replacement failure status.
- [x] Run `bash tests/test-sq-stall-detect.sh` and `bin/sq-lint.sh`; both passed.
- [ ] Commit implementation and run Drill through green CI.
