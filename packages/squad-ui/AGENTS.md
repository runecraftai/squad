# Squad UI — Coding Rules

## Architecture

- **FSD v2.1** (Feature-Sliced Design) — seguir https://fsd.how
- **Stack:** Bun + TypeScript (bridge), React 19 + Vite + Tailwind (frontend)
- **Monorepo:** `packages/squad-ui/` com `bridge/` e `web/`

## Structure

```
packages/squad-ui/
├── bridge/              # Backend Bun
│   └── src/
│       ├── api/             # HTTP API routes
│       ├── adapters/        # tmux, orca, herdr adapters
│       ├── state/           # Unit snapshot service
│       └── commands/        # Command gateway
├── web/                 # Frontend React
│   └── src/
│       ├── app/         # Providers, router, global config
│       ├── pages/       # Routes (Dashboard, TaskDetail, Backlog)
│       ├── features/    # User interactions (DispatchTask, RespondDecision)
│       ├── entities/    # Domain models (Task, Backlog, Project, XO)
│       └── shared/      # UI components, API client, hooks, lib
└── package.json
```

## FSD Rules

- **Layer hierarchy:** app > pages > features > entities > shared
- **Import rule:** lower layers never import from higher layers
- **Public API:** each slice exposes only `index.ts`
- **No widget layer** — pages compose features directly
- **Pages-first:** start with app/, pages/, shared/; open features/entities only when stable shared responsibility earns it

## Naming

- **Components:** `kebab-case` (e.g., `task-card.tsx`, `status-badge.tsx`)
- **Files:** `kebab-case.ts` / `kebab-case.tsx`
- **Types/Interfaces:** `PascalCase` (e.g., `TaskStatus`, `BacklogItem`)
- **Functions:** `camelCase` (e.g., `fetchTask`, `parseStatus`)
- **Constants:** `UPPER_SNAKE_CASE` (e.g., `API_BASE_URL`)

## Code Style

- **Early returns:** always prefer early returns to reduce cyclomatic complexity
- **No `any`:** use `unknown` + type guards when type is uncertain
- **Business rules outside React:** pure functions in `shared/lib/` or `entities/`
- **Components:** thin — delegate logic to hooks or lib functions
- **React Query** for server state, not local state

## Validation

- **Oxlint** for deterministic lint rules
- **TypeScript strict mode** — no implicit any, strict null checks
- **Vitest** for unit tests, **Playwright** for E2E

## Commit Convention

- Conventional Commits: `feat:`, `fix:`, `chore:`, `refactor:`, `test:`
- Format: `type(scope): description`
- Example: `feat(dashboard): add task status cards`

## PR Convention

- Branch: `feat/task-dashboard`, `fix/status-polling`
- Title matches commit convention
- Description: what changed + why
- Drill required before merge

## Imports

```typescript
// ✅ Good — lower layer imports shared
import { Button } from '@/shared/ui';
import { fetchTask } from '@/shared/api';

// ❌ Bad — higher layer imports from lower
// pages/ should not import from features/
// features/ should not import from pages/
```

## Early Returns

```typescript
// ✅ Good — early return
function getStatus(task: Task): string {
  if (!task) return 'unknown';
  if (task.failed) return 'failed';
  if (task.running) return 'running';
  return 'idle';
}

// ❌ Bad — nested if/else
function getStatus(task: Task): string {
  if (task) {
    if (task.failed) {
      return 'failed';
    } else if (task.running) {
      return 'running';
    } else {
      return 'idle';
    }
  }
  return 'unknown';
}
```

## Business Rules Outside React

```typescript
// ✅ Good — pure function in shared/lib/
export function calculateDuration(start: Date, end: Date): number {
  return end.getTime() - start.getTime();
}

// In component:
import { calculateDuration } from '@/shared/lib/duration';
const duration = calculateDuration(task.startedAt, task.completedAt);
```
