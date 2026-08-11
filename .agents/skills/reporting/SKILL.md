---
name: reporting
description: Recap visible session events since the prior real commander message plus visibly unanswered commander decisions when the commander explicitly invokes /reporting, with a Sitrep fallback when /reporting is the session's first real commander message.
user-invocable: true
metadata:
  internal: true
---

# reporting

Give the commander a concise session-only recap without gathering fresh state.

0. Before anything else, check whether this session has already taken the helm: a `SESSION START` digest for this base must be visible in the session history.
   If it is not, run `bin/sq-session-start.sh` once and read its digest before producing any recap.
   Run-tier harness surfaces run it automatically at session open, so this step is normally already satisfied and costs one glance; it is the safety net for surfaces that cannot run it on a hook, and for any path where a skill would otherwise act first.
   Taking the helm always precedes this skill's own logic, and the digest it produces is operational input, never a commander message or a recap event.

1. Inspect only conversation or session history already visible to the current sergeant at arms.
2. Find the most recent real commander-authored message before the current `/reporting` invocation.
   A commander boundary is an ordinary user-role message unless it matches one of the narrow operational exclusions below.
   Exclude messages that begin with the current U+2063 `SQUAD_OP:` injection prefix.
   Exclude legacy bare-marker away-mode injections only when U+2063 is immediately followed by `Supervisor escalate (`.
   Exclude the exact legacy unmarked session-start payload ``Run `bin/sq-session-start.sh` now, exactly once, before executing any other instructions.``
   Custom-role messages such as Pi's `Squad-sessionstart-nudge` are not commander messages.
   System, developer, tool, sentry, guard, away-mode, and other injected operational messages are not commander messages.
   Never infer commander authorship merely because a synthetic message appears in the user-role transcript.
   Do not exclude an ordinary commander message merely because it begins with U+2063 followed by other text, contains ASCII `SQUAD_OP:` without a leading U+2063, quotes or embeds a current operational message after ordinary commander text, quotes or mentions the legacy session-start payload, or adds any text to that payload.
   Apply the current exclusion only when U+2063 `SQUAD_OP:` begins at the first character of the whole message: `Commander quote: ` followed by that current prefix is a commander boundary.
   Apply the legacy startup exclusion as a literal whole-message match: ``Commander quote: Run `bin/sq-session-start.sh` now, exactly once, before executing any other instructions.`` is a commander boundary.
3. If no prior real commander message exists, load [`../sitrep/SKILL.md`](../sitrep/SKILL.md) and follow it exactly.
   Sitrep alone owns its gathering, artifact, and response contract.
   Do not restate that contract or combine a session recap with Sitrep output.
4. If a prior real commander message exists, preserve the ordinary recap interval: recap what happened after that message and before the current invocation.
   Include concrete outcomes, landed work, failures, decisions made, new decisions needed, and work still running only when those events appear in that visible interval.
   Use commander-facing outcome language and preserve every full PR URL present in that interval.
5. Additionally inspect the entire session history visible to the current sergeant at arms before the current invocation for every explicit commander decision that remains unanswered, including decisions raised before the ordinary recap boundary.
   A later unrelated commander message establishes a recap boundary but does not close an earlier decision.
   Treat a decision as closed only when a later visible response substantively resolves it, chooses an option, declines it, grants or denies the requested approval, or otherwise directly addresses that decision.
   Include every visibly supported open decision once, and deduplicate by the decision's substance when the ordinary interval recap already represents it or its wording differs.
6. The normal recap branch is session-history-only, apart from the step 0 helm check.
   Do not call Sitrep, shell commands, unit snapshots, status readers, GitHub or browser APIs, tools, or file reads or writes.
   Create no report, persist nothing, and do not guess current live state beyond the last visible event.
7. If no ordinary events occurred after the previous commander message but an older visibly open decision exists, report that decision instead of claiming nothing happened.
   If neither ordinary events nor visibly open decisions exist, say directly in one sentence that nothing happened after the previous commander message.

The current `/reporting` message is outside the recap interval.
A previous `/reporting` is a real commander message and may be the next interval boundary.
If context compaction makes the prior boundary unavailable, state that the exact session boundary is unavailable and summarize only visibly supported events.
Compacted history supports an open decision only when both its request and its still-unanswered status are visible; report uncertainty instead of reconstructing hidden requests or answers.
Do not silently invoke Sitrep unless this is genuinely the first real commander message.
