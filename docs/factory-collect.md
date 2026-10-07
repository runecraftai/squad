# Factory collection (phase 1)

`bin/sq-factory-collect.sh` is the input half of a small software factory pilot: it reads a few sources on demand, triages each item against an explicit verifiability test, and lands the ones that pass as queued backlog candidates for a human to review.
It is collection and triage only.

## No-execution boundary

This tool never dispatches a mission, never opens a pull request, never merges anything, and never touches a project clone.
Its only side effects are: reading GitHub through `sq-gh`, and writing a queued (never in-flight) `kind: candidate` item to `data/backlog.md` through `sq-tasks add`, plus its own local dedupe ledger and digest file under `data/factory-collect/`.
Turning a candidate into real work still goes through Squad's ordinary intake in `AGENTS.md` section 7: a human decides, nothing here decides for them.
Policy-based auto-dispatch is explicitly out of scope for this phase.

## Running it

```sh
bin/sq-factory-collect.sh run                      # collect, triage, queue candidates, write the digest
bin/sq-factory-collect.sh run --dry-run             # same triage, writes nothing (no ledger, no digest file, no backlog item)
bin/sq-factory-collect.sh run --json                # print the full structured result instead of the summary
bin/sq-factory-collect.sh run --config PATH         # use a config file other than the tracked default
```

