import XCTest
@testable import PhotoSyncCore

final class EngineTests: XCTestCase {
    func testUnknownImportDoesNotEmitRecoveredAfterSuccessfulTraversal() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let logDirectory = try temporaryDirectory()
        let logger = try RunLogger(directory: logDirectory)
        let engine = SyncEngine(store: f.store, photos: f.photos, logger: logger)
        let file = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        let id = try await f.store.save(file, decision: .importNew)
        try await f.store.beginAttempt(fileID: id, attemptID: UUID())

        await engine.scan(sourceIDs: f.sourceIDs)
        await engine.scan(sourceIDs: f.sourceIDs)

        let snapshot = await engine.snapshot()
        XCTAssertNotNil(snapshot.waitingSources[f.sourceIDs[0]])
        let logURL = logDirectory.appendingPathComponent("photo-sync.jsonl")
        let written = await engineEventually { FileManager.default.fileExists(atPath: logURL.path) }
        XCTAssertTrue(written)
        let lines = try String(contentsOf: logURL).split(separator: "\n")
        let recoveryResults = try lines.compactMap { line -> String? in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
            return object?["phase"] == "recovery" ? object?["result"] : nil
        }
        XCTAssertEqual(recoveryResults.filter { $0 == "waiting" }.count, 1)
        XCTAssertFalse(recoveryResults.contains("recovered"))
    }

    func testMetadataFailureLogsSourcePathAndRun() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let logDirectory = try temporaryDirectory()
        let logger = try RunLogger(directory: logDirectory)
        try Data("bad JPEG".utf8).write(to: f.directories[0].appendingPathComponent("same.jpg"))
        let engine = SyncEngine(store: f.store, photos: f.photos, logger: logger)

        await engine.scan(sourceIDs: f.sourceIDs)

        let logURL = logDirectory.appendingPathComponent("photo-sync.jsonl")
        let written = await engineEventually { loggedEvent(at: logURL, phase: "metadata", result: "failed") != nil }
        XCTAssertTrue(written)
        let metadata = try XCTUnwrap(loggedEvent(at: logURL, phase: "metadata", result: "failed"))
        XCTAssertTrue(metadata["path"]?.hasSuffix("/source-0/same.jpg") == true)
        XCTAssertEqual(metadata["source"], f.sourceIDs[0].uuidString)
        XCTAssertNotNil(metadata["run"])
        XCTAssertNotNil(metadata["error"])
    }

    func testDefiniteSubmissionFailureLogsFileAndAttempt() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let logDirectory = try temporaryDirectory()
        let logger = try RunLogger(directory: logDirectory)
        await f.photos.setCreationError(.definitelyNotCommitted("test failure"))
        let engine = SyncEngine(store: f.store, photos: f.photos, logger: logger)

        await engine.scan(sourceIDs: f.sourceIDs)

        let logURL = logDirectory.appendingPathComponent("photo-sync.jsonl")
        let written = await engineEventually { loggedEvent(at: logURL, phase: "submission", result: "failed") != nil }
        XCTAssertTrue(written)
        let submission = try XCTUnwrap(loggedEvent(at: logURL, phase: "submission", result: "failed"))
        XCTAssertEqual(submission["source"], f.sourceIDs[0].uuidString)
        XCTAssertNotNil(submission["run"])
        XCTAssertNotNil(submission["file"])
        XCTAssertNotNil(submission["attempt"])
        XCTAssertNotNil(submission["error"])
    }

    func testPreAdmissionDefiniteFailureStaysPendingAndRetriesOneActualSubmission() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let photos = PreAdmissionFailurePhotosGateway()
        let engine = SyncEngine(store: f.store, photos: photos)

        await engine.scan(sourceIDs: f.sourceIDs)

        let pending = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(pending?.state, .pending)
        XCTAssertNil(pending?.placeholderID)
        let firstSnapshot = await engine.snapshot()
        let initialSubmissionCount = await photos.actualSubmissionCount
        XCTAssertNil(firstSnapshot.blockingError)
        XCTAssertEqual(initialSubmissionCount, 0)

        try injectEngineSQL("UPDATE file_record SET next_retry_at = 0", at: f.databaseURL)
        await engine.scan(sourceIDs: f.sourceIDs)

        let imported = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let finalSubmissionCount = await photos.actualSubmissionCount
        let createCallCount = await photos.createCallCount
        XCTAssertEqual(imported?.state, .imported)
        XCTAssertEqual(finalSubmissionCount, 1)
        XCTAssertEqual(createCallCount, 2)
    }

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
        XCTAssertEqual(heldSnapshot.summary?.pending, 1)
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
        XCTAssertNotNil(snapshot.summaryError)
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
        let failed = (await f.engine.snapshot()).latestScan.failed
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

    func testRemovingSourceStopsQueuedSubmissionButPersistsInFlightResult() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let queuedURL = f.directories[0].appendingPathComponent("queued.jpg")
        try FileManager.default.copyItem(at: f.directories[0].appendingPathComponent("same.jpg"), to: queuedURL)
        let first = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        let queued = SourceFile(
            sourceID: f.sourceIDs[0],
            relativePath: "queued.jpg",
            url: queuedURL,
            stamp: try await DirectoryReader(sourceID: f.sourceIDs[0]).stamp(of: queuedURL),
            metadata: try await MetadataReader(sourceID: f.sourceIDs[0]).read(url: queuedURL, filename: "queued.jpg")
        )
        _ = try await f.store.save(first, decision: .importNew)
        _ = try await f.store.save(queued, decision: .importNew)
        let gate = EngineTestGate()
        await f.photos.setCreationGate(gate)

        let scan = Task { await f.engine.scan(sourceIDs: f.sourceIDs) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        try await f.engine.removeSource(id: f.sourceIDs[0])
        await gate.release()
        await scan.value

        let sources = try await f.engine.sources()
        let imported = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let pending = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "queued.jpg")
        let createCount = await f.photos.createCount
        XCTAssertTrue(sources.isEmpty)
        XCTAssertEqual(imported?.state, .imported)
        XCTAssertEqual(pending?.state, .pending)
        XCTAssertEqual(createCount, 1)
    }

    func testRemovingSourceWhileDirectoryReadIsHeldStopsNewRecords() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let gate = EngineTestGate()
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { id in
            GatedDirectoryReader(reader: DirectoryReader(sourceID: id), gate: gate)
        })

        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        try await engine.removeSource(id: f.sourceIDs[0])
        await gate.release()
        await scan.value

        let sources = try await engine.sources()
        let record = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let createCount = await f.photos.createCount
        XCTAssertTrue(sources.isEmpty)
        XCTAssertNil(record)
        XCTAssertEqual(createCount, 0)
    }

    func testRestartReconcilesRemovedUnknownWithoutVisibleWaitingSource() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let file = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        let fileID = try await f.store.save(file, decision: .importNew)
        try await f.store.beginAttempt(fileID: fileID, attemptID: UUID())
        try await f.store.removeSource(id: f.sourceIDs[0])
        let notifications = NotificationRecorder()
        let restarted = SyncEngine(store: f.store, photos: f.photos, notify: { sourceID, recovered in
            notifications.record(sourceID: sourceID, recovered: recovered)
        })

        await restarted.recoverImports()

        let snapshot = await restarted.snapshot()
        let emittedNotifications = notifications.events
        let sources = try await restarted.sources()
        let state = try await f.store.state(of: fileID)
        XCTAssertTrue(sources.isEmpty)
        XCTAssertEqual(state, .importing)
        XCTAssertNil(snapshot.waitingSources[f.sourceIDs[0]])
        XCTAssertTrue(emittedNotifications.isEmpty)
    }

    func testRemoveSourceStorageFailureClosesAdmission() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        try injectEngineSQL("CREATE TRIGGER fail_source_removal BEFORE UPDATE ON source WHEN NEW.removed = 1 BEGIN SELECT RAISE(FAIL, 'injected removal failure'); END", at: f.databaseURL)

        do {
            try await f.engine.removeSource(id: f.sourceIDs[0])
            XCTFail("Expected source removal to fail")
        } catch {}
        await f.engine.scan(sourceIDs: f.sourceIDs)

        let snapshot = await f.engine.snapshot()
        let createCount = await f.photos.createCount
        XCTAssertNotNil(snapshot.blockingError)
        XCTAssertEqual(createCount, 0)
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
        let unknown = PhotoKitGatewayError.resultUnknown("callback uncertain")
        await f.photos.setCreationError(unknown)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        await f.photos.setCreationError(nil)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 1, "Do not reuse submission slot while this process has an unresolved result")
        let status = await f.engine.snapshot()
        XCTAssertEqual(status.blockingError, unknown.localizedDescription)
        guard case .uncertainSubmission(let message)? = status.recoveryHint else {
            return XCTFail("An unknown Photos submission needs a typed recovery hint")
        }
        XCTAssertEqual(message, "callback uncertain")
    }

    func testCheckpointFailurePreservesRawBlockAndUsesDedicatedHint() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let checkpoint = PhotoKitGatewayError.checkpointFailed("placeholder checkpoint failed")
        await f.photos.setCreationError(checkpoint)

        await f.engine.scan(sourceIDs: f.sourceIDs)

        let snapshot = await f.engine.snapshot()
        XCTAssertEqual(snapshot.blockingError, checkpoint.localizedDescription)
        XCTAssertEqual(snapshot.recoveryHint, .checkpointFailure(message: "placeholder checkpoint failed"))
    }

    func testLatestRoundDoesNotCountACompletionFromAnEarlierHeldSubmission() async throws {
        let f = try await makeEngineFixture()
        try FileManager.default.moveItem(at: f.directories[1].appendingPathComponent("same.jpg"), to: f.directories[1].appendingPathComponent("different.jpg"))
        let gate = EngineTestGate()
        await f.photos.setCreationGate(gate)

        let first = Task { await f.engine.scan(sourceIDs: [f.sourceIDs[0]]) }
        let firstSubmissionEntered = await engineEventually { await gate.entered }
        XCTAssertTrue(firstSubmissionEntered)
        let second = Task { await f.engine.scan(sourceIDs: [f.sourceIDs[1]]) }
        let secondSourceScanned = try await engineEventually {
            try await f.store.file(sourceID: f.sourceIDs[1], relativePath: "different.jpg") != nil
        }
        XCTAssertTrue(secondSourceScanned)
        await gate.release()
        await first.value
        await second.value

        let snapshot = await f.engine.snapshot()
        XCTAssertEqual(snapshot.latestScan.state, .completed)
        XCTAssertEqual(snapshot.latestScan.checkedCandidates, 1)
        XCTAssertEqual(snapshot.latestScan.newlyImported, 1)
        XCTAssertEqual(snapshot.summary, SyncStatusSummary(imported: 2, skipped: 0, pending: 0, importing: 0))
    }

    func testCurrentRoundCountsOnlySupportedCandidatesAndKeepsPriorStateSummary() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        try FileManager.default.removeItem(at: f.directories[0].appendingPathComponent("same.jpg"))
        let reader = DirectoryReader(sourceID: f.sourceIDs[0])

        for index in 0..<116 {
            let name = "photo-\(index).jpg"
            let url = f.directories[0].appendingPathComponent(name)
            try Data("fixture-\(index)".utf8).write(to: url)
            let file = SourceFile(
                sourceID: f.sourceIDs[0],
                relativePath: name,
                url: url,
                stamp: try await reader.stamp(of: url),
                metadata: media(name)
            )
            let id = try await f.store.save(file, decision: .importNew)
            if index < 115 {
                let attempt = UUID()
                try await f.store.beginAttempt(fileID: id, attemptID: attempt)
                try await f.store.markImported(fileID: id, attemptID: attempt, identifier: "asset-\(index)")
            } else {
                try await f.store.markSkipped(fileID: id, reason: .suspectedDuplicate, candidates: [])
            }
        }
        for index in 0..<114 {
            try Data("raw".utf8).write(to: f.directories[0].appendingPathComponent("raw-\(index).ARW"))
        }
        for index in 0..<26 {
            try Data("sidecar".utf8).write(to: f.directories[0].appendingPathComponent("sidecar-\(index).xmp"))
        }

        await f.engine.scan(sourceIDs: f.sourceIDs)
        let first = await f.engine.snapshot()
        XCTAssertEqual(first.summary, SyncStatusSummary(imported: 115, skipped: 1, pending: 0, importing: 0))
        XCTAssertEqual(first.latestScan.state, .completed)
        XCTAssertEqual(first.latestScan.checkedCandidates, 116)
        XCTAssertEqual(first.latestScan.newlyImported, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM non_media_skip", at: f.databaseURL), 0)

        let reopenedStore = try SyncStore(url: f.databaseURL)
        let restarted = SyncEngine(store: reopenedStore, photos: f.photos)
        await restarted.scan(sourceIDs: f.sourceIDs)
        let again = await restarted.snapshot()
        XCTAssertEqual(again.summary, SyncStatusSummary(imported: 115, skipped: 1, pending: 0, importing: 0))
        XCTAssertEqual(again.latestScan.checkedCandidates, 116)
        XCTAssertEqual(again.latestScan.newlyImported, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM non_media_skip", at: f.databaseURL), 0)
    }

    func testSummaryFailureKeepsLastKnownValuesAndMarksTheSnapshotUnavailable() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let beforeFailure = await f.engine.snapshot()
        let known = try XCTUnwrap(beforeFailure.summary)

        try injectEngineSQL("ALTER TABLE source DROP COLUMN removed", at: f.databaseURL)
        let failed = await f.engine.snapshot()

        XCTAssertEqual(failed.summary, known)
        XCTAssertNotNil(failed.summaryError)
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

    func testStorageFailureDuringSubmissionStampBlocksDispatch() async throws {
        let f = try await makeEngineFixture()
        let submitGate = EngineTestGate(), sourceGate = EngineTestGate()
        let healthyID = f.sourceIDs[0], failingID = f.sourceIDs[1]
        let reader = SubmissionStampReader(sourceID: healthyID, gate: submitGate)
        try injectEngineSQL("CREATE TRIGGER fail_second_source BEFORE INSERT ON file_record WHEN NEW.source_id = '\(failingID.uuidString)' BEGIN SELECT RAISE(FAIL, 'injected other source failure'); END", at: f.databaseURL)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { id in
            if id == healthyID { return reader }
            return GatedDirectoryReader(reader: DirectoryReader(sourceID: id), gate: sourceGate)
        })
        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let held = await engineEventually { await submitGate.entered }
        XCTAssertTrue(held)
        await sourceGate.release()
        let stopped = await engineEventually { await engine.snapshot().blockingError != nil }
        XCTAssertTrue(stopped)
        await submitGate.release()
        await scan.value
        let count = await f.photos.createCount
        XCTAssertEqual(count, 0)
        let record = try await f.store.file(sourceID: healthyID, relativePath: "same.jpg")
        XCTAssertEqual(record?.state, .pending)
    }

    func testSubmissionStampFailurePersistsRetryAndScanJournal() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let reader = SubmissionStampReader(sourceID: f.sourceIDs[0], failSubmissionStamp: true)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        await engine.scan(sourceIDs: f.sourceIDs)
        let record = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(record?.state, .pending)
        XCTAssertNotNil(record?.nextRetryAt)
        let failed = (await engine.snapshot()).latestScan.failed
        XCTAssertEqual(failed, 1)
        XCTAssertEqual(try engineSQLInteger("SELECT SUM(failed) FROM scan_run", at: f.databaseURL), 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run WHERE complete = 0 AND last_error IS NOT NULL", at: f.databaseURL), 1)
        XCTAssertEqual(try engineSQLInteger("SELECT retry_count FROM file_record", at: f.databaseURL), 1)
        let count = await f.photos.createCount
        XCTAssertEqual(count, 0)
    }

    func testTerminalDuplicateSkipClearsOnlyItsRetryIssue() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let reader = SubmissionStampReader(sourceID: f.sourceIDs[0], failSubmissionStamp: true, failSubmissionStampOnce: true)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })

        await engine.scan(sourceIDs: f.sourceIDs)
        let waitingAfterFailure = await engine.snapshot().waitingSources[f.sourceIDs[0]]
        XCTAssertNotNil(waitingAfterFailure)
        try injectEngineSQL("UPDATE file_record SET next_retry_at = 0", at: f.databaseURL)
        let file = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        await f.photos.setCandidates([MatchCandidate(key: "existing", metadata: file.metadata)])

        await engine.scan(sourceIDs: f.sourceIDs)

        let record = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(record?.state, .skipped)
        let waitingAfterSkip = await engine.snapshot().waitingSources[f.sourceIDs[0]]
        let pending = try await f.store.countFiles(state: .pending)
        let importing = try await f.store.countFiles(state: .importing)
        XCTAssertNil(waitingAfterSkip)
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(importing, 0)
    }

    func testFinalizingScanPreservesConcurrentSubmissionFailureJournal() async throws {
        let f = try await makeEngineFixture()
        let readyGate = EngineTestGate(), heldGate = EngineTestGate()
        let pendingID = f.sourceIDs[1]
        try FileManager.default.createDirectory(at: f.directories[1].appendingPathComponent("held"), withIntermediateDirectories: true)
        let pendingFile = try await engineSourceFile(sourceID: pendingID, directory: f.directories[1])
        _ = try await f.store.save(pendingFile, decision: .importNew)
        let reader = JournalRaceReader(sourceID: pendingID, gate: heldGate)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { id in
            if id == pendingID { return reader }
            return GatedDirectoryReader(reader: DirectoryReader(sourceID: id), gate: readyGate)
        })
        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let held = await engineEventually { await heldGate.entered }
        XCTAssertTrue(held)
        await readyGate.release()
        let failureJournaled = try await engineEventually {
            try await f.store.latestScanFailureCount(sourceID: pendingID) == 1
        }
        XCTAssertTrue(failureJournaled)
        await heldGate.release()
        await scan.value
        XCTAssertEqual(try engineSQLInteger("SELECT failed FROM scan_run WHERE source_id = '\(pendingID.uuidString)'", at: f.databaseURL), 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run WHERE source_id = '\(pendingID.uuidString)' AND complete = 0 AND last_error IS NOT NULL AND ended_at IS NOT NULL", at: f.databaseURL), 1)
    }
}

private func loggedEvent(at url: URL, phase: String, result: String) -> [String: String]? {
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
    return text.split(separator: "\n").compactMap { line in
        let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        return object?["phase"] == phase && object?["result"] == result ? object : nil
    }.first
}

private actor PreAdmissionFailurePhotosGateway: PhotosGateway {
    private(set) var createCallCount = 0
    private(set) var actualSubmissionCount = 0

    func loadCandidates() async throws -> [MatchCandidate] { [] }

    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }

    func create(
        fileURL: URL,
        kind: MediaKind,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        createCallCount += 1
        guard createCallCount > 1 else {
            throw PhotoKitGatewayError.definitelyNotCommitted("The Photos candidate index was stale before PhotoKit submission.")
        }
        actualSubmissionCount += 1
        try onPlaceholder("submitted-1")
        return "submitted-1"
    }
}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [(UUID, Bool)] = []

    var events: [(UUID, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func record(sourceID: UUID, recovered: Bool) {
        lock.lock()
        recordedEvents.append((sourceID, recovered))
        lock.unlock()
    }
}
