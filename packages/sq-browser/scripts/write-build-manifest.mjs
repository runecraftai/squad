// Records the package-local build identity after `tsc`. See
// src/build-guard.ts for the runtime half of the stale-build guard.
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { writeBuildManifest } from "../dist/src/build-guard.js";

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const manifest = writeBuildManifest(packageRoot);
if (manifest === null) {
  console.error(
    "write-build-manifest: could not fingerprint the built dist and its source",
  );
  process.exit(1);
}
