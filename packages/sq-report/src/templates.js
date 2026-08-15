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
import { CODE_DIFF_SNIPPET } from "./playbooks.js";
import {
  callout,
  cardGrid,
  cls as clsAttr,
  codeBlock,
  colophon,
  decisionForm,
  evidenceTable,
  kvList,
  masthead,
  quote,
  section,
  statRow,
  timeline,
  verdict,
} from "./components.js";

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
    title: "A starter artifact you <em>fill with text</em>",
    eyebrow: "Starter",
    lede: "A painted starter document - replace the placeholder prose below with the real content.",
    use_when: "any artifact: a minimal painted starter you fill in",
    playbook: null,
    render: (kit) => baseSections(kit),
  },
  {
    id: "decision",
    title: "Decisions for review",
    eyebrow: "Decision",
    lede: "Choose an option per decision; selections stay local until you send them from the review panel.",
    use_when: "collect a structured decision or choice from the reviewer",
    playbook: "input",
    render: (kit) => decisionSections(kit),
  },
  {
    id: "comparison",
    title: "Options and tradeoffs",
    eyebrow: "Comparison",
    lede: "Name the decision at the top; compare concrete behavior per side, with the cost as visible as the benefit.",
    use_when: "show options, tradeoffs, or current vs target behavior",
    playbook: "comparison",
    render: (kit) => comparisonSections(kit),
  },
  {
    id: "table",
    title: "Evidence table",
    eyebrow: "Evidence",
    lede: "Scan-friendly records with the primary status visible at a glance.",
    use_when: "turn dense records into a scan-friendly table",
    playbook: "table",
    render: (kit) => tableSections(kit),
  },
  {
    id: "plan",
    title: "Plan for review",
    eyebrow: "Plan",
    lede: "Goal, current state, desired behavior, proposed approach, and open questions.",
    use_when: "present a product or technical plan before implementation",
    playbook: "plan",
    render: (kit) => planSections(kit),
  },
  {
    id: "code",
    title: "Code review",
    eyebrow: "Code review",
    lede: "Rendered source, files, and diffs through @pierre/diffs.",
    use_when: "render source code, files, or diffs",
    playbook: "code",
    render: (kit) => codeSections(kit),
  },
  {
    id: "diagram",
    title: "Architecture / flow",
    eyebrow: "Diagram",
    lede: "Lead with the question the diagram answers, then the core relationship.",
    use_when: "map relationships, flows, state, or architecture",
    playbook: "diagram",
    render: (kit) => diagramSections(kit),
  },
  {
    id: "slides",
    title: "Presentation",
    eyebrow: "Slides",
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
// system fonts. This kit is compiled plain CSS - no runtime, no CDN. The component rules
// below are the text-fill catalog from the sq-report design recon (src/components.js);
// every class name the template emits is defined here or in a kind's own inline <style>.
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
  --radius-xl: 14px;
  --radius-pill: 999px;
}

html, body {
  background: var(--bg);
  color: var(--fg);
  font-family: var(--font-sans);
  font-size: 15px;
  line-height: 1.5;
  margin: 0;
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}

.sq-page {
  max-width: 62rem;
  margin: 0 auto;
  padding: 3rem 1.5rem 5rem;
}

/* --- layout primitives (owned by the kit, NOT Tailwind names) --- */
.sq-row { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; }
.sq-row-between { justify-content: space-between; }
.sq-stack { display: grid; gap: 0.75rem; }
.sq-rule { height: 1px; background: var(--border-subtle); border: 0; margin: 0; }

/* --- masthead (C1) --- */
.sq-masthead { padding-bottom: 1.75rem; margin-bottom: 2.5rem; border-bottom: 1px solid var(--border); }

.sq-masthead-brand {
  display: flex; align-items: center; gap: 0.5rem;
  font-family: var(--font-sans);
  font-size: 11px; font-weight: 700;
  letter-spacing: 0.12em; text-transform: uppercase;
  color: var(--fg-label);
}
.sq-masthead-brand::before {
  content: ""; width: 7px; height: 7px; flex: none;
  border-radius: var(--radius-pill); background: var(--accent);
}
.sq-masthead-brand .sq-brand-sep { color: var(--border-strong); }

.sq-masthead-title {
  font-family: var(--font-serif);
  font-size: clamp(2.25rem, 5vw, 3.25rem);
  line-height: 1.05; letter-spacing: -0.015em;
  font-weight: 400; margin: 0.875rem 0 0;
  text-wrap: balance;
}
.sq-masthead-title em { font-style: italic; color: var(--accent); }

.sq-masthead-lede {
  font-family: var(--font-serif); font-size: 1.25rem; font-style: italic;
  line-height: 1.45; color: var(--fg-muted);
  max-width: 46rem; margin: 0.875rem 0 0;
  text-wrap: pretty;
}

