CREATE TABLE source (
 id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL,
 removed INTEGER NOT NULL DEFAULT 0,
 last_scan_at REAL, last_error TEXT
);
CREATE TABLE file_record (
 id TEXT PRIMARY KEY, created_order INTEGER NOT NULL UNIQUE,
 source_id TEXT NOT NULL REFERENCES source(id),
 relative_path TEXT NOT NULL, filename TEXT NOT NULL,
 size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, metadata_json TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('pending','importing','imported','skipped')),
 skip_reason TEXT, rule_version INTEGER NOT NULL,
 attempt_id TEXT, placeholder_id TEXT, submitted_at REAL,
 definitely_not_committed INTEGER NOT NULL DEFAULT 0,
 success_id TEXT, success_metadata_json TEXT, succeeded_at REAL,
 retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT,
 UNIQUE(source_id, relative_path)
);
CREATE TABLE match_evidence (
 file_id TEXT NOT NULL REFERENCES file_record(id), candidate_key TEXT NOT NULL,
 candidate_json TEXT NOT NULL, rule_version INTEGER NOT NULL, compared_at REAL NOT NULL,
 PRIMARY KEY(file_id, candidate_key)
);
CREATE TABLE scan_run (
 id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES source(id),
 started_at REAL NOT NULL, ended_at REAL, complete INTEGER NOT NULL DEFAULT 0,
 checked INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0,
 last_error TEXT
);
CREATE INDEX file_state_retry ON file_record(state, next_retry_at);
CREATE INDEX file_name ON file_record(filename);
CREATE INDEX file_state_created_order ON file_record(state, created_order);

CREATE TABLE non_media_skip (source_id TEXT NOT NULL REFERENCES source(id), relative_path TEXT NOT NULL, size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, disposition TEXT NOT NULL, state TEXT NOT NULL CHECK(state = 'skipped'), skip_reason TEXT NOT NULL, PRIMARY KEY(source_id, relative_path));
