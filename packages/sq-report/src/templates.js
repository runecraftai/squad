// Owns the `sq-report new` starter-artifact templates: the token kits and the
// playbook-aligned snippets the scaffold command writes out. Kinds and kits are
// listed here once; DESIGN_SYSTEM_HINT and the `sq-report design` output embed or
// point at them (src/design-reference.js). The queuePrompt decision form and the
// @pierre/diffs code snippet are imported from src/playbooks.js, so the templates
// render the same bytes the playbooks document and cannot drift from them.
//
// NOTE: this module imports from ./design-reference.js, which imports TEMPLATE_KINDS
// and TOKEN_KITS back from here. The cycle is intentional and safe: both modules read
// the other's exports only inside function bodies, never at module-evaluation time.

import {
  DESIGN_CDN_SNIPPET,
  DESIGN_CDN_URLS,
  LAYOUT_SAFETY_CSS_SNIPPET,
  MERMAID_CDN_SNIPPET,
} from "./design-reference.js";
import { CODE_DIFF_SNIPPET, INPUT_DECISION_FORM_SNIPPET } from "./playbooks.js";

export const TOKEN_KITS = [
  {
    id: "daisyui",
    name: "DaisyUI luxury (default)",
    description:
      'Tailwind CSS browser runtime v4 + DaisyUI v5 loaded from CDN, with data-theme="luxury" on the html element. This is the sq-report default design fallback; it needs network access and the DaisyUI component class reference assumes this CDN runtime.',
    default: true,
  },
  {
    id: "shadcn",
    name: "shadcn-style tokens (career-coach)",
    description:
      "Light/dark design tokens (--background/--foreground/--card plus verdict colors) mapped to Tailwind utilities via @theme inline, like the career-coach artifacts. Uses the same Tailwind browser runtime as the daisyui kit through a proper script tag, so it also needs network access.",
  },
  {
    id: "sq-report",
    name: "sq-report brand tokens (self-contained)",
    description:
      "Compiled plain CSS distilled from the internal sq-report-design colors_and_type.css (ink/steel/cream/brass surfaces). No runtime, no CDN: the file renders fully offline and export-inlines completely. It is NOT interchangeable with the CDN kits - DaisyUI component classes and Tailwind utilities are not available here.",
  },
];

export const TEMPLATE_KINDS = [
  {
    id: "base",
    title: "sq-report starter artifact",
    eyebrow: "sq-report starter",
    lede: "A minimal painted starter artifact - replace the placeholder content below with the real content.",
    use_when: "any artifact: a minimal painted starter you fill in",
    playbook: null,
    render: (kit) => baseSections(kit),
  },
  {
    id: "decision",
    title: "Decisions for review",
    eyebrow: "input playbook",
    lede: "Choose an option per decision; selections stay local until you send them from the sq-report panel.",
    use_when: "collect a structured decision or choice from the reviewer",
    playbook: "input",
    render: (kit) => decisionSections(kit),
  },
  {
    id: "comparison",
    title: "Options and tradeoffs",
    eyebrow: "comparison playbook",
    lede: "Name the decision at the top; compare concrete behavior per side, with the cost as visible as the benefit.",
    use_when: "show options, tradeoffs, or current vs target behavior",
    playbook: "comparison",
    render: (kit) => comparisonSections(kit),
  },
  {
    id: "table",
    title: "Evidence table",
    eyebrow: "table playbook",
    lede: "Scan-friendly records with the primary status visible at a glance.",
    use_when: "turn dense records into a scan-friendly table",
    playbook: "table",
    render: (kit) => tableSections(kit),
  },
  {
    id: "plan",
    title: "Plan for review",
    eyebrow: "plan playbook",
    lede: "Goal, current state, desired behavior, proposed approach, and open questions.",
    use_when: "present a product or technical plan before implementation",
    playbook: "plan",
    render: (kit) => planSections(kit),
  },
  {
    id: "code",
    title: "Code review",
    eyebrow: "code playbook",
    lede: "Rendered source, files, and diffs through @pierre/diffs.",
    use_when: "render source code, files, or diffs",
    playbook: "code",
    render: (kit) => codeSections(kit),
  },
  {
    id: "diagram",
    title: "Architecture / flow",
    eyebrow: "diagram playbook",
    lede: "Lead with the question the diagram answers, then the core relationship.",
    use_when: "map relationships, flows, state, or architecture",
    playbook: "diagram",
    render: (kit) => diagramSections(kit),
  },
  {
    id: "slides",
    title: "Presentation",
    use_when: "create a deliberate presentation deck",
    playbook: "slides",
    header: false,
    footer: false,
    containerClass: false,
    render: (kit) => slidesSections(kit),
  },
];

