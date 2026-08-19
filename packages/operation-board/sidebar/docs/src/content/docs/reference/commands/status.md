---
title: "status"
description: Query tracked agent status for worktrees
---

Reports tracked agents in the current repository or in explicitly requested
worktrees.

```bash
workmux status [WORKTREE ...] [--json] [--git]
```

## Options

- `--json`: Emit a machine-readable observation object.
- `--git`: Include staged, unstaged, and unmerged commit information for each
  returned agent.

Worktree arguments support `project:handle` syntax for cross-project queries.

## JSON output

```json
{
  "context": {
    "backend": "tmux",
    "instance": "/private/tmp/tmux-501/default"
  },
  "scope": {
    "repository": "/Users/user/code/project",
    "targets": []
  },
  "state_files_total": 3,
  "state_files_invalid": 1,
  "state_files_invalid_unattributed": 0,
  "state_files_invalid_matching_context": 0,
  "state_files_matching_context": 2,
  "reconciled_agent_count": 1,
  "agents": [],
  "target_errors": []
}
```

The counts describe successive stages of the observation.

- `state_files_total`: JSON state files found in the workmux agents directory,
  including files that cannot be decoded. Atomic-write temporary files are
  excluded.
- `state_files_invalid`: State files that cannot be decoded across all
  multiplexer contexts.
- `state_files_invalid_unattributed`: Invalid state files whose filenames do not
  unambiguously identify a backend and instance.
- `state_files_invalid_matching_context`: Invalid state files attributed to the
  selected backend and instance. A nonzero value in either this field or
  `state_files_invalid_unattributed` makes the command fail.
- `state_files_matching_context`: Readable state files whose backend and
  instance exactly match `context`.
- `reconciled_agent_count`: Agents accepted by live multiplexer reconciliation
  before repository and target filtering.
- `agents`: Reconciled agents inside the declared `scope`.
- `target_errors`: Requested worktrees that could not be resolved. Each error
  contains the original `target`, a stable `code`, and a human-readable
  `message`.

The observation does not remove stale or invalid state files. It excludes stale
entries from `agents` and leaves persisted evidence available for later cleanup
or diagnosis. If invalid state blocks an observation, inspect the agents
directory under the workmux XDG state directory and remove or repair the file
reported in the warning log.

`scope.repository` is the current repository when it can be resolved. With no
explicit targets, agents are filtered to that repository. Outside a Git
repository it is `null`, and a no-target query returns all reconciled agents in
the selected multiplexer context. `scope.targets` contains the requested
worktree selectors.

Each agent contains `worktree`, `branch`, `status`, `elapsed_secs`, `title`,
`pane_id`, `workdir`, `agent_kind`, `session`, `window_name`, and `updated_ts`.
With `--git`, it also contains a `git` object.

## Safe automation

Check the exit status before interpreting the JSON. Most failures produce no
JSON. When some explicit targets resolve and others do not, the command emits
the complete observation with details in `target_errors` and exits nonzero.
This preserves successful results without presenting a partial query as fully
successful.

A successful empty `agents` array has different meanings depending on the
counts:

- `state_files_total > 0` and `state_files_matching_context == 0`: persisted
  state exists, but none describes the selected backend and instance. A
  fleet-wide consumer should fail closed.
- `reconciled_agent_count > 0` and `agents` is empty: tracked agents exist in
  the selected multiplexer context but fall outside the repository or target
  scope.
- `reconciled_agent_count == 0`: no readable state in the selected context was
  accepted by live reconciliation.

State files for another context can belong to an old or concurrently running
multiplexer instance. Their presence is evidence of another context, not proof
that the selected context is wrong.

Workmux can observe only agents that produced tracking state. An agent without
configured or functioning status hooks remains invisible to this command.

## Errors

The command fails when it cannot complete the requested observation, including:

- invalid backend overrides
- unresolved multiplexer instance identity
- state inventory read failures
- invalid state files attributed to the selected multiplexer context
- multiplexer query or response parsing failures
- Git query failures when `--git` is requested
- missing or ambiguous requested worktrees, reported in `target_errors` when an
  observation can otherwise be completed
