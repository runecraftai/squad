---
name: sq-learn
description: Capture operational lessons with metadata after significant work.
user-invocable: false
metadata:
  internal: true
---

# sq-learn

Use this skill when a durable operational lesson should be captured for future Squad work.

## Triggers

Load this skill when the request includes "save lesson", "capture learning", "record gotcha", "log lesson", or "sq-learn".

## When to capture

Capture a lesson after a bug fix reveals a gotcha.

Capture a lesson after discovering a tool quirk.

Capture a lesson after a commander decision changes the approach.

Capture a lesson after a failure pattern repeats.

Capture a lesson after learning a new constraint.

## When not to capture

Do not capture routine progress updates.

Do not capture step-by-step FYI details that do not change future work.

Do not capture temporary workarounds that will not persist.

## How to capture

Run:

```sh
bin/sq-learn.sh "lesson" --task <id> --source "evidence"
```

Keep each lesson under 500 characters.

Make the lesson specific and actionable so another operator can apply it.

The script skips identical and near-duplicate lessons automatically.
