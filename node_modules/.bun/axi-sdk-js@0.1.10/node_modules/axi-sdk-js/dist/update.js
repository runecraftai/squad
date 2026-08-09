import { spawn } from "node:child_process";
import { execFile } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";
import { AxiError } from "./errors.js";
const execFileAsync = promisify(execFile);
const REGISTRY_BASE = "https://registry.npmjs.org";
const REGISTRY_FETCH_TIMEOUT_MS = 20_000;
/** Parse a semver string. Returns `null` when the version is not valid semver. */
export function parseSemver(version) {
    const match = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z-.]+))?(?:\+[0-9A-Za-z-.]+)?$/.exec(version.trim());
    if (!match) {
        return null;
    }
    return {
        major: Number(match[1]),
        minor: Number(match[2]),
        patch: Number(match[3]),
        prerelease: match[4] ? match[4].split(".") : [],
    };
}
function comparePrerelease(a, b) {
    // A version without prerelease identifiers is greater than one with them.
    if (a.length === 0 && b.length === 0)
        return 0;
    if (a.length === 0)
        return 1;
    if (b.length === 0)
        return -1;
    const length = Math.max(a.length, b.length);
    for (let index = 0; index < length; index += 1) {
        if (index >= a.length)
            return -1;
        if (index >= b.length)
            return 1;
        const left = a[index];
        const right = b[index];
        const leftNumeric = /^\d+$/.test(left);
        const rightNumeric = /^\d+$/.test(right);
        if (leftNumeric && rightNumeric) {
            const delta = Number(left) - Number(right);
            if (delta !== 0)
                return delta < 0 ? -1 : 1;
        }
        else if (leftNumeric) {
            return -1;
        }
        else if (rightNumeric) {
            return 1;
        }
        else if (left !== right) {
            return left < right ? -1 : 1;
        }
    }
    return 0;
}
/**
 * Compare two semver strings. Returns -1, 0, or 1. Unparseable versions fall
 * back to a deterministic lexical comparison so the caller never throws.
 */
export function compareSemver(a, b) {
    const parsedA = parseSemver(a);
    const parsedB = parseSemver(b);
    if (!parsedA || !parsedB) {
        if (a === b)
            return 0;
        return a < b ? -1 : 1;
    }
    if (parsedA.major !== parsedB.major) {
        return parsedA.major < parsedB.major ? -1 : 1;
    }
    if (parsedA.minor !== parsedB.minor) {
        return parsedA.minor < parsedB.minor ? -1 : 1;
    }
    if (parsedA.patch !== parsedB.patch) {
        return parsedA.patch < parsedB.patch ? -1 : 1;
    }
    return comparePrerelease(parsedA.prerelease, parsedB.prerelease);
}
/** True when `latest` is a strictly newer version than `current`. */
export function isUpdateAvailable(current, latest) {
    return compareSemver(latest, current) > 0;
}
const nodeFs = {
    existsSync,
    readFileSync: (path, encoding) => readFileSync(path, encoding),
};
/**
 * Walk up from `startPath` to the nearest `package.json` that declares a name,
 * returning the tool's npm package name and version. This is how a tool gains
 * `update` with zero per-tool wiring: its own published `package.json` ships
 * inside the install tree next to the running entrypoint.
 */
export function readNearestPackageJson(startPath, fs = nodeFs) {
    let dir = dirname(startPath);
    let previous = "";
    while (dir !== previous) {
        const packageJsonPath = join(dir, "package.json");
        if (fs.existsSync(packageJsonPath)) {
            try {
                const parsed = JSON.parse(fs.readFileSync(packageJsonPath, "utf-8"));
                if (typeof parsed.name === "string" && parsed.name.length > 0) {
                    return {
                        packageName: parsed.name,
                        version: typeof parsed.version === "string" ? parsed.version : undefined,
                        packageJsonPath,
                    };
                }
            }
            catch {
                // Malformed package.json: keep walking upward.
            }
        }
        previous = dir;
        dir = dirname(dir);
    }
    return {};
}
/**
 * Infer how the running tool was installed from its realpath-resolved entry and
 * the environment. Order matters: ephemeral caches and Homebrew Cellars are
 * checked before the generic global-install layouts they can contain.
 */
