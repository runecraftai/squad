#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ruleId = "squad/no-filesystem-routes";
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const configPath = path.join(scriptDirectory, "no-filesystem-routes.oxlintrc.json");
const sourceFile = /\.(?:[cm]?[jt]sx?)$/i;
const skippedDirectories = new Set([".git", "node_modules"]);
const oxlintBinary = process.platform === "win32" ? "oxlint.cmd" : "oxlint";
const suppressionDirective = /(?:oxlint|eslint)-disable(?:-next-line|-line)?(?:\s+([^*/]*))?/;

function refuse(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

function git(directory, args) {
  return spawnSync("git", ["-C", directory, ...args], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
}

function projectRoot() {
  const result = git(process.cwd(), ["rev-parse", "--show-toplevel"]);
  if (result.status === 0 && result.stdout.trim()) return result.stdout.trim();
  return process.cwd();
}

function trackedSourceFiles(root) {
  const result = git(root, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]);
  if (result.status !== 0) return null;
  return result.stdout.split("\0").filter(Boolean);
}

function walkSourceFiles(directory, root, found) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      if (!skippedDirectories.has(entry.name)) walkSourceFiles(full, root, found);
    } else if (entry.isFile()) {
      found.push(path.relative(root, full));
    }
  }
}

function projectSourceFiles(root) {
  const listed = trackedSourceFiles(root);
  if (listed) return listed;
  const found = [];
  walkSourceFiles(root, root, found);
  return found;
}

function findOxlint(root) {
  if (process.env.OXLINT_BIN) return process.env.OXLINT_BIN;
  const local = path.join(root, "node_modules", ".bin", oxlintBinary);
  if (fs.existsSync(local)) return local;
  for (const directory of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!directory) continue;
    const candidate = path.join(directory, oxlintBinary);
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function suppressionIn(line) {
  const match = suppressionDirective.exec(line);
  if (!match) return null;
  const targets = (match[1] ?? "")
    .split(",")
    .map((name) => name.trim())
    .filter(Boolean);
  if (targets.length > 0 && !targets.includes(ruleId)) return null;
  return match[0].trim();
}

function suppressionViolations(root, files) {
  const violations = [];
  for (const file of files) {
    let text;
    try {
      text = fs.readFileSync(path.resolve(root, file), "utf8");
    } catch {
      continue;
    }
    text.split(/\r?\n/).forEach((line, index) => {
      const directive = suppressionIn(line);
      if (directive) violations.push(`${file}:${index + 1}: ${directive}`);
    });
  }
  return violations;
}

function ownedByToolDirectory(root, file) {
  const absolute = path.resolve(root, file);
  return absolute === scriptDirectory || absolute.startsWith(`${scriptDirectory}${path.sep}`);
}

const root = projectRoot();
if (!fs.existsSync(configPath)) refuse(`missing rule config: ${configPath}`);

const requested = process.argv.slice(2);
let files;
if (requested.length > 0) {
  for (const file of requested) {
    if (!fs.existsSync(path.resolve(process.cwd(), file))) refuse(`no such source file: ${file}`);
  }
  files = requested.map((file) => path.resolve(process.cwd(), file));
} else {
  files = projectSourceFiles(root).filter(
    (file) => sourceFile.test(file) && fs.existsSync(path.resolve(root, file)),
  );
}
if (files.length === 0) refuse(`no source files found under ${root}`);
files = files.filter((file) => !ownedByToolDirectory(root, file));
if (files.length === 0) refuse(`no project source files found under ${root}`);

const suppressions = suppressionViolations(root, files);
if (suppressions.length > 0) {
  for (const violation of suppressions) {
    process.stderr.write(`error: suppression directive for ${ruleId}: ${violation}\n`);
  }
  process.exit(1);
}

const oxlint = findOxlint(root);
if (!oxlint) {
  refuse(
    'oxlint is not installed; install it in this project (for example "npm install --save-dev oxlint@1.87.0") or set OXLINT_BIN',
  );
}

const result = spawnSync(oxlint, ["--config", configPath, "--no-ignore", "-A", "all", "-D", ruleId, ...files], {
  cwd: root,
  stdio: "inherit",
});
if (result.error) refuse(`could not run oxlint at ${oxlint}: ${result.error.message}`);
if (result.status !== 0) process.exit(result.status ?? 1);
process.stdout.write(
  `no-filesystem-routes: checked ${files.length} source files; no filesystem routing found\n`,
);
