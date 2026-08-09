import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { monotonicNow, type MonotonicNow } from "./pr-review-telemetry.ts";
import { resolveTrustedExecutableFromStartupPath } from "./trusted-executable.ts";

export const VERIFY_TIMEOUT_MIN_MS = 2_000;
export const VERIFY_TIMEOUT_MAX_MS = 10 * 60_000;
export const VERIFY_OUTPUT_MAX_BYTES = 24 * 1024;
export const VERIFY_SERIALIZED_MAX_BYTES = 64 * 1024;

export const POSIX_PLATFORMS = ["aix", "android", "darwin", "freebsd", "haiku", "linux", "openbsd", "sunos"] as const;
export type PosixPlatform = (typeof POSIX_PLATFORMS)[number];

export interface RepositoryIdentity {
	host: string;
	owner: string;
	repo: string;
}

export interface VerificationBaselineProfile {
	repository: RepositoryIdentity;
	argv: [string, ...string[]];
	platforms: PosixPlatform[];
	totalTimeoutMs: number;
	allowForks: boolean;
	acknowledgeUnsandboxedPrCodeRisk: true;
	description?: string;
}

export type VerificationBaselines = Record<string, unknown>;

export interface VerifyRequest {
	prNumber: number;
	headSha: string;
	baselineName: string;
}

export type VerifyPrimaryOutcome =
	| "success"
	| "failure"
	| "timeout"
	| "aborted"
	| "stale_head"
	| "invalid_input"
	| "disabled"
	| "not_applicable"
	| "unsupported_platform"
	| "setup_failure";

export type VerifyOutcome = VerifyPrimaryOutcome | "termination_failure" | "cleanup_failure";

export interface VerifyResult {
	outcome: VerifyOutcome;
	primaryOutcome: { outcome: VerifyPrimaryOutcome; phase: "validation" | "setup" | "command"; message: string };
	terminationOutcome: {
		attempted: boolean;
		outcome: "not_needed" | "success" | "failure";
		reasons: Array<"timeout" | "abort" | "residual_descendants">;
		termSignalsSent: number;
		/** KILL attempts include already-gone groups; delivered signals are counted separately. */
		killAttempts: number;
		killSignalsSent: number;
		drained: boolean;
		errors: string[];
	};
	cleanupOutcome: {
		attempted: boolean;
		outcome: "not_needed" | "success" | "failure";
		worktreeRemoved: boolean;
		tempDirRemoved: boolean;
		fetchRefRemoved: boolean;
		errors: string[];
	};
	lifecycleOk: boolean;
	prNumber: number;
	headSha: string;
	baselineName: string;
	profile?: {
		repository: RepositoryIdentity;
		argv: string[];
		platforms: PosixPlatform[];
		totalTimeoutMs: number;
		allowForks: boolean;
		description?: string;
	};
	repository?: RepositoryIdentity;
	repoRoot?: string;
	exitCode?: number;
	signal?: string;
	stdout: string;
	stderr: string;
	output: {
		capturedBytes: { stdout: number; stderr: number; total: number };
		droppedBytes: { stdout: number; stderr: number; total: number };
		sanitized: true;
		serializedMaxBytes: number;
	};
	message: string;
	riskDisclosure: string;
	timing: { totalMs: number; setupMs: number; commandMs: number; cleanupMs: number };
}

export interface BaselineDiscoveryResult {
	action: "list";
	enabled: boolean;
	platform: NodeJS.Platform;
	repository?: RepositoryIdentity;
	baselines: Array<{
		name: string;
		description?: string;
		totalTimeoutMs: number;
		allowForks: boolean;
		repository: RepositoryIdentity;
	}>;
	rejected: Array<{ name: string; errors: string[] }>;
	message: string;
	riskDisclosure: string;
}

export interface VerifyOptions {
	tempRoot?: string;
	outputMaxBytes?: number;
	serializedMaxBytes?: number;
	killGraceMs?: number;
	drainMs?: number;
	now?: MonotonicNow;
	platform?: NodeJS.Platform;
	/** Test-only repository identity override; production resolves origin. */
	repositoryIdentity?: RepositoryIdentity;
	/** Test-only executable injection; production resolves canonical tools from startupPath. */
	ghExecutable?: string;
	/** Test-only executable injection; production resolves canonical tools from startupPath. */
	gitExecutable?: string;
	/** Trusted PATH captured once when the extension starts. */
	startupPath?: string;
	/** Test-only gh setup environment source; never inherited by the baseline command. */
	ghEnvironment?: NodeJS.ProcessEnv;
}

interface CapturedOutput {
	stdout: Buffer;
	stderr: Buffer;
	observedStdout: number;
	observedStderr: number;
}

interface ProcessTermination {
	attempted: boolean;
	reason?: "timeout" | "abort" | "residual_descendants";
	termSent: boolean;
	killAttempted: boolean;
	killSent: boolean;
	drained: boolean;
	errors: string[];
}

interface ProcessResult {
	exitCode: number | null;
	signal: string | null;
	output: CapturedOutput;
	timedOut: boolean;
	aborted: boolean;
	spawnError?: string;
	termination: ProcessTermination;
}

interface PullRequestMetadata {
	headSha: string;
	isCrossRepository: boolean;
	headRepository?: string;
	canonicalRepositoryPrivate: boolean;
}

interface DeadlineOptions {
	cwd?: string;
	env?: NodeJS.ProcessEnv;
	signal?: AbortSignal;
	deadlineMs: number;
	outputMaxBytes: number;
	killGraceMs: number;
	drainMs: number;
	now: MonotonicNow;
}

const RISK_DISCLOSURE =
	"Verification executes code from the pull request without a filesystem or network sandbox and is disabled unless a user-level profile sets acknowledgeUnsandboxedPrCodeRisk=true. Lifecycle supervision signals only the original POSIX process group; PR code can deliberately create a new session with setsid and survive it. Use an external sandbox or container wrapper for untrusted pull requests.";
const PROFILE_KEYS = new Set([
	"repository",
	"argv",
	"platforms",
	"totalTimeoutMs",
	"allowForks",
	"acknowledgeUnsandboxedPrCodeRisk",
	"description",
]);
const REPOSITORY_KEYS = new Set(["host", "owner", "repo"]);

function roundMs(value: number): number {
	return Math.round(Math.max(0, value) * 1000) / 1000;
}

function emptyTermination(): VerifyResult["terminationOutcome"] {
	return {
		attempted: false,
		outcome: "not_needed",
		reasons: [],
		termSignalsSent: 0,
		killAttempts: 0,
		killSignalsSent: 0,
		drained: true,
		errors: [],
	};
}

function emptyCleanup(): VerifyResult["cleanupOutcome"] {
	return {
		attempted: false,
		outcome: "not_needed",
		worktreeRemoved: true,
		tempDirRemoved: true,
		fetchRefRemoved: true,
		errors: [],
	};
}

function sanitizeOutput(buffer: Buffer): string {
	// Invalid UTF-8 becomes U+FFFD first. Replace it and controls with printable ASCII
	// so JSON escaping cannot amplify attacker-controlled bytes unexpectedly.
	return buffer
		.toString("utf8")
		.replace(/\uFFFD/g, "?")
		.replace(/[\u0000-\u001f\u007f-\u009f]/g, (char) => (char === "\n" || char === "\t" ? char : "."));
}

function appendShared(output: CapturedOutput, stream: "stdout" | "stderr", chunk: Buffer, limit: number): void {
	if (stream === "stdout") output.observedStdout += chunk.length;
	else output.observedStderr += chunk.length;
	const used = output.stdout.length + output.stderr.length;
	const take = Math.max(0, Math.min(chunk.length, limit - used));
	if (take === 0) return;
	output[stream] = Buffer.concat([output[stream], chunk.subarray(0, take)]);
}

function suppressAuthenticatedFetchOutput(output: CapturedOutput): { stdout: number; stderr: number } {
	const observed = { stdout: output.observedStdout, stderr: output.observedStderr };
	// Authenticated fetch output is wholly untrusted secret-adjacent data. Zero the
	// backing memory before replacing both buffers; observed counts remain available
	// so every suppressed byte is reported as dropped, including bytes beyond the cap.
	output.stdout.fill(0);
	output.stderr.fill(0);
	output.stdout = Buffer.alloc(0);
	output.stderr = Buffer.alloc(0);
	return observed;
}

