import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
	admit,
	answer,
	cleanup,
	cli,
	initStore,
	ledgerOf,
	PACKAGE_DIR,
	receipt,
	Service,
	startReady,
	stats,
	tempDir,
	until,
	waitEffect,
} from "./helpers.js";

afterEach(cleanup);

const APPROVAL = "dm1-test/lab-deploy/r1";

describe("approval survives a hard kill", () => {
	it("passes the executable Q4 proof end to end and leaves persisted evidence", async () => {
		const evidence = join(tempDir(), "evidence");
		const run = await new Promise<{ code: number; stderr: string }>((resolvePromise) => {
			execFile(
				"bash",
				[join(PACKAGE_DIR, "scripts", "lab-proof.sh")],
				{ env: { ...process.env, SQ_DURABLE_EVIDENCE_DIR: evidence }, timeout: 120_000 },
				(error, _stdout, stderr) => resolvePromise({ code: error === null ? 0 : Number(error.code ?? 1), stderr }),
			);
		});
		expect(run.code, run.stderr).toBe(0);
		const report = JSON.parse(readFileSync(join(evidence, "evidence.json"), "utf8"));
		expect(report.result).toBe("pass");
		const keys = report.facts.map((fact: { key: string }) => fact.key);
		expect(keys).toEqual(
			expect.arrayContaining(["kill_run_1", "kill_run_2", "pending_after_restart", "decision_receipt", "continuation", "effect", "resend", "counters_three_intervals"]),
		);
		const kills = report.facts.filter((fact: { key: string }) => fact.key.startsWith("kill_run_"));
		for (const kill of kills) expect(kill.value).toMatchObject({ signal: "SIGKILL", waitStatus: 137, gracefulShutdownLogged: false });
	});

	it("continues a decision recorded while the gate slept, after a crash, without new interaction", async () => {
		const store = await initStore();
		// A long interval: the decision lands while the gate sleeps, and the crash happens before it wakes.
		const first = await startReady(store, { pollMs: 3_000 });
		expect((await admit(store)).code).toBe(0);
		const recorded = await answer(store, APPROVAL, ["--revision", "r1", "--decision", "approve", "--response-id", "h1"]);
		expect(recorded.json.outcome).toBe("recorded");
		expect((await receipt(store, APPROVAL)).continuation).toBeNull();
		expect(await first.kill9()).toEqual({ code: null, signal: "SIGKILL" });

		await startReady(store, { pollMs: 3_000 });
		const view = await waitEffect(store, APPROVAL, 3_000 * 2 + 5_000);
		expect(view.effect.state).toBe("applied");
		expect(view.continuation.decisionReceiptId).toBe(recorded.json.receipt.receiptId);
		expect(ledgerOf(store).counters).toMatchObject({ appliedEffects: 1, distinctKeys: 1, receipts: 1 });
	});

	it("returns the recorded receipt to a resend after a crash between the decision commit and the reply", async () => {
		const store = await initStore();
		const crashing = Service.start(store, { env: { SQ_DURABLE_LAB_FAULT: "after-decision-commit" } });
		await cli(["ready", "--store", store, "--wait", "10"]);
		expect((await admit(store)).code).toBe(0);

		// The client keeps resending the same responseId while the service is down and after it returns.
		const pending = answer(store, APPROVAL, ["--revision", "r1", "--decision", "approve", "--response-id", "h-crash", "--timeout", "30"]);
		expect(await crashing.exited).toEqual({ code: null, signal: "SIGKILL" });
		await startReady(store);
		const result = await pending;
		expect(result.code).toBe(0);
		expect(result.json.outcome).toBe("duplicate");
		expect(result.json.receipt).toMatchObject({ responseId: "h-crash", decision: "approve" });

		const view = await waitEffect(store, APPROVAL);
		expect(view.decision.receiptId).toBe(result.json.receipt.receiptId);
		expect(ledgerOf(store).counters).toMatchObject({ appliedEffects: 1, receipts: 1 });
	});

	it("repeats the same key after a crash between applying the effect and recording its receipt", async () => {
		const store = await initStore();
		const crashing = Service.start(store, { env: { SQ_DURABLE_LAB_FAULT: "effect-applied-before-receipt" } });
		await cli(["ready", "--store", store, "--wait", "10"]);
		expect((await admit(store)).code).toBe(0);
		expect((await answer(store, APPROVAL, ["--revision", "r1", "--decision", "approve"])).code).toBe(0);
		expect(await crashing.exited).toEqual({ code: null, signal: "SIGKILL" });
		expect(ledgerOf(store).counters).toMatchObject({ invocations: 1, appliedEffects: 1 });

		await startReady(store);
		const view = await waitEffect(store, APPROVAL);
		expect(view.effect).toMatchObject({ state: "applied", attempts: 2 });
		expect(view.effect.receipt.attempt).toBe(2);
		expect(view.effect.receipt.effectKey).toBe(view.continuation.effectKey);
		expect(ledgerOf(store).counters).toEqual({ invocations: 2, applyCalls: 1, distinctKeys: 1, appliedEffects: 1, receipts: 1 });
	});

	it("keeps the first decision: duplicates get its receipt, conflicts and stale answers change nothing", async () => {
		const store = await initStore();
		await startReady(store);
		expect((await admit(store)).code).toBe(0);
		const pending = await cli(["approvals", "pending", "--store", store, "--json"]);
		const actionDigest = pending.json.pending[0].actionDigest;

		const stale = await answer(store, APPROVAL, ["--revision", "r0", "--decision", "approve"]);
		expect(stale.code).toBe(2);
		expect(stale.json.code).toBe("stale_revision");
		const otherAction = await answer(store, APPROVAL, ["--revision", "r1", "--decision", "approve", "--action-digest", "0".repeat(64)]);
		expect(otherAction.code).toBe(2);
		expect(otherAction.json.code).toBe("action_mismatch");
		expect(await stats(store)).toMatchObject({ seq: 1, decisions: 0, pending: 1 });

		const first = await answer(store, APPROVAL, ["--revision", "r1", "--decision", "approve", "--response-id", "a", "--action-digest", actionDigest]);
		expect(first.json.outcome).toBe("recorded");
		const second = await answer(store, APPROVAL, ["--revision", "r1", "--decision", "approve", "--response-id", "b"]);
		expect(second.json.outcome).toBe("duplicate");
		expect(second.json.receipt).toEqual(first.json.receipt);
		const conflicting = await answer(store, APPROVAL, ["--revision", "r1", "--decision", "reject", "--response-id", "c"]);
		expect(conflicting.code).toBe(2);
		expect(conflicting.json.code).toBe("conflict");
		expect(conflicting.json.detail.receipt).toEqual(first.json.receipt);

		const view = await waitEffect(store, APPROVAL);
		expect(view.decision).toEqual(first.json.receipt);
		expect(view.rejectedAttempts).toHaveLength(1);
		expect(view.rejectedAttempts[0]).toMatchObject({ responseId: "c", decision: "reject" });
		expect(ledgerOf(store).counters).toMatchObject({ appliedEffects: 1, receipts: 1 });
		expect(await stats(store)).toMatchObject({ decisions: 1, continuations: 1, effectReceipts: 1, pending: 0 });
	});

	it("ends a rejected mission without any effect", async () => {
		const store = await initStore();
		await startReady(store);
		expect((await admit(store)).code).toBe(0);
		expect((await answer(store, APPROVAL, ["--revision", "r1", "--decision", "reject"])).json.outcome).toBe("recorded");
		const final = await until(
			async () => {
				const view = await receipt(store, APPROVAL);
				return view.effect.state === "skipped" ? view : undefined;
			},
			5_000,
			"the gate to end the rejected mission",
		);
		expect(final).toMatchObject({ status: "rejected", missionStatus: "rejected", continuation: null });
		expect(final.effect.state).toBe("skipped");
		expect(ledgerOf(store).counters.invocations).toBe(0);
	});

	it("keeps the gate in the background and never abandoned on restart", async () => {
		const store = await initStore();
		await startReady(store);
		expect((await admit(store)).code).toBe(0);
		const mission = await cli(["mission", "--store", store, "--mission", "dm1-test", "--json"]);
		expect(mission.json.gate).toMatchObject({ kind: "sq.approval-gate", background: true, abandonOnRestart: null });
		expect(mission.json.mission.generation).toBe(1);
	});
});
