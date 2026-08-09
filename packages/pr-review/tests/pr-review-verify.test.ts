import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
	discoverVerificationBaselines,
	parseRepositoryRemote,
	resolveUserVerificationBaselines,
	validateBaselineProfile,
	validateVerifyRequest,
	verifyPullRequestHead,
	type RepositoryIdentity,
	type VerificationBaselines,
} from "../lib/pr-review-verify.ts";

const roots: string[] = [];
const identity: RepositoryIdentity = { host: "github.example", owner: "acme", repo: "widget" };
const executable = fs.realpathSync(process.execPath);

afterEach(() => {
	for (const root of roots.splice(0)) {
		for (const entry of fs.existsSync(root) ? fs.readdirSync(root) : []) {
			try { fs.chmodSync(path.join(root, entry), 0o700); } catch { /* best effort */ }
		}
		fs.rmSync(root, { recursive: true, force: true });
	}
});

function git(cwd: string, ...args: string[]): string {
	return execFileSync("git", ["-C", cwd, ...args], {
		encoding: "utf8",
		env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
	}).trim();
}

interface Fixture {
	root: string;
	repo: string;
	headSha: string;
	tempRoot: string;
	external: string;
	ghExecutable: string;
	gitExecutable: string;
	ghState: string;
	gitLog: string;
}