function preemptedProcessResult(reason: "abort" | "timeout"): ProcessResult {
	return {
		exitCode: null,
		signal: null,
		output: { stdout: Buffer.alloc(0), stderr: Buffer.alloc(0), observedStdout: 0, observedStderr: 0 },
		timedOut: reason === "timeout",
		aborted: reason === "abort",
		termination: {
			attempted: false,
			reason,
			termSent: false,
			killAttempted: false,
			killSent: false,
			drained: true,
			errors: [],
		},
	};
}

function runProcess(command: string, args: string[], options: DeadlineOptions): Promise<ProcessResult> {
	// Cancellation and an exhausted lifecycle budget must win before spawn and
	// before any listener/timer side effects.
	if (options.signal?.aborted) return Promise.resolve(preemptedProcessResult("abort"));
	if (options.deadlineMs - options.now() <= options.killGraceMs + options.drainMs) {
		return Promise.resolve(preemptedProcessResult("timeout"));
	}

	return new Promise((resolve) => {
		const output: CapturedOutput = {
			stdout: Buffer.alloc(0),
			stderr: Buffer.alloc(0),
			observedStdout: 0,
			observedStderr: 0,
		};
		let settled = false;
		let leaderExited = false;
		let leaderClosed = false;
		let exitCode: number | null = null;
		let exitSignal: string | null = null;
		let spawnError: string | undefined;
		let timedOut = false;
		let aborted = false;
		let timeoutTimer: ReturnType<typeof setTimeout> | undefined;
		let forceKillTimer: ReturnType<typeof setTimeout> | undefined;
		let drainTimer: ReturnType<typeof setTimeout> | undefined;
		const termination: ProcessTermination = {
			attempted: false,
			termSent: false,
			killAttempted: false,
			killSent: false,
			drained: true,
			errors: [],
		};

		let proc: ReturnType<typeof spawn>;
		try {
			proc = spawn(command, args, {
				cwd: options.cwd,
				env: options.env,
				detached: true,
				shell: false,
				stdio: ["ignore", "pipe", "pipe"],
			});
		} catch (error) {
			resolve({
				exitCode: null,
				signal: null,
				output,
				timedOut: false,
				aborted: false,
				spawnError: error instanceof Error ? error.message : String(error),
				termination,
			});
			return;
		}

		const cleanupListeners = () => {
			if (timeoutTimer) clearTimeout(timeoutTimer);
			if (forceKillTimer) clearTimeout(forceKillTimer);
			if (drainTimer) clearTimeout(drainTimer);
			options.signal?.removeEventListener("abort", onAbort);
		};
		const finish = () => {
			if (settled) return;
			settled = true;
			cleanupListeners();
			resolve({ exitCode, signal: exitSignal, output, timedOut, aborted, spawnError, termination });
		};
		const groupExists = (): boolean => {
			if (proc.pid === undefined) return false;
			try {
				process.kill(-proc.pid, 0);
				return true;
			} catch (error) {
				return (error as NodeJS.ErrnoException).code !== "ESRCH";
			}
		};
		const signalGroup = (signal: NodeJS.Signals): boolean => {
			if (proc.pid === undefined) return false;
			try {
				process.kill(-proc.pid, signal);
				return true;
			} catch (error) {
				const code = (error as NodeJS.ErrnoException).code;
				// ESRCH means the original process group is already gone; supervision succeeded.
				if (code === "ESRCH") return false;
				// Bun on macOS can report EPERM for a freshly detached group even though
				// direct signaling is permitted. TERM the leader as a compatibility
				// fallback; the unconditional group KILL still targets descendants.
				if (signal === "SIGTERM") {
					try {
						proc.kill(signal);
						return true;
					} catch {
						/* report the original group failure below */
					}
				}
				termination.errors.push(`${signal} process-group signal failed: ${error instanceof Error ? error.message : String(error)}`);
				return false;
			}
		};
		const afterKill = () => {
			const drainDeadline = Math.min(options.deadlineMs, options.now() + options.drainMs);
			const poll = () => {
				const groupGone = !groupExists();
				termination.drained = leaderClosed && groupGone;
				if (termination.drained) {
					finish();
					return;
				}
				const remaining = drainDeadline - options.now();
				if (remaining <= 0) {
					if (!leaderClosed) termination.errors.push("process output/close did not drain before the process deadline");
					if (!groupGone) termination.errors.push("process group still existed after KILL and bounded drain");
					finish();
					return;
				}
				drainTimer = setTimeout(poll, Math.min(5, remaining));
			};
			poll();
		};
		const terminate = (reason: "timeout" | "abort" | "residual_descendants") => {
			if (termination.attempted || settled) return;
			termination.attempted = true;
			termination.reason = reason;
			termination.drained = false;
			termination.termSent = signalGroup("SIGTERM");
			// Unconditionally signal the original process group after grace. Do not
			// cancel this when the group leader exits: descendants may still be alive.
			forceKillTimer = setTimeout(() => {
				// Record the mandatory KILL attempt even when TERM already reaped the
				// group and the OS returns ESRCH. `killSent` remains delivery-only.
				termination.killAttempted = true;
				termination.killSent = signalGroup("SIGKILL");
				afterKill();
			}, options.killGraceMs);
		};
		const onAbort = () => {
			if (settled || termination.attempted) return;
			aborted = true;
			terminate("abort");
		};

		// Attach all error/close/output listeners before cancellation and timeout
		// can initiate termination.
		proc.stdout?.on("data", (data: Buffer | string) =>
			appendShared(output, "stdout", Buffer.isBuffer(data) ? data : Buffer.from(data), options.outputMaxBytes),
		);
		proc.stderr?.on("data", (data: Buffer | string) =>
			appendShared(output, "stderr", Buffer.isBuffer(data) ? data : Buffer.from(data), options.outputMaxBytes),
		);
		proc.on("error", (error) => {
			spawnError = error.message;
			leaderExited = true;
			leaderClosed = true;
			if (!termination.attempted) finish();
		});
		proc.on("exit", (code, signal) => {
			exitCode = code;
			exitSignal = signal;
			leaderExited = true;
			if (termination.attempted) return;
			// A detached leader can exit successfully while background descendants
			// retain its process group. Probe synchronously so an already-gone group
			// proceeds directly to output close without grace delay; otherwise
			// extension-owned original-group supervision must finish before primary success.
			if (groupExists()) terminate("residual_descendants");
		});
		proc.on("close", (code, signal) => {
			exitCode = code;
			exitSignal = signal;
			leaderExited = true;
			leaderClosed = true;
			if (!termination.attempted) finish();
		});

		options.signal?.addEventListener("abort", onAbort, { once: true });
		// Reserve TERM, unconditional KILL, and bounded drain inside this process deadline.
		const remaining = options.deadlineMs - options.now();
		const runMs = Math.max(0, remaining - options.killGraceMs - options.drainMs);
		timeoutTimer = setTimeout(() => {
			if (settled || termination.attempted) return;
			timedOut = true;
			if (leaderExited && !groupExists()) {
				// The leader and group are gone; fail only the bounded output drain
				// rather than adding a pointless TERM/KILL grace interval.
				termination.attempted = true;
				termination.reason = "timeout";
				termination.drained = false;
				termination.errors.push("process output/close did not drain before the process deadline");
				finish();
				return;
			}
			terminate("timeout");
		}, runMs);
		// Close the tiny race between the initial precheck and listener attachment.
		if (options.signal?.aborted) onAbort();
	});
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
	if (!value || typeof value !== "object" || Array.isArray(value)) return false;
	const proto = Object.getPrototypeOf(value);
	return proto === Object.prototype || proto === null;
}

function unknownKeys(value: Record<string, unknown>, allowed: Set<string>): string[] {
	return Object.keys(value).filter((key) => !allowed.has(key));
}

/** Resolve only the user's profile map. The project argument is intentionally ignored. */
export function resolveUserVerificationBaselines(userConfig: unknown, _projectConfig?: unknown): VerificationBaselines {
	if (!isPlainObject(userConfig) || !isPlainObject(userConfig.verificationBaselines)) return {};
	return userConfig.verificationBaselines;
}

