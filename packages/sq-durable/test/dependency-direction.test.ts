import { execFileSync, spawnSync } from "node:child_process";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { PACKAGE_DIR } from "./helpers.js";

const CHECK = join(PACKAGE_DIR, "scripts", "check-core-deps.mjs");

describe("dependency direction of the neutral core", () => {
	it("passes for src/core: it imports only itself, Pi Durable and node:crypto", () => {
		const output = execFileSync(process.execPath, [CHECK, join(PACKAGE_DIR, "src", "core")], { encoding: "utf8" });
		expect(output).toContain("core dependency direction ok");
	});

	it("fails for the negative fixture, a core module that imports the Squad adapter", () => {
		const run = spawnSync(process.execPath, [CHECK, join(PACKAGE_DIR, "test", "fixtures", "forbidden-core")], { encoding: "utf8" });
		expect(run.status).toBe(1);
		expect(run.stderr).toContain("src/adapter/squad.js");
		expect(run.stderr).toContain("leaves the core");
		// The allowed sibling import in the same fixture is not reported.
		expect(run.stderr).not.toContain("helpers.js");
	});
});
