import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import plugin from "./no-filesystem-routes.mjs";

const rule = plugin.rules["no-filesystem-routes"];
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const routerPackage = "@tanstack/react-router";
const verifierFiles = ["no-filesystem-routes.mjs", "no-filesystem-routes.oxlintrc.json", "verify-no-filesystem-routes.mjs"];
const badCreateFileRoute =
  'import { createFileRoute } from "@tanstack/react-router";\nexport const Route = createFileRoute("/bad")({ component: () => null });\n';
const goodCodeRoute =
  'import { createRootRoute, createRoute } from "@tanstack/react-router";\nconst rootRoute = createRootRoute();\nexport const Route = createRoute({ getParentRoute: () => rootRoute, path: "/good" });\n';

const identifier = (name) => ({ type: "Identifier", name });
const literal = (value) => ({ type: "Literal", value });
const member = (object, property, computed = false) => ({
  type: "MemberExpression",
  object,
  property: computed ? literal(property) : identifier(property),
  computed,
});
const importSpecifier = (name, local = name) => ({
  type: "ImportSpecifier",
  imported: identifier(name),
  local: identifier(local),
});
const importDeclaration = (source, specifiers = []) => ({
  type: "ImportDeclaration",
  source: literal(source),
  specifiers,
});
const callExpression = (callee, args = []) => ({ type: "CallExpression", callee, arguments: args });
const requireCall = (source) => callExpression(identifier("require"), [literal(source)]);
const dynamicImport = (source) => ({ type: "ImportExpression", source: literal(source) });
const destructuredRequire = (source, imported, local) => {
  const node = requireCall(source);
  node.parent = {
    type: "VariableDeclarator",
    id: {
      type: "ObjectPattern",
      properties: [{ type: "Property", key: identifier(imported), value: identifier(local), computed: false }],
    },
    init: node,
  };
  return node;
};

function lint(nodes) {
  const reports = [];
  const visitor = rule.create({ report: (report) => reports.push(report) });
  for (const node of nodes) visitor[node.type]?.(node);
  return reports.map(({ messageId }) => messageId);
}

function findOxlint() {
  if (process.env.OXLINT_BIN) return process.env.OXLINT_BIN;
  const names = ["oxlint", "oxlint.exe", "oxlint.cmd"];
  let dir = scriptDirectory;
  while (true) {
    for (const name of names) {
      const candidate = path.join(dir, "node_modules", ".bin", name);
      if (fs.existsSync(candidate)) return candidate;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  for (const entry of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!entry) continue;
    for (const name of names) {
      const candidate = path.join(entry, name);
      if (fs.existsSync(candidate)) return candidate;
    }
  }
  return null;
}

const oxlint = findOxlint();

function requireOxlint() {
  assert.ok(
    oxlint,
    "oxlint is required for the filesystem-route proof; run bin/sq-install-oxlint.sh <directory> and set OXLINT_BIN",
  );
  return oxlint;
}

function makeProject() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "squad-route-project-"));
  fs.mkdirSync(path.join(dir, "tools", "oxlint"), { recursive: true });
  fs.mkdirSync(path.join(dir, "src", "app", "routes"), { recursive: true });
  for (const file of verifierFiles) {
    fs.copyFileSync(path.join(scriptDirectory, file), path.join(dir, "tools", "oxlint", file));
  }
  spawnSync("git", ["init", "-q", dir], { encoding: "utf8" });
  return dir;
}

function runVerifier(dir, env = {}) {
  return spawnSync(process.execPath, ["tools/oxlint/verify-no-filesystem-routes.mjs"], {
    cwd: dir,
    encoding: "utf8",
    env: { ...process.env, OXLINT_BIN: requireOxlint(), ...env },
  });
}

function routeFile(dir, name = "index.tsx") {
  return path.join(dir, "src", "app", "routes", name);
}

function output(result) {
  return `${result.stdout}${result.stderr}`;
}

test("code-based route tree passes", () => {
  assert.deepEqual(lint([importDeclaration(routerPackage, [importSpecifier("createRootRoute"), importSpecifier("createRoute")])]), []);
  assert.deepEqual(lint([callExpression(identifier("createRoute"))]), []);
  assert.deepEqual(lint([callExpression(identifier("createRootRoute"))]), []);
});

test("createFileRoute fails for the filesystem route pattern", () => {
  assert.deepEqual(lint([callExpression(identifier("createFileRoute"))]), ["fileRoute"]);
});

test("an aliased createFileRoute import fails instead of bypassing the rule", () => {
  assert.deepEqual(
    lint([importDeclaration(routerPackage, [importSpecifier("createFileRoute", "cfr")]), callExpression(identifier("cfr"))]),
    ["fileRoute"],
  );
  assert.deepEqual(
    lint([importDeclaration(routerPackage, [importSpecifier("createFileRoute", "makeFileRoute")]), callExpression(identifier("makeFileRoute"))]),
    ["fileRoute"],
  );
});

test("member access to createFileRoute fails instead of bypassing the rule", () => {
  assert.deepEqual(lint([callExpression(member(identifier("router"), "createFileRoute"))]), ["fileRoute"]);
  assert.deepEqual(lint([callExpression(member(identifier("router"), "createFileRoute", true))]), ["fileRoute"]);
});

