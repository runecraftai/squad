# Execution profile: `react@1`

## Accepted brief form

This profile accepts `strike` only, for React SPA work using TanStack Router with code-based routes, not Next.js.
It attaches to the playbook that owns the task's sequence, completion evidence, stop condition, and delivery; this profile adds only the React constraints below.
Read the sequence below as the constraint checkpoints this profile contributes to that playbook's steps, never as a second method.
It materializes the commander's standard from Career Coach's `apps/web/AGENTS.md` and its repo-root `AGENTS.md`, with decisions D1-D3 below.
The executor receives this contract in the brief and need not retrieve those source files.
Selection is explicit; this contract does not automatically classify or dispatch React tasks.

## Required sequence

1. State the requested behavior, affected routes, data contracts, and authorized surface before implementation.
2. Map changed modules to the D1 layers and identify import boundaries, hooks, pure functions, and component responsibilities before editing.
3. Implement one vertical slice using the architecture, naming, routing, query, and state rules below.
4. Record the D3 proposal's approval disposition; implement only approved lint changes within the task's scope, retaining existing architecture enforcement.
5. Run focused behavior tests, type checking, and the applicable lint commands; exercise the affected user flow on the real surface, including rejected and error paths.
6. Record completion evidence outside the project repository and leave review, fixes, delivery, approval, and merge to the existing strike lifecycle and drill owner.

## D1: classic FSD layers

Use `src/app > pages > widgets > features > entities > shared`, not a flattened or Next.js layout.
Create only the layers and slices the task needs.

| Layer | Responsibility |
| --- | --- |
| `app` | Bootstrap, providers, router, and application composition. |
| `pages` | Route-level screen composition. |
| `widgets` | Reusable compositions of features and entities. |
| `features` | User-action flows and their model hooks. |
| `entities` | Domain data, API/query models, and entity presentation. |
| `shared` | Domain-independent UI, infrastructure, and pure helpers. |

Imports may point downward, never upward.
The source boundaries configuration allows same-layer imports; preserve its explicit policy rather than silently imposing a different slice policy.
Enforce the six layer patterns with `eslint-plugin-boundaries` and `boundaries/element-types`, `default: disallow`, allowing each layer itself and the layers below it.
Resolve aliases correctly so the lint check catches real imports, not only relative paths.
Preserve the source exclusions for tests, specs, test directories, and declaration files where applicable; do not broaden them to hide production violations.
Do not assume oxlint replaces this boundaries check.

## D2: naming and component responsibility

Files and folders are kebab-case; component names in those files are PascalCase.
For example, `sign-in-form.tsx` exports `function SignInForm(...)`, never `const SignInForm = (...) => ...`.
Use named function declarations for components, including a named function when a wrapper such as `memo` is needed; do not use anonymous components or arrow-function components.
This restriction concerns components, not every callback or hook.
Leave legacy non-kebab paths alone unless the task requires a rename; every new path and rename follows the rule.

Components render markup, consume ready data from props/hooks, attach user-event handlers, and hold only local visual state such as fields, an open modal, or an active tab.
They do not perform business flows, server interactions, validation, derivations, or presentation mappings inline.
Put flows and server orchestration in hooks in a nearby `model.ts` module within the owning feature/page or entity.
Put mappings, validation, input selection, and error normalization in pure `.ts` functions with zero React imports, testable without rendering.
A submit flow belongs in a hook; the component wires its controlled inputs and submit handler to that hook's values and actions.
Do not move unrelated business logic into `shared` merely to empty a component.

## Router, queries, and state

