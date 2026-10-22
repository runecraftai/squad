import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { type CustodyScheme, type CustodyTable, installedGeneration } from "../core/index.js";
import { DURABLE_MISSION_PREFIX } from "./squad.js";

/**
 * Squad custody adapter: the responsibilities a legacy Squad writer can exercise on a task, the immutable custody table
 * of every published generation, and the inventory of every legacy writer with its consultation point.
 *
 * The inventory is derived from the code: `scanLegacyWriters` finds every file under `bin/` that writes a task record
 * or calls a writer that does, and `inventoryViolations` fails when one of them is missing here, or names a
 * responsibility it never consults. The shell side is `bin/sq-durable-custody.sh`, whose `durable_custody_check` is the
 * one consultation point every inventoried writer calls before it mutates anything.
 */

export const SQUAD_RESPONSIBILITIES = {
	admission: "create or redefine a task record: brief, launch metadata, promotion",
	approval: "decision and blocker records and the answers that close them",
	landing: "merging delivered work into the default branch",
	claim: "claim, running and release of the dispatch record",
	retry: "queueing a retry and claiming it when it is due",
	heartbeat: "refreshing the activity time of a live attempt",
	recovery: "repairing claimed, running and queued dispatch records",
	spawn: "launching the worker of a task",
	wait: "stall detection, interruption and backoff",
	status: "status events a worker-side helper appends for its task",
	metadata: "annotations on an existing record: PR pointer and merge watch, request links, custom check binding",
	"xo-routing": "handing work to an XO, or writing an XO's records",
	cleanup: "removing a task's records, endpoint or isolated copy",
} as const;

export type SquadResponsibility = keyof typeof SQUAD_RESPONSIBILITIES;

const engine = { kind: "engine" } as const;
const legacy = { kind: "legacy" } as const;
const whenTerminal = { kind: "legacy", requires: "terminal-reconciled" } as const;
const whenAdmitted = { kind: "legacy", requires: "admitted" } as const;

/**
 * Published custody tables. Never edit a published table and never remove one while a mission of its generation lives:
 * `CUSTODY_TABLE_DIGESTS` pins each one, and the custody suite fails when a table drifts from its digest. A new slice
 * publishes a new generation instead, and bumps `SQ_DURABLE_CUSTODY_GENERATION` in `bin/sq-durable-custody.sh`.
 */
export const CUSTODY_TABLES: readonly CustodyTable[] = Object.freeze([
	// Generation 1, laboratory slice A1: no legacy path ever acts on a `dm1-*` mission, except cleanup once the engine
	// confirms it is terminal and reconciled.
	Object.freeze({
		generation: 1,
		owners: Object.freeze({
			admission: engine,
			approval: engine,
			landing: engine,
			claim: engine,
			retry: engine,
			heartbeat: engine,
			recovery: engine,
			spawn: engine,
			wait: engine,
			status: engine,
			metadata: engine,
			"xo-routing": engine,
			cleanup: whenTerminal,
		}),
	}),
	// Generation 2, pilot slice A2 (plan section 12): admission and approval and landing belong to the engine, execution
	// stays legacy, durable missions never go to an XO, and cleanup waits for a terminal, reconciled mission.
	Object.freeze({
		generation: 2,
		owners: Object.freeze({
			admission: whenAdmitted,
			approval: engine,
			landing: engine,
			claim: legacy,
			retry: legacy,
			heartbeat: legacy,
			recovery: legacy,
			spawn: legacy,
			wait: legacy,
			status: legacy,
			metadata: legacy,
			"xo-routing": engine,
			cleanup: whenTerminal,
		}),
	}),
]);

/** Content identity of each published table (`tableDigest`); a mismatch means a published table was edited. */
export const CUSTODY_TABLE_DIGESTS: Readonly<Record<number, string>> = Object.freeze({
	1: "a7ad989e1f4724bab2b0721dd4fa8ddb2baede6a490043a94df742c279d666f0",
	2: "f37c78e8ae8c2e9024c00e8acd0e4134334c4faf62c046104fe4ede90e7c94dc",
});

