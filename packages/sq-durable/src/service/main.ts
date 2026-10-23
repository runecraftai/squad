import { randomUUID } from "node:crypto";
import { existsSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import type { Server } from "node:net";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels } from "@earendil-works/pi-ai/models";
import { createRegistry, defineExtension, Harness, ROOT_CONVERSATION_ID } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CUSTODY_TABLES, INSTALLED_CUSTODY_GENERATION } from "../adapter/legacy-writers.js";
import { LAB_CUSTODY_GENERATION, labMissionScheme, SQUAD_NAMESPACE } from "../adapter/squad.js";
import {
	type AdmissionRequest,
	type AnswerRequest,
	admitInTx,
	answerInTx,
	DomainError,
	defineDocuments,
	defineGate,
	plainCopy,
} from "../core/index.js";
import { LabLedgerExecutor, readLedger } from "../lab/executor.js";
import { createFaultInjector, FAULT_ENV, type FaultInjector, HOLD_ENV } from "../lab/fault.js";
import { custodyDecision, parseCustodyArgs } from "./custody-endpoint.js";
import { COMMANDS, type Command, MUTATING_COMMANDS, ok, PROTOCOL_VERSION, type Request, type Response, refuse } from "./protocol.js";
import { classify, type Phase } from "./readiness.js";
import { serveSocket } from "./socket.js";
import { acquireOwnership, createStore, type Ownership, resolveStore } from "./store.js";

const context = BACKGROUND_CONTEXT;
const PI_VERSION: string = createRequire(import.meta.url)("@earendil-works/pi-durable/package.json").version;
/** Deadline for the readiness read on the engine's mutation line. */
const LINE_DEADLINE_MS = 2_000;
/** How often the live owner checks that its ownership path still names the inode it locked. */
const OWNERSHIP_CHECK_MS = 1_000;

export type Logger = (event: string, data?: Record<string, unknown>) => void;

export function jsonLogger(incarnation: string): Logger {
	return (event, data = {}) => {
		process.stderr.write(`${JSON.stringify({ ts: Date.now(), pid: process.pid, incarnation, event, ...data })}\n`);
	};
}

function documentsAndGate(options: { pollMs: number; incarnation: string; ledgerPath: string; faults: FaultInjector }) {
	const documents = defineDocuments(SQUAD_NAMESPACE);
	const executor = new LabLedgerExecutor(options.ledgerPath);
	const gate = defineGate(SQUAD_NAMESPACE, {
		documents,
		executor,
		pollMs: options.pollMs,
		incarnation: options.incarnation,
		checkpoint: (point) => options.faults.checkpoint(point),
	});
	const registry = createRegistry();
	registry.install(defineExtension({ name: "sq-durable", tasks: [gate] }));
	return { documents, executor, gate, registry };
}

/** `sq-durable init`: create a store, its ownership file and identity, and its Pi storage. Never reuses a directory. */
export async function initStore(dir: string, options: { readonly lab: boolean }): Promise<{ storeId: string; dir: string; lab: boolean }> {
	const ownership = createStore(dir, options);
	try {
		const { documents, registry } = documentsAndGate({
			pollMs: 1_000,
			incarnation: "init",
			ledgerPath: ownership.paths.ledger,
			faults: createFaultInjector({ lab: options.lab, storeDir: ownership.paths.dir, faultSpec: undefined, holdSpec: undefined }),
		});
		const harness = await Harness.open(await openNodeSqliteStorage(ownership.paths.pi), { models: createModels(), registry }, context);
		try {
			const root = await harness.root(context);
			await root.commit(async (tx) => {
				const index = await tx.doc(documents.Index);
				index.storeId = ownership.storeId;
				index.lab = options.lab;
				index.createdAt = Date.now();
			}, context);
		} finally {
			await harness.close(context);
		}
		return { storeId: ownership.storeId, dir: ownership.paths.dir, lab: options.lab };
	} finally {
		ownership.release();
	}
}

export type ServiceOptions = {
	readonly storeDir: string;
	readonly pollMs: number;
	readonly env: NodeJS.ProcessEnv;
};

