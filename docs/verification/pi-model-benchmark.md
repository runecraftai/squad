# Pi model benchmark verification

Audience: maintainer verification.

The reusable benchmark is `bin/sq-pi-model-benchmark.sh`.

It compares exactly these Pi model identifiers:

- `opencode-go/mimo-v2.5`
- `opencode-go/muse-spark-1.2-contributor`
- `opencode-go/longcat-2.0`

The benchmark covers queue ordering, historical-event versus current-state reasoning, delegation instead of direct project mutation, long-context constraint retention, and higher-authority safety decisions.

All scenarios use temporary synthetic fixtures and mock tools.

The mock tools never touch the Squad base, a project, a credential store, or an external service.

The output contains one structured record per model, scenario, and trial without storing raw provider transcripts.

Each record reports tool-call correctness, orchestration correctness, safety violations, completion, latency, provider failure class, and whether usage counters were exposed.

Provider, transport, authentication, timeout, and quota failures remain unscored and are summarized separately.

Pi did not expose provider quota counters during the verification run, so the report records quota as unavailable rather than inventing a delta.

Fixture mode is the default and is safe for CI.

```sh
bin/sq-pi-model-benchmark.sh --fixtures --output /tmp/pi-model-benchmark-fixtures.json
jq '.summary, .recommendation' /tmp/pi-model-benchmark-fixtures.json
```

Live mode requires both `--live` and `SQ_PI_BENCHMARK_LIVE=1`.

Live mode is refused when `CI` is set to any non-empty value.

Before live execution, the runner verifies every exact model identifier through Pi's offline model catalog.

The Muse Spark scenario boundary is synthetic/public-only because OpenCode Go states that prompts and completions may be used for training.

No Muse Spark prompt, context payload, tool result, or artifact may contain commander-private preferences, local operational records, credentials, private repository content, or real task data.

A live verification run uses the following shape and keeps its report outside the repository unless a maintainer intentionally preserves a redacted result.

```sh
SQ_PI_BENCHMARK_LIVE=1 bin/sq-pi-model-benchmark.sh --live --output /tmp/pi-model-benchmark-live.json
jq '.run, .summary, .recommendation, .quota' /tmp/pi-model-benchmark-live.json
```

## Live verification on 2026-08-31

The exact model identifiers were checked with `pi --no-extensions --offline --list-models 'mimo-v2.5'`, `pi --no-extensions --offline --list-models 'muse-spark-1.2-contributor'`, and `pi --no-extensions --offline --list-models 'longcat-2.0'` before execution.

The comparable run used three trials per scenario for each approved model.

```sh
SQ_PI_BENCHMARK_LIVE=1 SQ_PI_BENCHMARK_TIMEOUT_SECONDS=60 bin/sq-pi-model-benchmark.sh --live --trials 3 --output /tmp/pi-model-benchmark-live.json
```

MiMo completed 15 of 15 attempts with 100% completion, 80% ordering correctness, 100% orchestration correctness, 100% safety, and a 95% composite score.

LongCat completed 14 of 15 attempts with one timeout, 100% completion among scored attempts, 64.29% ordering correctness, 100% orchestration correctness, 100% safety, and a 91.07% composite score.

Muse Spark produced 15 provider failures and no scored attempts because its provider was unavailable during this run.

Pi did not expose quota counters, so the run reported quota as unavailable rather than estimating a delta.

Among models with successful attempts, the run recommends `opencode-go/mimo-v2.5` for sustained Squad orchestration because it had the highest composite score and ordering score.

This recommendation is conditional on repeating the run when Muse Spark is available, since provider failures are not model scores.

The deterministic regression is:

```sh
bin/sq-test-run.sh tests/sq-pi-model-benchmark.test.sh
bin/sq-lint.sh
bin/sq-doc-audience-check.sh
```

A standard test or CI invocation must use fixture mode and must not set `SQ_PI_BENCHMARK_LIVE=1`.
