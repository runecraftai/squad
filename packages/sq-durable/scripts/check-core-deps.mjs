#!/usr/bin/env node
// check-core-deps.mjs - one-way dependency rule of the neutral core (plan section 5, Q15).
//
// Usage: node scripts/check-core-deps.mjs [<core-dir>]   (default: src/core)
// Exit 0 when every import in <core-dir> stays inside it or names an allowed module; exit 1 with one line per
// violation otherwise. The core may import only its own files, Pi Durable, and node:crypto. Anything else - Squad
// scripts, backlog, Drill, window runtimes, the adapter, the service, the laboratory - is a violation.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, extname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ALLOWED_MODULES = new Set(["@earendil-works/pi-durable", "node:crypto"]);
const SOURCE = new Set([".ts", ".mts", ".cts", ".js", ".mjs", ".cjs"]);
const IMPORT_PATTERNS = [
	/\bimport\s+(?:type\s+)?[^"';]*?\bfrom\s*["']([^"']+)["']/g,
	/\bexport\s+(?:type\s+)?[^"';]*?\bfrom\s*["']([^"']+)["']/g,
	/\bimport\s*["']([^"']+)["']/g,
	/\bimport\s*\(\s*["']([^"']+)["']\s*\)/g,
	/\brequire\s*\(\s*["']([^"']+)["']\s*\)/g,
];

const here = dirname(fileURLToPath(import.meta.url));
const coreDir = resolve(process.argv[2] ?? join(here, "..", "src", "core"));

function files(dir) {
	return readdirSync(dir).flatMap((name) => {
		const full = join(dir, name);
		if (statSync(full).isDirectory()) return files(full);
		return SOURCE.has(extname(full)) ? [full] : [];
	});
}

const violations = [];
for (const file of files(coreDir)) {
	const text = readFileSync(file, "utf8");
	for (const pattern of IMPORT_PATTERNS) {
		for (const match of text.matchAll(pattern)) {
			const specifier = match[1];
			const where = `${relative(process.cwd(), file)}: ${JSON.stringify(specifier)}`;
			if (specifier.startsWith(".")) {
				const target = resolve(dirname(file), specifier);
				if (target !== coreDir && !target.startsWith(coreDir + sep)) violations.push(`${where} leaves the core`);
			} else if (!ALLOWED_MODULES.has(specifier)) {
				violations.push(`${where} is not an allowed core dependency`);
			}
		}
	}
}

if (violations.length > 0) {
	for (const violation of violations) process.stderr.write(`forbidden core import: ${violation}\n`);
	process.exit(1);
}
process.stdout.write(`core dependency direction ok: ${relative(process.cwd(), coreDir) || "."}\n`);
