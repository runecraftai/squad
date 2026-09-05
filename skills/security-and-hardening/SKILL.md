---
name: security-and-hardening
description: Review a feature or codebase for trust-boundary abuse, input handling, secrets, authorization, and dependency risks.
license: MIT
metadata:
  source: addyosmani/agent-skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
---

# Security and Hardening

Use this skill when handling untrusted input, credentials, personal data, external integrations, file operations, or authentication.
Start with an abuse-oriented threat model instead of bolting on controls after implementation.

## Review

1. Map trust boundaries and name the assets at risk.
2. Run a compact STRIDE pass over each boundary.
3. Write misuse cases beside normal use cases and make the highest-risk one a test.
4. Validate input at system edges and authorize every protected action.
5. Check output encoding, secrets handling, error exposure, rate limits, security headers, SSRF, and dependency provenance.
6. Verify destructive paths against an allowlisted root, minimum depth, and ownership evidence.
7. Treat model output and third-party responses as untrusted data.

Ask before adding authentication flows, sensitive data, external services, uploads, CORS changes, or elevated permissions.
Never commit secrets or disable a security control for convenience.

## Report

Classify findings by exploitability, impact, reachability, and required action.
Separate confirmed vulnerabilities from hardening opportunities and unknowns.
Include a regression test or concrete verification command for every accepted fix.

## Example

Abuse case: a user-controlled webhook URL reaches a private metadata endpoint.

Verification: allow only approved HTTPS hosts, reject private resolved addresses, forbid redirects, and test the rejection path.

## Do not use for

- A purely stylistic refactor with no trust boundary.
- Generic compliance advice detached from the repository.
- Treating a clean dependency audit as proof that code is safe.
