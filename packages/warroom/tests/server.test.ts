import { afterEach, beforeEach, describe, expect, test, setDefaultTimeout } from "bun:test";

setDefaultTimeout(30_000);
import { captureReview } from "../src/review.ts";
import { createApp } from "../src/server.ts";
import { createReviewFixture, disposeFixture, type ReviewFixture } from "./fixtures/review-fixtures.ts";

function post(app: ReturnType<typeof createApp>, path: string, body: unknown) {
	return app.fetch(new Request(`http://local/${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));
}

function get(app: ReturnType<typeof createApp>, path: string) {
	return app.fetch(new Request(`http://local/${path}`));
}

describe("planning surface HTTP API", () => {
	test("GET / serves the static page with no external script or stylesheet references", async () => {
		const app = createApp();
		const response = await app.fetch(new Request("http://127.0.0.1:4600/", { headers: { host: "127.0.0.1:4600" } }));
		expect(response.status).toBe(200);
		const html = await response.text();
		expect(html).toContain("Runecraft Warroom");

		const refs: string[] = [];
		const rewriter = new HTMLRewriter()
			.on("script[src]", { element(element) { const src = element.getAttribute("src"); if (src) refs.push(src); } })
			.on("link[rel=stylesheet]", { element(element) { const href = element.getAttribute("href"); if (href) refs.push(href); } });
		await rewriter.transform(new Response(html)).text();

		const pageOrigin = "http://127.0.0.1:4600";
		const external = refs.filter((ref) => {
			try {
				const resolved = new URL(ref, pageOrigin);
				return (resolved.protocol === "http:" || resolved.protocol === "https:") && resolved.origin !== pageOrigin;
			} catch {
				return true;
			}
		});
		expect(external).toEqual([]);
	});

	test("the command endpoint drives the same invariants as the core directly", async () => {
		const app = createApp();
		const created = await post(app, "api/command", { type: "initiative.create", id: "i1", title: "Proof" });
		expect(created.status).toBe(201);
		await post(app, "api/command", { type: "revision.create", id: "p1", initiativeId: "i1", kind: "plan", content: "plan one" });

		const detail = await (await get(app, "api/initiative/i1")).json();
		expect(detail.initiative.id).toBe("i1");
		expect(detail.revisions).toHaveLength(1);
		expect(detail.timeline).toHaveLength(2);

		const approved = await post(app, "api/command", { type: "approval.record", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved" });
		expect(approved.status).toBe(201);

		const rejected = await post(app, "api/command", { type: "approval.record", initiativeId: "i1", kind: "execution-authorization", revisionId: "missing", decision: "approved" });
		expect(rejected.status).toBe(400);
		const error = await rejected.json();
		expect(error.error).toMatch(/revision/);
	});

	test("recording plan-approval for the current plan revision never creates an execution-authorization record", async () => {
		const app = createApp();
		await post(app, "api/command", { type: "initiative.create", id: "i1", title: "Proof" });
		await post(app, "api/command", { type: "revision.create", id: "p1", initiativeId: "i1", kind: "plan", content: "plan one" });
		await post(app, "api/command", { type: "approval.record", initiativeId: "i1", kind: "plan-approval", revisionId: "p1", decision: "approved" });
		const detail = await (await get(app, "api/initiative/i1")).json();
		expect(detail.approvals.map((a: { kind: string }) => a.kind)).toEqual(["plan-approval"]);
	});

	test("the compare endpoint distinguishes identical content at a new identity from genuinely different content", async () => {
		const app = createApp();
		await post(app, "api/command", { type: "initiative.create", id: "i1", title: "Proof" });
		await post(app, "api/command", { type: "revision.create", id: "p1", initiativeId: "i1", kind: "plan", content: "alpha" });
		await post(app, "api/command", { type: "revision.create", id: "p2", initiativeId: "i1", kind: "plan", content: "beta" });
		await post(app, "api/command", { type: "revision.create", id: "p3", initiativeId: "i1", kind: "plan", content: "alpha" });

		const differ = await (await get(app, "api/compare/i1?a=p1&b=p2")).json();
		expect(differ.identicalContent).toBe(false);

		const restored = await (await get(app, "api/compare/i1?a=p1&b=p3")).json();
		expect(restored.identicalContent).toBe(true);
		expect(restored.sameIdentity).toBe(false);
	});

	test("the question endpoint exercises ask/answer binding through the HTTP surface", async () => {
		const app = createApp();
		await post(app, "api/command", { type: "initiative.create", id: "i1", title: "Proof" });
		await post(app, "api/command", { type: "revision.create", id: "p1", initiativeId: "i1", kind: "plan", content: "plan one" });
		await post(app, "api/command", { type: "question.ask", id: "q1", initiativeId: "i1", revisionId: "p1", prompt: "Safe?" });
		const answered = await post(app, "api/command", { type: "question.answer", initiativeId: "i1", questionId: "q1", answer: "Yes" });
		expect(answered.status).toBe(201);
		const detail = await (await get(app, "api/initiative/i1")).json();
		expect(detail.questions[0].status).toBe("answered");
	});

	test("GET /api/initiative/:id for an unknown initiative returns 404", async () => {
		const app = createApp();
		const response = await get(app, "api/initiative/missing");
		expect(response.status).toBe(404);
	});

	test("the command endpoint rejects non-JSON content types so cross-site simple requests cannot mutate state", async () => {
		const app = createApp();
		const response = await app.fetch(new Request("http://local/api/command", { method: "POST", headers: { "content-type": "text/plain" }, body: JSON.stringify({ type: "initiative.create", id: "i1", title: "Proof" }) }));
		expect(response.status).toBe(415);
		expect(await (await get(app, "api/initiatives")).json()).toEqual([]);
	});

	test("the command endpoint rejects cross-origin requests", async () => {
		const app = createApp();
		const response = await app.fetch(new Request("http://local/api/command", { method: "POST", headers: { "content-type": "application/json", origin: "http://evil.example" }, body: JSON.stringify({ type: "initiative.create", id: "i1", title: "Proof" }) }));
		expect(response.status).toBe(403);
		expect(await (await get(app, "api/initiatives")).json()).toEqual([]);
	});
});

describe("local review surface", () => {
	const origin = "http://127.0.0.1:4600";
	const host = "127.0.0.1:4600";
	const token = "local-session-token";
	let fixture: ReviewFixture;
	let app: ReturnType<typeof createApp>;

	beforeEach(() => {
		fixture = createReviewFixture({ withUnreviewable: false });
		fixture.warroom.close();
		app = createApp({ dbPath: fixture.dbPath, dataDir: fixture.dataDir, port: 4600, actorId: "commander", sessionToken: token });
	});
	afterEach(() => {
		try { app.warroom.close(); } catch { /* closed */ }
		disposeFixture(fixture);
	});

	function request(path: string, init: RequestInit = {}): Promise<Response> {
		return Promise.resolve(app.fetch(new Request(`${origin}${path}`, init)));
	}
	function command(method: "POST", path: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
		return request(path, { method, headers: { "content-type": "application/json", origin, host, "x-warroom-session": token, ...headers }, body: JSON.stringify(body) });
	}

	function seed(provenance: "drill" | "fixture" = "drill") {
		// The fixture warroom is closed; capture through the app's own connection.
		return captureReview(app.warroom, fixture.dataDir, {
			repo: fixture.repo,
			drillDb: fixture.drillDb,
			drillLogs: fixture.drillLogs,
			repoId: fixture.repoId,
			runId: fixture.run1,
			targetRef: "main",
			headRef: "h1",
			planRevisionId: fixture.planRevisionId,
			provenance,
		});
	}

	test("serves packet detail, currentness and exact file bytes without accepting browser paths", async () => {
		const result = seed("drill");
		const detail = await (await request(`/api/review/${result.packetId}`, { headers: { host } })).json();
		expect(detail.packet.id).toBe(result.packetId);
		expect(detail.packet.head_sha).toBe(fixture.h1);
		expect(detail.files.length).toBe(8);
		expect(detail.limitations.mergePermission).toContain("not emitted");
		expect(detail.capture.run.id).toBe(fixture.run1);

		const currentness = await (await request(`/api/review/${result.packetId}/currentness`, { headers: { host } })).json();
		expect(currentness.status).toBe("ready");
		expect(currentness.currentness).toBe("verified");
		expect(currentness.evidenceEligible).toBe(true);

		const file = await (await request(`/api/review/${result.packetId}/file?path=${encodeURIComponent("src/hello.ts")}&side=head`, { headers: { host } })).json();
		expect(file.text).toContain("hello, ${name}!");
		expect(file.lineCount).toBe(4);

		const diff = await (await request(`/api/review/${result.packetId}/diff?path=${encodeURIComponent("docs/path with spaces e acentuação.txt")}`, { headers: { host } })).json();
		expect(diff.lines.some((line: any) => line.type === "added" && line.text === "line two")).toBe(true);

		for (const path of ["../../etc/passwd", "/etc/passwd", "docs/readme-link", "src/does-not-exist.ts"]) {
			const response = await request(`/api/review/${result.packetId}/file?path=${encodeURIComponent(path)}`, { headers: { host } });
			expect(response.status).toBe(404);
		}
	});

	test("requires the expected host, exact local origin and the per-session token, and rejects a body-supplied actor", async () => {
		const result = seed("drill");
		const wrongHost = await app.fetch(new Request(`http://evil.example/api/review/${result.packetId}`));
		expect(wrongHost.status).toBe(403);

		const noToken = await request(`/api/review/${result.packetId}/accept`, {
			method: "POST",
			headers: { "content-type": "application/json", origin, host },
			body: JSON.stringify({ packetDigest: result.packetDigest, scopeDigest: result.scopeDigest, declaration: "ok", actorConfirmed: true }),
		});
		expect(noToken.status).toBe(403);

		const wrongOrigin = await command("POST", `/api/review/${result.packetId}/accept`, {
			packetDigest: result.packetDigest, scopeDigest: result.scopeDigest, declaration: "ok", actorConfirmed: true,
		}, { origin: "http://127.0.0.1:9999" });
		expect(wrongOrigin.status).toBe(403);

		const accepted = await command("POST", `/api/review/${result.packetId}/accept`, {
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "I reviewed this exact head.",
			actorConfirmed: true,
			actor: "somebody-else",
		});
		expect(accepted.status).toBe(201);
		const body = await accepted.json();
		expect(body.actor).toBe("commander");
		expect(body.mergePermission).toContain("not granted");
		const approval = app.warroom.db.query("SELECT actor, declaration FROM approvals WHERE packet_id=?").get(result.packetId) as any;
		expect(approval.actor).toBe("commander");
		expect(approval.declaration).toBe("I reviewed this exact head.");
	});

	test("the generic command API cannot mint evidence, review acceptance or merge permission", async () => {
		const result = seed("drill");
		const before = app.warroom.events(fixture.initiativeId).length;
		for (const body of [
			{ type: "review.capture.record", initiativeId: "i1", revisionId: result.packetId, provenance: "drill", eligible: true },
			{ type: "review.packet.create", initiativeId: "i1", revisionId: result.packetId },
			{ type: "validation.record", initiativeId: "i1", revisionId: "plan-1", provider: "drill", result: "passed" },
			{ type: "approval.record", initiativeId: "i1", kind: "merge-permission", revisionId: result.packetId, decision: "approved" },
			{ type: "approval.record", initiativeId: "i1", kind: "code-review-acceptance", revisionId: result.packetId, decision: "approved", evidenceId: result.evidenceId },
		]) {
			const response = await app.fetch(new Request("http://local/api/command", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));
			expect(response.status).toBe(403);
		}
		expect(app.warroom.events(fixture.initiativeId).length).toBe(before);
		expect(app.warroom.db.query("SELECT COUNT(*) AS n FROM approvals WHERE packet_id IS NOT NULL").get()).toEqual({ n: 0 });
	});

	test("a stale snapshot token from another tab is refused without recording acceptance", async () => {
		const first = seed("drill");
		const second = captureReview(app.warroom, fixture.dataDir, {
			repo: fixture.repo,
			drillDb: fixture.drillDb,
			repoId: fixture.repoId,
			runId: fixture.run2,
			targetRef: "main",
			headRef: "h2",
			planRevisionId: fixture.planRevisionId,
			provenance: "drill",
		});
		const response = await command("POST", `/api/review/${second.packetId}/accept`, {
			packetDigest: first.packetDigest,
			scopeDigest: first.scopeDigest,
			declaration: "stale tab",
			actorConfirmed: true,
		});
		expect(response.status).toBe(400);
		expect(app.warroom.db.query("SELECT COUNT(*) AS n FROM approvals WHERE packet_id=?").get(second.packetId)).toEqual({ n: 0 });
	});

	test("comments store hostile text as data, resolve without approval, and never travel to the next snapshot", async () => {
		const result = seed("drill");
		const files = app.warroom.db.query("SELECT capture_json FROM evidence_captures WHERE id=?").get(result.evidenceId) as any;
		expect(files).toBeDefined();
		const packet = app.warroom.db.query("SELECT * FROM review_packets WHERE id=?").get(result.packetId) as any;
		const manifest = JSON.parse((app.warroom.db.query("SELECT content FROM revisions WHERE id=?").get(packet.code_revision_id) as any).content);
		const hello = manifest.files.find((file: any) => file.path === "src/hello.ts");
		const hostile = `<script>alert("x")</script><img src=x onerror=alert(1)>`;
		const created = await command("POST", `/api/review/${result.packetId}/comments`, {
			targetType: "code-range",
			path: "src/hello.ts",
			side: "head",
			startLine: 1,
			endLine: 3,
			blobSha: hello.head.blob,
			kind: "comment",
			body: hostile,
		});
		expect(created.status).toBe(201);
		const { commentId } = await created.json();
		const stored = app.warroom.db.query("SELECT body, snapshot_digest FROM comments WHERE id=?").get(commentId) as any;
		expect(stored.body).toBe(hostile);
		expect(stored.snapshot_digest).toBe(result.packetDigest);

		const resolved = await command("POST", `/api/review/${result.packetId}/comments/resolve`, { commentId });
		expect(resolved.status).toBe(200);
		expect(app.warroom.db.query("SELECT COUNT(*) AS n FROM approvals WHERE packet_id=?").get(result.packetId)).toEqual({ n: 0 });
	});

	test("export is a read-only derived snapshot with no remote resource and no state change", async () => {
		const result = seed("drill");
		const packet = app.warroom.db.query("SELECT * FROM review_packets WHERE id=?").get(result.packetId) as any;
		const manifest = JSON.parse((app.warroom.db.query("SELECT content FROM revisions WHERE id=?").get(packet.code_revision_id) as any).content);
		const hello = manifest.files.find((file: any) => file.path === "src/hello.ts");
		await command("POST", `/api/review/${result.packetId}/comments`, {
			targetType: "code-range",
			path: "src/hello.ts",
			side: "head",
			startLine: 1,
			endLine: 3,
			blobSha: hello.head.blob,
			kind: "comment",
			body: `<script>alert("export")</script>`,
		});
		await command("POST", `/api/review/${result.packetId}/request-changes`, {
			packetDigest: result.packetDigest,
			scopeDigest: result.scopeDigest,
			declaration: "Fix the validation before merge.",
			actorConfirmed: true,
		});
		const before = app.warroom.events(fixture.initiativeId).length;
		const approvalsBefore = app.warroom.db.query("SELECT COUNT(*) AS n FROM approvals").get();
		const response = await request(`/api/review/${result.packetId}/export`, { headers: { host } });
		expect(response.status).toBe(200);
		expect(response.headers.get("content-type")).toContain("text/html");
		const html = await response.text();
		expect(html).toContain("records no acceptance and authorizes no merge");
		expect(html).not.toContain("<script>alert");
		expect(html).not.toMatch(/<[^>]*(?:src|href)\s*=\s*["']?https?:/i);
		expect(html).not.toContain("<button");
		expect(html).toContain(result.packetDigest);
		// Replayed comments and approvals keep their anchor, author, digest and decision.
		expect(html).toContain("src/hello.ts:1-3");
		expect(html).toContain("commander");
		expect(html).toContain("Fix the validation before merge.");
		expect(html).toContain("changes-requested");
		expect(html).toContain(result.packetDigest.slice(0, 16));
		expect(app.warroom.events(fixture.initiativeId).length).toBe(before);
		expect(app.warroom.db.query("SELECT COUNT(*) AS n FROM approvals").get()).toEqual(approvalsBefore);
		const exportPath = response.headers.get("x-warroom-export-path")!;
		expect(exportPath.endsWith(`${result.packetId}.html`)).toBe(true);
	});

	test("packet listings and initiative state keep the recorded local repository path server-side", async () => {
		const result = seed("drill");
		expect((app.warroom.db.query("SELECT repo_path FROM review_packets WHERE id=?").get(result.packetId) as any).repo_path).toBeTruthy();
		const list = await (await request(`/api/review/packets?initiativeId=i1`, { headers: { host } })).json();
		expect(list).toHaveLength(1);
		expect(list[0]).not.toHaveProperty("repo_path");
		const initiative = await (await request(`/api/initiative/i1`, { headers: { host } })).json();
		expect(initiative.packets).toHaveLength(1);
		expect(initiative.packets[0]).not.toHaveProperty("repoPath");
	});

	test("unsafe command identifiers and traversal-shaped packet ids are rejected before any export path is built", async () => {
		const created = await command("POST", "/api/command", { type: "initiative.create", id: "../escape", title: "Escape" });
		expect(created.status).toBe(400);
		const traversal = await request(`/api/review/..%2Fescape/export`, { headers: { host } });
		expect(traversal.status).toBe(400);
		expect(app.warroom.db.query("SELECT COUNT(*) AS n FROM initiatives WHERE id LIKE '%escape%'").get()).toEqual({ n: 0 });
	});
});

describe("mixed reviewable sides", () => {
	let mixedFixture: ReviewFixture;
	let mixedApp: ReturnType<typeof createApp>;

	beforeEach(() => {
		mixedFixture = createReviewFixture();
		mixedFixture.warroom.close();
		mixedApp = createApp({ dbPath: mixedFixture.dbPath, dataDir: mixedFixture.dataDir, port: 4600, actorId: "commander", sessionToken: "mixed-token" });
	});
	afterEach(() => {
		try { mixedApp.warroom.close(); } catch { /* closed */ }
		disposeFixture(mixedFixture);
	});

	test("a diff whose base side is binary is refused instead of rendering an inferred empty side", async () => {
		const result = captureReview(mixedApp.warroom, mixedFixture.dataDir, {
			repo: mixedFixture.repo,
			drillDb: mixedFixture.drillDb,
			repoId: mixedFixture.repoId,
			runId: mixedFixture.run1,
			targetRef: "main",
			headRef: "h1",
			planRevisionId: mixedFixture.planRevisionId,
			provenance: "fixture",
		});
		const response = await mixedApp.fetch(new Request(`http://127.0.0.1:4600/api/review/${result.packetId}/diff?path=${encodeURIComponent("docs/mixed.txt")}`, { headers: { host: "127.0.0.1:4600" } }));
		expect(response.status).toBe(409);
		const body = await response.json();
		expect(body.sides.base).toEqual({ present: true, reviewable: false, reason: "binary" });
		expect(body.sides.head).toEqual({ present: true, reviewable: true, reason: null });
	});
});
