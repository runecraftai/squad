#!/usr/bin/env node
import { tryFastPath } from "axi-sdk-js/fast-path";
import { guardFreshBuild, STALE_BUILD_EXIT_CODE } from "../src/build-guard.js";
import { VERSION } from "../src/version.js";

const staleBuildError = guardFreshBuild(import.meta.url);
if (staleBuildError) {
  process.stderr.write(`${staleBuildError}\n`);
  process.exit(STALE_BUILD_EXIT_CODE);
}

if (!tryFastPath(process.argv.slice(2), { version: VERSION })) {
  const { main } = await import("../src/cli.js");
  await main(process.argv.slice(2));
}
