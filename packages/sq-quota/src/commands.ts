import { AxiError } from "axi-sdk-js";
import { annotateQuotaAdvice } from "./advice.js";
import { parseFlags, parseModelsFlags, type QuotaFlags } from "./args.js";
import { writeCachedProviders } from "./cache.js";
import { withQuotaSemantics } from "./interpretation.js";
import { createModelsResponse, MODEL_CATALOG_PROVIDER_IDS } from "./models.js";
import { nowIso } from "./lib/time.js";
import { PROVIDERS } from "./providers/index.js";
import {
  redactedResponse,
  renderAuthToon,
  renderModelsToon,
  renderQuotaToon,
} from "./render.js";
import { formatInterval, runLiveTui, type LiveTuiIo } from "./tui-live.js";
import { detectTuiColorDepth, renderQuotaTui } from "./tui.js";
import type {
  AuthProviderReport,
  ProviderId,
  ProviderOptions,
  ProviderQuota,
  SqQuotaResponse,
} from "./types.js";

export type QuotaContext = {
  binPath: string;
};

const DEFAULT_REFRESH_SECONDS = 300;

export async function quotaCommand(
  args: string[],
  context: QuotaContext | undefined,
): Promise<string> {
  const binPath = context?.binPath ?? "sq-quota";
  const flags = parseFlags(args);
  const options: ProviderOptions = {
    allowKeychainPrompt: flags.allowKeychainPrompt,
  };

  const effectiveProviders = await resolveEffectiveProviders(
    flags,
    options,
  );
  const effectiveFlags = { ...flags, providers: effectiveProviders };

  if (flags.tui) return quotaTuiReport(effectiveFlags, options);

  const response = await loadQuota(effectiveProviders, options, false);
  const redacted = redactedResponse(response, flags.full);
  return flags.json
    ? JSON.stringify(redacted, null, 2)
    : renderQuotaToon(redacted, binPath, flags.full);
}

/**
 * Render the human report. On an interactive terminal it stays live until the
 * operator quits and then echoes the final frame onto the normal screen;
 * everywhere else (pipes, CI, `--once`) it renders a single frame.
 */
async function quotaTuiReport(
  flags: QuotaFlags,
  options: ProviderOptions,
): Promise<string> {
  const frame = (response: SqQuotaResponse, footerHint?: string): string =>
    renderQuotaTui(redactedResponse(response, flags.full), {
      columns: process.stdout.columns,
      colorDepth: detectTuiColorDepth(
        process.env,
        process.stdout.isTTY === true,
      ),
      full: flags.full,
      ...(footerHint === undefined ? {} : { footerHint }),
    });

  if (flags.once || !isInteractiveTerminal()) {
    return frame(await loadQuota(flags.providers, options, false));
  }

  const refreshSeconds = flags.refreshSeconds ?? DEFAULT_REFRESH_SECONDS;
  const hint = `Press q to quit · refreshing every ${formatInterval(refreshSeconds)}`;
  const last = await runLiveTui<SqQuotaResponse>({
    load: () => loadQuota(flags.providers, options, true),
    render: (response) => frame(response, hint),
    intervalMillis: refreshSeconds * 1000,
    io: processLiveTuiIo(),
  });
  return last === undefined ? "" : frame(last);
}

function isInteractiveTerminal(): boolean {
  return process.stdout.isTTY === true && process.stdin.isTTY === true;
}

function processLiveTuiIo(): LiveTuiIo {
  return {
    stdout: process.stdout,
    stdin: process.stdin,
    setTimer: (callback, milliseconds) => setTimeout(callback, milliseconds),
    clearTimer: (handle) => {
      clearTimeout(handle as ReturnType<typeof setTimeout>);
    },
    onResize: (listener) => {
      process.stdout.on("resize", listener);
      return () => {
        process.stdout.off("resize", listener);
      };
    },
    onSignal: (listener) => {
      const signals = ["SIGINT", "SIGTERM", "SIGHUP"] as const;
      for (const signal of signals) process.on(signal, listener);
      return () => {
        for (const signal of signals) process.off(signal, listener);
      };
    },
  };
}

/**
 * Fetch, apply the all-failed exit code, and refresh the cache. A live report
 * re-evaluates the exit code every cycle so quitting reflects the last frame.
 */
