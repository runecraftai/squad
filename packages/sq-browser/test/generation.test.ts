import { describe, expect, it, afterEach } from "vitest";
import {
  bumpGeneration,
  getCurrentGeneration,
  resetGeneration,
} from "../src/generation.js";

describe("generation counter session-name validation", () => {
  const saved = process.env.SQ_BROWSER_SESSION;

  afterEach(() => {
    if (saved === undefined) {
      delete process.env.SQ_BROWSER_SESSION;
    } else {
      process.env.SQ_BROWSER_SESSION = saved;
    }
  });

  it("rejects a dot-only session instead of reading the default session's counter", () => {
    process.env.SQ_BROWSER_SESSION = "..";
    expect(() => getCurrentGeneration()).toThrow(/Invalid/);
    expect(() => bumpGeneration()).toThrow(/Invalid/);
    expect(() => resetGeneration()).toThrow(/Invalid/);
  });
});
