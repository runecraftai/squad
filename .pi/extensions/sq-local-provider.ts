// Squad's Pi-side local LM Studio provider registration.
//
// Registers the local OpenAI-compatible inference server (LM Studio on
// http://localhost:1234/v1) as the pi provider `local-openai`, discovering the
// served models live from /v1/models at load. Every local model is zero-cost
// (cost: 0) and non-reasoning. The provider exists so Squad's exploration and
// recon lanes can dispatch to the local Qwen model and burn zero cloud quota
// while the commander's opencode and claude subscriptions are at or near their
// monthly cap.
//
// Robustness: the factory fetches /v1/models at load. If LM Studio is not
// reachable, the extension fails gracefully: it registers nothing, logs a
// console warning, and returns, so a local inference outage never breaks the
// Squad pi session or dispatch. Squad's dispatch config must keep a cloud
// fallback for when this provider is absent. A short abort timeout bounds the
// load so a hung server cannot stall pi startup indefinitely.
//
// apiKey: pi's model listing surface (`pi --list-models`) and Squad's bootstrap
// model-existence check only surface providers that have auth configured, and
// this localhost server accepts no real key. A literal harmless key is used so
// the provider always lists and validation passes; it is a local-only value that
// never leaves the machine and LM Studio ignores it.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const LOCAL_BASE_URL = "http://localhost:1234/v1";
const LOCAL_API_KEY = "lm-studio-local";
const MODEL_DISCOVERY_TIMEOUT_MS = 2000;

interface LocalModelListing {
  data?: Array<{ id?: string; name?: string }>;
}

export default async function registerLocalProvider(pi: ExtensionAPI): Promise<void> {
  let payload: LocalModelListing;
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), MODEL_DISCOVERY_TIMEOUT_MS);
    let response: Response;
    try {
      response = await fetch(`${LOCAL_BASE_URL}/models`, { signal: controller.signal });
    } finally {
      clearTimeout(timer);
    }
    if (!response.ok) {
      throw new Error(`LM Studio /v1/models returned HTTP ${response.status}`);
    }
    payload = (await response.json()) as LocalModelListing;
  } catch (error) {
    console.error(`Squad local-provider: LM Studio unreachable at ${LOCAL_BASE_URL}, local model unavailable. ${String(error)}`);
    return;
  }

  const models = (payload.data ?? [])
    .filter((model) => typeof model.id === "string" && model.id.length > 0)
    .map((model) => ({
      id: model.id as string,
      name: model.name ?? (model.id as string),
      reasoning: false,
      input: ["text" as const],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      // /v1/models does not report these; keep conservative working defaults.
      contextWindow: 128000,
      maxTokens: 4096,
    }));

  if (models.length === 0) {
    console.error("Squad local-provider: LM Studio returned no models, registering nothing.");
    return;
  }

  pi.registerProvider("local-openai", {
    name: "Local LM Studio",
    baseUrl: LOCAL_BASE_URL,
    apiKey: LOCAL_API_KEY,
    api: "openai-completions",
    models,
  });
}