export function validateBaselineProfile(name: string, raw: unknown): { profile?: VerificationBaselineProfile; errors: string[] } {
	const errors: string[] = [];
	if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(name)) errors.push("profile name must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$");
	if (!isPlainObject(raw)) return { errors: [...errors, "profile must be an object"] };
	for (const key of unknownKeys(raw, PROFILE_KEYS)) errors.push(`unknown profile field ${JSON.stringify(key)}`);

	let repository: RepositoryIdentity | undefined;
	if (!isPlainObject(raw.repository)) {
		errors.push("repository must be an object");
	} else {
		for (const key of unknownKeys(raw.repository, REPOSITORY_KEYS)) errors.push(`unknown repository field ${JSON.stringify(key)}`);
		const host = raw.repository.host;
		const owner = raw.repository.owner;
		const repo = raw.repository.repo;
		if (typeof host !== "string" || host.length > 253 || !/^[a-z0-9.-]+(?::[0-9]+)?$/.test(host) || host !== host.toLowerCase()) {
			errors.push("repository.host must be a lowercase hostname of at most 253 characters without a URL scheme");
		}
		if (typeof owner !== "string" || !owner.trim() || owner.length > 255 || owner.includes("/")) errors.push("repository.owner must be a nonempty single path component of at most 255 characters");
		if (typeof repo !== "string" || !repo.trim() || repo.length > 255 || repo.includes("/") || repo.endsWith(".git")) errors.push("repository.repo must be a nonempty component of at most 255 characters without .git");
		if (typeof host === "string" && typeof owner === "string" && typeof repo === "string") repository = { host, owner, repo };
	}

	let argv: string[] | undefined;
	if (!Array.isArray(raw.argv) || raw.argv.length === 0 || raw.argv.length > 64) {
		errors.push("argv must be a nonempty array with at most 64 fixed arguments");
	} else {
		argv = [];
		for (const [index, arg] of raw.argv.entries()) {
			if (typeof arg !== "string" || arg.length === 0 || arg.length > 4096 || arg.includes("\0")) {
				errors.push(`argv[${index}] must be a nonempty NUL-free string of at most 4096 characters`);
			} else argv.push(arg);
		}
		if (typeof raw.argv[0] === "string" && !path.isAbsolute(raw.argv[0])) errors.push("argv[0] must be an absolute executable path");
		if (argv.reduce((total, arg) => total + Buffer.byteLength(arg), 0) > 8_192) errors.push("argv must total at most 8192 UTF-8 bytes");
	}

	let platforms: PosixPlatform[] | undefined;
	if (!Array.isArray(raw.platforms) || raw.platforms.length === 0) {
		errors.push("platforms must be a nonempty array of supported POSIX platform names");
	} else {
		const values = raw.platforms.filter((value): value is string => typeof value === "string");
		if (values.length !== raw.platforms.length || values.some((value) => !(POSIX_PLATFORMS as readonly string[]).includes(value))) {
			errors.push(`platforms may contain only: ${POSIX_PLATFORMS.join(", ")}`);
		} else if (new Set(values).size !== values.length) {
			errors.push("platforms must not contain duplicates");
		} else platforms = values as PosixPlatform[];
	}

	if (!Number.isSafeInteger(raw.totalTimeoutMs) || (raw.totalTimeoutMs as number) < VERIFY_TIMEOUT_MIN_MS || (raw.totalTimeoutMs as number) > VERIFY_TIMEOUT_MAX_MS) {
		errors.push(`totalTimeoutMs must be an integer from ${VERIFY_TIMEOUT_MIN_MS} to ${VERIFY_TIMEOUT_MAX_MS}`);
	}
	if (raw.allowForks !== undefined && typeof raw.allowForks !== "boolean") errors.push("allowForks must be a boolean when present");
	if (raw.acknowledgeUnsandboxedPrCodeRisk !== true) errors.push("acknowledgeUnsandboxedPrCodeRisk must be exactly true");
	if (raw.description !== undefined && (typeof raw.description !== "string" || !raw.description.trim() || raw.description.length > 500)) {
		errors.push("description must be a nonempty string of at most 500 characters when present");
	}

	if (errors.length || !repository || !argv || !platforms) return { errors };
	return {
		profile: {
			repository,
			argv: argv as [string, ...string[]],
			platforms,
			totalTimeoutMs: raw.totalTimeoutMs as number,
			allowForks: raw.allowForks === true,
			acknowledgeUnsandboxedPrCodeRisk: true,
			...(typeof raw.description === "string" ? { description: raw.description.trim() } : {}),
		},
		errors,
	};
}

export function validateVerifyRequest(request: VerifyRequest): string[] {
	const errors: string[] = [];
	if (!Number.isSafeInteger(request.prNumber) || request.prNumber <= 0) errors.push("prNumber must be a positive integer");
	if (!/^[0-9a-f]{40}$/.test(request.headSha)) errors.push("headSha must be an exact 40-character lowercase commit SHA");
	if (typeof request.baselineName !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(request.baselineName)) {
		errors.push("baselineName must name one configured profile");
	}
	return errors;
}

export function parseRepositoryRemote(remote: string): RepositoryIdentity | undefined {
	const trimmed = remote.trim();
	let host: string;
	let pathname: string;
	try {
		const url = new URL(trimmed);
		if (url.protocol !== "https:" && url.protocol !== "http:" && url.protocol !== "ssh:") return undefined;
		host = url.host.toLowerCase();
		pathname = url.pathname;
	} catch {
		const scp = /^(?:[^@/]+@)?([^:/]+):(.+)$/.exec(trimmed);
		if (!scp) return undefined;
		host = scp[1]!.toLowerCase();
		pathname = scp[2]!;
	}
	const components = pathname.replace(/^\/+|\/+$/g, "").split("/");
	if (components.length !== 2) return undefined;
	const owner = components[0]!;
	const repo = components[1]!.replace(/\.git$/, "");
	if (!host || !owner || !repo) return undefined;
	return { host, owner, repo };
}

function identitiesEqual(left: RepositoryIdentity, right: RepositoryIdentity): boolean {
	return left.host.toLowerCase() === right.host.toLowerCase()
		&& left.owner.toLowerCase() === right.owner.toLowerCase()
		&& left.repo.toLowerCase() === right.repo.toLowerCase();
}

function validateCanonicalExecutable(profile: VerificationBaselineProfile): string[] {
	const executable = profile.argv[0];
	const errors: string[] = [];
	try {
		const canonical = fs.realpathSync(executable);
		if (canonical !== executable) errors.push(`argv[0] must be canonical (resolved path is ${canonical})`);
		const stat = fs.statSync(canonical);
		if (!stat.isFile()) errors.push("argv[0] must resolve to a regular file");
		fs.accessSync(canonical, fs.constants.X_OK);
	} catch (error) {
		errors.push(`argv[0] is not an accessible executable: ${error instanceof Error ? error.message : String(error)}`);
	}
	return errors;
}

function trustedStartupPath(options: VerifyOptions): string {
	return options.startupPath ?? (options.ghEnvironment ?? process.env).PATH ?? "";
}

function resolveTrustedGhExecutable(options: VerifyOptions): string {
	return resolveTrustedExecutableFromStartupPath("gh", options.ghExecutable, trustedStartupPath(options));
}

function resolveTrustedGitExecutable(options: VerifyOptions): string {
	return resolveTrustedExecutableFromStartupPath("git", options.gitExecutable, trustedStartupPath(options));
}

function ghSetupEnv(source: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = {
		PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
		LANG: "C.UTF-8",
		LC_ALL: "C.UTF-8",
		GH_PROMPT_DISABLED: "1",
		NO_COLOR: "1",
		PAGER: "cat",
	};
	// Authentication/configuration and transport settings needed by gh are copied
	// only into setup subprocesses. The baseline command never receives this env.
	for (const key of [
		"HOME", "XDG_CONFIG_HOME", "GH_CONFIG_DIR", "GH_TOKEN", "GITHUB_TOKEN",
		"GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST",
		"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
		"http_proxy", "https_proxy", "all_proxy", "no_proxy",
		"SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
	]) {
		if (source[key] !== undefined) env[key] = source[key];
	}
	return env;
}

