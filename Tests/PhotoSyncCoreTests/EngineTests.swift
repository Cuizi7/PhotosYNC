import XCTest
import Darwin
import ImageIO
import SQLite3
@testable import PhotoSyncCore

final class EngineTests: XCTestCase {
    // Missing root admission used to fan one outage into a retry on every pending row.
    func testUnavailableRootHoldsLargePendingQueueAndHealthySourceContinues() async throws {
        let f = try await makeEngineFixture(sourceCount: 2)
        let root = f.directories[0], id = f.sourceIDs[0]
        for index in 0..<276 {
            let name = "pending-\(index).jpg", url = root.appendingPathComponent("pending-\(index).jpg")
            try FileManager.default.copyItem(at: root.appendingPathComponent("same.jpg"), to: url)
            let file = SourceFile(sourceID: id, relativePath: name, url: url,
                stamp: try await DirectoryReader().stamp(of: url),
                metadata: try await MetadataReader().read(url: url, filename: name))
            let recordID = try await f.store.save(file, decision: .importNew)
            try await f.store.recordRetry(fileID: recordID, attemptID: nil, nextRetry: .distantPast,
                error: "previous source read failure", definitelyNotCommitted: true)
        }
        let reader = RootOutageDirectory(sourceID: id, root: root, drop: .initial)
        let rootGate = EngineTestGate()
        await reader.holdRoot(rootGate)
        let engine = SyncEngine(store: f.store, photos: f.photos,
            directory: { source in
                if source == id { return reader }; return DirectoryReader(sourceID: source) })
        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let healthyImported = await engineEventually { await f.photos.createCount == 1 }
        XCTAssertTrue(healthyImported)
        let coldReads = await reader.stampCalls
        XCTAssertEqual(coldReads, 0, "Cold-start pending waits for actual root evidence")
        await rootGate.release(); await scan.value
        let snapshot = await engine.snapshot(), reads = await reader.stampCalls
        XCTAssertEqual(snapshot.sourceIssueDetails[id]?.map(\.path), [try SourceRegistry.normalizedURL(root).path])
        XCTAssertNil(snapshot.sourceFileIssueCounts[id])
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(snapshot.summary?.retryPending, 276)
        XCTAssertEqual(snapshot.summary?.pending, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT SUM(retry_count) FROM file_record", at: f.databaseURL), 276)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_record WHERE last_error = 'previous source read failure'", at: f.databaseURL), 276)
        XCTAssertEqual(snapshot.summary?.imported, 1)
        XCTAssertNil(snapshot.blockingError)
        await engine.scan(sourceIDs: [f.sourceIDs[1]])
        let stillHeldReads = await reader.stampCalls
        XCTAssertEqual(stillHeldReads, 0, "Other source rounds must not probe a held root's files")
    }

    func testOlderSuccessfulRootReadCannotReopenAfterNewerRootLoss() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let id = f.sourceIDs[0], reader = RootOutageDirectory(sourceID: f.sourceIDs[0], root: f.directories[0], drop: .submissionStamp)
        let failedStampGate = EngineTestGate(), olderRootGate = EngineTestGate()
        await reader.holdDrop(failedStampGate)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        let first = Task { await engine.scan(sourceIDs: [id]) }
        let stampHeld = await engineEventually { await failedStampGate.entered }
        XCTAssertTrue(stampHeld)
        await reader.holdNextRootResult(olderRootGate)
        let second = Task { await engine.scan(sourceIDs: [id]) }
        let oldSuccessHeld = await engineEventually { await olderRootGate.entered }
        XCTAssertTrue(oldSuccessHeld)
        await failedStampGate.release()
        let outage = await engineEventually { await engine.snapshot().waitingSources[id]?.isSourceAvailability == true }
        XCTAssertTrue(outage)
        await olderRootGate.release(); await first.value; await second.value
        let reads = await reader.stampCalls, snapshot = await engine.snapshot()
        XCTAssertEqual(reads, 2, "An older root result cannot admit another child read after newer root loss")
        XCTAssertEqual(snapshot.sourceIssueDetails[id]?.map(\.kind), [.sourceAvailability])
        XCTAssertEqual(snapshot.summary?.pending, 1)
        XCTAssertEqual(snapshot.summary?.retryPending, 0)
    }

    func testRootLossDuringScanConvergesBeforeReadingSiblingsAndRecovers() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let root = f.directories[0], id = f.sourceIDs[0]
        for index in 0..<12 {
            try FileManager.default.copyItem(at: root.appendingPathComponent("same.jpg"),
                to: root.appendingPathComponent("sibling-\(index).jpg"))
        }
        let reader = RootOutageDirectory(sourceID: id, root: root, drop: .scanStamp)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        await engine.scan(sourceIDs: [id])
        let unavailable = await engine.snapshot(), reads = await reader.stampCalls
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(unavailable.sourceIssueDetails[id]?.map(\.kind), [.sourceAvailability])
        XCTAssertEqual(unavailable.latestScan.failedFiles, 0)
        await reader.recover()
        await engine.scan(sourceIDs: [id])
        let restored = await engine.snapshot()
        XCTAssertNil(restored.waitingSources[id])
        XCTAssertEqual(restored.summary?.imported, 13)
    }

    func testRootLossDuringDrainPreservesPendingWithoutFileRetryAndResumes() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let root = f.directories[0], id = f.sourceIDs[0]
        for index in 0..<12 {
            try FileManager.default.copyItem(at: root.appendingPathComponent("same.jpg"),
                to: root.appendingPathComponent("sibling-\(index).jpg"))
        }
        let reader = RootOutageDirectory(sourceID: id, root: root, drop: .submissionStamp)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        await engine.scan(sourceIDs: [id])
        let unavailable = await engine.snapshot(), reads = await reader.stampCalls
        XCTAssertEqual(reads, 14, "13 scan stamps then only the first failing pre-submit stamp")
        XCTAssertEqual(unavailable.sourceIssueDetails[id]?.map(\.kind), [.sourceAvailability])
        XCTAssertEqual(unavailable.summary?.pending, 13)
        XCTAssertEqual(unavailable.summary?.retryPending, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT SUM(retry_count) FROM file_record", at: f.databaseURL), 0)
        await reader.recover()
        await engine.scan(sourceIDs: [id])
        let restored = await engine.snapshot()
        XCTAssertNil(restored.waitingSources[id])
        XCTAssertEqual(restored.summary?.imported, 13)
    }

    func testConfirmedRootOutageUsesSourceRecoveryInsteadOfEarlierReadDeferral() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let id = f.sourceIDs[0], root = f.directories[0]
        try FileManager.default.copyItem(at: root.appendingPathComponent("same.jpg"), to: root.appendingPathComponent("second.jpg"))
        let reader = RootOutageDirectory(sourceID: id, root: root, drop: .scanStamp)
        await reader.deferFirstStamp()
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        await engine.scan(sourceIDs: [id])
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.waitingSources[id]?.kind, .sourceAvailability)
        XCTAssertFalse(snapshot.deferredSources.contains(id), "Root outages must only use source recovery backoff")
        XCTAssertEqual(snapshot.latestScan.failedFiles, 0)
    }

    func testRootProbeContentionDefersWithoutOutageOrRetryFanout() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let id = f.sourceIDs[0], root = f.directories[0]
        for index in 0..<12 {
            try FileManager.default.copyItem(at: root.appendingPathComponent("same.jpg"),
                to: root.appendingPathComponent("sibling-\(index).jpg"))
        }
        let reader = RootOutageDirectory(sourceID: id, root: root, drop: .submissionStamp)
        await reader.deferRootProbe()
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        await engine.scan(sourceIDs: [id])
        let snapshot = await engine.snapshot(), reads = await reader.stampCalls
        XCTAssertEqual(reads, 14, "A deferred root probe holds this source until its next source scan")
        XCTAssertTrue(snapshot.deferredSources.contains(id))
        XCTAssertNil(snapshot.waitingSources[id])
        XCTAssertNil(snapshot.sourceIssueDetails[id])
        XCTAssertEqual(snapshot.summary?.pending, 13)
        XCTAssertEqual(snapshot.summary?.retryPending, 0)
        XCTAssertEqual(snapshot.latestScan.failed, 0)
        await reader.recover()
        await engine.scan(sourceIDs: [id])
        let recovered = await engine.snapshot()
        XCTAssertEqual(recovered.summary?.imported, 13)
    }

    func testRootOutageCollapsesProjectionWithoutErasingIndependentFileEvidence() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let id = f.sourceIDs[0], root = try SourceRegistry.normalizedURL(f.directories[0])
        let file = try await engineSourceFile(sourceID: id, directory: root)
        _ = try await f.store.save(file, decision: .importNew)
        let reader = DiagnosticDirectory(sourceID: id)
        await reader.setFileFailure(file.url, code: Int(EACCES))
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader }, now: { Date(timeIntervalSince1970: 100) })
        await engine.scan(sourceIDs: [id])
        let original = try await f.store.file(sourceID: id, relativePath: "same.jpg")
        let originalError = try engineSQLString("SELECT last_error FROM file_record", at: f.databaseURL)
        let originalDetails = await engine.snapshot().sourceIssueDetails[id]
        XCTAssertEqual(originalDetails?.count, 2)
        await reader.setFailure(root, code: Int(ENOENT))
        await engine.scan(sourceIDs: [id])
        let unavailable = await engine.snapshot()
        XCTAssertEqual(unavailable.sourceIssueDetails[id]?.map(\.path), [root.path])
        XCTAssertNil(unavailable.sourceFileIssueCounts[id])
        let held = try await f.store.file(sourceID: id, relativePath: "same.jpg")
        XCTAssertEqual(held?.retryCount, original?.retryCount)
        XCTAssertEqual(try engineSQLString("SELECT last_error FROM file_record", at: f.databaseURL), originalError)
        await reader.setFailure(root, code: nil)
        await engine.scan(sourceIDs: [id])
        let recoveredDetails = await engine.snapshot().sourceIssueDetails[id]
        XCTAssertEqual(recoveredDetails, originalDetails, "Independent bad-file evidence returns after root recovery")
    }

    func testRootOutagePreservesAlreadyDispatchedSuccess() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let id = f.sourceIDs[0], root = f.directories[0], gate = EngineTestGate()
        let reader = RootOutageDirectory(sourceID: id, root: root, drop: .never)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        await f.photos.setCreationGate(gate)
        let first = Task { await engine.scan(sourceIDs: [id]) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        await reader.disconnect()
        let second = Task { await engine.scan(sourceIDs: [id]) }
        let unavailable = await engineEventually { await engine.snapshot().waitingSources[id]?.isSourceAvailability == true }
        XCTAssertTrue(unavailable)
        await gate.release(); await first.value; await second.value
        let record = try await f.store.file(sourceID: id, relativePath: "same.jpg")
        XCTAssertEqual(record?.state, .imported)
        XCTAssertEqual(record?.successID, "fake-1")
        let creates = await f.photos.createCount
        XCTAssertEqual(creates, 1)
    }

    func testSourceIssueDetailsPreserveMixedDirectoriesFilesAndSubmission() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let root = try SourceRegistry.normalizedURL(f.directories[0]), id = f.sourceIDs[0]
        let file = try await engineSourceFile(sourceID: id, directory: root)
        let recordID = try await f.store.save(file, decision: .importNew)
        try await f.store.beginAttempt(fileID: recordID, attemptID: UUID())
        for name in ["A", "B"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        try Data("bad image".utf8).write(to: root.appendingPathComponent("bad.jpg"))
        let reader = DiagnosticDirectory(sourceID: id)
        await reader.setFailure(root.appendingPathComponent("A"), code: Int(EACCES))
        await reader.setFailure(root.appendingPathComponent("B"), code: Int(ENETDOWN))
        await reader.setFileFailure(file.url, code: Int(ENOENT))
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        await engine.scan(sourceIDs: f.sourceIDs)
        let snapshot = await engine.snapshot()
        let details = try XCTUnwrap(snapshot.sourceIssueDetails[id])
        XCTAssertEqual(details.count, 5)
        XCTAssertEqual(Set(details.map(\.id)), ["scan:directory:" + root.appendingPathComponent("A").path,
            "scan:directory:" + root.appendingPathComponent("B").path, "scan:file:bad.jpg", "scan:file:same.jpg", "file:" + recordID.uuidString])
        XCTAssertEqual(details.filter { $0.path == file.url.path }.count, 2)
        XCTAssertEqual(details.filter { $0.kind == .sourceAvailability }.count, 2)
        XCTAssertEqual(details.filter { $0.kind == .file }.count, 2)
        XCTAssertEqual(details.filter { $0.kind == .submission }.count, 1)
        XCTAssertEqual(snapshot.sourceFileIssueCounts[id], 2)
        XCTAssertTrue(details.first { $0.path.hasSuffix("/A") }?.detail.contains("fixture failure 13") == true)
        XCTAssertTrue(details.first { $0.id == "scan:file:same.jpg" }?.summary.contains("路径不可用") == true)
        XCTAssertEqual(details.map(\.path), details.map(\.path).sorted())
    }

    func testDirectoryPrimaryFollowsRemainingDiagnostic() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let id = f.sourceIDs[0], root = try SourceRegistry.normalizedURL(f.directories[0])
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B"), c = root.appendingPathComponent("C")
        for folder in [a, b, c] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let reader = DiagnosticDirectory(sourceID: id)
        let notices = SourceIssueNotificationRecorder()
        let logDirectory = try temporaryDirectory()
        let journalLogger = try RunLogger(directory: logDirectory)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader }, logger: journalLogger,
            notifySourceIssue: { _, recovered, issue in notices.record(recovered: recovered, issue: issue) })
        await reader.setFailure(a, code: Int(EACCES)); await reader.setFailure(b, code: Int(ENETDOWN))
        await engine.scan(sourceIDs: f.sourceIDs)
        let first = await engine.snapshot()
        XCTAssertTrue(first.waitingSources[id]?.detail.contains(a.path) == true)
        await reader.setFailure(a, code: nil)
        await engine.scan(sourceIDs: f.sourceIDs)
        let remaining = await engine.snapshot()
        XCTAssertEqual(remaining.sourceIssueDetails[id]?.count, 1)
        XCTAssertEqual(remaining.waitingSources[id]?.summary, "部分子目录所在的网络共享连接已中断；恢复后会自动继续。")
        XCTAssertTrue(remaining.waitingSources[id]?.detail.contains(b.path) == true)
        XCTAssertFalse(remaining.waitingSources[id]?.detail.contains(a.path) == true)
        journalLogger.flushForTesting()
        let partialRows = try String(contentsOf: logDirectory.appendingPathComponent("photo-sync.jsonl")).split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
        }
        let directoryRows = partialRows.filter { $0["phase"] == "directory" && $0["result"] == "failed" }
        XCTAssertEqual(directoryRows.filter { $0["path"] == a.path }.count, 1)
        XCTAssertEqual(directoryRows.filter { $0["path"] == b.path }.count, 1, "A's recovery must not reset B's log signature")
        XCTAssertTrue(directoryRows.allSatisfy { $0["detail"]?.contains("枚举目录") == true })
        await reader.setFailure(b, code: nil)
        await reader.deferDirectory(c)
        await engine.scan(sourceIDs: f.sourceIDs)
        let neutral = await engine.snapshot()
        XCTAssertNil(neutral.sourceIssueDetails[id])
        XCTAssertEqual(neutral.waitingSources[id]?.kind, .sourceAvailability)
        XCTAssertEqual(neutral.waitingSources[id]?.summary, "等待确认来源恢复")
        XCTAssertFalse(neutral.waitingSources[id]?.detail.contains(a.path) == true)
        XCTAssertEqual(notices.events.filter(\.recovered).count, 0)
        await reader.deferDirectory(nil)
        await engine.scan(sourceIDs: f.sourceIDs)
        let complete = await engine.snapshot()
        XCTAssertNil(complete.waitingSources[id])
        XCTAssertNil(complete.sourceIssueDetails[id])
        XCTAssertEqual(notices.events.filter(\.recovered).count, 1)
    }

    func testDirectoryDiagnosticRecoveryKeepsSourceRecoveryUntilCompleteTraversal() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let id = f.sourceIDs[0], root = try SourceRegistry.normalizedURL(f.directories[0])
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B"), c = root.appendingPathComponent("C")
        for folder in [a, b, c] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let reader = DiagnosticDirectory(sourceID: id), gate = EngineTestGate()
        let notices = SourceIssueNotificationRecorder()
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader },
            notifySourceIssue: { _, recovered, issue in notices.record(recovered: recovered, issue: issue) })
        var schedule = ScanSchedule()
        let start = Date(timeIntervalSince1970: 100)
        await reader.setFailure(a, code: Int(EACCES)); await reader.setFailure(b, code: Int(ENETDOWN))
        await engine.scan(sourceIDs: f.sourceIDs)
        let initial = await engine.snapshot()
        XCTAssertEqual(initial.sourceIssueDetails[id]?.count, 2)
        XCTAssertEqual(schedule.recordSourceFailure(id, now: start), start.addingTimeInterval(5))
        await reader.setFailure(a, code: nil)
        await engine.scan(sourceIDs: f.sourceIDs)
        let partial = await engine.snapshot()
        XCTAssertEqual(partial.sourceIssueDetails[id]?.map(\.path), [b.path])
        XCTAssertEqual(schedule.recordSourceFailure(id, now: start), start.addingTimeInterval(15))
        await reader.setFailure(b, code: nil)
        await reader.hold(c, gate: gate); await reader.deferDirectory(c)
        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let held = await engineEventually { await gate.entered }
        XCTAssertTrue(held)
        let beforePause = await engine.snapshot()
        XCTAssertNil(beforePause.sourceIssueDetails[id])
        XCTAssertEqual(beforePause.waitingSources[id]?.summary, "等待确认来源恢复")
        await engine.setPaused(true); await gate.release(); await scan.value
        let paused = await engine.snapshot()
        XCTAssertEqual(paused.waitingSources[id]?.kind, .sourceAvailability)
        XCTAssertNil(paused.sourceIssueDetails[id])
        XCTAssertEqual(notices.events.filter(\.recovered).count, 0)
        await engine.setPaused(false)
        await engine.scan(sourceIDs: f.sourceIDs)
        let deferred = await engine.snapshot()
        XCTAssertTrue(deferred.deferredSources.contains(id))
        XCTAssertEqual(deferred.waitingSources[id]?.kind, .sourceAvailability)
        XCTAssertNil(deferred.sourceIssueDetails[id])
        // Exercise the same availability/deferral separation consumed by finishedRound.
        if deferred.waitingSources[id]?.isSourceAvailability == true {
            XCTAssertEqual(schedule.recordSourceFailure(id, now: start), start.addingTimeInterval(30))
        } else { XCTFail("Source failure curve must survive leaf-only recovery") }
        XCTAssertEqual(schedule.recordSourceDeferral(id, now: start), start.addingTimeInterval(5))
        schedule.recordSourceDeferralRecovered(id)
        XCTAssertEqual(schedule.nextRecoveryAt, start.addingTimeInterval(30))
        XCTAssertEqual(notices.events.filter(\.recovered).count, 0)
        await reader.deferDirectory(nil)
        await engine.scan(sourceIDs: f.sourceIDs)
        let complete = await engine.snapshot()
        XCTAssertNil(complete.sourceIssueDetails[id]); XCTAssertNil(complete.waitingSources[id])
        XCTAssertFalse(complete.deferredSources.contains(id))
        XCTAssertEqual(notices.events.filter(\.recovered).count, 1)
        schedule.recordSourceFailureRecovered(id)
        XCTAssertEqual(schedule.recordSourceFailure(id, now: start), start.addingTimeInterval(5))
    }

    func testRepeatedIssuesUpdateWithoutAccumulating() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let id = f.sourceIDs[0], a = (try SourceRegistry.normalizedURL(f.directories[0])).appendingPathComponent("A")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        let reader = DiagnosticDirectory(sourceID: id)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        await reader.setFailure(a, code: Int(EACCES))
        await engine.scan(sourceIDs: f.sourceIDs)
        let first = await engine.snapshot().sourceIssueDetails[id]
        await engine.scan(sourceIDs: f.sourceIDs)
        let repeated = await engine.snapshot().sourceIssueDetails[id]
        XCTAssertEqual(first, repeated)
        await reader.setFailure(a, code: Int(ENETDOWN))
        await engine.scan(sourceIDs: f.sourceIDs)
        let changed = await engine.snapshot().sourceIssueDetails[id]
        XCTAssertEqual(first?.map(\.id), changed?.map(\.id))
        XCTAssertNotEqual(first?.first?.detail, changed?.first?.detail)
        XCTAssertEqual(changed?.count, 1)
        await reader.setFailure(a, code: nil)
        await engine.scan(sourceIDs: f.sourceIDs)
        let recovered = await engine.snapshot()
        XCTAssertNil(recovered.sourceIssueDetails[id])
        XCTAssertNil(recovered.waitingSources[id])
    }

    func testLateIssueCannotReviveDisabledOrRemovedSource() async throws {
        for remove in [false, true] {
            let f = try await makeEngineFixture(sourceCount: 1)
            let id = f.sourceIDs[0], gate = EngineTestGate()
            let reader = DiagnosticDirectory(sourceID: id)
            await reader.setFailure(f.directories[0], code: Int(EACCES))
            await reader.hold(f.directories[0], gate: gate)
            let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
            let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
            let held = await engineEventually { await gate.entered }
            XCTAssertTrue(held)
            if remove { try await engine.removeSource(id: id) } else { try await engine.disableSource(id: id) }
            await gate.release(); await scan.value
            let snapshot = await engine.snapshot()
            XCTAssertNil(snapshot.sourceIssueDetails[id])
            XCTAssertNil(snapshot.waitingSources[id])
            XCTAssertNil(snapshot.sourceFileIssueCounts[id])
        }
    }

    func testRecoveredDirectoryEntryAttributesClearOnlyTheirOwnDiagnostic() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let id = f.sourceIDs[0], root = try SourceRegistry.normalizedURL(f.directories[0])
        let folder = root.appendingPathComponent("unknown-child")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("bad JPEG".utf8).write(to: root.appendingPathComponent("bad.jpg"))
        let reader = DiagnosticDirectory(sourceID: id)
        let logs = try temporaryDirectory()
        let logger = try RunLogger(directory: logs)
        await reader.failAttribute(folder, code: Int(EACCES))
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader }, logger: logger)
        await engine.scan(sourceIDs: f.sourceIDs)
        let first = await engine.snapshot()
        let attribute = try XCTUnwrap(first.sourceIssueDetails[id]?.first { $0.path == folder.path })
        XCTAssertEqual(attribute.kind, .file)
        XCTAssertEqual(attribute.stage, "读取目录项属性")
        XCTAssertTrue(attribute.summary.contains("目录项")); XCTAssertTrue(attribute.summary.contains("权限"))
        XCTAssertTrue(attribute.detail.contains("NSCocoaErrorDomain")); XCTAssertTrue(attribute.detail.contains("NSPOSIXErrorDomain 13"))
        XCTAssertTrue(attribute.detail.contains("attribute leaf"))
        XCTAssertEqual(first.sourceIssueDetails[id]?.count, 2)
        logger.flushForTesting()
        let rows = try String(contentsOf: logs.appendingPathComponent("photo-sync.jsonl")).split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
        }
        let logged = try XCTUnwrap(rows.first { $0["phase"] == "metadata" && $0["path"] == folder.path })
        XCTAssertTrue(logged["detail"]?.contains("读取目录项属性") == true)
        XCTAssertTrue(logged["detail"]?.contains("NSPOSIXErrorDomain 13: attribute leaf") == true)
        await reader.failAttribute(folder, code: nil)
        await engine.scan(sourceIDs: f.sourceIDs)
        let remaining = await engine.snapshot()
        XCTAssertEqual(remaining.sourceIssueDetails[id]?.map(\.id), ["scan:file:bad.jpg"])
        XCTAssertEqual(remaining.sourceFileIssueCounts[id], 1)
    }

    func testCompleteTraversalClearsDeletedUnstoredScanDiagnosticWhileSiblingStillFails() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let id = f.sourceIDs[0], root = try SourceRegistry.normalizedURL(f.directories[0])
        let a = root.appendingPathComponent("a.jpg"), b = root.appendingPathComponent("b.jpg")
        for file in [a, b] { try Data("bad JPEG".utf8).write(to: file) }
        let notices = SourceIssueNotificationRecorder()
        let engine = SyncEngine(store: f.store, photos: f.photos,
            notifySourceIssue: { _, recovered, issue in notices.record(recovered: recovered, issue: issue) })
        await engine.scan(sourceIDs: f.sourceIDs)
        let first = await engine.snapshot()
        XCTAssertEqual(first.sourceIssueDetails[id]?.map(\.id), ["scan:file:a.jpg", "scan:file:b.jpg"])
        let aRecord = try await f.store.file(sourceID: id, relativePath: "a.jpg")
        let bRecord = try await f.store.file(sourceID: id, relativePath: "b.jpg")
        XCTAssertNil(aRecord); XCTAssertNil(bRecord)
        try FileManager.default.removeItem(at: a)
        await engine.scan(sourceIDs: f.sourceIDs)
        let remaining = await engine.snapshot()
        XCTAssertEqual(remaining.sourceIssueDetails[id]?.map(\.id), ["scan:file:b.jpg"])
        XCTAssertEqual(remaining.sourceFileIssueCounts[id], 1)
        XCTAssertEqual(remaining.waitingSources[id]?.kind, .file)
        XCTAssertEqual(notices.events.filter(\.recovered).count, 0)
        XCTAssertEqual(remaining.summary?.imported, 1)
        XCTAssertEqual(remaining.latestScan.failedFiles, 1)
        try FileManager.default.removeItem(at: b)
        await engine.scan(sourceIDs: f.sourceIDs)
        let clean = await engine.snapshot()
        XCTAssertNil(clean.sourceIssueDetails[id]); XCTAssertNil(clean.waitingSources[id])
        XCTAssertEqual(notices.events.filter(\.recovered).count, 0, "Normal deletion is not failure recovery")
    }

    func testIncompleteTraversalRetainsDeletedUnstoredScanDiagnostic() async throws {
        for incomplete in ["directory-deferred", "attribute-failed", "metadata-deferred", "paused"] {
            let f = try await makeEngineFixture(sourceCount: 1)
            let id = f.sourceIDs[0], root = try SourceRegistry.normalizedURL(f.directories[0])
            let a = root.appendingPathComponent("a.jpg"), b = root.appendingPathComponent("b.jpg")
            for file in [a, b] { try Data("bad JPEG".utf8).write(to: file) }
            let folder = root.appendingPathComponent("C")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let reader = DiagnosticDirectory(sourceID: id)
            let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
            await engine.scan(sourceIDs: f.sourceIDs)
            try FileManager.default.removeItem(at: a)
            if incomplete == "directory-deferred" { await reader.deferDirectory(folder) }
            if incomplete == "attribute-failed" { await reader.failAttribute(folder, code: Int(EACCES)) }
            if incomplete == "metadata-deferred" { await reader.setFileDeferred(b) }
            if incomplete == "paused" {
                let gate = EngineTestGate()
                await reader.hold(folder, gate: gate)
                let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
                let held = await engineEventually { await gate.entered }; XCTAssertTrue(held)
                await engine.setPaused(true); await gate.release(); await scan.value
            } else { await engine.scan(sourceIDs: f.sourceIDs) }
            let snapshot = await engine.snapshot()
            XCTAssertTrue(snapshot.sourceIssueDetails[id]?.contains { $0.id == "scan:file:a.jpg" } == true, incomplete)
            XCTAssertTrue(snapshot.sourceIssueDetails[id]?.contains { $0.id == "scan:file:b.jpg" } == true, incomplete)
        }
    }

    func testCompleteTraversalTreatsDeletedPendingFileAsNormalSourceChange() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let directory = f.directories[0]
        let sourceID = f.sourceIDs[0]
        let gone = directory.appendingPathComponent("gone.jpg")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("same.jpg"), to: gone)
        let stored = SourceFile(sourceID: sourceID, relativePath: "gone.jpg", url: gone,
                                stamp: try await DirectoryReader(sourceID: sourceID).stamp(of: gone),
                                metadata: try await MetadataReader(sourceID: sourceID).read(url: gone, filename: "gone.jpg"))
        let deletedID = try await f.store.save(stored, decision: .importNew)
        try await f.store.recordRetry(fileID: deletedID, attemptID: nil, nextRetry: Date(timeIntervalSince1970: 0),
                                      error: "missing before submission", definitelyNotCommitted: true)
        try FileManager.default.removeItem(at: gone)

        await f.engine.scan(sourceIDs: f.sourceIDs)

        let removed = try await f.store.file(sourceID: sourceID, relativePath: "gone.jpg")
        let due = try await f.store.dueRetrySourceIDs(at: Date())
        let summary = try await f.store.activeSourceSummary()
        let scan = await f.engine.snapshot().latestScan
        XCTAssertNil(removed)
        XCTAssertEqual(due, [])
        XCTAssertEqual(summary.retryPending, 0)
        XCTAssertEqual(scan.failed, 0)
        XCTAssertEqual(scan.failedFiles, 0)
        XCTAssertEqual(scan.state, .completed)
        let initialCreates = await f.photos.createCount
        XCTAssertEqual(initialCreates, 1)

        try FileManager.default.copyItem(at: directory.appendingPathComponent("same.jpg"), to: gone)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let rediscovered = try await f.store.file(sourceID: sourceID, relativePath: "gone.jpg")
        XCTAssertEqual(rediscovered?.state, .imported)
        let finalCreates = await f.photos.createCount
        XCTAssertEqual(finalCreates, 2)
    }

    func testBadMediaDoesNotBlockNormalDeletionReconciliation() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceID = f.sourceIDs[0]
        let directory = f.directories[0]
        let gone = directory.appendingPathComponent("gone.jpg")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("same.jpg"), to: gone)
        let stored = SourceFile(sourceID: sourceID, relativePath: "gone.jpg", url: gone,
                                stamp: try await DirectoryReader(sourceID: sourceID).stamp(of: gone),
                                metadata: try await MetadataReader(sourceID: sourceID).read(url: gone, filename: "gone.jpg"))
        _ = try await f.store.save(stored, decision: .importNew)
        try FileManager.default.removeItem(at: gone)
        try Data("bad JPEG".utf8).write(to: directory.appendingPathComponent("bad.jpg"))

        await f.engine.scan(sourceIDs: f.sourceIDs)

        let removed = try await f.store.file(sourceID: sourceID, relativePath: "gone.jpg")
        let snapshot = await f.engine.snapshot()
        XCTAssertNil(removed)
        XCTAssertEqual(snapshot.latestScan.failedFiles, 1)
        XCTAssertEqual(snapshot.latestScan.failed, 1)
        let creates = await f.photos.createCount
        XCTAssertEqual(creates, 1)
    }

    func testDeletedPendingFileClearsItsScanIssueWhileAnotherFileStillFails() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceID = f.sourceIDs[0]
        let file = try await engineSourceFile(sourceID: sourceID, directory: f.directories[0])
        _ = try await f.store.save(file, decision: .importNew)
        try Data("bad JPEG".utf8).write(to: f.directories[0].appendingPathComponent("bad.jpg"))
        let reader = FailingScanStampReader(reader: DirectoryReader(sourceID: sourceID))
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        await engine.scan(sourceIDs: [sourceID])
        let before = await engine.snapshot()
        XCTAssertEqual(before.sourceFileIssueCounts[sourceID], 2)
        try FileManager.default.removeItem(at: file.url)

        await engine.scan(sourceIDs: [sourceID])

        let snapshot = await engine.snapshot()
        let deleted = try await f.store.file(sourceID: sourceID, relativePath: "same.jpg")
        XCTAssertNil(deleted)
        XCTAssertEqual(snapshot.sourceFileIssueCounts[sourceID], 1)
        XCTAssertTrue(snapshot.waitingSources[sourceID]?.detail.contains("bad.jpg") == true)
    }

    func testDeletionDuringHeldDrainDoesNotStopStorageOrHealthySource() async throws {
        let f = try await makeEngineFixture(sourceCount: 2)
        let missingSource = f.sourceIDs[0]
        let missing = try await engineSourceFile(sourceID: missingSource, directory: f.directories[0])
        try FileManager.default.removeItem(at: missing.url)
        let scanGate = EngineTestGate()
        let stampGate = EngineTestGate()
        let heldReader = GatedMissingFileReader(reader: DirectoryReader(sourceID: missingSource),
                                                scanGate: scanGate, stampGate: stampGate)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { id -> any DirectoryReading in
            if id == missingSource { return heldReader }
            return DirectoryReader(sourceID: id)
        })

        // Establish root evidence before exercising an overlapping held drain. Cold
        // roots now intentionally forbid the pre-submit read this test needs to hold.
        await engine.scan(sourceIDs: [missingSource])
        _ = try await f.store.save(missing, decision: .importNew)
        await heldReader.holdScan()
        let round = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let scanHeld = await engineEventually { await scanGate.entered }
        let drainHeld = await engineEventually { await stampGate.entered }
        XCTAssertTrue(scanHeld)
        XCTAssertTrue(drainHeld)
        await scanGate.release()
        let removed = try await engineEventually {
            try await f.store.file(sourceID: missingSource, relativePath: "same.jpg") == nil
        }
        XCTAssertTrue(removed)
        await stampGate.release()
        await round.value

        let snapshot = await engine.snapshot()
        let healthy = try await f.store.file(sourceID: f.sourceIDs[1], relativePath: "same.jpg")
        XCTAssertNil(snapshot.blockingError)
        XCTAssertEqual(healthy?.state, .imported)
    }

    func testUnknownChildDirectoryTypeDoesNotConfirmDescendantDeletion() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceID = f.sourceIDs[0]
        let child = f.directories[0].appendingPathComponent("unreadable-child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let nested = child.appendingPathComponent("nested.jpg")
        try FileManager.default.copyItem(at: f.directories[0].appendingPathComponent("same.jpg"), to: nested)
        let stored = SourceFile(sourceID: sourceID, relativePath: "unreadable-child/nested.jpg", url: nested,
                                stamp: try await DirectoryReader(sourceID: sourceID).stamp(of: nested),
                                metadata: try await MetadataReader(sourceID: sourceID).read(url: nested, filename: "nested.jpg"))
        let fileID = try await f.store.save(stored, decision: .importNew)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { id in
            DirectoryReader(sourceID: id, attributes: { url, keys in
                if url.lastPathComponent == "unreadable-child" {
                    throw FixtureError.unavailable("child attributes unavailable")
                }
                return try url.resourceValues(forKeys: keys)
            })
        })

        await engine.scan(sourceIDs: [sourceID])

        let retained = try await f.store.file(sourceID: sourceID, relativePath: "unreadable-child/nested.jpg")
        XCTAssertEqual(retained?.id, fileID)
        let issue = await engine.snapshot().waitingSources[sourceID]
        XCTAssertNotNil(issue)
    }

    func testNormalSourceDeletionClearsRetryWithoutRecoveryNotification() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceID = f.sourceIDs[0]
        let reader = SubmissionStampReader(sourceID: sourceID, failSubmissionStamp: true)
        let notifications = SourceIssueNotificationRecorder()
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader },
                                notifySourceIssue: { _, recovered, issue in
                                    notifications.record(recovered: recovered, issue: issue)
                                })

        await engine.scan(sourceIDs: [sourceID])
        XCTAssertEqual(notifications.events.filter { !$0.recovered }.count, 1)
        try FileManager.default.removeItem(at: f.directories[0].appendingPathComponent("same.jpg"))
        await engine.scan(sourceIDs: [sourceID])

        let record = try await f.store.file(sourceID: sourceID, relativePath: "same.jpg")
        XCTAssertNil(record)
        XCTAssertEqual(notifications.events.filter { $0.recovered }.count, 0)
    }

    func testDeletionReconciliationDoesNotDiscardConcurrentImportingEvidence() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceID = f.sourceIDs[0]
        let file = try await engineSourceFile(sourceID: sourceID, directory: f.directories[0])
        let fileID = try await f.store.save(file, decision: .importNew)
        try FileManager.default.removeItem(at: file.url)
        let gate = EngineTestGate()
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { id in
            GatedDirectoryReader(reader: DirectoryReader(sourceID: id), gate: gate)
        })

        let scanning = Task { await engine.scan(sourceIDs: [sourceID]) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        let attempt = UUID()
        try await f.store.beginAttempt(fileID: fileID, attemptID: attempt)
        await gate.release()
        await scanning.value

        let retained = try await f.store.file(sourceID: sourceID, relativePath: "same.jpg")
        XCTAssertEqual(retained?.state, .importing)
        try await f.store.markImported(fileID: fileID, attemptID: attempt, identifier: "late-success")
        let success = try await f.store.successIdentifier(of: fileID)
        XCTAssertEqual(success, "late-success")
    }

    func testUnreadableVideoKeepsFileFailureWhileHealthySiblingImports() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let video = f.directories[0].appendingPathComponent("unreadable.mpg")
        try Data("not an MPEG program stream".utf8).write(to: video)
        let logDirectory = try temporaryDirectory()
        let logger = try RunLogger(directory: logDirectory)
        let engine = SyncEngine(store: f.store, photos: f.photos, logger: logger)

        await engine.scan(sourceIDs: f.sourceIDs)
        logger.flushForTesting()

        let failedVideo = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "unreadable.mpg")
        let snapshot = await engine.snapshot()
        let creates = await f.photos.createCount
        XCTAssertNil(failedVideo)
        XCTAssertEqual(snapshot.latestScan.failedFiles, 1)
        XCTAssertEqual(snapshot.sourceFileIssueCounts[f.sourceIDs[0]], 1)
        XCTAssertEqual(snapshot.waitingSources[f.sourceIDs[0]]?.kind, .file)
        XCTAssertEqual(creates, 1)
        let journal = try XCTUnwrap(loggedEvent(at: logDirectory.appendingPathComponent("photo-sync.jsonl"), phase: "metadata", result: "failed"))
        XCTAssertTrue(journal["error"]?.contains("AVFoundationErrorDomain") == true)
    }

    func testUnavailableDirectoryDoesNotDeletePendingFile() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceID = f.sourceIDs[0]
        let stored = try await engineSourceFile(sourceID: sourceID, directory: f.directories[0])
        let id = try await f.store.save(stored, decision: .importNew)
        try FileManager.default.removeItem(at: f.directories[0])

        await f.engine.scan(sourceIDs: f.sourceIDs)

        let surviving = try await f.store.file(sourceID: sourceID, relativePath: "same.jpg")
        XCTAssertEqual(surviving?.id, id)
        XCTAssertEqual(surviving?.state, .pending)
        let issue = await f.engine.snapshot().waitingSources[sourceID]
        XCTAssertEqual(issue?.kind, .sourceAvailability)
    }
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

    func testReconciliationDiagnosticsJournalEachIdentityAndChangedCauseWithoutRenotifying() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceID = f.sourceIDs[0], root = try SourceRegistry.normalizedURL(f.directories[0])
        let first = try await engineSourceFile(sourceID: sourceID, directory: root)
        let secondURL = root.appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: first.url, to: secondURL)
        let second = SourceFile(sourceID: sourceID, relativePath: "second.jpg", url: secondURL,
            stamp: try await DirectoryReader().stamp(of: secondURL),
            metadata: try await MetadataReader().read(url: secondURL, filename: "second.jpg"))
        let firstID = try await f.store.save(first, decision: .importNew)
        let secondID = try await f.store.save(second, decision: .importNew)
        let firstAttempt = UUID(), secondAttempt = UUID()
        try await f.store.beginAttempt(fileID: firstID, attemptID: firstAttempt)
        try f.store.checkpointPlaceholder(fileID: firstID, attemptID: firstAttempt, identifier: "first")
        try await f.store.beginAttempt(fileID: secondID, attemptID: secondAttempt)
        try f.store.checkpointPlaceholder(fileID: secondID, attemptID: secondAttempt, identifier: "second")
        let photos = DiagnosticSubmissionPhotos()
        await photos.setReconciliation("first", evidence: .unknown)
        await photos.setReconciliation("second", error: diagnosticReconciliationError("cause one"))
        let logs = try temporaryDirectory(), notices = SourceIssueNotificationRecorder()
        let logger = try RunLogger(directory: logs)
        let engine = SyncEngine(store: f.store, photos: photos, logger: logger,
            notifySourceIssue: { _, recovered, issue in notices.record(recovered: recovered, issue: issue) })
        let logURL = logs.appendingPathComponent("photo-sync.jsonl")
        await engine.recoverImports(); logger.flushForTesting()
        let initial = try submissionDiagnosticRows(at: logURL)
        XCTAssertEqual(initial.count, 2)
        for (fileID, fileURL, attempt) in [(firstID, first.url, firstAttempt), (secondID, second.url, secondAttempt)] {
            let row = try XCTUnwrap(initial.first { $0["file"] == fileID.uuidString })
            XCTAssertEqual(row["path"], fileURL.path)
            XCTAssertEqual(row["attempt"], attempt.uuidString)
            XCTAssertTrue(row["detail"]?.contains("核对导入结果") == true)
        }
        let unknown = try XCTUnwrap(initial.first { $0["file"] == firstID.uuidString })
        XCTAssertTrue(unknown["detail"]?.contains("An earlier Photos import is awaiting confirmation.") == true)
        let errorRow = try XCTUnwrap(initial.first { $0["file"] == secondID.uuidString })
        XCTAssertTrue(errorRow["detail"]?.contains("Fixture.Reconciliation 7: outer unchanged") == true)
        XCTAssertTrue(errorRow["detail"]?.contains("NSPOSIXErrorDomain 13: cause one") == true)
        XCTAssertEqual(notices.events.count, 1)
        XCTAssertEqual(notices.events.first?.recovered, false)
        await engine.recoverImports(); logger.flushForTesting()
        XCTAssertEqual(try submissionDiagnosticRows(at: logURL).count, 2, "Unchanged reconciliation must not duplicate rows")
        await photos.setReconciliation("second", error: diagnosticReconciliationError("cause two"))
        await engine.recoverImports(); logger.flushForTesting()
        let changed = try submissionDiagnosticRows(at: logURL)
        XCTAssertEqual(changed.count, 3)
        XCTAssertEqual(changed.filter { $0["file"] == firstID.uuidString }.count, 1)
        XCTAssertTrue(changed.last?["detail"]?.contains("NSPOSIXErrorDomain 13: cause two") == true)
        XCTAssertEqual(notices.events.count, 1)
        await photos.setReconciliation("first", evidence: .definitelyNotCommitted)
        await engine.recoverImports()
        XCTAssertEqual(notices.events.filter(\.recovered).count, 0, "The other identity is still unresolved")
        let nextAttempt = UUID()
        try await f.store.beginAttempt(fileID: firstID, attemptID: nextAttempt)
        try f.store.checkpointPlaceholder(fileID: firstID, attemptID: nextAttempt, identifier: "first")
        await photos.setReconciliation("first", evidence: .unknown)
        await engine.recoverImports(); logger.flushForTesting()
        let relapsed = try submissionDiagnosticRows(at: logURL)
        XCTAssertEqual(relapsed.count, 4)
        XCTAssertEqual(relapsed.filter { $0["file"] == firstID.uuidString }.count, 2, "Resolution resets only the matching identity")
        XCTAssertEqual(relapsed.filter { $0["file"] == secondID.uuidString }.count, 2, "Its sibling remains deduplicated")
        XCTAssertEqual(notices.events.count, 1)
        await photos.setReconciliation("first", evidence: .found(identifier: "imported-first"))
        await photos.setReconciliation("second", evidence: .found(identifier: "imported-second"))
        await engine.recoverImports()
        let recovered = await engine.snapshot()
        XCTAssertNil(recovered.sourceIssueDetails[sourceID]); XCTAssertNil(recovered.waitingSources[sourceID])
        XCTAssertEqual(notices.events.filter(\.recovered).count, 1)
        let creates = await photos.createCount
        XCTAssertEqual(creates, 0, "Reconciliation logging must not cause another submission")
    }

    func testPreparationFailureJournalsEachFilePathStageAndCause() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let root = try SourceRegistry.normalizedURL(f.directories[0]), id = f.sourceIDs[0]
        try FileManager.default.copyItem(at: root.appendingPathComponent("same.jpg"), to: root.appendingPathComponent("second.jpg"))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try JSONDecoder().decode(DedupConfiguration.self,
            from: Data(contentsOf: repository.appendingPathComponent("docs/research/advanced-dedup/integration-profile.json")))
        let photos = DiagnosticSubmissionPhotos(), model = DiagnosticPreparationModel()
        let coordinator = PhotosIndexCoordinator(store: f.store, photos: photos, fingerprinter: model, configuration: configuration)
        try await coordinator.reconcile(); await coordinator.processDueWork(now: Date())
        let executor = ReadExecutor(), budget = ImageWorkBudget(limits: configuration.resources)
        let service = AdvancedDedupService(store: f.store, photos: photos, coordinator: coordinator, fingerprinter: model,
            configuration: configuration, executor: executor, budget: budget)
        let logs = try temporaryDirectory(), notices = SourceIssueNotificationRecorder()
        let logger = try RunLogger(directory: logs)
        let engine = SyncEngine(store: f.store, photos: photos, logger: logger,
            advancedDedup: service, indexCoordinator: coordinator, requiresAdvancedDedup: true, dedupConfiguration: configuration,
            notifySourceIssue: { _, recovered, issue in notices.record(recovered: recovered, issue: issue) })
        await engine.scan(sourceIDs: f.sourceIDs); logger.flushForTesting()
        let snapshot = await engine.snapshot()
        let details = try XCTUnwrap(snapshot.sourceIssueDetails[id])
        XCTAssertEqual(details.count, 2)
        let rows = try submissionDiagnosticRows(at: logs.appendingPathComponent("photo-sync.jsonl"))
        XCTAssertEqual(rows.count, 2)
        for detail in details {
            XCTAssertEqual(detail.stage, "准备照片判重")
            let row = try XCTUnwrap(rows.first { $0["path"] == detail.path })
            XCTAssertTrue(row["detail"]?.contains("准备照片判重") == true)
            XCTAssertTrue(row["detail"]?.contains("Fixture.Preparation 8: preparation failed") == true)
            XCTAssertTrue(row["detail"]?.contains("NSPOSIXErrorDomain 13: preparation cause") == true)
        }
        XCTAssertEqual(notices.events.count, 1)
        XCTAssertEqual(notices.events.first?.recovered, false)
        let creates = await photos.createCount; XCTAssertEqual(creates, 0)
        XCTAssertEqual(snapshot.summary?.retryPending, 2)
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
        let stored = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(submission["path"], record.file.url.path)
        XCTAssertTrue(submission["detail"]?.contains("提交导入") == true)
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

    func testScanRechecksDuplicateDecisionAfterPhotosGenerationChanges() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceFile = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        await f.photos.setCandidates([MatchCandidate(key: "photos-duplicate", metadata: sourceFile.metadata)])
        let gate = EngineTestGate()
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { sourceID in
            GatedDirectoryReader(reader: DirectoryReader(sourceID: sourceID), gate: gate)
        })

        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        await f.photos.setCandidates([])
        await f.photos.bumpCandidateGeneration()
        await gate.release()
        await scan.value

        let record = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(record?.state, .imported)
        let createCount = await f.photos.createCount
        XCTAssertEqual(createCount, 1)
    }

    func testPhotosErrorDuringDuplicateRecheckBlocksSyncInsteadOfReportingUnreadableFile() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceFile = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        await f.photos.setCandidates([MatchCandidate(key: "photos-duplicate", metadata: sourceFile.metadata)])
        let gate = EngineTestGate()
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { sourceID in
            GatedDirectoryReader(reader: DirectoryReader(sourceID: sourceID), gate: gate)
        })

        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        await f.photos.setCandidateSnapshotErrorAfterFirst(.authorizationRequired)
        await gate.release()
        await scan.value

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.blockingError, PhotoKitGatewayError.authorizationRequired.localizedDescription)
        XCTAssertEqual(snapshot.blockingSummary, SourceIssueText.authorizationRequired)
        XCTAssertEqual(snapshot.latestScan.failed, 1)
        XCTAssertEqual(snapshot.latestScan.failedFiles, 0)
        XCTAssertTrue(snapshot.waitingSources.isEmpty)
        let record = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertNil(record)
    }

    func testScanDoesNotPersistSkipWhenPhotosChangesAfterLatestSnapshot() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceFile = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        await f.photos.setCandidates([MatchCandidate(key: "photos-duplicate", metadata: sourceFile.metadata)])
        await f.photos.setCandidateSnapshotMutationAfterCall(2)

        await f.engine.scan(sourceIDs: f.sourceIDs)

        let record = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(record?.state, .imported)
        let createCount = await f.photos.createCount
        XCTAssertEqual(createCount, 1)
    }

    func testDrainDoesNotPersistSkipWhenPhotosChangesAfterLatestSnapshot() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceFile = try await engineSourceFile(sourceID: f.sourceIDs[0], directory: f.directories[0])
        _ = try await f.store.save(sourceFile, decision: .importNew)
        await f.photos.setCandidates([MatchCandidate(key: "photos-duplicate", metadata: sourceFile.metadata)])
        await f.photos.setCandidateSnapshotMutationAfterCall(2)

        await f.engine.scan(sourceIDs: f.sourceIDs)

        let record = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(record?.state, .imported)
        let createCount = await f.photos.createCount
        XCTAssertEqual(createCount, 1)
    }

    func testRecoveredOlderPendingRowIsFoundAfterCursorAdvanceAndImportedOnce() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let sourceID = f.sourceIDs[0]
        let laterURL = f.directories[0].appendingPathComponent("later.jpg")
        try FileManager.default.copyItem(at: f.directories[0].appendingPathComponent("same.jpg"), to: laterURL)
        let older = try await engineSourceFile(sourceID: sourceID, directory: f.directories[0])
        let later = SourceFile(
            sourceID: sourceID,
            relativePath: "later.jpg",
            url: laterURL,
            stamp: try await DirectoryReader(sourceID: sourceID).stamp(of: laterURL),
            metadata: try await MetadataReader(sourceID: sourceID).read(url: laterURL, filename: "later.jpg")
        )
        let olderID = try await f.store.save(older, decision: .importNew)
        let laterID = try await f.store.save(later, decision: .importNew)
        try await f.store.beginAttempt(fileID: olderID, attemptID: UUID())
        await f.photos.setEvidence(.definitelyNotCommitted)

        let cursorAdvance = try await f.store.nextPendingFile(sourceIDs: [sourceID], afterOrder: nil)
        XCTAssertEqual(cursorAdvance?.id, laterID)
        let afterCursor = try await f.store.nextPendingFile(sourceIDs: [sourceID], afterOrder: cursorAdvance?.createdOrder)
        XCTAssertNil(afterCursor)

        await f.engine.recoverImports()
        let recovered = try await f.store.file(sourceID: sourceID, relativePath: "same.jpg")
        XCTAssertEqual(recovered?.state, .pending)

        await f.engine.scan(sourceIDs: [sourceID])
        let olderAfter = try await f.store.file(sourceID: sourceID, relativePath: "same.jpg")
        let laterAfter = try await f.store.file(sourceID: sourceID, relativePath: "later.jpg")
        XCTAssertEqual(olderAfter?.state, .imported)
        XCTAssertEqual(laterAfter?.state, .imported)
        let createCount = await f.photos.createCount
        XCTAssertEqual(createCount, 2)
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

    func testSourceChangeDuringCheckpointedCreatePreservesImportedResult() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let gate = EngineTestGate()
        await f.photos.setCreationGate(gate)

        let scan = Task { await f.engine.scan(sourceIDs: f.sourceIDs) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        let checkpointed = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let record = try XCTUnwrap(checkpointed)
        XCTAssertEqual(record.state, .importing)
        XCTAssertEqual(record.placeholderID, "fake-1")

        let changed = try await f.store.recordSourceChange(fileID: record.id, stamp: .init(size: 99, modifiedNanoseconds: 99))
        XCTAssertFalse(changed)
        await gate.release()
        await scan.value

        let imported = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let snapshot = await f.engine.snapshot()
        XCTAssertEqual(imported?.state, .imported)
        XCTAssertNotNil(imported?.successID)
        XCTAssertNil(snapshot.blockingError)
    }

    func testStalePendingAdmissionAfterSourceChangeDoesNotBlockEngine() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let gate = EngineTestGate()
        let reader = SubmissionStampReader(sourceID: f.sourceIDs[0], gate: gate)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })

        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        let pending = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let record = try XCTUnwrap(pending)
        let changed = try await f.store.recordSourceChange(fileID: record.id, stamp: .init(size: 99, modifiedNanoseconds: 99))
        XCTAssertTrue(changed)
        await gate.release()
        await scan.value

        let state = try await f.store.state(of: record.id)
        let snapshot = await engine.snapshot()
        let createCount = await f.photos.createCount
        XCTAssertEqual(state, .skipped)
        XCTAssertEqual(createCount, 0)
        XCTAssertNil(snapshot.blockingError)
    }

    func testLateStampFailureAfterSourceChangeKeepsHealthyWorkMoving() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let gate = EngineTestGate()
        let reader = SubmissionStampReader(sourceID: f.sourceIDs[0], gate: gate,
                                           failSubmissionStamp: true, failSubmissionStampOnce: true)
        let notifications = NotificationRecorder()
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader },
                                notify: { notifications.record(sourceID: $0, recovered: $1) })
        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        let pending = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let record = try XCTUnwrap(pending)
        let changed = try await f.store.recordSourceChange(fileID: record.id, stamp: .init(size: 99, modifiedNanoseconds: 99))
        XCTAssertTrue(changed)

        // Queue a distinct healthy sibling while the stale stamp is held, so continuing the
        // same drain (rather than restarting the engine) must admit this work.
        let healthyURL = f.directories[0].appendingPathComponent("healthy.jpg")
        try FileManager.default.copyItem(at: record.file.url, to: healthyURL)
        let healthy = SourceFile(sourceID: f.sourceIDs[0], relativePath: "healthy.jpg", url: healthyURL,
                                 stamp: try await DirectoryReader(sourceID: f.sourceIDs[0]).stamp(of: healthyURL),
                                 metadata: try await MetadataReader(sourceID: f.sourceIDs[0]).read(url: healthyURL, filename: "healthy.jpg"))
        let healthyID = try await f.store.save(healthy, decision: .importNew)
        await gate.release()
        await scan.value

        let skipped = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let healthyState = try await f.store.state(of: healthyID)
        let snapshot = await engine.snapshot()
        let createCount = await f.photos.createCount
        XCTAssertEqual(skipped?.state, .skipped)
        XCTAssertEqual(skipped?.file.stamp, FileStamp(size: 99, modifiedNanoseconds: 99))
        XCTAssertEqual(skipped?.retryCount, 0)
        XCTAssertNil(skipped?.nextRetryAt)
        XCTAssertNil(skipped?.successID)
        XCTAssertEqual(healthyState, .imported)
        XCTAssertEqual(createCount, 1)
        XCTAssertNil(snapshot.blockingError)
        XCTAssertTrue(snapshot.waitingSources.isEmpty)
        XCTAssertTrue(snapshot.sourceIssueDetails.isEmpty)
        XCTAssertEqual(snapshot.latestScan.failed, 0)
        XCTAssertTrue(notifications.events.isEmpty)
        XCTAssertEqual(try engineSQLInteger("SELECT COALESCE(SUM(failed), 0) FROM scan_run", at: f.databaseURL), 0)
        XCTAssertNil(try engineSQLString("SELECT last_error FROM file_record WHERE id = '\(record.id.uuidString)'", at: f.databaseURL))
    }

    func testStampRetryWriteFailuresStillStopStorageForPendingRecords() async throws {
        for action in ["IGNORE", "FAIL, 'injected retry write failure'"] {
            let f = try await makeEngineFixture(sourceCount: 1)
            let reader = SubmissionStampReader(sourceID: f.sourceIDs[0], failSubmissionStamp: true)
            try injectEngineSQL("CREATE TRIGGER fail_retry BEFORE UPDATE OF retry_count ON file_record BEGIN SELECT RAISE(\(action)); END", at: f.databaseURL)
            let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })

            await engine.scan(sourceIDs: f.sourceIDs)

            let snapshot = await engine.snapshot()
            let record = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
            let createCount = await f.photos.createCount
            XCTAssertNotNil(snapshot.blockingError, action)
            XCTAssertEqual(record?.state, .pending, action)
            XCTAssertEqual(record?.retryCount, 0, action)
            XCTAssertEqual(createCount, 0, action)
        }
    }

    func testLateStampFailureDoesNotTreatImportingAsTerminal() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let gate = EngineTestGate()
        let reader = SubmissionStampReader(sourceID: f.sourceIDs[0], gate: gate, failSubmissionStamp: true)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })
        let scan = Task { await engine.scan(sourceIDs: f.sourceIDs) }
        let entered = await engineEventually { await gate.entered }
        XCTAssertTrue(entered)
        let pending = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let record = try XCTUnwrap(pending)
        let attemptID = UUID()
        try await f.store.beginAttempt(fileID: record.id, attemptID: attemptID)
        try f.store.checkpointPlaceholder(fileID: record.id, attemptID: attemptID, identifier: "unresolved")
        await gate.release()
        await scan.value

        let unresolved = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let snapshot = await engine.snapshot()
        let createCount = await f.photos.createCount
        XCTAssertEqual(unresolved?.state, .importing)
        XCTAssertEqual(unresolved?.attemptID, attemptID)
        XCTAssertEqual(unresolved?.placeholderID, "unresolved")
        XCTAssertNotNil(snapshot.blockingError)
        XCTAssertEqual(createCount, 0)
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
        let progress = (await f.engine.snapshot()).latestScan
        XCTAssertEqual(progress.failed, 1)
        // An unreadable file is a file-level failure of this round, not a source outage.
        XCTAssertEqual(progress.failedFiles, 1)
        try bytes.write(to: url)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let recovered = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(recovered?.state, .imported)
    }

    func testUnavailableSourceIsReportedPerSourceAndClearsOnRecovery() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let directory = f.directories[0]
        try FileManager.default.removeItem(at: directory)

        await f.engine.scan(sourceIDs: f.sourceIDs)

        let broken = await f.engine.snapshot()
        // One source-level failure, and deliberately not a failed file.
        XCTAssertEqual(broken.latestScan.failed, 1)
        XCTAssertEqual(broken.latestScan.failedFiles, 0)
        let issue = broken.waitingSources[f.sourceIDs[0]]
        // The headline is plain language; the system text survives only in the detail/tooltip.
        XCTAssertEqual(issue?.summary, "来源目录不可用，正在等待恢复。请检查磁盘或网络连接。")
        XCTAssertTrue(issue?.detail.contains(directory.path) ?? false)
        XCTAssertNotEqual(issue?.summary, issue?.detail)
        XCTAssertEqual(broken.sourceFileIssueCounts[f.sourceIDs[0]] ?? 0, 0)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await f.engine.scan(sourceIDs: f.sourceIDs)

        let recovered = await f.engine.snapshot()
        XCTAssertNil(recovered.waitingSources[f.sourceIDs[0]])
        XCTAssertEqual(recovered.latestScan.state, .completed)
    }

    func testRecoveredDirectoryKeepsOnlyFileIssue() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let reader = Beta3RecoveryDirectory()
        let engine = SyncEngine(
            store: f.store,
            photos: f.photos,
            directory: { _ in reader },
            metadata: { _ in Beta3BrokenMetadata() }
        )

        await engine.scan(sourceIDs: f.sourceIDs)
        let offline = await engine.snapshot()
        XCTAssertEqual(offline.waitingSources[f.sourceIDs[0]]?.kind, .sourceAvailability)

        await engine.scan(sourceIDs: f.sourceIDs)
        let recovered = await engine.snapshot()
        XCTAssertEqual(recovered.waitingSources[f.sourceIDs[0]]?.kind, .file)
        XCTAssertEqual(recovered.sourceFileIssueCounts[f.sourceIDs[0]], 1)
        XCTAssertEqual(recovered.latestScan.failedFiles, 1)
    }

    func testDirectoryFailureIsJournaledAgainAfterRecoveryWithFileIssuesRemaining() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let logDirectory = try temporaryDirectory()
        let logger = try RunLogger(directory: logDirectory)
        let reader = ControlledDirectoryReader(sourceID: f.sourceIDs[0], failingDirectory: f.directories[0], failure: .cocoaReadMissing)
        let notifications = NotificationRecorder()
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader },
                                metadata: { _ in Beta3BrokenMetadata() }, logger: logger,
                                notify: { notifications.record(sourceID: $0, recovered: $1) })
        let logURL = logDirectory.appendingPathComponent("photo-sync.jsonl")
        func failureCount(_ phase: String) throws -> Int {
            logger.flushForTesting()
            return try String(contentsOf: logURL).split(separator: "\n").filter { line in
                let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
                return row?["phase"] == phase && row?["result"] == "failed"
            }.count
        }

        await engine.scan(sourceIDs: f.sourceIDs)
        XCTAssertEqual(try failureCount("directory"), 1)
        await reader.recover()
        await engine.scan(sourceIDs: f.sourceIDs)
        let fileOnly = await engine.snapshot()
        XCTAssertEqual(fileOnly.waitingSources[f.sourceIDs[0]]?.kind, .file)
        XCTAssertEqual(try failureCount("directory"), 1)
        XCTAssertEqual(try failureCount("metadata"), 1)

        await reader.failAgain(.cocoaReadMissing)
        await engine.scan(sourceIDs: f.sourceIDs)
        let offlineAgain = await engine.snapshot()
        XCTAssertEqual(offlineAgain.waitingSources[f.sourceIDs[0]]?.kind, .sourceAvailability)
        XCTAssertEqual(try failureCount("directory"), 2)

        // Directory recovery must not retire the ongoing file failure's signature or unlatch
        // the aggregate notification while that file is still unreadable.
        await reader.recover()
        await engine.scan(sourceIDs: f.sourceIDs)
        await engine.scan(sourceIDs: f.sourceIDs)
        XCTAssertEqual(try failureCount("directory"), 2)
        XCTAssertEqual(try failureCount("metadata"), 1)
        XCTAssertEqual(notifications.events.count, 1)
        XCTAssertEqual(notifications.events.first?.1, false)
    }

    func testUnreadableFilesAreCountedPerFileAndClearIndividually() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let valid = try Data(contentsOf: f.directories[0].appendingPathComponent("same.jpg"))
        let first = f.directories[0].appendingPathComponent("bad-1.jpg")
        let second = f.directories[0].appendingPathComponent("bad-2.jpg")
        try Data("bad JPEG".utf8).write(to: first)
        try Data("bad JPEG".utf8).write(to: second)

        await f.engine.scan(sourceIDs: f.sourceIDs)
        let both = await f.engine.snapshot()
        XCTAssertEqual(both.latestScan.failedFiles, 2)
        XCTAssertEqual(both.sourceFileIssueCounts[f.sourceIDs[0]], 2)
        XCTAssertEqual(both.waitingSources[f.sourceIDs[0]]?.summary, "文件暂时无法读取，具体原因尚无法确定。")
        XCTAssertTrue(both.waitingSources[f.sourceIDs[0]]?.detail.contains("bad-1.jpg") ?? false)

        // Repairing one file clears only that file's issue; the source keeps waiting for the other.
        try valid.write(to: first)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let partial = await f.engine.snapshot()
        XCTAssertEqual(partial.sourceFileIssueCounts[f.sourceIDs[0]], 1)
        XCTAssertNotNil(partial.waitingSources[f.sourceIDs[0]])

        try valid.write(to: second)
        await f.engine.scan(sourceIDs: f.sourceIDs)
        let clean = await f.engine.snapshot()
        XCTAssertEqual(clean.latestScan.state, .completed)
        XCTAssertNil(clean.waitingSources[f.sourceIDs[0]])
        XCTAssertNil(clean.sourceFileIssueCounts[f.sourceIDs[0]])
    }

    func testUnmountedVolumeIsExplainedInPlainLanguage() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                            userInfo: [NSLocalizedDescriptionKey: "The file “home” couldn’t be opened because there is no such file."])
        let url = URL(fileURLWithPath: "/Volumes/PhotoSyncMissingVolume/Photos/2026")
        let issue = SourceIssueText.directoryUnavailable(sourceURL: url, failingURL: url, isRoot: true, error: error)
        XCTAssertTrue(issue.summary.contains("未挂载"))
        XCTAssertTrue(issue.summary.contains("/Volumes/PhotoSyncMissingVolume"))
        XCTAssertFalse(issue.summary.contains("couldn’t be opened"))
        XCTAssertTrue(issue.detail.contains("couldn’t be opened"))
    }

    func testDeferredReadIsWaitingNotAnError() async throws {
        // The bounded reader refusing a concurrent read of one source is normal waiting: nothing
        // is reported to the person, nothing counts as an unreadable file, and it comes back.
        let f = try await makeEngineFixture(sourceCount: 1)
        let recorder = IssueRecorder()
        let reader = ControlledDirectoryReader(sourceID: f.sourceIDs[0], failingDirectory: f.directories[0],
                                              failure: .sourceBusy)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader },
                                notifyIssue: { message in Task { await recorder.record(message) } })

        await engine.scan(sourceIDs: f.sourceIDs)

        let waiting = await engine.snapshot()
        XCTAssertNil(waiting.waitingSources[f.sourceIDs[0]])
        XCTAssertEqual(waiting.sourceFileIssueCounts[f.sourceIDs[0]] ?? 0, 0)
        XCTAssertTrue(waiting.deferredSources.contains(f.sourceIDs[0]))
        XCTAssertTrue(waiting.latestScan.deferred)
        XCTAssertEqual(waiting.latestScan.failedFiles, 0)
        let announced = await recorder.messages.count
        XCTAssertEqual(announced, 0)

        await reader.recover()
        await engine.scan(sourceIDs: f.sourceIDs)

        let recovered = await engine.snapshot()
        XCTAssertFalse(recovered.deferredSources.contains(f.sourceIDs[0]))
        XCTAssertEqual(recovered.latestScan.state, .completed)
        let imported = await f.photos.createCount
        XCTAssertEqual(imported, 1)
    }

    func testDeferredDirectoryReadCompletesScanRunWithoutFailureOrJournal() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let logDirectory = try temporaryDirectory()
        let logger = try RunLogger(directory: logDirectory)
        let reader = ControlledDirectoryReader(sourceID: f.sourceIDs[0], failingDirectory: f.directories[0], failure: .sourceBusy)
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader }, logger: logger)

        await engine.scan(sourceIDs: f.sourceIDs)

        let snapshot = await engine.snapshot()
        XCTAssertTrue(snapshot.latestScan.deferred)
        XCTAssertEqual(snapshot.latestScan.failed, 0)
        XCTAssertEqual(snapshot.latestScan.failedFiles, 0)
        XCTAssertEqual(
            try engineSQLInteger("SELECT complete FROM scan_run WHERE source_id = '\(f.sourceIDs[0].uuidString)' ORDER BY started_at DESC LIMIT 1", at: f.databaseURL),
            1
        )
        XCTAssertEqual(
            try engineSQLInteger("SELECT failed FROM scan_run WHERE source_id = '\(f.sourceIDs[0].uuidString)' ORDER BY started_at DESC LIMIT 1", at: f.databaseURL),
            0
        )
        XCTAssertNil(try engineSQLString("SELECT last_error FROM scan_run WHERE source_id = '\(f.sourceIDs[0].uuidString)' ORDER BY started_at DESC LIMIT 1", at: f.databaseURL))

        let logURL = logDirectory.appendingPathComponent("photo-sync.jsonl")
        let text = try? String(contentsOf: logURL)
        XCTAssertFalse(text?.contains("\"result\":\"failed\"") == true)
    }

    func testDeferredMetadataReadCompletesScanRunWithoutFailureOrJournal() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let logDirectory = try temporaryDirectory()
        let logger = try RunLogger(directory: logDirectory)
        let engine = SyncEngine(
            store: f.store,
            photos: f.photos,
            metadata: { _ in DeferredMetadataReader() },
            logger: logger
        )

        await engine.scan(sourceIDs: f.sourceIDs)

        let snapshot = await engine.snapshot()
        XCTAssertTrue(snapshot.latestScan.deferred)
        XCTAssertEqual(snapshot.latestScan.failed, 0)
        XCTAssertEqual(snapshot.latestScan.failedFiles, 0)
        XCTAssertEqual(
            try engineSQLInteger("SELECT complete FROM scan_run WHERE source_id = '\(f.sourceIDs[0].uuidString)' ORDER BY started_at DESC LIMIT 1", at: f.databaseURL),
            1
        )
        XCTAssertEqual(
            try engineSQLInteger("SELECT failed FROM scan_run WHERE source_id = '\(f.sourceIDs[0].uuidString)' ORDER BY started_at DESC LIMIT 1", at: f.databaseURL),
            0
        )
        XCTAssertNil(try engineSQLString("SELECT last_error FROM scan_run WHERE source_id = '\(f.sourceIDs[0].uuidString)' ORDER BY started_at DESC LIMIT 1", at: f.databaseURL))
        let logURL = logDirectory.appendingPathComponent("photo-sync.jsonl")
        let text = try? String(contentsOf: logURL)
        XCTAssertFalse(text?.contains("\"result\":\"failed\"") == true)
    }

    func testDeferredStampReadKeepsTheFilePendingWithoutAnIssue() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let reader = ContendedSubmissionStampReader(sourceID: f.sourceIDs[0])
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })

        await engine.scan(sourceIDs: f.sourceIDs)

        let waiting = await engine.snapshot()
        XCTAssertNil(waiting.waitingSources[f.sourceIDs[0]])
        XCTAssertTrue(waiting.deferredSources.contains(f.sourceIDs[0]))
        XCTAssertTrue(waiting.latestScan.deferred)
        let record = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(record?.state, .pending)
        XCTAssertEqual(record?.retryCount, 0)
        XCTAssertNil(record?.nextRetryAt)
        XCTAssertEqual(try engineSQLString("SELECT last_error FROM file_record WHERE source_id = '\(f.sourceIDs[0].uuidString)' AND relative_path = 'same.jpg'", at: f.databaseURL), nil)
        let summary = try await f.store.activeSourceSummary()
        XCTAssertEqual(summary.retryPending, 0)
        let created = await f.photos.createCount
        XCTAssertEqual(created, 0)
        // The deferred read never marks the source's scan run as failed.
        XCTAssertEqual(try engineSQLInteger("SELECT COALESCE(SUM(failed), 0) FROM scan_run", at: f.databaseURL), 0)

        await reader.recover()
        try injectEngineSQL("UPDATE file_record SET next_retry_at = 0", at: f.databaseURL)
        await engine.scan(sourceIDs: f.sourceIDs)

        let recovered = await engine.snapshot()
        XCTAssertFalse(recovered.deferredSources.contains(f.sourceIDs[0]))
        let imported = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        XCTAssertEqual(imported?.state, .imported)
    }

    func testRepeatedUnavailableSourceIsJournaledOnce() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let logDirectory = try temporaryDirectory()
        let logger = try RunLogger(directory: logDirectory)
        let engine = SyncEngine(store: f.store, photos: f.photos, logger: logger)
        try FileManager.default.removeItem(at: f.directories[0])

        await engine.scan(sourceIDs: f.sourceIDs)
        await engine.scan(sourceIDs: f.sourceIDs)
        await engine.scan(sourceIDs: f.sourceIDs)

        // A recovered source starts a new condition: a later outage is journaled again.
        try FileManager.default.createDirectory(at: f.directories[0], withIntermediateDirectories: true)
        await engine.scan(sourceIDs: f.sourceIDs)
        try FileManager.default.removeItem(at: f.directories[0])
        await engine.scan(sourceIDs: f.sourceIDs)

        let logURL = logDirectory.appendingPathComponent("photo-sync.jsonl")
        let lines = try String(contentsOf: logURL).split(separator: "\n")
        let directoryFailures = try lines.filter { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
            return object?["phase"] == "directory" && object?["result"] == "failed"
        }
        // Each attempt persists its own scan_run row; the journal keeps the transitions only.
        XCTAssertEqual(directoryFailures.count, 2)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: f.databaseURL), 5)
    }

    func testBlockingIssueIsAnnouncedOncePerDistinctMessage() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let recorder = IssueRecorder()
        let engine = SyncEngine(store: f.store, photos: f.photos,
                                notifyIssue: { message in Task { await recorder.record(message) } })
        await f.photos.setLoadFailure(true)

        await engine.scan(sourceIDs: f.sourceIDs)
        let first = await engineEventually { await recorder.messages.count >= 1 }
        XCTAssertTrue(first)
        let blocked = await engine.snapshot()
        XCTAssertNotNil(blocked.blockingError)

        await engine.scan(sourceIDs: f.sourceIDs)
        let settled = await engineEventually { await recorder.messages.count > 1 }
        XCTAssertFalse(settled)
        let announced = await recorder.messages.count
        XCTAssertEqual(announced, 1)
    }

    func testAuthorizationRequiredCandidateLoadUsesPermissionHeadline() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let engine = SyncEngine(store: f.store, photos: AuthorizationRequiredPhotosGateway())

        await engine.scan(sourceIDs: f.sourceIDs)

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.blockingSummary, "未获“照片”读写权限，同步已暂停。请在设置中点“授权访问照片”。")
        XCTAssertEqual(snapshot.blockingError, PhotoKitGatewayError.authorizationRequired.localizedDescription)
    }

    func testSourceIssueNotificationCarriesFriendlySummaryAndRetainsRawDetailSeparately() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let recorder = SourceIssueNotificationRecorder()
        let reader = ControlledDirectoryReader(
            sourceID: f.sourceIDs[0],
            failingDirectory: f.directories[0],
            failure: .permissionDenied
        )
        let engine = SyncEngine(
            store: f.store,
            photos: f.photos,
            directory: { _ in reader },
            notifySourceIssue: { _, recovered, issue in
                recorder.record(recovered: recovered, issue: issue)
            }
        )

        await engine.scan(sourceIDs: f.sourceIDs)

        let event = recorder.events.first
        XCTAssertEqual(event?.recovered, false)
        XCTAssertEqual(event?.issue?.summary, "来源目录无法访问，请检查访问权限；恢复后会自动继续。")
        XCTAssertTrue(event?.issue?.detail.contains("permission denied") ?? false)
        XCTAssertNotEqual(event?.issue?.summary, event?.issue?.detail)
    }

    func testWaitingSourceSummaryCompatibilityAccessorMapsTheHumanHeadline() {
        let sourceID = UUID()
        var snapshot = EngineSnapshot()
        snapshot.waitingSources[sourceID] = SourceIssue(summary: "目录暂时不可用。", detail: "raw detail")
        XCTAssertEqual(snapshot.waitingSourceSummaries[sourceID], "目录暂时不可用。")
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

    func testSubmissionStampFailuresKeepSeparateFileIdentitiesAndResetAfterRecovery() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let secondURL = f.directories[0].appendingPathComponent("second.jpg")
        try FileManager.default.copyItem(at: f.directories[0].appendingPathComponent("same.jpg"), to: secondURL)
        let logDirectory = try temporaryDirectory()
        let logger = try RunLogger(directory: logDirectory)
        let reader = Beta3SubmissionStampDirectory(sourceID: f.sourceIDs[0])
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader }, logger: logger)
        let logURL = logDirectory.appendingPathComponent("photo-sync.jsonl")

        await engine.scan(sourceIDs: f.sourceIDs)
        logger.flushForTesting()

        let sameRecord = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "same.jpg")
        let secondRecord = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "second.jpg")
        let same = try XCTUnwrap(sameRecord)
        let second = try XCTUnwrap(secondRecord)
        let expectedIDs = Set([same.id.uuidString, second.id.uuidString])
        let initialRows = try submissionStampFailureRows(at: logURL)
        XCTAssertEqual(Set(initialRows.compactMap { $0["file"] }), expectedIDs)
        XCTAssertEqual(initialRows.count, 2)

        try injectEngineSQL("UPDATE file_record SET next_retry_at = 0", at: f.databaseURL)
        await engine.scan(sourceIDs: f.sourceIDs)
        logger.flushForTesting()
        XCTAssertEqual(try submissionStampFailureRows(at: logURL).count, 2)

        await reader.recover()
        try injectEngineSQL("UPDATE file_record SET next_retry_at = 0", at: f.databaseURL)
        await engine.scan(sourceIDs: f.sourceIDs)
        logger.flushForTesting()
        let sameState = try await f.store.state(of: same.id)
        let secondState = try await f.store.state(of: second.id)
        XCTAssertEqual(sameState, .imported)
        XCTAssertEqual(secondState, .imported)

        // The isolated row is made retryable again solely to exercise a later failure of the
        // same persisted identity after its successful recovery cleared the journal signature.
        try injectEngineSQL(
            "UPDATE file_record SET state = 'pending', success_id = NULL, success_metadata_json = NULL, retry_count = 0, next_retry_at = 0, last_error = NULL, definitely_not_committed = 0 WHERE id = '\(same.id.uuidString)'",
            at: f.databaseURL
        )
        await reader.failAgain()
        await engine.scan(sourceIDs: f.sourceIDs)
        logger.flushForTesting()
        let recoveredThenFailedRows = try submissionStampFailureRows(at: logURL)
        XCTAssertEqual(recoveredThenFailedRows.count, 3)
        XCTAssertEqual(recoveredThenFailedRows.filter { $0["file"] == same.id.uuidString }.count, 2)
        XCTAssertEqual(recoveredThenFailedRows.filter { $0["file"] == second.id.uuidString }.count, 1)

        try injectEngineSQL("UPDATE file_record SET next_retry_at = 0 WHERE id = '\(same.id.uuidString)'", at: f.databaseURL)
        await engine.scan(sourceIDs: f.sourceIDs)
        logger.flushForTesting()
        XCTAssertEqual(try submissionStampFailureRows(at: logURL).count, 3)
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

    func testRootDirectoryUnavailableMessageRetainsTechnicalErrorAndRecovers() async throws {
        let f = try await makeEngineFixture(sourceCount: 1)
        let logDirectory = try temporaryDirectory()
        let logger = try RunLogger(directory: logDirectory)
        let reader = ControlledDirectoryReader(
            sourceID: f.sourceIDs[0],
            failingDirectory: f.directories[0],
            failure: .cocoaMissing
        )
        let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader }, logger: logger)

        await engine.scan(sourceIDs: f.sourceIDs)

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.waitingSources[f.sourceIDs[0]]?.summary, "来源目录不可用，正在等待恢复。请检查磁盘或网络连接。")
        XCTAssertEqual(snapshot.latestScan.failed, 1)
        XCTAssertEqual(
            try engineSQLString("SELECT last_error FROM scan_run WHERE source_id = '\(f.sourceIDs[0].uuidString)' ORDER BY started_at DESC LIMIT 1", at: f.databaseURL),
            "file home no such directory"
        )
        let logURL = logDirectory.appendingPathComponent("photo-sync.jsonl")
        let logged = await engineEventually { loggedEvent(at: logURL, phase: "directory", result: "failed")?["error"] == "file home no such directory" }
        XCTAssertTrue(logged)

        await reader.recover()
        await engine.scan(sourceIDs: f.sourceIDs)

        let recoveredSnapshot = await engine.snapshot()
        let importedCount = await f.photos.createCount
        XCTAssertNil(recoveredSnapshot.waitingSources[f.sourceIDs[0]])
        XCTAssertEqual(importedCount, 1)
    }

    func testRootDirectoryFailuresUseFriendlyMessages() async throws {
        // Read contention is deliberately absent here: it is waiting, not a reported problem.
        let cases: [(String, DirectoryFailure, String)] = [
            ("Cocoa missing", .cocoaMissing, "来源目录不可用，正在等待恢复。请检查磁盘或网络连接。"),
            ("Cocoa read missing", .cocoaReadMissing, "来源目录不可用，正在等待恢复。请检查磁盘或网络连接。"),
            ("POSIX missing", .posixMissing, "来源目录不可用，正在等待恢复。请检查磁盘或网络连接。"),
            ("POSIX not directory", .posixNotDirectory, "来源目录不可用，正在等待恢复。请检查磁盘或网络连接。"),
            ("nested no device", .nestedNoDevice, "来源目录不可用，正在等待恢复。请检查磁盘或网络连接。"),
            ("permission", .permissionDenied, "来源目录无法访问，请检查访问权限；恢复后会自动继续。"),
            ("Cocoa permission", .cocoaReadPermission, "来源目录无法访问，请检查访问权限；恢复后会自动继续。"),
            ("operation not permitted", .operationNotPermitted, "来源目录无法访问，请检查访问权限；恢复后会自动继续。"),
            ("alias", .aliasOrLink, "来源配置无效：不支持别名或符号链接，请重新选择实际文件夹。"),
            ("not directory", .notDirectory, "来源配置无效：所选路径不是文件夹，请重新选择来源目录。"),
            ("unknown", .unknown, "来源目录暂时无法读取，正在等待恢复。")
        ]

        for (name, failure, expected) in cases {
            let f = try await makeEngineFixture(sourceCount: 1)
            let reader = ControlledDirectoryReader(
                sourceID: f.sourceIDs[0],
                failingDirectory: f.directories[0],
                failure: failure
            )
            let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })

            await engine.scan(sourceIDs: f.sourceIDs)

            let snapshot = await engine.snapshot()
            XCTAssertEqual(snapshot.waitingSources[f.sourceIDs[0]]?.summary, expected, name)
            // No reported problem for a deferred read: it must not reach the waiting list at all.
            XCTAssertFalse(snapshot.deferredSources.contains(f.sourceIDs[0]), name)
        }
    }

    func testEachContentionReasonIsDeferredInsteadOfReported() async throws {
        for failure in [DirectoryFailure.timedOut, .sourceBusy, .resourceExhausted] {
            let f = try await makeEngineFixture(sourceCount: 1)
            let reader = ControlledDirectoryReader(
                sourceID: f.sourceIDs[0],
                failingDirectory: f.directories[0],
                failure: failure
            )
            let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })

            await engine.scan(sourceIDs: f.sourceIDs)

            let snapshot = await engine.snapshot()
            XCTAssertNil(snapshot.waitingSources[f.sourceIDs[0]])
            XCTAssertTrue(snapshot.deferredSources.contains(f.sourceIDs[0]))
            XCTAssertEqual(snapshot.latestScan.failedFiles, 0)
        }
    }

    func testChildDirectoryFailuresUsePartialMessagesAndScanHealthySibling() async throws {
        let cases: [(DirectoryFailure, String)] = [
            (.cocoaReadMissing, "部分子目录不可用，正在等待恢复。请检查磁盘或网络连接。"),
            (.permissionDenied, "部分子目录无法访问，请检查访问权限；恢复后会自动继续。")
        ]

        for (failure, expected) in cases {
            let f = try await makeEngineFixture(sourceCount: 1)
            let unavailable = f.directories[0].appendingPathComponent("unavailable", isDirectory: true)
            let healthy = f.directories[0].appendingPathComponent("healthy", isDirectory: true)
            try FileManager.default.createDirectory(at: unavailable, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: f.directories[0].appendingPathComponent("same.jpg"), to: healthy.appendingPathComponent("healthy.jpg"))
            let reader = ControlledDirectoryReader(sourceID: f.sourceIDs[0], failingDirectory: unavailable, failure: failure)
            let engine = SyncEngine(store: f.store, photos: f.photos, directory: { _ in reader })

            await engine.scan(sourceIDs: f.sourceIDs)

            let snapshot = await engine.snapshot()
            XCTAssertEqual(snapshot.waitingSources[f.sourceIDs[0]]?.summary, expected)
            XCTAssertEqual(snapshot.latestScan.failed, 1)
            XCTAssertEqual(snapshot.summary?.imported, 1)
            let healthyFile = try await f.store.file(sourceID: f.sourceIDs[0], relativePath: "healthy/healthy.jpg")
            XCTAssertEqual(healthyFile?.state, .imported)
        }
    }
}

