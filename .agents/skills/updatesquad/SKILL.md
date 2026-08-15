---
name: updatesquad
description: >-
  Self-update a running Squad and its XOs to the latest from origin.
  Use when the commander invokes /updatesquad (e.g. "/updatesquad", "update Squad", "pull the latest Squad").
  Fast-forwards this Squad repo's default branch and every local or remote XO through its guarded update path (never forced, never disruptive), then re-reads AGENTS.md and nudges each updated XO to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
metadata:
  internal: true
---

# updatesquad

Self-update Squad in place.
Squad is its own repo, behind the same drill gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running Squad pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running Squad instruction surface; public `skills/` is installer-facing and is not loaded by Squad.
This skill performs that pull for the running main Squad and every XO, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the unit sync Squad already runs.
For a remote route, it updates the configured Squad code root on that host from its own origin, then guardedly fast-forwards the persistent base to that code-root commit.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .drill/) untouched, so an XO's in-flight work is never disrupted.
This touches only the Squad repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/sq-update.sh
   ```
   It fast-forwards this Squad repo's default branch from origin, then updates every registered local or remote XO base through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by two action lines that tell you exactly what to do next:
   - `reread-Squad: yes|no`
   - `nudge-XOs: sq-<id>...|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-Squad: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-Squad: no`, nothing changed for you - skip the re-read.

3. **Nudge each updated live XO.**
   For every target listed on the `nudge-XOs:` line (do nothing when it says `none`), send a one-line re-read nudge so that XO picks up its new instructions too:
   ```sh
   SQUAD_BASE=<this-Squad-base> bin/sq-send.sh <id> 'Squad was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `SQUAD_BASE=<this-Squad-base>` unless `SQUAD_BASE` is already set to the active Squad base.
   This is a gentle steer, not an interruption: the XO already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   An XO that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

4. **Report to the commander in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without Squad's internal vocabulary: which parts of the unit are now on the latest, and which were left as-is and why.
   For example: "Comandante, o agente e os dois subcomandantes estão na versão mais recente."
   Surface any skipped target whose reason needs the commander's attention - for instance a base with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the Squad repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the unit sync.
- **XOs are never disrupted.**
  A local or remote XO gets a tracked-files fast-forward only when its own checkout is safe to advance, plus a gentle re-read nudge when it changed.
  It is never torn down, interrupted, or forced.
