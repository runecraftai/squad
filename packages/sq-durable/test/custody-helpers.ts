import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { PACKAGE_DIR, tempDir } from "./helpers.js";

export const REPO_ROOT = resolve(PACKAGE_DIR, "..", "..");
export const CUSTODY_LIB = join(REPO_ROOT, "bin", "sq-durable-custody.sh");

/** A throwaway Squad base: state/, data/, and the refusal log custody keeps under data/durable/. */
export function sandboxBase(): string {
	const base = join(tempDir(), "base");
	mkdirSync(join(base, "state"), { recursive: true });
	mkdirSync(join(base, "data"), { recursive: true });
	return base;
}

/** The environment of a real legacy script run against `base`, cleared of every ambient runtime it could pick up. */
export function scriptEnv(base: string, extra: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = {};
	for (const [key, value] of Object.entries(process.env)) {
		if (/^(?:HERDR|TMUX|ZELLIJ|CMUX|ORCA|TUIOS|SQUAD_|SQ_DURABLE|CLAUDE|CODEX)/.test(key)) continue;
		env[key] = value;
	}
	return { ...env, SQUAD_BASE: base, SQUAD_SPAWN_NO_GUARD: "1", SQUAD_GATE_REFUSE_BYPASS: "1", ...extra };
}

export type RunResult = { code: number; stdout: string; stderr: string };

export function runBash(args: string[], env: NodeJS.ProcessEnv, input = ""): Promise<RunResult> {
	return new Promise((resolvePromise) => {
		const child = execFile("bash", args, { cwd: REPO_ROOT, env, timeout: 60_000 }, (error, stdout, stderr) => {
			const code = error === null ? 0 : typeof error.code === "number" ? error.code : 1;
			resolvePromise({ code, stdout, stderr });
		});
		child.stdin?.end(input);
	});
}

export function runScript(script: string, args: string[], env: NodeJS.ProcessEnv): Promise<RunResult> {
	return runBash([join(REPO_ROOT, "bin", script), ...args], env);
}

/** Source the custody library and run one check, as every consultation point does. */
export function custodyCheck(id: string, responsibilities: string[], env: NodeJS.ProcessEnv): Promise<RunResult> {
	return runBash(["-c", `. "$1"; shift; durable_custody_check "$@"`, "custody", CUSTODY_LIB, id, ...responsibilities], env);
}

function files(dir: string): string[] {
	if (!existsSync(dir)) return [];
	return readdirSync(dir).flatMap((name) => {
		const full = join(dir, name);
		return statSync(full).isDirectory() ? files(full) : [full];
	});
}

/**
 * Digest of every file in the base's state/ and data/, path and content. The refusal log under data/durable/ is the one
 * thing a refusal writes, and the supervision banner marker is written by sq-guard before any task logic runs, so both
 * stay out of the digest.
 */
export function stateDigest(base: string): string {
	const hash = createHash("sha256");
	for (const file of [...files(join(base, "state")), ...files(join(base, "data"))].sort()) {
		const path = relative(base, file);
		if (path.startsWith("data/durable/") || path.startsWith("state/.guard-sentry-stale-banner")) continue;
		hash.update(`${path}\0`);
		hash.update(readFileSync(file));
		hash.update("\0");
	}
	return hash.digest("hex");
}

export function refusalLog(base: string): string[] {
	const log = join(base, "data", "durable", "custody-refusals.log");
	return existsSync(log) ? readFileSync(log, "utf8").split("\n").filter((line) => line !== "") : [];
}

/** A durable task's legacy records, as sq-spawn would have left them. */
export function seedTask(base: string, id: string, fields: Record<string, string> = {}): void {
	const meta = { window: `sq-${id}`, kind: "strike", mode: "local-only", yolo: "off", harness: "claude", worktree: "", project: "", ...fields };
	const text = Object.entries(meta)
		.map(([key, value]) => `${key}=${value}`)
		.join("\n");
	writeFileSync(join(base, "state", `${id}.meta`), `${text}\n`);
	writeFileSync(join(base, "state", `${id}.status`), "working: started\nneeds-decision [key=land]: approve landing\n");
}
