import { createHash } from "node:crypto";

/** JSON value accepted by the canonical encoder. */
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

/**
 * Canonical JSON: object keys sorted at every level, no whitespace. Two inputs with the same meaning always produce the
 * same text, so their digest is a stable content identity.
 */
export function canonicalJson(value: Json): string {
	if (value === null || typeof value !== "object") {
		if (typeof value === "number" && !Number.isFinite(value)) throw new TypeError("non-finite number in canonical JSON");
		return JSON.stringify(value);
	}
	if (Array.isArray(value)) return `[${value.map((item) => canonicalJson(item as Json)).join(",")}]`;
	const object = value as { [key: string]: Json };
	const keys = Object.keys(object)
		.filter((key) => object[key] !== undefined)
		.sort();
	return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(object[key] as Json)}`).join(",")}}`;
}

/** Hex SHA-256 of a UTF-8 string. */
export function sha256(text: string): string {
	return createHash("sha256").update(text, "utf8").digest("hex");
}

/** Hex SHA-256 of the canonical JSON of `value`. */
export function digestOf(value: Json): string {
	return sha256(canonicalJson(value));
}

/** Plain deep copy of a JSON value, also of a document draft, which may not be structured-cloneable. */
export function plainCopy<T>(value: T): T {
	return JSON.parse(JSON.stringify(value)) as T;
}