export class StartRefused extends Error {
	constructor(message: string) {
		super(message);
		this.name = "StartRefused";
	}
}

/**
 * `sq-durable serve`: the single writer of one store. Startup order:
 * 1 exclusivity, 2 open existing storage (never a new one), 3 definitions, 4 `Harness.open` (recovers without
 * dispatching), 5-6 diagnostics, 7 projections (none in A1), 8 explicit `resume()`, 9 readiness published.
 * Resolves once the service is running; the process then lives until shutdown or failure.
 */
export async function runService(options: ServiceOptions): Promise<void> {
	const incarnation = randomUUID();
	const log = jsonLogger(incarnation);
	const startedAt = Date.now();
	let phase: Phase = "locking";
	let failure: string | undefined;
	let openedAt: number | undefined;
	let resumedAt: number | undefined;

	// 1. Exclusivity, before anything reads or writes the store.
	const paths = resolveStore(options.storeDir);
	let ownership: Ownership;
	try {
		ownership = acquireOwnership(paths);
	} catch (error) {
		throw new StartRefused(error instanceof Error ? error.message : String(error));
	}
	let faults: FaultInjector;
	try {
		faults = createFaultInjector({
			lab: ownership.lab,
			storeDir: paths.dir,
			faultSpec: options.env[FAULT_ENV],
			holdSpec: options.env[HOLD_ENV],
		});
	} catch (error) {
		ownership.release();
		throw new StartRefused(error instanceof Error ? error.message : String(error));
	}
	log("lock_acquired", { store: paths.dir, storeId: ownership.storeId, lab: ownership.lab, faults: faults.armed, holds: faults.holds });
	faults.checkpoint("after-lock");

	const { documents, executor, gate, registry } = documentsAndGate({ pollMs: options.pollMs, incarnation, ledgerPath: paths.ledger, faults });
	let harness: Harness | undefined;
	let server: Server | undefined;
	let exiting = false;

	const exit = (code: number) => {
		if (exiting) return;
		exiting = true;
		server?.close();
		const done = () => {
			ownership.release();
			process.exit(code);
		};
		if (harness === undefined) done();
		else harness.close(context).then(done, done);
	};
	const fail = (reason: string) => {
		if (phase === "failed") return;
		phase = "failed";
		failure = reason;
		log("failed", { reason });
		// Answer probes with `failed` briefly, then leave with a failure code.
		setTimeout(() => exit(1), 200).unref();
	};

	// The socket comes up first so a probe can see `starting`; it is the stale one of a dead owner only if we hold the
	// lock, which we do.
	rmSync(paths.socket, { force: true });
	server = await serveSocket(paths.socket, (request) => handle(request));
	log("socket_listening", { socket: paths.socket });

	const ownershipTimer = setInterval(() => {
		if (!ownership.stillOwned()) fail(`ownership file ${paths.owner} no longer names the locked inode; stopping the engine`);
	}, OWNERSHIP_CHECK_MS);
	ownershipTimer.unref();

	process.on("SIGTERM", () => {
		log("shutdown", { mode: "graceful", signal: "SIGTERM" });
		exit(0);
	});
	process.on("SIGINT", () => {
		log("shutdown", { mode: "graceful", signal: "SIGINT" });
		exit(0);
	});

	try {
		// 2. Existing storage only: a missing database is a failure, never a new store.
		phase = "opening";
		if (!existsSync(paths.pi)) throw new Error(`Pi storage ${paths.pi} is missing; it is never recreated`);
		const storage = await openNodeSqliteStorage(paths.pi);
		// 3-4. Definitions are registered; open recovers records and counts restarts without dispatching.
		harness = await Harness.open(
			storage,
			{
				models: createModels(),
				registry,
				onReport: (error, info) => log("engine_report", { type: info.type, error: error instanceof Error ? error.message : String(error) }),
			},
			context,
		);
		harness.closed.then((end) => {
			if (end.reason === "failed") fail(`engine session failed: ${end.error instanceof Error ? end.error.message : String(end.error)}`);
		});
		const index = await harness.snapshot(documents.Index, context);
		if (index === undefined || index.storeId !== ownership.storeId) {
			throw new Error(`store identity mismatch: ownership says ${ownership.storeId}, storage says ${index?.storeId ?? "nothing"}`);
		}
		if (index.lab !== ownership.lab) throw new Error("laboratory mark differs between ownership file and storage");
		phase = "opened";
		openedAt = Date.now();
		faults.checkpoint("after-open");

		// 5-6. Diagnostics only: classify, never consult the executor or write receipts here.
		const inspection = await harness.inspect(context);
		const blocked = inspection.tasks.filter((task) => task.state.kind === "blocked");
		const missions = await missionViews();
		log("opened", {
			lastSeq: index.seq,
			missions: missions.length,
			blocked: blocked.map((task) => ({ id: task.record.id, kind: task.record.kind, state: task.state })),
			effectsWithoutReceipt: missions
				.filter((m) => m.effect !== null && m.effect.attempts > 0 && m.effect.receipt === null)
				.map((m) => ({ missionId: m.missionId, attempts: m.effect?.attempts })),
		});

		// 8. Explicit resume; a laboratory hold keeps a live process from ever reaching it.
		if (faults.holding("resume")) {
			log("lab_hold", { hold: "resume" });
			return;
		}
		faults.checkpoint("before-resume");
		harness.resume();
		resumedAt = Date.now();
		phase = "resumed";
		log("resumed", { startupMs: resumedAt - startedAt });
	} catch (error) {
		fail(error instanceof Error ? error.message : String(error));
	}

	async function missionViews() {
		if (harness === undefined) return [];
		const index = await harness.snapshot(documents.Index, context);
		const views = [];
		for (const missionId of index?.missions ?? []) {
			const mission = await harness.snapshot(documents.Mission, missionId, context);
			if (mission !== undefined) views.push(plainCopy(mission));
		}
		return views;
	}

	async function approvalViews() {
		if (harness === undefined) return [];
		const views = [];
		for (const mission of await missionViews()) {
			const approval = await harness.snapshot(documents.Approval, mission.approvalId, context);
			if (approval !== undefined) views.push({ mission, approval: plainCopy(approval) });
		}
		return views;
	}

	async function probe() {
		const base = {
			protocol: PROTOCOL_VERSION,
			pi: PI_VERSION,
			custodyGeneration: LAB_CUSTODY_GENERATION,
			custody: { installed: INSTALLED_CUSTODY_GENERATION, generations: CUSTODY_TABLES.map((table) => table.generation) },
			storeId: ownership.storeId,
			lab: ownership.lab,
			incarnation,
			pid: process.pid,
			pollMs: options.pollMs,
			startedAt,
			openedAt: openedAt ?? null,
			resumedAt: resumedAt ?? null,
			faults: faults.armed,
			holds: faults.holds,
		};
		if (harness === undefined || (phase !== "opened" && phase !== "resumed")) {
			return { ...base, ...classify({ phase, failure, holds: faults.holds }), lastSeq: null };
		}
		let inspection: Awaited<ReturnType<Harness["inspect"]>> | undefined;
		try {
			inspection = await withDeadline(harness.inspect(context), LINE_DEADLINE_MS);
		} catch {
			inspection = undefined;
		}
		const blocked: string[] = [];
		const parked: string[] = [];
		const affectedTasks: number[] = [];
		for (const task of inspection?.tasks ?? []) {
			if (task.state.kind !== "blocked") continue;
			const label = `${task.record.kind}#${task.record.id} (${task.state.reason})`;
			(task.state.reason === "restart_limit" ? parked : blocked).push(label);
			affectedTasks.push(task.record.id);
		}
		const now = Date.now();
		const views = await approvalViews();
		const decidedWithoutContinuation = views
			.filter(({ approval }) => approval.status === "approved" && approval.continuation === null && approval.decision !== null)
			.map(({ approval }) => ({
				approvalId: approval.approvalId,
				decidedAt: approval.decision?.recordedAt ?? 0,
				overdue: now - (approval.decision?.recordedAt ?? now) > 2 * options.pollMs,
			}));
		const reconcile = views.filter(({ mission }) => mission.status === "reconcile").map(({ mission }) => mission.missionId);
		const index = await harness.snapshot(documents.Index, context);
		const readiness = classify({
			phase,
			failure,
			scheduling: inspection?.scheduling,
			lineRead: inspection !== undefined,
			blocked,
			parked,
			reconcile,
			overdue: decidedWithoutContinuation.filter((item) => item.overdue).map((item) => item.approvalId),
			holds: faults.holds,
		});
		return {
			...base,
			...readiness,
			lastSeq: index?.seq ?? 0,
			blocked,
			parked,
			reconcile,
			decidedWithoutContinuation,
			affected: {
				missions: reconcile,
				approvals: decidedWithoutContinuation.filter((item) => item.overdue).map((item) => item.approvalId),
				tasks: affectedTasks,
			},
		};
	}

	async function handle(request: Request): Promise<Response> {
		const id = request.id;
		const args = request.args ?? {};
		if (!(COMMANDS as readonly string[]).includes(request.command)) {
			return refuse(id, "unknown_command", `unknown command ${JSON.stringify(request.command)}; known: ${COMMANDS.join(", ")}`);
		}
		const command = request.command as Command;
		if (command === "ready") return ok(id, await probe());
		if (command === "custody") {
			// Answered in every phase: a service that cannot confirm a condition says so, and the decision refuses.
			const parsed = parseCustodyArgs(args);
			if ("error" in parsed) return refuse(id, "bad_request", parsed.error);
			const decision = await custodyDecision(parsed.query, {
				state: async () => {
					const report = await probe();
					return { state: report.state, reasons: report.reasons };
				},
				mission: async (missionId) => (harness === undefined ? undefined : harness.snapshot(documents.Mission, missionId, context)),
			});
			if (!decision.allowed) log("custody_refused", { missionId: decision.id, responsibility: decision.responsibility, code: decision.code });
			return ok(id, decision);
		}
		if (phase === "failed") return refuse(id, "failed", `service failed: ${failure ?? "unknown"}`);
		if (harness === undefined || phase === "locking" || phase === "opening") {
			return refuse(id, "not_ready", `service is starting (${phase}); the store is not open yet`);
		}
		if (MUTATING_COMMANDS.includes(command) && phase !== "resumed") {
			return refuse(id, "not_ready", `service is starting (${phase}): resume() not done, ${command} refused and nothing was written`);
		}
		const engine = harness;
		try {
			switch (command) {
				case "admit": {
					const admission: AdmissionRequest = {
						missionId: String(args.missionId ?? ""),
						action: args.action as AdmissionRequest["action"],
						revision: String(args.revision ?? ""),
					};
					const root = await engine.root(context);
					const result = await root.commit(
						(tx) =>
							admitInTx(tx, admission, {
								documents,
								gate,
								scheme: labMissionScheme(),
								now: Date.now(),
								incarnation,
								conversationId: ROOT_CONVERSATION_ID as unknown as number,
							}),
						context,
					);
					log("admitted", { ...result });
					if (result.outcome === "created") faults.checkpoint("after-admit-commit");
					return ok(id, result);
				}
				case "answer": {
					const answer: AnswerRequest = {
						approvalId: String(args.approvalId ?? ""),
						revision: String(args.revision ?? ""),
						decision: args.decision as AnswerRequest["decision"],
						responseId: String(args.responseId ?? ""),
						origin: typeof args.origin === "string" && /^[a-z]+:[A-Za-z0-9._-]{1,64}$/.test(args.origin) ? args.origin : "terminal:unknown",
						...(typeof args.actionDigest === "string" ? { actionDigest: args.actionDigest } : {}),
					};
					const root = await engine.root(context);
					const result = await root.commit((tx) => answerInTx(tx, answer, { documents, now: Date.now(), incarnation }), context);
					log("answered", { outcome: result.outcome, approvalId: answer.approvalId, receiptId: result.receipt.receiptId });
					if (result.outcome === "recorded") faults.checkpoint("after-decision-commit");
					if (result.outcome === "conflict") {
						return refuse(id, "conflict", `approval ${answer.approvalId} already has decision ${result.receipt.decision}; this answer was recorded as a rejected attempt`, result);
					}
					return ok(id, result);
				}
				case "pending": {
					const pending = (await approvalViews())
						.filter(({ approval }) => approval.status === "pending")
						.map(({ approval }) => ({
							approvalId: approval.approvalId,
							missionId: approval.missionId,
							revision: approval.revision,
							action: approval.action,
							actionDigest: approval.actionDigest,
							requestedSeq: approval.requestedSeq,
							presentableSince: approval.presentation?.presentableSince ?? null,
						}));
					return ok(id, { pending });
				}
				case "receipt": {
					const approvalId = String(args.approvalId ?? "");
					const approval = await engine.snapshot(documents.Approval, approvalId, context);
					if (approval === undefined || approval.status === "absent") return refuse(id, "not_found", `approval ${approvalId} does not exist`);
					const mission = await engine.snapshot(documents.Mission, approval.missionId, context);
					return ok(id, {
						approvalId,
						missionId: approval.missionId,
						status: approval.status,
						missionStatus: mission?.status ?? null,
						decision: approval.decision,
						continuation: approval.continuation,
						effect: mission?.effect ?? null,
						rejectedAttempts: approval.rejectedAttempts,
					});
				}
				case "mission": {
					const missionId = String(args.missionId ?? "");
					const mission = await engine.snapshot(documents.Mission, missionId, context);
					if (mission === undefined || mission.status === "absent") return refuse(id, "not_found", `mission ${missionId} does not exist`);
					const approval = await engine.snapshot(documents.Approval, mission.approvalId, context);
					const task = await engine.getTask(mission.gateTaskId as never, context);
					const gateView =
						task === undefined
							? null
							: {
									id: task.id,
									kind: task.kind,
									state: task.state,
									background: task.background,
									abandonOnRestart: task.abandonOnRestart ?? null,
									restarts: task.restarts ?? 0,
								};
					return ok(id, { mission, approval: approval ?? null, gate: gateView });
				}
				case "stats": {
					const views = await approvalViews();
					const index = await engine.snapshot(documents.Index, context);
					const inspection = await engine.inspect(context);
					let ledger: unknown;
					try {
						ledger = readLedger(executor.path).counters;
					} catch (error) {
						ledger = { error: error instanceof Error ? error.message : String(error) };
					}
					return ok(id, {
						seq: index?.seq ?? 0,
						missions: views.length,
						pending: views.filter(({ approval }) => approval.status === "pending").length,
						decisions: views.filter(({ approval }) => approval.decision !== null).length,
						rejectedAttempts: views.reduce((sum, { approval }) => sum + approval.rejectedAttempts.length, 0),
						continuations: views.filter(({ approval }) => approval.continuation !== null).length,
						effectAttempts: views.reduce((sum, { mission }) => sum + (mission.effect?.attempts ?? 0), 0),
						effectReceipts: views.filter(({ mission }) => mission.effect?.receipt != null).length,
						liveGates: inspection.tasks.filter((task) => task.record.kind === `${SQUAD_NAMESPACE}.approval-gate`).length,
						executor: ledger,
					});
				}
			}
		} catch (error) {
			if (error instanceof DomainError) return refuse(id, error.code, error.message, error.detail);
			// `phase` changes asynchronously when the engine fails during the command.
			if ((phase as Phase) === "failed") return refuse(id, "failed", `service failed: ${failure ?? "unknown"}`);
			throw error;
		}
		return refuse(id, "unknown_command", `unhandled command ${command}`);
	}

}

function withDeadline<T>(promise: Promise<T>, ms: number): Promise<T> {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`deadline of ${ms} ms passed`)), ms);
		promise.then(
			(value) => {
				clearTimeout(timer);
				resolve(value);
			},
			(error) => {
				clearTimeout(timer);
				reject(error);
			},
		);
	});
}