async function loadQuota(
  providers: ProviderId[],
  options: ProviderOptions,
  live: boolean,
): Promise<SqQuotaResponse> {
  const response = await fetchQuota(providers, options);
  const allFailed = response.providers.every(isFailed);
  if (allFailed) process.exitCode = 1;
  else if (live) process.exitCode = undefined;
  writeCachedProvidersBestEffort(response.providers);
  return response;
}

export async function modelsCommand(
  args: string[],
  context: QuotaContext | undefined,
): Promise<string> {
  const binPath = context?.binPath ?? "sq-quota";
  const flags = parseModelsFlags(args);
  const options: ProviderOptions = {
    allowKeychainPrompt: flags.allowKeychainPrompt,
  };

  const effectiveProviders = await resolveEffectiveProviders(
    flags,
    options,
  );
  const quota = await fetchQuota(effectiveProviders, options);
  writeCachedProvidersBestEffort(quota.providers);
  const response = createModelsResponse(quota, {
    ...(flags.intelligence ? { intelligence: flags.intelligence } : {}),
    ...(flags.sort ? { sort: flags.sort } : {}),
  });

  const modelProviders = quota.providers.filter((provider) =>
    MODEL_CATALOG_PROVIDER_IDS.includes(provider.provider),
  );
  if (modelProviders.every(isFailed)) process.exitCode = 1;
  return flags.json
    ? JSON.stringify(response, null, 2)
    : renderModelsToon(response, binPath, flags.full);
}

export async function authCommand(
  args: string[],
  context: QuotaContext | undefined,
): Promise<string> {
  const binPath = context?.binPath ?? "sq-quota";
  const flags = parseFlags(args);
  if (flags.tui) {
    throw new AxiError(
      "--tui is only supported by the quota command",
      "VALIDATION_ERROR",
      ["Run `sq-quota --tui` for the human quota report"],
    );
  }
  const options: ProviderOptions = {
    allowKeychainPrompt: flags.allowKeychainPrompt,
  };

  const effectiveProviders = await resolveEffectiveProviders(
    flags,
    options,
  );
  const reports = await inspectAuth(effectiveProviders, options);
  return flags.json
    ? JSON.stringify(
        { generatedAt: nowIso(), schemaVersion: 1, auth: reports },
        null,
        2,
      )
    : renderAuthToon(reports, binPath);
}

export async function fetchQuota(
  providers: ProviderId[],
  options: ProviderOptions,
): Promise<SqQuotaResponse> {
  const generatedAt = nowIso();
  const results = (
    await Promise.all(
      providers.map((provider) => PROVIDERS[provider].fetchQuota(options)),
    )
  ).map((provider) => withQuotaSemantics(provider, generatedAt));
  return annotateQuotaAdvice({
    generatedAt,
    providers: results,
  });
}

async function resolveEffectiveProviders(
  flags: { providers: ProviderId[]; allProviders: boolean; providersExplicit: boolean },
  options: ProviderOptions,
): Promise<ProviderId[]> {
  if (flags.providersExplicit || flags.allProviders) return flags.providers;
  return filterPresentProviders(flags.providers, options);
}

/**
 * Filter to providers that have at least one local credential artifact.
 * A provider is "present" if its inspectAuth reports any source that is
 * not "missing" - i.e. the user has configured it at some point.
 * This is a fast local file/env check, not a network probe.
 */
async function filterPresentProviders(
  providers: ProviderId[],
  options: ProviderOptions,
): Promise<ProviderId[]> {
  const reports = await Promise.all(
    providers.map((provider) => PROVIDERS[provider].inspectAuth(options)),
  );
  return providers.filter((_, index) => {
    const report = reports[index];
    return report.sources.some(
      (source) => source.status !== "missing",
    );
  });
}

async function inspectAuth(
  providers: ProviderId[],
  options: ProviderOptions,
): Promise<AuthProviderReport[]> {
  return Promise.all(
    providers.map((provider) => PROVIDERS[provider].inspectAuth(options)),
  );
}

function isFailed(provider: ProviderQuota): boolean {
  return !["fresh", "stale"].includes(provider.state.status);
}

function writeCachedProvidersBestEffort(providers: ProviderQuota[]): void {
  try {
    writeCachedProviders(providers);
  } catch {
    return;
  }
}
