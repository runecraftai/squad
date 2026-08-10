import { describe, it, expect, afterEach } from "vitest";
import { gistIdFromSelector } from "../src/gistSelector.js";
import { AxiError } from "../src/errors.js";

const ID = "5b0e0062eb8e9654adad7bb1d81cc75f";

afterEach(() => {
  delete process.env["GH_HOST"];
});

describe("gistIdFromSelector", () => {
  describe("bare ids", () => {
    it("returns a bare gist id unchanged", () => {
      expect(gistIdFromSelector(ID)).toBe(ID);
    });

    it("accepts a short numeric id", () => {
      expect(gistIdFromSelector("1234")).toBe("1234");
    });
  });

  describe("urls", () => {
    it("extracts the id from an owner-scoped gist url", () => {
      expect(gistIdFromSelector(`https://gist.github.com/OWNER/${ID}`)).toBe(
        ID,
      );
    });

    it("extracts the id from an ownerless gist url", () => {
      expect(gistIdFromSelector(`https://gist.github.com/${ID}`)).toBe(ID);
    });

    it("tolerates a trailing slash", () => {
      expect(gistIdFromSelector(`https://gist.github.com/OWNER/${ID}/`)).toBe(
        ID,
      );
    });

    // gh's own GistIDFromURL takes path segment [2], which yields "OWNER" for
    // this GHE shape. Taking the last segment is correct for every shape.
    it("extracts the id from a GHE /gist/OWNER/ID url", () => {
      process.env["GH_HOST"] = "ghe.example.com";
      expect(
        gistIdFromSelector(`https://ghe.example.com/gist/OWNER/${ID}`),
      ).toBe(ID);
    });

    it("accepts the bare configured host without a gist subdomain", () => {
      process.env["GH_HOST"] = "ghe.example.com";
      expect(gistIdFromSelector(`https://ghe.example.com/${ID}`)).toBe(ID);
    });
  });

  describe("host validation", () => {
    it("rejects a url pointing at a different host than configured", () => {
      process.env["GH_HOST"] = "ghe.example.com";
      expect(() =>
        gistIdFromSelector(`https://gist.github.com/OWNER/${ID}`),
      ).toThrow(AxiError);
    });

    it("names the configured host in the mismatch error", () => {
      process.env["GH_HOST"] = "ghe.example.com";
      expect(() =>
        gistIdFromSelector(`https://gist.github.com/OWNER/${ID}`),
      ).toThrow(/ghe\.example\.com/);
    });

    it("accepts gist.github.com by default", () => {
      expect(gistIdFromSelector(`https://gist.github.com/OWNER/${ID}`)).toBe(
        ID,
      );
    });

    it("accepts github.com by default", () => {
      expect(gistIdFromSelector(`https://github.com/OWNER/${ID}`)).toBe(ID);
    });
  });

  describe("invalid input", () => {
    it("rejects an empty selector", () => {
      expect(() => gistIdFromSelector("")).toThrow(AxiError);
    });

    it("rejects a whitespace-only selector", () => {
      expect(() => gistIdFromSelector("   ")).toThrow(AxiError);
    });

    it("rejects a url with no id segment", () => {
      expect(() => gistIdFromSelector("https://gist.github.com/")).toThrow(
        AxiError,
      );
    });

    it("rejects a selector containing whitespace", () => {
      expect(() => gistIdFromSelector("abc def")).toThrow(AxiError);
    });

    it("throws VALIDATION_ERROR for bad input", () => {
      try {
        gistIdFromSelector("");
        expect.unreachable("should have thrown");
      } catch (error) {
        expect((error as AxiError).code).toBe("VALIDATION_ERROR");
      }
    });
  });

  // A bare selector is interpolated into the `/gists/<id>` API path, so it must
  // be charset-validated (finding: unvalidated-bare-id).
  describe("bare id charset validation", () => {
    it("rejects a bare id containing a slash", () => {
      expect(() => gistIdFromSelector("abc/def")).toThrow(AxiError);
    });

    it("rejects a dot-segment traversal attempt", () => {
      expect(() => gistIdFromSelector("..")).toThrow(AxiError);
    });

    it("rejects a bare id with a path-traversal payload", () => {
      expect(() => gistIdFromSelector("../repos/owner/repo")).toThrow(AxiError);
    });

    it("throws VALIDATION_ERROR (not a raw error) for a bad bare id", () => {
      try {
        gistIdFromSelector("bad/id");
        expect.unreachable("should have thrown");
      } catch (error) {
        expect((error as AxiError).code).toBe("VALIDATION_ERROR");
      }
    });

    it("rejects a url whose last segment is not a valid id", () => {
      expect(() =>
        gistIdFromSelector("https://gist.github.com/OWNER/bad..id"),
      ).toThrow(AxiError);
    });
  });

  // A malformed URL must surface as a structured VALIDATION_ERROR, not a raw
  // TypeError from new URL() (finding: unguarded-url-parse).
  describe("malformed url handling", () => {
    it("throws AxiError for a URL with no host", () => {
      expect(() => gistIdFromSelector("https://")).toThrow(AxiError);
    });

    it("surfaces VALIDATION_ERROR (not a raw TypeError) for a malformed URL", () => {
      try {
        gistIdFromSelector("https://");
        expect.unreachable("should have thrown");
      } catch (error) {
        expect(error).toBeInstanceOf(AxiError);
        expect((error as AxiError).code).toBe("VALIDATION_ERROR");
      }
    });
  });
});