export function resolveTemplateKind(id) {
  return TEMPLATE_KINDS.find((kind) => kind.id === id) || null;
}

export function resolveTokenKit(id) {
  return TOKEN_KITS.find((kit) => kit.id === id) || null;
}

// The shadcn-style token block extracted from the career-coach artifacts: HSL tokens in
// :root and a .dark override, mapped to Tailwind utilities via @theme inline. Two
// corrections vs the original artifact: the Tailwind runtime loads through a proper
// <script> tag (never a <link rel="stylesheet"> pointing at a .js file), and the token
// block lives in a plain <style> so the page paints even before the runtime compiles.
const SHADCN_TOKENS = `:root {
  --background: hsl(0 0% 100%);
  --foreground: hsl(222 47% 11%);
  --card: hsl(0 0% 100%);
  --card-foreground: hsl(222 47% 11%);
  --popover: hsl(0 0% 100%);
  --popover-foreground: hsl(222 47% 11%);
  --primary: hsl(222 47% 11%);
  --primary-foreground: hsl(210 40% 98%);
  --secondary: hsl(210 40% 96%);
  --secondary-foreground: hsl(222 47% 11%);
  --muted: hsl(210 40% 96%);
  --muted-foreground: hsl(215 16% 47%);
  --accent: hsl(210 40% 96%);
  --accent-foreground: hsl(222 47% 11%);
  --destructive: hsl(0 84% 60%);
  --destructive-foreground: hsl(210 40% 98%);
  --border: hsl(214 32% 91%);
  --input: hsl(214 32% 91%);
  --ring: hsl(222 47% 11%);
  --radius: 0.5rem;
  --verdict-pass: hsl(142 71% 45%);
  --verdict-warn: hsl(38 92% 50%);
  --verdict-fail: hsl(0 84% 60%);
}

.dark {
  --background: hsl(222 47% 7%);
  --foreground: hsl(210 40% 98%);
  --card: hsl(222 44% 10%);
  --card-foreground: hsl(210 40% 98%);
  --popover: hsl(222 44% 10%);
  --popover-foreground: hsl(210 40% 98%);
  --primary: hsl(210 40% 98%);
  --primary-foreground: hsl(222 47% 11%);
  --secondary: hsl(217 33% 17%);
  --secondary-foreground: hsl(210 40% 98%);
  --muted: hsl(217 33% 17%);
  --muted-foreground: hsl(215 20% 65%);
  --accent: hsl(217 33% 17%);
  --accent-foreground: hsl(210 40% 98%);
  --destructive: hsl(0 63% 45%);
  --destructive-foreground: hsl(210 40% 98%);
  --border: hsl(217 33% 20%);
  --input: hsl(217 33% 20%);
  --ring: hsl(213 27% 84%);
}`;

const SHADCN_THEME_MAPPING = `@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --color-card: var(--card);
  --color-card-foreground: var(--card-foreground);
  --color-popover: var(--popover);
  --color-popover-foreground: var(--popover-foreground);
  --color-primary: var(--primary);
  --color-primary-foreground: var(--primary-foreground);
  --color-secondary: var(--secondary);
  --color-secondary-foreground: var(--secondary-foreground);
  --color-muted: var(--muted);
  --color-muted-foreground: var(--muted-foreground);
  --color-accent: var(--accent);
  --color-accent-foreground: var(--accent-foreground);
  --color-destructive: var(--destructive);
  --color-destructive-foreground: var(--destructive-foreground);
  --color-border: var(--border);
  --color-input: var(--input);
  --color-ring: var(--ring);
  --color-verdict-pass: var(--verdict-pass);
  --color-verdict-warn: var(--verdict-warn);
  --color-verdict-fail: var(--verdict-fail);
  --radius-sm: calc(var(--radius) - 4px);
  --radius-md: calc(var(--radius) - 2px);
  --radius-lg: var(--radius);
  --radius-xl: calc(var(--radius) + 4px);
}`;

