---
name: skill-forge
description: >
  Designs, authors, validates, and optimizes new Agent Skills from scratch. Use when creating
  a new skill, packaging a workflow as a skill, improving a skill's triggering accuracy, or
  evaluating whether a skill improves output quality. Covers the full lifecycle: DISCOVER,
  DESIGN, AUTHOR, VALIDATE, OPTIMIZE, DELIVER. Produces skills that follow the open
  SKILL.md format (YAML frontmatter + Markdown body, progressive disclosure, validation loops).
  EN triggers: /forge, create a skill, write a skill, build a skill, new skill, author a skill,
  package this as a skill, validate a skill, improve skill triggering, optimize skill description,
  evaluate skill quality.
  PT triggers: /forge, criar uma skill, escrever uma skill, construir uma skill, nova skill,
  empacotar como skill, validar skill, melhorar disparo, otimizar descrição de skill.
  Do NOT use for: discovering which existing skill to apply (use a dispatch/meta skill),
  planning feature implementation, or designing software architecture.
license: CC-BY-4.0
metadata:
  version: 1.0.0
---

# skill-forge

> Meta-skill for creating new Agent Skills from scratch. Produces publishable, validated, trigger-tested skills that compose with the rest of the catalog.

```
DISCOVER → DESIGN → AUTHOR → VALIDATE → OPTIMIZE → DELIVER
```

Each phase has explicit exit criteria. Move sequentially. Do not skip to AUTHOR before completing DISCOVER and DESIGN — bad frontmatter is the most common reason skills misfire.

## Critical rules (read before acting)

- **The open SKILL.md format is the source of truth.** This skill encodes the format rules (frontmatter schema, naming, progressive disclosure, folder layout). When in doubt, follow what this skill's own validator enforces — it is the single reference implementation.
- **The description field controls triggering.** It is the only thing the agent sees at startup. Write it last but treat it as the most important field. If triggering is wrong, nothing else matters.
- **Skills are for agents, not humans.** The `SKILL.md` body is agent instructions. Human-facing docs (README, changelogs) belong outside the skill folder.
- **Never fabricate domain knowledge.** Build skills from real expertise — your own run history, internal docs, runbooks, schemas, code review comments. Generic "best practices" skills have no edge.

---

## Phase 1: DISCOVER

**Goal:** Build a precise mental model of the skill before writing a single line.