- Compose the code-based TanStack Router tree in `src/app/routes.tsx`, adapting only the project source-root prefix.
- Implement route guards with `beforeLoad` and `throw redirect`; resolve the required session before entering protected routes using the project's session helper, such as `ensureSession()`.
- Keep business navigation flows in model hooks, not component bodies; preserve loading, unauthenticated, and failure behavior.
- Keep server state in TanStack Query and the shared client configuration in `shared/lib/react-query.ts`; reuse the project's query keys, API/query modules, and mutation invalidation conventions.
- After a mutation, invalidate the affected server data through TanStack Query rather than maintaining a second component/global-store cache.
- Default to hooks and props for client state; use Zustand for new global stores only when a store pattern is genuinely necessary.
- Preserve the documented existing session-store exception (`createStore` + `useSelector` using `useSyncExternalStore`); it is not the default for new stores and does not authorize a migration.
- Use native HTML controls plus Zod validation for simple forms, without a forms library; use React Hook Form for complex forms.

## D3: proposed amalgamated oxlint rules

This is a proposal for commander deliberation, not an approved configuration or permission to install or replace project tooling.
Each row is individually reviewable; record accepted, rejected, or pending decisions rather than silently adopting another repository's preset.
The candidate configuration combines hook correctness, component declarations, reconciliation, JSX correctness, unsafe rendering, and refresh boundaries using oxlint's native `react` plugin.
Enable these explicit rules rather than every React rule or a Next.js preset.

| Candidate rule | Proposed severity/options | Why it exists |
| --- | --- | --- |
| `react/rules-of-hooks` | `error` | Reject invalid hook placement and ordering. |
| `react/exhaustive-deps` | `error` | Catch stale closures and incomplete effect/memo dependencies instead of hiding them with suppressions. |
| `react/function-component-definition` | `error`, `namedComponents: function-declaration` | Enforce D2's declaration form for named components; unnamed components still require inspection. |
| `react/no-unstable-nested-components` | `error` | Prevent component identity recreation and state loss during a parent render. |
| `react/jsx-key` | `error` | Require keys for rendered collection children. |
| `react/no-array-index-key` | `error` | Avoid incorrect state association when lists are reordered or edited. |
| `react/jsx-no-duplicate-props` | `error` | Reject accidentally overwritten JSX inputs. |
| `react/jsx-no-undef` | `error` | Catch unresolved JSX component references. |
| `react/no-children-prop` | `error` | Avoid competing child definitions; use JSX nesting. |
| `react/no-danger` | `error` | Flag raw HTML injection for explicit security scrutiny. |
| `react/no-danger-with-children` | `error` | Reject conflicting raw HTML and JSX children. |
| `react/jsx-no-script-url` | `error` | Reject executable JavaScript URLs in JSX. |
| `react/jsx-no-target-blank` | `error` | Guard external new-tab links against unsafe opener access. |
| `react/only-export-components` | `warn`, `allowConstantExport: true` | Keep refresh boundaries reliable while retaining the source's constant-export allowance. |

Candidate `.oxlintrc.json` rule block, to merge only after approval and compatibility checks:

```json
{
  "plugins": ["react"],
  "rules": {
    "react/rules-of-hooks": "error",
    "react/exhaustive-deps": "error",
    "react/function-component-definition": ["error", { "namedComponents": "function-declaration" }],
    "react/no-unstable-nested-components": "error",
    "react/jsx-key": "error",
    "react/no-array-index-key": "error",
    "react/jsx-no-duplicate-props": "error",
    "react/jsx-no-undef": "error",
    "react/no-children-prop": "error",
    "react/no-danger": "error",
    "react/no-danger-with-children": "error",
    "react/jsx-no-script-url": "error",
    "react/jsx-no-target-blank": "error",
    "react/only-export-components": ["warn", { "allowConstantExport": true }]
  }
}
```

Check rule IDs and options against the project's installed oxlint version before enabling them; unsupported rules are a named gap, not a reason to drop checks silently.
Do not erase existing plugins, overrides, or ignore patterns when merging approved rules.
Keep ESLint boundaries and any other checks without equivalent oxlint coverage.
Lint cannot prove kebab-case folders, PascalCase names, absence of anonymous/wrapped arrow components, pure-function isolation, or absence of business logic in components merely by enabling this block.
Inspect those requirements explicitly and record concrete file/function evidence; do not claim automated coverage that was not exercised.
Pending D3 deliberation does not waive D1/D2 or existing lint checks and does not block unrelated React work; stop for a decision if the authorized task depends on changing the lint policy.

