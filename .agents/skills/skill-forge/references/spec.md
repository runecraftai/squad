# SKILL.md Format Specification (Reference)

> Authoritative rules for the open SKILL.md format. Read this when you need precise rules for `name`, `description`, frontmatter fields, or folder layout. When this reference and the bundled validator disagree, the validator wins.

## Directory structure

A skill is a directory containing, at minimum, a `SKILL.md` file:

```
skill-name/
├── SKILL.md          # Required: metadata + instructions
├── scripts/          # Optional: executable code
├── references/       # Optional: documentation
├── assets/           # Optional: templates, resources
└── ...               # Any additional files or directories
```

A skill may also include `evals/evals.json` for output-quality evaluation (see [output-evaluation.md](output-evaluation.md)).

## `SKILL.md` format

`SKILL.md` is YAML frontmatter followed by Markdown body.

### Frontmatter fields

| Field | Required | Constraints |
|---|---|---|
| `name` | Yes | 1-64 chars; lowercase letters, numbers, hyphens; no leading/trailing or consecutive hyphens; must match parent directory name. |
| `description` | Yes | 1-1024 chars; non-empty; describes what the skill does and when to use it. |
| `license` | No | License name or reference to bundled license file. |
| `compatibility` | No | 1-500 chars; intended product, system packages, network access, etc. |
| `metadata` | No | Arbitrary key→string mapping. Use unique key names to avoid conflicts. |
| `allowed-tools` | No | Space-separated string of pre-approved tools. Experimental. |

### `name` rules

- 1-64 characters.
- Lowercase letters (`a-z`), numbers (`0-9`), and hyphens (`-`) only.
- Must not start or end with a hyphen.
- Must not contain consecutive hyphens (`--`).
- Must match the parent directory name.

| Valid | Invalid | Reason |
|---|---|---|
| `pdf-processing` | `PDF-Processing` | Uppercase not allowed |
| `data-analysis` | `-pdf` | Cannot start with hyphen |
| `code-review` | `pdf--processing` | Consecutive hyphens |

### `description` rules

- 1-1024 characters.
- Should describe what the skill does **and** when to use it.
- Include specific keywords that help agents identify relevant tasks.
- No XML angle brackets (`<`, `>`) — they break the YAML.

Good example:

```yaml
description: Extracts text and tables from PDF files, fills PDF forms, and merges multiple PDFs. Use when working with PDF documents or when the user mentions PDFs, forms, or document extraction.
```

Poor example: `Helps with PDFs.`

### `license` (optional)

Keep it short. A common choice for distributable skills is `CC-BY-4.0`.

### `compatibility` (optional)

Use only if the skill has environment requirements. Examples:

```yaml
compatibility: Designed for Claude Code (or similar products)
compatibility: Requires git, docker, jq, and access to the internet
compatibility: Requires Python 3.11+ and uv
```

Most skills do not need this field.

### `metadata` (optional)

A map from string keys to string values. Common keys for distributable skills:

```yaml
metadata:
  author: your-name-or-org
  version: 1.0.0
```

### `allowed-tools` (optional, experimental)

```yaml
allowed-tools: Bash(git:*) Bash(jq:*) Read
```

Support varies across agents.

## Body content

The Markdown body has no format restrictions. Recommended sections:

- Step-by-step instructions
- Examples of inputs and outputs
- Common edge cases
- Anti-patterns to avoid

The full body is loaded once the skill is activated. Keep it focused. Move deep content to `references/`.

## Optional directories

### `scripts/`

Executable code the agent can run. Guidance: see [scripts-guide.md](scripts-guide.md).

- Be self-contained or document dependencies.
- Include helpful error messages.
- Handle edge cases gracefully.
- Support `--help` for agentic discovery.

Common languages: Python, Bash, JavaScript. Inline dependency declarations exist for Python (PEP 723), Deno, Bun, and Ruby.

### `references/`

Additional documentation the agent reads on demand. Convention: focused files, one topic each. Examples:

- `REFERENCE.md` — detailed technical reference
- `FORMS.md` — form templates or structured data formats
- Domain files (`finance.md`, `legal.md`, etc.)

Smaller files = less context. The agent only loads what it needs.

### `assets/`

Static resources the agent uses in output:

- Document templates
- Configuration templates
- Images (diagrams, examples)
- Data files (lookup tables, schemas)

Reference them from SKILL.md with a clear "when to use" clause.

## Progressive disclosure

Agents load skills progressively, in three stages:

1. **Discovery** — only `name` and `description` of each available skill.
2. **Activation** — full `SKILL.md` body when the task matches.
3. **Execution** — referenced files (scripts, references, assets) loaded only as needed.

Implications for skill design:

- Keep `name` and `description` rich enough to trigger correctly.
- Keep `SKILL.md` under **500 lines** and **5000 tokens** of body.
- Reference linked files with explicit load conditions.

## File references

When referencing other files, use **relative paths from the skill root**:

```markdown
See [the reference guide](references/spec.md) for details.

Run the validator:

```bash
python3 scripts/validate.py ./my-skill
```
```

Keep references one level deep from `SKILL.md`. Avoid deeply nested chains.

## Validation

This skill ships its own bundled validator at `../scripts/validate.py` (stdlib-only, no external deps, JSON output for agentic consumption). Use it as the single source of truth for what the format requires.
