import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import PhotoSyncCore

final class AdvancedDedupStoreTests: XCTestCase {
    func testLocalRevisionChangesWithCandidateLifecycle() async throws {
        let (root, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let generation = try await store.beginIndexReconciliation(context: .init(id: UUID(), epoch: 1), photosGeneration: 1, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: generation)
        let before = try await unwrap(try await store.indexPublication()).token.localRevision
        try await store.disableSource(id: source)
        let after = try await unwrap(try await store.indexPublication()).token.localRevision
        XCTAssertGreaterThan(after, before, "Source retirement must invalidate prepared local evidence")
    }

    func testOnlyOlderPendingCanBeDependency() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let a = try await prepared(store, source, root, "A.jpg")
        let b = try await prepared(store, source, root, "B.jpg")
        try await publishEmpty(store)
        let reverse = try await admission(store, a, candidate: b)
        try await assertFalse(try await store.commitAdvancedSkip(reverse))
        let forward = try await admission(store, b, candidate: a)
        try await assertTrue(try await store.commitAdvancedSkip(forward))
        try await assertEqual(try await store.state(of: a.fileID), .pending)
        try await assertEqual(try await store.state(of: b.fileID), .skipped)
        try await assertNil(try await store.successIdentifier(of: b.fileID))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM dedup_dependency", at: db), 1)
    }

