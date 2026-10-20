---
name: execution-playbooks
description: Versioned execution-method contracts materialized into briefs.
user-invocable: false
metadata:
  internal: true
---

An execution method is selected from three categories, and each one owns exactly one thing.

- A **playbook** is a complete method with its own sequence, reply contract, and stop condition.
  Choose it for how the task runs from start to its terminal evidence, and select it with `bin/sq-brief.sh --playbook <id>@<version>`.
- A **profile** is a reusable constraint set attached to a playbook, never standalone: it adds the architecture, naming, routing, and tooling rules that the playbook's steps must respect, and it never supplies the sequence or the stop condition.
  Select it with `bin/sq-brief.sh --playbook <id>@<version> --profile <id>@<version>`; the scaffold emits the profile block after the playbook block and refuses a profile with no playbook.
- A **gate** is a mechanical check on one property of the result, such as a lint rule or `bin/sq-playbook-validate.sh`.
  Gates are enforced by the selected playbook and are never selected on their own.

Every strike or recon brief records the decision: a selected playbook, or a one-line `--no-playbook` reason none applies.
The versioned contract owner is the reference named by the brief; other surfaces only enforce its identity and completion evidence.

When implementing a task that selected them, load the referenced playbook contract and, when the brief carries one, the profile alongside it.
