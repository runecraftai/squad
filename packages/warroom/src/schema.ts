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
