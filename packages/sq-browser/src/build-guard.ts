// Leaf module: node builtins only. Guards a locally linked dist from silently
// running when its compiled output does not match its TypeScript source.
// Published npm packages ship only `dist` (see package.json `files`), so the
// guard is inert there.
import { createHash } from "node:crypto";
import {
  existsSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

export const STALE_BUILD_EXIT_CODE = 49;

export const BUILD_MANIFEST_FILENAME = "sq-browser-build.json";
export const BUILD_MANIFEST_VERSION = 1;

export type StaleBuildReason =
  | "missing-manifest"
  | "source-mismatch"
  | "dist-mismatch";

export interface StaleBuild {
  entryPath: string;
  reason: StaleBuildReason;
}

export interface BuildManifest {
  version: number;
  sourceFingerprint: string;
  distFingerprint: string;
}

interface FingerprintScope {
  root: string;
  dirs: string[];
  isRuntimeFile: (name: string) => boolean;
}

function isCompiledRuntimeFile(name: string): boolean {
  return name.endsWith(".js");
}

function isSourceRuntimeFile(name: string): boolean {
  return (
    (name.endsWith(".ts") && !name.endsWith(".d.ts")) || name.endsWith(".js")
  );
}

/**
 * Which on-disk files define the code an entry point actually runs. A built
 * entry (`dist/bin/*.js` or `dist/src/*.js`) fingerprints the whole `dist`
 * tree; a source entry (`bin/*.ts` or `src/*.ts`) fingerprints `src` + `bin`.
 * Both the CLI and the bridge it spawns resolve the same entry, so they derive
 * the same identity from the same checkout.
 */
function fingerprintScopeFor(entryPath: string): FingerprintScope | null {
  const entryDir = basename(dirname(entryPath));
  const parentDir = dirname(dirname(entryPath));
  if (entryDir !== "bin" && entryDir !== "src") return null;
  if (basename(parentDir) === "dist") {
    const packageRoot = dirname(parentDir);
    return {
      root: packageRoot,
      dirs: [join(packageRoot, "dist")],
      isRuntimeFile: isCompiledRuntimeFile,
    };
  }
  return {
    root: parentDir,
    dirs: [join(parentDir, "src"), join(parentDir, "bin")],
    isRuntimeFile: isSourceRuntimeFile,
  };
}

function collectRuntimeFiles(
  dir: string,
  isRuntimeFile: (name: string) => boolean,
  out: string[],
): void {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      collectRuntimeFiles(full, isRuntimeFile, out);
    } else if (entry.isFile() && isRuntimeFile(entry.name)) {
      out.push(full);
    }
  }
}

function hashFiles(root: string, files: string[]): string | null {
  files.sort();
  const hash = createHash("sha256");
  for (const file of files) {
    let contents: Buffer;
    try {
      contents = readFileSync(file);
    } catch {
      return null;
    }
    hash.update(relative(root, file));
    hash.update("\0");
    hash.update(contents);
    hash.update("\0");
  }
  return hash.digest("hex");
}

function fingerprintScopeFiles(scope: FingerprintScope): string | null {
  const files: string[] = [];
  for (const dir of scope.dirs) {
    if (existsSync(dir)) collectRuntimeFiles(dir, scope.isRuntimeFile, files);
  }
  if (files.length === 0) return null;
  return hashFiles(scope.root, files);
}

/**
 * Content fingerprint of the code an entry point would run, or null when the
 * path is not part of a sq-browser package layout (`bin/`, `src/`, or their
 * `dist/` counterparts). A running bridge records the fingerprint it started
 * with so `ensureBridge` can recycle it once the on-disk build no longer
 * matches. Content hashing (not mtime) keeps the check correct even when a
 * rebuild preserves timestamps.
 */
export function computeBuildFingerprint(entryPath: string): string | null {
  const scope = fingerprintScopeFor(entryPath);
  if (scope === null) return null;
  return fingerprintScopeFiles(scope);
}

/**
 * Content fingerprint of the compiled `dist` tree for a package root. This is
 * the same value `computeBuildFingerprint` derives for a built entry, and the
 * build command records it in the build manifest so a later invocation can
 * prove the on-disk dist is byte-for-byte the build that was produced.
 */
export function computeDistBuildFingerprint(
  packageRoot: string,
): string | null {
  return fingerprintScopeFiles({
    root: packageRoot,
    dirs: [join(packageRoot, "dist")],
    isRuntimeFile: isCompiledRuntimeFile,
  });
}

/**
 * Content fingerprint of the TypeScript sources a local build was produced
 * from. `writeBuildManifest` records this at build time and `findStaleBuild`
 * recomputes it at runtime, so a compiled `dist` can prove it matches the
 * current source without relying on mtimes.
 */
