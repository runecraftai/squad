import * as fs from "node:fs";
import * as path from "node:path";
import { pathToFileURL } from "node:url";

const ACTION_PINS = Object.freeze({
	"actions/checkout": "9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
	"actions/create-github-app-token": "bcd2ba49218906704ab6c1aa796996da409d3eb1",
	"actions/setup-node": "820762786026740c76f36085b0efc47a31fe5020",
	"actions/upload-artifact": "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
	"googleapis/release-please-action": "45996ed1f6d02564a971a2fa1b5860e934307cf7",
	"oven-sh/setup-bun": "0c5077e51419868618aeaa5fe8019c62421857d6",
});

function invariant(condition, message) {
	if (!condition) throw new Error(`Workflow invariant failed: ${message}`);
}

function occurrences(source, pattern) {
	return [...source.matchAll(pattern)].length;
}

function jobBlock(source, name) {
	const marker = new RegExp(`^  ${name}:\\n`, "gm");
	const matches = [...source.matchAll(marker)];
	invariant(matches.length === 1, `release workflow must define ${name} exactly once`);
	const start = matches[0].index;
	const remainder = source.slice(start + matches[0][0].length);
	const next = remainder.search(/^  [A-Za-z0-9_-]+:\n/m);
	return source.slice(start, next === -1 ? source.length : start + matches[0][0].length + next);
}

function assertIncludes(source, text, message) {
	invariant(source.includes(text), message);
}

