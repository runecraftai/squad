import type { DomainErrorCode } from "../core/index.js";

/**
 * Local socket protocol: one JSON request per line, one JSON response per line. Every request and response carries the
 * protocol version; a peer whose major version differs is refused with an explicit message, never half-understood.
 */
export const PROTOCOL_VERSION = "1.0";
export const PROTOCOL_MAJOR = 1;

export const COMMANDS = ["ready", "custody", "admit", "pending", "answer", "receipt", "mission", "stats"] as const;
export type Command = (typeof COMMANDS)[number];

/** Commands that write; refused unless the service is ready or degraded. */
export const MUTATING_COMMANDS: readonly Command[] = ["admit", "answer"];

export type ErrorCode =
	| DomainErrorCode
	| "protocol_mismatch"
	| "bad_request"
	| "unknown_command"
	| "not_ready"
	| "failed"
	| "internal";

export type Request = {
	readonly protocol: string;
	readonly id: string;
	readonly command: string;
	readonly args?: Record<string, unknown>;
};

export type Response =
	| { readonly protocol: string; readonly id: string; readonly ok: true; readonly result: unknown }
	| {
			readonly protocol: string;
			readonly id: string;
			readonly ok: false;
			readonly code: ErrorCode;
			readonly message: string;
			readonly detail?: unknown;
	  };

export function majorOf(version: unknown): number | undefined {
	if (typeof version !== "string") return undefined;
	const match = /^([0-9]+)\.[0-9]+$/.exec(version);
	return match === null ? undefined : Number(match[1]);
}

/** Explicit refusal text for a peer speaking another major version, or undefined when compatible. */
export function incompatibility(version: unknown, peer: "client" | "service"): string | undefined {
	const major = majorOf(version);
	if (major === PROTOCOL_MAJOR) return undefined;
	const shown = typeof version === "string" ? version : JSON.stringify(version);
	const other = peer === "client" ? "this service" : "this client";
	return `protocol version ${shown} is not supported: ${other} speaks ${PROTOCOL_VERSION} (major ${PROTOCOL_MAJOR}); use a ${peer} of the same major version`;
}

export function ok(id: string, result: unknown): Response {
	return { protocol: PROTOCOL_VERSION, id, ok: true, result };
}

export function refuse(id: string, code: ErrorCode, message: string, detail?: unknown): Response {
	return detail === undefined
		? { protocol: PROTOCOL_VERSION, id, ok: false, code, message }
		: { protocol: PROTOCOL_VERSION, id, ok: false, code, message, detail };
}
