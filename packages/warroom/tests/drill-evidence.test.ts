import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, setDefaultTimeout } from "bun:test";

setDefaultTimeout(30_000);
import { captureDigest, captureJson, DrillEvidenceError, readDrillRun, verifyCaptureJson } from "../src/drill-evidence.ts";
import { createReviewFixture, disposeFixture, type ReviewFixture } from "./fixtures/review-fixtures.ts";

let fixture: ReviewFixture;

beforeEach(() => { fixture = createReviewFixture(); });
afterEach(() => { disposeFixture(fixture); });

function variant(mutate: (db: Database) => void): string {
	const target = join(fixture.root, `variant-${Math.random().toString(16).slice(2)}.sqlite`);
	copyFileSync(fixture.drillDb, target);
	const db = new Database(target);
	try { mutate(db); } finally { db.close(); }
	return target;
}

function read(dbPath: string, overrides: { runId?: string; repoId?: string } = {}) {
	return readDrillRun({ dbPath, runId: overrides.runId ?? fixture.run1, repoId: overrides.repoId ?? fixture.repoId });
}

describe("restricted Drill evidence reader", () => {
	test("reads exactly the named run and records heads, steps, rounds and coverage", () => {
		const capture = read(fixture.drillDb);
		expect(capture.captureVersion).toBe(1);
		expect(capture.provenance).toBe("drill");
		expect(capture.run.id).toBe(fixture.run1);
		expect(capture.run.headSha).toBe(fixture.h1);
		expect(capture.run.deliveredHeadSha).toBe(fixture.h1);
		expect(capture.run.submittedHeadSha).toBe(fixture.h1);
		expect(capture.run.reviewApprovedHeadSha).toBe(fixture.baseSha);
		expect(capture.run.drillVersion).toBe("1.4.2");
		expect(capture.run.status).toBe("running");
		expect(capture.coverage.ci).toBe("ready");
		expect(capture.coverage.reviewHead).toBe("recorded");
		expect(capture.steps.map((step) => step.name)).toEqual(["intent", "rebase", "review", "test", "document", "lint", "push", "pr", "ci"]);
		expect(capture.steps.find((step) => step.name === "ci")?.status).toBe("running");
		expect(capture.steps.find((step) => step.name === "test")?.exitCode).toBe(0);
		expect(capture.steps.find((step) => step.name === "ci")?.exitCode).toBeNull();
		expect(capture.rounds).toHaveLength(1);
		expect(capture.eligibility).toEqual({ eligible: true, reasons: [] });
	});

	test("a running CI monitor with persisted readiness is eligible without waiting for merge", () => {
		const capture = read(fixture.drillDb);
		expect(capture.run.status).toBe("running");
		expect(capture.steps.find((step) => step.name === "ci")?.status).toBe("running");
		expect(capture.run.ciReadyAt).not.toBeNull();
		expect(capture.eligibility.eligible).toBe(true);
	});

	test("no-CI readiness is reported as no CI configured, never as green", () => {
		const dbPath = variant((db) => db.query("UPDATE runs SET ci_ready_at=NULL, ci_ready_no_ci=1 WHERE id=?").run(fixture.run1));
		const capture = read(dbPath);
		expect(capture.coverage.ci).toBe("no-ci");
		expect(capture.run.ciReadyNoCi).toBe(true);
		expect(capture.eligibility.eligible).toBe(true);
	});

	test("missing CI readiness, delivered-head disagreement, merged PR or an agent wait are ineligible", () => {
		const missingReady = read(variant((db) => db.query("UPDATE runs SET ci_ready_at=NULL, ci_ready_no_ci=0 WHERE id=?").run(fixture.run1)));
		expect(missingReady.eligibility.reasons).toContain("CI readiness was not recorded");

		const movedHead = read(variant((db) => db.query("UPDATE runs SET last_pushed_sha=? WHERE id=?").run(fixture.h2, fixture.run1)));
		expect(movedHead.eligibility.eligible).toBe(false);
		expect(movedHead.eligibility.reasons.join()).toContain("delivered head does not match");

		const merged = read(variant((db) => db.query("UPDATE runs SET pr_state='merged' WHERE id=?").run(fixture.run1)));
		expect(merged.eligibility.reasons).toContain("pull request is merged");

		const waiting = read(variant((db) => db.query("UPDATE runs SET awaiting_agent_since=? WHERE id=?").run(Date.now(), fixture.run1)));
		expect(waiting.eligibility.reasons).toContain("run is waiting on an agent decision");
	});

	test("a failed or unfinished earlier step is ineligible; a skipped step is recorded as skipped, not as executed", () => {
		const failed = read(variant((db) => db.query("UPDATE step_results SET status='failed', exit_code=1 WHERE id=?").run(`${fixture.run1}-test`)));
		expect(failed.eligibility.eligible).toBe(false);
		expect(failed.eligibility.reasons.join()).toContain("step test is failed");

		const unfinished = read(variant((db) => db.query("UPDATE step_results SET status='fixing' WHERE id=?").run(`${fixture.run1}-lint`)));
		expect(unfinished.eligibility.eligible).toBe(false);
		expect(unfinished.eligibility.reasons.join()).toContain("step lint is fixing, not completed");

		const skipped = read(variant((db) => db.query("UPDATE step_results SET status='skipped', exit_code=NULL WHERE id=?").run(`${fixture.run1}-document`)));
		expect(skipped.eligibility.eligible).toBe(true);
		expect(skipped.coverage.stepsSkipped).toEqual(["document"]);
		expect(skipped.steps.find((step) => step.name === "document")?.skipped).toBe(true);
	});

	test("a run missing a required step row is not eligible, because an absent step is never a success", () => {
		const missingTest = variant((db) => db.query("DELETE FROM step_results WHERE run_id=? AND step_name='test'").run(fixture.run1));
		const capture = read(missingTest);
		expect(capture.eligibility.eligible).toBe(false);
		expect(capture.eligibility.reasons).toContain("step test was not recorded");

		const noSteps = variant((db) => db.query("DELETE FROM step_results WHERE run_id=?").run(fixture.run1));
		const empty = read(noSteps);
		expect(empty.eligibility.eligible).toBe(false);
		expect(empty.eligibility.reasons.join()).toContain("step intent was not recorded");
		expect(empty.eligibility.reasons.join()).toContain("step review was not recorded");
	});

	test("rejects an unknown Drill database format with a concrete message", () => {
		const noRuns = join(fixture.root, "no-runs.sqlite");
		const db = new Database(noRuns);
		db.exec("CREATE TABLE repos (id TEXT PRIMARY KEY)");
		db.close();
		expect(() => read(noRuns)).toThrow(DrillEvidenceError);
		expect(() => read(noRuns)).toThrow(/missing table runs/);

		const oldColumns = variant((db) => { db.exec("ALTER TABLE runs DROP COLUMN last_pushed_sha"); });
		expect(() => read(oldColumns)).toThrow(/runs is missing last_pushed_sha/);
	});

	test("rejects an abbreviated head recorded in the database instead of salvaging it", () => {
		const dbPath = variant((db) => db.query("UPDATE runs SET head_sha=? WHERE id=?").run(fixture.h1.slice(0, 12), fixture.run1));
		expect(() => read(dbPath)).toThrow(/not a complete object id/);
	});

	test("requires the exact repository and run identity, never the newest run", () => {
		expect(() => read(fixture.drillDb, { runId: "run-missing" })).toThrow(/does not belong to repository/);
		expect(() => read(fixture.drillDb, { runId: fixture.run2, repoId: "repo-other" })).toThrow(/does not exist/);
		const capture = read(fixture.drillDb, { runId: fixture.run2 });
		expect(capture.run.id).toBe(fixture.run2);
		expect(capture.run.baseSha).toBe(fixture.h1);
		expect(capture.run.headSha).toBe(fixture.h2);
	});

	test("opens the Drill database read-only and leaves its bytes and journal untouched", () => {
		const before = createHash("sha256").update(readFileSync(fixture.drillDb)).digest("hex");
		const filesBefore = readdirSync(join(fixture.root, "drill")).filter((name) => name.startsWith("state.sqlite")).sort();
		read(fixture.drillDb);
		read(fixture.drillDb, { runId: fixture.run2 });
		const after = createHash("sha256").update(readFileSync(fixture.drillDb)).digest("hex");
		const filesAfter = readdirSync(join(fixture.root, "drill")).filter((name) => name.startsWith("state.sqlite")).sort();
		expect(after).toBe(before);
		expect(filesAfter).toEqual(filesBefore);
		expect(existsSync(`${fixture.drillDb}-wal`)).toBe(false);
	});

	test("detects capture tampering and refuses unknown capture versions", () => {
		const capture = read(fixture.drillDb);
		const json = captureJson(capture);
		const digest = captureDigest(capture);
		expect(verifyCaptureJson(json, digest).run.id).toBe(fixture.run1);
		expect(() => verifyCaptureJson(json.replace(fixture.run1, "run-evil"), digest)).toThrow(/digest does not match/);
		expect(() => verifyCaptureJson(JSON.stringify({ captureVersion: 2 }), digest)).toThrow(/unsupported evidence capture version/);
	});
});