function assertImmutableActionPins(workflows) {
	for (const [filename, source] of workflows) {
		const uses = [...source.matchAll(/^\s*uses:\s*([^\s#]+)(?:\s+#.*)?$/gm)].map((match) => match[1]);
		for (const use of uses) {
			const match = /^([^@]+)@([0-9a-f]{40})$/.exec(use);
			invariant(match, `${filename} action is not pinned to a full commit SHA: ${use}`);
			invariant(ACTION_PINS[match[1]] === match[2], `${filename} action pin is not approved: ${use}`);
		}
	}
}

export function verifyWorkflowSources({ pullRequest, release, packageJson, allWorkflows }) {
	invariant(typeof pullRequest === "string" && typeof release === "string", "required workflows must be readable");
	invariant(Array.isArray(allWorkflows) && allWorkflows.length === 2, "repository must contain exactly the reviewed pull-request and release workflows");
	assertImmutableActionPins(allWorkflows);

	assertIncludes(pullRequest, "permissions:\n  contents: read", "pull-request workflow must be read-only");
	assertIncludes(pullRequest, "persist-credentials: false", "pull-request checkout must not persist its token");
	invariant(occurrences(pullRequest, /^\s+node-version: 24\.18\.0$/gm) === 1, "pull-request CI must use the reviewed Node 24 release");
	invariant(occurrences(pullRequest, /^\s+bun-version: 1\.3\.14$/gm) === 1, "pull-request CI must use the reviewed Bun release");
	assertIncludes(pullRequest, "run: bun test", "pull-request CI must run the Bun test suite");
	assertIncludes(pullRequest, "npm run test:tooling", "pull-request CI must run tooling policy tests");
	assertIncludes(pullRequest, "npm run verify:workflows", "pull-request CI must verify workflow policy");
	assertIncludes(pullRequest, "npm run verify:package", "pull-request CI must inspect the package with scripts disabled");
	assertIncludes(pullRequest, "ACTIONLINT_VERSION: 1.7.7", "actionlint must be pinned");
	assertIncludes(pullRequest, "ACTIONLINT_SHA256: 023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757", "actionlint archive checksum must be pinned");

	assertIncludes(release, "permissions: {}", "release workflow must deny permissions by default");
	for (const gate of ["vars.RELEASE_AUTOMATION_ENABLED == 'true'", "vars.NPM_TRUSTED_PUBLISHING_READY == 'true'", "github.ref == 'refs/heads/main'"]) {
		invariant(occurrences(release, new RegExp(gate.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g")) === 4, `every release job must use gate: ${gate}`);
	}
	const jobsBoundary = release.indexOf("\njobs:\n");
	invariant(jobsBoundary !== -1, "release workflow must define jobs");
	const jobsSource = release.slice(jobsBoundary + 7);
	const jobs = [...jobsSource.matchAll(/^  ([A-Za-z0-9_-]+):\n/gm)].map((match) => match[1]);
	invariant(JSON.stringify(jobs) === JSON.stringify(["release", "validate", "package", "publish"]), "release workflow job graph must remain release, validate, package, publish");

	const releaseJob = jobBlock(release, "release");
	const validate = jobBlock(release, "validate");
	const packageJob = jobBlock(release, "package");
	const publish = jobBlock(release, "publish");

	assertIncludes(releaseJob, "environment: release-automation", "App key must be scoped to release-automation");
	assertIncludes(releaseJob, "client-id: ${{ vars.NERV_OPS_CLIENT_ID }}", "App token must use the non-secret Client ID variable");
	invariant(!/(?:NERV_OPS_APP_ID|\bapp-id:)/.test(releaseJob), "deprecated GitHub App ID inputs are forbidden");
	assertIncludes(releaseJob, "permission-contents: write", "App token must request contents write explicitly");
	assertIncludes(releaseJob, "permission-pull-requests: write", "App token must request pull-requests write explicitly");
	invariant(occurrences(release, /\bsecrets(?:\.|\[)/g) === 1, "only release may reference one environment secret");
	invariant(occurrences(release, /actions\/create-github-app-token@/g) === 1, "only release may create an App token");
	invariant(!/(?:steps\.release|needs\.release)\.outputs\.version/.test(release), "workflow must derive versions from documented tag_name output");

	invariant(!/\benvironment:/.test(validate), "validate must not enter an environment");
	invariant(!/\bid-token:/.test(validate), "validate must not receive OIDC");
	invariant(!/\bsecrets(?:\.|\[)/.test(validate), "validate must not reference secrets");
	assertIncludes(validate, "persist-credentials: false", "validate checkout must not persist credentials");
	assertIncludes(validate, "run: bun test", "validate must run the Bun test suite");
	assertIncludes(validate, "npm run verify:package", "validate must inspect the release package");
	invariant(!/\bnpm\s+(?:ci|install)\b/.test(validate), "validate must not install npm packages");
	const ancestryIndex = validate.indexOf("Verify tag identity and main ancestry before source execution");
	const testIndex = validate.indexOf("run: bun test");
	invariant(ancestryIndex !== -1 && testIndex > ancestryIndex, "tag identity and ancestry must be verified before source execution");

	invariant(!/\benvironment:/.test(packageJob), "package must not enter an environment");
	invariant(!/\bid-token:/.test(packageJob), "package must not receive OIDC");
	invariant(!/\bsecrets(?:\.|\[)/.test(packageJob), "package must not reference secrets");
	invariant(!/\bbun\s+/.test(packageJob), "fresh package job must not execute repository code with Bun");
	invariant(!/\bnpm\s+(?:ci|install|test|run)\b/.test(packageJob), "fresh package job must not install dependencies or execute repository scripts");
	invariant(occurrences(packageJob, /^\s+npm pack --ignore-scripts --json --pack-destination /gm) === 1, "package job must build exactly one lifecycle-script-disabled tarball");
	assertIncludes(packageJob, "persist-credentials: false", "package checkout must not persist credentials");

	assertIncludes(publish, "environment: npm-publish", "publish must use the npm-publish environment");
	assertIncludes(publish, "      actions: read\n      id-token: write", "publish must have exactly artifact read and OIDC permissions");
	invariant(occurrences(release, /^\s+node-version: 24\.18\.0$/gm) === 3, "release execution must use the reviewed Node 24 release");
	invariant(occurrences(release, /^\s+bun-version: 1\.3\.14$/gm) === 1, "release validation must use the reviewed Bun release");
	invariant(!/actions\/checkout@/.test(publish), "publish must not check out repository source");
	invariant(!/actions\/download-artifact@/.test(publish), "publish must avoid the deprecated artifact extraction dependency");
	invariant(!/\bsecrets(?:\.|\[)/.test(publish), "publish must not reference secrets");
	invariant(!/\bbun\s+/.test(publish), "publish must not execute Bun");
	invariant(!/\bnpm\s+(?:ci|install|test|run|pack)\b/.test(publish), "publish must not install dependencies, execute repository scripts, or build packages");
	assertIncludes(publish, '"repos/$GITHUB_REPOSITORY/actions/artifacts/$ARTIFACT_ID/zip" > "$archive"', "publish must download only the validated artifact ID");
	assertIncludes(publish, '[[ "$(sha256sum "$archive" | awk \'{print $1}\')" == "$ARTIFACT_DIGEST" ]] || exit 1', "publish must verify the artifact archive digest before inspection");
	assertIncludes(publish, '[[ "${entries[0]}" == "$TARBALL_FILENAME" ]] || exit 1', "publish must require exactly the expected archive entry");
	invariant(occurrences(publish, /^\s+unzip -p "\$archive" "\$TARBALL_FILENAME" > "\$tarball_path"$/gm) === 1, "publish must stream exactly one expected tarball from the artifact archive");
	invariant(occurrences(release, /^\s+npm publish "\$TARBALL_PATH" --access public --provenance --tag "\$DIST_TAG" --ignore-scripts$/gm) === 1, "workflow must publish one exact tarball with provenance and scripts disabled");
	invariant(occurrences(release, /\bnpm publish\b/g) === 1, "release workflow must contain one npm publish command");
	invariant(occurrences(release, /^\s+id-token: write$/gm) === 1, "only publish may receive OIDC");
	invariant(!/(secrets\.GITHUB_TOKEN|\bNPM_TOKEN\b)/.test(`${pullRequest}\n${release}`), "token fallbacks are forbidden");

	invariant(packageJson && typeof packageJson === "object", "package.json must be readable");
	invariant(packageJson.publishConfig?.provenance === true, "package provenance must be enabled");
	invariant(packageJson.scripts?.["verify:workflows"] === "node scripts/verify-workflows.mjs", "verify:workflows script must be wired");
	invariant(packageJson.scripts?.["verify:package"] === "node scripts/verify-package-contents.mjs", "verify:package script must be wired");
	invariant(packageJson.scripts?.["test:tooling"]?.includes("tests/tooling/workflows.node.mjs"), "workflow tests must run in test:tooling");
}

export function verifyWorkflows(rootDir = process.cwd()) {
	const workflowDir = path.join(rootDir, ".github/workflows");
	const filenames = fs.readdirSync(workflowDir).filter((name) => /\.ya?ml$/.test(name)).sort();
	const allWorkflows = filenames.map((name) => [name, fs.readFileSync(path.join(workflowDir, name), "utf8")]);
	const sources = new Map(allWorkflows);
	const packageJson = JSON.parse(fs.readFileSync(path.join(rootDir, "package.json"), "utf8"));
	verifyWorkflowSources({
		pullRequest: sources.get("pull-request.yml"),
		release: sources.get("release-please.yml"),
		packageJson,
		allWorkflows,
	});
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
	try {
		verifyWorkflows();
		console.log("Verified release workflow trust boundaries.");
	} catch (error) {
		console.error(error instanceof Error ? error.message : String(error));
		process.exitCode = 1;
	}
}
