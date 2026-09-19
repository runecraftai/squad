---
name: execution-playbooks
description: Versioned execution-method contracts materialized into briefs.
user-invocable: false
metadata:
  internal: true
---

Execution playbooks are explicit method contracts selected by `sq-brief.sh` and copied into the brief.
The versioned contract owner is the reference named by the brief; other surfaces only enforce its identity and completion evidence.

Load the referenced contract when implementing a task that selected an execution playbook.
