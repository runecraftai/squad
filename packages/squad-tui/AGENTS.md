# Project agent memory

This file is the project's committed base for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.
- Bun must resolve to `>=1.3.0` (`.bun-version` pins `1.4.2`).
- Every script must be invoked as `bun --bun run <script>`, never the bare `bun run <script>`; see `README.md` "Toolchain" for why.
- `import { z } from "zod"` resolves `z` to `undefined` inside a Vitest-transformed module under this zod/Vitest combination, even though Bun's own native resolver exposes it fine.
- Use `import * as z from "zod"` for every runtime (value) import instead; `import type { z } from "zod"` is unaffected since type-only imports are erased before this resolution ever runs.
- `src/contracts/` holds the versioned schemas: sessions, mission/stage projections, transcript, extension UI, adapter capabilities, and the service-exclusivity lock.
- Those contracts consume the shared Squad/Hugin API contract (`squad-hugin-adapter-api`, not yet implemented) and never redefine task mutations.
- Mission/stage schemas reference existing task/attempt identities and mint no new authoritative store.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
