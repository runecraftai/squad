# @runecraft/pr-review

Part of [Runecraft Companion](../../README.md), the multi-agent harness for the [Pi coding agent](https://pi.dev).

Inside the harness, `@runecraft/pr-review` provides parallel, tiered code review of GitHub pull requests: five focused passes (correctness, contracts, security, performance, hygiene) run in parallel with models you choose, findings are validated before reporting, and a structured review with severity and verdict is rendered (`/pr-review <n>`).

## Install

Installed automatically as part of `@runecraft/companion`. Standalone:

    pi install npm:@runecraft/pr-review

## Docs

- Full guide, quickstart & agent matrix: [root README](../../README.md)
- Mental model / when to use this vs the other tools: [docs/architecture.md](../../docs/architecture.md)

## Relationship to upstream

Fork of `pi-pr-review` (10ego, MIT), pinned at v1.11.4 (SHA `dbb4ad7d7d993e737da26543240d787405683cf8`). Notable divergence: hardcoded upstream references (`pi-pr-review` / 10ego) were fixed in the verify-package-contents step so the packaged artifact validates under the `@runecraft/*` identity.

## Features

### Live focus viewer

`/pr-review-focus` opens a read-only live focus viewer on the review in progress (`Ctrl+Alt+R`). Return to the main thread without cancelling the review. The viewer never stores the pass objective, input context, captured diff, and cannot send prompts, steering, or follow-ups.

### Publication

`/pr-review-publish` publishes a completed review's findings and handles that request directly; publishing never starts or reruns a review. When the review was cancelled, it reports that state instead of publishing. With `allowStalePublish: true` the command runs the configured `light` subagent once to reformat the completed output and posts it as a stale review (`/pr-review-publish 123 --allow-stale`). Inline comments are always disabled for stale reviews.

The package caches one validated completed review; `autoPostReviews` and `--comment` publish that cached review after completion. It builds one GitHub review payload and sends at most one review `POST`: the first 50 eligible P0–P3 findings with valid, unique diff anchors are inline, and All other findings that pass content validation stay in the top-level review body.