export function squadCustodyScheme(): CustodyScheme {
	return { prefix: DURABLE_MISSION_PREFIX, tables: CUSTODY_TABLES };
}

/** The custody generation this build installs; the shell library's constant must equal it. */
export const INSTALLED_CUSTODY_GENERATION = installedGeneration(squadCustodyScheme());

/** Shell library every legacy consultation point sources. */
export const CUSTODY_SHELL_LIBRARY = "bin/sq-durable-custody.sh";

export type LegacyWriter = {
	/** Repository-relative path. */
	readonly path: string;
	/** Responsibilities the file consults with `durable_custody_check` before it mutates. */
	readonly consults: readonly SquadResponsibility[];
	/** Inventoried writers whose consultation covers this file's task-record mutations. */
	readonly delegatesTo?: readonly string[];
	/**
	 * Direct write lines of a file that consults nothing, pinned verbatim: each one is reviewed as never writing a
	 * durable mission's record. A new write line in such a file fails the inventory until it is reviewed.
	 */
	readonly exempt?: { readonly reason: string; readonly lines: readonly string[] };
	readonly note: string;
};

const guard = (path: string, consults: readonly SquadResponsibility[], note: string): LegacyWriter => ({ path, consults, note });

/**
 * Every legacy writer of a task record, derived from `scanLegacyWriters` over `bin/` plus the plan's named entry points
 * (`sq-merge-local.sh` and `sq-pr-merge.sh` land work without writing a record themselves). Keep it in step with the
 * code: the custody inventory suite fails on any drift.
 */