Ask one cluster at a time (don't dump). Capture answers in your working memory; you'll reuse them in DESIGN.

### 1.1 What workflow are we packaging?

- What does the user do today, step by step?
- Where does it go wrong without the skill (inconsistency, forgotten steps, wasted re-explaining)?
- What is the "good output" they expect (specific, observable)?

### 1.2 Use cases

Nail down 2-3 concrete ones:

```
Use Case: [Name]
Trigger phrase: "user would say…"
Steps: 1. … 2. … 3. …
Tools: built-in or MCP
Success: [specific output or state]
```

If vague, offer examples to react to. Concrete > abstract.

### 1.3 Category

| Category | When to choose |
|---|---|
| Document & Asset Creation | Consistent output generation (reports, slides, code, diagrams) |
| Workflow Automation | Multi-step processes with methodology (planning, onboarding, deploys) |
| MCP Enhancement | Workflow guidance on top of MCP tool access |
| Domain Intelligence | Specialized knowledge (compliance, finance rules, security checks) |

### 1.4 Out of scope (explicit)

List adjacent things this skill must NOT do. Add them to the `Do NOT use for…` clause of the description.

**Exit:** 2-3 use cases, category, out-of-scope list.

---

## Phase 2: DESIGN

**Goal:** Structural decisions before any writing.

### 2.1 Pick a pattern

| Pattern | When |
|---|---|
| Sequential Workflow | Steps have dependencies, ordering is load-bearing |
| Multi-MCP Coordination | Spans multiple external services |
| Iterative Refinement | Quality improves through review-fix cycles |
| Context-Aware Selection | Best tool depends on input properties |
| Domain-Specific Intelligence | Expert rules drive correct execution |

Most skills combine. Identify the **primary** pattern.

### 2.2 Folder layout

```
skill-name/
├── SKILL.md           # Required. Target <500 lines, <5000 tokens.
├── scripts/           # Only if deterministic checks needed
├── references/        # Only if deep content >100 lines
├── assets/            # Only if templates/static resources are used in output
└── evals/             # Optional, for output-quality evaluation
    └── evals.json
```

Decision rules:
- Logic that must be deterministic → `scripts/`
- Reference content >100 lines → `references/`
- Templates/images reused in output → `assets/`
- Everything else → keep in SKILL.md

### 2.3 Map progressive disclosure

| Level | What | Token budget |
|---|---|---|
| L1 Frontmatter | `name` + `description` | ~100 words |
| L2 SKILL.md body | Core workflow, steps, examples | <500 lines |
| L3 Linked files | Deep ref, API docs, large examples | As needed |

SKILL.md must tell the agent **when** to read each linked file. "Read `references/spec.md` if X" beats "see references/".

### 2.4 Draft the description (placeholder, finalize in OPTIMIZE)

Format: `[What] + [Use when, with trigger phrases] + [Do NOT use for]`. ≤1024 chars total.

**Exit:** Pattern, folder layout, L1/L2/L3 map, description draft.

---

## Phase 3: AUTHOR

**Goal:** Write the skill with precision.

### 3.1 Frontmatter hard rules

```yaml
---
name: kebab-case-name           # Must match folder. 1-64 chars, [a-z0-9-], no leading/trailing/consecutive hyphens.
description: >                   # Folded multiline OK; ≤1024 chars; no XML angle brackets.
  What it does. Use when [triggers]. Do NOT use for [exclusions].
license: CC-BY-4.0
metadata:
  version: 1.0.0
  author: your-name-or-org
---
```

Forbidden:
- Spaces or capitals in `name` or folder
- `claude` / `anthropic` reserved terms
- `SKILL.MD`, `Skill.md`, `skill.md` (must be exactly `SKILL.md`)
- XML angle brackets `<` `>` in description
- Description > 1024 characters

### 3.2 Body writing principles

- Imperative form ("Run X", "Check Y"). Specific > verbose.
- Critical rules at the top, not buried in the middle.
- 2-3 concrete examples (input → actions → result).
- Reference files with explicit load conditions.
- For deterministic checks, prefer scripts over prose.
- Do not wrap prose at arbitrary column widths; let sentences flow.
- Code blocks may wrap for readability.

### 3.3 Supporting files

For each `references/*.md` or `scripts/*`:
- Reference it from SKILL.md with a clear WHEN clause.
- For files >300 lines, add a Table of Contents.
- Scripts: see [scripts-guide](references/scripts-guide.md) for PEP 723, agentic design, --help, exit codes.

**Exit:** SKILL.md drafted, all hard rules satisfied, supporting files written.

---

## Phase 4: VALIDATE

**Goal:** Catch structural and spec errors before delivery.

### 4.1 Run the bundled validator

```bash
python3 scripts/validate.py <skill-folder>
# or, with PEP 723 inline dependencies via uv:
uv run --no-project scripts/validate.py <skill-folder>
```

The validator checks: folder kebab-case, SKILL.md exists, frontmatter YAML valid, `name` rules, `description` rules, body line count, examples present, references linked, no XML in description.

Pass = exit code 0. Warnings are allowed. Errors are not.

### 4.2 Spec re-check

Confirm against the full format spec (see [references/spec.md](references/spec.md)):
- `compatibility` field if the skill needs specific environment
- `allowed-tools` field if you want to pre-approve specific tools
- File references are relative to the skill root, one level deep preferred

### 4.3 Trigger sanity

Mentally run 5-10 short prompts. Should trigger; should NOT trigger (near-misses). If the description is too narrow, broaden it; if too broad, add exclusions. Save these prompts — they seed the eval in OPTIMIZE.

For the full eval-driven optimization, proceed to OPTIMIZE.

**Exit:** Validator PASS + spec check + trigger sanity.

---

## Phase 5: OPTIMIZE

**Goal:** Make the skill trigger reliably and prove it improves output quality.

Two eval loops, run in this order:

### 5.1 Description triggering eval

Open [description-optimization](references/description-optimization.md).

Write ~20 eval queries (8-10 should-trigger, 8-10 should-NOT-trigger), emphasizing near-misses. Split 60/40 into `train_queries.json` and `validation_queries.json`. Run the trigger script 3x per query. Iterate on the description (using only the train set) until stable. Select the best iteration by validation pass rate.

### 5.2 Output-quality eval (optional, recommended for workflow skills)

Open [output-evaluation](references/output-evaluation.md).

Build `evals/evals.json` with 2-3 test cases. Run each twice (with-skill, without-skill) into `iteration-1/`. Add assertions, grade, aggregate to `benchmark.json`. Iterate the skill body based on failed assertions and human review. Stop when pass rate plateaus or feedback is empty.

**Exit:** Description eval pass rate ≥0.5 on validation set; output eval (if run) shows skill adds value.

---

## Phase 6: DELIVER

**Goal:** Install + register.

### 6.1 Local install

Drop the skill into the right skills directory for the target agent:

| Agent | Path |
|---|---|
| VS Code + Copilot | `.agents/skills/` |
| Claude Code | `.claude/skills/` |
| Cursor | `.cursor/skills/` |
| OpenCode | `.opencode/skill/` |

Optionally add a slash command to the agent's command file (e.g. `/forge`) so the trigger works without typing a long phrase.

### 6.2 For catalog publication

1. Add a row to the catalog's index (package README) with version, description, main trigger, and link to the skill's README.
2. Create a release note in whatever format the catalog uses (changeset, changelog entry, release tag, etc.).
3. Bump the skill's own `metadata.version` to match the release.
4. Publish through whatever distribution mechanism the catalog uses (npm package, git tag, registry upload).

### 6.3 For distribution elsewhere

Keep the skill self-contained. Make sure the skill folder is at a path the target agent scans. Include a top-level human-facing README alongside the skill folder (not inside it).

**Exit:** Skill installed, registered, and a test prompt verifies triggering in the target agent.

---

## Bundled resources

- **[references/spec.md](references/spec.md)** — the open SKILL.md format reference.
- **[references/authoring-patterns.md](references/authoring-patterns.md)** — best practices: gotchas, templates, checklists, validation loops, plan-validate-execute, calibrating control.
- **[references/description-optimization.md](references/description-optimization.md)** — trigger eval methodology with train/val split.
- **[references/output-evaluation.md](references/output-evaluation.md)** — output-quality eval: with-skill vs without-skill, assertions, benchmark.
- **[references/scripts-guide.md](references/scripts-guide.md)** — using scripts in skills: PEP 723, agentic script design, --help, exit codes.
- **[scripts/validate.py](scripts/validate.py)** — stdlib-only validator; `--json-out` for agentic consumption.
- **[assets/SKILL.template.md](assets/SKILL.template.md)** — blank template for new skills.

## Anti-patterns to avoid

- ❌ Vague description: "Helps with documents."
- ❌ Verbose body the agent will skim.
- ❌ No examples.
- ❌ Wrong `SKILL.md` casing.
- ❌ Spaces or capitals in folder or name.
- ❌ `claude` or `anthropic` in the name.
- ❌ XML angle brackets in description.
- ❌ SKILL.md > 500 lines (move detail to references/).
- ❌ Description > 1024 chars.
- ❌ Claiming to be the only skill loaded (skills compose).
- ❌ Re-explaining what the agent already knows (PDFs, HTTP, etc.).
- ❌ Referencing internal projects, packages, or repos by name in the skill body.
