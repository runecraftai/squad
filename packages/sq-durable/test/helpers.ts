import { type ChildProcess, execFile, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const PACKAGE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const CLI = join(PACKAGE_DIR, "dist", "cli.js");
const NODE_ARGS = ["--disable-warning=ExperimentalWarning", CLI];

const scratch: string[] = [];
const services: Service[] = [];

/** A short temporary directory, so the store's socket path stays well under the sun_path limit. */
export function tempDir(): string {
	const dir = mkdtempSync(join(tmpdir(), "sqd-"));
	scratch.push(dir);
	return dir;
}

/** Kill every service a test started and remove its directories. */
export async function cleanup(): Promise<void> {
	for (const service of services.splice(0)) await service.kill9().catch(() => {});
	for (const dir of scratch.splice(0)) rmSync(dir, { recursive: true, force: true });
}

export type CliResult = { code: number; stdout: string; stderr: string; json: any };

export function cli(args: string[], env: NodeJS.ProcessEnv = {}): Promise<CliResult> {
	return new Promise((resolvePromise) => {
		execFile(process.execPath, [...NODE_ARGS, ...args], { env: { ...process.env, ...env }, timeout: 60_000 }, (error, stdout, stderr) => {
			const code = error === null ? 0 : typeof error.code === "number" ? error.code : 1;
			let json: unknown;
			try {
				json = JSON.parse(stdout);
			} catch {
				json = undefined;
			}
			resolvePromise({ code, stdout, stderr, json });
		});
	});
}

export async function initStore(lab = true): Promise<string> {
	const store = join(tempDir(), "store");
	const result = await cli(["init", "--store", store, ...(lab ? ["--lab"] : []), "--json"]);
	if (result.code !== 0) throw new Error(`init failed: ${result.stderr}`);
	return store;
}

export class Service {
	readonly process: ChildProcess;
	readonly exited: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
	log = "";

	private constructor(store: string, options: { pollMs?: number; env?: NodeJS.ProcessEnv }) {
		this.process = spawn(process.execPath, [...NODE_ARGS, "serve", "--store", store, "--poll-ms", String(options.pollMs ?? 200)], {
			env: { ...process.env, ...options.env },
			stdio: ["ignore", "ignore", "pipe"],
		});
		this.process.stderr?.setEncoding("utf8");
		this.process.stderr?.on("data", (chunk: string) => {
			this.log += chunk;
		});
		this.exited = new Promise((resolvePromise) => {
			this.process.once("exit", (code, signal) => resolvePromise({ code, signal }));
		});
	}

	static start(store: string, options: { pollMs?: number; env?: NodeJS.ProcessEnv } = {}): Service {
		const service = new Service(store, options);
		services.push(service);
		return service;
	}

	get pid(): number {
		return this.process.pid as number;
	}

	alive(): boolean {
		return this.process.exitCode === null && this.process.signalCode === null;
	}

	async kill9(): Promise<{ code: number | null; signal: NodeJS.Signals | null }> {
		if (this.alive()) this.process.kill("SIGKILL");
		return this.exited;
	}
}

export async function waitReady(store: string, seconds = 10): Promise<any> {
	const result = await cli(["ready", "--store", store, "--wait", String(seconds), "--json"]);
	if (result.code !== 0) throw new Error(`service not ready: ${result.stdout} ${result.stderr}`);
	return result.json;
}

export async function startReady(store: string, options: { pollMs?: number; env?: NodeJS.ProcessEnv } = {}): Promise<Service> {
	const service = Service.start(store, options);
	const report = await waitReady(store);
	if (report.pid !== service.pid) throw new Error(`ready answered from pid ${report.pid}, expected ${service.pid}`);
	return service;
}

export async function until<T>(probe: () => Promise<T | undefined>, timeoutMs: number, what: string): Promise<T> {
	const deadline = Date.now() + timeoutMs;
	for (;;) {
		const value = await probe();
		if (value !== undefined) return value;
		if (Date.now() > deadline) throw new Error(`timed out after ${timeoutMs} ms waiting for ${what}`);
		await new Promise((r) => setTimeout(r, 50));
	}
}

export function ledgerOf(store: string): any {
	try {
		return JSON.parse(readFileSync(join(store, "executor-ledger.json"), "utf8"));
	} catch {
		return { counters: { invocations: 0, applyCalls: 0, distinctKeys: 0, appliedEffects: 0, receipts: 0 }, effects: {} };
	}
}

export async function admit(store: string, mission = "dm1-test", revision = "r1", args = '{"k":"v"}'): Promise<CliResult> {
	return cli(["admit", "--store", store, "--mission", mission, "--action", "lab-deploy", "--revision", revision, "--args", args, "--json"]);
}

export async function answer(store: string, approvalId: string, extra: string[] = []): Promise<CliResult> {
	return cli(["answer", "--store", store, "--approval", approvalId, "--json", ...extra]);
}

export async function receipt(store: string, approvalId: string): Promise<any> {
	const result = await cli(["receipt", "--store", store, "--approval", approvalId, "--json"]);
	if (result.code !== 0) throw new Error(`receipt failed: ${result.stderr}`);
	return result.json;
}

export async function stats(store: string): Promise<any> {
	const result = await cli(["stats", "--store", store, "--json"]);
	if (result.code !== 0) throw new Error(`stats failed: ${result.stderr}`);
	return result.json;
}

export async function waitEffect(store: string, approvalId: string, timeoutMs = 8_000): Promise<any> {
	return until(
		async () => {
			const view = await receipt(store, approvalId);
			return view.effect?.state === "applied" || view.missionStatus === "reconcile" ? view : undefined;
		},
		timeoutMs,
		`effect of ${approvalId}`,
	);
}
