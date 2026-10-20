import { Database } from "bun:sqlite";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Warroom } from "../../src/core.ts";
import { type CaptureResult, captureReview } from "../../src/review.ts";

/**
 * Test fixtures. These are synthetic Git repositories and a synthetic Drill-shaped SQLite
 * database; they are not a real Drill execution, not a real change under review, and every
 * capture built through `captureFixture` is stored with `fixture` provenance, which the domain
 * always refuses as evidence for human acceptance.
 */

const GIT_ENV = {
	GIT_AUTHOR_NAME: "Fixture",
	GIT_AUTHOR_EMAIL: "fixture@example.test",
	GIT_COMMITTER_NAME: "Fixture",
	GIT_COMMITTER_EMAIL: "fixture@example.test",
	GIT_CONFIG_NOSYSTEM: "1",
	GIT_TERMINAL_PROMPT: "0",
};

export interface ReviewFixture {
	root: string;
	repo: string;
	drillDb: string;
	drillLogs: string;
	dataDir: string;
	dbPath: string;
	warroom: Warroom;
	initiativeId: string;
	planRevisionId: string;
	baseSha: string;
	h1: string;
	h2: string;
	repoId: string;
	run1: string;
	run2: string;
}

function git(repo: string, args: string[]): string {
	const result = spawnSync("git", ["--no-pager", ...args], { cwd: repo, env: { ...process.env, ...GIT_ENV }, encoding: "utf8", shell: false });
	if (result.status !== 0) throw new Error(`fixture git ${args.join(" ")} failed: ${result.stderr}`);
	return result.stdout.trim();
}

function commit(repo: string, message: string): string {
	git(repo, ["add", "-A"]);
	git(repo, ["commit", "-q", "-m", message]);
	return git(repo, ["rev-parse", "HEAD"]);
}

function createGitRepo(root: string, withUnreviewable: boolean): { repo: string; baseSha: string; h1: string; h2: string } {
	const repo = join(root, "repo");
	mkdirSync(join(repo, "src"), { recursive: true });
	mkdirSync(join(repo, "legacy"), { recursive: true });
	git(repo, ["init", "-q", "-b", "main"]);
	writeFileSync(join(repo, "README.md"), "# Fixture project\n\nSynthetic repository used only by tests.\n");
	writeFileSync(join(repo, "src", "hello.ts"), "export function hello(name: string) {\n\treturn `hello ${name}`;\n}\n");
	writeFileSync(join(repo, "legacy", "old-name.ts"), "export const value = 1;\n");
	const baseSha = commit(repo, "base");

	git(repo, ["checkout", "-q", "-b", "review"]);
	mkdirSync(join(repo, "docs"), { recursive: true });
	mkdirSync(join(repo, "config"), { recursive: true });
	mkdirSync(join(repo, "tests"), { recursive: true });
	writeFileSync(join(repo, "src", "hello.ts"), "export function hello(name: string) {\n\treturn `hello, ${name}!`;\n}\n");
	writeFileSync(join(repo, "docs", "guide.md"), "# Guide\n\nFixtures demonstrate review navigation, not a real delivery.\n");
	writeFileSync(join(repo, "config", "settings.json"), JSON.stringify({ enabled: true, retries: 2 }, null, 2));
	writeFileSync(join(repo, "tests", "hello.test.ts"), "import { expect, test } from \"bun:test\";\n\ntest(\"hello\", () => expect(true).toBe(true));\n");
	writeFileSync(join(repo, "docs", "path with spaces e acentuação.txt"), "line one\nline two\nline three\n");
	writeFileSync(join(repo, "docs", "empty.txt"), "");
	if (withUnreviewable) writeFileSync(join(repo, "docs", "binary.bin"), Buffer.from([0, 1, 2, 3, 0, 255]));
	rmSync(join(repo, "legacy", "old-name.ts"));
	writeFileSync(join(repo, "legacy", "new-name.ts"), "export const value = 1;\n");
	if (withUnreviewable) symlinkSync("../README.md", join(repo, "docs", "readme-link"));
	const h1 = commit(repo, "head one");

	writeFileSync(join(repo, "src", "hello.ts"), "export function hello(name: string) {\n\tif (!name) throw new Error(\"name required\");\n\treturn `hello, ${name}!`;\n}\n");
	writeFileSync(join(repo, "README.md"), "# Fixture project\n\nSynthetic repository used only by tests.\n\nFixed after review.\n");
	const h2 = commit(repo, "head two");

	git(repo, ["tag", "h1", h1]);
	git(repo, ["tag", "h2", h2]);
	return { repo, baseSha, h1, h2 };
}