private func loggedEvent(at url: URL, phase: String, result: String) -> [String: String]? {
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
    return text.split(separator: "\n").compactMap { line in
        let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: String]
        return object?["phase"] == phase && object?["result"] == result ? object : nil
    }.first
}

private func submissionStampFailureRows(at url: URL) throws -> [[String: String]] {
    let text = try String(contentsOf: url)
    return try text.split(separator: "\n").compactMap { line in
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
        return object?["phase"] == "submission-stamp" && object?["result"] == "failed" ? object : nil
    }
}

private actor PreAdmissionFailurePhotosGateway: PhotosGateway {
    private(set) var createCallCount = 0
    private(set) var actualSubmissionCount = 0

    func loadCandidates() async throws -> [MatchCandidate] { [] }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        PhotosCandidateSnapshot(generation: 0, candidates: [])
    }

    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }

    func create(
        fileURL: URL,
        kind: MediaKind,
        expectedGeneration: Int,
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

private struct FailingScanStampReader: DirectoryReading {
    let reader: DirectoryReader

    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        try await reader.entries(in: directory)
    }

    func stamp(of file: URL) async throws -> FileStamp {
        if file.lastPathComponent == "same.jpg" {
            throw FixtureError.unavailable("scan stamp unavailable")
        }
        return try await reader.stamp(of: file)
    }
}

