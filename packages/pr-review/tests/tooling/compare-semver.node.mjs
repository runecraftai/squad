import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { compareSemVer } from "../../scripts/compare-semver.mjs";

describe("release semantic-version comparison", () => {
	test("orders stable and prerelease versions by SemVer precedence", () => {
		assert.equal(compareSemVer("1.7.1", "1.7.0"), 1);
		assert.equal(compareSemVer("2.0.0-beta.2", "2.0.0-beta.1"), 1);
		assert.equal(compareSemVer("2.0.0-beta.1", "2.0.0"), -1);
		assert.equal(compareSemVer("1.7.0", "1.7.0"), 0);
	});

	test("handles large identifiers and ignores build metadata", () => {
		assert.equal(compareSemVer("999999999999999999999.0.0", "2.0.0"), 1);
		assert.equal(compareSemVer("1.0.0+build.2", "1.0.0+build.1"), 0);
	});

	test("rejects inexact versions", () => {
		for (const value of ["v1.0.0", "1.0", "01.0.0", "1.0.0-01", "latest"]) {
			assert.throws(() => compareSemVer(value, "1.0.0"), /Invalid exact semantic version/);
		}
	});
});
