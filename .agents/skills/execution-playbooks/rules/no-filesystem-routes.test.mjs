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

function runImport(source) {
  const reports = [];
  const visitor = rule.create({ report: (report) => reports.push(report) });
  visitor.ImportDeclaration({ source: { value: source } });
  return reports.map(({ messageId }) => messageId);
}

function runCall(name) {
  const reports = [];
  const visitor = rule.create({ report: (report) => reports.push(report) });
  visitor.CallExpression({ callee: { type: "Identifier", name } });
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
  assert.deepEqual(runImport("@tanstack/react-router"), []);
  assert.deepEqual(runCall("createRoute"), []);
});

test("createFileRoute fails for the filesystem route pattern", () => {
  assert.deepEqual(runCall("createFileRoute"), ["fileRoute"]);
});

test("filesystem route plugin import fails for the plugin pattern", () => {
  assert.deepEqual(runImport("@tanstack/router-plugin/vite"), ["filesystemPlugin"]);
});

test("generated routeTree import fails for the generated-tree pattern", () => {
  assert.deepEqual(runImport("./routeTree.gen"), ["generatedTree"]);
  assert.deepEqual(runImport("./routeTree.gen.ts"), ["generatedTree"]);
});

test("handwritten routeTree modules pass", () => {
  assert.deepEqual(runImport("./routeTree"), []);
  assert.deepEqual(runImport("./routeTree.tsx"), []);
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
          file: "bad-filesystem-plugin.ts",
          source: 'import { tanstackRouter } from "@tanstack/router-plugin/vite";\nexport const plugin = tanstackRouter();\n',
          fails: true,
        },
        {
          file: "bad-generated-tree.ts",
          source: 'import { routeTree } from "./routeTree.gen";\nexport const tree = routeTree;\n',
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