private actor GatedMissingFileReader: DirectoryReading {
    let reader: DirectoryReader
    let scanGate: EngineTestGate
    let stampGate: EngineTestGate
    private var holdsScan = false
    init(reader: DirectoryReader, scanGate: EngineTestGate, stampGate: EngineTestGate) {
        self.reader = reader; self.scanGate = scanGate; self.stampGate = stampGate
    }
    func holdScan() { holdsScan = true }

    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        if holdsScan { await scanGate.wait() }
        return try await reader.entries(in: directory)
    }

    func stamp(of file: URL) async throws -> FileStamp {
        await stampGate.wait()
        return try await reader.stamp(of: file)
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

private final class SourceIssueNotificationRecorder: @unchecked Sendable {
    struct Event {
        let recovered: Bool
        let issue: SourceIssue?
    }

    private let lock = NSLock()
    private var recorded: [Event] = []

    var events: [Event] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(recovered: Bool, issue: SourceIssue?) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Event(recovered: recovered, issue: issue))
    }
}

private func engineSQLString(_ sql: String, at url: URL) throws -> String? {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw FixtureError.unavailable("sqlite open") }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
        throw FixtureError.unavailable("sqlite query")
    }
    guard let value = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: value)
}

private enum DirectoryFailure: Sendable {
    case cocoaMissing
    case cocoaReadMissing
    case posixMissing
    case posixNotDirectory
    case nestedNoDevice
    case permissionDenied
    case cocoaReadPermission
    case operationNotPermitted
    case timedOut
    case sourceBusy
    case resourceExhausted
    case aliasOrLink
    case notDirectory
    case unknown

