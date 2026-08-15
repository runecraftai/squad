import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import * as parse5 from "parse5";

import { createDesignOutput, DESIGN_SYSTEM_HINT, LAYOUT_SAFETY_CSS_SNIPPET } from "../src/design-reference.js";
import { buildSelfContainedHtml } from "../src/export-bundle.js";
import { INPUT_DECISION_FORM_SNIPPET } from "../src/playbooks.js";
import { analyzeSelfPaint } from "../src/self-paint.js";
import {
  buildTemplate,
  createNewOutput,
  createTemplatesListOutput,
  TEMPLATE_KINDS,
  TOKEN_KITS,
} from "../src/templates.js";

const BIN = fileURLToPath(new URL("../bin/sq-report.js", import.meta.url));
const ALL_KINDS = TEMPLATE_KINDS.map((kind) => kind.id);
const ALL_KITS = TOKEN_KITS.map((kit) => kit.id);

/** @param {unknown} node @returns {Array<{ nodeName: string }>} */
function childrenOf(node) {
  const children = /** @type {{ childNodes?: Array<{ nodeName: string }> } | null} */ (node)?.childNodes;
  return Array.isArray(children) ? children : [];
}

function spawnNew(args, cwd) {
  return spawnSync(process.execPath, [BIN, "new", ...args], {
    cwd,
    encoding: "utf8",
    env: { ...process.env, SQ_REPORT_STATE_DIR: path.join(cwd, "state"), SQ_REPORT_TELEMETRY: "0" },
  });
}

test("every kind renders with every token kit and paints its own page", () => {
  for (const kind of ALL_KINDS) {
    for (const tokens of ALL_KITS) {
      const html = buildTemplate({ kind, tokens });
      const paint = analyzeSelfPaint(html);
      assert.equal(
        paint.painted,
        true,
        `${kind}/${tokens} must pass the self-paint check (got signal ${paint.signal})`,
      );
    }
  }
});

test("every template is a parseable standalone document with the layout-safety CSS", () => {
  for (const kind of ALL_KINDS) {
    for (const tokens of ALL_KITS) {
      const html = buildTemplate({ kind, tokens });
      assert.ok(html.includes(LAYOUT_SAFETY_CSS_SNIPPET), `${kind}/${tokens} embeds the layout-safety snippet`);
      assert.doesNotMatch(html, /undefined/, `${kind}/${tokens} renders no unfilled placeholder values`);
      const document = parse5.parse(html);
      const htmlNode = document.childNodes.find((node) => node.nodeName === "html");
      assert.ok(htmlNode, `${kind}/${tokens} parses with an html root`);
      const body = childrenOf(htmlNode).find((node) => node.nodeName === "body");
      assert.ok(body, `${kind}/${tokens} parses with a body`);
    }
  }
});

test("decision templates embed the input-playbook queuePrompt form verbatim", () => {
  for (const tokens of ALL_KITS) {
    const html = buildTemplate({ kind: "decision", tokens });
    assert.ok(html.includes(INPUT_DECISION_FORM_SNIPPET), `${tokens} embeds the shared decision form`);
    assert.match(html, /window\.lavish\.queuePrompt/, `${tokens} wires queuePrompt`);
    assert.match(html, /data-lavish-question/, `${tokens} marks the question scope`);
  }
});

test("code templates embed the shared @pierre/diffs snippet and diagram templates the Mermaid init", () => {
  const code = buildTemplate({ kind: "code", tokens: "daisyui" });
  assert.match(code, /https:\/\/esm\.sh\/@pierre\/diffs/, "code template renders through @pierre/diffs");
  const diagram = buildTemplate({ kind: "diagram", tokens: "daisyui" });
  assert.match(diagram, /class="mermaid"/, "diagram template has a .mermaid container");
  assert.match(diagram, /import mermaid from/, "diagram template wires the Mermaid init");
});

test("createNewOutput reports the written starter and a concrete next step", () => {
  const output = createNewOutput({ kind: "base", tokens: "daisyui", file: "/tmp/x.html", html: "<html></html>" });

  assert.equal(output.template.kind, "base");
  assert.equal(output.template.tokens, "daisyui");
  assert.equal(output.template.token_kit, "DaisyUI luxury (default)");
  assert.ok(output.next_step.includes("sq-report /tmp/x.html"));
});