function createDrillDb(root: string, baseSha: string, h1: string, h2: string): { dbPath: string; drillLogs: string } {
	const drillDir = join(root, "drill");
	mkdirSync(drillDir, { recursive: true });
	const logs = join(drillDir, "logs");
	mkdirSync(logs, { recursive: true });
	writeFileSync(join(logs, "test.log"), "fixture log line\n");
	const dbPath = join(drillDir, "state.sqlite");
	const db = new Database(dbPath, { create: true });
	db.exec(`
CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE, upstream_url TEXT NOT NULL, fork_url TEXT, default_branch TEXT NOT NULL DEFAULT 'main', created_at INTEGER NOT NULL);
CREATE TABLE runs (
  id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL, head_sha TEXT NOT NULL, base_sha TEXT NOT NULL,
  submitted_head_sha TEXT, drill_version TEXT, drill_build_sha TEXT, review_approved_head_sha TEXT, status TEXT NOT NULL DEFAULT 'pending',
  pr_url TEXT, pr_state TEXT, pr_state_observed_at INTEGER, ci_ready_at INTEGER, ci_ready_no_ci INTEGER NOT NULL DEFAULT 0,
  specialized_review_enabled INTEGER NOT NULL DEFAULT 0, last_pushed_sha TEXT, push_target_kind TEXT, push_target_fingerprint TEXT,
  push_ref TEXT, last_pushed_at INTEGER, push_generation INTEGER, push_active INTEGER NOT NULL DEFAULT 0,
  terminal_head_verified_at INTEGER, error TEXT, awaiting_agent_since INTEGER, parked_ms INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL, step_order INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
  exit_code INTEGER, duration_ms INTEGER, log_path TEXT, findings_json TEXT, error TEXT, started_at INTEGER, completed_at INTEGER, last_activity_at INTEGER,
  last_activity TEXT, agent_pid INTEGER, auto_fix_limit INTEGER);
CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL, trigger_type TEXT NOT NULL, findings_json TEXT,
  reviewed_head_sha TEXT, user_findings_json TEXT, selected_finding_ids TEXT, selection_source TEXT, fix_summary TEXT, duration_ms INTEGER NOT NULL, created_at INTEGER NOT NULL);
`);
	const now = Date.now();
	db.query("INSERT INTO repos(id,working_path,upstream_url,default_branch,created_at) VALUES(?,?,?,?,?)").run("repo-1", join(root, "repo"), "https://example.test/fixture/repo.git", "main", now);
	const insertRun = (id: string, head: string, base: string) => {
		db.query(`INSERT INTO runs(id,repo_id,branch,head_sha,base_sha,submitted_head_sha,drill_version,drill_build_sha,review_approved_head_sha,status,pr_url,pr_state,ci_ready_at,ci_ready_no_ci,last_pushed_sha,awaiting_agent_since,created_at,updated_at)
			VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
			.run(id, "repo-1", "review", head, base, head, "1.4.2", "fixture-build", base, "running", "https://example.test/fixture/repo/pull/1", "open", now, 0, head, null, now, now);
		const steps: Array<[string, number, string, number | null]> = [
			["intent", 1, "completed", 0],
			["rebase", 2, "completed", 0],
			["review", 3, "completed", 0],
			["test", 4, "completed", 0],
			["document", 5, "completed", 0],
			["lint", 6, "completed", 0],
			["push", 7, "completed", 0],
			["pr", 8, "completed", 0],
			["ci", 9, "running", null],
		];
		for (const [name, order, status, exitCode] of steps) {
			db.query("INSERT INTO step_results(id,run_id,step_name,step_order,status,exit_code,log_path,started_at,completed_at) VALUES(?,?,?,?,?,?,?,?,?)")
				.run(`${id}-${name}`, id, name, order, status, exitCode, name === "test" ? join(logs, "test.log") : null, now, status === "completed" ? now : null);
		}
		db.query("INSERT INTO step_rounds(id,step_result_id,round,trigger_type,reviewed_head_sha,duration_ms,created_at) VALUES(?,?,?,?,?,?,?)")
			.run(`${id}-round-1`, `${id}-review`, 1, "initial", base, 1000, now);
	};
	// The second run records the first head as its Drill base, so the Drill base and the human review base disagree.
	insertRun("run-1", h1, baseSha);
	insertRun("run-2", h2, h1);
	db.close();
	chmodSync(dbPath, 0o600);
	return { dbPath, drillLogs: logs };
}

export interface FixtureOptions {
	/** Set false for acceptance flows: a packet with any unreviewable object blocks total acceptance. */
	withUnreviewable?: boolean;
}

export function createReviewFixture(options: FixtureOptions = {}): ReviewFixture {
	const root = mkdtempSync(join(tmpdir(), "warroom-review-"));
	const gitFixture = createGitRepo(root, options.withUnreviewable !== false);
	const drill = createDrillDb(root, gitFixture.baseSha, gitFixture.h1, gitFixture.h2);
	const dataDir = join(root, "warroom-data");
	mkdirSync(dataDir, { recursive: true, mode: 0o700 });
	const dbPath = join(dataDir, "warroom.db");
	const warroom = new Warroom(dbPath, { id: "operator" });
	warroom.command({ type: "initiative.create", id: "i1", title: "Warroom first review slice" });
	warroom.command({
		type: "revision.create",
		id: "plan-1",
		initiativeId: "i1",
		kind: "plan",
		content: "# Plan\n\n- Review the exact head before merge.\n- Criteria: code, docs and tests are all navigable.\n",
	});
	warroom.command({ type: "approval.record", id: "plan-approval-1", initiativeId: "i1", kind: "plan-approval", revisionId: "plan-1", decision: "approved" });
	warroom.command({ type: "approval.record", id: "execution-1", initiativeId: "i1", kind: "execution-authorization", revisionId: "plan-1", decision: "approved" });
	const fixture: ReviewFixture = {
		root,
		repo: gitFixture.repo,
		drillDb: drill.dbPath,
		drillLogs: drill.drillLogs,
		dataDir,
		dbPath,
		warroom,
		initiativeId: "i1",
		planRevisionId: "plan-1",
		baseSha: gitFixture.baseSha,
		h1: gitFixture.h1,
		h2: gitFixture.h2,
		repoId: "repo-1",
		run1: "run-1",
		run2: "run-2",
	};
	return fixture;
}

export function captureFixture(fixture: ReviewFixture, head: "h1" | "h2" = "h1", provenance: "fixture" | "drill" = "fixture"): CaptureResult {
	return captureReview(fixture.warroom, fixture.dataDir, {
		repo: fixture.repo,
		drillDb: fixture.drillDb,
		drillLogs: fixture.drillLogs,
		repoId: fixture.repoId,
		runId: head === "h1" ? fixture.run1 : fixture.run2,
		targetRef: "main",
		headRef: head,
		planRevisionId: fixture.planRevisionId,
		provenance,
	});
}

export function reopenWarroom(fixture: ReviewFixture): Warroom {
	return new Warroom(fixture.dbPath, { id: "operator" });
}

export function disposeFixture(fixture: ReviewFixture): void {
	try { fixture.warroom.close(); } catch { /* already closed */ }
	rmSync(fixture.root, { recursive: true, force: true });
}
