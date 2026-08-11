import { describe, it, expect } from "vitest";
import { getSuggestions, withSuggestionHost } from "../src/suggestions.js";

describe("getSuggestions", () => {
  it("returns home suggestions", () => {
    const lines = getSuggestions({ domain: "home", action: "home" });
    expect(lines.length).toBeGreaterThan(0);
    expect(lines.some((l) => l.includes("issue") || l.includes("pr"))).toBe(
      true,
    );
  });

  it("returns issue list suggestions when non-empty", () => {
    const lines = getSuggestions({
      domain: "issue",
      action: "list",
      isEmpty: false,
    });
    expect(lines.some((l) => l.includes("issue view"))).toBe(true);
  });

  it("returns issue list suggestions when empty", () => {
    const lines = getSuggestions({
      domain: "issue",
      action: "list",
      isEmpty: true,
    });
    expect(lines.some((l) => l.includes("issue create"))).toBe(true);
    expect(lines.some((l) => l.includes("--state closed"))).toBe(true);
  });

  it("returns open issue view suggestions", () => {
    const lines = getSuggestions({
      domain: "issue",
      action: "view",
      state: "open",
      id: 42,
    });
    expect(lines.some((l) => l.includes("comment 42"))).toBe(true);
    expect(lines.some((l) => l.includes("close 42"))).toBe(true);
  });

  it("returns closed issue view suggestions", () => {
    const lines = getSuggestions({
      domain: "issue",
      action: "view",
      state: "closed",
      id: 42,
    });
    expect(lines.some((l) => l.includes("reopen 42"))).toBe(true);
  });

  it("carries -R flag when repo source is not git", () => {
    const lines = getSuggestions({
      domain: "issue",
      action: "list",
      isEmpty: false,
      repo: { owner: "cli", name: "cli", nwo: "cli/cli", source: "flag" },
    });
    expect(lines.every((l) => l.includes("-R cli/cli"))).toBe(true);
    expect(lines.every((l) => !l.includes("sq-gh -R"))).toBe(true);
    expect(lines).toContain(
      "Run `sq-gh issue view <number> -R cli/cli` to view details",
    );
  });

  it("carries explicit non-default hostname flags", () => {
    const lines = getSuggestions({
      domain: "issue",
      action: "list",
      isEmpty: false,
      repo: {
        owner: "cli",
        name: "cli",
        nwo: "cli/cli",
        source: "flag",
        host: { value: "git.example.com", source: "flag" },
      },
    });

    expect(lines).toEqual([
      "Run `sq-gh issue view <number> -R cli/cli --hostname git.example.com` to view details",
      'Run `sq-gh issue create --title "..." --body-file <path> -R cli/cli --hostname git.example.com` to create',
    ]);
  });

  it("does not carry env-only hostname flags", () => {
    const lines = getSuggestions({
      domain: "issue",
      action: "list",
      isEmpty: false,
      host: { value: "git.example.com", source: "env" },
    });

    expect(lines.every((l) => !l.includes("--hostname"))).toBe(true);
  });

  it("does not carry default hostname flags", () => {
    const lines = getSuggestions({
      domain: "issue",
      action: "list",
      isEmpty: false,
      host: { value: "github.com", source: "flag" },
    });

    expect(lines.every((l) => !l.includes("--hostname"))).toBe(true);
  });

  it("carries host-only CLI context into suggestions", async () => {
    const lines = await withSuggestionHost(
      { value: "git.example.com", source: "flag" },
      async () =>
        getSuggestions({
          domain: "issue",
          action: "list",
          isEmpty: false,
        }),
    );

    expect(lines).toContain(
      "Run `sq-gh issue view <number> --hostname git.example.com` to view details",
    );
  });

  it("does not carry -R flag when repo source is git", () => {
    const lines = getSuggestions({
      domain: "issue",
      action: "list",
      isEmpty: false,
      repo: { owner: "cli", name: "cli", nwo: "cli/cli", source: "git" },
    });
    expect(lines.every((l) => !l.includes("-R"))).toBe(true);
  });

  it("places explicit repo flags after secret commands", () => {
    const repo = {
      owner: "cli",
      name: "cli",
      nwo: "cli/cli",
      source: "flag" as const,
    };

    const lines = [
      ...getSuggestions({
        domain: "secret",
        action: "list",
        isEmpty: false,
        repo,
      }),
      ...getSuggestions({
        domain: "secret",
        action: "list",
        isEmpty: true,
        repo,
      }),
      ...getSuggestions({ domain: "secret", action: "set", repo }),
      ...getSuggestions({ domain: "secret", action: "delete", repo }),
    ];

    expect(lines).toEqual([
      'Run `echo -n "<value>" | sq-gh secret set <name> -R cli/cli` to add or update a secret',
      'Run `echo -n "<value>" | sq-gh secret set <name> -R cli/cli` to add a secret',
      "Run `sq-gh secret list -R cli/cli` to see all secrets",
      "Run `sq-gh secret list -R cli/cli` to see remaining secrets",
    ]);
    expect(lines.every((l) => !l.includes("sq-gh -R"))).toBe(true);
  });

  it("places explicit repo flags after variable commands", () => {
    const repo = {
      owner: "cli",
      name: "cli",
      nwo: "cli/cli",
      source: "flag" as const,
    };

    const lines = [
      ...getSuggestions({
        domain: "variable",
        action: "list",
        isEmpty: false,
        repo,
      }),
      ...getSuggestions({
        domain: "variable",
        action: "list",
        isEmpty: true,
        repo,
      }),
      ...getSuggestions({ domain: "variable", action: "set", repo }),
      ...getSuggestions({ domain: "variable", action: "delete", repo }),
    ];

    expect(lines).toEqual([
      "Run `sq-gh variable set <name> --body <value> -R cli/cli` to add or update a variable",
      "Run `sq-gh variable set <name> --body <value> -R cli/cli` to add a variable",
      "Run `sq-gh variable list -R cli/cli` to see all variables",
      "Run `sq-gh variable list -R cli/cli` to see remaining variables",
    ]);
    expect(lines.every((l) => !l.includes("sq-gh -R"))).toBe(true);
  });

  it("returns PR merge suggestions", () => {
    const lines = getSuggestions({ domain: "pr", action: "merge", id: 10 });
    expect(lines.some((l) => l.includes("revert"))).toBe(true);
  });

  it("returns run view suggestions for in-progress", () => {
    const lines = getSuggestions({
      domain: "run",
      action: "view",
      state: "in_progress",
      id: 123,
    });
    expect(lines.some((l) => l.includes("watch 123"))).toBe(true);
    expect(lines.some((l) => l.includes("cancel 123"))).toBe(true);
  });
});
