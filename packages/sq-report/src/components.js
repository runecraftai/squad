// The text-fill component catalog for the `sq-report new` starter templates: one
// builder per catalog block, each returning HTML built exclusively from `kit.cls()`
// lookups. There are no literal utility classes here, so the offline sq-report token
// kit can never receive a Tailwind class it has no CSS for (the dead-class defect the
// design recon recorded in §2.3). The DaisyUI / shadcn kits express the same semantic
// keys as Tailwind utility strings in their class maps; the sq-report kit expresses
// them as `.sq-*` names compiled in BRAND_CSS.
//
// Authors fill only the marked prose - the classes come from the kit and are never
// hand-edited. The catalog is documented per component in the design recon report
// (`data/sq-report-template-redesign/report.md` §4, C1-C14).

import { INPUT_DECISION_FORM_SNIPPET } from "./playbooks.js";

/**
 * Render a class attribute for one kit class, or "" when the kit defines none.
 * Keeping the attribute conditional means no `class=""` noise in shipped markup.
 */
export function cls(kit, name) {
  const value = kit.cls(name);
  return value ? ` class="${value}"` : "";
}

/** Render a class attribute combining two kit classes (for variant modifiers). */
function cls2(kit, base, modifier) {
  const value = [kit.cls(base), kit.cls(modifier)].filter(Boolean).join(" ").trim();
  return value ? ` class="${value}"` : "";
}

/** Wrap any content in the kit's section container with a numbered section head. */
export function section(kit, { num, title, lede, content = "" }) {
  return `<section${cls(kit, "section")}>
  ${sectionHead(kit, { num, title, lede })}
${content}
</section>`;
}

/** C1 · Masthead - the report hero. Exactly once, at the top of every artifact. */
export function masthead(kit, { brand, segment, title, lede, meta = [], toggle = "" }) {
  const dot = kit.cls("mastheadDot") ? `<span${cls(kit, "mastheadDot")}></span>\n    ` : "";
  // The one sanctioned brass phrase in the hero: a bare <em> inside the title is
  // colored per kit (brand: .sq-masthead-title em; CDN kits: a utility class).
  const titleHtml = title.replace(/<em>/g, `<em${cls(kit, "mastheadTitleEm")}>`);
  const metaItems = meta
    .map(({ label, value }) => `<span><b${cls(kit, "metaLabel")}>${label}</b> ${value}</span>`)
    .join("\n    ");
  const toggleItem = toggle ? `<span>${toggle}</span>` : "";
  return `<header${cls(kit, "masthead")}>
  <div${cls(kit, "mastheadBrand")}>
    ${dot}<span>${brand}</span>
    <span${cls(kit, "brandSep")}>/</span>
    <span>${segment}</span>
  </div>
  <h1${cls(kit, "mastheadTitle")}>${titleHtml}</h1>
  <p${cls(kit, "mastheadLede")}>${lede}</p>
  <div${cls(kit, "meta")}>
    ${metaItems}${toggleItem}
  </div>
</header>`;
}

/** C2 · Verdict banner - the one-line answer above the evidence. */
export function verdict(kit, { label = "Verdict", text }) {
  return `<div${cls(kit, "verdict")}>
  <span${cls(kit, "verdictLabel")}>${label}</span>
  <p${cls(kit, "verdictText")}>${text}</p>
</div>`;
}

/** C3 · Section header - numbered title with a rule running to the right margin. */
export function sectionHead(kit, { num, title, lede }) {
  const standfirst = lede ? `\n<p${cls(kit, "sectionLede")}>${lede}</p>` : "";
  return `<div${cls(kit, "sectionHead")}>
  <span${cls(kit, "sectionNum")}>${num}</span>
  <h2${cls(kit, "h2")}>${title}</h2>
  <hr${cls(kit, "rule")}>
</div>${standfirst}`;
}

/** C4 · Stat row (KPI) - three-to-four numbers that frame a section. */
export function statRow(kit, stats) {
  const cells = stats
    .map(({ label, value, note, accent }) => {
      const valueAttr = accent ? cls2(kit, "statValue", "statValueAccent") : cls(kit, "statValue");
      return `<div${cls(kit, "stat")}>
      <div${cls(kit, "statLabel")}>${label}</div>
      <div${valueAttr}>${value}</div>
      ${note ? `<div${cls(kit, "statNote")}>${note}</div>` : ""}
    </div>`;
    })
    .join("\n    ");
  return `<div${cls(kit, "stats")} style="--sq-stat-cols: ${stats.length}">
    ${cells}
  </div>`;
}

/** C5 · Card + card grid - parallel items of equal weight, one may be accent-marked. */
function cardBody(kit, { title, badge: badgeDef, body, points = [], accent = false }) {
  const head = badgeDef
    ? `<div${cls(kit, "cardHead")}>
      <h3${cls(kit, "cardTitle")}>${title}</h3>
      ${badge(kit, badgeDef)}
    </div>`
    : `<h3${cls(kit, "cardTitle")}>${title}</h3>`;
  const list = points.length
    ? `<ul${cls(kit, "list")}>
      ${points.map((point) => `<li${cls(kit, "listItem")}>${point}</li>`).join("\n      ")}
    </ul>`
    : "";
  const cardAttr = accent ? cls2(kit, "card", "cardAccent") : cls(kit, "card");
  return `<div${cardAttr}>
    ${head}
    <p${cls(kit, "cardText")}>${body}</p>
    ${list}
  </div>`;
}