There is no scheduler and none is wired up: this is a manual, on-demand command by design (`AGENTS.md`'s "no daemon, no new event system" boundary for this task).
A future phase may wire it to an existing cadence (a cron skill, a sentry poll); until then, run it by hand or from `/loop` if you want a recurring check, which still does not grant it any execution authority.

Re-running it is always safe: both the dedupe ledger and `sq-tasks add`'s own idempotent-by-id behavior mean a second run on unchanged inputs queues nothing new (see "Dedupe" below).

## Config schema (`.factory-collect.toml`)

Tracked at the repo root, parallel to `.tasks.toml`, because it configures the pilot run against this repo's own GitHub project and is itself part of what phase 1 demonstrates, not a per-commander operating choice.

```toml
schema_version = 1

[source.github_issues]
enabled = true
repo = "runecraftai/squad"
state = "open"
limit = 50
repro_patterns = ["(?i)steps to reproduce", "(?im)^#+\\s*repro"]

[source.ci_failures]
enabled = true
repo = "runecraftai/squad"
workflow = "ci.yml"      # workflow FILENAME, not display name
branch = "main"
run_limit = 20
min_failures = 2
```

- `source.github_issues.repro_patterns` — a list of regexes (Python `re` syntax); an issue qualifies when its body matches at least one. Each pattern must itself name a real reproduction signal (an explicit heading or phrase); a bare fenced code block is deliberately not one of the shipped patterns, since a stack trace or log dump in a fence names no reproduction path on its own.
- `source.ci_failures.min_failures` — how many times the same job (or, if no single job carries `conclusion: failure`, the same workflow+branch) must recur across the last `run_limit` fetched failed runs before it is a stable enough identity to queue. Below this, it goes to the human digest instead.

## Capability matrix

| Source | Status | Notes |
| --- | --- | --- |
| GitHub issues (open) | available | `sq-gh issue list`, filtered by `repro_patterns` |
| GitHub Actions job failures, recurring across runs | available | `sq-gh run list` + `sq-gh run view`; identity is `(workflow, job name)`, or `(workflow, branch)` when no job in a run carries `conclusion: failure` (e.g. a required branch-protection check failed outside the job graph) |
| Sentry-style error telemetry | not available | no error-telemetry pipeline is configured for this repo; nothing here simulates one |
| User feedback / support tickets | not applicable | this repo has no feedback channel to collect from |
| Dependabot / security advisories | not implemented | a plausible phase-2 source via `sq-gh api`; left out of phase 1 to keep the pilot to two sources, per the "keep it small" scope boundary |

"Recurring test failures, where a stable identity exists" (one of the pilot's requested inputs) is folded into the `ci_failures` source above rather than built as a third source: the stable identity available without log-scraping is the CI **job** name, not an individual test-case name inside that job's log.
Extracting per-test-case identity would need a log parser per CI framework — exactly the per-source abstraction layer the task scope says to cut back to avoid.
Job-level recurrence is honest about that granularity and is still a materially useful, concrete signal (see the real run below).

## How sq-gh output is parsed

`sq-gh` always renders through the TOON format (its `--json` flag only wraps the rendered TOON string, it does not emit structured data); `bin/sq-factory-collect-toon.mjs` strips the non-data `count:`/`total_count:` scalar line and the trailing `help[...]:` suggestions block sq-gh always appends, then decodes the rest with a vendored, byte-identical copy of `@toon-format/toon@2.3.1` at `bin/vendor/toon/` (MIT; license alongside). Vendoring keeps this step independent of an npm/pnpm/bun install at the repo root.
A source whose `sq-gh` call exits non-zero, times out, or produces output that does not decode is reported as a failed source (see "Failure handling") rather than crashing the run.

## Verifiability test

A candidate is queued only when the evidence names a concrete reproduction path: what to run or open, and what should happen.
- A `github_issue` candidate's `repro` names the issue URL and expects the described bug to occur when its own stated steps are followed; it only qualifies when the body text matched one of `repro_patterns`.
- A `ci_failure` candidate's `repro` names an exact command (`sq-gh run rerun <id> --failed --repo <repo>`) or the run URL, and expects it to pass once fixed; it only qualifies once the same job/identity has recurred `min_failures` times, so a single flaky blip never queues anything.

Everything that does not clear this bar goes to the human digest instead of being queued or dropped.

## Candidate record

Each queued candidate carries: `id`, `source`, `fingerprint`, `link`, `title`, `evidence`, `verifiable_reason`, `repro`.
It lands in `data/backlog.md` via `sq-tasks add <id> ... --kind candidate --queue`, so it is always `## Queued`, never `## In flight` — this tool has no authority to start work, only to propose it.
The same fields are written into the backlog item's body for durable, inspectable evidence.

## Dedupe

Two independent mechanisms, because they cover different failure modes:

1. A durable local ledger (`data/factory-collect/seen.json`, keyed by a stable `fingerprint` per source identity) — checked first, before anything else, so a candidate already queued in a prior run is never even re-sent to `sq-tasks`. This is what "never re-propose the same input across runs" means even if the backlog item was later closed, archived, or removed.
2. `sq-tasks add`'s own idempotent-by-id behavior — each candidate's `id` is deterministic (derived from the same fingerprint), so even if the local ledger were lost or reset, adding an id that is already in the backlog returns `already: true` instead of creating a duplicate. This covers "never propose something already present in the backlog" as a backstop independent of the ledger.

## Human digest

Everything that does not clear the verifiability bar is grouped by source into one bounded Markdown list (`data/factory-collect/digest.md`, also printed to stdout), not dropped and not escalated item by item.
It is recomputed fresh on every run from whatever is currently open/failing, so it never grows without bound.

## Failure handling

Each source is collected independently; one failing (a `sq-gh` error, a timeout, a missing binary, a TOON decode failure) is reported under `sources.<name>.error` in the JSON result and the run continues with the other source.
Within `ci_failures`, a single failed `sq-gh run view` is reported per-run in the human digest and skipped, so one unpaginated bad run cannot discard findings from every other fetched run; if every fetched failed run is unviewable, the whole source is reported as failed instead of as a healthy empty fetch.
A failure to queue a candidate is reported under `sources.<name>.queue_error` on the candidate's owning source and does not abort the remaining candidates.
The run's own exit code is non-zero only when every enabled source failed, and an all-failed run leaves the previously persisted `data/factory-collect/digest.md` untouched instead of blanking it with an empty digest.

## A real run

Run against `runecraftai/squad` itself on 2026-10-06 (`bin/sq-factory-collect.sh run --dry-run --json`, sensitive content redacted — there were no open issues on the repo at the time):

- `github_issues`: 0 fetched (no open issues).
- `ci_failures`: 7 distinct failing-job identities fetched across the last 20 failed `ci.yml` runs on `main`.
- 5 candidates qualified: CI jobs named `Behavior portable serial 1`, `Behavior tests (Herdr)`, `Behavior portable serial 2`, `Behavior portable serial 3`, and `Behavior portable serial 4`, each recurring 11-14 times in the 20 most recently fetched failed runs — a genuine, previously uncollected flaky-CI signal.
- 2 went to the human digest: two run-level failures that had not yet recurred a second time.

Re-run it yourself with:

```sh
bin/sq-factory-collect.sh run --dry-run --json
```

(drop `--dry-run` to actually queue the 5 candidates into `data/backlog.md`).
