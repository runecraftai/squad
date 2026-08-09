import * as fs from "node:fs";
import * as path from "node:path";
import { pathToFileURL } from "node:url";

// SemVer numeric prerelease identifiers cannot contain leading zeroes.
const NUMERIC_IDENTIFIER = "(?:0|[1-9]\\d*)";
const PRERELEASE_IDENTIFIER = `(?:${NUMERIC_IDENTIFIER}|\\d*[A-Za-z-][0-9A-Za-z-]*)`;
const SEMVER = new RegExp(`^${NUMERIC_IDENTIFIER}\\.${NUMERIC_IDENTIFIER}\\.${NUMERIC_IDENTIFIER}(?:-${PRERELEASE_IDENTIFIER}(?:\\.${PRERELEASE_IDENTIFIER})*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$`);

function readJson(filePath) {
	try {
		return JSON.parse(fs.readFileSync(filePath, "utf8"));
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		throw new Error(`Could not read ${filePath}: ${message}`);
	}
}

function assertVersion(location, value) {
	if (typeof value !== "string" || !SEMVER.test(value)) {
		throw new Error(`${location} must contain a valid semantic version; received ${JSON.stringify(value)}`);
	}
}

/**
 * Verify the root package metadata that Release Please updates in one release PR.
 * This deliberately reads only: Release Please remains the sole version writer.
 */
export function verifyRootReleaseVersion(rootDir = process.cwd(), expectedVersion) {
	const manifest = readJson(path.join(rootDir, ".release-please-manifest.json"));
	const packageJson = readJson(path.join(rootDir, "package.json"));
	const versions = {
		'.release-please-manifest.json["."]': manifest["."],
		"package.json.version": packageJson.version,
	};

	for (const [location, version] of Object.entries(versions)) assertVersion(location, version);
	if (expectedVersion !== undefined) assertVersion("expected release version", expectedVersion);

	const [firstLocation, firstVersion] = Object.entries(versions)[0];
	for (const [location, version] of Object.entries(versions).slice(1)) {
		if (version !== firstVersion) {
			throw new Error(`Root release version mismatch: ${firstLocation} is ${firstVersion}, but ${location} is ${version}`);
		}
	}
	if (expectedVersion !== undefined && firstVersion !== expectedVersion) {
		throw new Error(`Root release version mismatch: ${firstLocation} is ${firstVersion}, but expected release version is ${expectedVersion}`);
	}
	return firstVersion;
}

function main(args) {
	if (args.length === 0) return verifyRootReleaseVersion();
	if (args.length === 2 && args[0] === "--expected") return verifyRootReleaseVersion(process.cwd(), args[1]);
	throw new Error("Usage: node scripts/verify-release-version.mjs [--expected <version>]");
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
	try {
		const version = main(process.argv.slice(2));
		console.log(`Verified root release version ${version}.`);
	} catch (error) {
		console.error(error instanceof Error ? error.message : String(error));
		process.exitCode = 1;
	}
}
