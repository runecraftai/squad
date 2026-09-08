import { VERSION } from "./version.js";

export const AXI_SCHEMA = "https://axi.runecraft.ai/schemas/output/v1.json";

export type AxiJsonEnvelope = {
  $schema: string;
  version: string;
  data: unknown;
};

export function jsonOutput(data: unknown): string {
  return JSON.stringify({ $schema: AXI_SCHEMA, version: VERSION, data });
}

export function jsonError(
  code: string,
  message: string,
  suggestions: string[] = [],
): string {
  const error: Record<string, unknown> = { code, message };
  if (suggestions.length > 0) error.help = suggestions;
  return JSON.stringify({ $schema: AXI_SCHEMA, version: VERSION, error });
}

export const CAPABILITIES = {
  $schema: AXI_SCHEMA,
  version: VERSION,
  provider: "github",
  operations: {
    issue: ["list", "view", "create", "edit", "close", "comment"],
    pr: ["list", "view", "create", "edit", "merge", "comment"],
    run: ["list", "view", "watch", "rerun", "cancel", "logs"],
    workflow: ["list", "view", "run", "enable", "disable"],
    release: ["list", "view", "create", "edit", "delete"],
    repo: ["list", "view", "create", "fork", "archive"],
    label: ["list", "create", "delete"],
    gist: ["list", "view", "create", "edit", "delete"],
    project: ["list", "view", "create", "edit", "delete"],
    secret: ["list", "set", "delete"],
    variable: ["list", "set", "delete"],
    search: ["issues", "prs", "repos", "code"],
    api: ["request"],
  },
  output: {
    formats: ["text", "json"],
    json_flag: "--json",
    schema_version: "1.0",
  },
  pagination: {
    flags: ["--limit", "--cursor"],
    default_page_size: 30,
  },
  auth: ["gh auth status", "gh auth login"],
} as const;

export function capabilitiesOutput(): string {
  return JSON.stringify(CAPABILITIES);
}
