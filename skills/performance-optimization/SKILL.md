---
name: performance-optimization
description: Find and fix measured performance bottlenecks across frontend, backend, queries, storage, and delivery paths.
license: MIT
metadata:
  source: addyosmani/agent-skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
---

# Performance Optimization

Use this skill when performance requirements exist, users report slowness, or a regression is suspected.
Measure before optimizing and keep only changes that improve the target metric without breaking correctness.

## Workflow

1. Establish a baseline with a named metric, command, fixture, and conditions.
2. Identify the bottleneck from a trace, profile, query plan, or representative measurement.
3. Change one cause at a time.
4. Re-measure under the same conditions and compare against run-to-run variance.
5. Keep a measurable win, revert a neutral or worse result, and record both attempts.
6. Add a focused regression budget or monitor for the user-visible metric.

For web work, check LCP, INP, and CLS.
For APIs, check p95 latency, payload size, query count, and connection wait time.
For databases, read the query plan before adding an index.
For caches, state the key inputs, staleness window, invalidation strategy, and stampede behavior.

## Example

Hypothesis: a list endpoint is slow because it fetches owners one row at a time.

Evidence: query logging shows one query per row.

Fix: fetch the relation in one bounded query, then repeat the same measurement.

## Do not use for

- A request with no performance symptom, target, or measurement path.
- Keeping an optimization because it feels harmless.
- Replacing correctness work with a benchmark improvement.
