import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { main } from "../../src/cli.js";
import {
  fetchQuota,
  inspectAuth,
} from "../../src/providers/opencode.js";
import type { SqQuotaResponse } from "../../src/types.js";

const originalOpenCodeApiKey = process.env.OPENCODE_API_KEY;
const originalZenApiKey = process.env.ZEN_API_KEY;
const originalXdgDataHome = process.env.XDG_DATA_HOME;
let tempDir: string | undefined;

beforeEach(() => {
  tempDir = mkdtempSync(join(tmpdir(), "sq-quota-opencode-"));
  delete process.env.OPENCODE_API_KEY;
  delete process.env.ZEN_API_KEY;
  process.env.XDG_DATA_HOME = join(tempDir, "data");
  process.exitCode = undefined;
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  if (originalOpenCodeApiKey === undefined)
    delete process.env.OPENCODE_API_KEY;
  else process.env.OPENCODE_API_KEY = originalOpenCodeApiKey;
  if (originalZenApiKey === undefined) delete process.env.ZEN_API_KEY;
  else process.env.ZEN_API_KEY = originalZenApiKey;
  if (originalXdgDataHome === undefined) delete process.env.XDG_DATA_HOME;
  else process.env.XDG_DATA_HOME = originalXdgDataHome;
  if (tempDir) rmSync(tempDir, { recursive: true, force: true });
  tempDir = undefined;
  process.exitCode = undefined;
});

function writeJson(file: string, value: unknown): void {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(value));
}

function writeAuthJson(value: unknown): void {
  writeJson(join(process.env.XDG_DATA_HOME!, "opencode", "auth.json"), value);
}

function writeValidAuth(key = "sk-test-opencode-key"): void {
  writeAuthJson({
    opencode: {
      type: "api_key",
      key,
    },
  });
}

function stubModelsFetch(
  status = 200,
  body: unknown = [{ id: "model-a" }, { id: "model-b" }, { id: "model-c" }],
): ReturnType<typeof vi.fn> {
  const fetchMock = vi.fn(
    async () =>
      new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json" },
      }),
  );
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

describe("OpenCode credential discovery", () => {
  it("finds credentials from OPENCODE_API_KEY env var", async () => {
    process.env.OPENCODE_API_KEY = "sk-env-key";
    const fetchMock = stubModelsFetch();

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("fresh");
    expect(result.state.authStatus).toBe("usable");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer sk-env-key",
    );
  });

  it("prefers OPENCODE_API_KEY over ZEN_API_KEY", async () => {
    process.env.OPENCODE_API_KEY = "sk-opencode";
    process.env.ZEN_API_KEY = "sk-zen";
    const fetchMock = stubModelsFetch();

    await fetchQuota({ allowKeychainPrompt: false });

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer sk-opencode",
    );
  });

  it("falls back to ZEN_API_KEY when OPENCODE_API_KEY is not set", async () => {
    process.env.ZEN_API_KEY = "sk-zen-fallback";
    const fetchMock = stubModelsFetch();

    await fetchQuota({ allowKeychainPrompt: false });

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer sk-zen-fallback",
    );
  });

  it("finds credentials from auth.json with api_key type", async () => {
    writeValidAuth("sk-auth-file-key");
    const fetchMock = stubModelsFetch();

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("fresh");
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer sk-auth-file-key",
    );
  });

  it("finds credentials from auth.json with api-key type (hyphen variant)", async () => {
    writeAuthJson({
      provider: {
        type: "api-key",
        key: "sk-hyphen-key",
      },
    });
    const fetchMock = stubModelsFetch();

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("fresh");
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer sk-hyphen-key",
    );
  });

  it("reports missing when no credentials are found", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("auth_required");
    expect(result.windows).toEqual([]);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(result.attempts).toEqual([
      {
        source: "auth-json",
        status: "skipped",
        error: "credentials_missing",
      },
    ]);
  });

  it("reports invalid when auth.json has no api_key entries", async () => {
    writeAuthJson({
      provider: {
        type: "oauth",
        token: "not-an-api-key",
      },
    });
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("auth_required");
    expect(result.state.error).toBe("OpenCode sign-in required");
    expect(fetchMock).not.toHaveBeenCalled();
    expect(result.attempts).toEqual([
      {
        source: "auth-json",
        status: "skipped",
        error: "credentials_invalid",
      },
    ]);
  });

  it("reports invalid when auth.json is malformed JSON", async () => {
    mkdirSync(join(process.env.XDG_DATA_HOME!, "opencode"), {
      recursive: true,
    });
    writeFileSync(
      join(process.env.XDG_DATA_HOME!, "opencode", "auth.json"),
      "{not-json",
    );
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("auth_required");
    expect(result.attempts).toEqual([
      {
        source: "auth-json",
        status: "skipped",
        error: "credentials_invalid",
      },
    ]);
  });
});

