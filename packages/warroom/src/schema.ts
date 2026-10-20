import type { Database } from "bun:sqlite";

export const migrations = [
	{
		version: 1,
		sql: `
CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS events (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  initiative_id TEXT NOT NULL,
  type TEXT NOT NULL,
  actor TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  payload_version INTEGER NOT NULL CHECK (payload_version > 0),
  payload TEXT NOT NULL
);
CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT, 'events are append-only'); END;
CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'events are append-only'); END;
CREATE TABLE IF NOT EXISTS initiatives (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, working_name TEXT NOT NULL, phase TEXT NOT NULL,
  current_plan_revision_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS revisions (
  id TEXT PRIMARY KEY, initiative_id TEXT NOT NULL REFERENCES initiatives(id), kind TEXT NOT NULL,
  digest TEXT NOT NULL, previous_revision_id TEXT REFERENCES revisions(id), content TEXT NOT NULL,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS decisions (
  id TEXT PRIMARY KEY, initiative_id TEXT NOT NULL REFERENCES initiatives(id), source_revision_id TEXT NOT NULL REFERENCES revisions(id),
  statement TEXT NOT NULL, rationale TEXT NOT NULL, selected_alternatives TEXT NOT NULL, decided_by TEXT NOT NULL, decided_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS approvals (
  id TEXT PRIMARY KEY, initiative_id TEXT NOT NULL REFERENCES initiatives(id), kind TEXT NOT NULL CHECK(kind IN ('plan-approval','execution-authorization','code-review-acceptance','merge-permission')),
  subject_revision_id TEXT NOT NULL REFERENCES revisions(id), subject_digest TEXT NOT NULL, evidence_revision_id TEXT REFERENCES validation_evidence(id),
  decision TEXT NOT NULL CHECK(decision IN ('approved','rejected','changes-requested')), actor TEXT NOT NULL, created_at TEXT NOT NULL,
  superseded_at TEXT, superseded_by TEXT REFERENCES revisions(id)
);
CREATE TABLE IF NOT EXISTS comments (
  id TEXT PRIMARY KEY, initiative_id TEXT NOT NULL REFERENCES initiatives(id), revision_id TEXT NOT NULL REFERENCES revisions(id),
  body TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('open','resolved','outdated')), created_by TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS validation_evidence (
  id TEXT PRIMARY KEY, initiative_id TEXT NOT NULL REFERENCES initiatives(id), revision_id TEXT NOT NULL REFERENCES revisions(id),
  digest TEXT NOT NULL, provider TEXT NOT NULL, result TEXT NOT NULL, captured_at TEXT NOT NULL, stale INTEGER NOT NULL DEFAULT 0 CHECK(stale IN (0,1))
);
CREATE INDEX IF NOT EXISTS events_initiative_sequence ON events(initiative_id, sequence);
CREATE INDEX IF NOT EXISTS approvals_subject ON approvals(subject_revision_id, kind);
`,
	},
	{
		version: 2,
		sql: `
CREATE TABLE IF NOT EXISTS questions (
  id TEXT PRIMARY KEY, initiative_id TEXT NOT NULL REFERENCES initiatives(id), revision_id TEXT NOT NULL REFERENCES revisions(id),
  prompt TEXT NOT NULL, context TEXT NOT NULL DEFAULT '', status TEXT NOT NULL CHECK(status IN ('open','answered','outdated')),
  answer TEXT, answered_by TEXT, answered_at TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS questions_revision ON questions(revision_id);
`,
	},
	{
		version: 3,
		sql: `
ALTER TABLE validation_evidence ADD COLUMN provenance TEXT NOT NULL DEFAULT 'legacy';
ALTER TABLE validation_evidence ADD COLUMN capture_id TEXT;
ALTER TABLE validation_evidence ADD COLUMN capture_digest TEXT;
ALTER TABLE validation_evidence ADD COLUMN provider_version TEXT;
ALTER TABLE validation_evidence ADD COLUMN eligible INTEGER NOT NULL DEFAULT 0;
ALTER TABLE validation_evidence ADD COLUMN ineligibility TEXT;
ALTER TABLE validation_evidence ADD COLUMN delivered_head_sha TEXT;
ALTER TABLE validation_evidence ADD COLUMN drill_base_sha TEXT;
ALTER TABLE validation_evidence ADD COLUMN submitted_head_sha TEXT;
ALTER TABLE validation_evidence ADD COLUMN reviewed_head_sha TEXT;
ALTER TABLE validation_evidence ADD COLUMN run_status TEXT;
ALTER TABLE comments ADD COLUMN packet_id TEXT;
ALTER TABLE comments ADD COLUMN target_type TEXT NOT NULL DEFAULT 'review';
ALTER TABLE comments ADD COLUMN path TEXT;
ALTER TABLE comments ADD COLUMN side TEXT;
ALTER TABLE comments ADD COLUMN start_line INTEGER;
ALTER TABLE comments ADD COLUMN end_line INTEGER;
ALTER TABLE comments ADD COLUMN blob_sha TEXT;
ALTER TABLE comments ADD COLUMN anchor_context TEXT;
ALTER TABLE comments ADD COLUMN snapshot_digest TEXT;
ALTER TABLE comments ADD COLUMN comment_kind TEXT NOT NULL DEFAULT 'comment';
ALTER TABLE comments ADD COLUMN suggestion TEXT;
ALTER TABLE comments ADD COLUMN anchor_status TEXT NOT NULL DEFAULT 'current';
ALTER TABLE comments ADD COLUMN resolved_at TEXT;
ALTER TABLE comments ADD COLUMN resolved_by TEXT;
ALTER TABLE approvals ADD COLUMN packet_id TEXT;
ALTER TABLE approvals ADD COLUMN packet_digest TEXT;
ALTER TABLE approvals ADD COLUMN evidence_digest TEXT;
ALTER TABLE approvals ADD COLUMN scope_json TEXT;
ALTER TABLE approvals ADD COLUMN declaration TEXT;
ALTER TABLE approvals ADD COLUMN actor_confirmed INTEGER NOT NULL DEFAULT 0;
ALTER TABLE approvals ADD COLUMN stale_reason TEXT;
CREATE TABLE IF NOT EXISTS evidence_captures (
  id TEXT PRIMARY KEY, initiative_id TEXT NOT NULL REFERENCES initiatives(id), revision_id TEXT NOT NULL REFERENCES revisions(id),
  capture_version INTEGER NOT NULL, capture_json TEXT NOT NULL, capture_digest TEXT NOT NULL,
  provenance TEXT NOT NULL CHECK(provenance IN ('drill','manual','fixture')),
  run_id TEXT NOT NULL, repo_id TEXT NOT NULL, drill_version TEXT NOT NULL, drill_build_sha TEXT,
  drill_base_sha TEXT NOT NULL, submitted_head_sha TEXT, reviewed_head_sha TEXT, delivered_head_sha TEXT NOT NULL,
  run_status TEXT NOT NULL, ci_ready INTEGER NOT NULL DEFAULT 0, ci_ready_no_ci INTEGER NOT NULL DEFAULT 0,
  eligible INTEGER NOT NULL DEFAULT 0, ineligibility TEXT, captured_at TEXT NOT NULL, created_by TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS review_packets (
  id TEXT PRIMARY KEY, initiative_id TEXT NOT NULL REFERENCES initiatives(id),
  code_revision_id TEXT NOT NULL REFERENCES revisions(id), plan_revision_id TEXT NOT NULL REFERENCES revisions(id),
  plan_digest TEXT NOT NULL, repo_id TEXT NOT NULL, repo_fingerprint TEXT NOT NULL, repo_path TEXT,
  target_ref TEXT NOT NULL, target_observed_sha TEXT, head_ref TEXT,
  review_base_sha TEXT NOT NULL, head_sha TEXT NOT NULL, base_tree TEXT NOT NULL, head_tree TEXT NOT NULL,
  manifest_digest TEXT NOT NULL, patch_digest TEXT NOT NULL, scope_digest TEXT NOT NULL,
  evidence_id TEXT NOT NULL REFERENCES validation_evidence(id), evidence_digest TEXT NOT NULL,
  packet_digest TEXT NOT NULL UNIQUE, status TEXT NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','stale','accepted','changes-requested')),
  superseded_at TEXT, superseded_by TEXT, stale_reason TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS artifacts (
  digest TEXT PRIMARY KEY, byte_length INTEGER NOT NULL, media_type TEXT NOT NULL, relative_path TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS review_packets_initiative ON review_packets(initiative_id, created_at);
CREATE INDEX IF NOT EXISTS review_packets_revision ON review_packets(code_revision_id);
CREATE INDEX IF NOT EXISTS evidence_captures_revision ON evidence_captures(revision_id);
CREATE INDEX IF NOT EXISTS comments_packet ON comments(packet_id);
CREATE INDEX IF NOT EXISTS approvals_packet ON approvals(packet_id);
`,
	},
] as const;

export function migrate(db: Database): void {
	db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)");
	for (const migration of migrations) {
		const exists = db.query("SELECT 1 FROM schema_migrations WHERE version = ?").get(migration.version);
		if (exists) continue;
		db.transaction(() => {
			db.exec(migration.sql);
			db.query("INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)").run(migration.version, new Date().toISOString());
		})();
	}
}
