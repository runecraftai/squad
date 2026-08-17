import { homedir } from "node:os";
import { join } from "node:path";
import { readJsonFileResult, type JsonFileReadResult } from "../lib/fs.js";
import { nowIso } from "../lib/time.js";
import type {
  AuthProviderReport,
  AuthSourceReport,
  ProviderAdapter,
  ProviderOptions,
  ProviderQuota,
  SourceAttempt,
} from "../types.js";
import { failedProvider, sourceNames, statusFromError } from "./common.js";

const MODELS_URL = "https://opencode.ai/zen/v1/models";
const API_TIMEOUT_MS = 15_000;
const OPENCODE_AUTH_SOURCE = "auth-json";
const OPENCODE_ENV_SOURCE = "api-key-env";

type OpenCodeCredentials = {
  key: string;
};

type CredentialState =
  | {
      status: "available";
      credentials: OpenCodeCredentials;
      source: AuthSourceReport;
    }
  | { status: "missing" | "invalid"; source: AuthSourceReport };

export const opencodeAdapter: ProviderAdapter = {
  id: "opencode",
  label: "OpenCode",
  fetchQuota,
  inspectAuth,
};

export async function fetchQuota(
  _options: ProviderOptions,
): Promise<ProviderQuota> {
  const attempts: SourceAttempt[] = [];
  let finalError = "OpenCode sign-in required";

  const credentialState = readCredentialState();
  if (credentialState.status === "available") {
    attempts.push({ source: "api", status: "failed" });
    try {
      const modelCount = await validateApiKey(credentialState.credentials);
      attempts[attempts.length - 1] = { source: "api", status: "success" };
      return {
        provider: "opencode",
        label: "OpenCode",
        source: "api",
        windows: [],
        quotaSemantics: {
          status: "unknown",
          description:
            "OpenCode/Zen has no public quota, balance, or usage API. Authenticated successfully with model access only.",
          effectiveAvailability: [],
        },
        notes: modelCount > 0 ? [`${modelCount} models available`] : [],
        state: {
          status: "fresh",
          stale: false,
          refreshedAt: nowIso(),
          authStatus: "usable",
          sourcesTried: sourceNames(attempts),
        },
        attempts,
      };
    } catch (error) {
      finalError = errorMessage(error);
      attempts[attempts.length - 1] = {
        source: "api",
        status: "failed",
        error: finalError,
      };
    }
  } else {
    attempts.push({
      source: OPENCODE_AUTH_SOURCE,
      status: "skipped",
      error: `credentials_${credentialState.status}`,
    });
  }

  return failedProvider({
    provider: "opencode",
    label: "OpenCode",
    status: statusFromError(finalError),
    error: finalError,
    sourcesTried: sourceNames(attempts),
    attempts,
  });
}

export async function inspectAuth(
  _options: ProviderOptions,
): Promise<AuthProviderReport> {
  const credentialState = readCredentialState();
  return {
    provider: "opencode",
    sources: [credentialState.source],
  };
}

async function validateApiKey(credentials: OpenCodeCredentials): Promise<number> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), API_TIMEOUT_MS);
  try {
    const response = await fetch(MODELS_URL, {
      headers: {
        Authorization: `Bearer ${credentials.key}`,
        Accept: "application/json",
      },
      signal: controller.signal,
    });
    if (response.status === 401 || response.status === 403) {
      throw new Error("OpenCode sign-in required");
    }
    if (response.status === 429) {
      throw new Error("OpenCode rate limited");
    }
    if (!response.ok) {
      throw new Error("OpenCode API unavailable");
    }
    const data = (await response.json()) as unknown;
    if (Array.isArray(data)) return data.length;
    if (data && typeof data === "object" && "data" in data) {
      const inner = (data as Record<string, unknown>).data;
      if (Array.isArray(inner)) return inner.length;
    }
    return 0;
  } finally {
    clearTimeout(timer);
  }
}

function readCredentialState(): CredentialState {
  const envKey = process.env.OPENCODE_API_KEY ?? process.env.ZEN_API_KEY;
  if (envKey) {
    return {
      status: "available",
      credentials: { key: envKey },
      source: { source: OPENCODE_ENV_SOURCE, status: "available" },
    };
  }
  const authFile = opencodeAuthFile();
  return extractCredentialState(readJsonFileResult(authFile), authFile);
}

function extractCredentialState(
  raw: JsonFileReadResult,
  path: string,
): CredentialState {
  if (raw.status === "missing")
    return {
      status: "missing",
      source: { source: OPENCODE_AUTH_SOURCE, path, status: "missing" },
    };
  if (raw.status === "invalid")
    return {
      status: "invalid",
      source: {
        source: OPENCODE_AUTH_SOURCE,
        path,
        status: "invalid",
        error: raw.error,
      },
    };
  const data = objectValue(raw.value);
  if (!data)
    return {
      status: "invalid",
      source: { source: OPENCODE_AUTH_SOURCE, path, status: "invalid" },
    };
  const key = findApiKey(data);
  if (!key)
    return {
      status: "invalid",
      source: { source: OPENCODE_AUTH_SOURCE, path, status: "invalid" },
    };
  return {
    status: "available",
    credentials: { key },
    source: { source: OPENCODE_AUTH_SOURCE, path, status: "available" },
  };
}

function findApiKey(data: Record<string, unknown>): string | undefined {
  for (const value of Object.values(data)) {
    const entry = objectValue(value);
    if (!entry) continue;
    const type = stringValue(entry.type);
    if (type !== "api_key" && type !== "api-key") continue;
    const key = stringValue(entry.key);
    if (key) return key;
  }
  return undefined;
}

function opencodeAuthFile(): string {
  const dataHome =
    process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  return join(dataHome, "opencode", "auth.json");
}

function objectValue(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object"
    ? (value as Record<string, unknown>)
    : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.name === "AbortError")
    return "OpenCode request timed out";
  return error instanceof Error ? error.message : "OpenCode API unavailable";
}
