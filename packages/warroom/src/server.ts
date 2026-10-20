import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Server } from "bun";
import { assertIdentifier, type Command, Warroom } from "./core.ts";
import { lineDiff, withinDiffBudget } from "./diff.ts";
import {
	acceptReview,
	anchorComment,
	ArtifactStore,
	checkPacket,
	evidenceCapture,
	listPacketFiles,
	packetManifest,
	readPacketFile,
	requestReviewChanges,
	resolveComment,
} from "./review.ts";
import { renderReviewExport } from "./review-export.ts";

const indexHtml = readFileSync(join(import.meta.dir, "web", "index.html"), "utf8");

const SESSION_PLACEHOLDER = "__WARROOM_SESSION_TOKEN__";

function json(data: unknown, status = 200): Response {
	return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}

function decodeSegment(segment: string): string | null {
	try {
		return decodeURIComponent(segment);
	} catch {
		return null;
	}
}

function isLoopbackOrigin(origin: string): boolean {
	try {
		const { hostname } = new URL(origin);
		return hostname === "127.0.0.1" || hostname === "localhost" || hostname === "[::1]";
	} catch {
		return false;
	}
}

function isExpectedHost(host: string | null, port: number): boolean {
	if (!host) return false;
	return [`127.0.0.1:${port}`, `localhost:${port}`, `[::1]:${port}`].includes(host);
}

/** Local source paths stay server-side; every packet-shaped payload drops both the row and replay field. */
function redactPacket<T>(packet: T): Omit<T, "repo_path" | "repoPath"> {
	const { repo_path: _repoPath, repoPath: _repoPathCamel, ...safe } = packet as any;
	return safe;
}

/** A capture keeps its digests and step facts but never the local repository or log paths. */
function redactCapture<T>(capture: T): T {
	if (!capture || typeof capture !== "object") return capture;
	const safe = JSON.parse(JSON.stringify(capture));
	if (safe.repo && typeof safe.repo === "object") delete safe.repo.workingPath;
	if (Array.isArray(safe.logs)) for (const log of safe.logs) if (log && typeof log === "object") delete log.logPath;
	return safe as T;
}

function redactCaptureJson(captureJson: unknown): string | null {
	if (typeof captureJson !== "string") return null;
	try { return JSON.stringify(redactCapture(JSON.parse(captureJson))); } catch { return null; }
}

/** Review commands accept only the exact local origins this server is reachable at, never another loopback port. */
function isExactOrigin(origin: string, port: number): boolean {
	return [`http://127.0.0.1:${port}`, `http://localhost:${port}`, `http://[::1]:${port}`].includes(origin);
}

export interface ServerOptions {
	dbPath?: string;
	port?: number;
	actorId?: string;
	/** Data directory holding the database, artifacts and exports. Defaults to the database's directory. */
	dataDir?: string;
	/** Fixed session token for tests; a fresh random token is generated otherwise. */
	sessionToken?: string;
}

export interface App {
	warroom: Warroom;
	session: { token: string; actor: string; port: number };
	dataDir: string;
	fetch: (request: Request) => Response | Promise<Response>;
}

