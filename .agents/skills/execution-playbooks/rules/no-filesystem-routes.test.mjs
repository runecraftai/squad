import assert from "node:assert/strict";
import test from "node:test";
import plugin from "./no-filesystem-routes.mjs";

const rule = plugin.rules["no-filesystem-routes"];

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
});