.sq-meta {
  display: flex; flex-wrap: wrap; gap: 0.5rem 1.25rem;
  margin-top: 1.5rem;
  font-family: var(--font-mono); font-size: 12px; color: var(--fg-faint);
}
.sq-meta > span { display: inline-flex; gap: 0.4rem; align-items: baseline; min-width: 0; }
.sq-meta b {
  font-family: var(--font-sans); font-weight: 700; font-size: 10px;
  letter-spacing: 0.08em; text-transform: uppercase; color: var(--fg-label);
}

/* --- type --- */
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
  font-size: 1.375rem;
  font-weight: 600;
  line-height: 1.3;
  margin: 0;
  letter-spacing: -0.005em;
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

.sq-muted { color: var(--fg-faint); }

/* --- verdict banner (C2) --- */
.sq-verdict {
  display: flex; flex-wrap: wrap; align-items: baseline; gap: 0.5rem 1rem;
  border: 1px solid var(--accent); border-radius: var(--radius-lg);
  padding: 1rem 1.25rem; margin-bottom: 2.5rem;
  background: var(--bg-panel);
}
.sq-verdict-label {
  font-size: 10px; font-weight: 700; letter-spacing: 0.08em;
  text-transform: uppercase; color: var(--accent); flex: none;
}
.sq-verdict-text {
  font-family: var(--font-serif); font-size: 1.25rem; font-style: italic;
  color: var(--fg); margin: 0; flex: 1 1 20rem; min-width: 0; text-wrap: pretty;
}

/* --- section header (C3) --- */
.sq-section { margin-bottom: 3rem; }
.sq-section-head { display: flex; align-items: baseline; gap: 0.75rem; margin-bottom: 1rem; }
.sq-section-num {
  font-family: var(--font-mono); font-size: 12px; font-weight: 600;
  color: var(--accent); flex: none; padding-top: 0.15rem;
}
.sq-section-head .sq-rule { flex: 1; align-self: center; }
.sq-section-lede {
  font-family: var(--font-serif); font-size: 1.0625rem; font-style: italic;
  color: var(--fg-faint); max-width: 44rem; margin: 0 0 1.25rem;
}

/* --- stat row (C4) --- */
.sq-stats {
  display: grid; gap: 1px; background: var(--border-subtle);
  border: 1px solid var(--border); border-radius: var(--radius-lg);
  overflow: hidden; grid-template-columns: 1fr;
}
@media (min-width: 640px) {
  .sq-stats { grid-template-columns: repeat(var(--sq-stat-cols, 3), minmax(0, 1fr)); }
}
.sq-stat { background: var(--bg-panel); padding: 1.125rem 1.25rem; min-width: 0; }
.sq-stat-label {
  font-size: 10px; font-weight: 700; letter-spacing: 0.08em;
  text-transform: uppercase; color: var(--fg-label);
}
.sq-stat-value {
  font-family: var(--font-serif); font-size: 2.25rem; line-height: 1.1;
  margin-top: 0.375rem; color: var(--fg); font-variant-numeric: tabular-nums;
}
.sq-stat-value.is-accent { color: var(--accent); }
.sq-stat-note { font-size: 12px; color: var(--fg-faint); margin-top: 0.25rem; }

/* --- card + card grid (C5) --- */
.sq-card {
  background: var(--bg-panel); border: 1px solid var(--border);
  border-radius: var(--radius-lg); padding: 1.25rem; min-width: 0;
}
.sq-card-head { display: flex; align-items: baseline; justify-content: space-between; gap: 0.75rem; }
.sq-card-title { font-size: 1rem; font-weight: 600; margin: 0; }
.sq-card p { color: var(--fg-dim); font-size: 0.9375rem; margin: 0.5rem 0 0; text-wrap: pretty; }
.sq-card.is-accent { border-color: var(--accent); }
.sq-card + .sq-card { margin-top: 0.75rem; }