    func error(for directory: URL) -> Error {
        switch self {
        case .cocoaMissing:
            return NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                           userInfo: [NSLocalizedDescriptionKey: "file home no such directory"])
        case .cocoaReadMissing:
            return NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                           userInfo: [NSLocalizedDescriptionKey: "file read no such directory"])
        case .posixMissing:
            return NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSLocalizedDescriptionKey: "directory not found"])
        case .posixNotDirectory:
            return NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR), userInfo: [NSLocalizedDescriptionKey: "not a directory"])
        case .nestedNoDevice:
            // The outer error says nothing useful; the cause is one level down.
            return NSError(domain: NSURLErrorDomain, code: -1, userInfo: [
                NSLocalizedDescriptionKey: "directory transport failed",
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENODEV))
            ])
        case .permissionDenied:
            return NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        case .cocoaReadPermission:
            return NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [NSLocalizedDescriptionKey: "Cocoa permission denied"])
        case .operationNotPermitted:
            return NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: [NSLocalizedDescriptionKey: "operation not permitted"])
        case .timedOut:
            return ReadExecutorError.timedOut
        case .sourceBusy:
            return ReadExecutorError.sourceBusy
        case .resourceExhausted:
            return ReadExecutorError.resourceExhausted
        case .aliasOrLink:
            return SourceRegistryError.aliasOrLink(directory)
        case .notDirectory:
            return SourceRegistryError.notDirectory(directory)
        case .unknown:
            return NSError(domain: "PhotoSyncTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "do not display this technical error"])
        }
    }
}