// Artifact-content token system distilled from the internal sq-report-design
// colors_and_type.css (which owns the product chrome). The chrome-brand font import is
// deliberately dropped so the artifact stays dependency-free; type stacks fall back to
// system fonts. This kit is compiled plain CSS - no runtime, no CDN.
const BRAND_CSS = `:root {
  --ink-900: #0f1115;
  --ink-800: #11141a;
  --ink-700: #171a21;
  --ink-600: #1c212b;
  --steel-700: #2a2f3a;
  --steel-600: #303745;
  --steel-500: #3c4557;
  --steel-400: #8c96aa;
  --steel-300: #aeb6c6;
  --steel-200: #b9c0cf;
  --steel-100: #d8deea;
  --cream-50: #fffbf3;
  --cream-100: #f7f3ea;
  --cream-200: #e8e1cf;
  --brass-500: #f4c95d;
  --brass-400: #ffd877;
  --brass-ink: #17130a;
  --sage-900: #172419;
  --sage-700: #315f3a;
  --sage-300: #8fe39e;
  --amber-900: #25230f;
  --amber-700: #5d4d1b;
  --amber-300: #f0c75e;
  --rust-500: #f06464;

  --bg: var(--ink-900);
  --bg-panel: var(--ink-800);
  --bg-elevated: var(--ink-600);
  --fg: var(--cream-100);
  --fg-muted: var(--steel-100);
  --fg-dim: var(--steel-200);
  --fg-faint: var(--steel-300);
  --fg-label: var(--steel-400);
  --border: var(--steel-600);
  --border-subtle: var(--steel-700);
  --border-strong: var(--steel-500);
  --accent: var(--brass-500);
  --accent-hover: var(--brass-400);
  --accent-ink: var(--brass-ink);
  --danger: var(--rust-500);

  --font-serif: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", Georgia, serif;
  --font-sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
  --font-mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;

  --radius-sm: 8px;
  --radius-md: 10px;
  --radius-lg: 12px;
  --radius-pill: 999px;
}

html, body {
  background: var(--bg);
  color: var(--fg);
  font-family: var(--font-sans);
  font-size: 15px;
  line-height: 1.5;
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}

.sq-page {
  max-width: 68rem;
  margin: 0 auto;
  padding: 2.5rem 1.25rem 4rem;
}

.sq-eyebrow {
  display: inline-block;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--fg-label);
  border: 1px solid var(--border);
  border-radius: var(--radius-pill);
  padding: 0.25rem 0.625rem;
}

.sq-h1 {
  font-family: var(--font-serif);
  font-size: 2.5rem;
  line-height: 1.1;
  letter-spacing: -0.01em;
  margin: 0.75rem 0 0;
}

.sq-h2 {
  font-size: 1.1rem;
  font-weight: 600;
  margin: 0 0 0.75rem;
}

.sq-h3 {
  font-size: 0.95rem;
  font-weight: 600;
  margin: 0 0 0.25rem;
}

.sq-lede {
  font-family: var(--font-serif);
  font-size: 1.125rem;
  font-style: italic;
  color: var(--fg-muted);
  max-width: 52rem;
  margin: 0.5rem 0 0;
}

.sq-section { margin-bottom: 2.5rem; }

.sq-muted { color: var(--fg-faint); }

.sq-card {
  background: var(--bg-panel);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  padding: 1rem;
}

.sq-card + .sq-card { margin-top: 0.75rem; }

.sq-card-title { font-size: 0.95rem; font-weight: 600; margin: 0 0 0.25rem; }

.sq-grid { display: grid; gap: 0.75rem; }
.sq-grid-2 { grid-template-columns: 1fr; }
.sq-grid-3 { grid-template-columns: 1fr; }
@media (min-width: 640px) {
  .sq-grid-2 { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .sq-grid-3 { grid-template-columns: repeat(3, minmax(0, 1fr)); }
}

.sq-list { margin-top: 0.5rem; display: grid; gap: 0.375rem; font-size: 0.875rem; color: var(--fg-dim); }

.sq-badge {
  display: inline-block;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.04em;
  color: var(--fg-dim);
  border: 1px solid var(--border);
  border-radius: var(--radius-pill);
  padding: 0.2rem 0.5rem;
}

.sq-badge-accent { color: var(--accent); border-color: var(--accent); }

.sq-badge-warn { color: var(--amber-300); border-color: var(--amber-300); }

.sq-btn {
  display: inline-block;
  font: inherit;
  font-weight: 600;
  color: var(--accent-ink);
  background: var(--accent);
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  padding: 0.5rem 0.875rem;
  cursor: pointer;
}

.sq-btn:hover { background: var(--accent-hover); }

.sq-btn-ghost {
  color: var(--fg);
  background: transparent;
  border-color: var(--border);
}

.sq-btn-ghost:hover { background: var(--bg-elevated); }

.sq-table-wrap {
  overflow-x: auto;
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
  background: var(--bg-panel);
}

.sq-table {
  width: 100%;
  min-width: 36rem;
  border-collapse: collapse;
  font-size: 0.875rem;
  text-align: left;
}

.sq-table th {
  color: var(--fg-label);
  text-transform: uppercase;
  font-size: 11px;
  letter-spacing: 0.06em;
  font-weight: 600;
  padding: 0.625rem 1rem;
  border-bottom: 1px solid var(--border);
}

.sq-table td {
  padding: 0.625rem 1rem;
  border-bottom: 1px solid var(--border-subtle);
  vertical-align: top;
}

.sq-table tr:last-child td { border-bottom: none; }

.sq-code {
  font-family: var(--font-mono);
  font-size: 0.85em;
  background: var(--bg-elevated);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  padding: 0.1rem 0.4rem;
  color: var(--cream-200);
}

.sq-input {
  width: 100%;
  font: inherit;
  color: var(--fg);
  background: var(--bg);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm);
  padding: 0.5rem 0.625rem;
}

.sq-input:focus { outline: 2px solid var(--accent); outline-offset: 1px; }

.sq-footer {
  border-top: 1px solid var(--border);
  margin-top: 2rem;
  padding-top: 1rem;
  font-size: 0.75rem;
  color: var(--fg-faint);
}

.sq-mt-2 { margin-top: 0.5rem; }

/* Style the shared queuePrompt decision form (plain markup from the input playbook) */
form[data-lavish-question] {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  margin-top: 0.75rem;
}

form[data-lavish-question] label {
  display: flex;
  gap: 0.5rem;
  align-items: flex-start;
  padding: 0.625rem;
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  cursor: pointer;
}

form[data-lavish-question] label:hover { background: var(--bg-elevated); }

form[data-lavish-question] button[type="submit"] { align-self: flex-start; }`;

