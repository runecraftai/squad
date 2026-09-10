---
name: api-and-interface-design
description: Design stable APIs and module interfaces with explicit contracts, validation, errors, compatibility, and retry semantics.
license: MIT
metadata:
  source: addyosmani/agent-skills
  source-license: MIT
  attribution: Reconstructed for Runecraft
---

# API and Interface Design

Use this skill when creating or changing REST, GraphQL, module, component, or team-facing interfaces.
Define the contract before implementation and make misuse difficult.

## Design

1. Identify consumers, ownership, observable behavior, and compatibility commitments.
2. Define typed inputs, outputs, errors, state variants, and examples.
3. Validate external data at the boundary and trust validated internal contracts.
4. Use predictable names, resource-oriented routes, and pagination for collections.
5. Prefer additive evolution and plan deprecation before removing behavior.
6. Decide retry and idempotency semantics for every state-changing operation.
7. Document the contract beside the implementation and test it through the public interface.

Use one consistent error shape.
Treat third-party responses as untrusted.
An idempotency key must be stable across retries, claimed atomically, bound to the request payload, and retained longer than every replay path.
Choose deliberately whether an in-flight duplicate is rejected, waits, or returns pending.

## Example

A task collection should expose `GET /api/tasks?page=1&pageSize=20` with a stable data and pagination shape.
A create operation should document whether retrying the same idempotency key replays the first result or reports a conflict.

## Do not use for

- An internal helper whose contract is already clear and unchanged.
- A visual naming cleanup with no consumer-facing behavior.
- Adding compatibility layers without a concrete consumer or migration need.
