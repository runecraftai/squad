// Leaf module: node builtins only. Guards a locally linked dist from silently
// running when its TypeScript source is newer. Published npm packages ship only
// `dist` (see package.json `files`), so the guard is inert there.
import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

export const STALE_BUILD_EXIT_CODE = 49;

export interface StaleBuild {
  entryPath: string;
  newestSourcePath: string;
  buildMtimeMs: number;
  sourceMtimeMs: number;
}

function isSourceFile(name: string): boolean {
  return name.endsWith(".ts") && !name.endsWith(".d.ts");
}

function newestSourceAfter(
  dir: string,
  afterMs: number,
): { path: string; mtimeMs: number } | null {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return null;
  }
  let newest: { path: string; mtimeMs: number } | null = null;
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      const nested = newestSourceAfter(full, afterMs);
      if (nested && (!newest || nested.mtimeMs > newest.mtimeMs)) {
        newest = nested;
      }
      continue;
    }
    if (!entry.isFile() || !isSourceFile(entry.name)) continue;
    let mtimeMs: number;
    try {
      mtimeMs = statSync(full).mtimeMs;
    } catch {
      continue;
    }
    if (mtimeMs > afterMs && (!newest || mtimeMs > newest.mtimeMs)) {
      newest = { path: full, mtimeMs };
    }
  }
  return newest;
}

export function findStaleBuild(
  entryPath: string,
  sourceDirs: string[],
): StaleBuild | null {
  let buildMtimeMs: number;
  try {
    buildMtimeMs = statSync(entryPath).mtimeMs;
  } catch {
    return null;
  }
  let newest: { path: string; mtimeMs: number } | null = null;
  for (const dir of sourceDirs) {
    const candidate = newestSourceAfter(dir, buildMtimeMs);
    if (candidate && (!newest || candidate.mtimeMs > newest.mtimeMs)) {
      newest = candidate;
    }
  }
  if (!newest) return null;
  return {
    entryPath,
    newestSourcePath: newest.path,
    buildMtimeMs,
    sourceMtimeMs: newest.mtimeMs,
  };
}

function packageRootForDistEntry(entryPath: string): string | null {
  const binDir = dirname(entryPath);
  const distDir = dirname(binDir);
  if (basename(binDir) !== "bin" || basename(distDir) !== "dist") return null;
  return dirname(distDir);
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
  const sourceDirs = [join(packageRoot, "src"), join(packageRoot, "bin")];
  if (!sourceDirs.some((dir) => existsSync(dir))) return null;
  return findStaleBuild(entryPath, sourceDirs);
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
  const files: string[] = [];
  for (const dir of scope.dirs) {
    if (existsSync(dir)) collectRuntimeFiles(dir, scope.isRuntimeFile, files);
  }
  if (files.length === 0) return null;
  files.sort();
  const hash = createHash("sha256");
  for (const file of files) {
    let contents: Buffer;
    try {
      contents = readFileSync(file);
    } catch {
      return null;
    }
    hash.update(relative(scope.root, file));
    hash.update("\0");
    hash.update(contents);
    hash.update("\0");
  }
  return hash.digest("hex");
}

export function formatStaleBuildError(stale: StaleBuild): string {
  const seconds = Math.max(
    0,
    Math.round((stale.sourceMtimeMs - stale.buildMtimeMs) / 1000),
  );
  return [
    "sq-browser is running a stale build and will not continue.",
    `  build: ${stale.entryPath}`,
    `  newer source: ${stale.newestSourcePath} (${seconds}s newer than the build)`,
    "This local checkout's compiled dist predates its TypeScript source, so the CLI would run old behavior.",
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
