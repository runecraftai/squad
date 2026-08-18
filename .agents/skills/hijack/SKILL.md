---
name: hijack
description: >-
  Agent-only playbook for a hijack operation: sequestering an existing open-source product whole and transforming it into a Runecraft product.
  Load before evaluating a product for acquisition into the Runecraft brand, before taking its code into this repo, before rebranding or relicensing an acquired product, and before deciding go or no-go on that acquisition.
user-invocable: false
metadata:
  internal: true
---

# Hijack operation

This skill is the single policy owner for acquiring an existing open-source product into the Runecraft brand.

A hijack is an acquisition, not a fork.
The product is taken whole and becomes a Runecraft product: Runecraft naming, Runecraft identity, Runecraft documentation, Runecraft's own license.
There is no upstream relationship afterward.
Nothing tracks upstream, nothing syncs from upstream, and nothing in the product surface refers to upstream.

Independence is the point of the operation.
Do not frame the result as a fork, a vendored dependency, or a downstream copy, and do not build a sync obligation into it.
Section 4 handles licensing; it is a procedure, not a relationship with upstream.

## 1. Is the product worth taking

Do not take anything before this stage produces a written verdict.

1. Classify the license from the upstream repository's own `LICENSE` file, never from a README badge or a package registry field.
   Permissive licenses (MIT, BSD, ISC, Apache-2.0) are acquirable.
   Copyleft licenses (GPL, LGPL, AGPL) and source-available licenses (BSL, SSPL, Elastic, "commons clause") are NOT acquirable without an explicit commander decision, because their terms follow the code into whatever ships next to it.
   Code with no license file at all is a hard stop: no permission was granted to anyone.
2. Name the Runecraft surface that will own the product and the concrete capability the unit gains.
   An acquisition without a named owning surface is a hard stop, because owning a product with no home is pure cost.
   "Interesting project" is not fit.
3. Record the bus factor and the maintenance reality.
   A single-contributor or abandoned project is a strong acquisition target precisely because there is no upstream future worth staying attached to.
   It also means no second reviewer ever read the code, so budget a real read of what is being taken.
4. Judge the code as code you are about to own outright.
   After the acquisition every bug, every vulnerability, and every unfinished corner is Runecraft's, with nobody upstream to fix it.
   Read enough to accept that ownership honestly.
5. Decide whether the whole product is worth taking, or none of it.
   Taking a product whole is the operation; taking a fragment and wiring it to an upstream remainder is not a hijack and reintroduces the dependency the operation exists to remove.
   If only one mechanism is worth having and the rest is dead weight, build that mechanism internally instead.
6. Check for a lighter path.
   If a small internal implementation covers the need, build it: owning an acquired product is permanent maintenance, and `AGENTS.md`'s simplest-direct-path rule applies here too.

## 2. Take the product

1. Take the product at a single coherent point: a release tag when one exists, otherwise a commit SHA.
   Take from a fixed point rather than a moving branch, because you are copying a finished thing once, not opening a channel.
2. Take the whole tracked product, excluding `.git`, dependency directories, and build output.
3. Land it in the Runecraft workspace as a Runecraft-owned component under its Runecraft name, following the existing layout of the surfaces around it.
4. Cut every upstream channel in the same pass: remote references, update checks, telemetry endpoints, issue-tracker links, funding links, and any config pointing at an upstream registry or domain.
   Anything left pointing outward is a live dependency you did not intend to keep.
5. Make the inherited test suite green under Runecraft ownership before the acquisition is considered complete.
   A product whose tests were never made green is unowned code, not an acquired product.
6. Commit the raw intake separately from the transformation, so the transformation diff is reviewable on its own.
   This is a review convenience, not a provenance obligation.

## 3. Transform it into a Runecraft product

1. Assign the Runecraft name before writing any code against it, and apply that name everywhere it executes: directory, package name, binary name, published scope, module paths, and every call site.
2. Rewrite the documentation as Runecraft documentation.
   The README, help text, and examples describe the Runecraft product and its supported use, with no upstream roadmap, upstream community, upstream issue tracker, or upstream history in them.
3. Remove upstream's identity from the product surface completely: names in output, logos, badges, support links, social handles, author fields, and brand strings.
4. Apply Runecraft's own license to the product.
   This repo's root `LICENSE` is the model for what a Runecraft-owned product ships.
5. Sequence a large transformation as two reviewable passes: names first (everything that executes), prose second (everything that reads).
   Both passes must land; a half-transformed product still carries upstream identity.
6. Add a guard test that fails when an upstream name reappears in an executing surface, so the transformation cannot silently regress.

## 4. Licensing and attribution

A hijack ships the product as fully Runecraft's.
The commander's directive (decision key `hijack-strip-attribution`, confirmed twice) is explicit: complete removal of all upstream copyright, author, and license identity from every copied file.
The product launches under Runecraft's own license with no upstream attribution on the product surface.
This is a commander decision, not an operator judgment call; do not second-guess it or re-add attribution on your own initiative.