export function detectInstallMethod(options) {
    const env = options.env ?? process.env;
    const path = options.entry.replaceAll("\\", "/");
    // npx / ephemeral runner caches: nothing is persistently installed.
    if (path.includes("/_npx/") ||
        /\/dlx-[^/]+\//.test(path) ||
        path.includes("/pnpm/dlx/") ||
        path.includes("/bun/install/cache/")) {
        return { kind: "npx" };
    }
    const homebrewFormula = homebrewFormulaFromPath(path, env);
    if (homebrewFormula) {
        return { kind: "homebrew", formula: homebrewFormula };
    }
    const pnpmHome = normalizePathRoot(env.PNPM_HOME);
    if (isPathInsideRoot(path, pnpmHome) || isKnownPnpmGlobalStore(path, env)) {
        return { kind: "pnpm-global" };
    }
    // npm global (also covers npm-installed-under-Homebrew-node).
    if (isKnownNpmGlobalInstall(path, env)) {
        return { kind: "npm-global" };
    }
    return { kind: "unknown" };
}
function normalizePathRoot(path) {
    const normalized = path?.replaceAll("\\", "/").replace(/\/+$/, "");
    return normalized && normalized.length > 0 ? normalized : undefined;
}
function isPathInsideRoot(path, root) {
    return root !== undefined && (path === root || path.startsWith(`${root}/`));
}
function homebrewFormulaFromPath(path, env) {
    for (const root of homebrewCellarRoots(env)) {
        if (!isPathInsideRoot(path, root)) {
            continue;
        }
        const relative = path.slice(root.length).replace(/^\/+/, "");
        const formula = relative.split("/")[0];
        if (formula) {
            return formula;
        }
    }
    return null;
}
function homebrewCellarRoots(env) {
    const roots = [];
    const explicitCellar = normalizePathRoot(env.HOMEBREW_CELLAR);
    if (explicitCellar) {
        roots.push(explicitCellar);
    }
    const prefixes = [
        env.HOMEBREW_PREFIX,
        "/opt/homebrew",
        "/usr/local",
        "/home/linuxbrew/.linuxbrew",
    ];
    for (const prefix of prefixes) {
        const normalized = normalizePathRoot(prefix);
        if (normalized) {
            roots.push(`${normalized}/Cellar`);
        }
    }
    return [...new Set(roots)];
}
function isKnownPnpmGlobalStore(path, env) {
    return pnpmGlobalStoreRoots(env).some((root) => {
        if (!isPathInsideRoot(path, root)) {
            return false;
        }
        const relative = path.slice(root.length).replace(/^\/+/, "");
        return /^\d+\/\.pnpm\//.test(relative);
    });
}
function pnpmGlobalStoreRoots(env) {
    const roots = [];
    const home = normalizePathRoot(env.HOME ?? env.USERPROFILE);
    if (home) {
        roots.push(`${home}/Library/pnpm/global`);
        roots.push(`${home}/.local/share/pnpm/global`);
        roots.push(`${home}/AppData/Local/pnpm/global`);
    }
    const localAppData = normalizePathRoot(env.LOCALAPPDATA);
    if (localAppData) {
        roots.push(`${localAppData}/pnpm/global`);
    }
    return [...new Set(roots)];
}
function isKnownNpmGlobalInstall(path, env) {
    return (npmGlobalNodeModulesRoots(env).some((root) => isPathInsideRoot(path, root)) || isKnownVersionManagerNpmGlobal(path, env));
}
function npmGlobalNodeModulesRoots(env) {
    const roots = [
        "/usr/local/lib/node_modules",
        "/usr/lib/node_modules",
        "/opt/homebrew/lib/node_modules",
        "/opt/local/lib/node_modules",
    ];
    const prefixes = [env.npm_config_prefix, env.NPM_CONFIG_PREFIX];
    for (const prefix of prefixes) {
        const normalized = normalizePathRoot(prefix);
        if (normalized) {
            roots.push(`${normalized}/lib/node_modules`, `${normalized}/node_modules`);
        }
    }
    const appData = normalizePathRoot(env.APPDATA);
    if (appData) {
        roots.push(`${appData}/npm/node_modules`);
    }
    const home = normalizePathRoot(env.HOME ?? env.USERPROFILE);
    if (home) {
        roots.push(`${home}/.npm-global/lib/node_modules`, `${home}/.npm-packages/lib/node_modules`);
    }
    return [...new Set(roots)];
}
function isKnownVersionManagerNpmGlobal(path, env) {
    return versionManagerNodeRoots(env).some((root) => isPathInsideRoot(path, root) && path.includes("/lib/node_modules/"));
}
function versionManagerNodeRoots(env) {
    const roots = [];
    const home = normalizePathRoot(env.HOME ?? env.USERPROFILE);
    if (home) {
        roots.push(`${home}/.nvm/versions/node`, `${home}/.local/share/fnm/node-versions`, `${home}/.asdf/installs/nodejs`, `${home}/.nodenv/versions`, `${home}/.local/share/mise/installs/node`, `${home}/.volta/tools/image/node`);
    }
    const nvmDir = normalizePathRoot(env.NVM_DIR);
    if (nvmDir) {
        roots.push(`${nvmDir}/versions/node`);
    }
    const fnmDir = normalizePathRoot(env.FNM_DIR);
    if (fnmDir) {
        roots.push(`${fnmDir}/node-versions`);
    }
    return [...new Set(roots)];
}
/** Map a detected install method to the exact upgrade command for it. */
export function planUpgrade(method, packageName) {
    switch (method.kind) {
        case "npm-global":
            return {
                method: method.kind,
                command: `npm install -g ${packageName}@latest`,
                argv: ["npm", "install", "-g", `${packageName}@latest`],
            };
        case "pnpm-global":
            return {
                method: method.kind,
                command: `pnpm add -g ${packageName}@latest`,
                argv: ["pnpm", "add", "-g", `${packageName}@latest`],
            };
        case "homebrew":
            if (method.formula) {
                return {
                    method: method.kind,
                    command: `brew upgrade ${method.formula}`,
                    argv: ["brew", "upgrade", method.formula],
                };
            }
            return {
                method: method.kind,
                command: `brew upgrade ${packageName}`,
                argv: null,
                note: "Could not determine the Homebrew formula automatically",
            };
        case "npx":
            return {
                method: method.kind,
                command: `npx -y ${packageName}@latest`,
                argv: null,
                note: "npx always runs the latest published version, so no install is needed",
            };
        case "unknown":
            return {
                method: method.kind,
                command: `npm install -g ${packageName}@latest`,
                argv: null,
                note: "Could not determine how this tool was installed",
            };
    }
}
function packageManagerExecutable(command, platform) {
    if (platform === "win32" &&
        (command === "npm" || command === "pnpm" || command === "npx")) {
        return `${command}.cmd`;
    }
    return command;
}
function shouldUseWindowsPackageManagerShell(command, platform) {
    return (platform === "win32" &&
        (command === "npm" || command === "pnpm" || command === "npx"));
}
async function npmViewVersion(packageName, platform = process.platform) {
    try {
        const command = packageManagerExecutable("npm", platform);
        const { stdout } = await execFileAsync(command, ["view", packageName, "version"], {
            timeout: 20_000,
            shell: shouldUseWindowsPackageManagerShell("npm", platform),
        });
        const version = stdout.trim();
        return version.length > 0 ? version : null;
    }
    catch {
        return null;
    }
}
function registryPath(packageName) {
    // Scoped names encode only the slash; the registry expects a literal `@`.
    return packageName.startsWith("@")
        ? packageName.replace("/", "%2f")
        : packageName;
}
function notPublishedError(packageName) {
    return new AxiError(`${packageName} is not published to the npm registry`, "UPDATE_ERROR", [
        "Confirm the package name is correct",
        `Run \`npm view ${packageName} version\` to check manually`,
    ]);
}
class RegistryNotFoundError extends Error {
}
async function withRegistryTimeout(timeoutMs, operation) {
    const controller = new AbortController();
    let timer;
    const timeout = new Promise((_resolve, reject) => {
        timer = setTimeout(() => {
            controller.abort();
            reject(new Error(`Registry fetch timed out after ${timeoutMs}ms`));
        }, timeoutMs);
        timer.unref?.();
    });
    try {
        return await Promise.race([operation(controller.signal), timeout]);
    }
    finally {
        if (timer) {
            clearTimeout(timer);
        }
    }
}
async function fetchRegistryVersion(fetchImpl, packageName, timeoutMs) {
    return withRegistryTimeout(timeoutMs, async (signal) => {
        const response = await fetchImpl(`${REGISTRY_BASE}/${registryPath(packageName)}/latest`, { headers: { accept: "application/json" }, signal });
        if (response.ok) {
            const data = (await response.json());
            if (typeof data.version === "string" && data.version.length > 0) {
                return data.version;
            }
        }
        else if (response.status === 404) {
            throw new RegistryNotFoundError();
        }
        return null;
    });
}
/**
 * Resolve the latest published version. Prefers the registry HTTP endpoint and
 * falls back to `npm view`. Network, registry, and not-found failures surface as
 * `AxiError` with actionable suggestions, never a raw stack trace.
 */