const DAISYUI_CLASSES = {
  page: "bg-base-100 text-base-content",
  container: "mx-auto max-w-5xl px-4 py-8 lg:px-8",
  eyebrow: "badge badge-ghost",
  h1: "mt-3 text-3xl font-bold tracking-tight sm:text-4xl",
  lede: "mt-2 max-w-3xl text-sm leading-relaxed text-base-content/70 sm:text-base",
  section: "mb-10",
  h2: "mb-3 text-lg font-semibold",
  h3: "font-semibold",
  card: "card card-border bg-base-100 p-4",
  cardTitle: "card-title",
  grid2: "grid gap-3 sm:grid-cols-2",
  grid3: "grid gap-3 sm:grid-cols-3",
  list: "mt-2 space-y-1 text-sm text-base-content/70",
  badge: "badge badge-soft badge-neutral",
  badgePrimary: "badge badge-primary",
  badgeWarn: "badge badge-soft badge-warning",
  btnPrimary: "btn btn-primary",
  btnGhost: "btn btn-ghost",
  btnRow: "mt-2",
  muted: "text-base-content/60",
  tableWrap: "overflow-x-auto rounded-box border border-base-content/5 bg-base-100",
  table: "table table-zebra",
  code: "rounded bg-base-200 px-1 py-0.5 text-xs",
  textarea: "textarea textarea-bordered w-full",
  footer: "border-t border-base-content/10 pt-4 text-xs text-base-content/50",
};