function canonicalRepositoryUrl(repository: RepositoryIdentity): string {
	const url = new URL(`https://${repository.host}/`);
	url.pathname = `/${encodeURIComponent(repository.owner)}/${encodeURIComponent(repository.repo)}.git`;
	return url.toString();
}

function ghRepositorySpecifier(repository: RepositoryIdentity): string {
	return `${repository.host}/${repository.owner}/${repository.repo}`;
}

function minimalGitEnv(home: string): NodeJS.ProcessEnv {
	return {
		HOME: home,
		PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
		LANG: "C.UTF-8",
		LC_ALL: "C.UTF-8",
		GIT_CONFIG_NOSYSTEM: "1",
		GIT_CONFIG_GLOBAL: "/dev/null",
		GIT_TERMINAL_PROMPT: "0",
		GIT_ASKPASS: "/usr/bin/false",
		SSH_ASKPASS: "/usr/bin/false",
		GCM_INTERACTIVE: "never",
		PAGER: "cat",
		GIT_PAGER: "cat",
	};
}

function minimalCommandEnv(tempDir: string): NodeJS.ProcessEnv {
	const home = path.join(tempDir, "home");
	const cache = path.join(tempDir, "cache");
	const tmp = path.join(tempDir, "tmp");
	for (const dir of [home, cache, tmp]) fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
	return {
		HOME: home,
		XDG_CACHE_HOME: cache,
		TMPDIR: tmp,
		TMP: tmp,
		TEMP: tmp,
		PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
		LANG: "C.UTF-8",
		LC_ALL: "C.UTF-8",
		CI: "true",
		NO_COLOR: "1",
		GIT_CONFIG_NOSYSTEM: "1",
		GIT_CONFIG_GLOBAL: "/dev/null",
		GIT_TERMINAL_PROMPT: "0",
		GIT_ASKPASS: "/usr/bin/false",
		SSH_ASKPASS: "/usr/bin/false",
		GCM_INTERACTIVE: "never",
		PAGER: "cat",
		GIT_PAGER: "cat",
	};
}

function createAskpassHelper(tempDir: string): string {
	const helper = path.join(tempDir, "gh-askpass.sh");
	fs.writeFileSync(helper, `#!/bin/sh
case "$1" in
  *Username*|*username*) printf '%s\\n' 'x-access-token' ;;
  *Password*|*password*) printf '%s\\n' "$PI_PR_REVIEW_GH_TOKEN" ;;
  *) exit 1 ;;
esac
`, { encoding: "utf8", mode: 0o700 });
	return helper;
}

async function inspectCanonicalPullRequest(
	request: VerifyRequest,
	profile: VerificationBaselineProfile,
	ghExecutable: string,
	deadlineMs: number,
	signal: AbortSignal | undefined,
	options: Required<Pick<VerifyOptions, "outputMaxBytes" | "killGraceMs" | "drainMs" | "now">>,
	ghEnvironment: NodeJS.ProcessEnv,
): Promise<{
	metadata?: PullRequestMetadata;
	processResults: ProcessResult[];
	error?: string;
	timeout?: boolean;
	aborted?: boolean;
}> {
	const processResults: ProcessResult[] = [];
	const common = { env: ghSetupEnv(ghEnvironment), signal, deadlineMs, ...options };
	const repository = ghRepositorySpecifier(profile.repository);
	const runGh = async (args: string[], outputMaxBytes = options.outputMaxBytes) => {
		const processResult = await runProcess(ghExecutable, args, { ...common, outputMaxBytes });
		processResults.push(processResult);
		return processResult;
	};
	const pr = await runGh([
		"pr", "view", String(request.prNumber), "--repo", repository,
		"--json", "headRefOid,isCrossRepository,headRepository",
	]);
	if (pr.aborted) return { processResults, aborted: true };
	if (pr.timedOut) return { processResults, timeout: true };
	if (pr.exitCode !== 0 || pr.spawnError) {
		return { processResults, error: `gh PR metadata failed: ${pr.spawnError ?? (sanitizeOutput(pr.output.stderr).trim() || "unknown error")}` };
	}

	const canonical = await runGh(["repo", "view", repository, "--json", "nameWithOwner,isPrivate,url"]);
	if (canonical.aborted) return { processResults, aborted: true };
	if (canonical.timedOut) return { processResults, timeout: true };
	if (canonical.exitCode !== 0 || canonical.spawnError) {
		return { processResults, error: `gh canonical repository metadata failed: ${canonical.spawnError ?? (sanitizeOutput(canonical.output.stderr).trim() || "unknown error")}` };
	}

	let prJson: Record<string, unknown>;
	let repoJson: Record<string, unknown>;
	try {
		prJson = JSON.parse(sanitizeOutput(pr.output.stdout));
		repoJson = JSON.parse(sanitizeOutput(canonical.output.stdout));
	} catch {
		return { processResults, error: "gh returned malformed canonical PR/repository metadata" };
	}
	const canonicalIdentity = typeof repoJson.url === "string" ? parseRepositoryRemote(repoJson.url) : undefined;
	const expectedName = `${profile.repository.owner}/${profile.repository.repo}`;
	if (!canonicalIdentity || !identitiesEqual(canonicalIdentity, profile.repository)
		|| typeof repoJson.nameWithOwner !== "string" || repoJson.nameWithOwner.toLowerCase() !== expectedName.toLowerCase()
		|| typeof repoJson.isPrivate !== "boolean") {
		return { processResults, error: "gh repository metadata did not match the canonical verification profile repository" };
	}
	if (typeof prJson.headRefOid !== "string" || !/^[0-9a-f]{40}$/.test(prJson.headRefOid)
		|| typeof prJson.isCrossRepository !== "boolean") {
		return { processResults, error: "gh PR metadata omitted a valid head SHA or cross-repository status" };
	}
	let headRepository: string | undefined;
	if (isPlainObject(prJson.headRepository) && typeof prJson.headRepository.nameWithOwner === "string") {
		headRepository = prJson.headRepository.nameWithOwner;
	}

	return {
		processResults,
		metadata: {
			headSha: prJson.headRefOid,
			isCrossRepository: prJson.isCrossRepository,
			...(headRepository ? { headRepository } : {}),
			canonicalRepositoryPrivate: repoJson.isPrivate,
		},
	};
}

async function resolveGhHostToken(
	host: string,
	ghExecutable: string,
	deadlineMs: number,
	signal: AbortSignal | undefined,
	options: Required<Pick<VerifyOptions, "killGraceMs" | "drainMs" | "now">>,
	ghEnvironment: NodeJS.ProcessEnv,
): Promise<{ token?: string; processResult: ProcessResult; timeout?: boolean; aborted?: boolean }> {
	// A missing token is not itself fatal: public HTTPS fetch remains supported.
	// Never propagate token command output into the result or baseline environment.
	const processResult = await runProcess(ghExecutable, ["auth", "token", "--hostname", host], {
		env: ghSetupEnv(ghEnvironment),
		signal,
		deadlineMs,
		outputMaxBytes: 8_192,
		...options,
	});
	let token: string | undefined;
	if (processResult.exitCode === 0 && !processResult.spawnError && !processResult.aborted && !processResult.timedOut) {
		const candidate = processResult.output.stdout.toString("utf8").trim();
		if (candidate.length > 0 && candidate.length <= 4_096 && !/\s/.test(candidate)) token = candidate;
	}
	processResult.output.stdout.fill(0);
	processResult.output.stderr.fill(0);
	processResult.output.observedStdout = 0;
	processResult.output.observedStderr = 0;
	return {
		processResult,
		...(processResult.aborted ? { aborted: true } : {}),
		...(processResult.timedOut ? { timeout: true } : {}),
		...(token ? { token } : {}),
	};
}

function mergeTermination(target: VerifyResult["terminationOutcome"], source: ProcessTermination): void {
	if (!source.attempted) return;
	target.attempted = true;
	if (source.reason && !target.reasons.includes(source.reason)) target.reasons.push(source.reason);
	if (source.termSent) target.termSignalsSent++;
	if (source.killAttempted) target.killAttempts++;
	if (source.killSent) target.killSignalsSent++;
	target.drained &&= source.drained;
	target.errors.push(...source.errors);
	target.outcome = target.errors.length === 0 ? "success" : "failure";
}