export async function fetchLatestVersion(packageName, options = {}) {
    const fetchImpl = options.fetchImpl === undefined
        ? globalThis.fetch
        : (options.fetchImpl ?? undefined);
    let registryNotFound = false;
    if (typeof fetchImpl === "function") {
        try {
            const version = await fetchRegistryVersion(fetchImpl, packageName, options.fetchTimeoutMs ?? REGISTRY_FETCH_TIMEOUT_MS);
            if (version) {
                return version;
            }
        }
        catch (error) {
            if (error instanceof RegistryNotFoundError) {
                registryNotFound = true;
            }
            else if (error instanceof AxiError) {
                throw error;
            }
            // Network/parse failure: fall through to the npm CLI fallback.
        }
    }
    const viewed = await (options.npmView ??
        ((name) => npmViewVersion(name, options.platform)))(packageName);
    if (viewed) {
        return viewed;
    }
    if (registryNotFound) {
        throw notPublishedError(packageName);
    }
    throw new AxiError(`Could not reach the npm registry to check for updates to ${packageName}`, "UPDATE_ERROR", [
        "Check your network connection and try again",
        `Run \`npm view ${packageName} version\` to check manually`,
    ]);
}
async function defaultRunInstall(plan, stdout, context) {
    const argv = plan.argv;
    if (!argv || argv.length === 0) {
        return { ok: false, message: "No runnable upgrade command" };
    }
    stdout.write(`running: ${plan.command}\n`);
    return new Promise((resolve) => {
        const [command, ...args] = argv;
        const child = spawn(packageManagerExecutable(command, context.platform), args, {
            stdio: ["ignore", "pipe", "pipe"],
            shell: shouldUseWindowsPackageManagerShell(command, context.platform),
        });
        child.stdout?.on("data", (chunk) => {
            process.stderr.write(chunk);
        });
        child.stderr?.on("data", (chunk) => {
            process.stderr.write(chunk);
        });
        child.on("error", (error) => {
            resolve({ ok: false, message: error.message });
        });
        child.on("close", (code) => {
            resolve(code === 0
                ? { ok: true }
                : { ok: false, message: `${plan.command} exited with code ${code}` });
        });
    });
}
function binNameFromArgv(invokedAs) {
    return basename(invokedAs ?? "tool") || "tool";
}
function resolveEntry(invokedAs, realpath) {
    if (!invokedAs) {
        return undefined;
    }
    try {
        return realpath(invokedAs);
    }
    catch {
        return invokedAs;
    }
}
function resolveInstalledVersion(invokedAs, realpath, fs) {
    const installedEntry = resolveEntry(invokedAs, realpath);
    return installedEntry
        ? readNearestPackageJson(installedEntry, fs).version
        : undefined;
}
function homebrewUpgradeOutput(options) {
    const update = {
        package: options.packageName,
        previous: options.current,
        latest: options.latest,
    };
    if (options.installedVersion) {
        update.installed = options.installedVersion;
        update.available = isUpdateAvailable(options.installedVersion, options.latest);
    }
    else {
        update.action = "upgrade-command-ran";
        update.result = "installed version unknown";
    }
    return {
        update,
        command: options.command,
    };
}
function parseUpdateArgs(args, binName) {
    if (args.length === 0) {
        return "install";
    }
    if (args.length === 1 && (args[0] === "--check" || args[0] === "--dry-run")) {
        return "check";
    }
    const unknown = args.find((arg) => arg !== "--check" && arg !== "--dry-run");
    throw new AxiError(unknown ? `Unknown update option: ${unknown}` : "Invalid update arguments", "VALIDATION_ERROR", [
        `Run \`${binName} update --help\``,
        `Use \`${binName} update --check\` to check without installing`,
    ]);
}
/**
 * Execute the built-in `update` flow: resolve identity, query the registry,
 * compare versions, and (unless `--check`) upgrade via the detected install
 * method. Returns the renderable result; throws `AxiError` on failure.
 */
