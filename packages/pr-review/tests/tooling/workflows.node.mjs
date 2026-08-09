import assert from "node:assert/strict";
import * as fs from "node:fs";
import { describe, test } from "node:test";
import { verifyWorkflowSources } from "../../scripts/verify-workflows.mjs";

const pullRequest = fs.readFileSync(".github/workflows/pull-request.yml", "utf8");
const release = fs.readFileSync(".github/workflows/release-please.yml", "utf8");
const packageJson = JSON.parse(fs.readFileSync("package.json", "utf8"));

function sources(overrides = {}) {
	const nextPullRequest = overrides.pullRequest ?? pullRequest;
	const nextRelease = overrides.release ?? release;
	return {
		pullRequest: nextPullRequest,
		release: nextRelease,
		packageJson: overrides.packageJson ?? packageJson,
		allWorkflows: overrides.allWorkflows ?? [
			["pull-request.yml", nextPullRequest],
			["release-please.yml", nextRelease],
		],
	};
}

function replaceOnce(source, before, after) {
	assert.equal(source.split(before).length - 1, 1, `fixture must contain one occurrence of ${before}`);
	return source.replace(before, after);
}

function replaceFirst(source, before, after) {
	assert.ok(source.includes(before), `fixture must contain ${before}`);
	return source.replace(before, after);
}

function rejects(overrides, pattern) {
	assert.throws(() => verifyWorkflowSources(sources(overrides)), pattern);
}

describe("release workflow trust boundaries", () => {
	test("accepts the checked-in workflows", () => {
		assert.doesNotThrow(() => verifyWorkflowSources(sources()));
	});

	test("rejects mutable or unapproved action references", () => {
		rejects({ pullRequest: replaceOnce(pullRequest, "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0", "actions/checkout@v7") }, /not pinned/);
		rejects({ pullRequest: replaceOnce(pullRequest, "oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6", "oven-sh/setup-bun@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") }, /not approved/);
	});

	test("rejects removal of a fail-closed release gate", () => {
		rejects({ release: replaceFirst(release, "vars.NPM_TRUSTED_PUBLISHING_READY == 'true' && ", "") }, /every release job must use gate/);
	});

	test("rejects the deprecated numeric GitHub App ID input", () => {
		rejects({ release: replaceOnce(release, "client-id: ${{ vars.NERV_OPS_CLIENT_ID }}", "app-id: ${{ vars.NERV_OPS_APP_ID }}") }, /Client ID variable|deprecated GitHub App ID/);
	});

	test("rejects credentials or OIDC in validation and packaging", () => {
		rejects({ release: replaceOnce(release, "    outputs:\n      commit_sha:", "    environment: release-automation\n    outputs:\n      commit_sha:") }, /validate must not enter an environment/);
		rejects({ release: replaceOnce(release, "    permissions:\n      contents: read\n    outputs:\n      artifact_digest:", "    permissions:\n      contents: read\n      id-token: write\n    outputs:\n      artifact_digest:") }, /package must not receive OIDC/);
	});

	test("rejects unreviewed Node or Bun versions", () => {
		rejects({ pullRequest: replaceOnce(pullRequest, "node-version: 24.18.0", "node-version: 24") }, /reviewed Node 24 release/);
		rejects({ release: replaceFirst(release, "bun-version: 1.3.14", "bun-version: latest") }, /reviewed Bun release/);
	});

	test("rejects repository execution in the fresh package boundary", () => {
		rejects({ release: replaceOnce(release, "      - name: Build one lifecycle-script-disabled tarball", "      - name: Run untrusted code\n        run: bun test\n\n      - name: Build one lifecycle-script-disabled tarball") }, /must not execute repository code with Bun/);
	});

	test("rejects source checkout or secrets in the OIDC publisher", () => {
		rejects({ release: replaceOnce(release, "      - name: Set up Node.js for trusted publishing", "      - name: Check out source\n        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0\n\n      - name: Set up Node.js for trusted publishing") }, /must not check out/);
		rejects({ release: replaceOnce(release, "          DOWNLOAD_STEP_PATH: ${{ steps.download.outputs.download_path }}", "          DOWNLOAD_STEP_PATH: ${{ steps.download.outputs.download_path }}\n          NPM_AUTH: ${{ secrets.NPM_AUTH }}") }, /only release may reference one environment secret|publish must not reference secrets/);
	});

	test("rejects unsafe artifact archive handling", () => {
		rejects({ release: replaceOnce(release, '[[ "$(sha256sum "$archive" | awk \'{print $1}\')" == "$ARTIFACT_DIGEST" ]] || exit 1', "true") }, /archive digest/);
		rejects({ release: replaceOnce(release, 'unzip -p "$archive" "$TARBALL_FILENAME" > "$tarball_path"', 'unzip "$archive"') }, /stream exactly one expected tarball/);
	});

	test("rejects weakening the exact publication command", () => {
		const command = 'npm publish "$TARBALL_PATH" --access public --provenance --tag "$DIST_TAG" --ignore-scripts';
		rejects({ release: replaceOnce(release, command, 'npm publish "$TARBALL_PATH" --access public') }, /publish one exact tarball/);
	});

	test("rejects persisted pull-request checkout credentials", () => {
		rejects({ pullRequest: replaceOnce(pullRequest, "persist-credentials: false", "persist-credentials: true") }, /must not persist/);
	});

	test("rejects unreviewed workflow files", () => {
		rejects({ allWorkflows: [["pull-request.yml", pullRequest], ["release-please.yml", release], ["extra.yml", "name: Extra\n"]] }, /exactly the reviewed/);
	});
});
