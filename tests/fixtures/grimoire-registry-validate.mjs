#!/usr/bin/env node
// Reimplementation of @runecraft/skills' registry schema validator.
//
// The real package (projects/skills, a read-only clone of runecraftai/skills)
// is gitignored and not a dependency of this repo, so a clean checkout - and
// CI - has no way to import it. This file re-implements
// packages/core/src/index.ts's `validateRegistry`, `normalizePath`, `record`,
// `nonempty`, and `keys` check-for-check, as read on 2026-10-06 from that
// clone's packages/core/src/index.ts lines 5-12 and 18-31:
//
//   export type FileRecord = { path: string; size: number; sha256: string };
//   export type Skill = { id: string; name: string; version: string; category: string; description: string; license: string; attribution: { name: string; url: string; text: string }[]; entrypoint: string; files: FileRecord[]; contentSha256: string };
//   export type Registry = { schemaVersion: 1; catalogVersion: string; revision: string; generatedAt: string; skills: Skill[] };
//   export function normalizePath(path) {
//     if (!path || path.startsWith("/") || /^[A-Za-z]:/.test(path) || path.includes("\\") || /[\u0000-\u001f\u007f]/.test(path)) throw new Error(`Invalid path: ${path}`);
//     if (path.split("/").some((part) => !part || part === "." || part === "..")) throw new Error(`Invalid path: ${path}`);
//     return path;
//   }
//   const record = (x) => !!x && typeof x === "object" && !Array.isArray(x);
//   const nonempty = (x) => typeof x === "string" && !!x.trim();
//   function keys(x, expected) { if (Object.keys(x).sort().join(",") !== expected) throw new Error("Invalid registry schema keys"); }
//   export function validateRegistry(v) {
//     if (!record(v)) throw new Error("Invalid registry");
//     keys(v, "catalogVersion,generatedAt,revision,schemaVersion,skills");
//     if (v.schemaVersion !== 1 || !nonempty(v.catalogVersion) || !nonempty(v.revision) || !nonempty(v.generatedAt) || Number.isNaN(Date.parse(v.generatedAt)) || !Array.isArray(v.skills)) throw new Error("Invalid registry schema");
//     const ids = new Set();
//     for (const s of v.skills) {
//       if (!record(s)) throw new Error("Invalid skill");
//       keys(s, "attribution,category,contentSha256,description,entrypoint,files,id,license,name,version");
//       if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(s.id) || ids.has(s.id) || ![s.name, s.version, s.category, s.description, s.license, s.entrypoint].every(nonempty) || !Array.isArray(s.files) || !Array.isArray(s.attribution) || !s.attribution.length || !/^[a-f0-9]{64}$/.test(s.contentSha256)) throw new Error(`Invalid skill ${s.id}`);
//       ids.add(s.id);
//       const paths = new Set();
//       for (const f of s.files) {
//         if (!record(f)) throw new Error("Invalid file record");
//         keys(f, "path,sha256,size");
//         normalizePath(f.path);
//         if (paths.has(f.path) || !Number.isSafeInteger(f.size) || f.size < 0 || !/^[a-f0-9]{64}$/.test(f.sha256)) throw new Error("Invalid file record");
//         for (const p of paths) if (p.startsWith(f.path + "/") || f.path.startsWith(p + "/")) throw new Error("Path collision");
//         paths.add(f.path);
//       }
//       if (!paths.has(s.entrypoint)) throw new Error("Missing entrypoint");
//       for (const a of s.attribution) if (!record(a) || Object.keys(a).sort().join(",") !== "name,text,url" || ![a.name, a.text].every(nonempty) || typeof a.url !== "string" || new URL(a.url).protocol !== "https:") throw new Error("Invalid attribution");
//     }
//   }
//
// digestFiles (same file, lines 13-17) is reproduced in
// grimoire-digest-files.mjs, colocated, and used by the "content digest
// matches the real algorithm" regression instead of being duplicated here.

function normalizePath(path) {
  if (
    !path ||
    path.startsWith("/") ||
    /^[A-Za-z]:/.test(path) ||
    path.includes("\\") ||
    /[\u0000-\u001f\u007f]/.test(path)
  ) {
    throw new Error(`Invalid path: ${path}`);
  }
  if (path.split("/").some((part) => !part || part === "." || part === "..")) {
    throw new Error(`Invalid path: ${path}`);
  }
  return path;
}

const record = (x) => !!x && typeof x === "object" && !Array.isArray(x);
const nonempty = (x) => typeof x === "string" && !!x.trim();
function keys(x, expected) {
  if (Object.keys(x).sort().join(",") !== expected) throw new Error("Invalid registry schema keys");
}

export function validateRegistry(v) {
  if (!record(v)) throw new Error("Invalid registry");
  keys(v, "catalogVersion,generatedAt,revision,schemaVersion,skills");
  if (
    v.schemaVersion !== 1 ||
    !nonempty(v.catalogVersion) ||
    !nonempty(v.revision) ||
    !nonempty(v.generatedAt) ||
    Number.isNaN(Date.parse(v.generatedAt)) ||
    !Array.isArray(v.skills)
  ) {
    throw new Error("Invalid registry schema");
  }
  const ids = new Set();
  for (const s of v.skills) {
    if (!record(s)) throw new Error("Invalid skill");
    keys(s, "attribution,category,contentSha256,description,entrypoint,files,id,license,name,version");
    if (
      !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(s.id) ||
      ids.has(s.id) ||
      ![s.name, s.version, s.category, s.description, s.license, s.entrypoint].every(nonempty) ||
      !Array.isArray(s.files) ||
      !Array.isArray(s.attribution) ||
      !s.attribution.length ||
      !/^[a-f0-9]{64}$/.test(s.contentSha256)
    ) {
      throw new Error(`Invalid skill ${s.id}`);
    }
    ids.add(s.id);
    const paths = new Set();
    for (const f of s.files) {
      if (!record(f)) throw new Error("Invalid file record");
      keys(f, "path,sha256,size");
      normalizePath(f.path);
      if (paths.has(f.path) || !Number.isSafeInteger(f.size) || f.size < 0 || !/^[a-f0-9]{64}$/.test(f.sha256)) {
        throw new Error("Invalid file record");
      }
      for (const p of paths) {
        if (p.startsWith(f.path + "/") || f.path.startsWith(p + "/")) throw new Error("Path collision");
      }
      paths.add(f.path);
    }
    if (!paths.has(s.entrypoint)) throw new Error("Missing entrypoint");
    for (const a of s.attribution) {
      if (
        !record(a) ||
        Object.keys(a).sort().join(",") !== "name,text,url" ||
        ![a.name, a.text].every(nonempty) ||
        typeof a.url !== "string" ||
        new URL(a.url).protocol !== "https:"
      ) {
        throw new Error("Invalid attribution");
      }
    }
  }
}

// CLI: node grimoire-registry-validate.mjs <registry.json>
// Exits 0 and prints "valid" if the file passes; exits 1 and prints the
// thrown error message otherwise.
if (process.argv[1] && import.meta.url === (await import("node:url")).pathToFileURL(process.argv[1]).href) {
  const fs = await import("node:fs");
  const path = process.argv[2];
  if (!path) {
    console.error("usage: grimoire-registry-validate.mjs <registry.json>");
    process.exit(2);
  }
  try {
    const data = JSON.parse(fs.readFileSync(path, "utf8"));
    validateRegistry(data);
    console.log("valid");
  } catch (e) {
    console.error(String(e.message || e));
    process.exit(1);
  }
}
