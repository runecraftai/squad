import { describe, expect, test } from "bun:test";
import { createApp } from "../src/server.ts";

function post(app: ReturnType<typeof createApp>, path: string, body: unknown) {
	return app.fetch(new Request(`http://local/${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));
}

function get(app: ReturnType<typeof createApp>, path: string) {
	return app.fetch(new Request(`http://local/${path}`));
}

describe("planning surface HTTP API", () => {
	test("GET / serves the static page with no external script or stylesheet references", async () => {
		const app = createApp();
		const response = await get(app, "");
		expect(response.status).toBe(200);
		const html = await response.text();
		expect(html).toContain("Runecraft Warroom");
		expect(html).not.toMatch(/https?:\/\//);
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
});
