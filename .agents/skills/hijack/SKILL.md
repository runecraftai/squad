---
name: hijack
description: >-
  Agent-only playbook for a hijack operation: bringing an existing open-source tool's mechanisms under the Runecraft umbrella brand as a Runecraft-owned fork.
  Load before evaluating a candidate tool for adoption, before forking or vendoring upstream code into this repo, before rebranding or relicensing a vendored fork, and before deciding go or no-go on an adoption.
user-invocable: false
metadata:
  internal: true
---

# Hijack operation

This skill is the single policy owner for adopting an existing open-source tool's mechanisms into the Runecraft brand.
A hijack is not a dependency upgrade and not a contribution to upstream.
It takes the mechanism, not the identity: the fork ships as a Runecraft product with Runecraft naming, Runecraft documentation, and Runecraft's own license, while every attribution the source license legally requires is preserved.

The vendoring mechanics are already proven in this repo.
`packages/*/vendor.json` is the provenance record format, and `.specs/features/squad-m6-vendoring/design.md` section 9 owns the on-demand upstream-sync procedure.
Follow those rather than inventing a parallel mechanism.

## 1. Candidate evaluation

Do not fork before this stage produces a written verdict.

1. Classify the license from the upstream repository's own `LICENSE` file, never from a README badge or a package registry field.
   Permissive licenses (MIT, BSD, ISC, Apache-2.0) are hijack-eligible.
   Copyleft licenses (GPL, LGPL, AGPL) and source-available licenses (BSL, SSPL, Elastic, "commons clause") are NOT eligible without an explicit commander decision, because their terms follow the fork into whatever ships next to it.
   Unlicensed code and code with no license file at all is the worst case: no permission was granted, so it is a hard stop.
2. Record maintenance health: last release date, commit cadence over the last twelve months, open issue and PR backlog, and whether releases are tagged and reproducible.
   A stale but complete tool is a fine hijack target; a fast-moving one costs more at every sync.
3. Record the bus factor.
   A single-contributor project is a common hijack target precisely because upstream continuity is unreliable, but it also means no second reviewer ever read the code, so budget a real read of what is being adopted.
4. Judge fit against the Runecraft surfaces that would consume it.
   Name the concrete surface the mechanism plugs into and the concrete capability the unit gains.
   "Interesting project" is not fit.
5. Size the surface being adopted.
   Prefer taking the mechanism (the data model, the loop, the protocol) over taking the whole distribution when only part of it earns its keep.
6. Check for a lighter path.
   If a small internal implementation covers the need, build it instead: a fork is durable maintenance cost, and `AGENTS.md`'s simplest-direct-path rule applies here too.

## 2. Fork mechanics

1. Pin an exact upstream point: a release tag when one exists, otherwise a commit SHA.
   Never vendor from a moving branch.
2. Copy tracked files only, from a reference clone at that pin, excluding `.git`, `node_modules`, and build output.
3. Vendor into this repo's workspace under `packages/<runecraft-name>/`, following the existing package layout.
4. Write the `vendor.json` provenance record with the upstream name, the pinned version or SHA, the source URL, the extraction date, the extraction method, content hashes, and the upstream license identifier.
   Provenance is what makes a later sync, a later audit, and a later legal question answerable; it is not optional and it is not a comment in a script.
5. Keep the upstream test suite running in-workspace from the first commit.
   A fork whose inherited tests were never made green is unowned code, not adopted code.
6. Commit the untouched vendored copy separately from the rebrand, so the rename diff is reviewable on its own.

## 3. Rebrand

1. Assign the Runecraft name before writing any code against the fork, and use it everywhere a name is executed: directory, package name, binary name, published scope, and every call site.
2. Decouple the documentation.
   Rewrite the README, help text, and examples so they describe the Runecraft product and its supported use, not upstream's roadmap, upstream's community, or upstream's issue tracker.
3. Remove upstream's brand identity from the shipped product surface: logos, badges, project names in output, telemetry endpoints, support links, funding links, and social handles.
4. Separate the rename from the deep prose rebrand when the fork is large.
   Names-only first (things that execute), prose second (things that read), each as its own reviewable pass.
   `.specs/features/squad-m6-vendoring/spec.md` records the precedent for that split, including which deferred surfaces it left behind.
5. Point every internal reference at the Runecraft name, and add a guard test that fails when an old name reappears in an executing surface.

