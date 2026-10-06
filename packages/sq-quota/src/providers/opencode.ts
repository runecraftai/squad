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
  QuotaWindow,
  SourceAttempt,
} from "../types.js";
import {
  failedProvider,
  sourceNames,
  statusFromError,
  withRemaining,
} from "./common.js";

const MODELS_URL = "https://opencode.ai/zen/v1/models";
const GO_USAGE_URL = "https://opencode.ai/zen/go/v1/usage";
const API_TIMEOUT_MS = 15_000;
const OPENCODE_AUTH_SOURCE = "auth-json";
const OPENCODE_ENV_SOURCE = "api-key-env";
const GO_AUTH_ENTRY_KEY = "opencode-go";
const GO_NOTE =
  "OpenCode Go usage is account-level (all models on this key), not per-model.";

type OpenCodeCredentials = {
  key: string;
  isGo: boolean;
};

type CredentialState =
  | {
      status: "available";
      credentials: OpenCodeCredentials;
      source: AuthSourceReport;
    }
  | { status: "missing" | "invalid"; source: AuthSourceReport };

type GoWindowReading = {
  percent: number;
  resetsAt: string;
};

type GoUsageData = {
  rolling: GoWindowReading;
  weekly: GoWindowReading;
  monthly: GoWindowReading;
};

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
    const { credentials } = credentialState;
    if (credentials.isGo) {
      attempts.push({ source: "go-usage", status: "failed" });
      try {
        const usage = await fetchGoUsage(credentials);
        attempts[attempts.length - 1] = {
          source: "go-usage",
          status: "success",
        };
        return buildGoQuota(usage, attempts);
      } catch (error) {
        finalError = errorMessage(error);
        attempts[attempts.length - 1] = {
          source: "go-usage",
          status: "failed",
          error: finalError,
        };
      }
    } else {
      attempts.push({ source: "api", status: "failed" });
      try {
        const modelCount = await validateApiKey(credentials);
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

async function validateApiKey(
  credentials: OpenCodeCredentials,
): Promise<number> {
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

async function fetchGoUsage(
  credentials: OpenCodeCredentials,
): Promise<GoUsageData> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), API_TIMEOUT_MS);
  try {
    const response = await fetch(GO_USAGE_URL, {
      headers: {
        Authorization: `Bearer ${credentials.key}`,
        Accept: "application/json",
      },
      signal: controller.signal,
    });
    if (response.status === 403) {
      if (await isEntitlementError(response)) {
        throw new Error("OpenCode Go: not subscribed to Go");
      }
      throw new Error("OpenCode sign-in required");
    }
    if (response.status === 401) {
      throw new Error("OpenCode sign-in required");
    }
    if (response.status === 429) {
      throw new Error("OpenCode rate limited");
    }
    if (!response.ok) {
      throw new Error("OpenCode Go API unavailable");
    }
    const data = (await response.json()) as unknown;
    return parseGoUsage(data);
  } finally {
    clearTimeout(timer);
  }
}

async function isEntitlementError(response: Response): Promise<boolean> {
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    return false;
  }
  const root = objectValue(body);
  if (!root) return false;
  const error = objectValue(root.error);
  return stringValue(error?.type) === "EntitlementError";
}

function parseGoUsage(data: unknown): GoUsageData {
  const root = objectValue(data);
  const usage = root ? objectValue(root.usage) : undefined;
  if (!usage) throw new Error("OpenCode Go usage response malformed");
  return {
    rolling: parseGoWindow(usage.rolling),
    weekly: parseGoWindow(usage.weekly),
    monthly: parseGoWindow(usage.monthly),
  };
}

function parseGoWindow(value: unknown): GoWindowReading {
  const entry = objectValue(value);
  if (!entry) throw new Error("OpenCode Go usage response malformed");
  const percent = entry.percent;
  if (
    typeof percent !== "number" ||
    !Number.isFinite(percent) ||
    percent < 0 ||
    percent > 100
  ) {
    throw new Error("OpenCode Go usage response malformed");
  }
  const resetsAt = stringValue(entry.resetsAt);
  if (!resetsAt || Number.isNaN(new Date(resetsAt).getTime())) {
    throw new Error("OpenCode Go usage response malformed");
  }
  return { percent, resetsAt };
}

function buildGoQuota(
  usage: GoUsageData,
  attempts: SourceAttempt[],
): ProviderQuota {
  const windows: QuotaWindow[] = [
    goWindow(
      "go-rolling",
      "OpenCode Go rolling",
      "session",
      usage.rolling,
    ),
    goWindow(
      "go-weekly",
      "OpenCode Go weekly",
      "weekly",
      usage.weekly,
    ),
    goWindow(
      "go-monthly",
      "OpenCode Go monthly",
      "monthly",
      usage.monthly,
    ),
  ];
  return {
    provider: "opencode",
    label: "OpenCode",
    source: "api",
    windows,
    quotaSemantics: {
      status: "partial",
      description: GO_NOTE,
      effectiveAvailability: [],
    },
    notes: [GO_NOTE],
    state: {
      status: "fresh",
      stale: false,
      refreshedAt: nowIso(),
      authStatus: "usable",
      sourcesTried: sourceNames(attempts),
    },
    attempts,
  };
}

function goWindow(
  id: string,
  label: string,
  kind: QuotaWindow["kind"],
  reading: GoWindowReading,
): QuotaWindow {
  return withRemaining({
    id,
    label,
    kind,
    percentUsed: reading.percent,
    resetsAt: reading.resetsAt,
  });
}

function readCredentialState(): CredentialState {
  const envKey = process.env.OPENCODE_API_KEY ?? process.env.ZEN_API_KEY;
  if (envKey) {
    return {
      status: "available",
      credentials: { key: envKey, isGo: false },
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
  const credentials = findCredentials(data);
  if (!credentials)
    return {
      status: "invalid",
      source: { source: OPENCODE_AUTH_SOURCE, path, status: "invalid" },
    };
  return {
    status: "available",
    credentials,
    source: { source: OPENCODE_AUTH_SOURCE, path, status: "available" },
  };
}

function findCredentials(
  data: Record<string, unknown>,
): OpenCodeCredentials | undefined {
  const goEntry = objectValue(data[GO_AUTH_ENTRY_KEY]);
  if (goEntry) {
    const key = extractKey(goEntry);
    if (key) return { key, isGo: true };
  }
  const key = findApiKey(data);
  if (key) return { key, isGo: false };
  return undefined;
}

function findApiKey(data: Record<string, unknown>): string | undefined {
  for (const value of Object.values(data)) {
    const entry = objectValue(value);
    if (!entry) continue;
    const key = extractKey(entry);
    if (key) return key;
  }
  return undefined;
}

function extractKey(entry: Record<string, unknown>): string | undefined {
  const type = stringValue(entry.type);
  if (type !== "api_key" && type !== "api-key" && type !== "api")
    return undefined;
  return stringValue(entry.key);
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
