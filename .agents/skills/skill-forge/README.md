<p align="center">
  <img src="https://img.shields.io/badge/Skill-skill--forge-blue?style=for-the-badge" alt="skill badge" />
  <img src="https://img.shields.io/badge/Stack-Agnostic-green?style=for-the-badge" alt="stack agnostic" />
  <img src="https://img.shields.io/badge/Version-1.0.0-purple?style=for-the-badge" alt="version" />
</p>

<h1 align="center">🛠️ skill-forge</h1>

<p align="center">
  <strong>Meta-skill for creating new Agent Skills from scratch — aligned with the open SKILL.md format.<br/>Discover → Design → Author → Validate → Optimize → Deliver.</strong>
</p>

---

## ✨ What Is This Skill?

**skill-forge** turns an idea into a publishable Agent Skill. It walks you through the full lifecycle, end to end, with explicit exit criteria and a bundled validator. Every output conforms to the open SKILL.md format (YAML frontmatter + Markdown body, progressive disclosure, validation loops), so the skills you create trigger reliably across Claude Code, Cursor, GitHub Copilot, OpenCode, and other compatible agents.

```
DISCOVER → DESIGN → AUTHOR → VALIDATE → OPTIMIZE → DELIVER
   ↑                                              │
   └──────────── iterate on OPTIMIZE ────────────┘
```

- **DISCOVER** — capture use cases, category, out-of-scope list.
- **DESIGN** — pick a pattern, folder layout, progressive-disclosure map, description draft.
- **AUTHOR** — frontmatter per spec, body, supporting files.
- **VALIDATE** — bundled `scripts/validate.py` + spec re-check + trigger sanity.
- **OPTIMIZE** — description triggering eval (train/val split) + output-quality eval (with-skill vs without-skill).
- **DELIVER** — install into the target agent's skills directory; register in catalog if applicable.

---

## 🚀 Quick Start

### Installation

Install manually by copying `skills/skill-forge/` into your agent's skills directory, or use the `grimoire` installer TUI shipped with the package (see the [catalog README](../../README.md)):

| Agent | Path |
|---|---|
| VS Code + Copilot | `.agents/skills/skill-forge/` |
| Claude Code | `.claude/skills/skill-forge/` |
| Cursor | `.cursor/skills/skill-forge/` |
| OpenCode | `.opencode/skill/skill-forge/` |

Optionally add a slash command (`/forge`) to the agent's command file so the trigger works without typing a long phrase.

### How to use it

1. Open your agent in agentic mode.
2. Invoke `/forge` (or describe your intent: "create a skill that does X").
3. Answer the discovery questions one cluster at a time.
4. The skill will draft, validate, and (if you wish) optimize the new skill.
5. At the **DELIVER** step, the new skill lands in the right directory and (if publishing) gets a catalog row and a release note.

### Minimal example

> "I keep explaining how to onboard new engineers at our company. Make a skill that captures the standard process."

The agent will:

1. Ask 4-6 discovery questions (audience, what goes wrong without the skill, success criteria).
2. Propose a pattern (likely Sequential Workflow) and folder layout.
3. Draft `SKILL.md` + any needed `references/` or `scripts/`.
4. Run the bundled validator until it PASSes.
5. Hand you a test prompt to verify triggering in your agent.

---

## 📁 Anatomy

```
skill-forge/
├── SKILL.md                            # The 6-phase workflow (agent instructions)
├── README.md                           # This file (human-facing, outside agent context)
├── references/
│   ├── spec.md                         # open SKILL.md format specification
│   ├── authoring-patterns.md           # Best practices: gotchas, templates, validation loops
│   ├── description-optimization.md     # Trigger eval with train/val split
│   ├── output-evaluation.md            # With-skill vs without-skill quality eval
│   └── scripts-guide.md                # PEP 723, agentic script design, --help, exit codes
├── scripts/
│   └── validate.py                     # Stdlib-only spec validator (PEP 723 friendly)
└── assets/
    └── SKILL.template.md               # Blank template for new skills
```

The validator is intentionally stdlib-only and PEP 723 declared, so it runs with no install step:

```bash
python3 scripts/validate.py path/to/new-skill
uv run --no-project scripts/validate.py path/to/new-skill
```

Exit code 0 = pass (warnings allowed). Exit code 1 = format violation.

---

## 📐 Conformance to the open SKILL.md format

| Spec field | skill-forge value |
|---|---|
| `name` | `skill-forge` (kebab-case, matches folder) |
| `description` | 1024-char max, EN+PT triggers, explicit exclusions |
| `license` | `CC-BY-4.0` |
| `metadata.version` | `1.0.0` |
| Frontmatter delimiters | Exactly `---` on their own lines |
| `SKILL.md` casing | Exact |
| Body length | Under the 500-line cap |

Run the validator against itself to confirm:

```bash
python3 skills/skill-forge/scripts/validate.py skills/skill-forge
```

Expected: `PASS — N checks passed`.

---

## 🤖 Compatibility

| Agent | Status |
|---|---|
| Claude Code | ✅ Tested |
| OpenCode | ✅ Tested |
| Cursor | ✅ Tested |
| GitHub Copilot | ✅ Tested |
| Antigravity (Gemini) | ✅ Tested |

Works with any agent that follows the open SKILL.md format.

---

## 📥 See also

- [references/spec.md](references/spec.md) — the open SKILL.md format reference bundled in this skill.
- [references/authoring-patterns.md](references/authoring-patterns.md) — best practices for skill bodies (calibrating control, gotchas, templates, validation loops).
- [references/description-optimization.md](references/description-optimization.md) — eval-driven triggering improvement.
- [references/output-evaluation.md](references/output-evaluation.md) — proving a skill improves output quality.

---

## 📦 Catalog

This skill is part of the [Grimoire](https://github.com/runecraftai/skills) catalog, distributed via the [`@runecraft/grimoire`](https://www.npmjs.com/package/@runecraft/grimoire) npm package.

---

## 📄 License

CC-BY-4.0