test("a destructured require alias for createFileRoute fails", () => {
  assert.deepEqual(
    lint([destructuredRequire(routerPackage, "createFileRoute", "cfr"), callExpression(identifier("cfr"))]),
    ["fileRoute"],
  );
});

test("filesystem route plugin imports fail for the plugin pattern", () => {
  assert.deepEqual(lint([importDeclaration("@tanstack/router-plugin/vite")]), ["filesystemPlugin"]);
  assert.deepEqual(lint([importDeclaration("@tanstack/router-vite-plugin")]), ["filesystemPlugin"]);
  assert.deepEqual(lint([importDeclaration("@tanstack/router-generator")]), ["filesystemPlugin"]);
  assert.deepEqual(lint([importDeclaration("@tanstack/router-cli")]), ["filesystemPlugin"]);
});

test("generated routeTree imports fail for the generated-tree pattern", () => {
  assert.deepEqual(lint([importDeclaration("./routeTree.gen")]), ["generatedTree"]);
  assert.deepEqual(lint([importDeclaration("./routeTree.gen.ts")]), ["generatedTree"]);
  assert.deepEqual(lint([importDeclaration("./routeTree.gen?raw")]), ["generatedTree"]);
  assert.deepEqual(lint([dynamicImport("./routeTree.gen")]), ["generatedTree"]);
  assert.deepEqual(lint([callExpression({ type: "Import" }, [literal("./routeTree.gen")])]), ["generatedTree"]);
  assert.deepEqual(lint([requireCall("./routeTree.gen")]), ["generatedTree"]);
  assert.deepEqual(lint([{ type: "ExportAllDeclaration", source: literal("./routeTree.gen"), exported: null }]), ["generatedTree"]);
  assert.deepEqual(lint([{ type: "ExportNamedDeclaration", source: literal("./routeTree.gen"), specifiers: [] }]), [
    "generatedTree",
  ]);
});

test("handwritten routeTree modules pass", () => {
  assert.deepEqual(lint([importDeclaration("./routeTree")]), []);
  assert.deepEqual(lint([importDeclaration("./routeTree.tsx")]), []);
  assert.deepEqual(lint([requireCall("./routeTree")]), []);
});

test("the verification command fails on a project's own filesystem-routing source and passes its code-based source", () => {
  const dir = makeProject();
  try {
    fs.writeFileSync(routeFile(dir), badCreateFileRoute);
    const failed = runVerifier(dir);
    assert.notEqual(failed.status, 0, `a project file using createFileRoute must fail the command:\n${output(failed)}`);
    assert.match(output(failed), /no-filesystem-routes/, `the failure must name the rule:\n${output(failed)}`);

    fs.writeFileSync(routeFile(dir), goodCodeRoute);
    const passed = runVerifier(dir);
    assert.equal(passed.status, 0, `a code-based project file must pass the command:\n${output(passed)}`);
    assert.match(passed.stdout, /no-filesystem-routes: checked \d+ source files; no filesystem routing found/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("the verification command catches every banned pattern and an uncommitted route file", () => {
  const dir = makeProject();
  try {
    fs.writeFileSync(routeFile(dir), goodCodeRoute);
    spawnSync("git", ["-C", dir, "add", "src/app/routes/index.tsx"], { encoding: "utf8" });
    assert.equal(runVerifier(dir).status, 0, "a committed code-based route tree must pass before the new file exists");

    const violations = {
      "aliased createFileRoute":
        'import { createFileRoute as cfr } from "@tanstack/react-router";\nexport const Route = cfr("/bad")({ component: () => null });\n',
      "filesystem route plugin":
        'import { tanstackRouter } from "@tanstack/router-plugin/vite";\nexport const plugin = tanstackRouter();\n',
      "generated routeTree import": 'import { routeTree } from "./routeTree.gen";\nexport const tree = routeTree;\n',
      "generated routeTree require": 'const { routeTree } = require("./routeTree.gen");\nmodule.exports = routeTree;\n',
      "generated routeTree dynamic import":
        'export async function loadTree() {\n  const { routeTree } = await import("./routeTree.gen");\n  return routeTree;\n}\n',
    };
    for (const [label, source] of Object.entries(violations)) {
      const file = routeFile(dir, "uncommitted.tsx");
      fs.writeFileSync(file, source);
      const result = runVerifier(dir);
      fs.rmSync(file);
      assert.notEqual(result.status, 0, `${label} in an uncommitted project file must fail the command:\n${output(result)}`);
      assert.match(output(result), /no-filesystem-routes/, `${label} must be reported by the rule:\n${output(result)}`);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("the verification command fails closed when oxlint is unavailable", () => {
  const dir = makeProject();
  try {
    fs.writeFileSync(routeFile(dir), goodCodeRoute);
    const result = spawnSync(process.execPath, ["tools/oxlint/verify-no-filesystem-routes.mjs"], {
      cwd: dir,
      encoding: "utf8",
      env: { ...process.env, OXLINT_BIN: path.join(dir, "missing-oxlint"), PATH: "" },
    });
    assert.notEqual(result.status, 0, "a project without oxlint must not report a green route check");
    assert.match(output(result), /oxlint/, `the refusal must name oxlint:\n${output(result)}`);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