const SHADCN_CLASSES = {
  page: "bg-background text-foreground antialiased",
  container: "mx-auto max-w-5xl px-4 py-8 lg:px-8",
  eyebrow: "rounded-full border border-border px-2.5 py-0.5 text-xs font-medium",
  h1: "mt-3 text-3xl font-bold tracking-tight sm:text-4xl",
  lede: "mt-2 max-w-3xl text-sm leading-relaxed text-muted-foreground sm:text-base",
  section: "mb-10",
  h2: "mb-3 text-lg font-semibold",
  h3: "text-sm font-semibold",
  card: "rounded-lg border border-border bg-card p-4",
  cardTitle: "text-sm font-semibold",
  grid2: "grid gap-3 sm:grid-cols-2",
  grid3: "grid gap-3 sm:grid-cols-3",
  list: "mt-2 space-y-1 text-sm text-muted-foreground",
  badge: "rounded-full border border-border px-2.5 py-0.5 text-xs font-medium",
  badgePrimary: "rounded-full border border-border px-2.5 py-0.5 text-xs font-medium text-foreground",
  badgeWarn:
    "rounded-full border border-verdict-warn/50 bg-verdict-warn/10 px-2.5 py-0.5 text-xs font-medium text-verdict-warn",
  btnPrimary:
    "cursor-pointer rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:opacity-90",
  btnGhost:
    "cursor-pointer rounded-md border border-border bg-secondary px-3 py-1.5 text-sm font-medium hover:bg-muted",
  btnRow: "mt-2",
  muted: "text-muted-foreground",
  tableWrap: "overflow-x-auto rounded-lg border border-border bg-card",
  table: "w-full min-w-[560px] text-left text-sm",
  code: "rounded bg-secondary px-1 py-0.5 text-xs",
  textarea:
    "mt-3 w-full rounded-md border border-input bg-background px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-ring",
  footer: "border-t border-border pt-4 text-xs text-muted-foreground",
};

const BRAND_CLASSES = {
  page: "",
  container: "sq-page",
  eyebrow: "sq-eyebrow",
  h1: "sq-h1",
  lede: "sq-lede",
  section: "sq-section",
  h2: "sq-h2",
  h3: "sq-h3",
  card: "sq-card",
  cardTitle: "sq-card-title",
  grid2: "sq-grid sq-grid-2",
  grid3: "sq-grid sq-grid-3",
  list: "sq-list",
  badge: "sq-badge",
  badgePrimary: "sq-badge sq-badge-accent",
  badgeWarn: "sq-badge sq-badge-warn",
  btnPrimary: "sq-btn",
  btnGhost: "sq-btn sq-btn-ghost",
  btnRow: "sq-mt-2",
  muted: "sq-muted",
  tableWrap: "sq-table-wrap",
  table: "sq-table",
  code: "sq-code",
  textarea: "sq-input",
  footer: "sq-footer",
};

const SHADCN_FORM_CSS = `form[data-lavish-question] {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  margin-top: 0.75rem;
}
form[data-lavish-question] label {
  display: flex;
  gap: 0.5rem;
  align-items: flex-start;
  padding: 0.625rem;
  border: 1px solid var(--border);
  border-radius: 0.375rem;
  cursor: pointer;
}
form[data-lavish-question] label:hover { background: var(--secondary); }
form[data-lavish-question] button[type="submit"] { align-self: flex-start; }`;

const DAISYUI_FORM_CSS = `form[data-lavish-question] {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  margin-top: 0.75rem;
}
form[data-lavish-question] label {
  display: flex;
  gap: 0.5rem;
  align-items: flex-start;
  padding: 0.625rem;
  border: 1px solid var(--color-base-content);
  border-radius: 0.5rem;
  cursor: pointer;
}
form[data-lavish-question] label:hover { background: var(--color-base-200); }
form[data-lavish-question] button[type="submit"] { align-self: flex-start; }`;

