import * as fs from "node:fs";
import * as path from "node:path";

/** Resolve and validate one executable without retaining a mutable PATH lookup. */
export function canonicalExecutable(candidate: string, label: string): string {
	if (!path.isAbsolute(candidate)) throw new Error(`${label} executable path must be absolute`);
	const canonical = fs.realpathSync(candidate);
	const stat = fs.statSync(canonical);
	if (!stat.isFile()) throw new Error(`${label} executable must resolve to a regular file`);
	fs.accessSync(canonical, fs.constants.X_OK);
	return canonical;
}

/** Resolve an executable only from the PATH captured by its caller at extension startup. */
export function resolveTrustedExecutableFromStartupPath(
	name: string,
	injected: string | undefined,
	startupPath: string,
): string {
	if (injected) return canonicalExecutable(injected, name);
	for (const directory of startupPath.split(path.delimiter)) {
		if (!path.isAbsolute(directory)) continue;
		const candidate = path.join(directory, name);
		try {
			return canonicalExecutable(candidate, name);
		} catch {
			/* continue through the trusted extension startup PATH */
		}
	}
	throw new Error(`Unable to resolve an accessible ${name} executable from the trusted extension startup PATH.`);
}
