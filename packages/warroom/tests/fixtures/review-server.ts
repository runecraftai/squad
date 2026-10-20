import { writeFileSync } from "node:fs";
import { createApp } from "../../src/server.ts";
import { captureFixture, createReviewFixture } from "./review-fixtures.ts";

/**
 * Browser-test fixture server. It serves the real local surface over a private synthetic
 * repository, synthetic Drill-shaped database and synthetic Warroom data. The capture is stored
 * with `fixture` provenance, so the page shows a reviewable snapshot whose acceptance stays
 * disabled: automation must never record a human acceptance on the commander's behalf.
 */

const port = Number(process.env.WARROOM_E2E_PORT ?? "4711");
const infoPath = process.env.WARROOM_E2E_INFO;

const fixture = createReviewFixture();
const result = captureFixture(fixture, "h1", "fixture");
fixture.warroom.close();
const app = createApp({ dbPath: fixture.dbPath, dataDir: fixture.dataDir, port, actorId: "commander", sessionToken: "e2e-session" });

const server = Bun.serve({ port, hostname: "127.0.0.1", fetch: app.fetch });

if (infoPath) {
	writeFileSync(infoPath, JSON.stringify({
		port,
		root: fixture.root,
		repo: fixture.repo,
		dataDir: fixture.dataDir,
		h1: fixture.h1,
		h2: fixture.h2,
		packetId: result.packetId,
		packetDigest: result.packetDigest,
		scopeDigest: result.scopeDigest,
	}), { mode: 0o600 });
}
console.log(`review fixture server listening on http://127.0.0.1:${server.port}`);
