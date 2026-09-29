import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

import {
  computeBuildFingerprint,
  computeDistBuildFingerprint,
  computeSourceBuildFingerprint,
  detectStaleBuild,
  findStaleBuild,
  formatStaleBuildError,
  guardFreshBuild,
  STALE_BUILD_EXIT_CODE,
  writeBuildManifest,
} from "../src/build-guard.js";

const ROOT = resolve(import.meta.dirname, "..");
const TSX = join(ROOT, "node_modules", ".bin", "tsx");
const GUARD_SOURCE = join(ROOT, "src", "build-guard.ts");

const tempDirs: string[] = [];

function makePackageRoot(): string {
  const root = mkdtempSync(join(tmpdir(), "sq-browser-build-guard-"));
  tempDirs.push(root);
  mkdirSync(join(root, "dist", "bin"), { recursive: true });
  return root;
}

function writeFile(path: string, contents = "// x\n"): string {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
  return path;
}

/** utimesSync uses second-resolution mtimes; keep the two timestamps apart. */
function setMtime(path: string, epochSeconds: number): void {
  const when = new Date(epochSeconds * 1000);
  utimesSync(path, when, when);
}

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("detectStaleBuild", () => {
  it("accepts a fresh dist even when source mtimes are newer than the entry", () => {
    const root = makePackageRoot();
    const entry = writeFile(
      join(root, "dist", "bin", "sq-browser.js"),
      "#!/usr/bin/env node\n",
    );
    const source = writeFile(
      join(root, "src", "cli.ts"),
      "export const a = 1;\n",
    );
    writeBuildManifest(root);

    // A cache/rsync restore preserves old dist mtimes while a fresh checkout
    // stamps source mtimes at checkout time. Content is what must decide.
    setMtime(entry, 1_000);
    setMtime(source, 2_000);

    expect(detectStaleBuild(pathToFileURL(entry).href)).toBeNull();
  });

  it("rejects an old dist when source content changed but its mtime is not newer", () => {
    const root = makePackageRoot();
    const entry = writeFile(
      join(root, "dist", "bin", "sq-browser.js"),
      "#!/usr/bin/env node\n",
    );
    const source = writeFile(
      join(root, "src", "cli.ts"),
      "export const a = 1;\n",
    );
    writeBuildManifest(root);

    // Source moves on after the build, but a timestamp-preserving checkout
    // leaves it older than the compiled dist.
    writeFileSync(source, "export const a = 2;\n");
    setMtime(source, 1_000);
    setMtime(entry, 2_000);

    expect(detectStaleBuild(pathToFileURL(entry).href)?.reason).toBe(
      "source-mismatch",
    );
  });

  it("rejects a local dist that has no build manifest", () => {
    const root = makePackageRoot();
    const entry = writeFile(join(root, "dist", "bin", "sq-browser.js"));
    writeFile(join(root, "src", "cli.ts"));

    expect(detectStaleBuild(pathToFileURL(entry).href)?.reason).toBe(
      "missing-manifest",
    );
  });

  it("rejects a dist whose compiled files changed after the manifest was recorded", () => {
    const root = makePackageRoot();
    const entry = writeFile(
      join(root, "dist", "bin", "sq-browser.js"),
      "#!/usr/bin/env node\n",
    );
    writeFile(join(root, "src", "cli.ts"), "export const a = 1;\n");
    writeBuildManifest(root);

    writeFileSync(entry, "#!/usr/bin/env node\n// partial emit\n");

    expect(detectStaleBuild(pathToFileURL(entry).href)?.reason).toBe(
      "dist-mismatch",
    );
  });

  it("detects a change in bin source as well as src", () => {
    const root = makePackageRoot();
    const entry = writeFile(join(root, "dist", "bin", "sq-browser.js"));
    writeFile(join(root, "src", "cli.ts"), "export const a = 1;\n");
    const binSource = writeFile(
      join(root, "bin", "sq-browser.ts"),
      "export const b = 1;\n",
    );
    writeBuildManifest(root);

    writeFileSync(binSource, "export const b = 2;\n");

    expect(detectStaleBuild(pathToFileURL(entry).href)?.reason).toBe(
      "source-mismatch",
    );
  });

  it("is inert for a built npm package that ships no TypeScript source", () => {
    const root = makePackageRoot();
    const entry = writeFile(join(root, "dist", "bin", "sq-browser.js"));
    setMtime(entry, 1_000);

    expect(detectStaleBuild(pathToFileURL(entry).href)).toBeNull();
  });

  it("is inert for a source/dev entrypoint outside dist", () => {
    const root = makePackageRoot();
    const entry = writeFile(join(root, "bin", "sq-browser.js"));
    const source = writeFile(join(root, "src", "cli.ts"));
    setMtime(entry, 1_000);
    setMtime(source, 2_000);

    expect(detectStaleBuild(pathToFileURL(entry).href)).toBeNull();
  });
});

