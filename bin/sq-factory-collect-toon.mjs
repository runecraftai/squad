#!/usr/bin/env node
// Decode sq-gh's TOON-formatted stdout into JSON on stdout.
//
// sq-gh always renders through @toon-format/toon (there is no raw-JSON output
// mode), wrapping the real data with a leading `count:`/`total_count:` scalar
// line and a trailing `help[...]:` block of plain-string suggestions. Neither
// is part of the payload and the plain-string array form trips the decoder,
// so this strips both by top-level key before handing the rest to `decode`.
import { decode } from "@toon-format/toon";

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
