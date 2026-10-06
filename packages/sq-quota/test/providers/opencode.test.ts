import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { main } from "../../src/cli.js";
import { fetchQuota, inspectAuth } from "../../src/providers/opencode.js";
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
  if (originalOpenCodeApiKey === undefined) delete process.env.OPENCODE_API_KEY;
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

describe("OpenCode Go credential discovery", () => {
  function writeGoAuth(
    key = "sk-go-key",
    extra: Record<string, unknown> = {},
  ): void {
    writeAuthJson({
      opencode: { type: "api_key", key: "sk-zen-key" },
      "opencode-go": { type: "api", key },
      ...extra,
    });
  }

  function stubGoUsageFetch(
    status = 200,
    body: unknown = {
      usage: {
        rolling: {
          status: "ok",
          percent: 9,
          resetsAt: "2026-10-06T03:36:51.000Z",
        },
        weekly: {
          status: "ok",
          percent: 6,
          resetsAt: "2026-10-12T00:00:00.000Z",
        },
        monthly: {
          status: "ok",
          percent: 3,
          resetsAt: "2026-11-05T13:35:10.000Z",
        },
      },
    },
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

  it("prefers the opencode-go entry over the generic opencode entry", async () => {
    writeGoAuth("sk-go-preferred");
    const fetchMock = stubGoUsageFetch();

    await fetchQuota({ allowKeychainPrompt: false });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://opencode.ai/zen/go/v1/usage");
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer sk-go-preferred",
    );
  });

  it("falls back to the generic opencode entry when no opencode-go entry exists", async () => {
    writeAuthJson({ opencode: { type: "api", key: "sk-generic-api-type" } });
    const fetchMock = stubModelsFetch();

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("fresh");
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://opencode.ai/zen/v1/models");
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer sk-generic-api-type",
    );
  });

  it('accepts type: "api" for the generic opencode entry (pre-existing bug fix)', async () => {
    writeAuthJson({ opencode: { type: "api", key: "sk-api-type" } });
    const fetchMock = stubModelsFetch();

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("fresh");
    expect(result.state.authStatus).toBe("usable");
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer sk-api-type",
    );
  });

  it("falls back to the generic entry when the opencode-go entry has no usable key", async () => {
    writeAuthJson({
      opencode: { type: "api_key", key: "sk-fallback" },
      "opencode-go": { type: "oauth", token: "not-an-api-key" },
    });
    const fetchMock = stubModelsFetch();

    await fetchQuota({ allowKeychainPrompt: false });

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect((init.headers as Record<string, string>).Authorization).toBe(
      "Bearer sk-fallback",
    );
  });
});

describe("OpenCode Go window mapping", () => {
  function writeGoAuth(key = "sk-go-key"): void {
    writeAuthJson({ "opencode-go": { type: "api", key } });
  }

  it("maps rolling/weekly/monthly to session/weekly/monthly windows", async () => {
    writeGoAuth();
    const fetchMock = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            usage: {
              rolling: {
                status: "ok",
                percent: 9,
                resetsAt: "2026-10-06T03:36:51.000Z",
              },
              weekly: {
                status: "ok",
                percent: 6,
                resetsAt: "2026-10-12T00:00:00.000Z",
              },
              monthly: {
                status: "ok",
                percent: 3,
                resetsAt: "2026-11-05T13:35:10.000Z",
              },
            },
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
    );
    vi.stubGlobal("fetch", fetchMock);

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.status).toBe("fresh");
    expect(result.windows).toHaveLength(3);
    expect(result.windows).toEqual([
      expect.objectContaining({
        kind: "session",
        percentUsed: 9,
        percentRemaining: 91,
        resetsAt: "2026-10-06T03:36:51.000Z",
      }),
      expect.objectContaining({
        kind: "weekly",
        percentUsed: 6,
        percentRemaining: 94,
        resetsAt: "2026-10-12T00:00:00.000Z",
      }),
      expect.objectContaining({
        kind: "monthly",
        percentUsed: 3,
        percentRemaining: 97,
        resetsAt: "2026-11-05T13:35:10.000Z",
      }),
    ]);
    expect(result.quotaSemantics).toMatchObject({ status: "partial" });
    expect(result.windows.every((window) => window.pace === undefined)).toBe(
      true,
    );
    expect(result.quotaSemantics?.effectiveAvailability).toEqual([]);
    for (const window of result.windows) {
      expect(window.label.toLowerCase()).toContain("account-level");
    }
    expect(result.notes?.join(" ")).toContain("account-level");
  });
});

describe("OpenCode Go not-subscribed handling", () => {
  function writeGoAuth(key = "sk-go-key"): void {
    writeAuthJson({ "opencode-go": { type: "api", key } });
  }

  it("reports a distinct not-subscribed error on a 403 EntitlementError body", async () => {
    writeGoAuth();
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              type: "error",
              error: { type: "EntitlementError" },
            }),
            { status: 403, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.windows).toEqual([]);
    expect(result.state.error).toContain("not subscribed");
    expect(result.state.error).not.toBe("OpenCode API unavailable");
    expect(result.attempts).toEqual([
      {
        source: "go-usage",
        status: "failed",
        error: expect.stringContaining("not subscribed"),
      },
    ]);
  });

  it("treats a plain 403 without an EntitlementError body as sign-in required", async () => {
    writeGoAuth();
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("forbidden", { status: 403 })),
    );

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.error).toBe("OpenCode sign-in required");
  });
});

describe("OpenCode Go malformed or missing readings", () => {
  function writeGoAuth(key = "sk-go-key"): void {
    writeAuthJson({ "opencode-go": { type: "api", key } });
  }

  it("reports a malformed error when a window is missing entirely", async () => {
    writeGoAuth();
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              usage: {
                rolling: {
                  status: "ok",
                  percent: 9,
                  resetsAt: "2026-10-06T03:36:51.000Z",
                },
                weekly: {
                  status: "ok",
                  percent: 6,
                  resetsAt: "2026-10-12T00:00:00.000Z",
                },
              },
            }),
            { status: 200, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.windows).toEqual([]);
    expect(result.state.error).toContain("malformed");
  });

  it("reports a malformed error when percent is out of range", async () => {
    writeGoAuth();
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              usage: {
                rolling: {
                  status: "ok",
                  percent: 150,
                  resetsAt: "2026-10-06T03:36:51.000Z",
                },
                weekly: {
                  status: "ok",
                  percent: 6,
                  resetsAt: "2026-10-12T00:00:00.000Z",
                },
                monthly: {
                  status: "ok",
                  percent: 3,
                  resetsAt: "2026-11-05T13:35:10.000Z",
                },
              },
            }),
            { status: 200, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.error).toContain("malformed");
  });

  it("reports a malformed error when resetsAt is missing", async () => {
    writeGoAuth();
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({
              usage: {
                rolling: { status: "ok", percent: 9 },
                weekly: {
                  status: "ok",
                  percent: 6,
                  resetsAt: "2026-10-12T00:00:00.000Z",
                },
                monthly: {
                  status: "ok",
                  percent: 3,
                  resetsAt: "2026-11-05T13:35:10.000Z",
                },
              },
            }),
            { status: 200, headers: { "content-type": "application/json" } },
          ),
      ),
    );

    const result = await fetchQuota({ allowKeychainPrompt: false });

    expect(result.state.error).toContain("malformed");
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