private actor ControlledDirectoryReader: DirectoryReading {
    private let reader: DirectoryReader
    private let failingDirectory: URL
    private var failure: DirectoryFailure?

    init(sourceID: UUID, failingDirectory: URL, failure: DirectoryFailure) {
        reader = DirectoryReader(sourceID: sourceID)
        self.failingDirectory = failingDirectory
        self.failure = failure
    }

    func recover() { failure = nil }
    func failAgain(_ failure: DirectoryFailure) { self.failure = failure }

    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        if directory.resolvingSymlinksInPath().path == failingDirectory.resolvingSymlinksInPath().path, let failure {
            throw failure.error(for: directory)
        }
        return try await reader.entries(in: directory)
    }

    func stamp(of file: URL) async throws -> FileStamp { try await reader.stamp(of: file) }
}

/// Refuses the submission-time stamp read while the scan's own stamp read succeeds, which is the
/// same-source contention the bounded reader produces when imports and scans overlap.
private actor ContendedSubmissionStampReader: DirectoryReading {
    private let reader: DirectoryReader
    private var stamps = 0
    private var contended = true

    init(sourceID: UUID) { reader = DirectoryReader(sourceID: sourceID) }

    func recover() { contended = false }

    func entries(in directory: URL) async throws -> [DirectoryEntry] { try await reader.entries(in: directory) }

    func stamp(of file: URL) async throws -> FileStamp {
        stamps += 1
        if stamps > 1, contended { throw ReadExecutorError.sourceBusy }
        return try await reader.stamp(of: file)
    }
}