function createFixture(): Fixture {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "pi-pr-review-verify-test-"));
	roots.push(root);
	const remote = path.join(root, "remote.git");
	const repo = path.join(root, "repo");
	const tempRoot = path.join(root, "tool-temp");
	const external = path.join(root, "external");
	const ghState = path.join(root, "gh-state.json");
	const gitLog = path.join(root, "git-log.jsonl");
	const ghExecutable = path.join(root, "fake-gh");
	const gitExecutable = path.join(root, "fake-git");
	fs.mkdirSync(tempRoot);
	fs.mkdirSync(external);
	execFileSync("git", ["init", "--bare", remote], { stdio: "ignore" });
	execFileSync("git", ["init", repo], { stdio: "ignore" });
	git(repo, "config", "user.name", "PR Verify Test");
	git(repo, "config", "user.email", "verify@example.invalid");
	fs.writeFileSync(
		path.join(repo, "verify-script.js"),
		`const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const mode = process.argv[2];
const arg = process.argv[3];
if (mode === "success") { console.log("verified:" + process.cwd()); process.exit(0); }
if (mode === "success-descendant") {
  const ready = arg + ".ready";
  const child = spawn(process.execPath, [__filename, "descendant-child", ready], { stdio: "inherit" });
  const waitUntil = Date.now() + 1000;
  while (!fs.existsSync(ready) && Date.now() < waitUntil) {}
  if (!fs.existsSync(ready)) process.exit(9);
  fs.writeFileSync(arg, String(child.pid));
  process.exit(0);
}
if (mode === "failure") { console.error("expected failure"); process.exit(7); }
if (mode === "output") { process.stdout.write(Buffer.alloc(100000, 1)); process.exit(0); }
if (mode === "wait") { process.on("SIGTERM", () => {}); setInterval(() => {}, 1000); }
if (mode === "descendant") {
  const child = spawn(process.execPath, [__filename, "descendant-child"], { stdio: "ignore" });
  fs.writeFileSync(arg, String(child.pid));
  process.on("SIGTERM", () => process.exit(0));
  setInterval(() => {}, 1000);
}
if (mode === "descendant-child") {
  process.on("SIGTERM", () => {});
  if (arg) fs.writeFileSync(arg, "ready");
  setInterval(() => {}, 1000);
}
if (mode === "cleanup-fault") { fs.chmodSync(path.dirname(process.cwd()), 0); process.exit(0); }
if (mode === "marker") { fs.writeFileSync(arg, "spawned"); process.exit(0); }
if (mode === "env") { fs.writeFileSync(arg, JSON.stringify(Object.keys(process.env).sort())); process.exit(0); }
if (mode === "env-values") { fs.writeFileSync(arg, JSON.stringify(process.env)); process.exit(0); }
`,
	);
	git(repo, "add", "verify-script.js");
	git(repo, "commit", "-m", "test fixture");
	git(repo, "remote", "add", "origin", remote);
	git(repo, "push", "origin", "HEAD:refs/pull/7/head");
	git(repo, "remote", "set-url", "origin", "https://github.example/acme/widget.git");
	const headSha = git(repo, "rev-parse", "HEAD");
	fs.writeFileSync(ghState, JSON.stringify({
		headSha,
		isCrossRepository: false,
		headRepository: "acme/widget",
		isPrivate: false,
		token: "fixture-secret-token",
	}));
	fs.writeFileSync(ghExecutable, `#!${process.execPath}
const fs = require("node:fs");
const state = JSON.parse(fs.readFileSync(${JSON.stringify(ghState)}, "utf8"));
const args = process.argv.slice(2);
if (args[0] === "pr" && args[1] === "view") {
  console.log(JSON.stringify({ headRefOid: state.headSha, isCrossRepository: state.isCrossRepository, headRepository: { nameWithOwner: state.headRepository } }));
} else if (args[0] === "repo" && args[1] === "view") {
  console.log(JSON.stringify({ nameWithOwner: "acme/widget", isPrivate: state.isPrivate, url: "https://github.example/acme/widget" }));
} else if (args[0] === "auth" && args[1] === "token" && state.token) {
  console.log(state.token);
} else {
  console.error("no token configured");
  process.exit(1);
}
`, { mode: 0o700 });
	fs.writeFileSync(gitExecutable, `#!${process.execPath}
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");
const original = process.argv.slice(2);
const canonicalUrl = "https://github.example/acme/widget.git";
const args = original.map((arg) => arg === canonicalUrl ? ${JSON.stringify(remote)} : arg);
if (original.includes("fetch")) {
  const state = JSON.parse(fs.readFileSync(${JSON.stringify(ghState)}, "utf8"));
  const networkFetch = original.includes(canonicalUrl);
  const helper = process.env.GIT_ASKPASS;
  let username = "";
  let passwordMatches = false;
  let syntheticStdoutBytes = 0;
  let syntheticStderrBytes = 0;
  const emit = (stream, value) => {
    const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value);
    if (stream === "stdout") syntheticStdoutBytes += bytes.length;
    else syntheticStderrBytes += bytes.length;
    process[stream].write(bytes);
  };
  if (networkFetch && helper && helper !== "/usr/bin/false") {
    username = spawnSync(helper, ["Username for canonical HTTPS repository"], { env: process.env, encoding: "utf8" }).stdout.trim();
    const password = spawnSync(helper, ["Password for canonical HTTPS repository"], { env: process.env, encoding: "utf8" }).stdout.trim();
    passwordMatches = password === "fixture-secret-token";
  }
  if (networkFetch && state.probeCredentialHelpers) {
    const fetchIndex = original.indexOf("fetch");
    const probe = spawnSync("/usr/bin/git", [...original.slice(0, fetchIndex), "credential", "fill"], {
      env: process.env,
      input: "protocol=https\\nhost=github.example\\npath=acme/widget.git\\n\\n",
      encoding: "utf8",
    });
    if (probe.stdout) emit("stdout", probe.stdout);
    if (probe.stderr) emit("stderr", probe.stderr);
  }
  if (networkFetch && state.leakFetchToken) {
    emit("stdout", "fetch-stdout:" + process.env.PI_PR_REVIEW_GH_TOKEN + "\\n");
    emit("stderr", "fetch-stderr:" + process.env.PI_PR_REVIEW_GH_TOKEN + "\\n");
  }
  if (networkFetch && state.boundaryLeakFetchToken) {
    const token = Buffer.from(process.env.PI_PR_REVIEW_GH_TOKEN);
    const captureCap = state.boundaryCaptureCap;
    const helperOutput = Buffer.from("gh-askpass.sh helper output\\n");
    const tokenStart = captureCap - 4;
    const lead = Buffer.concat([helperOutput, Buffer.alloc(tokenStart - helperOutput.length, 0x78)]);
    emit("stdout", Buffer.concat([lead, token.subarray(0, 8)]));
    emit("stdout", Buffer.concat([token.subarray(8), Buffer.from(":token-suffix-output\\n")]));
    emit("stderr", "gh-askpass.sh stderr helper output:secret-token\\n");
  }
  if (networkFetch && state.fetchDiagnosticOutput) {
    emit("stdout", "bounded unauthenticated fetch stdout\\n");
    emit("stderr", "bounded unauthenticated fetch stderr\\n");
  }
  if (networkFetch && state.forceFetchFailure) emit("stderr", "fatal: authentication failed\\n");
  const gitDirIndex = original.indexOf("--git-dir");
  const gitDir = gitDirIndex >= 0 ? original[gitDirIndex + 1] : undefined;
  fs.appendFileSync(${JSON.stringify(gitLog)}, JSON.stringify({
    argv: original,
    networkFetch,
    hasSetupToken: Object.prototype.hasOwnProperty.call(process.env, "PI_PR_REVIEW_GH_TOKEN"),
    hasOriginalSentinel: Object.prototype.hasOwnProperty.call(process.env, "ORIGINAL_ENV_SENTINEL"),
    askpassIsTemporary: Boolean(helper && helper.includes("pi-pr-review-") && helper.endsWith("gh-askpass.sh")),
    askpassMode: networkFetch && helper && helper !== "/usr/bin/false" ? fs.statSync(helper).mode & 0o777 : null,
    username,
    passwordMatches,
    localConfigExists: Boolean(gitDir && fs.existsSync(gitDir + "/config")),
    hookEntries: gitDir && fs.existsSync(gitDir + "/hooks") ? fs.readdirSync(gitDir + "/hooks") : [],
    gitConfigNoSystem: process.env.GIT_CONFIG_NOSYSTEM,
    gitConfigGlobal: process.env.GIT_CONFIG_GLOBAL,
    syntheticStdoutBytes,
    syntheticStderrBytes,
  }) + "\\n");
  if (networkFetch && state.hangFetch) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
  if (networkFetch && state.forceFetchFailure) process.exit(128);
}
const child = spawnSync("/usr/bin/git", args, { env: process.env, encoding: "buffer" });
if (original.includes("fetch") && !original.includes(canonicalUrl) && child.status === 0) {
  const state = JSON.parse(fs.readFileSync(${JSON.stringify(ghState)}, "utf8"));
  if (state.removeImportedRef) {
    const repoIndex = original.indexOf("-C");
    const destination = original.at(-1).split(":").at(-1);
    spawnSync("/usr/bin/git", ["-C", original[repoIndex + 1], "update-ref", "-d", destination], { env: process.env });
  }
}
if (child.stdout) process.stdout.write(child.stdout);
if (child.stderr) process.stderr.write(child.stderr);
process.exit(child.status === null ? 1 : child.status);
`, { mode: 0o700 });
	return { root, repo, headSha, tempRoot, external, ghExecutable, gitExecutable, ghState, gitLog };
}

