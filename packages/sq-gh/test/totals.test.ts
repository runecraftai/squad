import { describe, it, expect } from "vitest";
import {
  isSearchableMilestone,
  isSearchableValue,
  searchQualifier,
  searchQualifiers,
  stateQualifiers,
} from "../src/totals.js";

describe("searchQualifier", () => {
  it("leaves a plain value unquoted", () => {
    expect(searchQualifier("label", "bug")).toBe("label:bug");
  });

  it("quotes a value containing whitespace", () => {
    expect(searchQualifier("label", "help wanted")).toBe('label:"help wanted"');
  });

  it("keeps the @me sentinel usable", () => {
    expect(searchQualifier("assignee", "@me")).toBe("assignee:@me");
    expect(searchQualifier("author", "@me")).toBe("author:@me");
  });
});

describe("searchQualifiers", () => {
  it("returns one qualifier for a single value", () => {
    expect(searchQualifiers("label", "bug")).toEqual(["label:bug"]);
  });

  it("splits a comma-separated list into one qualifier per value", () => {
    expect(searchQualifiers("label", "bug,gh-licenses")).toEqual([
      "label:bug",
      "label:gh-licenses",
    ]);
  });

  it("trims and quotes each value independently", () => {
    expect(searchQualifiers("label", "bug, help wanted")).toEqual([
      "label:bug",
      'label:"help wanted"',
    ]);
  });

  it("drops empty segments", () => {
    expect(searchQualifiers("label", "bug,,")).toEqual(["label:bug"]);
    expect(searchQualifiers("label", ",")).toEqual([]);
  });
});

describe("stateQualifiers", () => {
  it("defaults to open", () => {
    expect(stateQualifiers(undefined)).toEqual(["is:open"]);
  });

  it("maps a state onto its qualifier", () => {
    expect(stateQualifiers("CLOSED")).toEqual(["is:closed"]);
  });

  it("has no qualifier for all", () => {
    expect(stateQualifiers("all")).toEqual([]);
  });
});

describe("isSearchableMilestone", () => {
  it("accepts a milestone title", () => {
    expect(isSearchableMilestone("v1.0")).toBe(true);
    expect(isSearchableMilestone("1.0")).toBe(true);
  });

  it("rejects a milestone number, which search matches by title only", () => {
    expect(isSearchableMilestone("1")).toBe(false);
    expect(isSearchableMilestone("42")).toBe(false);
  });
});

describe("isSearchableValue", () => {
  it("accepts values search can express", () => {
    expect(isSearchableValue("bug")).toBe(true);
    expect(isSearchableValue("help wanted")).toBe(true);
    expect(isSearchableValue("@me")).toBe(true);
    expect(isSearchableValue("bug,gh-licenses")).toBe(true);
  });

  it("rejects a value containing a double quote search cannot escape", () => {
    expect(isSearchableValue('needs "design" input')).toBe(false);
    expect(isSearchableValue('"needs,triage"')).toBe(false);
  });
});