.sq-grid { display: grid; gap: 1rem; grid-template-columns: 1fr; }
@media (min-width: 640px) {
  .sq-grid-2 { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .sq-grid-3 { grid-template-columns: repeat(3, minmax(0, 1fr)); }
}
.sq-grid > * { min-width: 0; }

.sq-list { margin: 0.75rem 0 0; padding: 0; list-style: none; display: grid; gap: 0.5rem; }
.sq-list li {
  position: relative; padding-left: 1.125rem;
  font-size: 0.9375rem; color: var(--fg-dim); text-wrap: pretty;
}
.sq-list li::before {
  content: "·"; position: absolute; left: 0.25rem;
  color: var(--accent); font-weight: 700;
}

/* --- callout (C6) --- */
.sq-callout {
  display: grid; gap: 0.375rem;
  border-left: 2px solid var(--accent);
  background: var(--bg-panel);
  border-radius: 0 var(--radius-md) var(--radius-md) 0;
  padding: 1rem 1.25rem; margin: 1.25rem 0;
}
.sq-callout-label {
  font-size: 10px; font-weight: 700; letter-spacing: 0.08em;
  text-transform: uppercase; color: var(--accent);
}
.sq-callout p { margin: 0; color: var(--fg-muted); text-wrap: pretty; }
.sq-callout.is-danger { border-left-color: var(--danger); }
.sq-callout.is-danger .sq-callout-label { color: var(--danger); }
.sq-callout.is-quiet { border-left-color: var(--border-strong); }
.sq-callout.is-quiet .sq-callout-label { color: var(--fg-label); }

/* --- evidence table (C7) --- */
.sq-table-wrap {
  overflow-x: auto; border: 1px solid var(--border);
  border-radius: var(--radius-lg); background: var(--bg-panel);
}
.sq-table { width: 100%; min-width: 34rem; border-collapse: collapse; font-size: 0.875rem; text-align: left; }
.sq-table th {
  color: var(--fg-label); text-transform: uppercase; font-size: 10px;
  letter-spacing: 0.08em; font-weight: 700;
  padding: 0.75rem 1.125rem; border-bottom: 1px solid var(--border);
  white-space: nowrap;
}
.sq-table td {
  padding: 0.8125rem 1.125rem; border-bottom: 1px solid var(--border-subtle);
  vertical-align: top; color: var(--fg-dim); overflow-wrap: anywhere;
}
.sq-table td:first-child { color: var(--fg); font-weight: 500; }
.sq-table tr:last-child td { border-bottom: none; }
.sq-table tbody tr:hover td { background: var(--ink-700); }

/* --- badge (C8) --- */
.sq-badge {
  display: inline-block; font-size: 11px; font-weight: 600;
  letter-spacing: 0.04em; color: var(--fg-dim);
  border: 1px solid var(--border-strong); border-radius: var(--radius-pill);
  padding: 0.15rem 0.5rem; white-space: nowrap;
}
.sq-badge-accent { color: var(--accent); border-color: var(--accent); }
.sq-badge-warn { color: var(--amber-300); border-color: var(--amber-700); }
.sq-badge-danger { color: var(--danger); border-color: var(--danger); }
.sq-badge-ok { color: var(--sage-300); border-color: var(--sage-700); }

/* --- timeline (C9) --- */
.sq-timeline {
  margin: 0; padding: 0 0 0 1.5rem; list-style: none;
  border-left: 1px solid var(--border); display: grid; gap: 1.5rem;
}
.sq-timeline > li { position: relative; min-width: 0; }
.sq-timeline > li::before {
  content: ""; position: absolute; left: calc(-1.5rem - 4.5px); top: 0.4rem;
  width: 8px; height: 8px; border-radius: var(--radius-pill);
  background: var(--bg); border: 1px solid var(--border-strong);
}
.sq-timeline > li.is-now::before { background: var(--accent); border-color: var(--accent); }
.sq-timeline-when {
  font-family: var(--font-mono); font-size: 11px;
  letter-spacing: 0.04em; text-transform: uppercase; color: var(--fg-label);
}
.sq-timeline-what { font-size: 1rem; font-weight: 600; margin: 0.25rem 0 0; }
.sq-timeline > li p { margin: 0.25rem 0 0; color: var(--fg-faint); font-size: 0.9375rem; }

/* --- pull quote (C10) --- */
.sq-quote {
  font-family: var(--font-serif); font-style: italic;
  font-size: 1.75rem; line-height: 1.3; color: var(--fg);
  border-left: 2px solid var(--accent);
  padding: 0 0 0 1.5rem; margin: 2rem 0;
  max-width: 42rem; text-wrap: pretty;
}
.sq-quote footer {
  font-family: var(--font-sans); font-style: normal; font-size: 12px;
  letter-spacing: 0.08em; text-transform: uppercase;
  color: var(--fg-label); margin-top: 0.875rem;
}

/* --- code block (C11) --- */
.sq-code {
  font-family: var(--font-mono); font-size: 0.85em;
  background: var(--bg-elevated); border: 1px solid var(--border);
  border-radius: var(--radius-sm); padding: 0.1rem 0.4rem; color: var(--cream-200);
}
.sq-codeblock { border: 1px solid var(--border); border-radius: var(--radius-lg); overflow: hidden; background: var(--bg-panel); }
.sq-codeblock-bar {
  display: flex; justify-content: space-between; align-items: center; gap: 0.75rem;
  padding: 0.5rem 0.875rem; border-bottom: 1px solid var(--border);
  font-family: var(--font-mono); font-size: 12px; color: var(--fg-faint);
  background: var(--ink-700);
}
.sq-codeblock pre {
  margin: 0; padding: 1rem 1.125rem; overflow-x: auto;
  font-family: var(--font-mono); font-size: 13px; line-height: 1.6; color: var(--cream-200);
}

/* --- decision form (C12, styles the shared queuePrompt markup) --- */
form[data-lavish-question] { display: flex; flex-direction: column; gap: 0.5rem; margin-top: 1rem; }
form[data-lavish-question] label {
  display: flex; gap: 0.625rem; align-items: flex-start;
  padding: 0.75rem 0.875rem; border: 1px solid var(--border);
  border-radius: var(--radius-md); cursor: pointer; color: var(--fg-muted);
  transition: background 180ms cubic-bezier(0.2, 0.6, 0.2, 1), border-color 180ms;
}
form[data-lavish-question] label:hover { background: var(--bg-elevated); color: var(--fg); }
form[data-lavish-question] label:has(input:checked) { border-color: var(--accent); color: var(--fg); }
form[data-lavish-question] input[type="radio"] { accent-color: var(--accent); margin-top: 0.2rem; }
form[data-lavish-question] button[type="submit"] { align-self: flex-start; }

.sq-btn {
  display: inline-block; font: inherit; font-weight: 600;
  color: var(--accent-ink); background: var(--accent);
  border: 1px solid transparent; border-radius: var(--radius-md);
  padding: 0.5625rem 0.875rem; cursor: pointer;
}
.sq-btn:hover { background: var(--accent-hover); }
.sq-btn-ghost { color: var(--fg); background: transparent; border-color: var(--border-strong); }
.sq-btn-ghost:hover { background: var(--bg-elevated); }
.sq-input {
  width: 100%; font: inherit; color: var(--fg); background: var(--bg);
  border: 1px solid var(--border-strong); border-radius: var(--radius-md);
  padding: 0.625rem 0.75rem;
}
.sq-input:focus { outline: 2px solid var(--accent); outline-offset: 2px; }

/* --- key-value list (C13) --- */
.sq-kv { display: grid; gap: 0; margin: 0; border-top: 1px solid var(--border-subtle); }
.sq-kv > div {
  display: grid; grid-template-columns: 1fr; gap: 0.25rem;
  padding: 0.75rem 0; border-bottom: 1px solid var(--border-subtle); min-width: 0;
}
@media (min-width: 640px) { .sq-kv > div { grid-template-columns: 13rem 1fr; gap: 1.5rem; } }
.sq-kv dt {
  font-size: 10px; font-weight: 700; letter-spacing: 0.08em;
  text-transform: uppercase; color: var(--fg-label); padding-top: 0.15rem;
}
.sq-kv dd { margin: 0; color: var(--fg-dim); overflow-wrap: anywhere; }

/* --- footer / colophon (C14) --- */
.sq-footer {
  border-top: 1px solid var(--border); margin-top: 3.5rem; padding-top: 1.25rem;
  display: flex; flex-wrap: wrap; justify-content: space-between; gap: 0.5rem 1.5rem;
  font-family: var(--font-mono); font-size: 11.5px; color: var(--fg-label);
}

.sq-mt-2 { margin-top: 0.5rem; }`;

const DAISYUI_CLASSES = {
  page: "bg-base-100 text-base-content",
  container: "mx-auto max-w-5xl px-4 py-8 lg:px-8",
  eyebrow: "badge badge-ghost",
  h1: "mt-3 text-3xl font-bold tracking-tight sm:text-4xl",
  lede: "mt-2 max-w-3xl text-sm leading-relaxed text-base-content/70 sm:text-base",
  section: "mb-12",
  h2: "text-2xl font-semibold",
  h3: "font-semibold",
  card: "card card-border bg-base-200 p-5",
  cardTitle: "font-semibold",
  cardHead: "flex items-baseline justify-between gap-3",
  cardText: "mt-2 text-sm text-base-content/70",
  cardAccent: "border-primary",
  grid2: "grid gap-4 sm:grid-cols-2",
  grid3: "grid gap-4 sm:grid-cols-3",
  list: "mt-3 space-y-2 text-sm text-base-content/70",
  listItem: "before:mr-2 before:font-bold before:text-primary before:content-['·']",
  badge: "badge badge-ghost badge-sm",
  badgePrimary: "badge badge-primary badge-outline badge-sm",
  badgeOk: "badge badge-success badge-outline badge-sm",
  badgeWarn: "badge badge-warning badge-outline badge-sm",
  badgeDanger: "badge badge-error badge-outline badge-sm",
  btnPrimary: "btn btn-primary",
  btnGhost: "btn btn-ghost",
  btnRow: "mt-2",
  muted: "text-base-content/60",
  tableWrap: "overflow-x-auto rounded-box border border-base-content/15 bg-base-200",
  table: "table table-sm",
  code: "rounded bg-base-300 px-1 py-0.5 text-xs",
  textarea: "textarea textarea-bordered w-full",
  masthead: "mb-10 border-b border-base-content/15 pb-7",
  mastheadBrand:
    "flex flex-wrap items-center gap-2 text-[11px] font-bold uppercase tracking-[0.12em] text-base-content/50",
  mastheadDot: "inline-block size-[7px] rounded-full bg-primary",
  brandSep: "text-base-content/25",
  mastheadTitle: "mt-3.5 font-serif text-4xl leading-[1.05] tracking-tight text-balance sm:text-5xl",
  mastheadTitleEm: "text-primary",
  mastheadLede: "mt-3.5 max-w-3xl font-serif text-xl italic leading-relaxed text-base-content/70",
  meta: "mt-6 flex flex-wrap gap-x-5 gap-y-2 font-mono text-xs text-base-content/50",
  metaLabel: "font-sans text-[10px] font-bold uppercase tracking-[0.08em] text-base-content/40",
  verdict:
    "mb-10 flex flex-wrap items-baseline gap-x-4 gap-y-2 rounded-box border border-primary bg-base-200 px-5 py-4",
  verdictLabel: "text-[10px] font-bold uppercase tracking-[0.08em] text-primary",
  verdictText: "min-w-0 flex-1 font-serif text-xl italic text-pretty",
  sectionHead: "mb-4 flex items-baseline gap-3",
  sectionNum: "font-mono text-xs font-semibold text-primary",
  sectionLede: "mb-4 max-w-3xl font-serif text-base italic text-base-content/60",
  rule: "flex-1 self-center border-base-content/10",
  stats:
    "grid gap-px overflow-hidden rounded-box border border-base-content/15 bg-base-content/10 sm:grid-cols-[repeat(var(--sq-stat-cols,3),minmax(0,1fr))]",
  stat: "min-w-0 bg-base-200 px-5 py-4",
  statLabel: "text-[10px] font-bold uppercase tracking-[0.08em] text-base-content/50",
  statValue: "mt-1.5 font-serif text-4xl tabular-nums",
  statValueAccent: "text-primary",
  statNote: "mt-1 text-xs text-base-content/50",
  callout: "my-5 grid gap-1.5 rounded-r-box border-l-2 border-primary bg-base-200 px-5 py-4",
  calloutDanger: "border-error",
  calloutQuiet: "border-base-content/30",
  calloutLabel: "text-[10px] font-bold uppercase tracking-[0.08em] text-primary",
  calloutLabelDanger: "text-error",
  calloutLabelQuiet: "text-base-content/60",
  calloutText: "text-pretty text-base-content/80",
  timeline: "grid gap-6 border-l border-base-content/15 pl-6",
  timelineItem:
    "relative before:absolute before:-left-[1.72rem] before:top-1.5 before:size-2 before:rounded-full before:border before:border-base-content/30 before:bg-base-100",
  timelineItemNow: "before:border-primary before:bg-primary",
  timelineWhen: "font-mono text-[11px] uppercase tracking-wide text-base-content/50",
  timelineWhat: "mt-1 font-semibold",
  timelineDetail: "mt-1 text-sm text-base-content/60",
  quote: "my-8 max-w-2xl text-pretty border-l-2 border-primary pl-6 font-serif text-3xl italic leading-snug",
  quoteFooter: "mt-3.5 font-sans text-xs not-italic uppercase tracking-[0.08em] text-base-content/50",
  codeblock: "overflow-hidden rounded-box border border-base-content/15 bg-base-200",
  codeblockBar:
    "flex items-center justify-between gap-3 border-b border-base-content/15 bg-base-300 px-3.5 py-2 font-mono text-xs text-base-content/60",
  codeblockPre: "overflow-x-auto px-4 py-4 font-mono text-[13px] leading-relaxed",
  kv: "mt-8 border-t border-base-content/10",
  kvRow: "grid gap-1 border-b border-base-content/10 py-3 sm:grid-cols-[13rem_1fr] sm:gap-6",
  kvDt: "text-[10px] font-bold uppercase tracking-[0.08em] text-base-content/50",
  kvDd: "break-words text-base-content/70",
  footer:
    "mt-14 flex flex-wrap justify-between gap-x-6 gap-y-2 border-t border-base-content/15 pt-5 font-mono text-[11.5px] text-base-content/45",
};

const SHADCN_CLASSES = {
  page: "bg-background text-foreground antialiased",
  container: "mx-auto max-w-5xl px-4 py-8 lg:px-8",
  eyebrow: "rounded-full border border-border px-2.5 py-0.5 text-xs font-medium",
  h1: "mt-3 text-3xl font-bold tracking-tight sm:text-4xl",
  lede: "mt-2 max-w-3xl text-sm leading-relaxed text-muted-foreground sm:text-base",
  section: "mb-12",
  h2: "text-2xl font-semibold",
  h3: "text-sm font-semibold",
  card: "rounded-lg border border-border bg-card p-5",
  cardTitle: "text-sm font-semibold",
  cardHead: "flex items-baseline justify-between gap-3",
  cardText: "mt-2 text-sm text-muted-foreground",
  cardAccent: "border-primary",
  grid2: "grid gap-4 sm:grid-cols-2",
  grid3: "grid gap-4 sm:grid-cols-3",
  list: "mt-3 space-y-2 text-sm text-muted-foreground",
  listItem: "before:mr-2 before:font-bold before:text-primary before:content-['·']",
  badge: "rounded-full border border-border px-2.5 py-0.5 text-xs font-medium",
  badgePrimary: "rounded-full border border-primary px-2.5 py-0.5 text-xs font-medium text-primary",
  badgeOk:
    "rounded-full border border-verdict-pass/50 bg-verdict-pass/10 px-2.5 py-0.5 text-xs font-medium text-verdict-pass",
  badgeWarn:
    "rounded-full border border-verdict-warn/50 bg-verdict-warn/10 px-2.5 py-0.5 text-xs font-medium text-verdict-warn",
  badgeDanger:
    "rounded-full border border-verdict-fail/50 bg-verdict-fail/10 px-2.5 py-0.5 text-xs font-medium text-verdict-fail",
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
  masthead: "mb-10 border-b border-border pb-7",
  mastheadBrand:
    "flex flex-wrap items-center gap-2 text-[11px] font-bold uppercase tracking-[0.12em] text-muted-foreground",
  mastheadDot: "inline-block size-[7px] rounded-full bg-primary",
  brandSep: "text-border",
  mastheadTitle: "mt-3.5 font-serif text-4xl leading-[1.05] tracking-tight text-balance sm:text-5xl",
  mastheadTitleEm: "text-primary",
  mastheadLede: "mt-3.5 max-w-3xl font-serif text-xl italic leading-relaxed text-muted-foreground",
  meta: "mt-6 flex flex-wrap gap-x-5 gap-y-2 font-mono text-xs text-muted-foreground",
  metaLabel: "font-sans text-[10px] font-bold uppercase tracking-[0.08em] text-muted-foreground",
  verdict: "mb-10 flex flex-wrap items-baseline gap-x-4 gap-y-2 rounded-lg border border-primary bg-card px-5 py-4",
  verdictLabel: "text-[10px] font-bold uppercase tracking-[0.08em] text-primary",
  verdictText: "min-w-0 flex-1 font-serif text-xl italic text-pretty",
  sectionHead: "mb-4 flex items-baseline gap-3",
  sectionNum: "font-mono text-xs font-semibold text-primary",
  sectionLede: "mb-4 max-w-3xl font-serif text-base italic text-muted-foreground",
  rule: "flex-1 self-center border-border",
  stats:
    "grid gap-px overflow-hidden rounded-lg border border-border bg-border sm:grid-cols-[repeat(var(--sq-stat-cols,3),minmax(0,1fr))]",
  stat: "min-w-0 bg-card px-5 py-4",
  statLabel: "text-[10px] font-bold uppercase tracking-[0.08em] text-muted-foreground",
  statValue: "mt-1.5 font-serif text-4xl tabular-nums",
  statValueAccent: "text-primary",
  statNote: "mt-1 text-xs text-muted-foreground",
  callout: "my-5 grid gap-1.5 rounded-r-lg border-l-2 border-primary bg-card px-5 py-4",
  calloutDanger: "border-destructive",
  calloutQuiet: "border-border",
  calloutLabel: "text-[10px] font-bold uppercase tracking-[0.08em] text-primary",
  calloutLabelDanger: "text-destructive",
  calloutLabelQuiet: "text-muted-foreground",
  calloutText: "text-pretty text-muted-foreground",
  timeline: "grid gap-6 border-l border-border pl-6",
  timelineItem:
    "relative before:absolute before:-left-[1.72rem] before:top-1.5 before:size-2 before:rounded-full before:border before:border-border before:bg-background",
  timelineItemNow: "before:border-primary before:bg-primary",
  timelineWhen: "font-mono text-[11px] uppercase tracking-wide text-muted-foreground",
  timelineWhat: "mt-1 text-sm font-semibold",
  timelineDetail: "mt-1 text-sm text-muted-foreground",
  quote: "my-8 max-w-2xl text-pretty border-l-2 border-primary pl-6 font-serif text-3xl italic leading-snug",
  quoteFooter: "mt-3.5 font-sans text-xs not-italic uppercase tracking-[0.08em] text-muted-foreground",
  codeblock: "overflow-hidden rounded-lg border border-border bg-card",
  codeblockBar:
    "flex items-center justify-between gap-3 border-b border-border bg-secondary px-3.5 py-2 font-mono text-xs text-muted-foreground",
  codeblockPre: "overflow-x-auto px-4 py-4 font-mono text-[13px] leading-relaxed",
  kv: "mt-8 border-t border-border",
  kvRow: "grid gap-1 border-b border-border py-3 sm:grid-cols-[13rem_1fr] sm:gap-6",
  kvDt: "text-[10px] font-bold uppercase tracking-[0.08em] text-muted-foreground",
  kvDd: "break-words text-muted-foreground",
  footer:
    "mt-14 flex flex-wrap justify-between gap-x-6 gap-y-2 border-t border-border pt-5 font-mono text-[11.5px] text-muted-foreground",
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
  cardHead: "sq-card-head",
  cardText: "",
  cardAccent: "is-accent",
  grid2: "sq-grid sq-grid-2",
  grid3: "sq-grid sq-grid-3",
  list: "sq-list",
  listItem: "",
  badge: "sq-badge",
  badgePrimary: "sq-badge sq-badge-accent",
  badgeOk: "sq-badge sq-badge-ok",
  badgeWarn: "sq-badge sq-badge-warn",
  badgeDanger: "sq-badge sq-badge-danger",
  btnPrimary: "sq-btn",
  btnGhost: "sq-btn sq-btn-ghost",
  btnRow: "sq-mt-2",
  muted: "sq-muted",
  tableWrap: "sq-table-wrap",
  table: "sq-table",
  code: "sq-code",
  textarea: "sq-input",
  masthead: "sq-masthead",
  mastheadBrand: "sq-masthead-brand",
  mastheadDot: "",
  brandSep: "sq-brand-sep",
  mastheadTitle: "sq-masthead-title",
  mastheadTitleEm: "",
  mastheadLede: "sq-masthead-lede",
  meta: "sq-meta",
  metaLabel: "",
  verdict: "sq-verdict",
  verdictLabel: "sq-verdict-label",
  verdictText: "sq-verdict-text",
  sectionHead: "sq-section-head",
  sectionNum: "sq-section-num",
  sectionLede: "sq-section-lede",
  rule: "sq-rule",
  stats: "sq-stats",
  stat: "sq-stat",
  statLabel: "sq-stat-label",
  statValue: "sq-stat-value",
  statValueAccent: "is-accent",
  statNote: "sq-stat-note",
  callout: "sq-callout",
  calloutDanger: "is-danger",
  calloutQuiet: "is-quiet",
  calloutLabel: "sq-callout-label",
  calloutLabelDanger: "",
  calloutLabelQuiet: "",
  calloutText: "",
  timeline: "sq-timeline",
  timelineItem: "",
  timelineItemNow: "is-now",
  timelineWhen: "sq-timeline-when",
  timelineWhat: "sq-timeline-what",
  timelineDetail: "",
  quote: "sq-quote",
  quoteFooter: "",
  codeblock: "sq-codeblock",
  codeblockBar: "sq-codeblock-bar",
  codeblockPre: "",
  kv: "sq-kv",
  kvRow: "",
  kvDt: "",
  kvDd: "",
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
  return masthead(kit, {
    brand: "Squad Briefing",
    segment: kind.eyebrow,
    title: kind.title,
    lede: kind.lede,
    meta: [
      { label: "Prepared", value: new Date().toISOString().slice(0, 10) },
      { label: "Status", value: "For review" },
    ],
    toggle: kit.toggle,
  });
}

function pageFooter(kit) {
  return colophon(kit, { left: "Squad Briefing · prepared for review" });
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
  // Kind titles may carry a <em> brass phrase for the rendered <h1>; the browser
  // tab title stays plain text.
  const resolvedTitle = (title || kindDef.title).replace(/<[^>]+>/g, "").trim();
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
  return `${verdict(kit, {
    label: "Verdict",
    text: "One sentence stating the conclusion, so a busy reader can stop after this line.",
  })}
${section(kit, {
  num: "01",
  title: "What the numbers say",
  lede: "Three to four counts that frame the finding.",
  content: statRow(kit, [
    { label: "Replace: what is counted", value: "01", note: "Replace: qualifier" },
    { label: "Replace: the number that matters", value: "02", note: "Replace: qualifier", accent: true },
    { label: "Replace: what is counted", value: "03", note: "Replace: qualifier" },
  ]),
})}
${section(kit, {
  num: "02",
  title: "Options and tradeoffs",
  lede: "Parallel items of equal weight, with the recommended one marked.",
  content: cardGrid(kit, [
    {
      title: "Option A",
      badge: { text: "recommended", variant: "primary" },
      body: "Replace: what this option actually does.",
      points: ["Replace: primary benefit with its cost.", "Replace: second concrete behavior."],
      accent: true,
    },
    {
      title: "Option B",
      body: "Replace: what this option actually does.",
      points: ["Replace: primary benefit with its cost.", "Replace: second concrete behavior."],
    },
  ]),
})}
${section(kit, {
  num: "03",
  title: "Callouts and evidence",
  lede: "An aside that must not be missed, then the dense records.",
  content: `${callout(kit, { label: "Note", text: "Replace: a caveat, constraint, or note on method." })}
  ${callout(kit, { label: "Defect", text: "Replace: what is broken, with the evidence.", variant: "danger" })}
  ${evidenceTable(kit, {
    headers: ["Item", "Evidence", "Status"],
    rows: [
      {
        cells: [
          { text: "Replace: item" },
          { text: "Replace: path, link, or quote", muted: true },
          { badge: { text: "open", variant: "warn" } },
        ],
      },
      {
        cells: [
          { text: "Replace: item" },
          { text: "Replace: path, link, or quote", muted: true },
          { badge: { text: "passing", variant: "ok" } },
        ],
      },
    ],
  })}`,
})}
${section(kit, {
  num: "04",
  title: "Sequence and detail",
  lede: "Ordered steps, then the short facts that are not a table.",
  content: `${timeline(kit, [
    { when: "Step one · now", what: "Replace: what happens first", detail: "Replace: the detail line.", now: true },
    { when: "Step two", what: "Replace: what happens next", detail: "Replace: the detail line." },
  ])}
  ${kvList(kit, [
    { term: "Files touched", value: "Replace: path, path" },
    { term: "New dependencies", value: "Replace: none, or name them" },
  ])}`,
})}
${section(kit, {
  num: "05",
  title: "Voice and code",
  lede: "The sentence worth remembering, then the literal excerpt.",
  content: `${quote(kit, { text: "Replace: the sentence the reader should remember.", attribution: "Replace: attribution" })}
  ${codeBlock(kit, { path: "Replace: src/path.js", label: "excerpt", code: "Replace: the code" })}`,
})}
${section(kit, {
  num: "06",
  title: "Your call",
  lede: "The artifact needs an answer, not just a read.",
  content: decisionForm(kit, {
    question: "Replace: the question",
    context: "Replace: what is being chosen, what the options mean, and what happens next.",
  }),
})}`;
}

function decisionSections(kit) {
  return section(kit, {
    num: "01",
    title: "Decisions in review",
    lede: "Each decision keeps local selection state until the reviewer submits it.",
    content: `${callout(kit, {
      label: "Note",
      text: "Nothing is sent without the reviewer pressing the send control in the review panel.",
    })}
  ${decisionForm(kit, {
    question: "Your decision question",
    context: "Short context: what is being chosen, what the options mean, and what happens next.",
  })}

  <!-- REPLACE the options and labels below with your decision's options. Keep the
       <form> element and its onsubmit wiring untouched - it is the canonical
       input-playbook queuePrompt form (see the "input" playbook). -->
  <div${clsAttr(kit, "card")}>
    <h3${clsAttr(kit, "cardTitle")}>Open comment (optional)</h3>
    <p${clsAttr(kit, "cardText")}>Any adjustment, question, or condition that changes the answers above.</p>
    <form data-lavish-question="open" onsubmit="event.preventDefault(); const v = new FormData(event.currentTarget).get('open'); if (v && v.trim()) window.lavish.queuePrompt('Open comment: ' + v.trim(), { tag: 'feedback', text: v.trim(), element: event.currentTarget, data: { question: 'open' } }); event.currentTarget.reset();">
      <textarea name="open" rows="3"${clsAttr(kit, "textarea")} placeholder="Write here..."></textarea>
      <div${clsAttr(kit, "btnRow")}>
        <button type="submit"${clsAttr(kit, "btnGhost")}>Queue comment</button>
      </div>
    </form>
  </div>`,
  });
}

function comparisonSections(kit) {
  return section(kit, {
    num: "01",
    title: "Options",
    lede: "Name the decision at the top of the artifact; compare concrete behavior per side, with the cost as visible as the benefit.",
    content: cardGrid(kit, [
      {
        title: "Option A",
        badge: { text: "recommended", variant: "primary" },
        body: "Concrete behavior or artifact shape under this option.",
        points: ["Primary benefit with its cost or tradeoff."],
        accent: true,
      },
      {
        title: "Option B",
        body: "Concrete behavior or artifact shape under this option.",
        points: ["Primary benefit with its cost or tradeoff."],
      },
    ]),
  });
}

function tableSections(kit) {
  return section(kit, {
    num: "01",
    title: "Evidence table",
    lede: "Start with a short summary of what the rows prove or require; keep the primary status visible without reading every cell.",
    content: evidenceTable(kit, {
      headers: ["Item", "Evidence", "Status"],
      rows: [
        {
          cells: [
            { text: "Replace with real rows" },
            { text: "Evidence, path, or link for this row.", muted: true },
            { badge: { text: "open", variant: "warn" } },
          ],
        },
        {
          cells: [
            { text: "Replace with real rows" },
            { text: "Evidence, path, or link for this row.", muted: true },
            { badge: { text: "passing", variant: "ok" } },
          ],
        },
        {
          cells: [
            { text: "Replace with real rows" },
            { text: "Evidence, path, or link for this row.", muted: true },
            { badge: { text: "failing", variant: "danger" } },
          ],
        },
      ],
    }),
  });
}

function planSections(kit) {
  return `${section(kit, {
    num: "01",
    title: "Goal",
    lede: "The goal, the current state, and the desired behavior.",
  })}
${section(kit, {
  num: "02",
  title: "Proposed approach",
  lede: "High-level decisions, each with the reasoning that supports it.",
  content: cardGrid(kit, [
    { title: "Decision 1", body: "High-level choice with the reasoning that supports it." },
    { title: "Decision 2", body: "High-level choice with the reasoning that supports it." },
  ]),
})}
${section(kit, {
  num: "03",
  title: "Risks and open questions",
  lede: "Failure modes, migration concerns, and questions to resolve before shipping.",
  content: kvList(kit, [
    { term: "Risk", value: "Failure mode or migration concern." },
    { term: "Open question", value: "Resolve it with a comparison or decision section before shipping." },
  ]),
})}`;
}

function codeSections(kit) {
  return section(kit, {
    num: "01",
    title: "Code",
    lede: "Place the path, language, and reason to inspect the code immediately before each rendered file or diff.",
    content: CODE_DIFF_SNIPPET,
  });
}

function diagramSections(kit) {
  return `${section(kit, {
    num: "01",
    title: "Diagram",
    lede: "Lead with the question the diagram answers; keep the first visual to the core relationship.",
    content: `<div class="mermaid">
flowchart TD
  A[Start] --> B{Decision}
  B -- yes --> C[Next step]
  B -- no --> D[Alternative]
  </div>`,
  })}
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
