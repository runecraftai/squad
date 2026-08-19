---
title: "rebase"
description: Rebase a worktree branch onto its base branch
---

Rebases a worktree branch onto its saved base branch. If the branch does not have a saved local base branch, workmux rebases onto the configured main branch.

```bash
workmux rebase [name]
```

## Arguments

- `[name]`: Optional worktree name or branch. If omitted, workmux detects the current worktree from the current directory.

## What happens

1. Determines which worktree branch to rebase
2. Reads the saved base branch recorded when the worktree was created
3. Falls back to the configured main branch when the saved base is not a local branch
4. Runs `git rebase <base>` inside the worktree
5. Leaves the worktree, window, and branch in place

## Examples

```bash
workmux rebase user-auth
workmux rebase
```
