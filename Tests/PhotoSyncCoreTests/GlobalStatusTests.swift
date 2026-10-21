import XCTest
import AppKit
@testable import PhotoSyncCore

final class GlobalStatusTests: XCTestCase {
    func testWaitingAndFailureHaveDistinctHeadings() {
        XCTAssertEqual(GlobalStatus.waiting.description, "等待恢复")
        XCTAssertEqual(GlobalStatus.error.description, "需要处理")
    }

    func testWaitingIsVisibleWhileAnotherSourceRuns() {
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: true, running: true), .running)
    }
    func testErrorIsNotReportedAsCompleted() {
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: true, paused: false, waiting: false, running: false), .error)
    }
    func testMissingPhotosPermissionNeedsAttentionInsteadOfWaiting() {
        // Only the user can grant Photos access, so it must not hide behind the waiting symbol.
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: true, running: true, authorized: false), .error)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: true, waiting: false, running: false, authorized: false), .error)
        // Without configured sources nothing can be synced yet, so the plain symbol stays.
        XCTAssertEqual(GlobalStatus.resolve(configured: false, error: false, paused: false, waiting: false, running: false, authorized: false), .error)
    }
    func testSymbolsExistOnHostOS() {
        for status in GlobalStatus.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.description))
        }
    }
    func testLoggerReportsAppendFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let failure = expectation(description: "visible failure")
        let logger = try RunLogger(directory: directory) { _ in failure.fulfill() }
        try FileManager.default.removeItem(at: directory)
        logger.log(["result": "test"])
        await fulfillment(of: [failure], timeout: 2)
    }
    func testPriorityAndSymbols() {
        XCTAssertEqual(GlobalStatus.resolve(configured: false, error: true, paused: true, waiting: true, running: true), .error)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: true, waiting: true, running: true), .paused)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: false, running: true), .running)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: false, running: false), .completed)
        XCTAssertEqual(Set(GlobalStatus.allCases.map(\.symbol)).count, 6)
    }
}

