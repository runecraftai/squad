---
name: skill-creator
description: "Create new Squad skills from natural-language descriptions. Use when the user asks to create a skill, generate a skill package, or scaffold a new skill. Covers discovery, design, authoring, validation, optimization, and delivery."
user-invocable: true
author: Squad contributors
metadata:
  hermes:
    tags: [skills, creation, generation, scaffold]
    category: development
---

# skill-creator

Create complete, valid skill packages from natural-language descriptions.

## When to use

Use skill-creator when creating new skills for Squad. This covers:
- Generating SKILL.md files with proper frontmatter and sections
- Deriving trigger phrases and anti-triggers from descriptions
- Validating skill format against squad's standards
- Creating optional test stubs

## Workflow

The skill creation process follows six phases:

### 1. DISCOVER

Understand what the skill should do:
- Extract the core purpose from the description
- Identify trigger phrases (when to use the skill)
- Identify anti-triggers (when NOT to use the skill)
- Check for overlapping existing skills

### 2. DESIGN

Plan the skill structure:
- Name: lowercase, hyphen-separated, descriptive (e.g., `disk-monitor`, `csv-parser`)
- Description: one clear sentence for the frontmatter
- Sections: Triggers, Do NOT use for, Example usage, Validation checklist

### 3. AUTHOR

Generate the SKILL.md content with:

**Frontmatter:**
```yaml
---
name: <skill-name>
description: "<one-line description>"
user-invocable: true
author: Squad contributors
metadata:
  hermes:
    tags: [<relevant-tags>]
    category: <category>
---
```

**Required sections:**
- `## Triggers` - when to activate this skill
- `## Do NOT use for` - scope boundaries
- `## Example usage` - sample interaction
- `## Validation checklist` - verification steps

### 4. VALIDATE

Check the generated skill:
- Frontmatter has `name` and `description`
- `## Triggers` section exists and is non-empty
- `## Do NOT use for` section exists
- No overlap with existing skills
- Description accurately reflects purpose

### 5. OPTIMIZE

Refine the generated content:
- Ensure trigger phrases are natural and specific
- Verify anti-triggers are clear boundaries
- Check example usage is realistic
- Validate checklist items are actionable

### 6. DELIVER

Output the skill:
- Print generated SKILL.md for review
- Optionally create tests/ stub with `--tests`
- Install to target with `--approve`

## Skill format rules

### Name
- Lowercase with hyphens: `my-skill-name`
- Descriptive of the function
- No spaces or special characters

### Description (frontmatter)
- One clear sentence
- Starts with a verb or describes the capability
- Quoted in YAML

### Triggers
- "Use when the user asks to..."
- "Activates for..."
- Specific trigger phrases, not generic

### Anti-triggers
- "Do NOT use for..."
- Clear scope boundaries
- Prevent misuse cases

### Metadata
```yaml
metadata:
  hermes:
    tags: [relevant, keywords]
    category: development|productivity|automation|devops
```

## Example skill structure

```markdown
---
name: disk-monitor
description: "Monitor disk usage across servers and alert on thresholds."
user-invocable: true
author: Squad contributors
metadata:
  hermes:
    tags: [monitoring, disk, servers]
    category: devops
---

# disk-monitor

Monitor disk usage across servers and alert when thresholds are exceeded.

## Triggers

Use when the user asks to check disk usage, monitor storage, or alert on disk space.
Activates for disk monitoring, storage alerts, and server health checks.

## Do NOT use for

Do NOT use for general system monitoring beyond disk usage.
Do NOT use when a more specific monitoring skill already covers the request.

## Example usage

```
User: Check disk usage on production servers
Skill: Loads and applies the disk monitoring procedure.
```

## Validation checklist

- [ ] SKILL.md has valid frontmatter (name, description)
- [ ] Triggers section is present and non-empty
- [ ] Do NOT use for section is present
- [ ] Description accurately reflects the skill purpose
- [ ] No overlap with existing skills
```

## CLI integration

`sq-skill-create.sh` uses this knowledge to generate skills programmatically.
The script follows these same phases but automates the discovery and authoring.
