import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { main } from "../src/cli.js";
import { PROVIDERS } from "../src/providers/index.js";
import type { ProviderAdapter, ProviderQuota } from "../src/types.js";

const originalClaudeProvider = PROVIDERS.claude;
const originalCodexProvider = PROVIDERS.codex;
const originalCursorProvider = PROVIDERS.cursor;
const originalCopilotProvider = PROVIDERS.copilot;
const originalGrokProvider = PROVIDERS.grok;
const originalKimiProvider = PROVIDERS.kimi;
const originalOpencodeProvider = PROVIDERS.opencode;
const originalXdgDataHome = process.env.XDG_DATA_HOME;
const originalXdgCacheHome = process.env.XDG_CACHE_HOME;
const originalGrokAuthJson = process.env.GROK_AUTH_JSON;
let tempDir: string | undefined;

beforeEach(() => {
  tempDir = mkdtempSync(join(tmpdir(), "sq-quota-presence-"));
  process.env.XDG_DATA_HOME = join(tempDir, "data");
  process.env.XDG_CACHE_HOME = join(tempDir, "cache");
  // Point Grok auth to a missing file so it reports "missing"
  process.env.GROK_AUTH_JSON = join(tempDir, "grok", "nonexistent.json");
  process.exitCode = undefined;
});

afterEach(() => {
  PROVIDERS.claude = originalClaudeProvider;
  PROVIDERS.codex = originalCodexProvider;
  PROVIDERS.cursor = originalCursorProvider;
  PROVIDERS.copilot = originalCopilotProvider;
  PROVIDERS.grok = originalGrokProvider;
  PROVIDERS.kimi = originalKimiProvider;
  PROVIDERS.opencode = originalOpencodeProvider;
  if (originalXdgDataHome === undefined) delete process.env.XDG_DATA_HOME;
  else process.env.XDG_DATA_HOME = originalXdgDataHome;
  if (originalXdgCacheHome === undefined) delete process.env.XDG_CACHE_HOME;
  else process.env.XDG_CACHE_HOME = originalXdgCacheHome;
  if (originalGrokAuthJson === undefined) delete process.env.GROK_AUTH_JSON;
  else process.env.GROK_AUTH_JSON = originalGrokAuthJson;
  if (tempDir) rmSync(tempDir, { recursive: true, force: true });
  tempDir = undefined;
  process.exitCode = undefined;
});

function stubProvider(
  id: ProviderQuota["provider"],
  label: string,
  inspectSources: Array<{ source: string; status: string }>,
  quota?: ProviderQuota,
): void {
  PROVIDERS[id] = {
    id,
    label,
    async fetchQuota() {
      return (
        quota ?? {
          provider: id,
          label,
          source: "api",
          windows: [],
          state: { status: "fresh", stale: false, sourcesTried: ["api"] },
        }
      );
    },
    async inspectAuth() {
      return {
        provider: id,
        sources: inspectSources,
      } as ReturnType<ProviderAdapter["inspectAuth"]>;
    },
  } as ProviderAdapter;
}