/** Builds the Warroom instance and request handler. Exported separately from `serve()` so tests can exercise routing without binding a socket. */
export function createApp(options: ServerOptions = {}): App {
	const dbPath = options.dbPath ?? ":memory:";
	const port = options.port ?? 4600;
	const actor = options.actorId ?? "operator";
	const dataDir = options.dataDir ?? (dbPath === ":memory:" ? process.cwd() : join(dbPath, ".."));
	const token = options.sessionToken ?? randomBytes(24).toString("hex");
	const warroom = new Warroom(dbPath, { id: actor });
	const pageHtml = indexHtml.replaceAll(SESSION_PLACEHOLDER, token);

	function initiativeSummaries(): Array<{ id: string; title: string; workingName: string; phase: string; createdAt: string; updatedAt: string }> {
		return warroom.db
			.query("SELECT id, title, working_name as workingName, phase, created_at as createdAt, updated_at as updatedAt FROM initiatives ORDER BY updated_at DESC")
			.all() as any;
	}

	function packetDetail(packetId: string): Response {
		const packet = warroom.db.query("SELECT * FROM review_packets WHERE id=?").get(packetId) as any;
		if (!packet) return json({ error: "review packet does not exist" }, 404);
		// The recorded local path stays server-side; the browser addresses content only by manifest path.
		const { repo_path: _repoPath, ...safePacket } = packet;
		const state = warroom.state(packet.initiative_id);
		const manifest = packetManifest(warroom, packet);
		const capture = evidenceCapture(warroom, packet);
		return json({
			packet: safePacket,
			initiative: state.initiative,
			plan: state.revisions.find((revision: any) => revision.id === packet.plan_revision_id) ?? null,
			files: manifest.files,
			filesDigest: packet.manifest_digest,
			capture: capture ? redactCapture(capture) : null,
			comments: state.comments.filter((comment: any) => comment.packetId === packet.id),
			approvals: state.approvals.filter((approval: any) => approval.packetId === packet.id),
			timeline: warroom.timeline(packet.initiative_id),
			limitations: {
				mergePermission: "Merge permission is not emitted by this surface. Acceptance is not merge authorization.",
				currentness: "Currentness is verified against the recorded local refs only; remote forge state is not checked here.",
			},
		});
	}

	function reviewRoute(request: Request, url: URL, segments: string[]): Response | Promise<Response> {
		// segments: ["api","review", packetId, ...rest]
		const host = request.headers.get("host");
		if (!isExpectedHost(host, port)) return json({ error: "unexpected host" }, 403);
		const origin = request.headers.get("origin");
		if (origin !== null && !isLoopbackOrigin(origin)) return json({ error: "cross-origin requests are not allowed" }, 403);
		const packetId = segments[2] ? decodeSegment(segments[2]) : null;
		const rest = segments.slice(3);
		if (packetId !== null) {
			try { assertIdentifier(packetId, "review packet id"); } catch { return json({ error: "invalid review packet id" }, 400); }
		}
		const mutating = request.method !== "GET";
		if (mutating) {
			const supplied = request.headers.get("x-warroom-session");
			if (!supplied || supplied !== token) return json({ error: "a valid local review session token is required" }, 403);
			if (origin === null || !isExactOrigin(origin, port) || !isExpectedHost(host, port)) return json({ error: "exact local origin is required for review commands" }, 403);
		}

		if (request.method === "GET" && segments[2] === "packets") {
			const initiativeId = url.searchParams.get("initiativeId");
			const packets = (initiativeId
				? warroom.db.query("SELECT * FROM review_packets WHERE initiative_id=? ORDER BY created_at DESC").all(initiativeId)
				: warroom.db.query("SELECT * FROM review_packets ORDER BY created_at DESC").all()) as any[];
			return json(packets.map(redactPacket));
		}
		if (!packetId) return json({ error: "review packet is required" }, 400);
		if (request.method === "GET" && rest.length === 0) return packetDetail(packetId);
		if (request.method === "GET" && rest.length === 1 && rest[0] === "currentness") {
			const check = checkPacket(warroom, dataDir, packetId);
			const { packet: _packet, capture: _capture, manifest: _manifest, ...report } = check;
			return json(report);
		}
		if (request.method === "GET" && rest.length === 1 && rest[0] === "files") {
			try { return json(listPacketFiles(warroom, packetId)); } catch (error) { return json({ error: (error as Error).message }, 404); }
		}
		if (request.method === "GET" && rest.length === 1 && rest[0] === "file") {
			const path = url.searchParams.get("path");
			const side = url.searchParams.get("side") === "base" ? "base" : "head";
			if (!path) return json({ error: "query parameter 'path' is required" }, 400);
			try {
				const file = readPacketFile(warroom, dataDir, packetId, path, side);
				return json({ path, side, blob: file.file[side]?.blob ?? null, text: file.text, lineCount: file.lineCount });
			} catch (error) { return json({ error: (error as Error).message }, 404); }
		}
		if (request.method === "GET" && rest.length === 1 && rest[0] === "diff") {
			const path = url.searchParams.get("path");
			if (!path) return json({ error: "query parameter 'path' is required" }, 400);
			try {
				const packet = warroom.db.query("SELECT * FROM review_packets WHERE id=?").get(packetId) as any;
				if (!packet) return json({ error: "review packet does not exist" }, 404);
				const manifest = packetManifest(warroom, packet);
				const entry = manifest.files.find((item) => item.path === path);
				if (!entry) return json({ error: "path is not part of the review packet manifest" }, 404);
				const store = new ArtifactStore(dataDir);
				const sides = {
					base: entry.base ? { present: true, reviewable: Boolean(entry.base.reviewable), reason: entry.base.reason ?? null } : { present: false, reviewable: false, reason: null },
					head: entry.head ? { present: true, reviewable: Boolean(entry.head.reviewable), reason: entry.head.reason ?? null } : { present: false, reviewable: false, reason: null },
				};
				if ((sides.base.present && !sides.base.reviewable) || (sides.head.present && !sides.head.reviewable)) {
					return json({ error: "one side of this object is not reviewable text; no bytes are inferred", path, sides }, 409);
				}
				const baseText = entry.base?.contentDigest ? store.readText(entry.base.contentDigest) : "";
				const headText = entry.head?.contentDigest ? store.readText(entry.head.contentDigest) : "";
				if (!withinDiffBudget(baseText, headText)) return json({ error: "object is too large for an inline structural diff; the stored packet patch covers it" }, 413);
				const lines = lineDiff(baseText, headText);
				let baseLine = 1;
				let headLine = 1;
				const numbered = lines.map((line) => {
					const baseNumber = line.type === "added" ? null : baseLine++;
					const headNumber = line.type === "removed" ? null : headLine++;
					return { type: line.type, text: line.text, baseLine: baseNumber, headLine: headNumber };
				});
				return json({
					path,
					status: entry.status,
					base: entry.base ? { blob: entry.base.blob, reviewable: entry.base.reviewable, reason: entry.base.reason ?? null, lineCount: baseText === "" ? 0 : baseText.split("\n").length } : null,
					head: entry.head ? { blob: entry.head.blob, reviewable: entry.head.reviewable, reason: entry.head.reason ?? null, lineCount: headText === "" ? 0 : headText.split("\n").length } : null,
					lines: numbered,
				});
			} catch (error) { return json({ error: (error as Error).message }, 404); }
		}
		if (request.method === "GET" && rest.length === 1 && rest[0] === "export") {
			return exportResponse(packetId);
		}
		if (request.method === "POST" && rest.length === 2 && rest[0] === "comments" && rest[1] === "resolve") {
			return readBody(request).then((body) => {
				const commentId = typeof body.commentId === "string" ? body.commentId : null;
				if (!commentId) return json({ error: "commentId is required" }, 400);
				try { resolveComment(warroom, commentId); return json({ resolved: commentId }); } catch (error) { return json({ error: (error as Error).message }, 400); }
			});
		}
		if (request.method === "POST" && rest.length === 1 && (rest[0] === "comments" || rest[0] === "comment")) {
			return readBody(request).then((body) => {
				try {
					const packetRow = warroom.db.query("SELECT plan_revision_id, code_revision_id FROM review_packets WHERE id=?").get(packetId) as { plan_revision_id: string; code_revision_id: string } | null;
					if (!packetRow) return json({ error: "review packet does not exist" }, 404);
					const targetType = body.targetType === "plan-range" || body.targetType === "diagram-node" || body.targetType === "review" ? body.targetType : "code-range";
					const commentId = anchorComment(warroom, dataDir, {
						packetId,
						targetType,
						revisionId: targetType === "plan-range" ? packetRow.plan_revision_id : packetRow.code_revision_id,
						path: typeof body.path === "string" ? body.path : undefined,
						side: body.side === "base" ? "base" : body.side === "head" ? "head" : undefined,
						startLine: Number.isInteger(body.startLine) ? body.startLine : undefined,
						endLine: Number.isInteger(body.endLine) ? body.endLine : undefined,
						blobSha: typeof body.blobSha === "string" ? body.blobSha : undefined,
						context: typeof body.context === "string" ? body.context : undefined,
						kind: body.kind === "suggestion" ? "suggestion" : "comment",
						suggestion: typeof body.suggestion === "string" ? body.suggestion : undefined,
						body: String(body.body ?? ""),
					});
					return json({ commentId }, 201);
				} catch (error) { return json({ error: (error as Error).message }, 400); }
			});
		}
		if (request.method === "POST" && rest.length === 1 && rest[0] === "request-changes") {
			return readBody(request).then((body) => {
				try {
					const result = requestReviewChanges(warroom, dataDir, {
						packetId,
						packetDigest: String(body.packetDigest ?? ""),
						scopeDigest: String(body.scopeDigest ?? ""),
						declaration: String(body.declaration ?? ""),
						actorConfirmed: body.actorConfirmed === true,
					});
					return json({ approvalId: result.approvalId, status: result.check.status }, 201);
				} catch (error) { return json({ error: (error as Error).message }, 400); }
			});
		}
		if (request.method === "POST" && rest.length === 1 && rest[0] === "accept") {
			return readBody(request).then((body) => {
				try {
					const result = acceptReview(warroom, dataDir, {
						packetId,
						packetDigest: String(body.packetDigest ?? ""),
						scopeDigest: String(body.scopeDigest ?? ""),
						declaration: String(body.declaration ?? ""),
						actorConfirmed: body.actorConfirmed === true,
					});
					return json({
						approvalId: result.approvalId,
						packetDigest: result.check.packet.packet_digest,
						scopeDigest: result.check.packet.scope_digest,
						actor,
						declaration: String(body.declaration),
						headSha: result.check.packet.head_sha,
						reviewBaseSha: result.check.packet.review_base_sha,
						mergePermission: "not granted by this surface",
					}, 201);
				} catch (error) { return json({ error: (error as Error).message }, 400); }
			});
		}
		return json({ error: "not found" }, 404);
	}

	function exportResponse(packetId: string): Response {
		const packet = warroom.db.query("SELECT * FROM review_packets WHERE id=?").get(packetId) as any;
		if (!packet) return json({ error: "review packet does not exist" }, 404);
		const state = warroom.state(packet.initiative_id);
		const manifest = packetManifest(warroom, packet);
		const store = new ArtifactStore(dataDir);
		const contents: Record<string, { base?: string; head?: string }> = {};
		for (const file of manifest.files) {
			const entry: { base?: string; head?: string; baseUnreviewable?: boolean; headUnreviewable?: boolean; baseReason?: string; headReason?: string } = {};
			if (file.base?.reviewable && file.base.contentDigest) entry.base = store.readText(file.base.contentDigest);
			else if (file.base) { entry.baseUnreviewable = true; entry.baseReason = file.base.reason ?? "not reviewable"; }
			if (file.head?.reviewable && file.head.contentDigest) entry.head = store.readText(file.head.contentDigest);
			else if (file.head) { entry.headUnreviewable = true; entry.headReason = file.head.reason ?? "not reviewable"; }
			if (Object.keys(entry).length > 0) contents[file.path] = entry;
		}
		const plan = state.revisions.find((revision: any) => revision.id === packet.plan_revision_id) as any;
		const comments = state.comments
			.filter((comment: any) => comment.packetId === packet.id)
			.map((comment: any) => ({
				id: comment.id,
				target_type: comment.targetType,
				path: comment.path ?? null,
				side: comment.side ?? null,
				start_line: comment.startLine ?? null,
				end_line: comment.endLine ?? null,
				body: comment.body,
				state: comment.state,
				comment_kind: comment.kind,
				suggestion: comment.suggestion ?? null,
				created_by: comment.createdBy ?? "",
				created_at: comment.createdAt ?? "",
			}));
		const approvals = state.approvals
			.filter((approval: any) => approval.packetId === packet.id)
			.map((approval: any) => ({
				id: approval.id,
				kind: approval.kind,
				decision: approval.decision,
				actor: approval.actor ?? "",
				created_at: approval.createdAt ?? "",
				declaration: approval.declaration ?? null,
				packet_digest: approval.packetDigest ?? null,
				scope_json: approval.scopeDigest ?? null,
				superseded_at: approval.superseded ? (approval.supersededAt ?? "superseded") : null,
			}));
		const html = renderReviewExport({
			initiative: state.initiative,
			packet,
			plan: plan ? { id: plan.id, digest: plan.digest, content: plan.content } : null,
			manifest,
			capture: evidenceCapture(warroom, packet),
			comments,
			approvals,
			timeline: warroom.timeline(packet.initiative_id),
			exportedAt: new Date().toISOString(),
			contents,
		});
		const before = warroom.events(packet.initiative_id).length;
		const exportsDir = join(dataDir, "exports");
		mkdirSync(exportsDir, { recursive: true, mode: 0o700 });
		const target = join(exportsDir, `${packetId}.html`);
		writeFileSync(target, html, { mode: 0o600 });
		if (warroom.events(packet.initiative_id).length !== before) return json({ error: "export unexpectedly changed review state" }, 500);
		return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-warroom-export-path": join("exports", `${packetId}.html`) } });
	}

	function readBody(request: Request): Promise<Record<string, any>> {
		const length = Number(request.headers.get("content-length") ?? 0);
		if (Number.isFinite(length) && length > 1024 * 1024) return Promise.reject(new Error("request body is too large"));
		return request.text().then((text) => {
			if (text.length > 1024 * 1024) throw new Error("request body is too large");
			try { return JSON.parse(text || "{}"); } catch { throw new Error("request body must be JSON"); }
		}).catch((error) => { throw error; });
	}

	function fetch(request: Request): Response | Promise<Response> {
		const url = new URL(request.url);
		const segments = url.pathname.split("/").filter((segment) => segment.length > 0);

		if (request.method === "GET" && url.pathname === "/") {
			// The page carries the session token, so it is served only to the expected local host.
			if (!isExpectedHost(request.headers.get("host"), port)) return json({ error: "unexpected host" }, 403);
			return new Response(pageHtml, { headers: { "content-type": "text/html; charset=utf-8" } });
		}

		if (segments[0] === "api" && segments[1] === "review") {
			return Promise.resolve()
				.then(() => reviewRoute(request, url, segments))
				.catch((error) => json({ error: (error as Error).message }, 400));
		}

		if (request.method === "GET" && url.pathname === "/api/initiatives") {
			return json(initiativeSummaries());
		}

		if (request.method === "GET" && url.pathname.startsWith("/api/initiative/")) {
			const id = decodeSegment(url.pathname.slice("/api/initiative/".length));
			if (id === null) return json({ error: "invalid initiative id" }, 400);
			const state = warroom.state(id);
			if (!state.initiative) return json({ error: "initiative does not exist" }, 404);
			return json({
				...state,
				packets: state.packets.map(redactPacket),
				captures: state.captures.map(({ captureJson, ...capture }: any) => ({ ...capture, captureJson: redactCaptureJson(captureJson) })),
				timeline: warroom.timeline(id),
			});
		}

		if (request.method === "GET" && url.pathname.startsWith("/api/compare/")) {
			const initiativeId = decodeSegment(url.pathname.slice("/api/compare/".length));
			if (initiativeId === null) return json({ error: "invalid initiative id" }, 400);
			const a = url.searchParams.get("a");
			const b = url.searchParams.get("b");
			if (!a || !b) return json({ error: "query params 'a' and 'b' are required" }, 400);
			try {
				return json(warroom.compare(initiativeId, a, b));
			} catch (error) {
				return json({ error: (error as Error).message }, 400);
			}
		}

		if (request.method === "POST" && url.pathname === "/api/command") {
			const contentType = request.headers.get("content-type") ?? "";
			if (!/^application\/json\b/i.test(contentType)) {
				return json({ error: "content-type must be application/json" }, 415);
			}
			const origin = request.headers.get("origin");
			if (origin !== null && !isLoopbackOrigin(origin)) {
				return json({ error: "cross-origin requests are not allowed" }, 403);
			}
			return request.json().then(
				(command: Command) => {
					// The generic command API cannot mint validation evidence, review acceptance or merge permission.
					// Those scopes need the capture adapter and the review endpoints, which apply currentness, scope,
					// evidence and session-authority checks the body cannot supply.
					if (command?.type === "validation.record" || command?.type === "review.capture.record" || command?.type === "review.packet.create" || command?.type === "review.supersede") {
						return json({ error: "validation evidence and review packets must come from the review capture adapter; the generic command API cannot mint or supersede them" }, 403);
					}
					if (command?.type === "approval.record" && (command.kind === "code-review-acceptance" || command.kind === "merge-permission")) {
						return json({ error: "review acceptance and merge permission are not available through the generic command API" }, 403);
					}
					try {
						const event = warroom.command(command);
						return json(event, 201);
					} catch (error) {
						return json({ error: (error as Error).message }, 400);
					}
				},
				() => json({ error: "request body must be JSON" }, 400),
			);
		}

		return json({ error: "not found" }, 404);
	}

	return { warroom, session: { token, actor, port }, dataDir, fetch };
}

export function serve(options: ServerOptions = {}): Server<undefined> {
	const app = createApp(options);
	const server = Bun.serve({ port: options.port ?? 4600, hostname: "127.0.0.1", fetch: app.fetch });
	console.log(`Runecraft Warroom surface at http://127.0.0.1:${server.port} (db: ${options.dbPath ?? ":memory:"})`);
	return server;
}

if (import.meta.main) {
	const dbPath = process.argv[2] ?? process.env.WARROOM_DB;
	if (!dbPath) {
		console.error("usage: bun run src/server.ts <explicit-db-path> [port]");
		console.error("The database and its artifact directory are private state and are never created in the current directory by default.");
		process.exit(1);
	}
	serve({
		dbPath,
		dataDir: process.env.WARROOM_DATA_DIR,
		port: Number(process.argv[3] ?? process.env.WARROOM_PORT ?? 4600),
		actorId: process.env.WARROOM_ACTOR ?? "operator",
	});
}
