import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import PhotoSyncCore

final class AdvancedDedupStoreTests: XCTestCase {
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