final class RuntimeIntegrationTests: XCTestCase {
    func testEnableSourceReusesIdentityAndSuccessfulHistory() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let runtime = SyncRuntime(store: fixture.store, engine: fixture.engine,
                                  now: { Date() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()
        await runtime.tick(force: true)
        await runtime.waitForRound()
        let countBefore = await fixture.photos.createCount
        XCTAssertEqual(countBefore, 1)
        try await runtime.disable(fixture.sourceIDs[0])
        for _ in 0..<2 {
            try await runtime.enable(fixture.sourceIDs[0])
            await runtime.waitForRound()
        }
        let state = await runtime.current()
        let countAfter = await fixture.photos.createCount
        XCTAssertEqual(state.sources.map(\.id), fixture.sourceIDs)
        XCTAssertTrue(state.sources[0].enabled)
        XCTAssertEqual(state.snapshot.summary?.imported, 1)
        XCTAssertEqual(countAfter, countBefore)
    }

    func testEnableUnavailableSourceKeepsItDisabledAndCanRecover() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let runtime = SyncRuntime(store: fixture.store, engine: fixture.engine,
                                  now: { Date() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()
        try await runtime.disable(fixture.sourceIDs[0])
        let directory = fixture.directories[0]
        let offline = directory.appendingPathExtension("offline")
        try FileManager.default.moveItem(at: directory, to: offline)
        do {
            try await runtime.enable(fixture.sourceIDs[0])
            XCTFail("An unavailable source must fail validation")
        } catch {}
        let failedState = await runtime.current()
        XCTAssertFalse(failedState.sources[0].enabled)
        let createsWhileUnavailable = await fixture.photos.createCount
        XCTAssertEqual(createsWhileUnavailable, 0)
        try FileManager.default.moveItem(at: offline, to: directory)
        try await runtime.enable(fixture.sourceIDs[0])
        await runtime.waitForRound()
        let recovered = await runtime.current()
        XCTAssertTrue(recovered.sources[0].enabled)
        XCTAssertEqual(recovered.snapshot.summary?.imported, 1)
    }

    func testEnableRemovedSourceDoesNotRestoreConfiguration() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let runtime = SyncRuntime(store: fixture.store, engine: fixture.engine,
                                  now: { Date() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()
        try await runtime.removeSource(fixture.sourceIDs[0])
        do {
            try await runtime.enable(fixture.sourceIDs[0])
            XCTFail("Enable must not re-add a removed source")
        } catch RuntimeSourceOperationError.sourceRemoved {
        }
        let state = await runtime.current()
        XCTAssertTrue(state.sources.isEmpty)
        let removed = try await fixture.store.isSourceRemoved(id: fixture.sourceIDs[0])
        XCTAssertTrue(removed)
        let creates = await fixture.photos.createCount
        XCTAssertEqual(creates, 0)
    }

    func testEnableWhilePausedWaitsUntilResumeBeforeSubmitting() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let runtime = SyncRuntime(store: fixture.store, engine: fixture.engine,
                                  now: { Date() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()
        try await runtime.disable(fixture.sourceIDs[0])
        await runtime.pause()
        try await runtime.enable(fixture.sourceIDs[0])
        await runtime.waitForRound()
        let paused = await runtime.current()
        XCTAssertTrue(paused.sources[0].enabled)
        XCTAssertTrue(paused.snapshot.isPaused)
        let whilePaused = await fixture.photos.createCount
        XCTAssertEqual(whilePaused, 0)
        await runtime.resume()
        await runtime.waitForRound()
        let resumed = await runtime.current()
        XCTAssertEqual(resumed.snapshot.summary?.imported, 1)
    }

    func testDueFileRetryRunsAtFiveSeconds() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let clock = RuntimeClock()
        let engine = SyncEngine(store: fixture.store, photos: fixture.photos, now: { clock.read() })
        let runtime = SyncRuntime(store: fixture.store, engine: engine,
                                  now: { clock.read() }, authorized: { true })
        await fixture.photos.setCreationError(.definitelyNotCommitted("temporary"))
        try await runtime.prepareInjectedRuntime()

        await runtime.tick(force: true)
        await runtime.waitForRound()

        await fixture.photos.setCreationError(nil)
        clock.set(4)
        await runtime.tick()
        await runtime.waitForRound()
        let beforeDue = await fixture.photos.createCount
        XCTAssertEqual(beforeDue, 1)

        clock.set(5)
        await runtime.tick()
        await runtime.waitForRound()
        let afterDue = await fixture.photos.createCount
        XCTAssertEqual(afterDue, 2)
        let state = await runtime.current()
        XCTAssertEqual(state.snapshot.summary?.imported, 1)
        XCTAssertEqual(state.nextScan, Date(timeIntervalSince1970: 1_800))
    }

    func testDueFileRetryUsesPersistedBackoffWithoutOverlappingAtTheSameDeadline() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let clock = RuntimeClock()
        let engine = SyncEngine(store: fixture.store, photos: fixture.photos, now: { clock.read() })
        let runtime = SyncRuntime(store: fixture.store, engine: engine,
                                  now: { clock.read() }, authorized: { true })
        await fixture.photos.setCreationError(.definitelyNotCommitted("temporary"))
        try await runtime.prepareInjectedRuntime()

        await runtime.tick(force: true)
        await runtime.waitForRound()
        for (time, expectedCreates) in [(4.0, 1), (5.0, 2), (5.0, 2), (19.0, 2),
                                        (20.0, 3), (49.0, 3), (50.0, 4), (109.0, 4), (110.0, 5)] {
            clock.set(time)
            await runtime.tick()
            await runtime.waitForRound()
            let creates = await fixture.photos.createCount
            XCTAssertEqual(creates, expectedCreates, "unexpected create count at t=\(time)")
        }
    }

    func testPausedDueFileRetryWaitsUntilResume() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let clock = RuntimeClock()
        let engine = SyncEngine(store: fixture.store, photos: fixture.photos, now: { clock.read() })
        let runtime = SyncRuntime(store: fixture.store, engine: engine,
                                  now: { clock.read() }, authorized: { true })
        await fixture.photos.setCreationError(.definitelyNotCommitted("temporary"))
        try await runtime.prepareInjectedRuntime()
        await runtime.tick(force: true)
        await runtime.waitForRound()

        await fixture.photos.setCreationError(nil)
        await runtime.pause()
        clock.set(5)
        await runtime.tick()
        await runtime.waitForRound()
        let whilePaused = await fixture.photos.createCount
        XCTAssertEqual(whilePaused, 1)

        await runtime.resume()
        await runtime.waitForRound()
        let afterResume = await fixture.photos.createCount
        XCTAssertEqual(afterResume, 2)
    }

    func testDueFileRetryWaitsForFutureUnavailableSourceRecovery() async throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: directory)
        let reader = RuntimeBlockedRetryDirectory(mode: .unavailable)
        let clock = RuntimeClock()
        let engine = SyncEngine(store: store, photos: RuntimePhotos(), directory: { _ in reader }, now: { clock.read() })
        let runtime = SyncRuntime(store: store, engine: engine, now: { clock.read() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()

        await runtime.tick(force: true)
        await runtime.waitForRound()
        let retry = try await store.save(runtimeRetryFile(sourceID: sourceID, directory: directory), decision: .importNew)
        try await store.recordRetry(fileID: retry, attemptID: nil, nextRetry: clock.read(),
                                    error: "temporary", definitelyNotCommitted: true)

        clock.set(1)
        await runtime.tick()
        await runtime.waitForRound()
        let beforeSourceRecovery = await reader.calls
        XCTAssertEqual(beforeSourceRecovery, 1)

        clock.set(5)
        await runtime.tick()
        await runtime.waitForRound()
        let atSourceRecovery = await reader.calls
        XCTAssertEqual(atSourceRecovery, 2)
    }

    func testDueFileRetryWaitsForFutureDeferredReadRecovery() async throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: directory)
        let reader = RuntimeBlockedRetryDirectory(mode: .deferred)
        let clock = RuntimeClock()
        let engine = SyncEngine(store: store, photos: RuntimePhotos(), directory: { _ in reader }, now: { clock.read() })
        let runtime = SyncRuntime(store: store, engine: engine, now: { clock.read() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()

        await runtime.tick(force: true)
        await runtime.waitForRound()
        let retry = try await store.save(runtimeRetryFile(sourceID: sourceID, directory: directory), decision: .importNew)
        try await store.recordRetry(fileID: retry, attemptID: nil, nextRetry: clock.read(),
                                    error: "temporary", definitelyNotCommitted: true)

        clock.set(1)
        await runtime.tick()
        await runtime.waitForRound()
        let beforeDeferredRecovery = await reader.calls
        XCTAssertEqual(beforeDeferredRecovery, 1)

        clock.set(5)
        await runtime.tick()
        await runtime.waitForRound()
        let atDeferredRecovery = await reader.calls
        XCTAssertEqual(atDeferredRecovery, 2)
    }

    func testLongRoundDropsScheduledTickWithoutCatchup() async throws {
        let root = try temporaryDirectory()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let folder = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await store.registerSource(url: folder)
        let reader = HeldRuntimeDirectory()
        let engine = SyncEngine(store: store, photos: RuntimePhotos(), directory: { _ in reader })
        let clock = RuntimeClock()
        let runtime = SyncRuntime(store: store, engine: engine, now: { clock.read() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()
        await runtime.tick(force: true)
        while await reader.calls == 0 { await Task.yield() }
        clock.set(1800)
        await runtime.tick()
        clock.set(2400)
        await reader.release()
        await runtime.waitForRound()
        await runtime.tick()
        let state = await runtime.current()
        XCTAssertEqual(state.nextScan, Date(timeIntervalSince1970: 3600))
        let calls = await reader.calls
        XCTAssertEqual(calls, 1)
        await runtime.stop()
        await reader.release()
    }

    func testDisabledPendingHistoryIsNotActionable() async throws {
        let root = try temporaryDirectory()
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let id = try await store.registerSource(url: first)
        _ = try await store.registerSource(url: second)
        let file = SourceFile(sourceID: id, relativePath: "pending.jpg", url: first.appendingPathComponent("pending.jpg"),
                              stamp: FileStamp(size: 1, modifiedNanoseconds: 1),
                              metadata: MediaMetadata(filename: "pending.jpg", kind: .image, captureSecond: nil, rawCaptureTime: nil, rawCaptureOffset: nil, make: nil, model: nil, width: nil, height: nil, duration: nil))
        _ = try await store.save(file, decision: .importNew)
        let engine = SyncEngine(store: store, photos: RuntimePhotos())
        let runtime = SyncRuntime(store: store, engine: engine, now: { Date() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()
        try await runtime.disable(id)
        await runtime.tick(force: true)
        await runtime.waitForRound()
        let state = await runtime.current()
        XCTAssertEqual(state.snapshot.summary?.pending, 0)
        let historical = try await store.countFiles(state: .pending)
        XCTAssertEqual(historical, 1)
        XCTAssertFalse(state.snapshot.activeWork)
    }
}

private final class RuntimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) }
    func set(_ value: TimeInterval) { lock.lock(); defer { lock.unlock() }; seconds = value }
}

private func runtimeRetryFile(sourceID: UUID, directory: URL) -> SourceFile {
    let url = directory.appendingPathComponent("retry.jpg")
    return SourceFile(
        sourceID: sourceID,
        relativePath: "retry.jpg",
        url: url,
        stamp: FileStamp(size: 1, modifiedNanoseconds: 1),
        metadata: media("retry.jpg")
    )
}

private enum RuntimeRetryBlock: Sendable {
    case unavailable
    case deferred
}

private actor RuntimeBlockedRetryDirectory: DirectoryReading {
    let mode: RuntimeRetryBlock
    private(set) var calls = 0

    init(mode: RuntimeRetryBlock) { self.mode = mode }

    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        calls += 1
        switch mode {
        case .unavailable: throw CocoaError(.fileReadNoSuchFile)
        case .deferred: throw ReadExecutorError.sourceBusy
        }
    }

    func stamp(of file: URL) async throws -> FileStamp {
        FileStamp(size: 1, modifiedNanoseconds: 1)
    }
}

private actor HeldRuntimeDirectory: DirectoryReading {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return []
    }
    func stamp(of file: URL) async throws -> FileStamp { FileStamp(size: 1, modifiedNanoseconds: 1) }
    func release() { continuation?.resume(); continuation = nil }
}
private struct RuntimePhotos: PhotosGateway {
    func loadCandidates() async throws -> [MatchCandidate] { [] }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        PhotosCandidateSnapshot(generation: 0, candidates: [])
    }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        throw PhotoKitGatewayError.definitelyNotCommitted("Test never imports")
    }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}

