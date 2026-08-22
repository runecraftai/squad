# Decision Card Examples

Three real-world examples of decision cards for keyed-decision workflows.
For general multi-item responses, use the reference code format defined in `AGENTS.md` section 9.

## Example 1: Merge Authority Decision

**Scenario**: A drill task has completed validation and needs the commander to decide how to merge.

### Decision Card JSON

```json
{
  "version": 1,
  "id": "merge-auth-fix-auth",
  "title": "Merge Strategy",
  "question": "How should we merge the authentication fix PR?",
  "context": "PR #42 fixes the OAuth token refresh bug. CI is green, 2 commits with logical separation. The fix is time-sensitive.",
  "options": [
    {
      "id": "squash",
      "label": "Squash & Merge",
      "description": "Combine into one clean commit on main",
      "recommended": true
    },
    {
      "id": "rebase",
      "label": "Rebase & Merge",
      "description": "Preserve both commits in history"
    },
    {
      "id": "merge-commit",
      "label": "Create Merge Commit",
      "description": "Standard merge with merge commit message"
    }
  ],
  "default_option_id": "squash",
  "allow_free_text": false,
  "expires_at": null,
  "metadata": {
    "task_id": "fix-auth-bug",
    "key": "merge-strategy",
    "source": "ask-user"
  }
}
```

### Status Line Format
```
needs-decision [key=merge-strategy]: Merge Strategy | options: Squash|Rebase|Merge-commit | default: Squash
```

### Chat Card Rendering
```
━━━ DECISION: Merge Strategy ━━━
How should we merge the authentication fix PR?

PR #42 fixes the OAuth token refresh bug. CI is green, 2 commits with logical separation.
The fix is time-sensitive.

Options:
  1. Squash & Merge - Combine into one clean commit on main  ← recommended
  2. Rebase & Merge - Preserve both commits in history
  3. Create Merge Commit - Standard merge with merge commit message

Your call [Squash & Merge]: _
```

---

## Example 2: Ask-User Finding from Drill

**Scenario**: During drill validation, the linter found a style issue that could go either way. The drill pipeline surfaces this as an ask-user finding.

### Decision Card JSON

```json
{
  "version": 1,
  "id": "ask-user-import-style",
  "title": "Import Style",
  "question": "Should we use named imports or wildcard imports for the utility module?",
  "context": "The linter flagged mixed import styles in utils.ts. Both are valid; the codebase uses both patterns. This is a style preference that should be consistent.",
  "options": [
    {
      "id": "named",
      "label": "Named Imports",
      "description": "import { func1, func2 } from './utils'",
      "recommended": true
    },
    {
      "id": "wildcard",
      "label": "Wildcard Import",
      "description": "import * as utils from './utils'"
    },
    {
      "id": "default",
      "label": "Default Import",
      "description": "import utils from './utils'"
    }
  ],
  "default_option_id": "named",
  "allow_free_text": true,
  "expires_at": null,
  "metadata": {
    "task_id": "refactor-utils",
    "key": "import-style",
    "source": "ask-user"
  }
}
```

### Status Line Format
```
needs-decision [key=import-style]: Import Style | options: Named|Wildcard|Default | default: Named
```

### Chat Card Rendering
```
━━━ DECISION: Import Style ━━━
Should we use named imports or wildcard imports for the utility module?

The linter flagged mixed import styles in utils.ts. Both are valid; the codebase uses
both patterns. This is a style preference that should be consistent.

Options:
  1. Named Imports - import { func1, func2 } from './utils'  ← recommended
  2. Wildcard Import - import * as utils from './utils'
  3. Default Import - import utils from './utils'
  0. Type something (free text)

Your call [Named Imports]: _
```

---

## Example 3: Product-Scope Choice

**Scenario**: During a feature implementation, the scope needs to be clarified. The worker needs the commander to decide whether to expand scope or keep it minimal.

### Decision Card JSON

```json
{
  "version": 1,
  "id": "scope-user-dashboard",
  "title": "Dashboard Scope",
  "question": "Should the user dashboard include analytics widgets in the initial release?",
  "context": "The basic dashboard (profile, recent activity) is complete. Analytics widgets were in the original spec but could be deferred to v2 to ship faster. Adding analytics now would add ~2 days.",
  "options": [
    {
      "id": "minimal",
      "label": "Ship Without Analytics",
      "description": "Release dashboard with profile and activity only",
      "recommended": true
    },
    {
      "id": "full",
      "label": "Include Analytics",
      "description": "Add analytics widgets before release (+2 days)"
    },
    {
      "id": "feature-flag",
      "label": "Analytics Behind Flag",
      "description": "Include analytics but gate behind feature flag"
    }
  ],
  "default_option_id": "minimal",
  "allow_free_text": true,
  "expires_at": "2025-02-01T00:00:00Z",
  "metadata": {
    "task_id": "user-dashboard",
    "key": "dashboard-scope",
    "source": "needs-decision"
  }
}
```

### Status Line Format
```
needs-decision [key=dashboard-scope]: Dashboard Scope | options: Ship-Without|Include-Analytics|Feature-Flag | default: Ship-Without
```

### Chat Card Rendering
```
━━━ DECISION: Dashboard Scope ━━━
Should the user dashboard include analytics widgets in the initial release?

The basic dashboard (profile, recent activity) is complete. Analytics widgets were in
the original spec but could be deferred to v2 to ship faster. Adding analytics now would
add ~2 days.

Options:
  1. Ship Without Analytics - Release dashboard with profile and activity only  ← recommended
  2. Include Analytics - Add analytics widgets before release (+2 days)
  3. Analytics Behind Flag - Include analytics but gate behind feature flag
  0. Type something (free text)

Your call [Ship Without Analytics]: _
```

---

## Integration with sq-send

When the commander answers a decision, the answer flows through sq-send with --resolve-key:

```bash
# Commander selects option 1 (Squash & Merge)
sq-send.sh fix-auth-bug --resolve-key merge-strategy "answer: Squash & Merge"

# Commander enters free text
sq-send.sh refactor-utils --resolve-key import-style "answer: Use barrel exports from index.ts"
```

The sq-send --resolve-key flag automatically appends the closing `resolved [key=<key>]: answered: <excerpt>` to the status file, closing the decision in the ledger.

## Integration with Drill Ask-User Findings

When drill surfaces an ask-user finding, the presentation should follow this card format:

1. The finding text includes the decision card JSON or references it
2. Squad renders the card using `sq-ask.sh --render` for chat presentation
3. The commander answers through the normal decision flow
4. The answer is fed back to drill via `drill axi respond`

The drill pipeline itself handles the mechanics of surfacing findings; this standard only defines the presentation format to ensure consistency across all decision surfaces.
