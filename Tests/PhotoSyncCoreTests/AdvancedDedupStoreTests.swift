import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import PhotoSyncCore

final class AdvancedDedupStoreTests: XCTestCase {
    func testOldSuccessfulFingerprintVersionIsRetainedAndNotSilentlyIgnored() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let old = try await prepared(store, source, root, "old-success.jpg", version: "old")
        let attempt = UUID(); try await store.beginAttempt(fileID: old.fileID, attemptID: attempt)
        try await store.markImported(fileID: old.fileID, attemptID: attempt, identifier: "retained", sourceFingerprint: old)
        let incoming = try await prepared(store, source, root, "incoming.jpg")
        try await publishEmpty(store)
        let token = try await unwrap(try await store.indexReadiness()).token
        let bytes = try Data(contentsOf: db)
        let accepted = try await store.beginAdvancedAttempt(admission(store, incoming), attemptID: UUID())
        XCTAssertFalse(accepted, "Durable admission must independently block unsupported success history")
        do {
            _ = try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10)
            XCTFail("Old success cannot disappear from comparison")
        } catch is ModelExecutionUnavailable { }
        XCTAssertEqual(try Data(contentsOf: db), bytes)
        let fact = try await store.file(sourceID: source, relativePath: old.file.relativePath)
        XCTAssertEqual(fact?.successID, "retained"); XCTAssertEqual(fact?.state, .imported)
        let held = try await store.fingerprint(fileID: old.fileID, stamp: old.file.stamp, version: "old")
        XCTAssertEqual(held, old.fingerprint)
    }

    func testSQLiteStepFailureDiscardsHitsAndFinalizesReadSnapshot() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        _ = try await prepared(store, source, root, "first-hit.jpg")
        let bad = try await prepared(store, source, root, "second-error.jpg")
        let incoming = try await prepared(store, source, root, "incoming.jpg")
        try await publishEmpty(store)
        let token = try await unwrap(try await store.indexReadiness()).token
        try injectEngineSQL("""
            ALTER TABLE file_fingerprint RENAME TO saved_fingerprint;
            CREATE VIEW file_fingerprint AS SELECT file_id,size,modified_ns,fingerprint_version,purpose,width,height,
                CASE WHEN file_id = '\(bad.fileID.uuidString)' THEN abs(-9223372036854775808) ELSE vector END AS vector,
                attempt_id FROM saved_fingerprint;
            """, at: db)
        do {
            _ = try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10)
            XCTFail("SQLite step failure returned a partial result")
        } catch SyncStoreError.sqlite(let detail) { XCTAssertTrue(detail.contains("overflow")) }
        try injectEngineSQL("DROP VIEW file_fingerprint; ALTER TABLE saved_fingerprint RENAME TO file_fingerprint;", at: db)
        let recovered = try await unwrap(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10))
        XCTAssertEqual(recovered.matches.count, 2)
    }

    func testSQLiteQueryEligibilityCancellationAndExpiredTokens() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var sourceIDs = [UUID](), roots = [URL]()
        for name in ["active", "disabled", "removed", "history"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            roots.append(directory); sourceIDs.append(try await store.registerSource(url: directory))
        }
        let pending = try await prepared(store, sourceIDs[0], roots[0], "pending.jpg")
        let importing = try await prepared(store, sourceIDs[0], roots[0], "importing.jpg")
        try await store.beginAttempt(fileID: importing.fileID, attemptID: UUID())
        let skipped = try await prepared(store, sourceIDs[0], roots[0], "skipped.jpg")
        try await store.markSkipped(fileID: skipped.fileID, reason: .unsupportedFormat, candidates: [])
        _ = try await prepared(store, sourceIDs[1], roots[1], "disabled.jpg")
        _ = try await prepared(store, sourceIDs[2], roots[2], "removed.jpg")
        let history = try await prepared(store, sourceIDs[3], roots[3], "history.jpg")
        let attempt = UUID(); try await store.beginAttempt(fileID: history.fileID, attemptID: attempt)
        try await store.markImported(fileID: history.fileID, attemptID: attempt, identifier: "retained-success", sourceFingerprint: history)
        try await store.disableSource(id: sourceIDs[1]); try await store.removeSource(id: sourceIDs[2])
        try await store.removeSource(id: sourceIDs[3])
        _ = try await store.recordSourceChange(fileID: history.fileID, stamp: .init(size: 20, modifiedNanoseconds: 30))
        let changed = try await prepared(store, sourceIDs[0], roots[0], "stale-stamp.jpg")
        let version = try await prepared(store, sourceIDs[0], roots[0], "other-version.jpg")
        try injectEngineSQL("UPDATE file_fingerprint SET modified_ns = 99 WHERE file_id = '\(changed.fileID.uuidString)'; UPDATE file_fingerprint SET fingerprint_version = 'other' WHERE file_id = '\(version.fileID.uuidString)'", at: db)
        let incoming = try await prepared(store, sourceIDs[0], roots[0], "incoming.jpg")
        _ = try await prepared(store, sourceIDs[0], roots[0], "newer.jpg")
        try await publishEmpty(store)
        let token = try await unwrap(try await store.indexReadiness()).token
        let before = try Data(contentsOf: db)
        let result = try await unwrap(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10))
        XCTAssertEqual(Set(result.matches.map(\.key)), Set([pending, importing, history].map { "file:\($0.fileID.uuidString)" }))
        XCTAssertEqual(Set(result.matches.map(\.origin)), [.localPending, .localImporting, .successHistory])
        XCTAssertEqual(try Data(contentsOf: db), before, "Candidate queries must not write persistent facts")
        XCTAssertGreaterThanOrEqual(store.vectorQueryMmapBytes, 0)
        XCTAssertLessThanOrEqual(store.vectorQueryMmapBytes, 2147483648)
        let stale = [
            IndexToken(context: .init(id: UUID(), epoch: token.context.epoch), photosGeneration: token.photosGeneration, indexGeneration: token.indexGeneration, localRevision: token.localRevision, fingerprintVersion: token.fingerprintVersion),
            IndexToken(context: .init(id: token.context.id, epoch: token.context.epoch + 1), photosGeneration: token.photosGeneration, indexGeneration: token.indexGeneration, localRevision: token.localRevision, fingerprintVersion: token.fingerprintVersion),
            IndexToken(context: token.context, photosGeneration: token.photosGeneration + 1, indexGeneration: token.indexGeneration, localRevision: token.localRevision, fingerprintVersion: token.fingerprintVersion),
            IndexToken(context: token.context, photosGeneration: token.photosGeneration, indexGeneration: token.indexGeneration + 1, localRevision: token.localRevision, fingerprintVersion: token.fingerprintVersion),
            IndexToken(context: token.context, photosGeneration: token.photosGeneration, indexGeneration: token.indexGeneration, localRevision: token.localRevision + 1, fingerprintVersion: token.fingerprintVersion),
            IndexToken(context: token.context, photosGeneration: token.photosGeneration, indexGeneration: token.indexGeneration, localRevision: token.localRevision, fingerprintVersion: "other")]
        for old in stale {
            try await assertNil(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: old, threshold: 0.98, diagnosticLimit: 10))
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled query exposed a result") } catch is CancellationError {}
        for assignments in ["width=NULL", "height=0", "width='bad'"] {
            try injectEngineSQL("UPDATE file_fingerprint SET \(assignments) WHERE file_id = '\(pending.fileID.uuidString)'", at: db)
            await XCTAssertThrowsErrorAsync(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10))
            try injectEngineSQL("UPDATE file_fingerprint SET width=640,height=480 WHERE file_id = '\(pending.fileID.uuidString)'", at: db)
        }
    }

    func testSQLiteQueryRetainsAllMatchesAndSwiftUnicodeDiagnosticOrder() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try configurationFiles(); defer { try? FileManager.default.removeItem(at: files) }
        let config = try DedupConfiguration.loadValidated(resourceDirectory: files)
        let version = config.fingerprint.version
        let source = try await store.registerSource(url: root)
        let olderSeed = try await prepared(store, source, root, "older.jpg", version: version)
        let older = PreparedSource(fileID: olderSeed.fileID, file: olderSeed.file, fingerprint: olderSeed.fingerprint,
            size: try PixelSize(width: 1, height: 1))
        try await assertTrue(try await store.cacheFingerprint(older))
        let incoming = try await prepared(store, source, root, "incoming.jpg", version: version)
        let newer = try await prepared(store, source, root, "newer.jpg", version: version)
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 7, fingerprintVersion: version)
        let names = (0..<400).map { String(format: "tie-%03d", $0) } + ["é:原", "é:原", "😀:current", "字:原", "negative"]
        let descriptors = names.enumerated().map { i, name in
            RepresentationDescriptor(key: .init(assetID: name, kind: .original), context: context,
                revision: "A", size: try! PixelSize(width: i == 11 ? 1000 : 1, height: i == 11 ? 1000 : 1),
                equivalentToOriginal: false, revisionIsReliable: true)
        }
        try await store.upsertRepresentations(descriptors, generation: generation)
        let tasks = try await store.nextRepresentationTasks(now: Date(), limit: 1000)
        var oracle = [VectorEntry(key: "file:\(older.fileID.uuidString)", origin: .localPending, fingerprint: older.fingerprint, size: older.size)]
        for task in tasks {
            let asset = task.descriptor.key.assetID
            let vector = try Fingerprint(version: version, values: [asset == "negative" ? -1 : 1] + Array(repeating: 0, count: 1023))
            try await assertTrue(try await store.completeRepresentation(task, fingerprint: vector))
            oracle.append(.init(key: "photos:\(asset.utf8.count):\(asset):original", origin: .photosOriginal, fingerprint: vector, size: task.descriptor.size))
        }
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set((descriptors).map(\.key)))
        let publication = try await unwrap(try await store.indexPublication())
        try await assertTrue(try await store.markIndexPublished(token: publication.token))
        for threshold in [0.98, 1, -1] {
            let expected = try ExactVectorIndex.scoreWithDiagnostics(query: incoming.fingerprint, entries: oracle, minimumScore: threshold, diagnosticLimit: 10)
            let result = try await unwrap(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: publication.token, threshold: threshold, diagnosticLimit: 10))
            XCTAssertEqual(result.matches, expected.matches)
            XCTAssertEqual(result.diagnostics, expected.diagnostics)
            XCTAssertFalse(result.matches.contains { $0.key == "file:\(newer.fileID.uuidString)" || $0.key == "file:\(incoming.fileID.uuidString)" })
            if threshold == 0.98 {
                XCTAssertEqual(result.matches.count, 405)
                XCTAssertTrue(result.matches.contains { $0.size?.width == 1000 })
                XCTAssertFalse(result.diagnostics.contains { $0.size?.width == 1000 }, "Only a candidate beyond the diagnostic limit covers the source")
                let decision = try AdvancedDuplicatePolicy.evaluate(sourceSize: incoming.size, candidates: result.matches, configuration: config)
                XCTAssertEqual(decision.action, .skip)
                XCTAssertEqual(decision.coveringKeys, ["photos:7:tie-011:original"])
            }
        }
        let token = publication.token
        try await store.disableSource(id: source)
        try await assertNil(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation", at: db), names.count)
    }

    func testSQLiteQueryFailsForMalformedNonmatchAfterLegalHits() async throws {
        for payload in ["NULL", "X'0000'", vectorSQL(.nan), vectorSQL(.infinity), vectorSQL(0), vectorSQL(-2), vectorSQL(-0.5)] {
            let (root, db, store) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = try await store.registerSource(url: root)
            _ = try await prepared(store, source, root, "first-hit.jpg")
            let incoming = try await prepared(store, source, root, "incoming.jpg")
            let context = LibraryContext(id: UUID(), epoch: 1)
            let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
            try await store.upsertRepresentations([descriptor(context, asset: "a-hit"), descriptor(context, asset: "z-nonmatch")], generation: generation)
            for task in try await store.nextRepresentationTasks(now: Date(), limit: 2) {
                try await assertTrue(try await store.completeRepresentation(task, fingerprint: fingerprint("v1")))
            }
            try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context, asset: "a-hit"), descriptor(context, asset: "z-nonmatch")]).map(\.key)))
            let publication = try await unwrap(try await store.indexPublication())
            try await assertTrue(try await store.markIndexPublished(token: publication.token))
            let token = try await unwrap(try await store.indexReadiness()).token
            try injectEngineSQL("PRAGMA ignore_check_constraints = ON; UPDATE photos_representation SET vector = \(payload) WHERE asset_id = 'z-nonmatch'", at: db)
            await XCTAssertThrowsErrorAsync(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10))
        }
    }

    func testSQLiteQueryNormAndThresholdAdjacentFloatsMatchOracle() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let candidate = try await prepared(store, source, root, "candidate.jpg")
        let incoming = try await prepared(store, source, root, "incoming.jpg")
        try await publishEmpty(store)
        let token = try await unwrap(try await store.indexReadiness()).token
        let high = Float(sqrt(1.00001)), low = Float(sqrt(0.99999))
        for component in [high.nextDown, high, high.nextUp, low.nextDown, low, low.nextUp] {
            try injectEngineSQL("UPDATE file_fingerprint SET vector = \(vectorSQL(component)) WHERE file_id = '\(candidate.fileID.uuidString)'", at: db)
            let data = vectorData(component)
            if let vector = try? Fingerprint(version: "v1", littleEndianFloat32: data) {
                let expected = try ExactVectorIndex.scoreWithDiagnostics(query: incoming.fingerprint, entries: [.init(key: "file:\(candidate.fileID.uuidString)", origin: .localPending, fingerprint: vector, size: candidate.size)], minimumScore: 0.98, diagnosticLimit: 10)
                let actual = try await unwrap(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10))
                XCTAssertEqual(actual, expected)
            } else {
                await XCTAssertThrowsErrorAsync(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10))
            }
        }
        for score in [Float(0.98).nextDown, Float(0.98), Float(0.98).nextUp, Float(-0.98)] {
            let vector = try Fingerprint(version: "v1", values: [score, Float(sqrt(1 - Double(score) * Double(score)))] + Array(repeating: 0, count: 1022))
            try injectEngineSQL("UPDATE file_fingerprint SET vector = X'\(vector.littleEndianFloat32.map { String(format: "%02x", $0) }.joined())' WHERE file_id = '\(candidate.fileID.uuidString)'", at: db)
            let expected = try ExactVectorIndex.scoreWithDiagnostics(query: incoming.fingerprint, entries: [.init(key: "file:\(candidate.fileID.uuidString)", origin: .localPending, fingerprint: vector, size: candidate.size)], minimumScore: 0.98, diagnosticLimit: 10)
            let actual = try await unwrap(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10))
            XCTAssertEqual(actual, expected)
        }
    }

    private func vectorData(_ first: Float) -> Data {
        var bytes = Data(count: 4096)
        for i in 0..<4 { bytes[i] = UInt8(truncatingIfNeeded: first.bitPattern >> (8 * i)) }
        return bytes
    }
    private func vectorSQL(_ first: Float) -> String {
        "X'\(vectorData(first).map { String(format: "%02x", $0) }.joined())'"
    }
    private func photosVector(at database: URL) throws -> Fingerprint {
        var handle: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK else { throw FixtureError.unavailable("sqlite") }
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        guard sqlite3_prepare_v2(handle, "SELECT fingerprint_version, vector FROM photos_representation WHERE tombstoned = 0", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let version = sqlite3_column_text(statement, 0),
              let bytes = sqlite3_column_blob(statement, 1) else { throw FixtureError.unavailable("vector") }
        return try Fingerprint(version: String(cString: version), littleEndianFloat32: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))))
    }

    func testPublicationContainsOnlyTokenAndRepresentationCount() async throws {
        let (root, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        let task = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        try await assertTrue(try await store.completeRepresentation(task, fingerprint: fingerprint("v1")))
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context)]).map(\.key)))
        let publication = try await unwrap(try await store.indexPublication())
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(publication)) as! [String: Any]
        XCTAssertEqual(Set(fields.keys), ["token", "representationCount"], "Publication must not retain or copy every gallery vector")
        XCTAssertEqual(fields["representationCount"] as? Int, 1)
    }

    func testLocalRevisionChangesWithCandidateLifecycle() async throws {
        let (root, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let generation = try await store.beginIndexReconciliation(context: .init(id: UUID(), epoch: 1), photosGeneration: 1, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: generation, seenKeys: [])
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
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(library, asset: "original-success")]).map(\.key)))
        try await assertEqual(try await store.indexPublication()?.representationCount, 1)
        generation = try await store.beginIndexReconciliation(context: library, photosGeneration: 3, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: generation, seenKeys: [])
        try await assertEqual(try await store.indexPublication()?.representationCount, 0)
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
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context, asset: "asset:é")]).map(\.key)))
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
            try injectEngineSQL(sql + "DROP TABLE photos_index_exclusion; PRAGMA user_version = 4;", at: db)
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
            XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), fail ? 4 : 6)
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

    private func prepared(_ store: SyncStore, _ source: UUID, _ root: URL, _ path: String, cache: Bool = true, version: String = "v1") async throws -> PreparedSource {
        let file = SourceFile(sourceID: source, relativePath: path, url: root.appendingPathComponent(path),
            stamp: .init(size: 10, modifiedNanoseconds: 12), metadata: .init(filename: path, kind: .image,
                captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: 640, height: 480, duration: nil))
        let id = try await store.save(file, decision: .importNew)
        let result = PreparedSource(fileID: id, file: file, fingerprint: try fingerprint(version), size: try PixelSize(width: 640, height: 480))
        if cache { _ = try await store.cacheFingerprint(result) }
        return result
    }

    private func publishEmpty(_ store: SyncStore) async throws {
        let generation = try await store.beginIndexReconciliation(context: .init(id: UUID(), epoch: 1), photosGeneration: 1, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: generation, seenKeys: [])
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
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 6)
        XCTAssertEqual(try facts(at: db), before)
        let generation = try await store.beginIndexReconciliation(context: LibraryContext(id: UUID(), epoch: 1), photosGeneration: 4, fingerprintVersion: "new-model")
        try await store.finishIndexReconciliation(generation: generation, seenKeys: [])
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
        try injectEngineSQL("PRAGMA user_version = 7", at: db)
        XCTAssertThrowsError(try SyncStore(url: db))
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 7)
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
        try await store.finishIndexReconciliation(generation: first, seenKeys: Set(([descriptor(context, asset: "one"), descriptor(context, asset: "two")]).map(\.key)))
        let second = try await store.beginIndexReconciliation(context: context, photosGeneration: 2, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context, asset: "one")], generation: second)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE tombstoned = 0", at: db), 2)
        try await assertNil(try await store.indexPublication())
        try await store.finishIndexReconciliation(generation: first, seenKeys: Set(([descriptor(context, asset: "one"), descriptor(context, asset: "two")]).map(\.key))) // Stale finish cannot delete anything.
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE tombstoned = 0", at: db), 2)
        try await store.finishIndexReconciliation(generation: second, seenKeys: Set(([descriptor(context, asset: "one")]).map(\.key)))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE tombstoned = 0", at: db), 1)
    }

    func testCommittedVectorsCanRebuildPublicationButRequireExactPublishToken() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 9, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context)]).map(\.key)))
        try await assertNil(try await store.indexPublication())
        let tasks = try await store.nextRepresentationTasks(now: Date(), limit: 1)
        try await assertTrue(try await store.completeRepresentation(try XCTUnwrap(tasks.first), fingerprint: fingerprint("v1")))
        let reopened = try SyncStore(url: db)
        let publication = try await unwrap(try await reopened.indexPublication())
        XCTAssertEqual(publication.representationCount, 1)
        XCTAssertEqual(try photosVector(at: db), try fingerprint("v1"))
        try await assertFalse(try await reopened.indexIsReady(token: publication.token))
        try await assertTrue(try await reopened.markIndexPublished(token: publication.token))
        try await assertTrue(try await reopened.indexIsReady(token: publication.token))
        let next = try await store.beginIndexReconciliation(context: context, photosGeneration: 10, fingerprintVersion: "v1")
        try await assertFalse(try await reopened.markIndexPublished(token: publication.token))
        try await assertFalse(try await reopened.indexIsReady(token: publication.token))
        try await store.upsertRepresentations([descriptor(context)], generation: next)
        try await store.finishIndexReconciliation(generation: next, seenKeys: Set(([descriptor(context)]).map(\.key)))
        try await assertTrue(try await store.nextRepresentationTasks(now: Date(), limit: 10).isEmpty)
        try await assertEqual(try await store.indexPublication()?.representationCount, 1)
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
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context)]).map(\.key)))
        generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 2, fingerprintVersion: "v2")
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context)]).map(\.key)))
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
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context)]).map(\.key)))
        let task = try await unwrap(try await store.nextRepresentationTasks(now: Date(timeIntervalSince1970: 100), limit: 1).first)
        try await store.failRepresentation(task, nextRetryAt: Date(timeIntervalSince1970: 200), detail: "unavailable")
        try await assertTrue(try await store.nextRepresentationTasks(now: Date(timeIntervalSince1970: 199), limit: 1).isEmpty)
        let due = try await store.nextRepresentationTasks(now: Date(timeIntervalSince1970: 200), limit: 1)
        XCTAssertEqual(due.first?.retryCount, 1)
        try await assertTrue(try await store.completeRepresentation(try XCTUnwrap(due.first), fingerprint: fingerprint("v1")))
        try injectEngineSQL("PRAGMA ignore_check_constraints = ON; UPDATE photos_representation SET vector = X'0000'", at: db)
        let metadata = try await unwrap(try await store.indexPublication())
        XCTAssertEqual(metadata.representationCount, 1)
        try await assertTrue(try await store.markIndexPublished(token: metadata.token))
        let source = try await store.registerSource(url: root)
        let incoming = try await prepared(store, source, root, "incoming.jpg")
        let token = try await unwrap(try await store.indexReadiness()).token
        await XCTAssertThrowsErrorAsync(try await store.vectorCandidates(for: incoming.fileID, query: incoming.fingerprint, token: token, threshold: 0.98, diagnosticLimit: 10))
    }

    func testUserSelectedConfigurationLoadsWithoutStatisticalPass() throws {
        let root = try configurationFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try DedupConfiguration.loadValidated(resourceDirectory: root)
        XCTAssertEqual(configuration.threshold, 0.98)
        XCTAssertEqual(configuration.backend, "sqlite-exact-f32-v1")
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
        let validRoot = try configurationFiles()
        defer { try? FileManager.default.removeItem(at: validRoot) }
        XCTAssertNoThrow(try DedupConfiguration.loadValidated(resourceDirectory: validRoot))
        try mutate(validRoot, file: "profile.json") { $0["acceptanceID"] = "research:old" }
        XCTAssertThrowsError(try DedupConfiguration.loadValidated(resourceDirectory: validRoot)) {
            XCTAssertEqual($0 as? AdvancedDedupError, .invalidConfiguration)
        }
    }

    func testThresholdMustMatchDecisionAndPolicyVersion() throws {
        let root = try configurationFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        try mutate(root, file: "profile.json") { $0["threshold"] = 0.97 }
        XCTAssertThrowsError(try DedupConfiguration.loadValidated(resourceDirectory: root))
        // Even a valid recomputed policy cannot change the selection without a new bound decision.
        try mutate(root, file: "profile.json") {
            let fingerprint = $0["fingerprint"] as! [String: Any]
            $0["policyVersion"] = DedupConfiguration.computePolicyVersion(fingerprintVersion: fingerprint["version"] as! String, threshold: 0.97, backend: "sqlite-exact-f32-v1")
        }
        try rebind(root)
        XCTAssertThrowsError(try DedupConfiguration.loadValidated(resourceDirectory: root))
    }

    func testBoundResourcesRejectAnOldOrUnrecognizedQueryBackend() throws {
        for backend in ["exact-f32-v1", "sqlite-vec", "sqlite-exact-f32-v2"] {
            let root = try configurationFiles()
            defer { try? FileManager.default.removeItem(at: root) }
            let original = try DedupConfiguration.loadValidated(resourceDirectory: root)
            let policy = DedupConfiguration.computePolicyVersion(fingerprintVersion: original.fingerprint.version,
                threshold: original.threshold, backend: backend)
            XCTAssertNotEqual(policy, original.policyVersion)
            try mutate(root, file: "decision.json") {
                var selected = $0["configuration"] as! [String: Any]
                selected["backend"] = backend; selected["policyVersion"] = policy; $0["configuration"] = selected
            }
            for file in ["profile.json", "regression.json", "closeout.json"] {
                try mutate(root, file: file) { $0["backend"] = backend; $0["policyVersion"] = policy }
            }
            try rebind(root)
            XCTAssertThrowsError(try DedupConfiguration.loadValidated(resourceDirectory: root), backend)
        }
    }

    func testReopenedStoreRequiresDerivedIndexRepublication() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: generation, seenKeys: [])
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
        try await store.finishIndexReconciliation(generation: generation, seenKeys: [])
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
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context)]).map(\.key)))
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
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context)]).map(\.key)))
        generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 2, fingerprintVersion: changed.fingerprint.version)
        try await store.upsertRepresentations([descriptor(context)], generation: generation)
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context)]).map(\.key)))
        try await assertTrue(try await store.nextRepresentationTasks(now: Date(), limit: 10).isEmpty)
        try await assertEqual(try await store.indexPublication()?.representationCount, 1)
        XCTAssertEqual(try facts(at: db), before)
    }

    func testV5MigrationPreservesVectorBytesAndRetryIssuanceAndRevokesPublication() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let a = descriptor(context, asset: "a"), b = descriptor(context, asset: "b")
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([a,b], generation: generation)
        try await store.finishIndexReconciliation(generation: generation, seenKeys: [a.key,b.key])
        let tasks = try await store.nextRepresentationTasks(now: Date(), limit: 2)
        _ = try await store.completeRepresentation(tasks[0], fingerprint: fingerprint("v1"))
        _ = try await store.failRepresentation(tasks[1], nextRetryAt: Date(timeIntervalSince1970: 9999999999), detail: "cloud")
        try injectEngineSQL("""
            CREATE TABLE before_vectors AS SELECT asset_id,vector FROM photos_representation;
            CREATE TABLE before_tasks AS SELECT asset_id,revision,generation,retry_count,next_retry_at,last_error FROM fingerprint_task;
            DROP TABLE photos_content_change;
            ALTER TABLE fingerprint_task DROP COLUMN issuance_revision;
            PRAGMA user_version=5;
            """, at: db)
        let reopened = try SyncStore(url: db)
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 6)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM before_vectors EXCEPT SELECT asset_id,vector FROM photos_representation)", at: db), 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM (SELECT * FROM before_tasks EXCEPT SELECT asset_id,revision,generation,retry_count,next_retry_at,last_error FROM fingerprint_task)", at: db), 0)
        let publication = try await reopened.indexPublication(); XCTAssertNil(publication)
    }

    func testJournalSeparatesProcessGenerationsAndKeepsUncoveredObligations() throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1), oldRun = UUID(), newRun = UUID()
        try store.recordPhotosChanges(context: context, runID: oldRun, generation: 100,
            changed: ["old"], deleted: [], content: ["old"], batchSize: 1)
        let reopened = try SyncStore(url: db)
        try reopened.recordPhotosChanges(context: context, runID: newRun, generation: 1,
            changed: ["neutral"], deleted: [], content: [], batchSize: 1)
        try reopened.recordPhotosChanges(context: context, runID: newRun, generation: 2,
            changed: ["later"], deleted: [], content: ["later"], batchSize: 1)
        XCTAssertEqual(try reopened.photosContentChanges(context: context, assetIDs: ["old","neutral","later"]), ["later","old"])
        let batch = try reopened.photosCatalogChanges(context: context, runID: newRun, afterGeneration: 0, throughGeneration: 1, afterAssetID: nil, limit: 128)
        XCTAssertEqual(batch.changedAssetIDs, ["neutral"])
        try reopened.acknowledgePhotosChanges(context: context, runID: newRun, throughGeneration: 1)
        XCTAssertEqual(try reopened.photosContentChanges(context: context, assetIDs: ["old","neutral","later"]), ["later"])
    }

    func testPartialDeltaCrashCannotSkipABatchOrPublishTheInterval() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let values = ["a","b","c"].map { descriptor(context, asset: $0) }
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations(values, generation: generation)
        let checkpoint = LibraryResumeCheckpoint(context: context, archivedChangeToken: Data([1]), photosGeneration: 1)
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(values.map(\.key)), checkpoint: checkpoint)
        let interval = PhotosIndexDelta(context: context, fromGeneration: 1, toGeneration: 2, changedAssetIDs: ["a","b","c"], deletedAssetIDs: [])
        func page(_ index: Int) -> RepresentationPage { .init(context: context, generation: 2, descriptors: [values[index]], nextOffset: nil, invalidatedAssetIDs: [values[index].key.assetID]) }
        _ = try await store.applyIndexDeltaBatch(.init(interval: interval, offset: 0, count: 1), page: page(0), fingerprintVersion: "v1", checkpoint: nil)
        let reopened = try SyncStore(url: db)
        let oldCheckpoint = try await reopened.libraryResumeCheckpoint(); XCTAssertEqual(oldCheckpoint, checkpoint)
        let publication = try await reopened.indexPublication(); XCTAssertNil(publication)
        await XCTAssertThrowsErrorAsync(try await reopened.applyIndexDeltaBatch(.init(interval: interval, offset: 2, count: 1), page: page(2), fingerprintVersion: "v1", checkpoint: nil))
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM photos_representation WHERE tombstoned=0", at: db), 3)
        _ = try await reopened.applyIndexDeltaBatch(.init(interval: interval, offset: 1, count: 1), page: page(1), fingerprintVersion: "v1", checkpoint: nil)
        _ = try await reopened.applyIndexDeltaBatch(.init(interval: interval, offset: 2, count: 1), page: page(2), fingerprintVersion: "v1", checkpoint: .init(context: context, archivedChangeToken: Data([2]), photosGeneration: 2))
        XCTAssertEqual(try engineSQLInteger("SELECT reconciliation_complete FROM dedup_index_state", at: db), 1)
    }

    func testUnchangedTaskCanCompleteAcrossGlobalGeneration() async throws {
        let (root, _, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let first = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context)], generation: first)
        let stale = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        let next = try await store.beginIndexReconciliation(context: context, photosGeneration: 2, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context)], generation: next)
        let current = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        XCTAssertEqual(current.indexGeneration, first)
        try await assertTrue(try await store.completeRepresentation(stale, fingerprint: fingerprint("v1")))
    }

    func testDeltaTransactionBindsBaselinePageCheckpointAndTaskIssuance() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let a = descriptor(context, asset: "a"), b = descriptor(context, asset: "b")
        let first = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([a, b], generation: first)
        try await store.finishIndexReconciliation(generation: first, seenKeys: [a.key, b.key])
        let tasks = try await store.nextRepresentationTasks(now: Date(), limit: 2)
        for issuance in [Int64(0), -1, first + 1] {
            try injectEngineSQL("UPDATE photos_representation SET seen_generation=\(issuance) WHERE asset_id='a'; UPDATE fingerprint_task SET generation=\(issuance) WHERE asset_id='a';", at: db)
            let impossible = RepresentationTask(descriptor: a, retryCount: 0, nextRetryAt: nil, fingerprintVersion: "v1", indexGeneration: issuance)
            try await assertFalse(try await store.completeRepresentation(impossible, fingerprint: fingerprint("v1")))
            let poll = try await store.nextRepresentationTasks(now: Date(), limit: 2)
            XCTAssertEqual(poll.map { $0.descriptor.key.assetID }, ["b"])
        }
        try injectEngineSQL("UPDATE photos_representation SET seen_generation=\(first) WHERE asset_id='a'; UPDATE fingerprint_task SET generation=\(first) WHERE asset_id='a';", at: db)
        let delta = PhotosIndexDelta(context: context, fromGeneration: 1, toGeneration: 2, changedAssetIDs: ["a"], deletedAssetIDs: [])
        let valid = RepresentationPage(context: context, generation: 2, descriptors: [a], nextOffset: nil, invalidatedAssetIDs: ["a"])
        for page in [RepresentationPage(context: context, generation: 2, descriptors: [], nextOffset: nil),
                     RepresentationPage(context: context, generation: 2, descriptors: [a], nextOffset: 1),
                     RepresentationPage(context: context, generation: 3, descriptors: [a], nextOffset: nil)] {
            await XCTAssertThrowsErrorAsync(try await store.applyIndexDelta(delta, page: page, fingerprintVersion: "v1", checkpoint: nil))
        }
        await XCTAssertThrowsErrorAsync(try await store.applyIndexDelta(delta, page: valid, fingerprintVersion: "v1",
            checkpoint: .init(context: context, archivedChangeToken: Data([1]), photosGeneration: 1)))
        XCTAssertEqual(try engineSQLInteger("SELECT generation FROM dedup_index_state", at: db), Int(first))
        XCTAssertEqual(try engineSQLInteger("SELECT SUM(generation) FROM fingerprint_task", at: db), 2 * Int(first))
        let next = try await store.applyIndexDelta(delta, page: valid, fingerprintVersion: "v1",
            checkpoint: .init(context: context, archivedChangeToken: Data([2]), photosGeneration: 2))
        XCTAssertGreaterThan(next, first)
        let oldA = try XCTUnwrap(tasks.first { $0.descriptor.key.assetID == "a" })
        let oldB = try XCTUnwrap(tasks.first { $0.descriptor.key.assetID == "b" })
        try await assertFalse(try await store.completeRepresentation(oldA, fingerprint: fingerprint("v1")))
        try await assertTrue(try await store.completeRepresentation(oldB, fingerprint: fingerprint("v1")))
        let current = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        XCTAssertEqual(current.indexGeneration, next)
        try await assertTrue(try await store.completeRepresentation(current, fingerprint: fingerprint("v1")))
        let publication = try await store.indexPublication(); XCTAssertEqual(publication?.representationCount, 2)
        await XCTAssertThrowsErrorAsync(try await store.applyIndexDelta(delta, page: valid, fingerprintVersion: "v1", checkpoint: nil))
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

    func testReadinessIndexPreservesEveryIntegrityGuardAndExtendsV4() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = LibraryContext(id: UUID(), epoch: 1)
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await store.upsertRepresentations([descriptor(context, asset: "a")], generation: generation)
        let task = try await unwrap(try await store.nextRepresentationTasks(now: Date(), limit: 1).first)
        let vector = try Fingerprint(version: "v1", values: [1] + Array(repeating: 0, count: 1023))
        try await assertTrue(try await store.completeRepresentation(task, fingerprint: vector))
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set(([descriptor(context, asset: "a")]).map(\.key)))
        let indexSQL = "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='photos_representation_readiness'"
        XCTAssertEqual(try engineSQLInteger(indexSQL, at: db), 1)
        let hex = vector.littleEndianFloat32.map { String(format: "%02x", $0) }.joined()
        for corruption in ["seen_generation=0", "seen_generation=-1", "seen_generation=99999", "state='pending'", "fingerprint_version='other'", "vector=NULL"] {
            try injectEngineSQL("UPDATE photos_representation SET \(corruption)", at: db)
            try await assertNil(try await store.indexReadiness())
            try injectEngineSQL("UPDATE photos_representation SET seen_generation=\(generation),state='ready',fingerprint_version='v1',vector=X'\(hex)'", at: db)
            let ready = try await store.indexReadiness(); XCTAssertEqual(ready?.entryCount, 1)
        }
        try injectEngineSQL("UPDATE photos_representation SET tombstoned=1", at: db)
        let tombstoned = try await store.indexReadiness(); XCTAssertEqual(tombstoned?.entryCount, 0)
        try injectEngineSQL("UPDATE photos_representation SET tombstoned=0; PRAGMA user_version=4; DROP TABLE photos_index_exclusion; DROP INDEX IF EXISTS photos_representation_readiness", at: db)
        let upgraded = try SyncStore(url: db)
        XCTAssertEqual(try engineSQLInteger(indexSQL, at: db), 1)
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 6)
        let after = try await upgraded.indexReadiness(); XCTAssertNil(after)
        let publication = try await upgraded.indexPublication()
        XCTAssertEqual(try photosVector(at: db), vector)
        XCTAssertNil(publication)
        let refreshed = try await upgraded.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        try await upgraded.upsertRepresentations([descriptor(context, asset: "a")], generation: refreshed)
        try await upgraded.finishIndexReconciliation(generation: refreshed, seenKeys: [descriptor(context, asset: "a").key])
        let restored = try await upgraded.indexReadiness(); XCTAssertEqual(restored?.entryCount, 1)
    }

    func testFreshDependencyReverseQueriesUseIndexedLookup() throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try assertReverseDependencyLookup(at: db)
        withExtendedLifetime(store) {}
    }

    func testV4ExtensionAddsReverseIndexWithoutLosingEdges() async throws {
        let (root, db, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await store.registerSource(url: root)
        let candidate = try await prepared(store, source, root, "candidate.jpg")
        let dependent = try await prepared(store, source, root, "dependent.jpg")
        try await publishEmpty(store)
        try await assertTrue(try await store.commitAdvancedSkip(admission(store, dependent, candidate: candidate)))
        // Reproduce the previous unreleased integration-v4 shape without its reverse index.
        try injectEngineSQL("PRAGMA user_version=4; DROP TABLE photos_index_exclusion; DROP INDEX IF EXISTS dedup_dependency_candidate;", at: db)
        let migrated = try SyncStore(url: db)
        XCTAssertEqual(try engineSQLInteger("PRAGMA user_version", at: db), 6)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM dedup_dependency", at: db), 1)
        try await assertEqual(try await migrated.state(of: dependent.fileID), .skipped)
        try assertReverseDependencyLookup(at: db)
        // The preserved edge still points to the original candidate after extension.
        try await assertTrue(try await migrated.removeConfirmedAbsentPending(fileID: candidate.fileID))
        try await assertEqual(try await migrated.state(of: dependent.fileID), .pending)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM dedup_dependency", at: db), 0)
    }

    private func assertReverseDependencyLookup(at db: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(db.path, &handle) == SQLITE_OK else { throw FixtureError.unavailable("sqlite") }
        defer { sqlite3_close(handle) }
        for sql in ["SELECT file_id FROM dedup_dependency WHERE candidate_file_id = ?",
                    "DELETE FROM dedup_dependency WHERE candidate_file_id = ?"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil) == SQLITE_OK else {
                throw FixtureError.unavailable("dependency query plan")
            }
            defer { sqlite3_finalize(statement) }
            var plan = [String]()
            while sqlite3_step(statement) == SQLITE_ROW {
                plan.append(String(cString: sqlite3_column_text(statement, 3)))
            }
            XCTAssertTrue(plan.contains { $0.contains("SEARCH dedup_dependency") && $0.contains("candidate_file_id=?") },
                          "Reverse lookup must search by candidate, not scan all edges: \(sql): \(plan)", file: file, line: line)
        }
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
        let resources = try DedupConfiguration.bundledResourceDirectory()
        for name in ["decision.json", "profile.json", "regression.json", "closeout.json", "execution-policy.json", "ModelSelfTest"] {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: root.appendingPathComponent(name))
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
