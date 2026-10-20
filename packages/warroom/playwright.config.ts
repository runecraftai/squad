import { defineConfig } from "@playwright/test";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * Browser suite for the local review surface.
 *
 * It runs only against the private fixture server in `tests/fixtures/review-server.ts`, which
 * uses a disposable Git repository, a synthetic Drill-shaped database and a private Warroom data
 * directory. No credential, real Drill database or real project is used, and the suite never
 * records a human acceptance.
 */

const port = Number(process.env.WARROOM_E2E_PORT ?? "4711");
// Playwright transpiles this config for Node, where CommonJS `__dirname` is available.
const root = __dirname;

export default defineConfig({
	testDir: "./e2e",
	fullyParallel: false,
	workers: 1,
	timeout: 60_000,
	expect: { timeout: 10_000 },
	// Local validation state lives under .drill/, which the repository ignores.
	outputDir: process.env.WARROOM_E2E_OUTPUT ?? join(root, ".drill", "e2e-results"),
	use: {
		baseURL: `http://127.0.0.1:${port}`,
		trace: "off",
		video: "off",
		screenshot: "only-on-failure",
	},
	webServer: {
		command: "bun run tests/fixtures/review-server.ts",
		cwd: root,
		url: `http://127.0.0.1:${port}/`,
		reuseExistingServer: false,
		timeout: 60_000,
		env: {
			...process.env,
			WARROOM_E2E_PORT: String(port),
			WARROOM_E2E_INFO: process.env.WARROOM_E2E_INFO ?? join(tmpdir(), `warroom-e2e-${port}.json`),
		},
	},
});