function applyOutput(result: VerifyResult, processResult: ProcessResult): void {
	result.stdout = sanitizeOutput(processResult.output.stdout);
	result.stderr = sanitizeOutput(processResult.output.stderr);
	const capturedStdout = processResult.output.stdout.length;
	const capturedStderr = processResult.output.stderr.length;
	const droppedStdout = processResult.output.observedStdout - capturedStdout;
	const droppedStderr = processResult.output.observedStderr - capturedStderr;
	result.output.capturedBytes = { stdout: capturedStdout, stderr: capturedStderr, total: capturedStdout + capturedStderr };
	result.output.droppedBytes = { stdout: droppedStdout, stderr: droppedStderr, total: droppedStdout + droppedStderr };
}

function setPrimary(result: VerifyResult, outcome: VerifyPrimaryOutcome, phase: VerifyResult["primaryOutcome"]["phase"], message: string): void {
	result.primaryOutcome = { outcome, phase, message };
	result.outcome = outcome;
	result.message = message;
}

function redactTemporaryPath(result: VerifyResult, tempDir: string): void {
	const redact = (value: string) => value.replaceAll(tempDir, "[verification temporary directory]");
	result.stdout = redact(result.stdout);
	result.stderr = redact(result.stderr);
	result.message = redact(result.message);
	result.primaryOutcome.message = redact(result.primaryOutcome.message);
	result.terminationOutcome.errors = result.terminationOutcome.errors.map(redact);
	result.cleanupOutcome.errors = result.cleanupOutcome.errors.map(redact);
}

function truncateUtf8(value: string, maxBytes: number): string {
	const bytes = Buffer.from(value);
	if (bytes.length <= maxBytes) return value;
	return `${bytes.subarray(0, Math.max(0, maxBytes - 3)).toString("utf8").replace(/\uFFFD$/g, "")}...`;
}

function finalizeResult(result: VerifyResult, serializedMaxBytes: number): VerifyResult {
	result.cleanupOutcome.outcome = !result.cleanupOutcome.attempted
		? "not_needed"
		: result.cleanupOutcome.errors.length === 0
			? "success"
			: "failure";
	result.terminationOutcome.outcome = !result.terminationOutcome.attempted
		? "not_needed"
		: result.terminationOutcome.errors.length === 0
			? "success"
			: "failure";
	if (result.cleanupOutcome.outcome === "failure") result.outcome = "cleanup_failure";
	else if (result.terminationOutcome.outcome === "failure") result.outcome = "termination_failure";
	else result.outcome = result.primaryOutcome.outcome;
	result.lifecycleOk = result.primaryOutcome.outcome === "success"
		&& result.terminationOutcome.outcome !== "failure"
		&& result.cleanupOutcome.outcome !== "failure";
	if (result.cleanupOutcome.outcome === "failure") result.message = `${result.primaryOutcome.message} Cleanup failed: ${result.cleanupOutcome.errors.join("; ")}`;
	if (result.terminationOutcome.outcome === "failure") result.message += ` Termination failed: ${result.terminationOutcome.errors.join("; ")}`;

	// Normally the shared raw cap leaves ample room. If unusually long platform
	// paths/messages still exceed the serialized contract, drop complete captured
	// streams and account for every removed raw byte rather than slicing UTF-8.
	if (Buffer.byteLength(JSON.stringify(result, null, 2)) > serializedMaxBytes) {
		result.output.droppedBytes.stdout += result.output.capturedBytes.stdout;
		result.output.droppedBytes.stderr += result.output.capturedBytes.stderr;
		result.output.droppedBytes.total += result.output.capturedBytes.total;
		result.output.capturedBytes = { stdout: 0, stderr: 0, total: 0 };
		result.stdout = "";
		result.stderr = "";
	}
	if (Buffer.byteLength(JSON.stringify(result, null, 2)) > serializedMaxBytes) {
		result.message = truncateUtf8(result.message, 2_048);
		result.primaryOutcome.message = truncateUtf8(result.primaryOutcome.message, 2_048);
		result.terminationOutcome.errors = result.terminationOutcome.errors.slice(0, 8).map((error) => truncateUtf8(error, 512));
		result.cleanupOutcome.errors = result.cleanupOutcome.errors.slice(0, 8).map((error) => truncateUtf8(error, 512));
		if (result.repoRoot) result.repoRoot = truncateUtf8(result.repoRoot, 1_024);
	}
	if (Buffer.byteLength(JSON.stringify(result, null, 2)) > serializedMaxBytes && result.profile) {
		result.profile.argv = ["[argv omitted to preserve the serialized result cap]"];
	}
	return result;
}

function baseResult(request: VerifyRequest, serializedMaxBytes: number): VerifyResult {
	return {
		outcome: "setup_failure",
		primaryOutcome: { outcome: "setup_failure", phase: "validation", message: "Verification did not start." },
		terminationOutcome: emptyTermination(),
		cleanupOutcome: emptyCleanup(),
		lifecycleOk: false,
		prNumber: request.prNumber,
		headSha: request.headSha,
		baselineName: request.baselineName,
		stdout: "",
		stderr: "",
		output: {
			capturedBytes: { stdout: 0, stderr: 0, total: 0 },
			droppedBytes: { stdout: 0, stderr: 0, total: 0 },
			sanitized: true,
			serializedMaxBytes,
		},
		message: "Verification did not start.",
		riskDisclosure: RISK_DISCLOSURE,
		timing: { totalMs: 0, setupMs: 0, commandMs: 0, cleanupMs: 0 },
	};
}

async function locateRepository(
	cwd: string,
	home: string,
	deadlineMs: number,
	signal: AbortSignal | undefined,
	options: Required<Pick<VerifyOptions, "outputMaxBytes" | "killGraceMs" | "drainMs" | "now">>,
	gitExecutable: string,
): Promise<{ repoRoot?: string; identity?: RepositoryIdentity; processResults: ProcessResult[]; error?: string; timeout?: boolean; aborted?: boolean }> {
	const processResults: ProcessResult[] = [];
	const common = { env: minimalGitEnv(home), signal, deadlineMs, ...options };
	const root = await runProcess(gitExecutable, ["-C", cwd, "rev-parse", "--show-toplevel"], common);
	processResults.push(root);
	if (root.aborted) return { processResults, aborted: true };
	if (root.timedOut) return { processResults, timeout: true };
	if (root.exitCode !== 0 || root.spawnError) return { processResults, error: root.spawnError ?? (sanitizeOutput(root.output.stderr).trim() || "git rev-parse failed") };
	const repoRoot = sanitizeOutput(root.output.stdout).trim();
	if (!path.isAbsolute(repoRoot)) return { processResults, error: "git returned a non-absolute repository root" };
	const remote = await runProcess(gitExecutable, ["-C", repoRoot, "remote", "get-url", "origin"], common);
	processResults.push(remote);
	if (remote.aborted) return { repoRoot, processResults, aborted: true };
	if (remote.timedOut) return { repoRoot, processResults, timeout: true };
	if (remote.exitCode !== 0 || remote.spawnError) return { repoRoot, processResults, error: remote.spawnError ?? (sanitizeOutput(remote.output.stderr).trim() || "origin URL unavailable") };
	const identity = parseRepositoryRemote(sanitizeOutput(remote.output.stdout));
	if (!identity) return { repoRoot, processResults, error: "origin URL must identify exactly host/owner/repo" };
	return { repoRoot, identity, processResults };
}