const TOKEN_KIT_DEFS = {
  daisyui: {
    htmlAttrs: 'lang="en" data-theme="luxury"',
    bodyClass: "bg-base-100 text-base-content",
    head: (title) => `<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${title}</title>
${DESIGN_CDN_SNIPPET}
<style>
${DAISYUI_FORM_CSS}
</style>
${LAYOUT_SAFETY_CSS_SNIPPET}
</head>`,
    toggle:
      "<button onclick=\"document.documentElement.setAttribute('data-theme', document.documentElement.getAttribute('data-theme') === 'luxury' ? 'light' : 'luxury')\" class=\"btn btn-ghost btn-sm\">Toggle light/dark</button>",
  },
  shadcn: {
    htmlAttrs: 'lang="en" class="light"',
    bodyClass: "bg-background text-foreground antialiased",
    head: (title) => `<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${title}</title>
<script src="${DESIGN_CDN_URLS.tailwind}"></script>
<style>
${SHADCN_TOKENS}
html, body {
  background-color: var(--background);
  color: var(--foreground);
}
${SHADCN_FORM_CSS}
</style>
<style type="text/tailwindcss">
@custom-variant dark (&:is(.dark *));

${SHADCN_THEME_MAPPING}
</style>
${LAYOUT_SAFETY_CSS_SNIPPET}
</head>`,
    toggle:
      '<button onclick="document.documentElement.classList.toggle(\'dark\')" class="cursor-pointer rounded-md border border-border bg-secondary px-3 py-1.5 text-sm font-medium hover:bg-muted">Toggle light/dark</button>',
  },
  "sq-report": {
    htmlAttrs: 'lang="en"',
    bodyClass: "",
    head: (title) => `<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${title}</title>
<style>
${BRAND_CSS}
</style>
${LAYOUT_SAFETY_CSS_SNIPPET}
</head>`,
    toggle: "",
  },
};

function kitWithClassHelper(id) {
  const kit = TOKEN_KITS.find((candidate) => candidate.id === id) || TOKEN_KITS[0];
  const def = TOKEN_KIT_DEFS[kit.id];
  return {
    ...kit,
    ...def,
    cls: (name) => KIT_CLASSES[kit.id][name] || "",
  };
}

const KIT_CLASSES = {
  daisyui: DAISYUI_CLASSES,
  shadcn: SHADCN_CLASSES,
  "sq-report": BRAND_CLASSES,
};

function pageHeader(kit, kind) {
  return `<header class="mb-8">
  <div class="flex flex-wrap items-center gap-2 text-xs">
    <span class="${kit.cls("eyebrow")}">${kind.eyebrow}</span>
    ${kit.toggle ? `<span>${kit.toggle}</span>` : ""}
  </div>
  <h1 class="${kit.cls("h1")}">${kind.title}</h1>
  <p class="${kit.cls("lede")}">${kind.lede}</p>
</header>`;
}

function pageFooter(kit) {
  return `<footer class="${kit.cls("footer")}">
  <p>sq-report review surface.</p>
</footer>`;
}

function starterComment(kind, tokens) {
  return `<!--
  sq-report starter (kind: ${kind}, tokens: ${tokens}).
  Edit this file, then run:
    sq-report <this file>    opens the review session
    sq-report poll <this file>  collects reviewer feedback
  Design guidance: run \`sq-report design\`. Playbooks: run \`sq-report playbook <id>\`.
-->
`;
}

export function buildTemplate({ kind = "base", tokens = "daisyui", title = "" } = {}) {
  const kindDef = resolveTemplateKind(kind) || TEMPLATE_KINDS[0];
  const kit = kitWithClassHelper(tokens);
  const resolvedTitle = title || kindDef.title;
  const header = kindDef.header === false ? "" : pageHeader(kit, kindDef);
  const body = kindDef.render(kit);
  const containerClass = kindDef.containerClass === false ? "" : kit.cls("container");
  const footer = kindDef.footer === false ? "" : pageFooter(kit);
  return `<!DOCTYPE html>
<html ${kit.htmlAttrs}>
${kit.head(resolvedTitle)}
<body class="${kit.cls("page")}">
${starterComment(kindDef.id, kit.id)}
<main class="${containerClass}">
${header}${body}${footer}
</main>
</body>
</html>
`;
}

function baseSections(kit) {
  return `<section class="${kit.cls("section")}">
  <h2 class="${kit.cls("h2")}">Placeholder section</h2>
  <div class="${kit.cls("card")}">
    <h3 class="${kit.cls("cardTitle")}">Replace me</h3>
    <p class="${kit.cls("muted")}">Write the artifact content here. Add sections, cards, tables, diagrams, or queuePrompt forms matching the relevant playbooks: run \`sq-report playbook\` to list them.</p>
  </div>
</section>`;
}