test("the no-arg list output names every kind and token kit with the default flagged", () => {
  const output = createTemplatesListOutput();

  assert.deepEqual(
    output.template_kinds.map((kind) => kind.id),
    ALL_KINDS,
  );
  assert.deepEqual(
    output.token_kits.map((kit) => kit.id),
    ALL_KITS,
  );
  assert.equal(output.token_kits.find((kit) => kit.id === "daisyui")?.default, true);
  assert.equal(output.token_kits.find((kit) => kit.id === "sq-report")?.default, undefined);
});

test("design output and hint point agents at the starter scaffold (single-sourced discovery)", () => {
  const output = createDesignOutput();

  assert.deepEqual(
    output.templates.kinds.map((kind) => kind.id),
    ALL_KINDS,
  );
  assert.deepEqual(
    output.templates.token_kits.map((kit) => kit.id),
    ALL_KITS,
  );
  assert.match(output.templates.instruction, /sq-report new <kind>/);
  assert.match(DESIGN_SYSTEM_HINT, /sq-report new/);
});

test("a generated artifact survives export inlining with the queuePrompt wiring intact", async () => {
  for (const tokens of ALL_KITS) {
    const html = buildTemplate({ kind: "decision", tokens });
    const { html: exported, warnings } = await buildSelfContainedHtml(html, {
      baseDir: "/art",
      readLocalFile: async () => {
        throw Object.assign(new Error(`unexpected local asset read for ${tokens}`), { code: "ENOENT" });
      },
    });

    assert.equal(warnings.length, 0, `${tokens} export resolves every reference`);
    assert.ok(exported.includes(INPUT_DECISION_FORM_SNIPPET), `${tokens} export keeps the queuePrompt form`);
    assert.match(exported, /<!doctype html/i);
  }
});

test("the sq-report brand kit exports fully standalone with no external references", async () => {
  const html = buildTemplate({ kind: "plan", tokens: "sq-report" });
  const { html: exported, warnings } = await buildSelfContainedHtml(html, {
    baseDir: "/art",
    readLocalFile: async () => {
      throw Object.assign(new Error("unexpected local asset read"), { code: "ENOENT" });
    },
  });

  assert.equal(warnings.length, 0);
  assert.doesNotMatch(exported, /https?:\/\//, "no network references survive");
  assert.doesNotMatch(exported, /<link\b/, "no stylesheet links survive");
  assert.doesNotMatch(exported, /<script\b[^>]*\bsrc\s*=/, "no external scripts survive");
});

test("sq-report new writes a painted, queuePrompt-wired starter file", async () => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), "sq-report-new-cli-"));
  try {
    const result = spawnNew(
      ["decision", "--tokens", "sq-report", "--out", path.join(cwd, "out", "decision.html")],
      cwd,
    );
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /kind: decision/);

    const html = await readFile(path.join(cwd, "out", "decision.html"), "utf8");
    assert.equal(analyzeSelfPaint(html).painted, true);
    assert.ok(html.includes(INPUT_DECISION_FORM_SNIPPET));
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
});

test("sq-report new defaults to .sq-report/<kind>.html in the working directory", async () => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), "sq-report-new-cli-"));
  try {
    const result = spawnNew(["base"], cwd);
    assert.equal(result.status, 0, result.stderr || result.stdout);
    const html = await readFile(path.join(cwd, ".sq-report", "base.html"), "utf8");
    assert.ok(html.includes("<!DOCTYPE html>"));
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
});

test("sq-report new refuses to overwrite an existing file", async () => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), "sq-report-new-cli-"));
  try {
    const target = path.join(cwd, "base.html");
    const first = spawnNew(["base", "--out", target], cwd);
    assert.equal(first.status, 0, first.stderr || first.stdout);

    const second = spawnNew(["base", "--out", target], cwd);
    assert.notEqual(second.status, 0);
    assert.match(second.stdout, /already exists/);
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
});

test("sq-report new rejects unknown kinds and token kits and lists them on no args", async () => {
  const cwd = await mkdtemp(path.join(os.tmpdir(), "sq-report-new-cli-"));
  try {
    const unknownKind = spawnNew(["nope"], cwd);
    assert.notEqual(unknownKind.status, 0);
    assert.match(unknownKind.stdout, /Unknown template kind: nope/);
    assert.match(unknownKind.stdout, /base, decision/);

    const unknownKit = spawnNew(["base", "--tokens", "nope"], cwd);
    assert.notEqual(unknownKit.status, 0);
    assert.match(unknownKit.stdout, /Unknown token kit: nope/);

    const list = spawnNew([], cwd);
    assert.equal(list.status, 0, list.stderr || list.stdout);
    assert.match(list.stdout, /template_kinds\[8\]/);
    assert.match(list.stdout, /token_kits\[3\]/);
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
});