1. Remove every upstream copyright line, author line, license header, and license notice from all copied source files.
   After this pass, no file in the product carries an upstream copyright or attribution string.
2. Remove any upstream `LICENSE`, `NOTICE`, `COPYING`, or license-directory files that arrived with the intake.
   Replace them with Runecraft's own `LICENSE` file, modeled on this repo's root `LICENSE`.
3. Apply Runecraft's own license uniformly to the entire product tree.
   Every file ships under Runecraft's license, not under the upstream license it carried before.
4. Remove any `SPDX-License-Identifier` headers that name the upstream license and replace them with Runecraft's license identifier, or remove them entirely.
5. Apache-2.0 `NOTICE` content and file-level modification markers are removed with the rest; the product no longer carries the Apache-2.0 license.
6. Legal risk flag: MIT and BSD licenses legally require their copyright notice and permission text to travel with redistributed copies.
   The commander has accepted this risk deliberately.
   Before publication, flag the licensing posture in the PR description so the legal exposure is visible and documented.
   Do not let this flag block execution; it is a documentation requirement, not a gate.
7. Escalate to the commander, with exact text and file path, for any copyleft or source-available license, any missing or ambiguous license, any file whose license differs from the repository root, and any third-party subtree carrying its own license.
   Do not resolve a licensing ambiguity by guessing in either direction.
8. Record the resulting license posture in the PR description so a later reader does not have to re-derive it.
   Note the commander's attribution-removal decision and its key (`hijack-strip-attribution`) in that record.

## 5. Integration into Runecraft surfaces

1. Wire the product into the Runecraft build and installation path so the unit consumes the Runecraft product and nothing else.
2. Remove any upstream package from dependencies and installation in the same change, so there is no window where both exist and either could win.
3. Add build and test coverage alongside the surrounding surfaces.
4. Give the product exactly one owner in the instruction surface, and add its load trigger where `squad-coding-guidelines` requires it: a one-line pointer, never a restatement of the product's own documentation.
5. Migrate call sites in one pass, under the Runecraft name.

## 6. After the acquisition

The product is Runecraft's. Treat it as code the unit wrote.

1. There is no upstream sync, on demand or otherwise.
   Do not diff against upstream, do not port upstream releases, and do not maintain a mapping back to an upstream version.
2. Upstream dying, going closed, changing direction, or being abandoned changes nothing here.
   That immunity is the return on the operation.
3. Fix bugs and security issues directly, as the owner.
   There is no upstream patch to wait for and no advisory feed that applies to a product that no longer exists outside Runecraft.
4. Evolve it for Runecraft's needs without regard for upstream compatibility.
   Divergence is expected and is not drift.
5. If a specific later upstream change ever looks genuinely valuable, treat it as a new idea to implement under Runecraft ownership, and escalate it as a fresh decision rather than reopening a dependency.

## 7. Go / no-go

Proceed only when all of these hold:

- The license is permissive, unambiguous, and confirmed from the upstream `LICENSE` file.
- A named Runecraft surface will own the product, and the gained capability is written down.
- Taking the product whole is the right move, not taking a fragment.
- The inherited test suite can be made green under Runecraft ownership.
- The unit accepts permanent ownership of the code, including its unfixed bugs.

Stop and escalate to the commander when any of these appear:

- Copyleft, source-available, missing, ambiguous, or mixed licensing.
- Patent, trademark, or trade-name exposure in the upstream name or assets.
- Third-party subtrees carrying their own licenses.
- A product whose upstream channels cannot be fully severed.

Abandon an in-flight acquisition when the inherited tests cannot be made green under Runecraft ownership, when the transformation cannot be completed without breaking the product, or when honest reading shows the unit is not willing to own the code permanently.
Abandoning is cheap before intake and expensive after, which is why section 1 is a written verdict rather than a formality.

## Appendix A: first application - SOVEREIGN

Product name: SOVEREIGN.
Publication target: `runecraftai/SOVEREIGN`.
The product will also carry the Runecraft brand on the nm/github surface.

The first acquisition target is LifeOS and Agentic OS (upstream `danielmiessler/LifeOS`, MIT, single-maintainer, high star count), whose mechanisms are organized as the SEED and PAUL frameworks.
Mechanisms in scope: the memory layer (Cortex), the skills layer, the hooks layer, the background daemon (Pulse), the goals and identity model (TELOS), and the assistant instruction layer (ISA).
Hermes, the sidecar, is excluded by explicit commander order and is not to be acquired, adapted, or referenced as a Runecraft surface.
Framework component names (TELOS, ISA, SEED, PAUL equivalents) remain as internal component names within SOVEREIGN.

Study the SEED and PAUL references (`github.com/ChristopherKahler/seed`, `/paul`, both MIT) for mechanisms only; reimplement clean-room, do not copy their files.

That execution is a separate task; this appendix is a pointer, not the acquisition plan.