private actor Beta3RecoveryDirectory: DirectoryReading {
    private var calls = 0

    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        calls += 1
        if calls == 1 { throw CocoaError(.fileReadNoSuchFile) }
        return [DirectoryEntry(url: directory.appendingPathComponent("broken.jpg"), isDirectory: false, stamp: nil)]
    }

    func stamp(of file: URL) async throws -> FileStamp {
        FileStamp(size: 12, modifiedNanoseconds: 1)
    }
}

private struct Beta3BrokenMetadata: MetadataReading {
    func read(url: URL, filename: String) async throws -> MediaMetadata {
        throw MetadataError.unreadable
    }
}

private actor Beta3SubmissionStampDirectory: DirectoryReading {
    private let reader: DirectoryReader
    private var scanStampsRemaining = 0
    private var failingSubmissionStamps = true
    private var expectsRootProbe = false

    init(sourceID: UUID) {
        reader = DirectoryReader(sourceID: sourceID)
    }

    func recover() { failingSubmissionStamps = false }
    func failAgain() { failingSubmissionStamps = true }

    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        let entries = try await reader.entries(in: directory)
        if expectsRootProbe { expectsRootProbe = false }
        else { scanStampsRemaining += entries.filter { !$0.isDirectory && $0.failure == nil }.count }
        return entries
    }

    func stamp(of file: URL) async throws -> FileStamp {
        if scanStampsRemaining > 0 {
            scanStampsRemaining -= 1
            return try await reader.stamp(of: file)
        }
        if failingSubmissionStamps {
            expectsRootProbe = true
            throw FixtureError.unavailable("submission stat unavailable")
        }
        return try await reader.stamp(of: file)
    }
}