export async function runUpdate(options) {
    const invokedAs = options.invokedAs ?? process.argv[1];
    const binName = binNameFromArgv(invokedAs);
    const mode = parseUpdateArgs(options.args, binName);
    const platform = options.platform ?? process.platform;
    const realpath = options.realpath ?? ((path) => realpathSync(path));
    const entry = resolveEntry(invokedAs, realpath);
    const fs = options.fs ?? nodeFs;
    const fromPackageJson = entry ? readNearestPackageJson(entry, fs) : {};
    const packageName = options.packageName ?? fromPackageJson.packageName;
    const current = options.version ?? fromPackageJson.version;
    if (!packageName) {
        throw new AxiError("Could not determine the package name to update", "UPDATE_ERROR", [
            "Reinstall the tool from npm so its package.json is available",
            "Tool authors can pass `packageName` to runAxiCli()",
        ]);
    }
    if (!current) {
        throw new AxiError(`Could not determine the current version of ${packageName}`, "UPDATE_ERROR", [
            "Reinstall the tool from npm so its version is available",
            "Tool authors can pass `version` to runAxiCli()",
        ]);
    }
    const fetchLatest = options.fetchLatest ??
        ((name) => fetchLatestVersion(name, { platform }));
    const latest = await fetchLatest(packageName);
    const available = isUpdateAvailable(current, latest);
    if (mode === "check") {
        const output = {
            update: { package: packageName, current, latest, available },
        };
        if (available) {
            output.help = [`Run \`${binName} update\` to upgrade`];
        }
        return output;
    }
    if (!available) {
        return {
            update: `${packageName} is already on the latest version (${current})`,
        };
    }
    const method = entry
        ? detectInstallMethod({ entry, env: options.env })
        : { kind: "unknown" };
    const plan = planUpgrade(method, packageName);
    if (!plan.argv) {
        const help = method.kind === "npx"
            ? `Re-run with \`${plan.command}\` to use the latest version`
            : `Run \`${plan.command}\` to upgrade`;
        return {
            update: {
                package: packageName,
                current,
                latest,
                available: true,
                action: "manual",
                ...(plan.note ? { reason: plan.note } : {}),
                run: plan.command,
            },
            help: [help],
        };
    }
    const runInstall = options.runInstall ?? defaultRunInstall;
    const result = await runInstall(plan, options.stdout, { platform });
    if (!result.ok) {
        throw new AxiError(`Failed to upgrade ${packageName}`, "UPDATE_ERROR", [
            `Run \`${plan.command}\` manually`,
            ...(result.message ? [result.message] : []),
        ]);
    }
    if (method.kind === "homebrew") {
        return homebrewUpgradeOutput({
            packageName,
            current,
            latest,
            installedVersion: resolveInstalledVersion(invokedAs, realpath, fs),
            command: plan.command,
        });
    }
    return {
        update: `${packageName} upgraded ${current} -> ${latest}`,
        command: plan.command,
    };
}