export const LEGACY_WRITERS: readonly LegacyWriter[] = Object.freeze([
	guard("bin/sq-backlog-handoff.sh", ["xo-routing"], "moves backlog items to an XO; refuses the XO and every item key before any move"),
	guard("bin/sq-backlog-receive.sh", ["xo-routing"], "XO side of a handoff; refuses every received key before the destination backlog is touched"),
	guard("bin/sq-brief.sh", ["admission"], "writes data/<id>/brief.md; a durable mission needs its admission confirmed"),
	guard("bin/sq-check-register.sh", ["metadata"], "binds a task's custom check and trust record"),
	guard("bin/sq-decision-hold.sh", ["approval"], "decision holds, status closures and decision_keys meta of an origin task"),
	guard("bin/sq-drill-drive.sh", ["status"], "worker-side drill driver; appends its task's blocked event"),
	guard(
		"bin/sq-exec-state.sh",
		["claim", "retry", "heartbeat", "recovery", "cleanup"],
		"state/<id>.exec: claim, running and release (claim), retry and after_run (retry), heartbeat, recover and recover-all (recovery), orphan sidecar removal (cleanup)",
	),
	guard("bin/sq-herdr-session-cleanup.sh", ["cleanup"], "session-start retirement of a restored presentation pane and journal whose task meta is gone"),
	guard("bin/sq-home-seed.sh", ["xo-routing"], "seeds an XO base and its charter brief"),
	guard("bin/sq-mcp-link.sh", ["metadata"], "records mcp_request= in a task's meta"),
	guard("bin/sq-merge-local.sh", ["landing"], "guarded local-only landing; a direct call for a durable mission is refused"),
	guard("bin/sq-pending-reply-lib.sh", ["xo-routing"], "writes an XO task's parent status through fm_pending_reply_parent_custody"),
	guard("bin/sq-pr-check.sh", ["metadata"], "records pr=/pr_head= and arms the merge watch"),
	guard("bin/sq-pr-lib.sh", ["metadata"], "PR-watch artifacts: fm_pr_poll_prepare, fm_pr_poll_retirement_publish and fm_pr_poll_retirement_recover_one consult; the other mutators act only on what prepare staged"),
	guard("bin/sq-pr-merge.sh", ["landing"], "guarded PR merge; a direct call for a durable mission is refused"),
	guard("bin/sq-procevent-remote-reply.sh", ["xo-routing"], "mirrors a remote XO's status lines into its parent status"),
	guard("bin/sq-promote.sh", ["admission"], "promotes a recon to a strike by rewriting its meta"),
	guard("bin/sq-remote-home-seed.sh", ["xo-routing"], "seeds a remote XO base and its charter brief"),
	guard("bin/sq-self-heal.sh", ["cleanup"], "housekeeping that archives a status log whose meta is gone"),
	guard("bin/sq-send.sh", ["approval"], "--resolve-key closes a task's open decision; checked on the named and on the resolved task"),
	guard("bin/sq-spawn.sh", ["admission", "spawn", "retry", "xo-routing"], "launch metadata, endpoint records and status of a task; an XO launch consults xo-routing"),
	guard("bin/sq-stall-detect.sh", ["wait", "retry"], "sourced by the sentry: stall interrupts and status (wait), due retry claims (retry)"),
	guard("bin/sq-teardown.sh", ["cleanup"], "removes a task's records, endpoint and copy; --force never bypasses custody"),
	guard("bin/sq-x-lib.sh", ["metadata"], "Relay link fields of a task's meta, through fmx_meta_custody"),
	guard("bin/sq-xo-report.sh", ["xo-routing"], "an XO's routed reply into its parent status"),
	{
		path: "bin/sq-bootstrap.sh",
		consults: [],
		delegatesTo: ["bin/sq-spawn.sh", "bin/sq-backlog-handoff.sh"],
		note: "relaunches XOs and resumes pending handoffs only through those writers",
	},
	{
		path: "bin/sq-pr-check-migrate.sh",
		consults: [],
		delegatesTo: ["bin/sq-pr-lib.sh"],
		note: "rebuilds PR polls only through the pr-lib mutators",
	},
	{
		path: "bin/sq-remote-xo-control.sh",
		consults: [],
		delegatesTo: ["bin/sq-exec-state.sh", "bin/sq-spawn.sh", "bin/sq-teardown.sh"],
		note: "remote XO lifecycle only through those writers",
	},
	{
		path: "bin/sq-sentry.sh",
		consults: [],
		delegatesTo: ["bin/sq-exec-state.sh", "bin/sq-pr-lib.sh", "bin/sq-stall-detect.sh"],
		exempt: {
			reason: "drops the sentry's own window-keyed markers (.stale-*, .stale-since-*, .wedge-escalations-*, .seen-*) of windows whose task record is gone, and writes its .hb-surfaced-* heartbeat dedupe marker; never a task record",
			lines: ['rm -f "$f" && dropped=$((dropped + 1))', `printf '%s' "$last" > "$(_hb_surfaced_path "$task")"`],
		},
		note: "long-running; task records change only through sq-exec-state, the pr-lib mutators and the sourced sq-stall-detect, whose custody generation is pinned when the sentry starts",
	},
	{
		path: "bin/sq-x-followup.sh",
		consults: [],
		delegatesTo: ["bin/sq-x-lib.sh"],
		note: "Relay follow-ups change meta only through the x-lib mutators",
	},
	{
		path: "bin/sq-x-link.sh",
		consults: [],
		delegatesTo: ["bin/sq-x-lib.sh"],
		note: "Relay links change meta only through the x-lib mutators",
	},
	{
		path: "bin/sq-push-transition-lib.sh",
		consults: [],
		exempt: {
			reason: "writes the sentry's .hb-surfaced-* heartbeat dedupe marker, a supervision internal keyed by task, never a task record",
			lines: [`printf '%s' "$last" > "$(_hb_surfaced_path "$task")"`],
		},
		note: "push-transition heartbeat dedupe",
	},
	{
		path: "bin/sq-busy-lib.sh",
		consults: [],
		exempt: {
			reason: "drops the state/<id>.muse-session-current busy-state cache it re-derives in the same call; a read-side cache, never authority",
			lines: ['rm -f "$(fm_busy_muse_cache_path "$1" "$2")"'],
		},
		note: "busy-state reader",
	},
	{
		path: "bin/sq-check-lib.sh",
		consults: [],
		exempt: {
			reason: "copies a task's registered check into a private snapshot before running it; it reads the record and writes only the snapshot",
			lines: ['cp "$check" "$SQUAD_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }'],
		},
		note: "check runner",
	},
	{
		path: "bin/sq-timeout-lib.sh",
		consults: [],
		exempt: {
			reason: "writes and removes its own temporary command-exit and deadline files, never a task's status log",
			lines: [
				`printf '%s\\n' "$command_rc" > "$command_status"`,
				`printf 'expired\\n' > "$deadline_status"`,
				'rm -f "$command_status" "$deadline_status" 2>/dev/null || true',
				'printf "%s\\n" "$command_rc" > "$status_file"',
				'rm -f "$status_file" 2>/dev/null || true',
			],
		},
		note: "bounded command runner",
	},
	{
		path: "bin/sq-factory-collect.py",
		consults: [],
		exempt: {
			reason: "adds and holds factory candidates, whose IDs are always fc-issue-* or fc-ci-*, never a durable mission ID",
			lines: [
				"[SQ_TASKS, 'add', cand_id, title, '--kind', 'candidate', '--repo', repo_tag,",
				"[SQ_TASKS, 'hold', cand_id, '--reason', HOLD_REASON, '--kind', 'commander', '--json'],",
			],
		},
		note: "candidate collector",
	},
]);

