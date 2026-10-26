#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ruleId = "squad/no-filesystem-routes";
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const configPath = path.join(scriptDirectory, "no-filesystem-routes.oxlintrc.json");
const sourceFile = /\.(?:[cm]?[jt]sx?)$/i;
const skippedDirectories = new Set([".git", "node_modules"]);
const oxlintBinary = process.platform === "win32" ? "oxlint.cmd" : "oxlint";
const directivePattern = /^(?:oxlint|eslint)-disable(?:-next-line|-line)?(?:\s+([\s\S]*))?$/;
const neutralizedDirective = /(?:oxlint|eslint)-disable/g;

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

function commentsIn(text) {
  const comments = [];
  const length = text.length;
  let index = 0;
  let line = 1;
  while (index < length) {
    const character = text[index];
    const next = text[index + 1];
    if (character === "/" && next === "/") {
      const start = index + 2;
      let end = start;
      while (end < length && text[end] !== "\n") end++;
      comments.push({ line, text: text.slice(start, end) });
      index = end;
      continue;
    }
    if (character === "/" && next === "*") {
      const startLine = line;
      let end = index + 2;
      while (end < length && !(text[end] === "*" && text[end + 1] === "/")) {
        if (text[end] === "\n") line++;
        end++;
      }
      comments.push({ line: startLine, text: text.slice(index + 2, end) });
      index = end + 2;
      continue;
    }
    if (character === '"' || character === "'") {
      index++;
      while (index < length) {
        if (text[index] === "\\") {
          index += 2;
          continue;
        }
        if (text[index] === character || text[index] === "\n") {
          index++;
          break;
        }
        index++;
      }
      continue;
    }
    if (character === "`") {
      index++;
      let depth = 0;
      while (index < length) {
        const current = text[index];
        if (current === "\\") {
          index += 2;
          continue;
        }
        if (depth === 0 && current === "`") {
          index++;
          break;
        }
        if (current === "$" && text[index + 1] === "{") {
          depth++;
          index += 2;
          continue;
        }
        if (depth > 0 && current === "}") depth--;
        if (current === "\n") line++;
        index++;
      }
      continue;
    }
    if (character === "\n") line++;
    index++;
  }
  return comments;
}

function directivesIn(text) {
  const directives = [];
  for (const comment of commentsIn(text)) {
    const match = directivePattern.exec(comment.text.trim());
    if (!match) continue;
    const targets = (match[1] ?? "")
      .split(",")
      .map((name) => name.trim().split(/\s/)[0])
      .filter(Boolean);
    directives.push({ line: comment.line, text: match[0].trim(), targets });
  }
  return directives;
}

function hidesRoutePattern(oxlint, root, file, text) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "squad-route-shadow-"));
  const extension = path.extname(file) || ".js";
  const shadow = path.join(directory, `source${extension}`);
  fs.writeFileSync(shadow, text.replace(neutralizedDirective, "squad-directive-neutralized"));
  try {
    const result = spawnSync(
      oxlint,
      ["--config", configPath, "--no-ignore", "-A", "all", "-D", ruleId, "--format", "json", shadow],
      { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
    );
    let diagnostics;
    try {
      diagnostics = JSON.parse(result.stdout).diagnostics ?? [];
    } catch {
      return result.status !== 0;
    }
    return diagnostics.some((diagnostic) => String(diagnostic.code ?? "").includes("no-filesystem-routes"));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

function suppressionViolations(root, files, oxlint) {
  const violations = [];
  for (const file of files) {
    let text;
    try {
      text = fs.readFileSync(path.resolve(root, file), "utf8");
    } catch {
      continue;
    }
    let bareHidesRoutes;
    for (const directive of directivesIn(text)) {
      if (directive.targets.includes(ruleId)) {
        violations.push(`${file}:${directive.line}: ${directive.text} names ${ruleId}`);
        continue;
      }
      if (directive.targets.length > 0) continue;
      if (bareHidesRoutes === undefined) {
        bareHidesRoutes = hidesRoutePattern(oxlint, root, file, text);
      }
      if (bareHidesRoutes) {
        violations.push(`${file}:${directive.line}: ${directive.text} (bare directive in a file with filesystem routing)`);
      }
    }
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

const oxlint = findOxlint(root);
if (!oxlint) {
  refuse(
    'oxlint is not installed; install it in this project (for example "npm install --save-dev oxlint@1.87.0") or set OXLINT_BIN',
  );
}

const suppressions = suppressionViolations(root, files, oxlint);
if (suppressions.length > 0) {
  for (const violation of suppressions) {
    process.stderr.write(`error: suppression directive for ${ruleId}: ${violation}\n`);
  }
  process.exit(1);
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
