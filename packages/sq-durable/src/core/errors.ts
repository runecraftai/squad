/** Refusal codes a command can end with without writing anything durable it was not meant to write. */
export type DomainErrorCode =
	| "invalid"
	| "conflict"
	| "not_found"
	| "stale_revision"
	| "action_mismatch"
	| "closed";

/**
 * A definitive refusal from the domain. Thrown inside a commit callback it rolls the whole commit back, so a refused
 * command leaves the store exactly as it found it.
 */
export class DomainError extends Error {
	readonly code: DomainErrorCode;
	readonly detail: Record<string, unknown> | undefined;

	constructor(code: DomainErrorCode, message: string, detail?: Record<string, unknown>) {
		super(message);
		this.name = "DomainError";
		this.code = code;
		this.detail = detail;
	}
}
