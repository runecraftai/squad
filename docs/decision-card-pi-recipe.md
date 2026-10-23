# Decision Card Pi Recipe (Optional)

This document describes how pi sessions could optionally use the rpiv extension for richer interactive decision dialogs while everything else stays harness-agnostic.

## Overview

The `@juicesharp/rpiv-ask-user-question` pi extension provides native terminal dialogs with:
- Up to 4 questions per dialog
- 2-4 authored options with descriptions
- Typed free-text row
- Markdown previews
- Submit tab summary

This is richer than the basic `sq-ask.sh` picker, so pi sessions may want to use it when available.

## Integration Approach

### Option 1: Skill-Based Approach (Recommended)

Create a pi skill that wraps decision card presentation:

```markdown
---
name: decision-card
description: Present decision cards using rpiv extension when available
---

When presenting a decision card to the commander:
1. Check if rpiv extension is available
2. If yes, transform card JSON to rpiv format and use ask_user_question
3. If no, show the prose block from `sq-ask.sh --render` and resolve the typed reply with `sq-ask.sh --answer`
```

### Option 2: Transparent Fallback

The simplest approach: always use sq-ask.sh, but document that pi users can install rpiv for richer UX.

## rpiv Extension Format Reference

The rpiv extension expects:

```json
{
  "questions": [
    {
      "question": "How should we merge?",
      "options": [
        {"label": "Squash", "description": "Combine commits"},
        {"label": "Rebase", "description": "Preserve history"}
      ],
      "notes": "Choose carefully",
      "required": true
    }
  ]
}
```

Mapping from decision card:
- `card.question` → `questions[0].question`
- `card.options[].label` → `questions[0].options[].label`
- `card.options[].description` → `questions[0].options[].description`
- `card.context` → `questions[0].notes`
- `card.allow_free_text` → rpiv always allows free text

## Implementation Notes

This is an optional enhancement. The core decision card standard works without it:

- `sq-ask.sh` works from any shell
- The text format works in any chat
- The JSON format enables future tooling

The pi recipe is documented here for completeness but should not be built unless:
1. The commander explicitly requests it
2. The rpiv extension is already installed in target environments
3. A native dialog adds clear value over text-based answers

## Recommendation

Start with the harness-agnostic approach (sq-ask.sh prose rendering and `--answer`). Monitor whether pi users frequently want richer interactive dialogs. If demand emerges, scope a native dialog integration as a separate task.
