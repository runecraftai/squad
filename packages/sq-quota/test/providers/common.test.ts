import { describe, expect, it } from "vitest";
import { statusFromError } from "../../src/providers/common.js";

describe("shared statusFromError", () => {
  it("keeps access-token-expired phrasing on the shared auth_required path", () => {
    // Grok soft-expiry must not change this shared helper; provider-specific
    // classification belongs in the Grok adapter (grokStatusForAuthFailure).
    expect(statusFromError("Grok access token expired")).toBe("auth_required");
    expect(statusFromError("OAuth access token expired")).toBe("auth_required");
    expect(statusFromError("Codex sign-in required")).toBe("auth_required");
    expect(statusFromError("provider rate limited")).toBe("rate_limited");
    expect(statusFromError("quota unavailable")).toBe("error");
  });
});
