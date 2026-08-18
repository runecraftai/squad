# Decision Card Schema v1

A decision card is a structured representation of a commander decision request.
It standardizes how Squad presents choices to the commander across all harnesses.

## JSON Schema

```json
{
  "version": 1,
  "id": "<unique-id>",
  "title": "<short title>",
  "question": "<the question being asked>",
  "context": "<brief context, 1-3 sentences>",
  "options": [
    {
      "id": "<option-id>",
      "label": "<display label>",
      "description": "<one-line description>",
      "recommended": false
    }
  ],
  "default_option_id": "<id of default option>",
  "allow_free_text": true,
  "expires_at": "<ISO-8601 timestamp or null>",
  "metadata": {
    "task_id": "<squad task id>",
    "key": "<decision key slug>",
    "source": "<where this decision originated>"
  }
}
```

### Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | integer | yes | Schema version (currently 1) |
| `id` | string | yes | Unique decision identifier (UUID or slug) |
| `title` | string | yes | Short title for the decision |
| `question` | string | yes | The specific question being asked |
| `context` | string | no | Brief context (1-3 sentences max) |
| `options` | array | yes | Array of option objects (2-4 recommended) |
| `default_option_id` | string | yes | ID of the recommended/default option |
| `allow_free_text` | boolean | no | Whether free-text input is allowed (default: true) |
| `expires_at` | string | no | ISO-8601 timestamp when decision expires |
| `metadata` | object | no | Additional context (task_id, key, source) |

### Option Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Unique option identifier |
| `label` | string | yes | Short display label (2-4 words) |
| `description` | string | no | One-line description of this option |
| `recommended` | boolean | no | Whether this is the recommended choice (should match default_option_id) |

### Metadata Object

| Field | Type | Description |
|-------|------|-------------|
| `task_id` | string | Squad task ID this decision belongs to |
| `key` | string | Decision key slug (for sq-send --resolve-key) |
| `source` | string | Origin: "ask-user", "blocked", "needs-decision", "manual" |

## Validation Rules

1. `version` must be 1
2. `id` must be non-empty
3. `title` must be non-empty
4. `question` must be non-empty
5. `options` must have at least 1 entry
6. `default_option_id` must reference an existing option id
7. Each option `id` must be unique within the card
8. Each option `label` must be non-empty
9. At most one option should have `recommended: true`

## Example

```json
{
  "version": 1,
  "id": "merge-strategy-2025-01",
  "title": "Merge Strategy",
  "question": "How should we merge this PR?",
  "context": "The PR has 3 commits with logical separation. CI is green.",
  "options": [
    {
      "id": "squash",
      "label": "Squash & Merge",
      "description": "Combine all commits into one clean commit",
      "recommended": true
    },
    {
      "id": "rebase",
      "label": "Rebase & Merge",
      "description": "Preserve individual commits in history"
    },
    {
      "id": "merge-commit",
      "label": "Create Merge Commit",
      "description": "Standard merge with merge commit"
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
