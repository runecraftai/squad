import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import plugin from "./no-filesystem-routes.mjs";

const rule = plugin.rules["no-filesystem-routes"];
const rulePath = fileURLToPath(new URL("./no-filesystem-routes.mjs", import.meta.url));
const routerPackage = "@tanstack/react-router";

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
  let dir = path.dirname(rulePath);
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

const oxlint = findOxlint();

test(
  "oxlint fails the build for filesystem routing and passes the code-based tree",
  { skip: oxlint ? false : "oxlint is not installed" },
  () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "squad-route-rule-"));
    try {
      fs.copyFileSync(rulePath, path.join(dir, "no-filesystem-routes.mjs"));
      fs.writeFileSync(
        path.join(dir, ".oxlintrc.json"),
        `${JSON.stringify(
          {
            jsPlugins: ["./no-filesystem-routes.mjs"],
            rules: { "squad/no-filesystem-routes": "error" },
          },
          null,
          2,
        )}\n`,
      );
      const fixtures = [
        {
          file: "bad-create-file-route.tsx",
          source: 'import { createFileRoute } from "@tanstack/react-router";\nexport const Route = createFileRoute("/bad")({ component: () => null });\n',
          fails: true,
        },
        {
          file: "bad-aliased-create-file-route.tsx",
          source: 'import { createFileRoute as cfr } from "@tanstack/react-router";\nexport const Route = cfr("/bad")({ component: () => null });\n',
          fails: true,
        },
        {
          file: "bad-member-create-file-route.ts",
          source: 'import * as router from "@tanstack/react-router";\nexport const Route = router.createFileRoute("/bad", { component: () => null });\n',
          fails: true,
        },
        {
          file: "bad-required-create-file-route.cjs",
          source: 'const { createFileRoute: cfr } = require("@tanstack/react-router");\nmodule.exports = cfr("/bad", { component: () => null });\n',
          fails: true,
        },
        {
          file: "bad-filesystem-plugin.ts",
          source: 'import { tanstackRouter } from "@tanstack/router-plugin/vite";\nexport const plugin = tanstackRouter();\n',
          fails: true,
        },
        {
          file: "bad-router-generator.ts",
          source: 'export { generate } from "@tanstack/router-generator";\n',
          fails: true,
        },
        {
          file: "bad-generated-tree.ts",
          source: 'import { routeTree } from "./routeTree.gen";\nexport const tree = routeTree;\n',
          fails: true,
        },
        {
          file: "bad-required-generated-tree.cjs",
          source: 'const { routeTree } = require("./routeTree.gen");\nmodule.exports = routeTree;\n',
          fails: true,
        },
        {
          file: "bad-dynamic-generated-tree.ts",
          source: 'export async function loadTree() {\n  const { routeTree } = await import("./routeTree.gen");\n  return routeTree;\n}\n',
          fails: true,
        },
        {
          file: "bad-reexported-generated-tree.ts",
          source: 'export * from "./routeTree.gen";\n',
          fails: true,
        },
        {
          file: "good-handwritten-tree.ts",
          source: 'import { routeTree } from "./routeTree";\nexport const tree = routeTree;\n',
          fails: false,
        },
        {
          file: "good-code-route.tsx",
          source: 'import { createRootRoute, createRoute } from "@tanstack/react-router";\nconst rootRoute = createRootRoute();\nexport const Route = createRoute({ getParentRoute: () => rootRoute, path: "/good" });\n',
          fails: false,
        },
      ];
      for (const { file, source, fails } of fixtures) {
        fs.writeFileSync(path.join(dir, file), source);
        const result = spawnSync(oxlint, [file], { cwd: dir, encoding: "utf8" });
        const output = `${result.stdout}${result.stderr}`;
        if (fails) {
          assert.notEqual(result.status, 0, `${file} should fail the lint, got:\n${output}`);
          assert.match(output, /no-filesystem-routes/, `${file} did not report the rule:\n${output}`);
        } else {
          assert.equal(result.status, 0, `${file} should pass the lint, got:\n${output}`);
        }
      }
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  },
);
