#!/usr/bin/env node
// Reimplementation of @runecraft/skills' digestFiles, used to independently
// verify that sq-skill-registry.sh's --grimoire-output contentSha256 matches
// the real algorithm rather than just being internally self-consistent.
//
// Re-implemented check-for-check from packages/core/src/index.ts lines 13-17
// of the runecraftai/skills clone, as read on 2026-10-06 (see
// grimoire-registry-validate.mjs for why the real package cannot be
// imported directly):
//
//   export function digestFiles(files) {
//     const hash = createHash("sha256");
//     for (const file of [...files].sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)))) {
//       hash.update(normalizePath(file.path));
//       hash.update(Buffer.from([0]));
//       hash.update(file.bytes);
//     }
//     return hash.digest("hex");
//   }
//
// CLI: node grimoire-digest-files.mjs <skill-dir> <relative-path>...
// Prints the hex digest for the given skill directory's files, read from
// disk in the given relative paths, sorted and hashed exactly as above.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export function digestFiles(files) {
  const hash = createHash("sha256");
  for (const file of [...files].sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)))) {
    hash.update(file.path);
    hash.update(Buffer.from([0]));
    hash.update(file.bytes);
  }
  return hash.digest("hex");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const skillDir = process.argv[2];
  const relPaths = process.argv.slice(3);
  if (!skillDir || relPaths.length === 0) {
    console.error("usage: grimoire-digest-files.mjs <skill-dir> <relative-path>...");
    process.exit(2);
  }
  const files = relPaths.map((path) => ({ path, bytes: readFileSync(join(skillDir, path)) }));
  console.log(digestFiles(files));
}