    func testDisabledOrMissingCandidateReopensDependents() async throws {
        for event in ["disable", "remove", "missing", "stamp", "skip"] {
            let (root, db, store) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = try await store.registerSource(url: root)
            let a = try await prepared(store, source, root, "A.jpg")
            let b = try await prepared(store, source, root, "B.jpg")
            try await publishEmpty(store)
            try await assertTrue(try await store.commitAdvancedSkip(admission(store, b, candidate: a)))
            switch event {
            case "disable": try await store.disableSource(id: source)
            case "remove": try await store.removeSource(id: source)
            case "missing": try await assertTrue(try await store.removeConfirmedAbsentPending(fileID: a.fileID))
            case "stamp": _ = try await store.recordSourceChange(fileID: a.fileID, stamp: .init(size: 20, modifiedNanoseconds: 30))
            default: try await store.markSkipped(fileID: a.fileID, reason: .unsupportedFormat, candidates: [])
            }
            try await assertEqual(try await store.state(of: b.fileID), .pending)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM dedup_dependency", at: db), 0)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM advanced_match_evidence", at: db), 1)
        }
    }

    func testSuccessFingerprintSurvivesPhotosDeletionAndSourceRemoval() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let historyRoot = root.appendingPathComponent("history"), incomingRoot = root.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incomingRoot, withIntermediateDirectories: true)
        let source = try await store.registerSource(url: historyRoot)
        let incomingSource = try await store.registerSource(url: incomingRoot)
        let incoming = try await prepared(store, incomingSource, incomingRoot, "older-incoming.jpg")
        let a = try await prepared(store, source, historyRoot, "newer-success.jpg")
        try await publishEmpty(store)
        let attempt = UUID()
        try await assertTrue(try await store.beginAdvancedAttempt(admission(store, a), attemptID: attempt))
        try await store.removeSource(id: source)
        try await store.invalidateIndexPublication()
        // Three-argument recovery uses the immutable prepared attempt after restart/invalidation.
        try await store.markImported(fileID: a.fileID, attemptID: attempt, identifier: "original-success")
        _ = try await store.recordSourceChange(fileID: a.fileID, stamp: .init(size: 900, modifiedNanoseconds: 800))
        // Observe the imported Photos representation, then remove it from the next
        // complete inventory in the same library context.
        let library = LibraryContext(id: UUID(), epoch: 1)
        var generation = try await store.beginIndexReconciliation(context: library, photosGeneration: 2, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(library, asset: "original-success")], generation: generation)
        let task = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        try await assertTrue(try await store.completeRepresentation(task, fingerprint: a.fingerprint))
        try await store.finishIndexReconciliation(generation: generation)
        try await assertEqual(try await store.indexPublication()?.entries.count, 1)
        generation = try await store.beginIndexReconciliation(context: library, photosGeneration: 3, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: generation)
        try await assertEqual(try await store.indexPublication()?.entries.count, 0)
        let candidates = try await store.localVectorCandidates(beforeOrder: 1, excluding: incoming.fileID, version: "v1")
        XCTAssertEqual(candidates.entries.map(\.key), ["file:\(a.fileID.uuidString)"])
        XCTAssertEqual(candidates.entries.first?.origin, .successHistory)
        XCTAssertEqual(candidates.entries.first?.size, a.size)
        try await assertEqual(try await store.successIdentifier(of: a.fileID), "original-success")
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_fingerprint WHERE purpose = 'success'", at: db), 1)
        let publication = try await unwrap(try await store.indexPublication())
        try await assertTrue(try await store.markIndexPublished(token: publication.token))
        try await assertTrue(try await store.commitAdvancedSkip(admission(store, incoming, candidate: a, origin: .successHistory)))
        try await assertNil(try await store.successIdentifier(of: incoming.fileID))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM dedup_dependency", at: db), 0)
    }

    func testEvidenceFailureRollsBackSkipAndAttempt() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let a = try await prepared(store, source, root, "A.jpg")
        let b = try await prepared(store, source, root, "B.jpg")
        try await publishEmpty(store)
        let skip = try await admission(store, b, candidate: a)
        let start = try await admission(store, a)
        try injectEngineSQL("CREATE TRIGGER reject_evidence BEFORE INSERT ON advanced_match_evidence BEGIN SELECT RAISE(ABORT, 'injected evidence failure'); END;", at: db)
        await XCTAssertThrowsErrorAsync(try await store.commitAdvancedSkip(skip))
        await XCTAssertThrowsErrorAsync(try await store.beginAdvancedAttempt(start, attemptID: UUID()))
        try await assertEqual(try await store.state(of: b.fileID), .pending)
        try await assertEqual(try await store.state(of: a.fileID), .pending)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM dedup_dependency", at: db), 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_fingerprint WHERE purpose = 'attempt'", at: db), 0)
        try await assertTrue(try await store.indexIsReady(token: skip.evidence.token))
    }

    func testLocalRevisionChangeRejectsAdmission() async throws {
        let (root, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let a = try await prepared(store, source, root, "A.jpg")
        let b = try await prepared(store, source, root, "B.jpg")
        try await publishEmpty(store)
        let skip = try await admission(store, b, candidate: a)
        try await store.beginAttempt(fileID: a.fileID, attemptID: UUID())
        try await assertFalse(try await store.commitAdvancedSkip(skip))
        let importing = try await admission(store, b, candidate: a, origin: .localImporting)
        try await assertTrue(try await store.commitAdvancedSkip(importing))
        try await assertFalse(try await store.removeConfirmedAbsentPending(fileID: a.fileID))
        try await assertEqual(try await store.state(of: b.fileID), .skipped)
    }

    func testConservativeAdmissionCreatesEvidenceWithoutFingerprint() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let a = try await prepared(store, source, root, "animated.gif", cache: false)
        try await publishEmpty(store)
        let token = try await unwrap(try await store.indexReadiness()).token
        let evidence = AdvancedEvidence(eventID: UUID(), fileID: a.fileID, stamp: a.file.stamp, token: token,
            policyVersion: "policy", evaluation: .init(content: .notCompared, action: .importFile,
            reason: .nonComparableSource, matchedKeys: [], coveringKeys: []), decisiveCandidates: [], diagnostics: [], timingsMS: [:])
        let conservative = ConservativeSourceAdmission(fileID: a.fileID, file: a.file, reason: .multiFrameOrCompound,
            evidence: evidence, validity: AlwaysValidPhotosCandidateValidity())
        let attempt = UUID()
        try await assertTrue(try await store.beginAdvancedAttempt(conservative, attemptID: attempt))
        try await assertTrue(try await store.advancedAttemptIsCurrent(fileID: a.fileID, attemptID: attempt))
        let afterOwnWrite = try await unwrap(try await store.indexReadiness()).token.localRevision
        XCTAssertEqual(afterOwnWrite, evidence.token.localRevision + 1)
        _ = try await prepared(store, source, root, "other.jpg", cache: false)
        try await assertFalse(try await store.advancedAttemptIsCurrent(fileID: a.fileID, attemptID: attempt))
        try await store.markImported(fileID: a.fileID, attemptID: attempt, identifier: "animated", sourceFingerprint: a)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_fingerprint", at: db), 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM advanced_match_evidence", at: db), 1)
    }

    func testUnknownAttemptRetainsImmutableFingerprintUntilSuccess() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let a = try await prepared(store, source, root, "A.jpg")
        try await publishEmpty(store)
        let attempt = UUID()
        try await assertTrue(try await store.beginAdvancedAttempt(admission(store, a), attemptID: attempt))
        try await store.recordRetry(fileID: a.fileID, attemptID: attempt, nextRetry: Date(), error: "unknown", definitelyNotCommitted: false)
        try await assertFalse(try await store.removeConfirmedAbsentPending(fileID: a.fileID))
        try await assertFalse(try await store.recordSourceChange(fileID: a.fileID, stamp: .init(size: 2, modifiedNanoseconds: 3)))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_fingerprint WHERE purpose = 'attempt'", at: db), 1)
        // A caller carrying a different image cannot overwrite the frozen submitted facts.
        let replacement = PreparedSource(fileID: a.fileID, file: a.file,
            fingerprint: try Fingerprint(version: "v1", values: [0, 1] + Array(repeating: 0, count: 1022)), size: try PixelSize(width: 1, height: 1))
        try await store.markImported(fileID: a.fileID, attemptID: attempt, identifier: "success", sourceFingerprint: replacement)
        let history = try await store.localVectorCandidates(beforeOrder: 0, excluding: UUID(), version: "v1")
        XCTAssertEqual(history.entries.first?.fingerprint, a.fingerprint)
        XCTAssertEqual(history.entries.first?.size, a.size)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_fingerprint WHERE purpose = 'attempt'", at: db), 0)
        await XCTAssertThrowsErrorAsync(try await store.markSkipped(fileID: a.fileID, reason: .suspectedDuplicate, candidates: []))
        await XCTAssertThrowsErrorAsync(try await store.recordRetry(fileID: a.fileID, attemptID: attempt, nextRetry: Date(), error: "late failure", definitelyNotCommitted: true))
        try await assertEqual(try await store.successIdentifier(of: a.fileID), "success")
    }

    func testDefiniteRetriesBoundAttemptFactsAndAbsenceDeletesObsoleteEvidence() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let a = try await prepared(store, source, root, "A.jpg")
        try await publishEmpty(store)
        for _ in 0..<3 {
            let attempt = UUID()
            try await assertTrue(try await store.beginAdvancedAttempt(admission(store, a), attemptID: attempt))
            try await store.recordRetry(fileID: a.fileID, attemptID: attempt, nextRetry: Date(), error: "definite", definitelyNotCommitted: true)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_fingerprint WHERE purpose = 'attempt'", at: db), 0)
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM advanced_match_evidence", at: db), 1)
        }
        try await assertTrue(try await store.removeConfirmedAbsentPending(fileID: a.fileID))
        try await assertNil(try await store.file(sourceID: source, relativePath: "A.jpg"))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM advanced_match_evidence", at: db), 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_fingerprint", at: db), 0)
    }

    func testPhotosValidityAndChangedStampRejectWithoutWriting() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let a = try await prepared(store, source, root, "A.jpg")
        try await publishEmpty(store)
        let prepared = try await admission(store, a)
        let stale = AdvancedAdmission(source: a, evidence: prepared.evidence, validity: P5InvalidValidity())
        try await assertFalse(try await store.beginAdvancedAttempt(stale, attemptID: UUID()))
        _ = try await store.recordSourceChange(fileID: a.fileID, stamp: .init(size: 99, modifiedNanoseconds: 100))
        try await assertFalse(try await store.beginAdvancedAttempt(prepared, attemptID: UUID()))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM advanced_match_evidence", at: db), 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_fingerprint WHERE purpose = 'attempt'", at: db), 0)
    }

    func testPhotosCoveringCandidateValidatedInTransaction() async throws {
        let (root, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let a = try await prepared(store, source, root, "A.jpg")
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 2, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context, asset: "asset:é")], generation: generation)
        let task = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        try await assertTrue(try await store.completeRepresentation(task, fingerprint: a.fingerprint))
        try await store.finishIndexReconciliation(generation: generation)
        let publication = try await unwrap(try await store.indexPublication())
        try await assertTrue(try await store.markIndexPublished(token: publication.token))
        let candidate = ScoredCandidate(key: "photos:8:asset:é:original", origin: .photosOriginal, score: 1, size: a.size, fingerprintVersion: "v1")
        let evidence = AdvancedEvidence(eventID: UUID(), fileID: a.fileID, stamp: a.file.stamp, token: publication.token,
            policyVersion: "policy", evaluation: .init(content: .duplicate, action: .skip, reason: .covered,
            matchedKeys: [candidate.key], coveringKeys: [candidate.key]), decisiveCandidates: [candidate], diagnostics: [], timingsMS: [:])
        let valid = AdvancedAdmission(source: a, evidence: evidence, validity: AlwaysValidPhotosCandidateValidity())
        try await assertTrue(try await store.commitAdvancedSkip(valid))
    }

    func testEarlierUnreleasedV4MigrationPreservesFingerprintFactsAndRollsBackFailure() async throws {
        for fail in [false, true] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let db = root.appendingPathComponent("old-v4.sqlite")
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            var sql = try String(contentsOf: repository.appendingPathComponent("Sources/PhotoSyncCore/Storage/Schema.sql"), encoding: .utf8)
            sql = sql.replacingOccurrences(of: "'current','success','attempt'", with: "'current','success'")
                .replacingOccurrences(of: " attempt_id TEXT NOT NULL DEFAULT '',\n", with: "")
                .replacingOccurrences(of: "PRIMARY KEY(file_id, size, modified_ns, fingerprint_version, purpose, attempt_id),\n CHECK((purpose = 'attempt' AND attempt_id <> '') OR (purpose <> 'attempt' AND attempt_id = ''))", with: "PRIMARY KEY(file_id, size, modified_ns, fingerprint_version, purpose)")
                .replacingOccurrences(of: "CREATE INDEX advanced_evidence_file ON advanced_match_evidence(file_id);", with: "")
            try injectEngineSQL(sql + "PRAGMA user_version = 4;", at: db)
            // Fixtures are opaque historical records, never source paths to scan.
            try injectEngineSQL("""
                INSERT INTO source (id, path, enabled) VALUES ('source', '/fixture-only', 0);
                INSERT INTO file_record (id, created_order, source_id, relative_path, filename, size, modified_ns, metadata_json, state, rule_version, success_id) VALUES ('file', 1, 'source', 'a.jpg', 'a.jpg', 1, 2, '{}', 'imported', 1, 'success');
                INSERT INTO file_fingerprint VALUES ('file', 1, 2, 'v1', 'current', 640, 480, zeroblob(4096)), ('file', 1, 2, 'v1', 'success', 640, 480, zeroblob(4096));
                """, at: db)
            if fail {
                // Force the final index creation to fail after table replacement/copy.
                try injectEngineSQL("CREATE TABLE advanced_evidence_file (id INTEGER);", at: db)
                XCTAssertThrowsError(try SyncStore(url: db))
                XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM pragma_table_info('file_fingerprint') WHERE name = 'attempt_id'", at: db), 0)
                XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM sqlite_master WHERE name = 'old_file_fingerprint'", at: db), 0)
            } else {
                let migrated = try SyncStore(url: db)
                withExtendedLifetime(migrated) {}
                XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_fingerprint WHERE attempt_id = ''", at: db), 2)
            }
            XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_fingerprint", at: db), 2)
            XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 4)
        }
    }

    func testEveryCandidateQualificationMutationRejectsPreparedAdmission() async throws {
        for event in ["save", "disable", "enable", "remove", "restore", "begin", "retry", "skip", "stamp", "missing", "success"] {
            let (root, _, store) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
            try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
            let candidateSource = try await store.registerSource(url: left)
            let incomingSource = try await store.registerSource(url: right)
            let a = try await prepared(store, candidateSource, left, "A.jpg")
            let b = try await prepared(store, incomingSource, right, "B.jpg")
            let attempt = UUID()
            if event == "enable" { try await store.disableSource(id: candidateSource) }
            if event == "restore" { try await store.removeSource(id: candidateSource) }
            if event == "retry" || event == "success" { try await store.beginAttempt(fileID: a.fileID, attemptID: attempt) }
            try await publishEmpty(store)
            let old = try await admission(store, b)
            switch event {
            case "save": _ = try await prepared(store, candidateSource, left, "C.jpg", cache: false)
            case "disable": try await store.disableSource(id: candidateSource)
            case "enable", "restore": _ = try await store.registerSource(url: left)
            case "remove": try await store.removeSource(id: candidateSource)
            case "begin": try await store.beginAttempt(fileID: a.fileID, attemptID: attempt)
            case "retry": try await store.recordRetry(fileID: a.fileID, attemptID: attempt, nextRetry: Date(), error: "definite", definitelyNotCommitted: true)
            case "skip": try await store.markSkipped(fileID: a.fileID, reason: .unsupportedFormat, candidates: [])
            case "stamp": _ = try await store.recordSourceChange(fileID: a.fileID, stamp: .init(size: 100, modifiedNanoseconds: 200))
            case "missing": _ = try await store.removeConfirmedAbsentPending(fileID: a.fileID)
            default: try await store.markImported(fileID: a.fileID, attemptID: attempt, identifier: "success", sourceFingerprint: a)
            }
            let current = try await unwrap(try await store.indexReadiness()).token
            XCTAssertGreaterThan(current.localRevision, old.evidence.token.localRevision, event)
            try await assertFalse(try await store.beginAdvancedAttempt(old, attemptID: UUID()))
            try await assertEqual(try await store.state(of: b.fileID), .pending)
        }
    }

    func testSuccessResolvesDependencyWithoutReopeningOrRequiringCurrentSource() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let a = try await prepared(store, source, root, "A.jpg")
        let b = try await prepared(store, source, root, "B.jpg")
        try await publishEmpty(store)
        let attempt = UUID()
        let incoming = try await admission(store, a)
        let gate = P5BeforeTransactionValidity(database: db)
        try await assertTrue(try await store.beginAdvancedAttempt(.init(source: a, evidence: incoming.evidence, validity: gate), attemptID: attempt))
        try await assertTrue(try await store.commitAdvancedSkip(admission(store, b, candidate: a, origin: .localImporting)))
        try await store.markImported(fileID: a.fileID, attemptID: attempt, identifier: "success")
        try await store.removeSource(id: source)
        try await assertEqual(try await store.state(of: b.fileID), .skipped)
        try await assertNil(try await store.successIdentifier(of: b.fileID))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM dedup_dependency", at: db), 0)
    }

    func testAdvancedDecisionReplacesSupersededLegacyDependencyEvidence() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let old = try await prepared(store, source, root, "old.jpg")
        let current = try await prepared(store, source, root, "current.jpg")
        let b = try await prepared(store, source, root, "incoming.jpg")
        try await store.markSkipped(fileID: b.fileID, reason: .suspectedDuplicate,
            candidates: [.init(key: "file:\(old.fileID.uuidString)", metadata: old.file.metadata)])
        // A legacy recheck reopened this unsubmitted file; its old evidence still
        // describes the previous decision until the new transaction replaces it.
        try injectEngineSQL("UPDATE file_record SET state = 'pending', skip_reason = NULL WHERE id = '\(b.fileID.uuidString)';", at: db)
        try await publishEmpty(store)
        try await assertTrue(try await store.commitAdvancedSkip(admission(store, b, candidate: current)))
        try await assertTrue(try await store.removeConfirmedAbsentPending(fileID: old.fileID))
        try await assertEqual(try await store.state(of: b.fileID), .skipped)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM match_evidence", at: db), 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM dedup_dependency", at: db), 1)
    }

    func testAdvancedAttemptReceiptAcceptsOnlyItsOwnRevisionIncrement() async throws {
        let (root, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        let source = try await store.registerSource(url: left)
        let otherSource = try await store.registerSource(url: right)
        let a = try await prepared(store, source, left, "A.jpg")
        _ = try await prepared(store, otherSource, right, "other.jpg")
        try await publishEmpty(store)
        let admission = try await admission(store, a)
        let attempt = UUID()
        try await assertFalse(try await store.advancedAttemptIsCurrent(fileID: a.fileID, attemptID: attempt))
        try await assertTrue(try await store.beginAdvancedAttempt(admission, attemptID: attempt))
        try await assertTrue(try await store.advancedAttemptIsCurrent(fileID: a.fileID, attemptID: attempt))
        try await assertFalse(try await store.advancedAttemptIsCurrent(fileID: a.fileID, attemptID: UUID()))
        let afterOwnWrite = try await unwrap(try await store.indexReadiness()).token.localRevision
        XCTAssertEqual(afterOwnWrite, admission.evidence.token.localRevision + 1)
        // Even a different source's eligibility change invalidates the scored view.
        try await store.disableSource(id: otherSource)
        try await assertFalse(try await store.advancedAttemptIsCurrent(fileID: a.fileID, attemptID: attempt))
    }

    func testAdvancedAttemptReceiptRejectsOverflowAndIndexInvalidation() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let a = try await prepared(store, source, root, "A.jpg")
        try await publishEmpty(store)
        let admission = try await admission(store, a)
        let attempt = UUID()
        try await assertTrue(try await store.beginAdvancedAttempt(admission, attemptID: attempt))
        try await store.invalidateIndexPublication()
        try await assertFalse(try await store.advancedAttemptIsCurrent(fileID: a.fileID, attemptID: attempt))
        let publication = try await unwrap(try await store.indexPublication())
        try await assertTrue(try await store.markIndexPublished(token: publication.token))
        try await assertTrue(try await store.advancedAttemptIsCurrent(fileID: a.fileID, attemptID: attempt))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(admission.evidence.token)) as! [String: Any]
        json["localRevision"] = Int64.max
        let corruptToken = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        try injectEngineSQL("UPDATE advanced_match_evidence SET token_json = '\(corruptToken)' WHERE file_id = '\(a.fileID.uuidString)';", at: db)
        try await assertFalse(try await store.advancedAttemptIsCurrent(fileID: a.fileID, attemptID: attempt))
    }

    private func prepared(_ store: SyncStore, _ source: UUID, _ root: URL, _ path: String, cache: Bool = true) async throws -> PreparedSource {
        let file = SourceFile(sourceID: source, relativePath: path, url: root.appendingPathComponent(path),
            stamp: .init(size: 10, modifiedNanoseconds: 12), metadata: .init(filename: path, kind: .image,
                captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: 640, height: 480, duration: nil))
        let id = try await store.save(file, decision: .importNew)
        let result = PreparedSource(fileID: id, file: file, fingerprint: try fingerprint("v1"), size: try PixelSize(width: 640, height: 480))
        if cache { _ = try await store.cacheFingerprint(result) }
        return result
    }

    private func publishEmpty(_ store: SyncStore) async throws {
        let generation = try await store.beginIndexReconciliation(context: .init(id: UUID(), epoch: 1), photosGeneration: 1, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: generation)
        let publication = try await unwrap(try await store.indexPublication())
        try await assertTrue(try await store.markIndexPublished(token: publication.token))
    }

    private func admission(_ store: SyncStore, _ source: PreparedSource, candidate: PreparedSource? = nil,
                           origin: CandidateOrigin = .localPending) async throws -> AdvancedAdmission {
        let token = try await unwrap(try await store.indexReadiness()).token
        let key = candidate.map { "file:\($0.fileID.uuidString)" }
        let evidence = AdvancedEvidence(eventID: UUID(), fileID: source.fileID, stamp: source.file.stamp, token: token,
            policyVersion: "policy", evaluation: .init(content: candidate == nil ? .notDuplicate : .duplicate,
            action: candidate == nil ? .importFile : .skip, reason: candidate == nil ? .noMatch : .covered,
            matchedKeys: key.map { [$0] } ?? [], coveringKeys: key.map { [$0] } ?? []),
            decisiveCandidates: candidate.map { [.init(key: key!, origin: origin, score: 1, size: $0.size, fingerprintVersion: "v1")] } ?? [],
            diagnostics: [], timingsMS: [:])
        return AdvancedAdmission(source: source, evidence: evidence, validity: AlwaysValidPhotosCandidateValidity())
    }

    func testV3MigrationPreservesSuccessAndUnknown() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("state.sqlite")
        try makeV3(at: db)
        let before = try facts(at: db)
        let store = try SyncStore(url: db)
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 4)
        XCTAssertEqual(try facts(at: db), before)
        let generation = try await store.beginIndexReconciliation(context: LibraryContext(id: UUID(), epoch: 1), photosGeneration: 4, fingerprintVersion: "new-model")
        try await store.finishIndexReconciliation(generation: generation)
        XCTAssertEqual(try facts(at: db), before)
    }

    func testMigrationRollbackAndFutureSchemaRejection() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("state.sqlite")
        try makeV3(at: db)
        let before = try facts(at: db)
        // A colliding third DDL object forces rollback after earlier new tables were created.
        try injectEngineSQL("CREATE TABLE fingerprint_task (collision TEXT)", at: db)
        XCTAssertThrowsError(try SyncStore(url: db))
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 3)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM sqlite_master WHERE name = 'dedup_index_state'", at: db), 0)
        XCTAssertEqual(try facts(at: db), before)
        try injectEngineSQL("PRAGMA user_version = 5", at: db)
        XCTAssertThrowsError(try SyncStore(url: db))
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 5)
    }

    func testStaleTaskCannotPublish() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context, revision: "A")], generation: generation)
        let tasks = try await store.nextRepresentationTasks(now: Date(), limit: 10)
        let staleTask = try XCTUnwrap(tasks.first)
        try await store.upsertRepresentations([descriptor(context, revision: "B")], generation: generation)
        let published = try await store.completeRepresentation(staleTask, fingerprint: fingerprint("v1"))
        XCTAssertFalse(published)
        try await store.failRepresentation(staleTask, nextRetryAt: Date().addingTimeInterval(100), detail: "late error")
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM fingerprint_task WHERE revision = 'B' AND retry_count = 0", at: db), 1)
        let newTasks = try await store.nextRepresentationTasks(now: Date(), limit: 10)
        XCTAssertEqual(newTasks.map(\.descriptor.revision), ["B"])
    }

    func testPartialReconciliationDoesNotDeleteUnseenAssets() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let first = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context, asset: "one"), descriptor(context, asset: "two")], generation: first)
        try await store.finishIndexReconciliation(generation: first)
        let second = try await store.beginIndexReconciliation(context: context, photosGeneration: 2, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context, asset: "one")], generation: second)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE tombstoned = 0", at: db), 2)
        try await assertNil(try await store.indexPublication())
        try await store.finishIndexReconciliation(generation: first) // Stale finish cannot delete anything.
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE tombstoned = 0", at: db), 2)
        try await store.finishIndexReconciliation(generation: second)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE tombstoned = 0", at: db), 1)
    }

    func testCommittedVectorsCanRebuildPublicationButRequireExactPublishToken() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 9, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        try await store.finishIndexReconciliation(generation: generation)
        try await assertNil(try await store.indexPublication())
        let tasks = try await store.nextRepresentationTasks(now: Date(), limit: 1)
        try await assertTrue(try await store.completeRepresentation(try XCTUnwrap(tasks.first), fingerprint: fingerprint("v1")))
        let reopened = try SyncStore(url: db)
        let publication = try await unwrap(try await reopened.indexPublication())
        XCTAssertEqual(publication.entries.count, 1)
        XCTAssertEqual(publication.entries[0].fingerprint.littleEndianFloat32, try fingerprint("v1").littleEndianFloat32)
        try await assertFalse(try await reopened.indexIsReady(token: publication.token))
        try await assertTrue(try await reopened.markIndexPublished(token: publication.token))
        try await assertTrue(try await reopened.indexIsReady(token: publication.token))
        let next = try await store.beginIndexReconciliation(context: context, photosGeneration: 10, fingerprintVersion: "v1")
        try await assertFalse(try await reopened.markIndexPublished(token: publication.token))
        try await assertFalse(try await reopened.indexIsReady(token: publication.token))
        try await store.upsertRepresentations([descriptor(context)], generation: next)
        try await store.finishIndexReconciliation(generation: next)
        try await assertTrue(try await store.nextRepresentationTasks(now: Date(), limit: 10).isEmpty)
        try await assertEqual(try await store.indexPublication()?.entries.count, 1)
    }

    func testVersionContextAndUnreliableRevisionDoNotReuseStaleVectors() async throws {
        let (root, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        var generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        var tasks = try await store.nextRepresentationTasks(now: Date(), limit: 10)
        let stale = try XCTUnwrap(tasks.first)
        try await assertTrue(try await store.completeRepresentation(stale, fingerprint: fingerprint("v1")))
        try await store.finishIndexReconciliation(generation: generation)
        generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 2, fingerprintVersion: "v2")
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        try await store.finishIndexReconciliation(generation: generation)
        try await assertNil(try await store.indexPublication())
        try await assertFalse(try await store.completeRepresentation(stale, fingerprint: fingerprint("v1")))
        tasks = try await store.nextRepresentationTasks(now: Date(), limit: 10)
        XCTAssertEqual(tasks.map(\.fingerprintVersion), ["v2"])
        try await assertTrue(try await store.completeRepresentation(try XCTUnwrap(tasks.first), fingerprint: fingerprint("v2")))
        generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 3, fingerprintVersion: "v2")
        try await store.upsertRepresentations([descriptor(context, reliable: false)], generation: generation)
        try await assertEqual(try await store.nextRepresentationTasks(now: Date(), limit: 10).count, 1)
        let other = LibraryContext(id: context.id, epoch: 2)
        _ = try await store.beginIndexReconciliation(context: other, photosGeneration: 1, fingerprintVersion: "v2")
        try await assertTrue(try await store.nextRepresentationTasks(now: Date(), limit: 10).isEmpty)
    }

    func testRetryDeadlineAndMalformedBlobPreventReadiness() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        try await store.finishIndexReconciliation(generation: generation)
        let task = try await unwrap(try await store.nextRepresentationTasks(now: Date(timeIntervalSince1970: 100), limit: 1).first)
        try await store.failRepresentation(task, nextRetryAt: Date(timeIntervalSince1970: 200), detail: "unavailable")
        try await assertTrue(try await store.nextRepresentationTasks(now: Date(timeIntervalSince1970: 199), limit: 1).isEmpty)
        let due = try await store.nextRepresentationTasks(now: Date(timeIntervalSince1970: 200), limit: 1)
        XCTAssertEqual(due.first?.retryCount, 1)
        try await assertTrue(try await store.completeRepresentation(try XCTUnwrap(due.first), fingerprint: fingerprint("v1")))
        try injectEngineSQL("PRAGMA ignore_check_constraints = ON; UPDATE photos_representation SET vector = X'0000'", at: db)
        await XCTAssertThrowsErrorAsync(try await store.indexPublication())
    }

    func testUserSelectedConfigurationLoadsWithoutStatisticalPass() throws {
        let root = try configurationFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try DedupConfiguration.loadValidated(resourceDirectory: root)
        XCTAssertEqual(configuration.threshold, 0.98)
        XCTAssertEqual(configuration.backend, "exact-f32-v1")
        XCTAssertTrue(configuration.acceptanceID.hasPrefix("user-decision:"))
    }

    func testMissingOrTamperedDecisionRejectsConfiguration() throws {
        for file in ["decision.json", "profile.json", "regression.json", "closeout.json"] {
            let root = try configurationFiles()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.removeItem(at: root.appendingPathComponent(file))
            XCTAssertThrowsError(try DedupConfiguration.loadValidated(resourceDirectory: root), file)
        }
        let root = try configurationFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let decision = root.appendingPathComponent("decision.json")
        var data = try Data(contentsOf: decision); data.append(0x20)
        try data.write(to: decision)
        XCTAssertThrowsError(try DedupConfiguration.loadValidated(resourceDirectory: root))
        try mutate(root, file: "profile.json") { $0["acceptanceID"] = "research:old" }
        XCTAssertThrowsError(try DedupConfiguration.loadValidated(resourceDirectory: root))
    }

    func testThresholdMustMatchDecisionAndPolicyVersion() throws {
        let root = try configurationFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try mutate(root, file: "profile.json") { $0["threshold"] = 0.97 }
        XCTAssertThrowsError(try DedupConfiguration.loadValidated(resourceDirectory: root))
        // Even a valid recomputed policy cannot change the selection without a new bound decision.
        try mutate(root, file: "profile.json") {
            let fingerprint = $0["fingerprint"] as! [String: Any]
            $0["policyVersion"] = DedupConfiguration.computePolicyVersion(fingerprintVersion: fingerprint["version"] as! String, threshold: 0.97, backend: "exact-f32-v1")
        }
        try rebind(root)
        XCTAssertThrowsError(try DedupConfiguration.loadValidated(resourceDirectory: root))
    }

    func testReopenedStoreRequiresDerivedIndexRepublication() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: generation)
        let publication = try await unwrap(try await store.indexPublication())
        try await assertTrue(try await store.markIndexPublished(token: publication.token))
        try await assertTrue(try await store.indexIsReady(token: publication.token))
        let reopened = try SyncStore(url: db)
        try await assertFalse(try await reopened.indexIsReady(token: publication.token))
        let reconstructed = try await unwrap(try await reopened.indexPublication())
        XCTAssertEqual(reconstructed, publication)
        try await assertTrue(try await reopened.markIndexPublished(token: reconstructed.token))
        try await assertTrue(try await reopened.indexIsReady(token: reconstructed.token))
    }

    func testLocalRevisionChangesDoNotRequirePhotosIndexReconstruction() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: generation)
        let publication = try await unwrap(try await store.indexPublication())
        try await assertTrue(try await store.markIndexPublished(token: publication.token))
        // P4/P5 advance this independently when local candidate facts change.
        try injectEngineSQL("UPDATE dedup_index_state SET local_revision = local_revision + 1", at: db)
        try await assertFalse(try await store.indexIsReady(token: publication.token))
        let current = try await unwrap(try await store.indexPublication())
        XCTAssertEqual(current.token.indexGeneration, publication.token.indexGeneration)
        XCTAssertEqual(current.token.localRevision, publication.token.localRevision + 1)
        try await assertTrue(try await store.indexIsReady(token: current.token))
    }

    func testUnfinishedTaskFactsBlockPublication() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        let task = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        try await assertTrue(try await store.completeRepresentation(task, fingerprint: fingerprint("v1")))
        try await store.finishIndexReconciliation(generation: generation)
        let publication = try await unwrap(try await store.indexPublication())
        try injectEngineSQL("INSERT INTO fingerprint_task (context_id, context_epoch, asset_id, kind, revision, fingerprint_version, generation) SELECT context_id, context_epoch, asset_id, kind, revision, fingerprint_version, seen_generation FROM photos_representation", at: db)
        try await assertNil(try await store.indexPublication())
        try await assertFalse(try await store.markIndexPublished(token: publication.token))
    }

    func testThresholdOnlyPolicyChangeRetainsVectorsAndHistory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("state.sqlite")
        try makeV3(at: db)
        let store = try SyncStore(url: db)
        let before = try facts(at: db)
        let resourcesRoot = try configurationFiles()
        defer { try? FileManager.default.removeItem(at: resourcesRoot) }
        let selected = try DedupConfiguration.loadValidated(resourceDirectory: resourcesRoot)
        let changed = try DedupConfiguration(fingerprint: selected.fingerprint,
            policyVersion: DedupConfiguration.computePolicyVersion(fingerprintVersion: selected.fingerprint.version, threshold: 0.97, backend: selected.backend),
            threshold: 0.97, backend: selected.backend, resources: selected.resources,
            evidenceCandidateLimit: selected.evidenceCandidateLimit, acceptanceID: "user-decision:future")
        XCTAssertNotEqual(selected.policyVersion, changed.policyVersion)
        XCTAssertEqual(selected.fingerprint.version, changed.fingerprint.version)
        let context = LibraryContext(id: UUID(), epoch: 1)
        var generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: selected.fingerprint.version)
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        let task = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        try await assertTrue(try await store.completeRepresentation(task, fingerprint: fingerprint(selected.fingerprint.version)))
        try await store.finishIndexReconciliation(generation: generation)
        generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 2, fingerprintVersion: changed.fingerprint.version)
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        try await store.finishIndexReconciliation(generation: generation)
        try await assertTrue(try await store.nextRepresentationTasks(now: Date(), limit: 10).isEmpty)
        try await assertEqual(try await store.indexPublication()?.entries.count, 1)
        XCTAssertEqual(try facts(at: db), before)
    }

    func testStaleGenerationCannotCompleteEquivalentTask() async throws {
        let (root, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let first = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context)], generation: first)
        let stale = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        let next = try await store.beginIndexReconciliation(context: context, photosGeneration: 2, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context)], generation: next)
        try await assertFalse(try await store.completeRepresentation(stale, fingerprint: fingerprint("v1")))
        let current = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        XCTAssertEqual(current.indexGeneration, next)
        try await assertTrue(try await store.completeRepresentation(current, fingerprint: fingerprint("v1")))
    }

    func testMalformedFloat32PayloadsReject() throws {
        XCTAssertThrowsError(try Fingerprint(version: "v1", littleEndianFloat32: Data(count: 4095)))
        XCTAssertThrowsError(try Fingerprint(version: "v1", littleEndianFloat32: Data(count: 4096)))
        for bits in [UInt32(0x7fc00000), 0x7f800000, 0x40000000] {
            var bytes = Data(count: 4096)
            for i in 0..<4 { bytes[i] = UInt8(truncatingIfNeeded: bits >> (8 * i)) }
            XCTAssertThrowsError(try Fingerprint(version: "v1", littleEndianFloat32: bytes))
        }
    }

    func testBoundResourceChangeCannotSilentlyRelaxIntegrationLimits() throws {
        let root = try configurationFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try mutate(root, file: "decision.json") {
            var configuration = $0["configuration"] as! [String: Any]
            var limits = configuration["resources"] as! [String: Any]
            limits["maxInFlightTasks"] = 200
            configuration["resources"] = limits; $0["configuration"] = configuration
        }
        try mutate(root, file: "profile.json") {
            var limits = $0["resources"] as! [String: Any]
            limits["maxInFlightTasks"] = 200; $0["resources"] = limits
        }
        try rebind(root)
        XCTAssertThrowsError(try DedupConfiguration.loadValidated(resourceDirectory: root))
    }

    func testFreshSchemaMatchesSQLAndMigratedSchema() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = root.appendingPathComponent("fresh.sqlite")
        let sqlDB = root.appendingPathComponent("sql.sqlite")
        let migrated = root.appendingPathComponent("migrated.sqlite")
        let store = try SyncStore(url: fresh)
        withExtendedLifetime(store) {}
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sql = try String(contentsOf: repository.appendingPathComponent("Sources/PhotoSyncCore/Storage/Schema.sql"), encoding: .utf8)
        try injectEngineSQL(sql, at: sqlDB)
        // Use the complete historical v3 schema, then apply the production migration.
        let legacy = String(sql.prefix(upTo: sql.range(of: "CREATE TABLE dedup_index_state")!.lowerBound))
        try injectEngineSQL(legacy + "PRAGMA user_version = 3;", at: migrated)
        let migratedStore = try SyncStore(url: migrated)
        withExtendedLifetime(migratedStore) {}
        XCTAssertEqual(try schemaFacts(at: fresh), try schemaFacts(at: sqlDB))
        XCTAssertEqual(try schemaFacts(at: fresh), try schemaFacts(at: migrated))
    }

    private func schemaFacts(at db: URL) throws -> [String] {
        var handle: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(db.path, &handle) == SQLITE_OK else { throw FixtureError.unavailable("sqlite") }
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        guard sqlite3_prepare_v2(handle, "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name", -1, &statement, nil) == SQLITE_OK else { throw FixtureError.unavailable("query") }
        var result = [String]()
        while sqlite3_step(statement) == SQLITE_ROW {
            let sql = String(cString: sqlite3_column_text(statement, 0))
            result.append(sql.filter { !$0.isWhitespace })
        }
        return result
    }

    private func XCTAssertThrowsErrorAsync<T>(_ value: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await value(); XCTFail("Expected a thrown error", file: file, line: line) } catch {}
    }
    private func assertTrue(_ value: @autoclosure () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await value(); XCTAssertTrue(result, file: file, line: line)
    }
    private func assertFalse(_ value: @autoclosure () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await value(); XCTAssertFalse(result, file: file, line: line)
    }
    private func assertNil<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await value(); XCTAssertNil(result, file: file, line: line)
    }
    private func assertEqual<T: Equatable>(_ value: @autoclosure () async throws -> T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await value(); XCTAssertEqual(result, expected, file: file, line: line)
    }
    private func unwrap<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let result = try await value(); return try XCTUnwrap(result, file: file, line: line)
    }
    private func fixture() throws -> (URL, URL, SyncStore) {
        let root = try temporaryDirectory()
        let db = root.appendingPathComponent("state.sqlite")
        return (root, db, try SyncStore(url: db))
    }
    private func descriptor(_ context: LibraryContext, asset: String = "asset", revision: String = "A", reliable: Bool = true) -> RepresentationDescriptor {
        RepresentationDescriptor(key: RepresentationKey(assetID: asset, kind: .original), context: context, revision: revision, size: try! PixelSize(width: 640, height: 480), equivalentToOriginal: false, revisionIsReliable: reliable)
    }
    private func fingerprint(_ version: String) throws -> Fingerprint {
        try Fingerprint(version: version, values: [1] + Array(repeating: 0, count: 1023))
    }
    private func makeV3(at db: URL) throws {
        try injectEngineSQL("""
        CREATE TABLE source (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL, removed INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE file_record (id TEXT PRIMARY KEY, created_order INTEGER NOT NULL UNIQUE, source_id TEXT NOT NULL REFERENCES source(id), relative_path TEXT NOT NULL, filename TEXT NOT NULL, size INTEGER NOT NULL, modified_ns INTEGER NOT NULL, metadata_json TEXT NOT NULL, state TEXT NOT NULL, skip_reason TEXT, rule_version INTEGER NOT NULL, attempt_id TEXT, placeholder_id TEXT, submitted_at REAL, definitely_not_committed INTEGER NOT NULL DEFAULT 0, success_id TEXT, success_metadata_json TEXT, succeeded_at REAL, retry_count INTEGER NOT NULL DEFAULT 0, next_retry_at REAL, last_error TEXT);
        INSERT INTO source VALUES ('source', '/fixture', 1, 0);
        INSERT INTO file_record (id, created_order, source_id, relative_path, filename, size, modified_ns, metadata_json, state, rule_version, success_id, success_metadata_json, attempt_id, placeholder_id, submitted_at, definitely_not_committed) VALUES ('success', 1, 'source', 'a.jpg', 'a.jpg', 4, 5, '{}', 'imported', 1, 'photos-success', '{"exact":"history"}', 'successful-attempt', 'placeholder-success', 123.5, 0), ('unknown', 2, 'source', 'b.jpg', 'b.jpg', 6, 7, '{}', 'importing', 1, NULL, NULL, 'unknown-attempt', 'placeholder-unknown', 124.75, 0);
        PRAGMA user_version = 3;
        """, at: db)
    }
    private func facts(at db: URL) throws -> [[String?]] {
        var handle: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(db.path, &handle) == SQLITE_OK else { throw FixtureError.unavailable("sqlite") }
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        let sql = "SELECT state, success_id, success_metadata_json, attempt_id, placeholder_id, submitted_at, definitely_not_committed FROM file_record ORDER BY created_order"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.unavailable("query") }
        var result = [[String?]]()
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<7).map { i in sqlite3_column_text(statement, Int32(i)).map { String(cString: $0) } })
        }
        return result
    }
    private func configurationFiles() throws -> URL {
        let root = try temporaryDirectory()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let research = repository.appendingPathComponent("docs/research/advanced-dedup")
        for (from, to) in [("integration-decision.json", "decision.json"), ("integration-profile.json", "profile.json"), ("2026-10-05-threshold-098-regression.json", "regression.json"), ("research-closeout.json", "closeout.json")] {
            try FileManager.default.copyItem(at: research.appendingPathComponent(from), to: root.appendingPathComponent(to))
        }
        return root
    }
    private func mutate(_ root: URL, file: String, _ change: (inout [String: Any]) -> Void) throws {
        let url = root.appendingPathComponent(file)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        change(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }
    private func rebind(_ root: URL) throws {
        func hash(_ file: String) throws -> String { SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(file))).map { String(format: "%02x", $0) }.joined() }
        let decisionHash = try hash("decision.json")
        try mutate(root, file: "profile.json") { $0["acceptanceID"] = "user-decision:" + decisionHash }
        let profileHash = try hash("profile.json")
        try mutate(root, file: "regression.json") { $0["decisionSHA256"] = decisionHash; $0["integrationProfileSHA256"] = profileHash }
        let regressionHash = try hash("regression.json")
        try mutate(root, file: "closeout.json") {
            $0["decisionSHA256"] = decisionHash; $0["profileSHA256"] = profileHash; $0["acceptanceID"] = "user-decision:" + decisionHash
            var r = $0["regression"] as! [String: Any]; r["sha256"] = regressionHash; $0["regression"] = r
        }
    }
}

private struct P5InvalidValidity: PhotosCandidateValidity {
    func commitIfCurrent(_ commit: @escaping @Sendable () throws -> Void) throws -> Bool { false }
}

private struct P5BeforeTransactionValidity: PhotosCandidateValidity {
    let database: URL
    func commitIfCurrent(_ commit: @escaping @Sendable () throws -> Void) throws -> Bool {
        // A second connection can acquire the write lock before the gate enters the
        // store closure. Acquiring BEGIN before this gate would fail with SQLITE_BUSY.
        try injectEngineSQL("BEGIN IMMEDIATE; COMMIT;", at: database)
        try commit()
        return true
    }
}