private struct DeferredMetadataReader: MetadataReading {
    func read(url: URL, filename: String) async throws -> MediaMetadata {
        throw ReadExecutorError.sourceBusy
    }
}

private struct AuthorizationRequiredPhotosGateway: PhotosGateway {
    func loadCandidates() async throws -> [MatchCandidate] {
        throw PhotoKitGatewayError.authorizationRequired
    }

    func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        throw PhotoKitGatewayError.authorizationRequired
    }

    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        throw PhotoKitGatewayError.authorizationRequired
    }

    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}

/// Uses real synthetic-directory enumeration; faults occur at the I/O boundary only.
private actor DiagnosticDirectory: DirectoryReading {
    private let reader: DirectoryReader
    private var failures: [String: NSError] = [:]
    private var fileFailures: [String: NSError] = [:]
    private var attributeFailures: [String: NSError] = [:]
    private var deferredFilePath: String?
    private var deferredPath: String?
    private var heldPath: String?
    private var gate: EngineTestGate?
    init(sourceID: UUID) { reader = DirectoryReader(sourceID: sourceID) }
    func setFailure(_ url: URL, code: Int?) {
        failures[url.resolvingSymlinksInPath().path] = code.map { NSError(domain: NSPOSIXErrorDomain, code: $0,
            userInfo: [NSLocalizedDescriptionKey: "fixture failure \($0)"]) }
    }
    func setFileFailure(_ url: URL, code: Int) {
        fileFailures[url.resolvingSymlinksInPath().path] = NSError(domain: NSPOSIXErrorDomain, code: code)
    }
    func failAttribute(_ url: URL, code: Int?) {
        attributeFailures[url.resolvingSymlinksInPath().path] = code.map {
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSLocalizedDescriptionKey: "attribute wrapper",
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: $0, userInfo: [NSLocalizedDescriptionKey: "attribute leaf"])])
        }
    }
    func setFileDeferred(_ url: URL) { deferredFilePath = url.resolvingSymlinksInPath().path }
    func deferDirectory(_ url: URL?) { deferredPath = url?.resolvingSymlinksInPath().path }
    func hold(_ url: URL, gate: EngineTestGate) { heldPath = url.resolvingSymlinksInPath().path; self.gate = gate }
    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        if directory.resolvingSymlinksInPath().path == heldPath, let gate { await gate.wait() }
        if directory.resolvingSymlinksInPath().path == deferredPath { throw ReadExecutorError.sourceBusy }
        if let failure = failures[directory.resolvingSymlinksInPath().path] { throw failure }
        return try await reader.entries(in: directory).map { entry in
            guard let error = attributeFailures[entry.url.resolvingSymlinksInPath().path] else { return entry }
            return DirectoryEntry(url: entry.url, isDirectory: false, stamp: nil, failure: error.localizedDescription, failureCause: error)
        }
    }
    func stamp(of file: URL) async throws -> FileStamp {
        if file.resolvingSymlinksInPath().path == deferredFilePath { throw ReadExecutorError.sourceBusy }
        if let failure = fileFailures[file.resolvingSymlinksInPath().path] { throw failure }
        return try await reader.stamp(of: file)
    }
}