function profile(mode: string, timeout = 5_000, extraArg?: string, extra: Record<string, unknown> = {}): VerificationBaselines {
	return {
		baseline: {
			repository: identity,
			argv: [executable, "verify-script.js", mode, ...(extraArg ? [extraArg] : [])],
			platforms: [process.platform],
			totalTimeoutMs: timeout,
			acknowledgeUnsandboxedPrCodeRisk: true,
			...extra,
		},
	};
}

function request(headSha: string) {
	return { prNumber: 7, headSha, baselineName: "baseline" };
}

function options(fixture: Fixture) {
	return {
		tempRoot: fixture.tempRoot,
		repositoryIdentity: identity,
		ghExecutable: fixture.ghExecutable,
		gitExecutable: fixture.gitExecutable,
		ghEnvironment: { ...process.env, ORIGINAL_ENV_SENTINEL: "must-not-reach-git-or-baseline" },
		killGraceMs: 30,
		drainMs: 30,
	};
}

function startupToolBin(fixture: Fixture): string {
	const bin = path.join(fixture.root, "startup-bin");
	fs.mkdirSync(bin, { mode: 0o700 });
	fs.symlinkSync(fixture.gitExecutable, path.join(bin, "git"));
	fs.symlinkSync(fixture.ghExecutable, path.join(bin, "gh"));
	return bin;
}

function updateGhState(fixture: Fixture, patch: Record<string, unknown>): void {
	const current = JSON.parse(fs.readFileSync(fixture.ghState, "utf8"));
	fs.writeFileSync(fixture.ghState, JSON.stringify({ ...current, ...patch }));
}

