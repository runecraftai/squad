import { type DiffLine, lineDiff, withinDiffBudget } from "./diff.ts";
import type { DrillCapture } from "./drill-evidence.ts";
import type { PacketManifest } from "./review.ts";

/**
 * Derived, read-only HTML snapshot of one review packet.
 *
 * The export is a rendering, never a source of truth: it creates no event, no review state and
 * no approval, contains no approval or merge control, loads no script, font, stylesheet, image
 * or other resource from any origin, and escapes every piece of repository, evidence, comment
 * and log content it displays. All text is offline and self-contained.
 */

export interface ExportComment {
	id: string;
	target_type: string;
	path: string | null;
	side: string | null;
	start_line: number | null;
	end_line: number | null;
	body: string;
	state: string;
	comment_kind: string;
	suggestion: string | null;
	created_by: string;
	created_at: string;
}

export interface ExportApproval {
	id: string;
	kind: string;
	decision: string;
	actor: string;
	created_at: string;
	declaration: string | null;
	packet_digest: string | null;
	scope_json: string | null;
	superseded_at: string | null;
}

export interface ExportInput {
	initiative: { id: string; title: string } | null;
	packet: any;
	plan: { id: string; digest: string; content: string } | null;
	manifest: PacketManifest;
	capture: DrillCapture | null;
	comments: ExportComment[];
	approvals: ExportApproval[];
	timeline: Array<{ sequence: number; type: string; summary: string; actor: string; occurredAt: string }>;
	exportedAt: string;
	/** Text of each reviewable manifest side, keyed by path; absent text stays explicitly unavailable. */
	contents?: Record<string, { base?: string; head?: string }>;
}

export function escapeHtml(value: unknown): string {
	return String(value ?? "").replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character] as string);
}

function renderDiff(baseText: string, headText: string): string {
	if (!withinDiffBudget(baseText, headText)) return `<p class="muted">This object is too large for an inline line diff; its exact bytes are in the stored packet artifacts.</p>`;
	const lines: DiffLine[] = lineDiff(baseText, headText);
	let baseLine = 1;
	let headLine = 1;
	const rows = lines.map((line) => {
		const baseNumber = line.type === "added" ? "" : String(baseLine++);
		const headNumber = line.type === "removed" ? "" : String(headLine++);
		const marker = line.type === "added" ? "+" : line.type === "removed" ? "-" : " ";
		return `<tr class="diff-${line.type}"><td class="lineno">${baseNumber}</td><td class="lineno">${headNumber}</td><td class="marker">${marker}</td><td class="code">${escapeHtml(line.text)}</td></tr>`;
	});
	return `<table class="diff"><tbody>${rows.join("")}</tbody></table>`;
}

/** Renders one file's stored object text side by side; the export never reads the repository at open time. */
export function renderFileSection(file: PacketManifest["files"][number], contents?: { base?: string; head?: string }): string {
	if (!contents) return `<h3 class="mono">${escapeHtml(file.path)}</h3><p class="muted">Stored text is unavailable; no bytes are inferred.</p>`;
	return `<h3 class="mono">${escapeHtml(file.path)}</h3>${renderDiff(contents.base ?? "", contents.head ?? "")}`;
}

