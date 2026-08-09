import { pathToFileURL } from "node:url";

const SEMVER_PATTERN = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;

function compareBigInt(left, right) {
	return left < right ? -1 : left > right ? 1 : 0;
}

function compareIdentifier(left, right) {
	const leftNumeric = /^[0-9]+$/.test(left);
	const rightNumeric = /^[0-9]+$/.test(right);
	if (leftNumeric && rightNumeric) return compareBigInt(BigInt(left), BigInt(right));
	if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
	return left < right ? -1 : left > right ? 1 : 0;
}

function parseSemVer(version) {
	const match = SEMVER_PATTERN.exec(version);
	if (!match) throw new Error(`Invalid exact semantic version: ${version}`);
	return {
		core: match.slice(1, 4).map(BigInt),
		prerelease: match[4] === undefined ? null : match[4].split("."),
	};
}

export function compareSemVer(leftVersion, rightVersion) {
	const left = parseSemVer(leftVersion);
	const right = parseSemVer(rightVersion);

	for (let index = 0; index < left.core.length; index += 1) {
		const comparison = compareBigInt(left.core[index], right.core[index]);
		if (comparison !== 0) return comparison;
	}

	if (left.prerelease === null || right.prerelease === null) {
		if (left.prerelease === right.prerelease) return 0;
		return left.prerelease === null ? 1 : -1;
	}

	const length = Math.max(left.prerelease.length, right.prerelease.length);
	for (let index = 0; index < length; index += 1) {
		if (left.prerelease[index] === undefined) return -1;
		if (right.prerelease[index] === undefined) return 1;
		const comparison = compareIdentifier(left.prerelease[index], right.prerelease[index]);
		if (comparison !== 0) return comparison;
	}
	return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
	try {
		if (process.argv.length !== 4) throw new Error("Usage: compare-semver.mjs <left-version> <right-version>");
		process.stdout.write(String(compareSemVer(process.argv[2], process.argv[3])));
	} catch (error) {
		console.error(error instanceof Error ? error.message : String(error));
		process.exitCode = 1;
	}
}