export function computeSourceBuildFingerprint(
  packageRoot: string,
): string | null {
  return fingerprintScopeFiles({
    root: packageRoot,
    dirs: [join(packageRoot, "src"), join(packageRoot, "bin")],
    isRuntimeFile: isSourceRuntimeFile,
  });
}

export function buildManifestPath(packageRoot: string): string {
  return join(packageRoot, "dist", BUILD_MANIFEST_FILENAME);
}

function readBuildManifest(packageRoot: string): BuildManifest | null {
  let raw: string;
  try {
    raw = readFileSync(buildManifestPath(packageRoot), "utf-8");
  } catch {
    return null;
  }
  try {
    const data = JSON.parse(raw) as Partial<BuildManifest>;
    if (
      data.version !== BUILD_MANIFEST_VERSION ||
      typeof data.sourceFingerprint !== "string" ||
      data.sourceFingerprint.length === 0 ||
      typeof data.distFingerprint !== "string" ||
      data.distFingerprint.length === 0
    ) {
      return null;
    }
    return {
      version: data.version,
      sourceFingerprint: data.sourceFingerprint,
      distFingerprint: data.distFingerprint,
    };
  } catch {
    return null;
  }
}

/**
 * Record the build identity of the current `dist` and its source. The build
 * command runs this after `tsc`, so the manifest is a package-local, content
 * based record a runtime guard can compare against. Returns null when either
 * side is missing (a published tarball has no `src`/`bin`).
 */
export function writeBuildManifest(packageRoot: string): BuildManifest | null {
  const sourceFingerprint = computeSourceBuildFingerprint(packageRoot);
  const distFingerprint = computeDistBuildFingerprint(packageRoot);
  if (sourceFingerprint === null || distFingerprint === null) return null;
  const manifest: BuildManifest = {
    version: BUILD_MANIFEST_VERSION,
    sourceFingerprint,
    distFingerprint,
  };
  writeFileSync(
    buildManifestPath(packageRoot),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );
  return manifest;
}

function packageRootForDistEntry(entryPath: string): string | null {
  const binDir = dirname(entryPath);
  const distDir = dirname(binDir);
  if (basename(binDir) !== "bin" || basename(distDir) !== "dist") return null;
  return dirname(distDir);
}

/**
 * Decide whether the compiled entry at `entryPath` still matches the current
 * source and its recorded build identity. Returns null for a published install
 * (no source to compare against) and for an entry that is not under a `dist/`
 * layout. Any other outcome is a stale build: a missing/invalid manifest, a
 * source tree that no longer hashes to the recorded source, or a `dist` whose
 * files no longer hash to the recorded build.
 */
export function findStaleBuild(
  entryPath: string,
  packageRoot: string,
): StaleBuild | null {
  try {
    statSync(entryPath);
  } catch {
    return null;
  }
  const currentSourceFingerprint = computeSourceBuildFingerprint(packageRoot);
  if (currentSourceFingerprint === null) return null;
  const manifest = readBuildManifest(packageRoot);
  if (manifest === null) {
    return { entryPath, reason: "missing-manifest" };
  }
  if (manifest.sourceFingerprint !== currentSourceFingerprint) {
    return { entryPath, reason: "source-mismatch" };
  }
  if (manifest.distFingerprint !== computeDistBuildFingerprint(packageRoot)) {
    return { entryPath, reason: "dist-mismatch" };
  }
  return null;
}

export function detectStaleBuild(entryUrl: string): StaleBuild | null {
  let entryPath: string;
  try {
    entryPath = fileURLToPath(entryUrl);
  } catch {
    return null;
  }
  const packageRoot = packageRootForDistEntry(entryPath);
  if (packageRoot === null) return null;
  return findStaleBuild(entryPath, packageRoot);
}

const STALE_BUILD_REASON_TEXT: Record<StaleBuildReason, string> = {
  "missing-manifest":
    "compiled dist has no build manifest, so it cannot be matched to the current source",
  "source-mismatch":
    "compiled dist was built from different TypeScript source than the current checkout",
  "dist-mismatch":
    "compiled dist files changed after the build that recorded them",
};

export function formatStaleBuildError(stale: StaleBuild): string {
  return [
    "sq-browser is running a stale build and will not continue.",
    `  build: ${stale.entryPath}`,
    `This local checkout's ${STALE_BUILD_REASON_TEXT[stale.reason]}.`,
    "Rebuild before running: `pnpm run build` from packages/sq-browser (or `pnpm --filter @runecraft/sq-browser run build`), then re-link if you used `pnpm link`.",
    "Set SQ_BROWSER_SKIP_BUILD_CHECK=1 to bypass this guard.",
  ].join("\n");
}

export function guardFreshBuild(
  entryUrl: string,
  env: NodeJS.ProcessEnv = process.env,
): string | null {
  if (env.SQ_BROWSER_SKIP_BUILD_CHECK === "1") return null;
  const stale = detectStaleBuild(entryUrl);
  return stale ? formatStaleBuildError(stale) : null;
}