function allFetchLogs(fixture: Fixture): Array<Record<string, unknown>> {
	if (!fs.existsSync(fixture.gitLog)) return [];
	return fs.readFileSync(fixture.gitLog, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

function fetchLogs(fixture: Fixture): Array<Record<string, unknown>> {
	return allFetchLogs(fixture).filter((entry) => entry.networkFetch === true);
}

function installMaliciousReferenceTransactionHook(fixture: Fixture): { marker: string; leak: string } {
	const hooks = path.join(fixture.repo, ".git", "hooks");
	const hook = path.join(hooks, "reference-transaction");
	const marker = path.join(fixture.external, "reference-transaction-ran");
	const leak = path.join(fixture.external, "reference-transaction-token");
	fs.writeFileSync(hook, `#!/bin/sh
cat >/dev/null
printf 'ran' >> ${JSON.stringify(marker)}
printf '%s' "$PI_PR_REVIEW_GH_TOKEN" >> ${JSON.stringify(leak)}
`, { mode: 0o700 });
	return { marker, leak };
}

function installMaliciousCredentialHelper(fixture: Fixture): { helper: string; marker: string; leak: string } {
	const helper = path.join(fixture.external, "malicious-credential-helper.sh");
	const marker = path.join(fixture.external, "credential-helper-ran");
	const leak = path.join(fixture.external, "credential-helper-token");
	fs.writeFileSync(helper, `#!/bin/sh
cat >/dev/null
printf 'ran' > ${JSON.stringify(marker)}
printf '%s' "$PI_PR_REVIEW_GH_TOKEN" > ${JSON.stringify(leak)}
printf 'username=attacker\\npassword=%s\\n' "$PI_PR_REVIEW_GH_TOKEN"
`, { mode: 0o700 });
	git(fixture.repo, "config", "credential.helper", `!${helper}`);
	git(fixture.repo, "config", "credential.https://github.example.helper", `!${helper}`);
	return { helper, marker, leak };
}

function assertClean(repo: string, tempRoot: string): void {
	expect(fs.readdirSync(tempRoot)).toEqual([]);
	const worktrees = git(repo, "worktree", "list", "--porcelain")
		.split("\n")
		.filter((line) => line.startsWith("worktree "));
	expect(worktrees).toHaveLength(1);
	expect(git(repo, "for-each-ref", "--format=%(refname)", "refs/pi-pr-review")).toBe("");
}

function processExists(pid: number): boolean {
	try { process.kill(pid, 0); return true; } catch (error) { return (error as NodeJS.ErrnoException).code !== "ESRCH"; }
}

describe("strict trusted verification profiles", () => {
	test("requires repository identity, fixed absolute argv, POSIX platforms, timeout, and explicit risk acknowledgement", () => {
		const valid = validateBaselineProfile("unit", {
			repository: identity,
			argv: [executable, "test"],
			platforms: [process.platform],
			totalTimeoutMs: 5_000,
			acknowledgeUnsandboxedPrCodeRisk: true,
		});
		expect(valid.errors).toEqual([]);
		expect(valid.profile?.allowForks).toBeFalse();

		expect(validateBaselineProfile("unit", {
			repository: { ...identity, extra: true },
			argv: ["bun", "test"],
			platforms: ["win32"],
			totalTimeoutMs: 1,
			acknowledgeUnsandboxedPrCodeRisk: false,
			command: "rm -rf /",
		}).errors).toEqual(expect.arrayContaining([
			'unknown profile field "command"',
			'unknown repository field "extra"',
			"argv[0] must be an absolute executable path",
			"acknowledgeUnsandboxedPrCodeRisk must be exactly true",
		]));
		expect(validateVerifyRequest({ prNumber: 0, headSha: "ABC", baselineName: "bad name" })).toHaveLength(3);
		expect(parseRepositoryRemote("git@github.com:owner/repo.git")).toEqual({ host: "github.com", owner: "owner", repo: "repo" });
	});

	test("ignores project-local profile overlays even when a project defines names", () => {
		const user = { verificationBaselines: { userOnly: profile("success").baseline } };
		const project = { verificationBaselines: { projectOnly: profile("failure").baseline, userOnly: profile("failure").baseline } };
		expect(resolveUserVerificationBaselines(user, project)).toEqual(user.verificationBaselines);
		expect(resolveUserVerificationBaselines({}, project)).toEqual({});
	});

	test("discovers only applicable names, disables missing config, and rejects noncanonical executables", async () => {
		const fixture = createFixture();
		const disabled = await discoverVerificationBaselines(fixture.repo, undefined, undefined, options(fixture));
		expect(disabled).toMatchObject({ enabled: false, baselines: [] });

		const configured = {
			...profile("success"),
			otherRepo: { ...profile("success").baseline, repository: { ...identity, repo: "other" } },
			badExecutable: { ...profile("success").baseline, argv: [path.dirname(executable) + "/../" + path.basename(path.dirname(executable)) + "/" + path.basename(executable), "verify-script.js", "success"] },
		};
		const discovered = await discoverVerificationBaselines(fixture.repo, configured, undefined, options(fixture));
		expect(discovered.enabled).toBeTrue();
		expect(discovered.baselines.map((entry) => entry.name)).toEqual(["baseline"]);
		expect(discovered.riskDisclosure).toContain("without a filesystem or network sandbox");
		expect(discovered.riskDisclosure).toContain("acknowledgeUnsandboxedPrCodeRisk=true");
		expect(discovered.riskDisclosure).toContain("only the original POSIX process group");
		expect(discovered.riskDisclosure).toContain("setsid");
		expect(discovered.riskDisclosure).toContain("external sandbox or container wrapper");
	});

	test("resolves canonical git and gh from the trusted startup PATH for discovery and run", async () => {
		const fixture = createFixture();
		const startupPath = startupToolBin(fixture);
		const discovered = await discoverVerificationBaselines(fixture.repo, profile("success"), undefined, {
			tempRoot: fixture.tempRoot,
			startupPath,
			killGraceMs: 30,
			drainMs: 30,
		});
		expect(discovered.enabled).toBeTrue();
		const result = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("success"), undefined, {
			tempRoot: fixture.tempRoot,
			startupPath,
			ghEnvironment: process.env,
			killGraceMs: 30,
			drainMs: 30,
		});
		expect(result.primaryOutcome.outcome).toBe("success");
		assertClean(fixture.repo, fixture.tempRoot);
	});

	test("fails clearly and without temp side effects when trusted startup PATH has no git", async () => {
		const fixture = createFixture();
		const emptyBin = path.join(fixture.root, "empty-startup-bin");
		fs.mkdirSync(emptyBin);
		const discovery = await discoverVerificationBaselines(fixture.repo, profile("success"), undefined, {
			tempRoot: fixture.tempRoot,
			startupPath: emptyBin,
		});
		expect(discovery.enabled).toBeFalse();
		expect(discovery.message).toContain("Unable to resolve an accessible git executable from the trusted extension startup PATH");
		const result = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("success"), undefined, {
			tempRoot: fixture.tempRoot,
			startupPath: emptyBin,
		});
		expect(result.primaryOutcome.outcome).toBe("setup_failure");
		expect(result.message).toContain("Unable to resolve an accessible git executable from the trusted extension startup PATH");
		expect(fs.readdirSync(fixture.tempRoot)).toEqual([]);
	});

	test("fails closed on the unsupported Windows adapter without side effects", async () => {
		const fixture = createFixture();
		const result = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("success"), undefined, {
			...options(fixture), platform: "win32",
		});
		expect(result.primaryOutcome.outcome).toBe("unsupported_platform");
		expect(result.cleanupOutcome.outcome).toBe("not_needed");
		expect(fs.readdirSync(fixture.tempRoot)).toEqual([]);
	});
});