extension RuntimeIntegrationTests {
    func testImageAndSidecarDoNotScheduleRecoveryRounds() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        try Data("sidecar".utf8).write(to: fixture.directories[0].appendingPathComponent("same.xmp"))
        let clock = RuntimeClock()
        let runtime = SyncRuntime(store: fixture.store, engine: fixture.engine, now: { clock.read() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()
        await runtime.tick(force: true)
        await runtime.waitForRound()
        for second in [5.0, 15.0, 30.0, 60.0] {
            clock.set(second)
            await runtime.tick()
            await runtime.waitForRound()
        }
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: fixture.databaseURL), 1)
        let state = await runtime.current()
        XCTAssertTrue(state.snapshot.waitingSources.isEmpty)
        XCTAssertEqual(state.snapshot.summary?.skipped, 0)
        XCTAssertEqual(state.snapshot.latestScan.checkedCandidates, 1)
        XCTAssertEqual(state.snapshot.summary?.imported, 1)
    }

    func testFailureAndRecoveryNotificationTransitionsAreDeduplicated() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let transitions = NotificationTransitions()
        let reader = FailingNotificationDirectory()
        let engine = SyncEngine(store: fixture.store, photos: fixture.photos, directory: { _ in reader },
                                notify: { _, recovered in transitions.append(recovered) })
        await engine.scan(sourceIDs: fixture.sourceIDs)
        await engine.scan(sourceIDs: fixture.sourceIDs)
        XCTAssertEqual(transitions.read(), [false])
        await reader.recover()
        await engine.scan(sourceIDs: fixture.sourceIDs)
        await engine.scan(sourceIDs: fixture.sourceIDs)
        XCTAssertEqual(transitions.read(), [false, true])
    }

    func testFileIssueDoesNotScheduleSourceRecoveryBackoff() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let sourceID = try await store.registerSource(url: source)
        let reader = RuntimeFileIssueDirectory(fileURL: source.appendingPathComponent("broken.jpg"))
        let engine = SyncEngine(
            store: store,
            photos: RuntimePhotos(),
            directory: { _ in reader },
            metadata: { _ in RuntimeUnreadableMetadata() }
        )
        let clock = RuntimeClock()
        let runtime = SyncRuntime(store: store, engine: engine, now: { clock.read() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()

        await runtime.tick(force: true)
        await runtime.waitForRound()
        let firstCalls = await reader.calls
        // One scheduled traversal plus one bounded root verification after metadata fails.
        XCTAssertEqual(firstCalls, 2)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: root.appendingPathComponent("state.sqlite")), 1)
        let firstState = await runtime.current()
        XCTAssertEqual(firstState.snapshot.waitingSources[sourceID]?.kind, .file)

        // A readable source with one bad file must not be quarantined on the source recovery curve.
        clock.set(5)
        await runtime.tick()
        await runtime.waitForRound()
        let afterEarlyTick = await reader.calls
        XCTAssertEqual(afterEarlyTick, 2, "No traversal or root probe before the ordinary scan deadline")
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: root.appendingPathComponent("state.sqlite")), 1)

        clock.set(1_800)
        await runtime.tick()
        await runtime.waitForRound()
        let afterRegularTick = await reader.calls
        XCTAssertEqual(afterRegularTick, 4, "Each scheduled bad-file scan verifies its still-readable root")
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: root.appendingPathComponent("state.sqlite")), 2)
    }

    func testDirectoryRecoveryToFileIssueClearsSourceBackoffWithoutPrematureRecoveryNotification() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let sourceID = fixture.sourceIDs[0]
        let brokenURL = fixture.directories[0].appendingPathComponent("broken.jpg")
        try FileManager.default.copyItem(at: fixture.directories[0].appendingPathComponent("same.jpg"), to: brokenURL)
        let reader = RuntimeRecoveryThenBrokenDirectory(fileURL: brokenURL)
        let metadata = RuntimeRecoveringMetadata()
        let transitions = NotificationTransitions()
        let clock = RuntimeClock()
        let engine = SyncEngine(
            store: fixture.store,
            photos: fixture.photos,
            directory: { _ in reader },
            metadata: { _ in metadata },
            notify: { _, recovered in transitions.append(recovered) },
            now: { clock.read() }
        )
        let runtime = SyncRuntime(store: fixture.store, engine: engine, now: { clock.read() }, authorized: { true })
        try await runtime.prepareInjectedRuntime()

        await runtime.tick(force: true)
        await runtime.waitForRound()
        let unavailable = await runtime.current()
        XCTAssertEqual(unavailable.snapshot.waitingSources[sourceID]?.kind, .sourceAvailability)
        XCTAssertEqual(transitions.read(), [false])

        clock.set(5)
        await runtime.tick()
        await runtime.waitForRound()
        let fileFailure = await runtime.current()
        XCTAssertEqual(fileFailure.snapshot.waitingSources[sourceID]?.kind, .file)
        XCTAssertEqual(fileFailure.snapshot.sourceFileIssueCounts[sourceID], 1)
        XCTAssertEqual(transitions.read(), [false])

        clock.set(10)
        await runtime.tick()
        await runtime.waitForRound()
        let callsAfterBackoffClears = await reader.calls
        // Initial root failure, recovery traversal, then the bad file's healthy-root probe.
        XCTAssertEqual(callsAfterBackoffClears, 3, "A file issue must not schedule another early source round")
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM scan_run", at: fixture.databaseURL), 2)

        await metadata.recover()
        clock.set(1_800)
        await runtime.tick()
        await runtime.waitForRound()
        let recovered = await runtime.current()
        XCTAssertNil(recovered.snapshot.waitingSources[sourceID])
        XCTAssertNil(recovered.snapshot.sourceFileIssueCounts[sourceID])
        XCTAssertEqual(transitions.read(), [false, true])
    }

    func testLoggerBootstrapFailureIsNonBlockingAndDoesNotBecomeGlobalError() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let logPath = fixture.directories[0].appendingPathComponent("logger-file")
        try Data("not a directory".utf8).write(to: logPath)
        let runtime = SyncRuntime(
            store: fixture.store,
            engine: fixture.engine,
            logsURL: logPath,
            databaseURL: fixture.databaseURL,
            now: { Date(timeIntervalSince1970: 0) },
            authorized: { false }
        )

        await runtime.bootstrap()

        let state = await runtime.current()
        XCTAssertNil(state.message)
        XCTAssertEqual(state.warning, "日志文件写入失败，同步仍在继续，但排查信息可能不完整。")
        XCTAssertNotNil(state.warningDetail)
        XCTAssertEqual(
            GlobalStatus.resolve(
                configured: true,
                error: state.message != nil,
                paused: false,
                waiting: false,
                running: false,
                authorized: true
            ),
            .completed
        )
        // A logger warning remains visible in the detail area but is not a global blocker. Before
        // any scan has completed, the pure projection therefore waits for a scan instead of
        // showing either an error or completion.
        let projection = SyncStatusPresentation(snapshot: state.snapshot).globalStatus(
            enabledSourceIDs: Set(fixture.sourceIDs),
            authorized: true,
            hasBlockingError: state.message != nil || state.snapshot.blockingError != nil ||
                state.snapshot.summaryError != nil
        )
        XCTAssertEqual(projection, .waiting)
    }
}