## 4. License handling

Removing upstream's licensing identity from the product surface is part of the hijack.
Violating the source license is not, and no brand goal overrides that.

1. Apply Runecraft's own license to the fork as the license of the combined work.
   This repo's root `LICENSE` is the model for what a Runecraft-owned fork ships.
2. Preserve every attribution the source license legally requires.
   For MIT and BSD, the copyright notice and permission text must travel with redistributed copies of that code.
   Satisfy this with a third-party attribution file (`NOTICE`, or a `LICENSES/` entry) referenced from the fork, plus the `license` field in `vendor.json`.
   That keeps upstream's name out of the product surface while keeping the legally required notice in the distribution.
3. Never delete an upstream copyright line and ship the file as original Runecraft work.
   That is the one action in this playbook that converts a legitimate fork into an infringement.
4. Apache-2.0 additionally requires carrying `NOTICE` content and marking modified files; do both or do not adopt.
5. Any license that is not plainly permissive, any missing or ambiguous license, any file with a different license than the repository root, and any vendored third-party subtree inside the upstream tree are legal edge cases.
   Stop and escalate them as a commander decision with the exact text and file path.
   Do not resolve a licensing ambiguity by guessing in either direction.
6. Record the resulting license posture in the fork's `vendor.json` and in the PR description, so a later reader does not have to re-derive it.

## 5. Integration into Runecraft surfaces

1. Wire the fork into the workspace build and into bootstrap installation, so the unit consumes the workspace copy and never the upstream package.
2. Add a version floor or presence check at the call site, matching how the other vendored tools are gated.
3. Add build and test coverage in CI alongside the existing package jobs.
4. Give the mechanism exactly one owner in the instruction surface, and add its load trigger where `squad-coding-guidelines` requires it: a one-line pointer, never a restatement of the fork's own documentation.
5. Migrate call sites in one pass and remove the upstream dependency in the same change, so there is no window where both are installed and either could win.

## 6. Ops and maintenance

1. Upstream sync is on-demand, not scheduled.
   Follow `.specs/features/squad-m6-vendoring/design.md` section 9; it owns the diff, re-rename, floor bump, provenance update, and per-package commit sequence.
2. Re-apply the rename on every newly copied upstream file.
   Blind-copying upstream `package.json` or bin names is how a rebrand silently regresses.
3. Watch upstream for security advisories even while skipping feature syncs, since the fork inherits the vulnerability without inheriting the patch.
4. Treat every protocol or CLI-contract change upstream as a call-site change here, caught by the floors and compatibility probes rather than discovered in production.
5. When upstream dies, nothing breaks: that outcome is the point of the hijack, and the fork simply stops having a sync source.

## 7. Go / no-go

Proceed only when all of these hold:

- The license is permissive, unambiguous, and confirmed from the upstream `LICENSE` file.
- The named Runecraft surface and the concrete gained capability are both written down.
- An exact upstream pin exists.
- The inherited test suite can be made green in-workspace.
- The maintenance cost of syncing is acceptable against the value of the mechanism.

Stop and escalate to the commander when any of these appear:

- Copyleft, source-available, missing, ambiguous, or mixed licensing.
- A required attribution that cannot be satisfied without keeping upstream branding on the product surface.
- Patent, trademark, or trade-name exposure in the upstream name or assets.
- Vendored third-party subtrees inside upstream with their own licenses.
- A scope that has grown past the mechanism into adopting an entire product the unit has no use for.

Abandon an in-flight hijack when the inherited tests cannot be made green, when the rebrand cannot be completed without breaking the mechanism, or when the sync cost is discovered to exceed rewriting the mechanism outright.
Abandoning is cheap before the fork reaches the workspace and expensive after, which is why stage 1 evaluation is a written verdict rather than a formality.

## Appendix: first application

The first hijack target is the LifeOS and Agentic OS mechanism set (upstream `danielmiessler/LifeOS`, MIT, single-maintainer, high star count).
Mechanisms in scope for the port: the memory layer (Cortex), the skills layer, the hooks layer, the background daemon (Pulse), the goals and identity model (TELOS), and the assistant instruction layer (ISA).
Hermes, the sidecar, is excluded by explicit commander instruction and is not to be ported, adapted, or referenced as a Runecraft surface.
That execution is a separate task; this appendix is a pointer, not the migration spec.