private func submissionDiagnosticRows(at url: URL) throws -> [[String: String]] {
    try String(contentsOf: url).split(separator: "\n").compactMap { line in
        let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
        return row?["phase"] == "submission-diagnostic" ? row : nil
    }
}

private func diagnosticReconciliationError(_ cause: String) -> NSError {
    NSError(domain: "Fixture.Reconciliation", code: 7, userInfo: [NSLocalizedDescriptionKey: "outer unchanged",
        NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: cause])])
}

private actor DiagnosticSubmissionPhotos: PhotosIndexGateway {
    nonisolated let context = LibraryContext(id: UUID(), epoch: 1)
    private var evidence: [String: ImportEvidence] = [:]
    private var errors: [String: NSError] = [:]
    private(set) var createCount = 0
    func setReconciliation(_ placeholder: String, evidence: ImportEvidence) { self.evidence[placeholder] = evidence; errors[placeholder] = nil }
    func setReconciliation(_ placeholder: String, error: NSError) { errors[placeholder] = error }
    func reconcile(placeholder: String?) async throws -> ImportEvidence {
        let key = placeholder ?? ""
        if let error = errors[key] { throw error }
        return evidence[key] ?? .unknown
    }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot { .init(generation: 1, candidates: []) }
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { AsyncStream { $0.finish() } }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage {
        .init(context: context, generation: 1, descriptors: [], nextOffset: nil)
    }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation { throw PhotoKitGatewayError.libraryUnavailable }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        createCount += 1
        throw FixtureError.unavailable("No create is expected while logging these diagnostics")
    }
}

private struct DiagnosticPreparationModel: ImageFingerprinting {
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        throw NSError(domain: "Fixture.Preparation", code: 8, userInfo: [NSLocalizedDescriptionKey: "preparation failed",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: "preparation cause"])])
    }
}

/// Real synthetic filesystem reads with faults only at root/file I/O boundaries.
private actor RootOutageDirectory: DirectoryReading {
    enum Drop: Sendable { case initial, scanStamp, submissionStamp, never }
    private let reader: DirectoryReader
    private let root: URL
    private var drop: Drop
    private var offline: Bool
    private var scanStampsRemaining = 0
    private var rootGate: EngineTestGate?
    private var dropGate: EngineTestGate?
    private var nextRootResultGate: EngineTestGate?
    func holdDrop(_ gate: EngineTestGate) { dropGate = gate }
    func holdNextRootResult(_ gate: EngineTestGate) { nextRootResultGate = gate }
    private var defersRootProbe = false
    private var defersFirstStamp = false
    func deferFirstStamp() { defersFirstStamp = true }
    func deferRootProbe() { defersRootProbe = true }
    private(set) var stampCalls = 0
    func holdRoot(_ gate: EngineTestGate) { rootGate = gate }
    init(sourceID: UUID, root: URL, drop: Drop) {
        reader = DirectoryReader(sourceID: sourceID); self.root = root; self.drop = drop
        offline = drop == .initial
    }
    func disconnect() { offline = true }
    func recover() { offline = false; drop = .never }
    private func unavailable() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))])
    }
    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        if let rootGate { await rootGate.wait() }
        if offline, defersRootProbe { throw ReadExecutorError.sourceBusy }
        if offline { throw unavailable() }
        let entries = try await reader.entries(in: directory)
        if directory.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path {
            scanStampsRemaining = entries.filter { !$0.isDirectory }.count
            if let gate = nextRootResultGate {
                nextRootResultGate = nil
                await gate.wait()
            }
        }
        return entries
    }
    func stamp(of file: URL) async throws -> FileStamp {
        stampCalls += 1
        if defersFirstStamp, stampCalls == 1 { throw ReadExecutorError.sourceBusy }
        if drop == .scanStamp || (drop == .submissionStamp && scanStampsRemaining == 0) {
            if let dropGate { await dropGate.wait() }
            offline = true
        }
        if offline { throw unavailable() }
        scanStampsRemaining -= 1
        return try await reader.stamp(of: file)
    }
}