describe("extension-owned PR verification lifecycle", () => {
	test("runs the fixed profile, preserves FETCH_HEAD, reports failure, and cleans up", async () => {
		const fixture = createFixture();
		const fetchHead = path.join(fixture.repo, ".git", "FETCH_HEAD");
		fs.writeFileSync(fetchHead, "sentinel-fetch-head\n");
		const success = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("success"), undefined, options(fixture));
		expect(success).toMatchObject({
			outcome: "success",
			primaryOutcome: { outcome: "success", phase: "command" },
			terminationOutcome: { outcome: "not_needed" },
			cleanupOutcome: { outcome: "success", worktreeRemoved: true, tempDirRemoved: true, fetchRefRemoved: true },
			lifecycleOk: true,
		});
		expect(success.stdout).toContain("verified:");
		expect(fs.readFileSync(fetchHead, "utf8")).toBe("sentinel-fetch-head\n");
		assertClean(fixture.repo, fixture.tempRoot);

		const failure = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("failure"), undefined, options(fixture));
		expect(failure).toMatchObject({ outcome: "failure", primaryOutcome: { outcome: "failure" }, exitCode: 7, lifecycleOk: false });
		expect(failure.stderr).toContain("expected failure");
		assertClean(fixture.repo, fixture.tempRoot);
	});

	test("rejects a stale head and never runs the configured command", async () => {
		const fixture = createFixture();
		const marker = path.join(fixture.external, "marker");
		const staleSha = `${fixture.headSha.slice(0, -1)}${fixture.headSha.endsWith("0") ? "1" : "0"}`;
		const stale = await verifyPullRequestHead(fixture.repo, request(staleSha), profile("marker", 5_000, marker), undefined, options(fixture));
		expect(stale.primaryOutcome.outcome).toBe("stale_head");
		expect(fs.existsSync(marker)).toBeFalse();
		expect(fetchLogs(fixture)).toEqual([]);
		assertClean(fixture.repo, fixture.tempRoot);
	});

	test("verifies the exact SHA both in staging and after local import before execution", async () => {
		const stagedFixture = createFixture();
		const stagedMarker = path.join(stagedFixture.external, "staged-marker");
		fs.writeFileSync(path.join(stagedFixture.repo, "later.txt"), "later\n");
		git(stagedFixture.repo, "add", "later.txt");
		git(stagedFixture.repo, "commit", "-m", "later remote head");
		execFileSync("git", [
			"-C", stagedFixture.repo, "push", path.join(stagedFixture.root, "remote.git"),
			"+HEAD:refs/pull/7/head",
		], { stdio: "ignore" });
		const stagedMismatch = await verifyPullRequestHead(
			stagedFixture.repo,
			request(stagedFixture.headSha),
			profile("marker", 5_000, stagedMarker),
			undefined,
			options(stagedFixture),
		);
		expect(stagedMismatch.primaryOutcome.outcome).toBe("stale_head");
		expect(stagedMismatch.message).toContain("Staged pull-request head");
		expect(fs.existsSync(stagedMarker)).toBeFalse();
		assertClean(stagedFixture.repo, stagedFixture.tempRoot);

		const importedFixture = createFixture();
		const importedMarker = path.join(importedFixture.external, "imported-marker");
		updateGhState(importedFixture, { removeImportedRef: true });
		const importedMismatch = await verifyPullRequestHead(
			importedFixture.repo,
			request(importedFixture.headSha),
			profile("marker", 5_000, importedMarker),
			undefined,
			options(importedFixture),
		);
		expect(importedMismatch.primaryOutcome.outcome).toBe("stale_head");
		expect(importedMismatch.message).toContain("Imported pull-request head (unresolved)");
		expect(fs.existsSync(importedMarker)).toBeFalse();
		assertClean(importedFixture.repo, importedFixture.tempRoot);
	});

	test("rejects fork PRs before fetch unless the trusted profile allows forks", async () => {
		const rejectedFixture = createFixture();
		const rejectedMarker = path.join(rejectedFixture.external, "marker");
		updateGhState(rejectedFixture, { isCrossRepository: true, headRepository: "contributor/widget" });
		const rejected = await verifyPullRequestHead(
			rejectedFixture.repo,
			request(rejectedFixture.headSha),
			profile("marker", 5_000, rejectedMarker),
			undefined,
			options(rejectedFixture),
		);
		expect(rejected.primaryOutcome).toMatchObject({ outcome: "not_applicable", phase: "validation" });
		expect(rejected.message).toContain("rejects cross-repository pull requests from contributor/widget");
		expect(fetchLogs(rejectedFixture)).toEqual([]);
		expect(fs.existsSync(rejectedMarker)).toBeFalse();
		assertClean(rejectedFixture.repo, rejectedFixture.tempRoot);

		const allowedFixture = createFixture();
		updateGhState(allowedFixture, { isCrossRepository: true, headRepository: "contributor/widget" });
		const allowed = await verifyPullRequestHead(
			allowedFixture.repo,
			request(allowedFixture.headSha),
			profile("success", 5_000, undefined, { allowForks: true }),
			undefined,
			options(allowedFixture),
		);
		expect(allowed.primaryOutcome.outcome).toBe("success");
		expect(fetchLogs(allowedFixture)).toHaveLength(1);
		assertClean(allowedFixture.repo, allowedFixture.tempRoot);
	});

	test("stages authenticated fetch away from original hooks/config, then imports locally without the token", async () => {
		const fixture = createFixture();
		const envFile = path.join(fixture.external, "baseline-env.json");
		const maliciousHook = installMaliciousReferenceTransactionHook(fixture);
		const result = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("env", 5_000, envFile), undefined, options(fixture));
		expect(result.primaryOutcome.outcome).toBe("success");
		const logs = fetchLogs(fixture);
		expect(logs).toHaveLength(1);
		expect(logs[0]).toMatchObject({
			networkFetch: true,
			hasSetupToken: true,
			hasOriginalSentinel: false,
			askpassIsTemporary: true,
			askpassMode: 0o700,
			username: "x-access-token",
			passwordMatches: true,
			localConfigExists: false,
			hookEntries: [],
			gitConfigNoSystem: "1",
			gitConfigGlobal: "/dev/null",
		});
		const networkArgv = logs[0]?.argv as string[];
		expect(networkArgv).toContain("https://github.example/acme/widget.git");
		expect(networkArgv).toContain("--git-dir");
		expect(networkArgv).not.toContain(fixture.repo);
		expect(networkArgv).not.toContain("origin");
		const importLog = allFetchLogs(fixture).find((entry) => entry.networkFetch === false)!;
		expect(importLog).toMatchObject({
			hasSetupToken: false,
			hasOriginalSentinel: false,
			askpassIsTemporary: false,
		});
		expect((importLog.argv as string[])[(importLog.argv as string[]).indexOf("fetch") + 4]).toContain("fetch.git");
		expect(fs.existsSync(maliciousHook.marker)).toBeTrue();
		expect(fs.readFileSync(maliciousHook.leak, "utf8")).toBe("");
		const baselineKeys: string[] = JSON.parse(fs.readFileSync(envFile, "utf8"));
		expect(baselineKeys).not.toContain("PI_PR_REVIEW_GH_TOKEN");
		expect(baselineKeys).not.toContain("GH_TOKEN");
		expect(baselineKeys).not.toContain("GITHUB_TOKEN");
		expect(baselineKeys).not.toContain("ORIGINAL_ENV_SENTINEL");
		expect(JSON.stringify(result)).not.toContain("fixture-secret-token");
		expect(JSON.stringify(result)).not.toContain("gh-askpass.sh");
		assertClean(fixture.repo, fixture.tempRoot);
	});

	test("blocks local credential helpers and suppresses all authenticated fetch output", async () => {
		const fixture = createFixture();
		const envFile = path.join(fixture.external, "baseline-env-values.json");
		const malicious = installMaliciousCredentialHelper(fixture);
		updateGhState(fixture, { probeCredentialHelpers: true, leakFetchToken: true });

		const success = await verifyPullRequestHead(
			fixture.repo,
			request(fixture.headSha),
			profile("env-values", 5_000, envFile),
			undefined,
			options(fixture),
		);
		expect(success.primaryOutcome.outcome).toBe("success");
		expect(fs.existsSync(malicious.marker)).toBeFalse();
		expect(fs.existsSync(malicious.leak)).toBeFalse();
		const baselineEnv: Record<string, string> = JSON.parse(fs.readFileSync(envFile, "utf8"));
		expect(baselineEnv.PI_PR_REVIEW_GH_TOKEN).toBeUndefined();
		expect(baselineEnv.ORIGINAL_ENV_SENTINEL).toBeUndefined();
		expect(baselineEnv.GIT_ASKPASS).toBe("/usr/bin/false");
		const successJson = JSON.stringify(success);
		expect(successJson).not.toContain("fixture-secret-token");
		expect(successJson).not.toContain("gh-askpass.sh");
		expect(successJson).not.toContain("must-not-reach-git-or-baseline");
		expect(successJson).not.toContain(malicious.helper);
		assertClean(fixture.repo, fixture.tempRoot);

		updateGhState(fixture, { forceFetchFailure: true });
		const failed = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("success"), undefined, options(fixture));
		expect(failed.primaryOutcome.outcome).toBe("setup_failure");
		expect(fs.existsSync(malicious.marker)).toBeFalse();
		expect(fs.existsSync(malicious.leak)).toBeFalse();
		expect(JSON.stringify(failed)).not.toContain("fixture-secret-token");
		expect(failed.stdout).toBe("");
		expect(failed.stderr).toBe("");
		expect(failed.message).toBe("Authenticated HTTPS fetch of the canonical repository failed; captured fetch output was suppressed.");
		expect(failed.output.capturedBytes).toEqual({ stdout: 0, stderr: 0, total: 0 });
		const failedLog = fetchLogs(fixture).at(-1)!;
		expect(failed.output.droppedBytes).toEqual({
			stdout: failedLog.syntheticStdoutBytes,
			stderr: failedLog.syntheticStderrBytes,
			total: Number(failedLog.syntheticStdoutBytes) + Number(failedLog.syntheticStderrBytes),
		});
		assertClean(fixture.repo, fixture.tempRoot);
	});

	test("suppresses authenticated token fragments and helper output across the capture boundary", async () => {
		const fixture = createFixture();
		const captureCap = 24 * 1024;
		updateGhState(fixture, { boundaryLeakFetchToken: true, boundaryCaptureCap: captureCap, forceFetchFailure: true });
		const result = await verifyPullRequestHead(
			fixture.repo,
			request(fixture.headSha),
			profile("success"),
			undefined,
			options(fixture),
		);
		const log = fetchLogs(fixture).at(-1)!;
		const serialized = JSON.stringify(result);
		expect(result.primaryOutcome.outcome).toBe("setup_failure");
		expect(result.stdout).toBe("");
		expect(result.stderr).toBe("");
		expect(serialized).not.toContain("fixt");
		expect(serialized).not.toContain("secret-token");
		expect(serialized).not.toContain("token-suffix-output");
		expect(serialized).not.toContain("gh-askpass.sh");
		expect(serialized).not.toContain("fatal: authentication failed");
		expect(result.output.capturedBytes).toEqual({ stdout: 0, stderr: 0, total: 0 });
		expect(result.output.droppedBytes).toEqual({
			stdout: log.syntheticStdoutBytes,
			stderr: log.syntheticStderrBytes,
			total: Number(log.syntheticStdoutBytes) + Number(log.syntheticStderrBytes),
		});
		expect(result.output.droppedBytes.total).toBeGreaterThan(captureCap);
		assertClean(fixture.repo, fixture.tempRoot);
	});

	test("preserves diagnostics only for unauthenticated public fetch failures", async () => {
		const fixture = createFixture();
		updateGhState(fixture, { token: null, leakFetchToken: true, forceFetchFailure: true });
		const result = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("success"), undefined, options(fixture));
		expect(result.primaryOutcome.outcome).toBe("setup_failure");
		expect(result.stderr).toContain("fatal: authentication failed");
		expect(result.message).toContain("Unauthenticated public HTTPS fetch");
		expect(result.message).toContain("fatal: authentication failed");
		expect(result.output.capturedBytes.total + result.output.droppedBytes.total).toBe(
			Number(fetchLogs(fixture).at(-1)!.syntheticStdoutBytes) + Number(fetchLogs(fixture).at(-1)!.syntheticStderrBytes),
		);
		assertClean(fixture.repo, fixture.tempRoot);
	});

	test("retains bounded unauthenticated fetch diagnostics and byte accounting on timeout and abort", async () => {
		const timeoutFixture = createFixture();
		updateGhState(timeoutFixture, { token: null, fetchDiagnosticOutput: true, hangFetch: true });
		const timedOut = await verifyPullRequestHead(
			timeoutFixture.repo,
			request(timeoutFixture.headSha),
			profile("success", 2_000),
			undefined,
			options(timeoutFixture),
		);
		expect(timedOut.primaryOutcome.outcome).toBe("timeout");
		expect(timedOut.stdout).toContain("bounded unauthenticated fetch stdout");
		expect(timedOut.stderr).toContain("bounded unauthenticated fetch stderr");
		const timeoutLog = fetchLogs(timeoutFixture).at(-1)!;
		expect(timedOut.output.capturedBytes.total + timedOut.output.droppedBytes.total).toBe(
			Number(timeoutLog.syntheticStdoutBytes) + Number(timeoutLog.syntheticStderrBytes),
		);
		assertClean(timeoutFixture.repo, timeoutFixture.tempRoot);

		const abortFixture = createFixture();
		updateGhState(abortFixture, { token: null, fetchDiagnosticOutput: true, hangFetch: true });
		const controller = new AbortController();
		const pending = verifyPullRequestHead(
			abortFixture.repo,
			request(abortFixture.headSha),
			profile("success", 5_000),
			controller.signal,
			options(abortFixture),
		);
		for (let index = 0; index < 200 && fetchLogs(abortFixture).length === 0; index++) await Bun.sleep(5);
		expect(fetchLogs(abortFixture)).toHaveLength(1);
		controller.abort();
		const aborted = await pending;
		expect(aborted.primaryOutcome.outcome).toBe("aborted");
		expect(aborted.stdout).toContain("bounded unauthenticated fetch stdout");
		expect(aborted.stderr).toContain("bounded unauthenticated fetch stderr");
		const abortLog = fetchLogs(abortFixture).at(-1)!;
		expect(aborted.output.capturedBytes.total + aborted.output.droppedBytes.total).toBe(
			Number(abortLog.syntheticStdoutBytes) + Number(abortLog.syntheticStderrBytes),
		);
		assertClean(abortFixture.repo, abortFixture.tempRoot);
	});

	test("permits public fetch without a token and clearly reports private auth failure", async () => {
		const publicFixture = createFixture();
		updateGhState(publicFixture, { token: null });
		const publicResult = await verifyPullRequestHead(publicFixture.repo, request(publicFixture.headSha), profile("success"), undefined, options(publicFixture));
		expect(publicResult.primaryOutcome.outcome).toBe("success");
		expect(fetchLogs(publicFixture)[0]).toMatchObject({ hasSetupToken: false, askpassIsTemporary: false });
		assertClean(publicFixture.repo, publicFixture.tempRoot);

		const privateFixture = createFixture();
		updateGhState(privateFixture, { token: null, isPrivate: true });
		const privateResult = await verifyPullRequestHead(privateFixture.repo, request(privateFixture.headSha), profile("success"), undefined, options(privateFixture));
		expect(privateResult.primaryOutcome.outcome).toBe("setup_failure");
		expect(privateResult.message).toContain("Private canonical repository fetch requires a gh host token");
		expect(privateResult.message).toContain("gh auth login");
		expect(fetchLogs(privateFixture)).toEqual([]);
		assertClean(privateFixture.repo, privateFixture.tempRoot);
	});

	test("pre-abort returns before temp directories, subprocesses, or listeners can have effects", async () => {
		const fixture = createFixture();
		const marker = path.join(fixture.external, "marker");
		const controller = new AbortController();
		controller.abort();
		const result = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("marker", 5_000, marker), controller.signal, options(fixture));
		expect(result.primaryOutcome.outcome).toBe("aborted");
		expect(result.cleanupOutcome.outcome).toBe("not_needed");
		expect(fs.readdirSync(fixture.tempRoot)).toEqual([]);
		expect(fs.existsSync(marker)).toBeFalse();
	});

	test("uses one bounded total deadline with reserved cleanup time", async () => {
		const fixture = createFixture();
		const started = performance.now();
		const result = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("wait", 2_000), undefined, options(fixture));
		const elapsed = performance.now() - started;
		expect(result.primaryOutcome.outcome).toBe("timeout");
		expect(result.terminationOutcome).toMatchObject({ attempted: true, outcome: "success" });
		// The fixed two-second emergency cleanup allowance is unconditionally
		// available to bounded cleanup beyond the profile budget.
		expect(elapsed).toBeLessThan(4_500);
		expect(result.timing.totalMs).toBeLessThan(4_500);
		assertClean(fixture.repo, fixture.tempRoot);
	});

	test("contains background descendants before preserving a successful primary outcome", async () => {
		const fixture = createFixture();
		const pidFile = path.join(fixture.external, "successful-descendant.pid");
		let descendantPid = 0;
		try {
			const result = await verifyPullRequestHead(
				fixture.repo,
				request(fixture.headSha),
				profile("success-descendant", 5_000, pidFile),
				undefined,
				options(fixture),
			);
			descendantPid = Number(fs.readFileSync(pidFile, "utf8"));
			expect(result.primaryOutcome.outcome).toBe("success");
			expect(result.outcome).toBe("success");
			expect(result.lifecycleOk).toBeTrue();
			expect(result.terminationOutcome).toMatchObject({
				attempted: true,
				outcome: "success",
				reasons: ["residual_descendants"],
				termSignalsSent: 1,
				killAttempts: 1,
				killSignalsSent: 1,
				drained: true,
			});
			expect(processExists(descendantPid)).toBeFalse();
			assertClean(fixture.repo, fixture.tempRoot);
		} finally {
			if (descendantPid && processExists(descendantPid)) {
				try { process.kill(descendantPid, "SIGKILL"); } catch { /* best effort */ }
			}
		}
	});

	test("always KILLs the POSIX group after grace when the leader exits on TERM", async () => {
		const fixture = createFixture();
		const pidFile = path.join(fixture.external, "descendant.pid");
		const result = await verifyPullRequestHead(
			fixture.repo,
			request(fixture.headSha),
			profile("descendant", 5_000, pidFile, { allowForks: true }),
			undefined,
			options(fixture),
		);
		const descendantPid = Number(fs.readFileSync(pidFile, "utf8"));
		// The verifier has already drained the original group. Give init a bounded
		// window to reap a just-killed orphan before probing its PID on busy hosts.
		for (let i = 0; i < 100 && processExists(descendantPid); i++) await Bun.sleep(10);
		expect(result.primaryOutcome.outcome).toBe("timeout");
		// The final KILL is mandatory even if the group is already gone after TERM;
		// delivery is OS-race-dependent, but the attempt and drained state are not.
		expect(result.terminationOutcome).toMatchObject({ attempted: true, outcome: "success", killAttempts: 1, drained: true });
		expect(processExists(descendantPid)).toBeFalse();
		assertClean(fixture.repo, fixture.tempRoot);
	});

	test("shares raw output capacity, sanitizes controls, and bounds final serialization with exact dropped bytes", async () => {
		const fixture = createFixture();
		updateGhState(fixture, { token: null });
		const result = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("output"), undefined, options(fixture));
		expect(result.primaryOutcome.outcome).toBe("success");
		expect(result.stdout).not.toContain("\u0001");
		expect(result.output.capturedBytes.total + result.output.droppedBytes.total).toBe(100_000);
		expect(result.output.droppedBytes.total).toBeGreaterThan(0);
		expect(Buffer.byteLength(JSON.stringify(result, null, 2))).toBeLessThanOrEqual(result.output.serializedMaxBytes);
		assertClean(fixture.repo, fixture.tempRoot);
	});

	test("preserves primary success while reporting cleanup as an independent failure", async () => {
		const fixture = createFixture();
		const result = await verifyPullRequestHead(fixture.repo, request(fixture.headSha), profile("cleanup-fault"), undefined, options(fixture));
		expect(result.primaryOutcome.outcome).toBe("success");
		expect(result.outcome).toBe("cleanup_failure");
		expect(result.cleanupOutcome.outcome).toBe("failure");
		expect(result.lifecycleOk).toBeFalse();
		expect(result.message).toContain("Cleanup failed");
		for (const entry of fs.readdirSync(fixture.tempRoot)) fs.chmodSync(path.join(fixture.tempRoot, entry), 0o700);
		git(fixture.repo, "worktree", "prune");
	});
});