// ---------------------------------------------------------------------------------------------------------------------
// Derivation from the code.

export type WriteSignature = "record-write" | "status-append" | "writer-call";

export type ScanHit = { readonly line: number; readonly text: string; readonly signature: WriteSignature };

export type ScannedWriter = { readonly path: string; readonly hits: readonly ScanHit[] };

const STATE_DIR = String.raw`(?:\$\{?[A-Za-z_]*(?:STATE|state)[A-Za-z_0-9]*\}?|\$\{?[A-Za-z_]*(?:BASE|HOME|ROOT|base|home|root)\}?/state|\bstate)`;
const DATA_DIR = String.raw`(?:\$\{?[A-Za-z_]*(?:DATA|data)[A-Za-z_0-9]*\}?|\$\{?[A-Za-z_]*(?:BASE|HOME|ROOT|base|home|root)\}?/data)`;
const VAR = String.raw`\$\{?[A-Za-z_][A-Za-z_0-9]*\}?`;
/** A path to one task's record: `<state>/<id>.<ext>` or `<data>/<id>/...`, the ID coming from a variable. */
const TASK_RECORD = new RegExp(String.raw`${STATE_DIR}/${VAR}\.[a-z][a-z0-9-]*|${DATA_DIR}/${VAR}/`);
const WRITE_OP = /(?:(?<![0-9&<>])>>?\s*["']?\$|\b(?:mv|rm|cp|tee|touch|ln|install|truncate)\s)/;
/** Variables that hold a task record path by name. */
const RECORD_VAR_NAME = /^(?:[A-Za-z_]*_)?(?:meta|META|status|STATUS|exec|EXEC)(?:_[A-Za-z_]*)?$/;
const STATUS_APPEND = /\bstatus_line_append\b/;
const WRITER_CALLS: readonly RegExp[] = [
	/\bsq-exec-state(?:\.sh)?["']?\s+["']?(?:claim|running|retry|retry_queued|release|released|after_run|heartbeat|recover|recover-all|transition)\b/,
	/\b(?:sq-tasks|tasks-axi|tasks_axi)\s+["']?(?:add|done|hold|mv|compact|update|rm|remove|move|unblock|block|release|start|edit|set|note|archive)\b/,
	/\bSQ_TASKS\s*,\s*["'](?:add|done|hold|mv|update|rm)["']/,
	/\bsq-(?:merge-local|pr-merge|backlog-handoff|backlog-receive|teardown|spawn|promote|pr-check|decision-hold)\.sh\b/,
	/\bfm_pr_poll_(?:prepare|publish_prepared|cleanup|revoke_final|retirement_publish|retirement_recover_one)\b/,
	/\bfmx_meta_(?:link_set|followups_set|link_clear)\b/,
];
const SCANNED = new Set([".sh", ".py", ".mjs", ".js", ""]);
const SKIPPED_DIRS = new Set(["__pycache__", "vendor", "node_modules"]);

/** Index of the quote that opens the string enclosing `index`, or -1 when `index` is outside any quoted string. */
function enclosingQuote(line: string, index: number): number {
	let open = -1;
	let quote = "";
	for (let i = 0; i < index; i++) {
		const c = line[i];
		if (c === "\\" && quote !== "'") {
			i++;
			continue;
		}
		if (quote === "" && (c === "'" || c === '"')) {
			quote = c;
			open = i;
		} else if (c === quote) {
			quote = "";
			open = -1;
		}
	}
	return open;
}

function insideQuotes(line: string, index: number): boolean {
	return enclosingQuote(line, index) >= 0;
}

/** A writer named inside quotes is still a call when the quoted word is its path: `"$SCRIPT_DIR/sq-x.sh" args`. */
function quotedInvocation(line: string, index: number): boolean {
	const open = enclosingQuote(line, index);
	if (open < 0) return true;
	return line[open] === '"' && /^\$\{?[A-Za-z_][A-Za-z_0-9]*\}?\/(?:[^\s"$]*\/)?$/.test(line.slice(open + 1, index));
}

function isComment(line: string): boolean {
	const trimmed = line.trim();
	return trimmed.startsWith("#") || /^[A-Za-z_]+\(\)\s*\{?\s*(?:#.*)?$/.test(trimmed);
}

/** A line that only prints or reports: a writer it names is text, though a redirect on it still writes. */
function isMessage(line: string): boolean {
	return /^(?:echo|printf|die|fail|usage|raise|err|warn|log)\b/.test(line.trim());
}

function extensionOf(name: string): string {
	const dot = name.lastIndexOf(".");
	return dot <= 0 ? "" : name.slice(dot);
}

function walk(dir: string): string[] {
	return readdirSync(dir).flatMap((name) => {
		if (SKIPPED_DIRS.has(name)) return [];
		const full = join(dir, name);
		if (statSync(full).isDirectory()) return walk(full);
		return SCANNED.has(extensionOf(name)) ? [full] : [];
	});
}

/** `<<EOF`, `<<'EOF'`, `<<-EOF`, or `<< EOF` with an upper-case word; `(1 << shift)` is arithmetic, not a heredoc. */
const HEREDOC = /<<-?(?:(["']?)([A-Za-z_][A-Za-z_0-9]*)\1|\s+(["']?)([A-Z_][A-Z_0-9]*)\3(?![A-Za-z_0-9]))/;
const WRITE_VERB = /\b(?:mv|rm|cp|tee|touch|ln|truncate)\s/;
const REDIRECT_TARGET = /(?<![0-9&<>])>>?\s*["']?\$\{?([A-Za-z_][A-Za-z_0-9]*)\b/g;
const VARIABLE = /\$\{?([A-Za-z_][A-Za-z_0-9]*)\b/g;

/** Lines that are code: heredoc bodies and Python docstrings are text the file writes or documents, never code it runs. */
function codeLines(text: string, python: boolean): (string | undefined)[] {
	const lines = text.split("\n");
	const code: (string | undefined)[] = [];
	let heredoc: string | undefined;
	let docstring = false;
	for (const line of lines) {
		if (heredoc !== undefined) {
			code.push(undefined);
			if (line.trim() === heredoc) heredoc = undefined;
			continue;
		}
		if (python) {
			const quotes = (line.match(/"""|\'\'\'/g) ?? []).length;
			if (docstring || quotes > 0) {
				code.push(undefined);
				if (quotes % 2 === 1) docstring = !docstring;
				continue;
			}
		}
		code.push(line);
		const opener = isComment(line) || isMessage(line) ? null : HEREDOC.exec(line);
		if (opener !== null && !insideQuotes(line, opener.index)) heredoc = opener[2] ?? opener[4];
	}
	return code;
}

/** A command substitution that computes a record path, such as `$(path_for "$id")`. */
const RECORD_PATH_CALL = /\$\(\s*(?:[A-Za-z_]*path[A-Za-z_]*|[A-Za-z_]+_for)\s/;

function writesRecordVariable(line: string, recordVars: ReadonlySet<string>): boolean {
	const isRecord = (name: string) => recordVars.has(name) || RECORD_VAR_NAME.test(name);
	for (const match of line.matchAll(REDIRECT_TARGET)) if (isRecord(match[1] as string)) return true;
	const redirect = /(?<![0-9&<>])>>?\s*["']?(?=\$\()/.exec(line);
	if (redirect !== null && RECORD_PATH_CALL.test(line.slice(redirect.index))) return true;
	const verb = WRITE_VERB.exec(line);
	if (verb === null || insideQuotes(line, verb.index)) return false;
	const rest = line.slice(verb.index);
	for (const match of rest.matchAll(VARIABLE)) if (isRecord(match[1] as string)) return true;
	return RECORD_PATH_CALL.test(rest);
}

/**
 * Scan one file's text for task-record write signatures. `self` is the file's own name, so a script naming itself in
 * its usage text is not taken for a call to itself.
 */
export function scanText(text: string, self = "", python = false): ScanHit[] {
	const lines = codeLines(text, python);
	const recordVars = new Set<string>();
	const assignment = /(?:^|[\s;(])(?:local\s+|export\s+|readonly\s+)?([A-Za-z_][A-Za-z_0-9]*)=("[^"]*"|'[^']*'|[^\s;]+)/g;
	const loop = new RegExp(String.raw`\bfor\s+([A-Za-z_][A-Za-z_0-9]*)\s+in\s+["']?${STATE_DIR}["']?/\*`);
	for (const line of lines) {
		if (line === undefined) continue;
		for (const match of line.matchAll(assignment)) {
			if (TASK_RECORD.test(match[2] as string)) recordVars.add(match[1] as string);
		}
		// `for file in "$STATE"/*.exec` walks task records.
		const walked = loop.exec(line);
		if (walked !== null) recordVars.add(walked[1] as string);
	}
	const hits: ScanHit[] = [];
	lines.forEach((line, index) => {
		if (line === undefined || isComment(line)) return;
		const at = index + 1;
		const text = line.trim();
		if ((WRITE_OP.test(line) && TASK_RECORD.test(line)) || writesRecordVariable(line, recordVars)) {
			hits.push({ line: at, text, signature: "record-write" });
			return;
		}
		if (isMessage(line)) return;
		const append = STATUS_APPEND.exec(line);
		if (append !== null && !insideQuotes(line, append.index)) {
			hits.push({ line: at, text, signature: "status-append" });
			return;
		}
		for (const pattern of WRITER_CALLS) {
			const call = pattern.exec(line);
			if (call === null || !quotedInvocation(line, call.index)) continue;
			// A case pattern (`bin/sq-x.sh|...`) or the file's own name in its usage text is not a call.
			if (/^[|)]/.test(line.slice(call.index + call[0].length))) continue;
			if (self !== "" && call[0] === self) continue;
			hits.push({ line: at, text, signature: "writer-call" });
			return;
		}
	});
	return hits;
}

/** Every file under `<repo>/bin` that writes a task record or calls a writer that does, with the lines found. */
export function scanLegacyWriters(repoRoot: string): ScannedWriter[] {
	const writers: ScannedWriter[] = [];
	for (const file of walk(join(repoRoot, "bin")).sort()) {
		const path = relative(repoRoot, file).split(sep).join("/");
		if (path === CUSTODY_SHELL_LIBRARY) continue;
		const name = path.slice(path.lastIndexOf("/") + 1);
		const hits = scanText(readFileSync(file, "utf8"), name, name.endsWith(".py"));
		if (hits.length > 0) writers.push({ path, hits });
	}
	return writers;
}

/**
 * The file's executable lines: a comment, a heredoc body, a Python docstring or a message is text the file documents or
 * prints, so a consultation that only survives there is not a consultation the file runs.
 */
function executableText(text: string, python: boolean): string {
	return codeLines(text, python)
		.map((line) => (line === undefined || isComment(line) || isMessage(line) ? "" : line))
		.join("\n");
}

/** Where a shell command starts: the line after indentation, or after a list separator or a compound-command keyword. */
const COMMAND_START = String.raw`(?:^[ \t]*|[;&|(){}][ \t]*|\b(?:if|then|do|else|elif|while|until)[ \t]+!?[ \t]*)`;

/** A `durable_custody_check` call naming the responsibility, or a `custody_responsibility=<r>` it is called with. */
const CONSULT = (responsibility: string) => {
	const name = responsibility.replace(/-/g, "\\-");
	const call = String.raw`durable_custody_check\b[^\n#]*["'\s]${name}(?=["'\s;)|&]|$)`;
	const assigned = String.raw`custody_responsibility=${name}(?=[\s;]|$)`;
	return new RegExp(String.raw`${COMMAND_START}(?:${call}|${assigned})`, "m");
};

/**
 * Inventory violations against the scanned code: every scanned writer is inventoried; every consulted responsibility has
 * a `durable_custody_check` call naming it and the shell library is sourced; a writer that consults nothing keeps only
 * its pinned, reviewed write lines and delegates every writer call to an inventoried writer that consults.
 */
export function inventoryViolations(repoRoot: string, inventory: readonly LegacyWriter[] = LEGACY_WRITERS): string[] {
	const violations: string[] = [];
	const scanned = scanLegacyWriters(repoRoot);
	const byPath = new Map(inventory.map((entry) => [entry.path, entry]));
	for (const writer of scanned) {
		if (!byPath.has(writer.path)) {
			const first = writer.hits[0];
			violations.push(
				`${writer.path} writes task records without passing through custody (line ${first?.line}: ${first?.text}); add a durable_custody_check consultation and an inventory entry`,
			);
		}
	}
	const scannedPaths = new Map(scanned.map((writer) => [writer.path, writer]));
	for (const entry of inventory) {
		let text: string;
		try {
			text = readFileSync(join(repoRoot, entry.path), "utf8");
		} catch {
			violations.push(`${entry.path} is inventoried but does not exist`);
			continue;
		}
		const writer = scannedPaths.get(entry.path);
		if (writer === undefined && entry.consults.length === 0) {
			violations.push(`${entry.path} is inventoried but neither writes task records nor consults custody; remove the entry`);
		}
		const code = executableText(text, entry.path.endsWith(".py"));
		for (const responsibility of entry.consults) {
			if (!(responsibility in SQUAD_RESPONSIBILITIES)) violations.push(`${entry.path} names unknown responsibility ${responsibility}`);
			if (!CONSULT(responsibility).test(code)) {
				violations.push(`${entry.path} is inventoried as consulting ${responsibility} but has no durable_custody_check call naming it`);
			}
		}
		if (entry.consults.length > 0 && !code.includes("sq-durable-custody.sh")) {
			violations.push(`${entry.path} consults custody but never sources ${CUSTODY_SHELL_LIBRARY}`);
		}
		if (entry.consults.length === 0 && writer !== undefined) {
			const pinned = new Set(entry.exempt?.lines ?? []);
		for (const hit of writer.hits) {
				if (hit.signature === "writer-call" || pinned.has(hit.text)) continue;
				violations.push(`${entry.path}:${hit.line} writes a task record outside custody review: ${hit.text}`);
			}
			for (const line of pinned) {
				if (!writer.hits.some((hit) => hit.text === line)) violations.push(`${entry.path} pins a write line that no longer exists: ${line}`);
			}
			const calls = writer.hits.filter((hit) => hit.signature === "writer-call" && !pinned.has(hit.text));
			if (calls.length > 0) {
				const delegates = entry.delegatesTo ?? [];
				if (delegates.length === 0) violations.push(`${entry.path} calls writers (line ${calls[0]?.line}) but names no delegate`);
				for (const delegate of delegates) {
					const target = byPath.get(delegate);
					if (target === undefined || target.consults.length === 0) {
						violations.push(`${entry.path} delegates to ${delegate}, which consults no custody`);
					}
				}
			}
		}
	}
	return violations;
}