describe("computeBuildFingerprint", () => {
  it("changes when a nested compiled module changes in a built layout", () => {
    const root = makePackageRoot();
    const entry = writeFile(join(root, "dist", "bin", "sq-browser-bridge.js"));
    const dependency = writeFile(
      join(root, "dist", "src", "bridge.js"),
      "export const a = 1;\n",
    );

    const before = computeBuildFingerprint(entry);
    writeFileSync(dependency, "export const a = 2;\n");
    const after = computeBuildFingerprint(entry);

    expect(before).not.toBeNull();
    expect(after).not.toBeNull();
    expect(after).not.toBe(before);
  });

  it("is stable for an unchanged built layout", () => {
    const root = makePackageRoot();
    const entry = writeFile(join(root, "dist", "bin", "sq-browser-bridge.js"));
    writeFile(join(root, "dist", "src", "bridge.js"));
    writeFile(join(root, "dist", "src", "bridge.d.ts"));

    expect(computeBuildFingerprint(entry)).toBe(computeBuildFingerprint(entry));
  });

  it("fingerprints source files for an unbundled source entry", () => {
    const root = makePackageRoot();
    const entry = writeFile(join(root, "bin", "sq-browser-bridge.ts"));
    const dependency = writeFile(
      join(root, "src", "bridge.ts"),
      "export const a = 1;\n",
    );

    const before = computeBuildFingerprint(entry);
    writeFileSync(dependency, "export const a = 2;\n");

    expect(before).not.toBeNull();
    expect(computeBuildFingerprint(entry)).not.toBe(before);
  });

  it("is inert for an entry outside a package source/build layout", () => {
    const root = makePackageRoot();
    const entry = writeFile(join(root, "scripts", "tool.js"));

    expect(computeBuildFingerprint(entry)).toBeNull();
  });

  it("dist and source fingerprints match their dedicated helpers", () => {
    const root = makePackageRoot();
    const distEntry = writeFile(
      join(root, "dist", "bin", "sq-browser.js"),
      "#!/usr/bin/env node\n",
    );
    const sourceEntry = writeFile(
      join(root, "bin", "sq-browser.ts"),
      "export const a = 1;\n",
    );

    expect(computeBuildFingerprint(distEntry)).toBe(
      computeDistBuildFingerprint(root),
    );
    expect(computeBuildFingerprint(sourceEntry)).toBe(
      computeSourceBuildFingerprint(root),
    );
  });
});

describe("findStaleBuild", () => {
  it("accepts a source-matched, dist-matched build", () => {
    const root = makePackageRoot();
    const entry = writeFile(
      join(root, "dist", "bin", "sq-browser.js"),
      "#!/usr/bin/env node\n",
    );
    writeFile(join(root, "src", "cli.ts"), "export const a = 1;\n");
    writeBuildManifest(root);

    expect(findStaleBuild(entry, root)).toBeNull();
  });
});