export async function discoverVerificationBaselines(
	cwd: string,
	baselines: VerificationBaselines | undefined,
	signal?: AbortSignal,
	options: VerifyOptions = {},
): Promise<BaselineDiscoveryResult> {
	const platform = options.platform ?? process.platform;
	const result: BaselineDiscoveryResult = {
		action: "list",
		enabled: false,
		platform,
		baselines: [],
		rejected: [],
		message: "Verification is disabled because no user-level verificationBaselines are configured.",
		riskDisclosure: RISK_DISCLOSURE,
	};
	if (platform === "win32") {
		result.message = "Verification is unavailable on win32 until reliable Job Object process-tree containment is implemented.";
		return result;
	}
	if (signal?.aborted) {
		result.message = "Baseline discovery was aborted before repository inspection.";
		return result;
	}
	if (!isPlainObject(baselines) || Object.keys(baselines).length === 0) return result;

	const parsed = new Map<string, VerificationBaselineProfile>();
	for (const [name, raw] of Object.entries(baselines)) {
		const validation = validateBaselineProfile(name, raw);
		if (validation.profile) parsed.set(name, validation.profile);
		else result.rejected.push({ name, errors: validation.errors });
	}
	const candidates = [...parsed.entries()].filter(([, profile]) => profile.platforms.includes(platform as PosixPlatform));
	if (candidates.length === 0) {
		result.message = "No valid user-level verification baseline applies to this POSIX platform.";
		return result;
	}

	const now = options.now ?? monotonicNow;
	const tempRoot = options.tempRoot ?? os.tmpdir();
	let gitExecutable: string;
	try {
		gitExecutable = resolveTrustedGitExecutable(options);
	} catch (error) {
		result.message = error instanceof Error ? error.message : String(error);
		return result;
	}
	const discoveryDir = await fs.promises.mkdtemp(path.join(tempRoot, "pi-pr-review-discover-"));
	try {
		const located = options.repositoryIdentity
			? { identity: options.repositoryIdentity }
			: await locateRepository(cwd, discoveryDir, now() + 5_000, signal, {
				outputMaxBytes: 4_096,
				killGraceMs: options.killGraceMs ?? 250,
				drainMs: options.drainMs ?? 100,
				now,
			}, gitExecutable);
		if (!located.identity) {
			result.message = "Unable to identify the current repository origin for baseline discovery.";
			return result;
		}
		result.repository = located.identity;
		for (const [name, profile] of candidates) {
			if (!identitiesEqual(profile.repository, located.identity)) continue;
			const executableErrors = validateCanonicalExecutable(profile);
			if (executableErrors.length) {
				result.rejected.push({ name, errors: executableErrors });
				continue;
			}
			result.baselines.push({
				name,
				...(profile.description ? { description: profile.description } : {}),
				totalTimeoutMs: profile.totalTimeoutMs,
				allowForks: profile.allowForks,
				repository: profile.repository,
			});
		}
		result.enabled = result.baselines.length > 0;
		result.message = result.enabled
			? `Applicable user-level verification baselines: ${result.baselines.map((entry) => entry.name).join(", ")}. ${RISK_DISCLOSURE}`
			: "No valid user-level verification baseline applies to this repository and platform.";
		return result;
	} finally {
		await fs.promises.rm(discoveryDir, { recursive: true, force: true });
	}
}