## What this profile does not decide

The state defaults and form choices above are settled by the source standard; an alternative global-state library requires a separate decision rather than executor preference.
This contract does not choose a styling system or test runner, neither of which the source standard settles as a general React rule.
Retain the target project's tools and conventions; do not transplant Career Coach's product routes, API details, workspace commands, coverage thresholds, or styling tokens.
It does not authorize a framework migration, broad legacy renaming, a store rewrite, or deployment changes.

## Required evidence

Write a `# react profile evidence` section in a Markdown file under the Squad base's `data/<id>/artifacts/`, never in the project repository.
Begin that file with exactly the `# react profile evidence` heading, because `bin/sq-playbook-validate.sh` adopts the first artifact it finds whose headings include `checklist` or an `@version` token.
Never repeat the brief's profile identity heading, in its `# Execution profile:` plus `react@1` form or any other version-tagged form, in this file: such a heading can make the gate adopt this profile record as the playbook's completion artifact and fail an otherwise complete paired task.
Keep every heading in this file free of `@` version tokens so the profile record cannot be selected as a checklist.
Record five numbered `## Evidence N` sections, each naming the concrete `path:` or command with its result that a reviewer can check; a profile requires no separately validated checklist of its own.
The labels below name the evidence this profile records.
The attached playbook owns the completion gate, so a passing `bin/sq-playbook-validate.sh` run does not prove these records and its structural success proves neither architectural nor runtime correctness.

1. **architecture**: changed modules mapped to layers, import directions, and boundaries check command/result, including unchanged architecture where relevant.
2. **components**: changed named functions and kebab-case paths, hooks owning flows, and pure functions with zero React imports, with concrete inspection evidence.
3. **router and queries**: exactly one routing record and exactly one queries record in this grammar, where the label and the state token are case-insensitive:

   ```
   Routing: <changed|unchanged> - <free text>
   Queries: <changed|unchanged> - <free text>
   ```

   Write each record as a plain line beginning, after optional whitespace, with `Routing:` or `Queries:`; do not prefix Markdown list markers or emphasize the labels.
   No mechanical gate inspects these records for a paired brief, so the reviewing operator checks that each label appears once with a `changed` or `unchanged` state, a `-` separator, and nonblank free text, then reads the free text for code-based routing, guards, invalidation, wording, case, and word order, so changed read-only queries pass on their own terms without a fabricated `unchanged` claim or mandatory invalidation wording.
   Put the concrete path, command, and result in the free text; justify an unchanged dimension there rather than asserting it without evidence.
4. **lint**: the proposal's per-rule rationale and approval disposition, pending deliberations, retained checks, and command/results for any approved configuration actually applied.
5. **behavior**: focused test command/results plus the real user surface exercised, including loading, error, and rejected paths applicable to the task.

## Exit predicate

The authorized React behavior works on the real surface, all five evidence areas have concrete evidence, and applicable type, lint, and focused behavior checks pass.
Unchanged surfaces are justified rather than fabricated, and any pending D3 deliberation is explicit without being represented as an adopted configuration.
The existing delivery path remains the authority for review, fixes, tests, delivery, approval, and merge.
Read this predicate together with the stop conditions below as this profile's satisfaction and escalation conditions inside the attached playbook's exit and stop rules, never as a second terminal authority.

## Stop conditions

Stop when the requested surface is unreachable, the project contradicts D1/D2 or requires a different router/framework, required checks cannot run, or an unapproved design or lint-policy change is necessary.
Name the conflict and request a decision instead of silently migrating, weakening a rule, or extending scope.

## Anti-patterns

Do not put business logic back in JSX, use effects as a substitute for the query layer, mirror server state into stores, flatten the layers, or replace code-based routing with file routes.
Do not treat the proposed oxlint block as commander approval or pretend lint alone proves the component-responsibility contract.
Do not commit Squad profile evidence or create playbook-owned review, delivery, approval, or terminal authority.
