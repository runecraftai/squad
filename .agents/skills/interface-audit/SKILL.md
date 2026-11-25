---
name: interface-audit
description: Audit an interface and design system that already exist before changing them, covering reusable components, tokens in use, navigation conventions, inconsistencies, duplications, and divergences between design and shipped code. Use when designing, before touching an existing product's interface; not for judging an artifact you just produced.
user-invocable: false
metadata:
  internal: true
---

# interface-audit

Use this skill before designing anything that has to fit an existing product.
Its job is to describe what already exists well enough that the design work starts from fact instead of assumption.

## Inventory

Cover all seven, and name the surface every entry belongs to.

1. Surfaces: every screen, route, and stateful view the product actually ships, with the file or route that renders it.
2. Components: the reusable ones, how many call sites each has, and which duplicates exist under different names.
   Reuse count is the finding; a component used once is a candidate, not a system.
3. Tokens in use versus tokens declared: which color, spacing, radius, type, and elevation values appear in real markup, and which declared tokens nothing consumes.
   The declared-but-unused list is as valuable as the used-but-undeclared one.
4. Navigation and layout conventions: how the product moves between views, the shell shape, the breakpoints, and the grid measures that repeat.
5. States that exist: loading, empty, error, disabled, focus, long content, and permission-limited views, per surface.
6. Accessibility and responsive defects: contrast, focus order, keyboard reach, hit targets, overflow, and narrow-width breakage.
7. Design-to-code divergence: every place a design file and the shipped code disagree, with each side referenced by file, page, or frame.

## Evidence every finding

State a measurable claim and the artifact that proves it, one line each.

| Claim shape | Proof it needs |
| --- | --- |
| "The primary button appears on 14 screens" | the call sites, or the command that counts them and its output |
| "Three near-identical card components exist" | each file, plus what makes them near-identical |
| "Token `--color-accent` is declared and unused" | the declaration, plus the empty search result |
| "Narrow width overflows at the filter row" | the capture at that viewport, with the width and the command used |
| "Design shows a two-column form, code ships one column" | the frame reference and the component file |

A finding without a file, screen, or capture path is an opinion: mark it as one, or drop it.

## Preserve what is consolidated

Prefer the existing pattern when the product uses it consistently.
Replacing or consolidating it needs a stated reason: an inconsistency it causes, a defect it produces, or a requirement it cannot meet.
Record that reason beside the recommendation, so the next reader can disagree with the reason instead of repeating the inventory.

## Boundary

Quality judgement of an artifact someone just produced belongs to the QA phase, not here.
This skill describes what exists and where it diverges; it does not rate a fresh design.
Generic UI review is owned by the `design-review` skill and accessibility review by `accessibility-compliance`, both installed as machine skills under `~/.agents/skills/` rather than shipped by this repository; point at them instead of restating their checks, and when one is absent record the capability as unavailable and stop.
