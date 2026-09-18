import XCTest
import AppKit
@testable import PhotoSyncCore

final class GlobalStatusTests: XCTestCase {
    func testWaitingIsVisibleWhileAnotherSourceRuns() {
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: true, running: true), .waiting)
    }
    func testErrorIsNotReportedAsCompleted() {
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: true, paused: false, waiting: false, running: false), .error)
    }
    func testMissingPhotosPermissionNeedsAttentionInsteadOfWaiting() {
        // Only the user can grant Photos access, so it must not hide behind the waiting symbol.
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: true, running: true, authorized: false), .error)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: true, waiting: false, running: false, authorized: false), .error)
        // Without configured sources nothing can be synced yet, so the plain symbol stays.
        XCTAssertEqual(GlobalStatus.resolve(configured: false, error: false, paused: false, waiting: false, running: false, authorized: false), .unconfigured)
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
        XCTAssertEqual(GlobalStatus.resolve(configured: false, error: true, paused: true, waiting: true, running: true), .unconfigured)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: true, waiting: true, running: true), .paused)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: false, running: true), .running)
        XCTAssertEqual(GlobalStatus.resolve(configured: true, error: false, paused: false, waiting: false, running: false), .completed)
        XCTAssertEqual(Set(GlobalStatus.allCases.map(\.symbol)).count, 6)
    }
}

final class RuntimeIntegrationTests: XCTestCase {
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
    func create(fileURL: URL, kind: MediaKind, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
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
        XCTAssertEqual(firstCalls, 1)
        let firstState = await runtime.current()
        XCTAssertNotNil(firstState.snapshot.waitingSources[sourceID])

        // A readable source with one bad file must not be quarantined on the source recovery curve.
        clock.set(5)
        await runtime.tick()
        await runtime.waitForRound()
        let afterEarlyTick = await reader.calls
        XCTAssertEqual(afterEarlyTick, 1)

        clock.set(1_800)
        await runtime.tick()
        await runtime.waitForRound()
        let afterRegularTick = await reader.calls
        XCTAssertEqual(afterRegularTick, 2)
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