export function renderReviewExport(input: ExportInput): string {
	const { packet, manifest, capture } = input;
	const files = manifest.files;
	const reviewable = files.filter((file) => file.head?.reviewable || file.base?.reviewable);
	const fileRows = files.map((file) => `<tr><td class="mono">${escapeHtml(file.path)}</td><td>${escapeHtml(file.status)}</td><td class="mono">${escapeHtml(file.base?.blob?.slice(0, 12) ?? "-")}</td><td class="mono">${escapeHtml(file.head?.blob?.slice(0, 12) ?? "-")}</td><td>${file.head?.reviewable || file.base?.reviewable ? "reviewable text" : escapeHtml(file.head?.reason ?? file.base?.reason ?? "not reviewable")}</td></tr>`).join("");
	const evidenceRows = capture
		? `<table><thead><tr><th>Step</th><th>Status</th><th>Exit</th><th>Coverage</th></tr></thead><tbody>${capture.steps.map((step) => `<tr><td class="mono">${escapeHtml(step.name)}</td><td>${escapeHtml(step.status)}</td><td>${step.exitCode === null ? "not recorded" : escapeHtml(step.exitCode)}</td><td>${step.skipped ? "skipped, not executed" : "recorded"}</td></tr>`).join("")}</tbody></table>`
		: `<p class="muted">No recorded Drill capture is attached to this packet.</p>`;
	const commentRows = input.comments.map((comment) => `<li><div class="meta"><span class="mono">${escapeHtml(comment.target_type)}</span> ${comment.path ? `<span class="mono">${escapeHtml(comment.path)}${comment.start_line ? `:${escapeHtml(comment.start_line)}-${escapeHtml(comment.end_line ?? comment.start_line)}` : ""}</span>` : ""} <span class="tag">${escapeHtml(comment.state)}</span> <span class="mono">${escapeHtml(comment.comment_kind)}</span></div><div>${escapeHtml(comment.body)}</div>${comment.suggestion ? `<pre class="suggestion">${escapeHtml(comment.suggestion)}</pre>` : ""}<div class="muted">${escapeHtml(comment.created_by)} · ${escapeHtml(comment.created_at)}</div></li>`).join("");
	const approvalRows = input.approvals.map((approval) => `<tr><td class="mono">${escapeHtml(approval.kind)}</td><td>${escapeHtml(approval.decision)}</td><td>${escapeHtml(approval.actor)}</td><td>${escapeHtml(approval.declaration ?? "")}</td><td>${approval.superseded_at ? "superseded" : "recorded"}</td><td class="mono">${escapeHtml((approval.packet_digest ?? "").slice(0, 16))}</td></tr>`).join("");
	const timelineRows = input.timeline.map((entry) => `<tr><td class="mono">${escapeHtml(entry.sequence)}</td><td class="mono">${escapeHtml(entry.type)}</td><td>${escapeHtml(entry.summary)}</td><td class="mono">${escapeHtml(entry.actor)}</td></tr>`).join("");

	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Warroom review snapshot ${escapeHtml(packet.id)}</title>
<style>
	body { margin: 0; background: #0d0f10; color: #f2eee7; font-family: ui-sans-serif, system-ui, sans-serif; font-size: 14px; line-height: 1.45; }
	main { max-width: 78rem; margin: 0 auto; padding: 2rem; }
	h1, h2, h3 { font-family: ui-serif, Georgia, serif; }
	.mono { font-family: ui-monospace, "Cascadia Code", monospace; }
	.muted { color: #a9b0b1; font-size: 12px; }
	table { width: 100%; border-collapse: collapse; margin: .5rem 0 1.5rem; }
	th, td { text-align: left; padding: .4rem .6rem; border-bottom: 1px solid #333a3d; vertical-align: top; }
	th { color: #a9b0b1; font-size: 11px; text-transform: uppercase; letter-spacing: .04em; }
	.lineno { color: #a9b0b1; text-align: right; width: 3rem; user-select: none; }
	.marker { width: 1rem; }
	.code { white-space: pre-wrap; word-break: break-word; font-family: ui-monospace, monospace; }
	.diff-added { background: #122017; } .diff-removed { background: #241514; }
	.tag { border: 1px solid #626b6f; border-radius: 4px; padding: 0 .3rem; font-size: 11px; }
	.summary { border: 1px solid #333a3d; border-radius: 10px; padding: 1rem; margin-bottom: 1.5rem; }
	.suggestion { background: #1a1e20; padding: .5rem; border-radius: 4px; white-space: pre-wrap; }
	ol { padding-left: 1.25rem; }
	li { margin-bottom: 1rem; }
	.notice { border: 1px solid #70482e; color: #d68a52; border-radius: 10px; padding: 1rem; }
</style>
</head>
<body>
<main>
<h1>Warroom review snapshot</h1>
<div class="notice">Static export. It records no acceptance and authorizes no merge. Review acceptance belongs to the local session and to a separate human decision.</div>
<section class="summary">
	<div><strong>${escapeHtml(input.initiative?.title ?? "Initiative")}</strong></div>
	<div class="mono">packet ${escapeHtml(packet.id)}</div>
	<div class="mono">packetDigest ${escapeHtml(packet.packet_digest)}</div>
	<div class="mono">evidenceDigest ${escapeHtml(packet.evidence_digest)}</div>
	<div class="mono">scopeDigest ${escapeHtml(packet.scope_digest)}</div>
	<div class="mono">manifestDigest ${escapeHtml(packet.manifest_digest)}</div>
	<div class="mono">patchDigest ${escapeHtml(packet.patch_digest)}</div>
	<div class="mono">repo ${escapeHtml(packet.repo_fingerprint)}</div>
	<div class="mono">target ${escapeHtml(packet.target_ref)}</div>
	<div class="mono">base ${escapeHtml(packet.review_base_sha)}</div>
	<div class="mono">head ${escapeHtml(packet.head_sha)}</div>
	<div class="mono">plan ${escapeHtml(packet.plan_revision_id)} · ${escapeHtml(packet.plan_digest)}</div>
	<div class="mono">status ${escapeHtml(packet.status)}${packet.stale_reason ? ` · ${escapeHtml(packet.stale_reason)}` : ""}</div>
	<div class="mono">exported ${escapeHtml(input.exportedAt)}</div>
</section>
<h2>Drill evidence</h2>
${capture ? `<div class="summary">
	<div class="mono">run ${escapeHtml(capture.run.id)} · status ${escapeHtml(capture.run.status)}</div>
	<div class="mono">drill ${escapeHtml(capture.run.drillVersion)}${capture.run.drillBuildSha ? ` · ${escapeHtml(capture.run.drillBuildSha)}` : ""}</div>
	<div class="mono">drill base ${escapeHtml(capture.run.baseSha)}</div>
	<div class="mono">submitted head ${escapeHtml(capture.run.submittedHeadSha ?? "not recorded")}</div>
	<div class="mono">review-approved head ${escapeHtml(capture.run.reviewApprovedHeadSha ?? "not recorded")}</div>
	<div class="mono">delivered head ${escapeHtml(capture.run.deliveredHeadSha ?? "not recorded")}</div>
	<div class="mono">coverage ${escapeHtml(capture.coverage.ci === "no-ci" ? "no CI configured" : capture.coverage.ci === "ready" ? "CI readiness recorded, PR monitoring may continue" : "CI readiness not recorded")}</div>
	<div class="mono">eligibility ${capture.eligibility.eligible ? "eligible" : escapeHtml(capture.eligibility.reasons.join("; "))}</div>
</div>` : ""}
${evidenceRows}
<h2>Files in scope (${files.length})</h2>
<table><thead><tr><th>Path</th><th>Status</th><th>Base object</th><th>Head object</th><th>Review</th></tr></thead><tbody>${fileRows}</tbody></table>
<h2>Plan vs implementation criteria</h2>
<pre>${escapeHtml(input.plan?.content ?? "")}</pre>
<h2>Reviewed content</h2>
${reviewable.map((file) => renderFileSection(file, input.contents?.[file.path])).join("")}
<h2>Comments</h2>
<ol>${commentRows || "<li class=\"muted\">No comments recorded.</li>"}</ol>
<h2>Approval records</h2>
<table><thead><tr><th>Kind</th><th>Decision</th><th>Actor</th><th>Declaration</th><th>State</th><th>Packet digest</th></tr></thead><tbody>${approvalRows || ""}</tbody></table>
<h2>Timeline</h2>
<table><thead><tr><th>#</th><th>Type</th><th>Summary</th><th>Actor</th></tr></thead><tbody>${timelineRows}</tbody></table>
</main>
</body>
</html>`;
}
