# sq-durable

Durable mission core for Squad over Pi Durable, at laboratory slice A1.
A1 proves one thing: a human approval survives a hard kill of the service, and the mission continues exactly once after it is answered.
It uses a laboratory store, a controlled executor with no network effect, and the terminal as the only answer surface.
It touches no Squad production state, script, backlog, or supervision path.

## Layout

- `src/core/` is the neutral core: mission identity and idempotent admission, the approval record and decision receipts, the effect record, the executor contract, and the approval gate task.
  It is built only from Pi Durable documents and one task, and it never imports Squad surfaces.
- `src/adapter/squad.ts` is the only module that names Squad concepts, such as the `sq` namespace and the `dm<generation>-<slug>` mission IDs.
- `src/service/` is the single-writer service: exclusive store ownership, startup with an explicit `resume()`, the readiness states, and the versioned local socket protocol.
- `src/lab/` holds the controlled ledger executor and the deterministic fault injection, which only stores created with `init --lab` accept.
- `src/cli.ts` is the `sq-durable` command; `sq-durable --help` owns commands, flags, and exit codes.

## Invariants

- Only the service opens and writes the Pi storage; every other surface sends commands over the store's socket.
- One live owner per store, enforced by a kernel lock that a killed process releases.
- A missing store or database is a failure and is never recreated.
- Ready means `resume()` has run and the engine answers on its mutation line, never just a live process.
- The first recorded decision for an approval and revision wins, and a resend returns its receipt.
- An effect is applied under one idempotent key, after asking the executor whether that key was already applied.
- The core's one-way dependency rule is enforced by `scripts/check-core-deps.mjs` and its negative fixture.

## Verification

From this directory: `npm ci`, `npm run build`, `npm test`, and `npm run test:dependency`.
`bash scripts/lab-proof.sh` runs the end-to-end Q4 proof and persists its evidence; its header lists the steps it checks.
