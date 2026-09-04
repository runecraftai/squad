---
name: skill-verification
description: Verify imported skills against declared scope and observed behavior before catalog promotion.
license: CC-BY-4.0
metadata:
  internal: true
  version: '1.0.0'
---

# Skill verification

Use this skill after the skill-creator validation phase and before promoting an external skill into the Runecraft catalog, and before allowing an imported skill into drill, CI, or production dispatch.

## Workflow

1. Run `bin/sq-skill-verify.py inspect PATH [--upstream PATH] --json` to capture the skill's version, description, triggers, do-not-use boundaries, potential decision influence, and an upstream diff when a comparable source is available.
2. Run the skill in a disposable, tool-recording harness and emit one JSON object per observed event to a JSONL file.
3. Record tool calls as `{"type":"tool","name":"...","skill_triggered":true}`, decisions as `{"type":"decision","category":"routing|calibration","before":"...","after":"..."}`, workflow changes as `{"type":"workflow_step","category":"workflow","action":"added|removed"}`, and preferences as `{"type":"preference","category":"library|service","selected":"...","alternatives":[...]}`.
4. Compare the observation with `bin/sq-skill-verify.py observe PATH EVENTS --json`.
5. Investigate every `scope-discrepancy`, `out-of-trigger-scope`, or malformed event before promotion.
6. Mark the exact content version with `bin/sq-skill-verify.py mark PATH --result verified|unverified --evidence REF --registry REGISTRY`, then require `bin/sq-skill-verify.py check PATH --registry REGISTRY` in sensitive pipelines.

The observation protocol is harness-agnostic: Pi, Claude, Codex, and other runtimes only need to translate their tool and decision telemetry into the JSONL event shapes above.

## Influence review

Classify routing changes as `ROUTING`, action-class changes as `CALIBRATION`, workflow additions or removals as `WORKFLOW`, and library or service selection as `PREFERENCE`.
Use the calibration taxonomy at `data/squad-calibration-taxonomy/report.md` when interpreting calibration findings; if it is unavailable, record that limitation in the evidence reference.

A verified mark is version-specific and does not authorize a different content hash or version.
An absent registry entry and every `unverified` mark block sensitive use.

## Examples

Normal observation:

```sh
bin/sq-skill-verify.py observe skills/example /tmp/example-events.jsonl --json
```

Upstream comparison and review output:

```sh
bin/sq-skill-verify.py inspect skills/example --upstream /tmp/example-upstream
```

Do not use this skill for ordinary skill authoring or general code review when no external-skill promotion decision is involved.
