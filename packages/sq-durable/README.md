# sq-durable

Durable mission core for Squad over Pi Durable, at laboratory slice A1 plus custody slice A2.0.
A1 proves one thing: a human approval survives a hard kill of the service, and the mission continues exactly once after it is answered.
It uses a laboratory store, a controlled executor with no network effect, and the terminal as the only answer surface.
A2.0 adds custody: no legacy Squad writer can act on a responsibility the engine owns for a durable mission.
Neither slice migrates a mission, writes production state, or changes supervision behavior for any legacy task.

## Layout

- `src/core/` is the neutral core: mission identity and idempotent admission, the approval record and decision receipts, the effect record, the executor contract, and the approval gate task.
  It is built only from Pi Durable documents and one task, and it never imports Squad surfaces.
- `src/adapter/squad.ts` is the only module that names Squad concepts, such as the `sq` namespace and the `dm<generation>-<slug>` mission IDs.
- `src/service/` is the single-writer service: exclusive store ownership, startup with an explicit `resume()`, the readiness states, and the versioned local socket protocol.
- `src/lab/` holds the controlled ledger executor with no network effect, and the deterministic fault injection that only a store created with `init --lab` accepts.
- `src/core/custody.ts` decides custody from a mission ID, the immutable table of its generation, and the writer's loaded generation; `src/service/custody-endpoint.ts` adds only what the engine alone can confirm.
- `src/adapter/legacy-writers.ts` owns the Squad responsibilities, the published generation tables, and the inventory of every legacy writer, which it derives from `bin/` and checks for drift.
- `bin/sq-durable-custody.sh` is the one shell consultation point every inventoried writer calls before it mutates; its header owns the shell contract.
- `src/cli.ts` is the `sq-durable` command; `sq-durable --help` owns commands, flags, and exit codes.

## Invariants

- Only the service opens and writes the Pi storage, except `init`, which writes it once while it holds the ownership lock of the store it just created; every other surface sends its commands over the store's socket, and `ledger` reads only the executor's own ledger file.
- One live owner per store, enforced by a kernel lock that a killed process releases.
- A missing store or database is a failure and is never recreated.
- Ready means `resume()` has run and the engine answers on its mutation line, never just a live process.
- The first recorded decision for an approval and revision wins, and a resend returns its receipt.
- An effect is applied under one idempotent key, after asking the executor whether that key was already applied.
- The core's one-way dependency rule is enforced by `scripts/check-core-deps.mjs` and its negative fixture.
- Authority is fixed at birth: an ID matching `^dm[0-9]+-` carries its custody generation, and only that generation's table decides each responsibility.
- A published table is never edited; a new slice publishes a new generation and bumps the shell library's generation with it.
- A stopped service, a missing projection, or a missing `.meta` never grants legacy authority; a legacy ID is never affected and costs no subprocess.
- Every refusal exits 3 with an explicit message and a line in `data/durable/custody-refusals.log`, before any write.
- A long-running writer that loaded another custody generation than the one installed is refused on every durable mission until it restarts.

## Verification

From this directory: `npm ci`, `npm run build`, `npm test`, and `npm run test:dependency`.
`bash scripts/lab-proof.sh` runs the end-to-end Q4 proof and persists its evidence; its header lists the steps it checks.
`sq-durable custody inventory --repo <squad-repo>` prints the derived writer inventory and any violation; the custody suites run real `bin/` scripts against throwaway bases.