export function cardGrid(kit, cards, columns = 2) {
  const gridKey = columns === 3 ? "grid3" : "grid2";
  const inner = cards.map((card) => cardBody(kit, card)).join("\n  ");
  return `<div${cls(kit, gridKey)}>
  ${inner}
</div>`;
}

/** C6 · Callout / notice - an aside that must not be missed. Variants: danger, quiet. */
export function callout(kit, { label = "Note", text, variant = "" }) {
  const variantKey = variant ? `callout${variant[0].toUpperCase()}${variant.slice(1)}` : "";
  const containerAttr = variantKey ? cls2(kit, "callout", variantKey) : cls(kit, "callout");
  const labelAttr = variantKey ? cls2(kit, "calloutLabel", `${variantKey}Label`) : cls(kit, "calloutLabel");
  return `<div${containerAttr}>
  <span${labelAttr}>${label}</span>
  <p${cls(kit, "calloutText")}>${text}</p>
</div>`;
}

/** C7 · Evidence table - dense records with a scan-readable status column. */
export function evidenceTable(kit, { headers, rows }) {
  const head = headers.map((header) => `<th>${header}</th>`).join("");
  const body = rows
    .map((row) => {
      const cells = row.cells
        .map((cell) => {
          if (cell.badge) {
            return `<td>${badge(kit, { text: cell.badge.text, variant: cell.badge.variant })}</td>`;
          }
          if (cell.muted) {
            return `<td><span${cls(kit, "muted")}>${cell.text}</span></td>`;
          }
          return `<td>${cell.text}</td>`;
        })
        .join("");
      return `      <tr>${cells}</tr>`;
    })
    .join("\n");
  return `<div${cls(kit, "tableWrap")}>
    <table${cls(kit, "table")}>
      <thead>
        <tr>${head}</tr>
      </thead>
      <tbody>
${body}
      </tbody>
    </table>
  </div>`;
}

/** C8 · Badge / tag - a one-word status. Variants: primary, ok, warn, danger. */
export function badge(kit, { text, variant = "" }) {
  const key =
    {
      primary: "badgePrimary",
      ok: "badgeOk",
      warn: "badgeWarn",
      danger: "badgeDanger",
    }[variant] || "badge";
  return `<span${cls(kit, key)}>${text}</span>`;
}

/** C9 · Timeline - ordered steps; `now: true` fills the current step's dot. */
export function timeline(kit, steps) {
  const items = steps
    .map(({ when, what, detail, now }) => {
      const itemAttr = now ? cls2(kit, "timelineItem", "timelineItemNow") : cls(kit, "timelineItem");
      return `    <li${itemAttr}>
      <div${cls(kit, "timelineWhen")}>${when}</div>
      <h3${cls(kit, "timelineWhat")}>${what}</h3>
      <p${cls(kit, "timelineDetail")}>${detail}</p>
    </li>`;
    })
    .join("\n");
  return `<ol${cls(kit, "timeline")}>
${items}
</ol>`;
}

/** C10 · Pull quote - the sentence the reader should remember, at most twice. */
export function quote(kit, { text, attribution }) {
  const footer = attribution ? `\n  <footer${cls(kit, "quoteFooter")}>${attribution}</footer>` : "";
  return `<blockquote${cls(kit, "quote")}>
  ${text}${footer}
</blockquote>`;
}

/** C11 · Code block - a literal excerpt with its provenance attached. */
export function codeBlock(kit, { path, label = "", code }) {
  const barLabel = label ? `<span>${label}</span>` : "";
  return `<div${cls(kit, "codeblock")}>
  <div${cls(kit, "codeblockBar")}>
    <span>${path}</span>
    ${barLabel}
  </div>
  <pre${cls(kit, "codeblockPre")}>${code}</pre>
</div>`;
}

/**
 * C12 · Decision form - collect a choice from the reviewer. The <form> element and its
 * onsubmit wiring are the canonical INPUT_DECISION_FORM_SNIPPET from src/playbooks.js
 * and stay byte-for-byte untouched; the kit styles it by attribute selector.
 */
export function decisionForm(kit, { question, context }) {
  return `<div${cls(kit, "card")}>
    <h3${cls(kit, "cardTitle")}>D1 · ${question}</h3>
    <p${cls(kit, "cardText")}>${context}</p>
    ${INPUT_DECISION_FORM_SNIPPET}
  </div>`;
}

/** C13 · Key-value list - short facts that are not a table. */
export function kvList(kit, pairs) {
  const rows = pairs
    .map(
      ({ term, value }) => `<div${cls(kit, "kvRow")}>
      <dt${cls(kit, "kvDt")}>${term}</dt>
      <dd${cls(kit, "kvDd")}>${value}</dd>
    </div>`,
    )
    .join("\n  ");
  return `<dl${cls(kit, "kv")}>
  ${rows}
</dl>`;
}

/** C14 · Footer / colophon - the right slot is where the tool name belongs. */
export function colophon(kit, { left }) {
  return `<footer${cls(kit, "footer")}>
  <span>${left}</span>
  <span>Rendered with sq-report</span>
</footer>`;
}
