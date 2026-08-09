import { afterEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { verifyRootReleaseVersion } from "../scripts/verify-release-version.mjs";

type VersionFiles = {
	manifest?: unknown;
	packageJson?: unknown;
};

const tempDirs: string[] = [];

function writeVersionFiles(versions: VersionFiles = {}): string {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-pr-review-release-version-test-"));
	tempDirs.push(dir);
	fs.writeFileSync(path.join(dir, ".release-please-manifest.json"), JSON.stringify({ ".": versions.manifest ?? "1.2.3" }));
	fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({ version: versions.packageJson ?? "1.2.3" }));
	return dir;
}

afterEach(() => {
	for (const dir of tempDirs.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
});

describe("root release-version invariant", () => {
	test("accepts matching Release Please and npm metadata", () => {
		expect(verifyRootReleaseVersion(writeVersionFiles())).toBe("1.2.3");
		expect(verifyRootReleaseVersion(process.cwd())).toMatch(/^\d+\.\d+\.\d+$/);
	});

	for (const [location, versions] of [
		["Release Please manifest", { manifest: "1.2.2" }],
		["package manifest", { packageJson: "1.2.2" }],
	] satisfies [string, VersionFiles][]) {
		test(`rejects a stale ${location}`, () => {
			expect(() => verifyRootReleaseVersion(writeVersionFiles(versions))).toThrow(/Root release version mismatch/);
		});
	}

	test("rejects missing or malformed root versions", () => {
		const missing = fs.mkdtempSync(path.join(os.tmpdir(), "pi-pr-review-release-version-test-"));
		tempDirs.push(missing);
		fs.writeFileSync(path.join(missing, ".release-please-manifest.json"), JSON.stringify({ ".": "1.2.3" }));
		fs.writeFileSync(path.join(missing, "package.json"), JSON.stringify({}));
		expect(() => verifyRootReleaseVersion(missing)).toThrow(/valid semantic version/);
		expect(() => verifyRootReleaseVersion(writeVersionFiles({ packageJson: "not-a-version" }))).toThrow(/valid semantic version/);
	});

	test("rejects leading zeroes in numeric prerelease identifiers even when every field agrees", () => {
		const invalidVersion = "1.2.3-01";
		expect(() => verifyRootReleaseVersion(writeVersionFiles({
			manifest: invalidVersion,
			packageJson: invalidVersion,
		}))).toThrow(/valid semantic version/);
	});

	test("binds publish verification to Release Please's emitted version", () => {
		const dir = writeVersionFiles();
		expect(verifyRootReleaseVersion(dir, "1.2.3")).toBe("1.2.3");
		expect(() => verifyRootReleaseVersion(dir, "1.2.4")).toThrow(/expected release version/);
	});
});