describe("presence filtering", () => {
  it("by default only shows providers with local credentials present", async () => {
    stubProvider("claude", "Claude", [
      { source: "oauth-file", status: "available" },
    ]);
    stubProvider("codex", "Codex", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("cursor", "Cursor", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("copilot", "GitHub Copilot", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("grok", "Grok", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("kimi", "Kimi", [
      { source: "pi:kimi-coding", status: "missing" },
    ]);
    stubProvider("opencode", "OpenCode", [
      { source: "auth-json", status: "missing" },
    ]);

    const output = await capture(["--json"]);
    const json = JSON.parse(output);
    const providers = json.providers.map(
      (p: { provider: string }) => p.provider,
    );
    expect(providers).toEqual(["claude"]);
    expect(providers).not.toContain("codex");
    expect(providers).not.toContain("cursor");
    expect(providers).not.toContain("grok");
    expect(providers).not.toContain("kimi");
    expect(providers).not.toContain("opencode");
  });

  it("shows expired credentials as present (not missing)", async () => {
    stubProvider("claude", "Claude", [
      { source: "oauth-file", status: "expired" },
    ]);
    stubProvider("codex", "Codex", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("cursor", "Cursor", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("copilot", "GitHub Copilot", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("grok", "Grok", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("kimi", "Kimi", [
      { source: "pi:kimi-coding", status: "missing" },
    ]);
    stubProvider("opencode", "OpenCode", [
      { source: "auth-json", status: "missing" },
    ]);

    const output = await capture(["--json"]);
    const json = JSON.parse(output);
    const providers = json.providers.map(
      (p: { provider: string }) => p.provider,
    );
    expect(providers).toContain("claude");
    expect(providers).not.toContain("codex");
  });

  it("shows providers with invalid credentials as present", async () => {
    stubProvider("claude", "Claude", [
      { source: "oauth-file", status: "missing" },
    ]);
    stubProvider("codex", "Codex", [
      { source: "auth-json", status: "invalid" },
    ]);
    stubProvider("cursor", "Cursor", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("copilot", "GitHub Copilot", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("grok", "Grok", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("kimi", "Kimi", [
      { source: "pi:kimi-coding", status: "missing" },
    ]);
    stubProvider("opencode", "OpenCode", [
      { source: "auth-json", status: "missing" },
    ]);

    const output = await capture(["--json"]);
    const json = JSON.parse(output);
    const providers = json.providers.map(
      (p: { provider: string }) => p.provider,
    );
    expect(providers).toContain("codex");
  });

  it("--all-providers shows every provider regardless of presence", async () => {
    stubProvider("claude", "Claude", [
      { source: "oauth-file", status: "available" },
    ]);
    stubProvider("codex", "Codex", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("cursor", "Cursor", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("copilot", "GitHub Copilot", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("grok", "Grok", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("kimi", "Kimi", [
      { source: "pi:kimi-coding", status: "missing" },
    ]);
    stubProvider("opencode", "OpenCode", [
      { source: "auth-json", status: "missing" },
    ]);

    const output = await capture(["--all-providers", "--json"]);
    const json = JSON.parse(output);
    const providers = json.providers.map(
      (p: { provider: string }) => p.provider,
    );
    expect(providers).toContain("claude");
    expect(providers).toContain("codex");
    expect(providers).toContain("cursor");
    expect(providers).toContain("copilot");
    expect(providers).toContain("grok");
    expect(providers).toContain("kimi");
    expect(providers).toContain("opencode");
  });

  it("--provider overrides presence filtering to show exactly what was asked", async () => {
    stubProvider("claude", "Claude", [
      { source: "oauth-file", status: "available" },
    ]);
    stubProvider("codex", "Codex", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("cursor", "Cursor", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("copilot", "GitHub Copilot", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("grok", "Grok", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("kimi", "Kimi", [
      { source: "pi:kimi-coding", status: "missing" },
    ]);
    stubProvider("opencode", "OpenCode", [
      { source: "auth-json", status: "missing" },
    ]);

    const output = await capture(["--provider", "codex,grok", "--json"]);
    const json = JSON.parse(output);
    const providers = json.providers.map(
      (p: { provider: string }) => p.provider,
    );
    expect(providers).toEqual(["codex", "grok"]);
    expect(providers).not.toContain("claude");
  });

  it("--provider and --all-providers together still show only specified providers", async () => {
    stubProvider("claude", "Claude", [
      { source: "oauth-file", status: "missing" },
    ]);
    stubProvider("codex", "Codex", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("cursor", "Cursor", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("copilot", "GitHub Copilot", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("grok", "Grok", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("kimi", "Kimi", [
      { source: "pi:kimi-coding", status: "missing" },
    ]);
    stubProvider("opencode", "OpenCode", [
      { source: "auth-json", status: "missing" },
    ]);

    const output = await capture([
      "--provider",
      "claude",
      "--all-providers",
      "--json",
    ]);
    const json = JSON.parse(output);
    const providers = json.providers.map(
      (p: { provider: string }) => p.provider,
    );
    // --provider takes precedence for the list, --all-providers bypasses presence filter
    // but the explicit list wins
    expect(providers).toEqual(["claude"]);
  });

  it("presence filtering works for TUI output", async () => {
    stubProvider("claude", "Claude", [
      { source: "oauth-file", status: "available" },
    ]);
    stubProvider("codex", "Codex", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("cursor", "Cursor", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("copilot", "GitHub Copilot", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("grok", "Grok", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("kimi", "Kimi", [
      { source: "pi:kimi-coding", status: "missing" },
    ]);
    stubProvider("opencode", "OpenCode", [
      { source: "auth-json", status: "missing" },
    ]);

    const output = await capture(["--tui", "--once"]);
    expect(output).toContain("1 live");
    expect(output).toContain("● claude");
    expect(output).not.toContain("codex");
    expect(output).not.toContain("cursor");
    expect(output).not.toContain("grok");
    expect(output).not.toContain("kimi");
    expect(output).not.toContain("opencode");
  });

  it("presence filtering works for auth command", async () => {
    stubProvider("claude", "Claude", [
      { source: "oauth-file", status: "available" },
    ]);
    stubProvider("codex", "Codex", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("cursor", "Cursor", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("copilot", "GitHub Copilot", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("grok", "Grok", [
      { source: "auth-json", status: "missing" },
    ]);
    stubProvider("kimi", "Kimi", [
      { source: "pi:kimi-coding", status: "missing" },
    ]);
    stubProvider("opencode", "OpenCode", [
      { source: "auth-json", status: "missing" },
    ]);

    const output = await capture(["auth", "--json"]);
    const json = JSON.parse(output);
    expect(json.auth).toHaveLength(1);
    expect(json.auth[0].provider).toBe("claude");
  });
});

async function capture(argv: string[]): Promise<string> {
  const chunks: string[] = [];
  await main({
    argv,
    binPath: "sq-quota",
    stdout: {
      write(chunk) {
        chunks.push(String(chunk));
        return true;
      },
    },
  });
  return chunks.join("");
}
