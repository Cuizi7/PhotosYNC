import XCTest
@testable import PhotoSyncCore

final class EngineTests: XCTestCase {
    func testTwoSourcesSubmitOnlyOnce() async throws {
        let f = try await makeEngineFixture()
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let again = await f.photos.createCount
        XCTAssertEqual(again, 1)
    }

    func testDeletedTargetAndChangedSourceKeepSuccessfulHistory() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let beforeOptional = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let status = await f.engine.snapshot()
        let before = try XCTUnwrap(beforeOptional, "snapshot: \(status)")
        await f.photos.setCandidates([])
        try Data("changed".utf8).write(to: f.directories[0].appendingPathComponent("same.jpg"))
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let afterOptional = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let after = try XCTUnwrap(afterOptional)
        XCTAssertEqual(after.successID, before.successID)
        XCTAssertEqual(after.state, .skipped)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1)
    }

    func testIndexFailureNeverSubmits() async throws {
        let f = try await makeEngineFixture()
        await f.photos.setLoadFailure(true)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 0)
        let snapshot = await f.engine.snapshot()
        XCTAssertNotNil(snapshot.blockingError)
    }

    func testPendingResumesAndUnknownImportNeverRetries() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let file = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        let id = try await f.store.save(file, decision: .importNew)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1)
        let state = try await f.store.state(of: id)
        XCTAssertEqual(state, .imported)

        let other = try await makeEngineFixture(sourceCount: 1)
        let uncertain = try await engineSourceFile(sourceID: other.sourceIDs[0], directory: other.directories[0])
        let unknownID = try await other.store.save(uncertain, decision: .importNew)
        try await other.store.beginAttempt(fileID: unknownID, attemptID: UUID())
        await other.engine.scan(sourceIDs: other.sourceIDs)
        let unknownCount = await other.photos.createCount
        XCTAssertEqual(unknownCount, 0)
        let unknownState = try await other.store.state(of: unknownID)
        XCTAssertEqual(unknownState, .importing)
    }

    func testLivePhotosSlotAllowsLaterSourceScanWithoutAnotherCreate() async throws {
        let f = try await makeEngineFixture()
        try FileManager.default.moveItem(at: f.directories[1].appendingPathComponent("same.jpg"), to: f.directories[1].appendingPathComponent("different.jpg"))
        let gate = EngineTestGate()
        await f.photos.setCreationGate(gate)
        let first = Task { await f.engine.scan(sourceIDs: [f.sourceIDs[0]]) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        let second = Task { await f.engine.scan(sourceIDs: [f.sourceIDs[1]]) }
        let scanned = try await engineEventually { try await f.store.file(sourceID: f.sourceIDs[1], relativePath: "different.jpg") != nil }
        XCTAssertTrue(scanned, "A live Photos callback must not block later source scans")
        let heldCount = await f.photos.createCount
        XCTAssertEqual(heldCount, 1)
        let heldSnapshot = await f.engine.snapshot()
        XCTAssertEqual(heldSnapshot.pending, 1)
        await f.engine.pause()
        await gate.release()
        await first.value; await second.value
        let imported = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(imported?.state, .imported, "Late committed callback survives pause")
    }

    func testSlowSourceDoesNotBlockHealthySource() async throws {
        let f = try await makeEngineFixture()
        let gate = EngineTestGate()
        let slowID = f.sourceIDs[0]
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { id in
            if id == slowID { return GatedDirectoryReader(reader: DirectoryReader(sourceID: id), gate: gate) }
            return DirectoryReader(sourceID: id)
        })
        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let healthyImported = await engineEventually { await f.photos.createCount == 1 }
        XCTAssertTrue(healthyImported)
        await gate.release()
        await scan.value
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1)
    }

    func testSuccessfulCreateStorageFailureStopsSecondCreate() async throws {
        let f = try await makeEngineFixture()
        try FileManager.default.moveItem(at: f.directories[1].appendingPathComponent("same.jpg"), to: f.directories[1].appendingPathComponent("different.jpg"))
        try injectEngineSQL("CREATE TRIGGER fail_success BEFORE UPDATE ON file_record WHEN NEW.state = 'imported' BEGIN SELECT RAISE(FAIL, 'injected success persistence failure'); END", at: f.databaseURL)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1)
        let snapshot = await f.engine.snapshot()
        XCTAssertNotNil(snapshot.blockingError)
        let uncertain = try await f.store.listFiles(state: .importing, afterID: nil, limit: 10)
        XCTAssertEqual(uncertain.count, 1)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let again = await f.photos.createCount
        XCTAssertEqual(again, 1)
    }

    func testUnreadableMetadataLeavesNoRecordAndRecoversNextScan() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let url = f.directories[0].appendingPathComponent("same.jpg")
        let bytes = try Data(contentsOf: url)
        try Data("bad JPEG".utf8).write(to: url)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let missing = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertNil(missing)
        let failed = await f.engine.snapshot().failed
        XCTAssertEqual(failed, 1)
        try bytes.write(to: url)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let recovered = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(recovered?.state, .imported)
    }

    func testMultipleCandidatesSkipAndDisabledSourceRetainsHistory() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let source = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        await f.photos.setCandidates([MatchCandidate(key: "a", metadata: source.metadata), MatchCandidate(key: "b", metadata: source.metadata)])
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let skipped = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(skipped?.state, .skipped)
        try await f.engine.disableSource(id: f.sourceIDs[0])
        await f.photos.setCandidates([])
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let preserved = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(preserved?.id, skipped?.id)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 0)
    }

    func testCommittedResultSurvivesLaterIndexHealthFailure() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        await f.photos.setFailIndexAfterCreate()
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let file = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(file?.state, .imported)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1)
    }

    func testSequentialPhysicalReadsReleaseSourceBeforeReturning() async throws {
        let executor = ReadExecutor()
        let id = UUID()
        for value in 0..<1000 {
            let result = try await executor.execute(sourceID: id) { value }
            XCTAssertEqual(result, value)
            let snapshot = await executor.snapshot()
            XCTAssertEqual(snapshot.physicalOccupancy, 0)
        }
    }

    func testUnknownReturnedResultBlocksLaterSubmissionsAcrossRounds() async throws {
        let f = try await makeEngineFixture()
        try FileManager.default.moveItem(at: f.directories[1].appendingPathComponent("same.jpg"), to: f.directories[1].appendingPathComponent("different.jpg"))
        await f.photos.setCreationError(.resultUnknown("callback uncertain"))
        await f.engine.scan(sourceIDs: f.sourceIDs)
        await f.photos.setCreationError(nil)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1, "Do not reuse submission slot while this process has an unresolved result")
        let status = await f.engine.snapshot()
        XCTAssertNotNil(status.blockingError)
    }

    func testOrderedPendingReservationsHaveOneWinnerAndExcludeSelf() async throws {
        let f = try await makeEngineFixture()
        let first = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        let second = try await engineSourceFile(sourceID: f.sourceIDs[1], directory: f.directories[1])
        let firstID = try await f.store.save(first, decision: .importNew)
        let secondID = try await f.store.save(second, decision: .importNew)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let firstState = try await f.store.state(of: firstID)
        let secondState = try await f.store.state(of: secondID)
        XCTAssertEqual(firstState, .imported)
        XCTAssertEqual(secondState, .skipped)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1)
    }

    func testHistoricalUnknownAllowsDifferentNameAndDefiniteRecoveryRetries() async throws {
        let f = try await makeEngineFixture()
        let first = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        let firstID = try await f.store.save(first, decision: .importNew)
        try await f.store.beginAttempt(fileID: firstID, attemptID: UUID())
        try FileManager.default.moveItem(at: f.directories[1].appendingPathComponent("same.jpg"), to: f.directories[1].appendingPathComponent("different.jpg"))
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1)
        let firstState = try await f.store.state(of: firstID)
        XCTAssertEqual(firstState, .importing)
        await f.photos.setEvidence(.definitelyNotCommitted)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let after = try await f.store.state(of: firstID)
        XCTAssertEqual(after, .imported)
        let total = await f.photos.createCount
        XCTAssertEqual(total, 2)
    }
}
