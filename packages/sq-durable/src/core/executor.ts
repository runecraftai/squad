/**
 * Executor contract: the only way the core touches the outside world. An executor must answer "already applied?" for a
 * key, apply with that same key, and return a receipt the core can verify against the key it asked for.
 */

/** What the core asks an executor to do: one logical effect under one idempotent key. */
export type EffectRequest = {
	/** Stable logical identity of the effect, the same across every attempt. */
	readonly effectId: string;
	/** Idempotent key taken from the continuation receipt; no attempt ever mints another. */
	readonly effectKey: string;
	/** Digest of the exact payload; the receipt must carry the same digest. */
	readonly payloadDigest: string;
	readonly payload: { readonly [key: string]: unknown };
};

/** Verifiable receipt from the executor's own records, independent of the durable store. */
export type ExternalReceipt = {
	readonly receiptId: string;
	readonly effectKey: string;
	readonly payloadDigest: string;
	readonly target: string;
	readonly appliedAt: number;
};

/** Answer to "already applied?". `ambiguous` means the executor cannot tell, and the core must not apply. */
export type LookupResult =
	| { readonly status: "applied"; readonly receipt: ExternalReceipt }
	| { readonly status: "absent" }
	| { readonly status: "ambiguous"; readonly reason: string };

export interface Executor {
	/** Name recorded in effect receipts. */
	readonly name: string;
	/** Report whether the effect with this key was already applied, with its receipt when it was. */
	lookup(effectKey: string, signal: AbortSignal): Promise<LookupResult>;
	/** Apply under `request.effectKey`; applying an already applied key returns its existing receipt. */
	apply(request: EffectRequest, signal: AbortSignal): Promise<ExternalReceipt>;
	/** Find a running execution for the key, when the executor supports it. */
	locate?(effectKey: string, signal: AbortSignal): Promise<{ readonly running: boolean } | undefined>;
	/** Interrupt a running execution for the key, when the executor supports it. */
	interrupt?(effectKey: string, signal: AbortSignal): Promise<void>;
}

/** A receipt is accepted only when it names the key and the payload the core asked for. */
export function verifyReceipt(receipt: ExternalReceipt, request: Pick<EffectRequest, "effectKey" | "payloadDigest">): boolean {
	return (
		typeof receipt.receiptId === "string" &&
		receipt.receiptId.length > 0 &&
		receipt.effectKey === request.effectKey &&
		receipt.payloadDigest === request.payloadDigest
	);
}