describe("OpenCode API validation", () => {
  it("reports auth-only success with model count on 200", async () => {
    writeValidAuth();
    stubModelsFetch(200, [
      { id: "model-a" },
      { id: "model-b" },
      { id: "model-c" },
    ]);

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result).toMatchObject({
      provider: "opencode",
      label: "OpenCode",
      source: "api",
      windows: [],
      notes: ["3 models available"],
      state: {
        status: "fresh",
        stale: false,
        authStatus: "usable",
      },
      quotaSemantics: {
        status: "unknown",
        description: expect.stringContaining("no public quota"),
        effectiveAvailability: [],
      },
    });
    expect(result.state.refreshedAt).toBeDefined();
  });

  it("handles response with data wrapper shape", async () => {
    writeValidAuth();
    stubModelsFetch(200, {
      data: [{ id: "m1" }, { id: "m2" }],
    });

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.notes).toEqual(["2 models available"]);
  });

  it("classifies 401 as auth_required", async () => {
    writeValidAuth();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("unauthorized", { status: 401 })),
    );

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("auth_required");
    expect(result.state.error).toBe("OpenCode sign-in required");
  });

  it("classifies 403 as auth_required", async () => {
    writeValidAuth();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("forbidden", { status: 403 })),
    );

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("auth_required");
  });

  it("classifies 429 as rate_limited", async () => {
    writeValidAuth();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("too many", { status: 429 })),
    );

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("rate_limited");
  });

  it("classifies 500 as error", async () => {
    writeValidAuth();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("server error", { status: 500 })),
    );

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("error");
    expect(result.state.error).toBe("OpenCode API unavailable");
  });

  it("times out after 15 seconds", async () => {
    vi.useFakeTimers();
    writeValidAuth();
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async (_url: string, init: RequestInit) =>
          new Promise<Response>((_resolve, reject) => {
            init.signal?.addEventListener("abort", () => {
              const error = new Error("aborted");
              error.name = "AbortError";
              reject(error);
            });
          }),
      ),
    );

    const pending = fetchQuota({ allowKeychainPrompt: false });
    await Promise.resolve();
    await vi.advanceTimersByTimeAsync(15_000);
    const result = await pending;

    expect(result.state.status).toBe("error");
    expect(result.state.error).toBe("OpenCode request timed out");
  });
});

describe("OpenCode inspectAuth", () => {
  it("reports available when credentials are present", async () => {
    writeValidAuth();

    const report = await inspectAuth({ allowKeychainPrompt: false });

    expect(report).toEqual({
      provider: "opencode",
      sources: [
        {
          source: "auth-json",
          path: join(process.env.XDG_DATA_HOME!, "opencode", "auth.json"),
          status: "available",
        },
      ],
    });
  });

  it("reports missing when no credentials are found", async () => {
    const report = await inspectAuth({ allowKeychainPrompt: false });

    expect(report).toEqual({
      provider: "opencode",
      sources: [
        {
          source: "auth-json",
          path: join(process.env.XDG_DATA_HOME!, "opencode", "auth.json"),
          status: "missing",
        },
      ],
    });
  });

  it("reports env source when env var is set", async () => {
    process.env.OPENCODE_API_KEY = "sk-env";

    const report = await inspectAuth({ allowKeychainPrompt: false });

    expect(report).toEqual({
      provider: "opencode",
      sources: [
        {
          source: "api-key-env",
          status: "available",
        },
      ],
    });
  });
});

describe("OpenCode CLI rendering", () => {
  it("renders OpenCode card in TUI output", async () => {
    writeValidAuth();
    stubModelsFetch(200, [{ id: "m1" }, { id: "m2" }]);

    const output = await capture(["--tui", "--once", "--provider", "opencode"]);

    expect(output).toContain("● opencode");
    expect(output).toContain("2 models available");
    expect(output).toContain("effective unknown");
  });

  it("does not fabricate a percentage for OpenCode", async () => {
    writeValidAuth();
    stubModelsFetch(200, [{ id: "m1" }]);

    const output = await capture(["--tui", "--once", "--provider", "opencode"]);

    expect(output).not.toMatch(/\d+%/);
    expect(output).toContain("effective unknown");
  });

  it("shows OpenCode in JSON output with auth-only semantics", async () => {
    writeValidAuth();
    stubModelsFetch(200, [{ id: "m1" }, { id: "m2" }, { id: "m3" }]);

    const json = JSON.parse(
      await capture(["--provider", "opencode", "--json"]),
    ) as SqQuotaResponse;

    expect(json.providers).toHaveLength(1);
    const opencode = json.providers[0];
    expect(opencode).toMatchObject({
      provider: "opencode",
      label: "OpenCode",
      source: "api",
      windows: [],
      notes: ["3 models available"],
      state: {
        status: "fresh",
        authStatus: "usable",
      },
      quotaSemantics: {
        status: "unknown",
        effectiveAvailability: [],
      },
    });
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
