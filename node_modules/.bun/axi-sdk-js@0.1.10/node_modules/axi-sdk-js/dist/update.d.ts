import type { AxiRenderable } from "./output.js";
/**
 * Minimal `fetch`-like shape so registry lookups stay decoupled from the global
 * `fetch` typings and trivially mockable in tests.
 */
export type FetchLike = (input: string, init?: {
    headers?: Record<string, string>;
    signal?: AbortSignal;
}) => Promise<{
    ok: boolean;
    status: number;
    json: () => Promise<unknown>;
}>;
/** Structured semver components returned by `parseSemver()`. */
export interface ParsedSemver {
    major: number;
    minor: number;
    patch: number;
    prerelease: string[];
}
/** Parse a semver string. Returns `null` when the version is not valid semver. */
export declare function parseSemver(version: string): ParsedSemver | null;
/**
 * Compare two semver strings. Returns -1, 0, or 1. Unparseable versions fall
 * back to a deterministic lexical comparison so the caller never throws.
 */
export declare function compareSemver(a: string, b: string): number;
/** True when `latest` is a strictly newer version than `current`. */
export declare function isUpdateAvailable(current: string, latest: string): boolean;
/** Package metadata resolved from the nearest named `package.json`. */
export interface PackageIdentity {
    /** npm package name, when a named package.json was found. */
    packageName?: string;
    /** package.json version, when declared. */
    version?: string;
    /** Absolute path to the package.json that supplied the identity. */
    packageJsonPath?: string;
}
/** Small filesystem seam used by updater tests and custom embedders. */
export interface IdentityFs {
    existsSync: (path: string) => boolean;
    readFileSync: (path: string, encoding: "utf-8") => string;
}
/**
 * Walk up from `startPath` to the nearest `package.json` that declares a name,
 * returning the tool's npm package name and version. This is how a tool gains
 * `update` with zero per-tool wiring: its own published `package.json` ships
 * inside the install tree next to the running entrypoint.
 */
export declare function readNearestPackageJson(startPath: string, fs?: IdentityFs): PackageIdentity;
/** Installation source inferred from the realpath-resolved CLI entrypoint. */
export type InstallMethod = {
    kind: "npm-global";
} | {
    kind: "pnpm-global";
} | {
    kind: "homebrew";
    formula: string | null;
} | {
    kind: "npx";
} | {
    kind: "unknown";
};
/**
 * Infer how the running tool was installed from its realpath-resolved entry and
 * the environment. Order matters: ephemeral caches and Homebrew Cellars are
 * checked before the generic global-install layouts they can contain.
 */
export declare function detectInstallMethod(options: {
    entry: string;
    env?: NodeJS.ProcessEnv;
}): InstallMethod;
/** Upgrade command selected for a detected install method. */
export interface UpgradePlan {
    method: InstallMethod["kind"];
    /** Human-readable command, used both for announcing and print-only output. */
    command: string;
    /** Spawn argv, or `null` when the upgrade must not be run automatically. */
    argv: string[] | null;
    /** Why the plan is print-only, when applicable. */
    note?: string;
}
/** Map a detected install method to the exact upgrade command for it. */
export declare function planUpgrade(method: InstallMethod, packageName: string): UpgradePlan;
/** Injection points for fetching the latest published npm version. */
export interface FetchLatestOptions {
    /** Custom fetch implementation. Pass `null` to skip HTTP and use npm only. */
    fetchImpl?: FetchLike | null;
    /** Custom `npm view` fallback. */
    npmView?: (packageName: string) => Promise<string | null>;
    /** Registry HTTP timeout in milliseconds. */
    fetchTimeoutMs?: number;
    /** Platform used when invoking npm through the fallback path. */
    platform?: NodeJS.Platform;
}
/**
 * Resolve the latest published version. Prefers the registry HTTP endpoint and
 * falls back to `npm view`. Network, registry, and not-found failures surface as
 * `AxiError` with actionable suggestions, never a raw stack trace.
 */
export declare function fetchLatestVersion(packageName: string, options?: FetchLatestOptions): Promise<string>;
/** Result returned by the install runner used by `runUpdate()`. */
export interface InstallResult {
    ok: boolean;
    message?: string;
}
/** Runtime context passed to a custom install runner. */
export interface RunInstallContext {
    platform: NodeJS.Platform;
}
/** Options for invoking the built-in self-update flow directly. */
export interface RunUpdateOptions {
    /** Args after the `update` command (e.g. `["--check"]`). */
    args: string[];
    /** Output stream used for the `running:` announcement. */
    stdout: {
        write: (chunk: string) => unknown;
    };
    /** Explicit npm package name override (escape hatch). */
    packageName?: string;
    /** Current version, normally `options.version` from `runAxiCli`. */
    version?: string;
    /** CLI entrypoint path, normally `process.argv[1]`. */
    invokedAs?: string;
    /** Environment used for install-method detection. */
    env?: NodeJS.ProcessEnv;
    /** Realpath resolver for the invoked entrypoint. */
    realpath?: (path: string) => string;
    /** Filesystem seam used to read package metadata. */
    fs?: IdentityFs;
    /** Latest-version resolver. */
    fetchLatest?: (packageName: string) => Promise<string>;
    /** Installer seam. Defaults to spawning the planned package-manager command. */
    runInstall?: (plan: UpgradePlan, stdout: {
        write: (chunk: string) => unknown;
    }, context: RunInstallContext) => Promise<InstallResult>;
    /** Platform used for package-manager command shims. */
    platform?: NodeJS.Platform;
}
/**
 * Execute the built-in `update` flow: resolve identity, query the registry,
 * compare versions, and (unless `--check`) upgrade via the detected install
 * method. Returns the renderable result; throws `AxiError` on failure.
 */
export declare function runUpdate(options: RunUpdateOptions): Promise<AxiRenderable>;