private final class NotificationTransitions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func append(_ value: Bool) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func read() -> [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}
private actor FailingNotificationDirectory: DirectoryReading {
    var failed = true
    func recover() { failed = false }
    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        if failed { throw FixtureError.unavailable("source offline") }
        return []
    }
    func stamp(of file: URL) async throws -> FileStamp { throw FixtureError.unavailable("unused") }
}

private actor RuntimeFileIssueDirectory: DirectoryReading {
    let fileURL: URL
    private(set) var calls = 0

    init(fileURL: URL) { self.fileURL = fileURL }

    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        calls += 1
        return [DirectoryEntry(url: fileURL, isDirectory: false, stamp: FileStamp(size: 1, modifiedNanoseconds: 1))]
    }

    func stamp(of file: URL) async throws -> FileStamp {
        FileStamp(size: 1, modifiedNanoseconds: 1)
    }
}

private struct RuntimeUnreadableMetadata: MetadataReading {
    func read(url: URL, filename: String) async throws -> MediaMetadata {
        throw MetadataError.unreadable
    }
}

private actor RuntimeRecoveryThenBrokenDirectory: DirectoryReading {
    let fileURL: URL
    private(set) var calls = 0

    init(fileURL: URL) { self.fileURL = fileURL }

    func entries(in directory: URL) async throws -> [DirectoryEntry] {
        calls += 1
        if calls == 1 { throw CocoaError(.fileReadNoSuchFile) }
        return [DirectoryEntry(url: fileURL, isDirectory: false, stamp: nil)]
    }

    func stamp(of file: URL) async throws -> FileStamp {
        FileStamp(size: 12, modifiedNanoseconds: 1)
    }
}

private actor RuntimeRecoveringMetadata: MetadataReading {
    private var unreadable = true

    func recover() { unreadable = false }

    func read(url: URL, filename: String) async throws -> MediaMetadata {
        if unreadable { throw MetadataError.unreadable }
        return try await MetadataReader().read(url: url, filename: filename)
    }
}