function decisionSections(kit) {
  return `<section class="${kit.cls("section")}">
  <h2 class="${kit.cls("h2")}">Decisions in review</h2>
  <p class="${kit.cls("muted")}">Each decision keeps local selection state until the reviewer submits it. Nothing is sent without the reviewer pressing the send control in the sq-report panel.</p>

  <!-- REPLACE the options and labels below with your decision's options. Keep the
       <form> element and its onsubmit wiring untouched - it is the canonical
       input-playbook queuePrompt form (see the "input" playbook). -->
  <div class="${kit.cls("card")}">
    <h3 class="${kit.cls("cardTitle")}">D1 · Your decision question</h3>
    <p class="${kit.cls("muted")}">Short context: what is being chosen, what the options mean, and what happens next.</p>
    ${INPUT_DECISION_FORM_SNIPPET}
  </div>

  <div class="${kit.cls("card")}">
    <h3 class="${kit.cls("cardTitle")}">Open comment (optional)</h3>
    <p class="${kit.cls("muted")}">Any adjustment, question, or condition that changes the answers above.</p>
    <form data-lavish-question="open" onsubmit="event.preventDefault(); const v = new FormData(event.currentTarget).get('open'); if (v && v.trim()) window.lavish.queuePrompt('Open comment: ' + v.trim(), { tag: 'feedback', text: v.trim(), element: event.currentTarget, data: { question: 'open' } }); event.currentTarget.reset();">
      <textarea name="open" rows="3" class="${kit.cls("textarea")}" placeholder="Write here..."></textarea>
      <div class="${kit.cls("btnRow")}">
        <button type="submit" class="${kit.cls("btnGhost")}">Queue comment</button>
      </div>
    </form>
  </div>
</section>`;
}

function comparisonSections(kit) {
  return `<section class="${kit.cls("section")}">
  <h2 class="${kit.cls("h2")}">Options</h2>
  <p class="${kit.cls("muted")}">Name the decision at the top of the artifact and show the concrete behavior per side, not just abstract pros and cons. Make the cost of each option as visible as the benefit.</p>
  <div class="${kit.cls("grid2")}">
    <div class="${kit.cls("card")}">
      <h3 class="${kit.cls("cardTitle")}">Option A <span class="${kit.cls("badgePrimary")}">recommended</span></h3>
      <ul class="${kit.cls("list")}">
        <li>Concrete behavior or artifact shape under this option.</li>
        <li>Primary benefit with its cost or tradeoff.</li>
      </ul>
    </div>
    <div class="${kit.cls("card")}">
      <h3 class="${kit.cls("cardTitle")}">Option B</h3>
      <ul class="${kit.cls("list")}">
        <li>Concrete behavior or artifact shape under this option.</li>
        <li>Primary benefit with its cost or tradeoff.</li>
      </ul>
    </div>
  </div>
</section>`;
}

function tableSections(kit) {
  return `<section class="${kit.cls("section")}">
  <h2 class="${kit.cls("h2")}">Evidence table</h2>
  <p class="${kit.cls("muted")}">Start with a short summary of what the rows prove or require, keep the primary status visible without reading every cell, and protect long paths and URLs from overflowing.</p>
  <div class="${kit.cls("tableWrap")}">
    <table class="${kit.cls("table")}">
      <thead>
        <tr>
          <th>Item</th>
          <th>Evidence</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>Replace with real rows</td>
          <td class="${kit.cls("muted")}">Evidence, path, or link for this row.</td>
          <td><span class="${kit.cls("badgeWarn")}">open</span></td>
        </tr>
      </tbody>
    </table>
  </div>
</section>`;
}