export async function verifyPullRequestHead(
	cwd: string,
	request: VerifyRequest,
	baselines: VerificationBaselines | undefined,
	signal?: AbortSignal,
	options: VerifyOptions = {},
): Promise<VerifyResult> {
	const now = options.now ?? monotonicNow;
	const startedAt = now();
	const serializedMaxBytes = Math.max(16_384, options.serializedMaxBytes ?? VERIFY_SERIALIZED_MAX_BYTES);
	const outputMaxBytes = Math.min(options.outputMaxBytes ?? VERIFY_OUTPUT_MAX_BYTES, Math.max(0, Math.floor((serializedMaxBytes - 16_384) / 2)));
	const killGraceMs = options.killGraceMs ?? 250;
	const drainMs = options.drainMs ?? 100;
	const platform = options.platform ?? process.platform;
	const result = baseResult(request, serializedMaxBytes);
	const validationErrors = validateVerifyRequest(request);
	if (validationErrors.length) {
		setPrimary(result, "invalid_input", "validation", validationErrors.join("; "));
		result.timing.totalMs = roundMs(now() - startedAt);
		return finalizeResult(result, serializedMaxBytes);
	}
	if (typeof cwd !== "string" || !cwd.trim()) {
		setPrimary(result, "invalid_input", "validation", "cwd must be a non-empty path");
		result.timing.totalMs = roundMs(now() - startedAt);
		return finalizeResult(result, serializedMaxBytes);
	}
	if (platform === "win32") {
		setPrimary(result, "unsupported_platform", "validation", "Verification fails closed on win32 until reliable Job Object process-tree containment is implemented.");
		result.timing.totalMs = roundMs(now() - startedAt);
		return finalizeResult(result, serializedMaxBytes);
	}
	if (signal?.aborted) {
		setPrimary(result, "aborted", "validation", "Verification was aborted before setup side effects.");
		result.timing.totalMs = roundMs(now() - startedAt);
		return finalizeResult(result, serializedMaxBytes);
	}
	if (!isPlainObject(baselines) || Object.keys(baselines).length === 0) {
		setPrimary(result, "disabled", "validation", "Verification is disabled because no user-level verificationBaselines are configured.");
		result.timing.totalMs = roundMs(now() - startedAt);
		return finalizeResult(result, serializedMaxBytes);
	}
	const selected = validateBaselineProfile(request.baselineName, baselines[request.baselineName]);
	if (!selected.profile) {
		setPrimary(result, "invalid_input", "validation", `Baseline ${JSON.stringify(request.baselineName)} is not a valid user-level profile: ${selected.errors.join("; ")}`);
		result.timing.totalMs = roundMs(now() - startedAt);
		return finalizeResult(result, serializedMaxBytes);
	}
	const profile = selected.profile;
	result.profile = {
		repository: profile.repository,
		argv: [...profile.argv],
		platforms: [...profile.platforms],
		totalTimeoutMs: profile.totalTimeoutMs,
		allowForks: profile.allowForks,
		...(profile.description ? { description: profile.description } : {}),
	};
	if (!profile.platforms.includes(platform as PosixPlatform)) {
		setPrimary(result, "not_applicable", "validation", `Baseline ${request.baselineName} does not apply to platform ${platform}.`);
		result.timing.totalMs = roundMs(now() - startedAt);
		return finalizeResult(result, serializedMaxBytes);
	}
	const executableErrors = validateCanonicalExecutable(profile);
	if (executableErrors.length) {
		setPrimary(result, "invalid_input", "validation", executableErrors.join("; "));
		result.timing.totalMs = roundMs(now() - startedAt);
		return finalizeResult(result, serializedMaxBytes);
	}

	// totalTimeoutMs is one monotonic setup+command+cleanup budget. Reserve a
	// bounded cleanup slice; process helpers reserve TERM/KILL/drain within each phase.
	const cleanupReserveMs = Math.min(5_000, Math.max(1_000, Math.floor(profile.totalTimeoutMs * 0.2)));
	const setupCommandDeadline = startedAt + profile.totalTimeoutMs - cleanupReserveMs;
	const cleanupDeadline = startedAt + profile.totalTimeoutMs;
	// A fixed emergency ceiling is unconditionally available to bounded cleanup
	// beyond the profile budget; cleanup still never receives an unbounded retry.
	const cleanupEmergencyDeadline = cleanupDeadline + 2_000;
	let repoRoot: string | undefined;
	let tempDir: string | undefined;
	let worktreePath: string | undefined;
	let fetchRef: string | undefined;
	let worktreeAdded = false;
	let commandStartedAt: number | undefined;
	let commandFinishedAt: number | undefined;
	let cleanupStartedAt = now();
	let gitExecutable = "";
	let suppressedAuthenticatedFetchBytes = { stdout: 0, stderr: 0 };
	const common = { outputMaxBytes, killGraceMs, drainMs, now };
	const observe = (processResult: ProcessResult) => mergeTermination(result.terminationOutcome, processResult.termination);

	try {
		if (signal?.aborted) {
			setPrimary(result, "aborted", "validation", "Verification was aborted before setup side effects.");
			return result;
		}
		gitExecutable = resolveTrustedGitExecutable(options);
		const ghExecutable = resolveTrustedGhExecutable(options);
		tempDir = await fs.promises.mkdtemp(path.join(options.tempRoot ?? os.tmpdir(), `pi-pr-review-${request.prNumber}-${request.headSha.slice(0, 12)}-`));
		fs.chmodSync(tempDir, 0o700);
		const located = options.repositoryIdentity
			? { repoRoot: cwd, identity: options.repositoryIdentity, processResults: [] as ProcessResult[] }
			: await locateRepository(cwd, tempDir, setupCommandDeadline, signal, { ...common, outputMaxBytes }, gitExecutable);
		for (const processResult of located.processResults ?? []) observe(processResult);
		if (located.aborted) {
			setPrimary(result, "aborted", "setup", "Verification aborted while identifying the repository.");
			return result;
		}
		if (located.timeout) {
			setPrimary(result, "timeout", "setup", "The total verification deadline expired while identifying the repository.");
			return result;
		}
		if (!located.repoRoot || !located.identity) {
			setPrimary(result, "setup_failure", "setup", `Unable to identify repository: ${located.error ?? "unknown error"}`);
			return result;
		}
		repoRoot = located.repoRoot;
		result.repoRoot = repoRoot;
		result.repository = located.identity;
		if (!identitiesEqual(profile.repository, located.identity)) {
			setPrimary(result, "not_applicable", "validation", `Baseline ${request.baselineName} is for ${profile.repository.host}/${profile.repository.owner}/${profile.repository.repo}, not ${located.identity.host}/${located.identity.owner}/${located.identity.repo}.`);
			return result;
		}
		if (signal?.aborted) {
			setPrimary(result, "aborted", "setup", "Verification aborted before trusted GitHub metadata validation.");
			return result;
		}
		const inspected = await inspectCanonicalPullRequest(
			request,
			profile,
			ghExecutable,
			setupCommandDeadline,
			signal,
			{ ...common, outputMaxBytes: Math.min(outputMaxBytes, 16_384) },
			options.ghEnvironment ?? process.env,
		);
		for (const processResult of inspected.processResults) observe(processResult);
		if (inspected.aborted) {
			setPrimary(result, "aborted", "setup", "Verification aborted while validating trusted GitHub PR metadata.");
			return result;
		}
		if (inspected.timeout) {
			setPrimary(result, "timeout", "setup", "The total verification deadline expired while validating trusted GitHub PR metadata.");
			return result;
		}
		if (!inspected.metadata) {
			setPrimary(result, "setup_failure", "setup", `Unable to validate trusted GitHub PR metadata: ${inspected.error ?? "unknown error"}`);
			return result;
		}
		if (inspected.metadata.headSha !== request.headSha) {
			setPrimary(result, "stale_head", "setup", `Current GitHub pull-request head ${inspected.metadata.headSha} does not equal captured head ${request.headSha}.`);
			return result;
		}
		if (inspected.metadata.isCrossRepository && !profile.allowForks) {
			const source = inspected.metadata.headRepository ? ` from ${inspected.metadata.headRepository}` : "";
			setPrimary(result, "not_applicable", "validation", `Baseline ${request.baselineName} rejects cross-repository pull requests${source}; set allowForks: true in the trusted user profile to permit one.`);
			return result;
		}
		worktreePath = path.join(tempDir, "worktree");
		fetchRef = `refs/pi-pr-review/${process.pid}-${randomUUID().replaceAll("-", "")}`;
		const stagingRef = `refs/pi-pr-review/staging-${randomUUID().replaceAll("-", "")}`;
		const stagingRepository = path.join(tempDir, "fetch.git");
		const emptyTemplateDir = path.join(tempDir, "empty-git-template");
		const emptyHooksDir = path.join(tempDir, "empty-git-hooks");
		for (const directory of [emptyTemplateDir, emptyHooksDir]) fs.mkdirSync(directory, { mode: 0o700 });
		const gitEnv = minimalGitEnv(tempDir);
		const runGit = async (args: string[], env: NodeJS.ProcessEnv = gitEnv) => {
			const processResult = await runProcess(gitExecutable, args, {
				env,
				signal,
				deadlineMs: setupCommandDeadline,
				...common,
			});
			observe(processResult);
			return processResult;
		};

		// The only network operation occurs in a fresh extension-owned bare staging
		// repository. Empty templates prevent hook installation; removing the generated
		// config ensures the fetch has no local config, while minimalGitEnv disables
		// system/global config. The original repository is not touched while auth exists.
		const initialized = await runGit(["init", "--bare", `--template=${emptyTemplateDir}`, stagingRepository]);
		if (initialized.aborted || initialized.timedOut || initialized.exitCode !== 0 || initialized.spawnError) {
			applyOutput(result, initialized);
			setPrimary(result, initialized.aborted ? "aborted" : initialized.timedOut ? "timeout" : "setup_failure", "setup", "Unable to initialize the extension-owned staging repository.");
			return result;
		}
		fs.rmSync(path.join(stagingRepository, "config"), { force: true });

		// Resolve authentication only after staging is ready, immediately before the
		// one operation permitted to receive it.
		const tokenResolution = await resolveGhHostToken(
			profile.repository.host,
			ghExecutable,
			setupCommandDeadline,
			signal,
			{ killGraceMs, drainMs, now },
			options.ghEnvironment ?? process.env,
		);
		observe(tokenResolution.processResult);
		if (tokenResolution.aborted) {
			setPrimary(result, "aborted", "setup", "Verification aborted while resolving setup-only GitHub authentication.");
			return result;
		}
		if (tokenResolution.timeout) {
			setPrimary(result, "timeout", "setup", "The total verification deadline expired while resolving setup-only GitHub authentication.");
			return result;
		}
		if (inspected.metadata.canonicalRepositoryPrivate && !tokenResolution.token) {
			setPrimary(result, "setup_failure", "setup", "Private canonical repository fetch requires a gh host token; run gh auth login for this host.");
			return result;
		}

		let authToken = tokenResolution.token;
		delete tokenResolution.token;
		const usedAuthentication = authToken !== undefined;
		const fetchEnv = minimalGitEnv(tempDir);
		const canonicalUrl = canonicalRepositoryUrl(profile.repository);
		let askpassHelper: string | undefined;
		let fetch: ProcessResult | undefined;
		try {
			if (authToken) {
				askpassHelper = createAskpassHelper(tempDir);
				fetchEnv.GIT_ASKPASS = askpassHelper;
				fetchEnv.PI_PR_REVIEW_GH_TOKEN = authToken;
			}
			fetch = await runGit([
				"-c", `core.hooksPath=${emptyHooksDir}`,
				"-c", "credential.helper=",
				"-c", `credential.https://${profile.repository.host}.helper=`,
				"-c", `credential.${canonicalUrl}.helper=`,
				"--git-dir", stagingRepository,
				"fetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules",
				canonicalUrl,
				`+refs/pull/${request.prNumber}/head:${stagingRef}`,
			], fetchEnv);
		} catch {
			// Authenticated fetch diagnostics are never surfaced, including thrown paths.
		} finally {
			if (authToken && fetch) suppressedAuthenticatedFetchBytes = suppressAuthenticatedFetchOutput(fetch.output);
			delete fetchEnv.PI_PR_REVIEW_GH_TOKEN;
			authToken = undefined;
			if (askpassHelper) fs.rmSync(askpassHelper, { force: true });
		}
		if (!fetch) {
			setPrimary(
				result,
				"setup_failure",
				"setup",
				usedAuthentication
					? "Authenticated HTTPS fetch of the canonical repository could not be completed; captured fetch output was suppressed."
					: "Unauthenticated public HTTPS fetch of the canonical repository could not be completed.",
			);
			return result;
		}
		if (fetch.aborted) {
			if (!usedAuthentication) applyOutput(result, fetch);
			setPrimary(result, "aborted", "setup", "Verification aborted while fetching the pull-request ref.");
			return result;
		}
		if (fetch.timedOut) {
			if (!usedAuthentication) applyOutput(result, fetch);
			setPrimary(result, "timeout", "setup", "The total verification deadline expired while fetching the pull-request ref.");
			return result;
		}
		if (fetch.exitCode !== 0 || fetch.spawnError) {
			if (usedAuthentication) {
				const authContext = inspected.metadata.canonicalRepositoryPrivate
					? "Authenticated HTTPS fetch of the private canonical repository failed"
					: "Authenticated HTTPS fetch of the canonical repository failed";
				setPrimary(result, "setup_failure", "setup", `${authContext}; captured fetch output was suppressed.`);
			} else {
				applyOutput(result, fetch);
				const detail = fetch.spawnError ?? (sanitizeOutput(fetch.output.stderr).trim() || "git fetch failed");
				setPrimary(result, "setup_failure", "setup", `Unauthenticated public HTTPS fetch of the canonical repository failed: ${detail}`);
			}
			return result;
		}

		const staged = await runGit(["--git-dir", stagingRepository, "rev-parse", "--verify", `${stagingRef}^{commit}`]);
		if (staged.aborted || staged.timedOut) {
			setPrimary(result, staged.aborted ? "aborted" : "timeout", "setup", "Verification stopped while validating the staged pull-request commit.");
			return result;
		}
		const stagedSha = sanitizeOutput(staged.output.stdout).trim();
		if (staged.exitCode !== 0 || staged.spawnError || stagedSha !== request.headSha) {
			setPrimary(result, "stale_head", "setup", `Staged pull-request head ${stagedSha || "(unresolved)"} does not equal captured head ${request.headSha}.`);
			return result;
		}

		// Import only from the already-fetched local path after authentication and its
		// helper have been destroyed. Original local hooks/config may run here, but the
		// environment is minimal and contains no token; --no-write-fetch-head preserves
		// the caller's FETCH_HEAD. Verify the destination ref independently afterward.
		const imported = await runGit([
			"-C", repoRoot, "fetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules",
			stagingRepository,
			`+${stagingRef}:${fetchRef}`,
		]);
		if (imported.aborted || imported.timedOut || imported.exitCode !== 0 || imported.spawnError) {
			applyOutput(result, imported);
			setPrimary(result, imported.aborted ? "aborted" : imported.timedOut ? "timeout" : "setup_failure", "setup", "Unable to import the staged pull-request commit into the original repository.");
			return result;
		}
		const resolved = await runGit(["-C", repoRoot, "rev-parse", "--verify", `${fetchRef}^{commit}`]);
		if (resolved.aborted) {
			setPrimary(result, "aborted", "setup", "Verification aborted while resolving the imported pull-request ref.");
			return result;
		}
		if (resolved.timedOut) {
			setPrimary(result, "timeout", "setup", "The total verification deadline expired while resolving the imported pull-request ref.");
			return result;
		}
		const fetchedSha = sanitizeOutput(resolved.output.stdout).trim();
		if (resolved.exitCode !== 0 || resolved.spawnError || fetchedSha !== request.headSha) {
			setPrimary(result, "stale_head", "setup", `Imported pull-request head ${fetchedSha || "(unresolved)"} does not equal captured head ${request.headSha}.`);
			return result;
		}
		const added = await runGit(["-C", repoRoot, "worktree", "add", "--detach", worktreePath, request.headSha]);
		if (added.aborted) {
			setPrimary(result, "aborted", "setup", "Verification aborted while creating the detached worktree.");
			return result;
		}
		if (added.timedOut) {
			setPrimary(result, "timeout", "setup", "The total verification deadline expired while creating the detached worktree.");
			return result;
		}
		if (added.exitCode !== 0 || added.spawnError) {
			applyOutput(result, added);
			setPrimary(result, "setup_failure", "setup", `Unable to create detached worktree: ${added.spawnError ?? (sanitizeOutput(added.output.stderr).trim() || "git worktree add failed")}`);
			return result;
		}
		worktreeAdded = true;
		if (signal?.aborted) {
			setPrimary(result, "aborted", "setup", "Verification aborted before the configured baseline command.");
			return result;
		}
		commandStartedAt = now();
		const command = await runProcess(profile.argv[0], profile.argv.slice(1), {
			cwd: worktreePath,
			env: minimalCommandEnv(tempDir),
			signal,
			deadlineMs: setupCommandDeadline,
			...common,
		});
		commandFinishedAt = now();
		observe(command);
		applyOutput(result, command);
		result.exitCode = command.exitCode ?? undefined;
		result.signal = command.signal ?? undefined;
		if (command.aborted) setPrimary(result, "aborted", "command", "Baseline verification was aborted; TERM/KILL supervision of the original POSIX process group was attempted.");
		else if (command.timedOut) setPrimary(result, "timeout", "command", `Baseline verification exhausted the profile's ${profile.totalTimeoutMs}ms total lifecycle budget.`);
		else if (command.spawnError) setPrimary(result, "failure", "command", `Unable to spawn the configured baseline executable: ${command.spawnError}`);
		else if (command.exitCode === 0) setPrimary(result, "success", "command", "Configured baseline verification completed successfully.");
		else setPrimary(result, "failure", "command", `Configured baseline verification exited with code ${command.exitCode ?? "unknown"}.`);
		return result;
	} catch (error) {
		setPrimary(result, signal?.aborted ? "aborted" : now() >= setupCommandDeadline ? "timeout" : "setup_failure", commandStartedAt ? "command" : "setup", error instanceof Error ? error.message : String(error));
		return result;
	} finally {
		cleanupStartedAt = now();
		result.cleanupOutcome.attempted = tempDir !== undefined || fetchRef !== undefined || worktreePath !== undefined;
		const cleanupGit = async (args: string[]): Promise<ProcessResult> => {
			if (!gitExecutable) throw new Error("Git cleanup was requested before trusted Git discovery completed.");
			const processResult = await runProcess(gitExecutable, args, {
				env: minimalGitEnv(tempDir ?? os.tmpdir()),
				deadlineMs: cleanupEmergencyDeadline,
				...common,
			});
			observe(processResult);
			return processResult;
		};
		if (repoRoot && worktreePath) {
			const existed = fs.existsSync(worktreePath);
			const removed = await cleanupGit(["-C", repoRoot, "worktree", "remove", "--force", worktreePath]);
			result.cleanupOutcome.worktreeRemoved = removed.exitCode === 0 || (!worktreeAdded && !existed);
			if (!result.cleanupOutcome.worktreeRemoved) result.cleanupOutcome.errors.push(`worktree remove failed: ${removed.spawnError ?? (sanitizeOutput(removed.output.stderr).trim() || "unknown error")}`);
		}
		if (repoRoot && fetchRef) {
			const removedRef = await cleanupGit(["-C", repoRoot, "update-ref", "-d", fetchRef]);
			result.cleanupOutcome.fetchRefRemoved = removedRef.exitCode === 0;
			if (!result.cleanupOutcome.fetchRefRemoved) result.cleanupOutcome.errors.push(`fetch ref cleanup failed: ${removedRef.spawnError ?? (sanitizeOutput(removedRef.output.stderr).trim() || "unknown error")}`);
		}
		if (tempDir) {
			const remaining = Math.max(0, cleanupEmergencyDeadline - now());
			let timer: ReturnType<typeof setTimeout> | undefined;
			try {
				const removal = fs.promises.rm(tempDir, { recursive: true, force: true });
				await Promise.race([
					removal,
					new Promise<never>((_, reject) => {
						timer = setTimeout(() => reject(new Error("temporary directory removal exceeded cleanup deadline")), remaining);
					}),
				]);
				result.cleanupOutcome.tempDirRemoved = !fs.existsSync(tempDir);
				if (!result.cleanupOutcome.tempDirRemoved) result.cleanupOutcome.errors.push("temporary directory still exists after removal");
			} catch (error) {
				result.cleanupOutcome.tempDirRemoved = false;
				result.cleanupOutcome.errors.push(`temp directory cleanup failed: ${error instanceof Error ? error.message : String(error)}`);
			} finally {
				if (timer) clearTimeout(timer);
			}
		}
		if (tempDir) redactTemporaryPath(result, tempDir);
		result.output.droppedBytes.stdout += suppressedAuthenticatedFetchBytes.stdout;
		result.output.droppedBytes.stderr += suppressedAuthenticatedFetchBytes.stderr;
		result.output.droppedBytes.total += suppressedAuthenticatedFetchBytes.stdout + suppressedAuthenticatedFetchBytes.stderr;
		const finishedAt = now();
		result.timing.setupMs = roundMs((commandStartedAt ?? cleanupStartedAt) - startedAt);
		result.timing.commandMs = roundMs(commandStartedAt && commandFinishedAt ? commandFinishedAt - commandStartedAt : 0);
		result.timing.cleanupMs = roundMs(finishedAt - cleanupStartedAt);
		result.timing.totalMs = roundMs(finishedAt - startedAt);
		finalizeResult(result, serializedMaxBytes);
	}
}

export function verificationLifecycleFailed(result: VerifyResult): boolean {
	return !result.lifecycleOk;
}
