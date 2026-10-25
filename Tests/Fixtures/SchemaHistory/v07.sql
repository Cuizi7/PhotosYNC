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
 recheck_policy_version TEXT, recheck_retry_count INTEGER NOT NULL DEFAULT 0, recheck_next_retry_at REAL,
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
CREATE INDEX file_recheck_retry ON file_record(recheck_policy_version,recheck_next_retry_at,created_order) WHERE recheck_retry_count > 0;

CREATE TABLE non_media_skip (source_id TEXT NOT NULL REFERENCES source(id), relative_path TEXT NOT NULL, size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, disposition TEXT NOT NULL, state TEXT NOT NULL CHECK(state = 'skipped'), skip_reason TEXT NOT NULL, PRIMARY KEY(source_id, relative_path));

CREATE TABLE dedup_index_state (
 id INTEGER PRIMARY KEY CHECK(id = 1), context_id TEXT NOT NULL, context_epoch INTEGER NOT NULL,
 generation INTEGER NOT NULL, published_generation INTEGER, fingerprint_version TEXT NOT NULL,
 photos_generation INTEGER NOT NULL, local_revision INTEGER NOT NULL DEFAULT 0,
 reconcile_cursor TEXT, reconciliation_complete INTEGER NOT NULL DEFAULT 0,
 resume_checkpoint BLOB, excluded_assets INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE photos_representation (
 context_id TEXT NOT NULL, context_epoch INTEGER NOT NULL, asset_id TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('original','current')), revision TEXT NOT NULL,
 width INTEGER, height INTEGER, equivalent_to_original INTEGER NOT NULL,
 revision_is_reliable INTEGER NOT NULL, seen_generation INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('ready','pending','failed')), fingerprint_version TEXT NOT NULL,
 vector BLOB, tombstoned INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(context_id, context_epoch, asset_id, kind),
 CHECK((width IS NULL AND height IS NULL) OR (width > 0 AND height > 0)),
 CHECK(vector IS NULL OR length(vector) = 4096)
);
CREATE INDEX photos_representation_readiness ON photos_representation(context_id,context_epoch,state,fingerprint_version,(vector IS NULL),seen_generation) WHERE tombstoned=0;
CREATE TABLE photos_index_exclusion (
 context_id TEXT NOT NULL, context_epoch INTEGER NOT NULL, asset_id TEXT NOT NULL,
 PRIMARY KEY(context_id, context_epoch, asset_id)
);
CREATE TABLE fingerprint_task (
 context_id TEXT NOT NULL, context_epoch INTEGER NOT NULL, asset_id TEXT NOT NULL,
 kind TEXT NOT NULL, revision TEXT NOT NULL, fingerprint_version TEXT NOT NULL,
 generation INTEGER NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT,
 PRIMARY KEY(context_id, context_epoch, asset_id, kind, revision, fingerprint_version),
 FOREIGN KEY(context_id, context_epoch, asset_id, kind) REFERENCES photos_representation(context_id, context_epoch, asset_id, kind)
);
CREATE INDEX fingerprint_task_due ON fingerprint_task(generation, next_retry_at);
CREATE TABLE file_fingerprint (
 file_id TEXT NOT NULL REFERENCES file_record(id), size INTEGER NOT NULL, modified_ns INTEGER NOT NULL,
 fingerprint_version TEXT NOT NULL, purpose TEXT NOT NULL CHECK(purpose IN ('current','success','attempt')),
 width INTEGER, height INTEGER, vector BLOB NOT NULL CHECK(length(vector) = 4096),
 attempt_id TEXT NOT NULL DEFAULT '',
 PRIMARY KEY(file_id, size, modified_ns, fingerprint_version, purpose, attempt_id),
 CHECK((purpose = 'attempt' AND attempt_id <> '') OR (purpose <> 'attempt' AND attempt_id = ''))
);
CREATE TABLE advanced_match_evidence (
 event_id TEXT PRIMARY KEY, file_id TEXT NOT NULL REFERENCES file_record(id),
 size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, token_json TEXT NOT NULL,
 policy_version TEXT NOT NULL, action TEXT NOT NULL, evidence_json TEXT NOT NULL, created_at REAL NOT NULL
);
CREATE INDEX advanced_evidence_file ON advanced_match_evidence(file_id);
CREATE TABLE dedup_dependency (
 file_id TEXT NOT NULL REFERENCES file_record(id), candidate_file_id TEXT NOT NULL REFERENCES file_record(id),
 candidate_revision TEXT NOT NULL, PRIMARY KEY(file_id, candidate_file_id), CHECK(file_id <> candidate_file_id)
);
CREATE INDEX dedup_dependency_candidate ON dedup_dependency(candidate_file_id, file_id);
CREATE TABLE dedup_recheck_progress (
 target_policy_version TEXT PRIMARY KEY, cursor INTEGER, complete INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0
);

ALTER TABLE fingerprint_task ADD COLUMN issuance_revision TEXT;
ALTER TABLE fingerprint_task ADD COLUMN failure_kind TEXT CHECK(failure_kind IS NULL OR failure_kind = 'photos_read');
CREATE TABLE photos_content_change (
 context_id TEXT NOT NULL, context_epoch INTEGER NOT NULL, run_id TEXT NOT NULL,
 asset_id TEXT NOT NULL, generation INTEGER NOT NULL, removed INTEGER NOT NULL,
 content_changed INTEGER NOT NULL,
 PRIMARY KEY(context_id, context_epoch, run_id, asset_id)
);
CREATE INDEX photos_content_change_asset ON photos_content_change(context_id, context_epoch, asset_id, content_changed);