describe("guardFreshBuild", () => {
  it("returns the rebuild instruction when the build has no manifest", () => {
    const root = makePackageRoot();
    const entry = writeFile(join(root, "dist", "bin", "sq-browser.js"));
    writeFile(join(root, "src", "cli.ts"));

    const message = guardFreshBuild(pathToFileURL(entry).href, {});

    expect(message).toContain("stale build");
    expect(message).toContain(entry);
    expect(message).toContain("pnpm run build");
    expect(message).toContain("SQ_BROWSER_SKIP_BUILD_CHECK=1");
  });

  it("honors the bypass environment variable", () => {
    const root = makePackageRoot();
    const entry = writeFile(join(root, "dist", "bin", "sq-browser.js"));
    writeFile(join(root, "src", "cli.ts"));

    expect(
      guardFreshBuild(pathToFileURL(entry).href, {
        SQ_BROWSER_SKIP_BUILD_CHECK: "1",
      }),
    ).toBeNull();
  });
});

describe("formatStaleBuildError", () => {
  it("names the stale build and the remedy", () => {
    const message = formatStaleBuildError({
      entryPath: "/pkg/dist/bin/sq-browser.js",
      reason: "source-mismatch",
    });

    expect(message).toContain("/pkg/dist/bin/sq-browser.js");
    expect(message).toContain("pnpm run build");
  });
});

describe("stale-build guard process boundary", () => {
  const canSpawnTsx = existsSync(TSX);

  function runGuardEntry(entry: string): {
    status: number | null;
    stderr: string;
    stdout: string;
  } {
    const result = spawnSync(TSX, [entry], { encoding: "utf8" });
    return {
      status: result.status,
      stderr: result.stderr,
      stdout: result.stdout,
    };
  }

  function guardEntrySource(): string {
    const guardUrl = pathToFileURL(GUARD_SOURCE).href;
    return [
      `import { guardFreshBuild, STALE_BUILD_EXIT_CODE } from ${JSON.stringify(guardUrl)};`,
      "const message = guardFreshBuild(import.meta.url);",
      "if (message) {",
      "  process.stderr.write(`${message}\\n`);",
      "  process.exit(STALE_BUILD_EXIT_CODE);",
      "}",
      'process.stdout.write("ran\\n");',
      "",
    ].join("\n");
  }

  it.runIf(canSpawnTsx)(
    "refuses to run and exits with the stale-build code when the source changed after the manifest",
    () => {
      const root = makePackageRoot();
      const source = writeFile(
        join(root, "src", "cli.ts"),
        "export const a = 1;\n",
      );
      const entry = writeFile(
        join(root, "dist", "bin", "guard-entry.ts"),
        guardEntrySource(),
      );
      writeFile(
        join(root, "dist", "bin", "sq-browser.js"),
        "#!/usr/bin/env node\n",
      );
      writeBuildManifest(root);

      writeFileSync(source, "export const a = 2;\n");
      setMtime(source, 1_000);
      setMtime(entry, 2_000);

      const result = runGuardEntry(entry);

      expect(result.status).toBe(STALE_BUILD_EXIT_CODE);
      expect(result.stderr).toContain("stale build");
      expect(result.stdout).toBe("");
    },
    30_000,
  );

  it.runIf(canSpawnTsx)(
    "runs normally when the manifest matches the source even if the entry mtime is older",
    () => {
      const root = makePackageRoot();
      const source = writeFile(
        join(root, "src", "cli.ts"),
        "export const a = 1;\n",
      );
      const entry = writeFile(
        join(root, "dist", "bin", "guard-entry.ts"),
        guardEntrySource(),
      );
      writeFile(
        join(root, "dist", "bin", "sq-browser.js"),
        "#!/usr/bin/env node\n",
      );
      writeBuildManifest(root);

      setMtime(entry, 1_000);
      setMtime(source, 2_000);

      const result = runGuardEntry(entry);

      expect(result.status).toBe(0);
      expect(result.stdout).toBe("ran\n");
    },
    30_000,
  );
});
