#!/usr/bin/env node
// Decode sq-gh's TOON-formatted stdout into JSON on stdout.
//
// sq-gh always renders through the TOON format (its `--json` mode only wraps
// the rendered TOON string, it does not emit structured data), wrapping the
// real data with a leading `count:`/`total_count:` scalar line and a trailing
// `help[...]:` block of plain-string suggestions. Neither is part of the
// payload and the plain-string array form trips the decoder, so this strips
// both by top-level key before handing the rest to `decode`.
//
// The decoder is a vendored, byte-identical copy of @toon-format/toon@2.3.1
// (MIT), at ./vendor/toon/index.mjs, so this step never depends on an
// npm/pnpm/bun install being present at the repo root.
import { decode } from "./vendor/toon/index.mjs";

const DROP_KEYS = new Set(["count", "total_count", "help"]);

function stripNonData(text) {
  const lines = text.split("\n");
  const kept = [];
  let dropping = false;
  for (const line of lines) {
    const isTopLevel = line.length > 0 && !/^[ \t]/.test(line);
    if (isTopLevel) {
      const key = line.split(/[:[]/, 1)[0].trim();
      dropping = DROP_KEYS.has(key);
    }
    if (!dropping) kept.push(line);
  }
  return kept.join("\n");
}

function main() {
  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    input += chunk;
  });
  process.stdin.on("end", () => {
    try {
      const stripped = stripNonData(input);
      const data = stripped.trim() ? decode(stripped) : {};
      process.stdout.write(JSON.stringify(data));
    } catch (error) {
      process.stderr.write(`toon-decode-error: ${error.message}\n`);
      process.exitCode = 1;
    }
  });
}

main();