function planSections(kit) {
  return `<section class="${kit.cls("section")}">
  <h2 class="${kit.cls("h2")}">Goal</h2>
  <p class="${kit.cls("lede")}">The goal, the current state, and the desired behavior.</p>
</section>
<section class="${kit.cls("section")}">
  <h2 class="${kit.cls("h2")}">Proposed approach</h2>
  <div class="${kit.cls("grid2")}">
    <div class="${kit.cls("card")}">
      <h3 class="${kit.cls("cardTitle")}">Decision 1</h3>
      <p class="${kit.cls("muted")}">High-level choice with the reasoning that supports it.</p>
    </div>
    <div class="${kit.cls("card")}">
      <h3 class="${kit.cls("cardTitle")}">Decision 2</h3>
      <p class="${kit.cls("muted")}">High-level choice with the reasoning that supports it.</p>
    </div>
  </div>
</section>
<section class="${kit.cls("section")}">
  <h2 class="${kit.cls("h2")}">Risks and open questions</h2>
  <ul class="${kit.cls("list")}">
    <li>Risk, failure mode, or migration concern.</li>
    <li>Open question - resolve it with a comparison or decision section before shipping.</li>
  </ul>
</section>`;
}

function codeSections(kit) {
  return `<section class="${kit.cls("section")}">
  <h2 class="${kit.cls("h2")}">Code</h2>
  <p class="${kit.cls("muted")}">Place the path, language, and reason to inspect the code immediately before each rendered file or diff. Replace the file contents in the snippet below.</p>
  ${CODE_DIFF_SNIPPET}
</section>`;
}

function diagramSections(kit) {
  return `<section class="${kit.cls("section")}">
  <h2 class="${kit.cls("h2")}">Diagram</h2>
  <p class="${kit.cls("muted")}">Lead with the question the diagram answers, keep the first visual to the core relationship, and put dense evidence below it. Diagrams in .mermaid containers become editable whiteboards in sq-report.</p>
  <div class="mermaid">
flowchart TD
  A[Start] --> B{Decision}
  B -- yes --> C[Next step]
  B -- no --> D[Alternative]
  </div>
</section>
${MERMAID_CDN_SNIPPET}`;
}

const SLIDES_CSS = `<style>
  .sq-deck {
    height: 100svh;
    overflow-y: auto;
    scroll-snap-type: y mandatory;
  }
  .sq-slide {
    min-height: 100svh;
    display: flex;
    flex-direction: column;
    justify-content: center;
    max-width: 52rem;
    margin: 0 auto;
    padding: 2rem 1.25rem;
    scroll-snap-align: start;
  }
</style>`;

function slidesSections(kit) {
  return `${SLIDES_CSS}
<!-- Navigation: the deck scrolls vertically, one slide per viewport, with scroll-snap.
     Add or remove slides by copying a <section class="sq-slide">. -->
<section class="sq-deck">
  <section class="sq-slide">
    <span class="${kit.cls("eyebrow")}">Slide 1 / N</span>
    <h1 class="${kit.cls("h1")}">The point</h1>
    <p class="${kit.cls("lede")}">One idea per slide, sparse text, and visuals carry the explanation.</p>
  </section>
  <section class="sq-slide">
    <h2 class="${kit.cls("h2")}">Evidence</h2>
    <p class="${kit.cls("muted")}">Show the evidence for the point.</p>
  </section>
  <section class="sq-slide">
    <h2 class="${kit.cls("h2")}">Decision or next action</h2>
    <p class="${kit.cls("muted")}">Close with the decision or next action.</p>
  </section>
</section>`;
}

export function createTemplatesListOutput() {
  return {
    template_kinds: TEMPLATE_KINDS.map(({ id, use_when }) => ({ id, use_when })),
    token_kits: TOKEN_KITS.map(({ id, name, description, default: isDefault }) => ({
      id,
      name,
      description,
      ...(isDefault ? { default: true } : {}),
    })),
    help: [
      "Run `sq-report new <kind>` to scaffold a starter artifact, then edit it",
      "Run `sq-report new <kind> --tokens <kit>` to pick a token kit (default: daisyui)",
      "Run `sq-report new <kind> --out <path>` to write to a specific path (default: .sq-report/<kind>.html)",
    ],
  };
}

export function createNewOutput({ kind, tokens, file, html }) {
  const kit = resolveTokenKit(tokens) || TOKEN_KITS[0];
  return {
    template: {
      kind,
      tokens: kit.id,
      token_kit: kit.name,
      file,
      bytes: Buffer.byteLength(html),
    },
    next_step: `Wrote ${file}. Open the file, replace the placeholder content with the real artifact content (keep the <head> tokens, the painted page background, and the queuePrompt wiring), then run \`sq-report ${file}\` to open the review session.`,
  };
}
