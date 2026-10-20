import XCTest
@testable import PhotoSyncCore

@MainActor
final class AppModelTests: XCTestCase {
    func testUnmountedMenuBarDrawingKeepsBlockingErrorsVisible() async throws {
        let fixture = try await makeAppModelFixture()
        let model = fixture.model
        let source = try XCTUnwrap(model.state.sources.first)
        let message = "所在磁盘或网络共享 /Volumes/Example 未挂载；挂载后会自动继续同步。"
        model.state.snapshot.waitingSources[source.id] = SourceIssue(summary: message, detail: "synthetic")
        model.state.snapshot.sourceIssueDetails[source.id] = [SourceIssueDetail(id: "root", kind: .sourceAvailability,
            path: source.url.path, summary: message, stage: nil, detail: "synthetic")]
        XCTAssertEqual(model.status, .waiting)
        XCTAssertTrue(model.statusIconIsDimmed)
        model.state.authorized = false
        XCTAssertEqual(model.status, .error)
        XCTAssertFalse(model.statusIconIsDimmed)
        XCTAssertEqual(model.statusDescription, "同步异常")
        model.state.authorized = true
        model.state.snapshot.sourceIssueDetails = [:]
        XCTAssertFalse(model.statusIconIsDimmed, "A recovered root must immediately return to the normal waiting mark")
        model.state.sources = []
        XCTAssertEqual(model.status, .unconfigured)
        XCTAssertFalse(model.statusIconIsDimmed)
    }

    // Catches a regression where the menu action stops forwarding a scan to the injected runtime.
    func testScanImportsAnEnabledSourceThroughInjectedRuntime() async throws {
        let fixture = try await makeAppModelFixture()

        XCTAssertFalse(fixture.model.allowsSystemIntegrations)
        XCTAssertTrue(fixture.model.ready)

        fixture.model.scan()

        let importedByAction = try await waitForImportedFile(in: fixture)
        let importCount = await fixture.photos.createCount
        XCTAssertTrue(importedByAction)
        XCTAssertEqual(importCount, 1)
        let imported = try await fixture.store.file(
            sourceID: fixture.sourceID,
            relativePath: "same.jpg"
        )
        XCTAssertEqual(imported?.state, .imported)
    }

    // Catches a regression where an authorization action reaches system APIs instead of the
    // supplied runtime, or fails to resume the real queued scan after authorization is granted.
    func testAuthorizeResumesScanThroughInjectedRuntime() async throws {
        let authorization = AuthorizationProbe()
        let fixture = try await makeAppModelFixture(
            authorized: { authorization.isGranted },
            requestAuthorization: { authorization.grant() }
        )
        XCTAssertFalse(fixture.model.state.authorized)

        fixture.model.authorize()

        let importedByAuthorization = try await waitForImportedFile(in: fixture)
        XCTAssertTrue(importedByAuthorization)
        XCTAssertEqual(authorization.requestCount, 1)
        let runtimeState = await fixture.runtime.current()
        let imported = try await fixture.store.file(sourceID: fixture.sourceID, relativePath: "same.jpg")
        let importCount = await fixture.photos.createCount
        XCTAssertTrue(runtimeState.authorized)
        XCTAssertEqual(imported?.state, .imported)
        XCTAssertEqual(importCount, 1)
    }

    // Catches a missing source-control action or a re-registration that changes the source ID
    // and loses the durable successful-import history.
    func testDisableThenEnableKeepsSourceIdentityAndSuccessfulHistory() async throws {
        let fixture = try await makeAppModelFixture()
        try await importInitialSource(from: fixture)

        fixture.model.disable(fixture.sourceID)
        let disabled = try await engineEventually {
            try await fixture.store.sources().first?.enabled == false
        }
        XCTAssertTrue(disabled)
        let disableFinished = await waitForModelOperation(fixture.model, sourceID: fixture.sourceID)
        XCTAssertTrue(disableFinished)
        let disabledSources = try await fixture.store.sources()
        XCTAssertEqual(disabledSources.map(\.id), [fixture.sourceID])
        XCTAssertFalse(disabledSources.first?.enabled ?? true)

        fixture.model.enable(fixture.sourceID)
        let enabled = try await engineEventually {
            try await fixture.store.sources().first?.enabled == true
        }
        XCTAssertTrue(enabled)
        let enableFinished = await waitForModelOperation(fixture.model, sourceID: fixture.sourceID)
        XCTAssertTrue(enableFinished)
        let enabledSources = try await fixture.store.sources()
        let summary = try await fixture.store.activeSourceSummary()
        XCTAssertEqual(enabledSources.map(\.id), [fixture.sourceID])
        XCTAssertEqual(summary, SyncStatusSummary(imported: 1))
    }

    // Catches removal that erases the import audit trail, or an AppModel action that recreates a
    // removed source when a stale view asks it to enable the old ID.
    func testRemovedSourceKeepsHistoryAndCannotBeEnabledAgain() async throws {
        let fixture = try await makeAppModelFixture()
        try await importInitialSource(from: fixture)

        fixture.model.remove(fixture.sourceID)
        let removed = try await engineEventually {
            try await fixture.store.sources().isEmpty
        }
        XCTAssertTrue(removed)
        let removalFinished = await waitForModelOperation(fixture.model, sourceID: fixture.sourceID)
        XCTAssertTrue(removalFinished)
        let retainedAfterRemoval = try await fixture.store.activeSourceSummary()
        XCTAssertEqual(retainedAfterRemoval, SyncStatusSummary(retainedImported: 1))

        fixture.model.enable(fixture.sourceID)
        let rejected = await waitForModelOperation(fixture.model, sourceID: fixture.sourceID)
        XCTAssertTrue(rejected)
        XCTAssertFalse(fixture.model.changingSources.contains(fixture.sourceID))
        XCTAssertEqual(fixture.model.error, "该来源已移除，请重新添加来源目录。")
        let sourcesAfterRejectedEnable = try await fixture.store.sources()
        let retainedAfterRejectedEnable = try await fixture.store.activeSourceSummary()
        XCTAssertTrue(sourcesAfterRejectedEnable.isEmpty)
        XCTAssertEqual(retainedAfterRejectedEnable, SyncStatusSummary(retainedImported: 1))
    }

    // Catches a boot-state regression where a source action can start before the runtime has
    // supplied an initial state. `changingSources` changes synchronously before any task begins.
    func testSourceEnableIsIgnoredUntilRuntimeIsReady() async throws {
        let fixture = try await makeAppModelFixture()
        try await fixture.runtime.disable(fixture.sourceID)
        fixture.model.state = await fixture.runtime.current()
        fixture.model.ready = false

        fixture.model.enable(fixture.sourceID)

        XCTAssertFalse(fixture.model.changingSources.contains(fixture.sourceID))
        let sources = try await fixture.store.sources()
        XCTAssertFalse(sources.first?.enabled ?? true)
    }

    // Catches the guard being cleared by a second same-source action while the first validation
    // is still in flight. The store/runtime remain real; only directory validation is held.
    func testSameSourceEnableStaysMutuallyExclusiveUntilItsValidationCompletes() async throws {
        let root = try temporaryDirectory()
        let sourceURL = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let validation = BlockingSourceValidation()
        let store = try SyncStore(
            url: root.appendingPathComponent("state.sqlite"),
            readExecutor: ReadExecutor(maxConcurrentOperations: 2, defaultTimeout: .seconds(5)),
            validateSource: { url in try validation.validate(url) }
        )
        let sourceID = try await store.registerSource(url: sourceURL)
        try await store.disableSource(id: sourceID)
        let engine = SyncEngine(store: store, photos: FakePhotosGateway())
        let runtime = SyncRuntime(
            store: store,
            engine: engine,
            now: { Date() },
            authorized: { true },
            requestAuthorization: { true },
            notificationsEnabled: { false }
        )
        try await runtime.prepareInjectedRuntime()
        let model = AppModel(runtime: runtime, initialState: await runtime.current())
        let validationsBeforeEnable = validation.count
        validation.blockNextValidation()
        addTeardownBlock { [runtime, root] in
            validation.releaseAll()
            await runtime.stop()
            await runtime.waitForRound()
            try? FileManager.default.removeItem(at: root)
        }

        model.enable(sourceID)
        XCTAssertTrue(model.changingSources.contains(sourceID))
        let firstEntered = await validation.waitForEntry(timeout: .seconds(2))
        XCTAssertTrue(firstEntered)
        model.enable(sourceID)
        let secondEntered = await validation.waitForEntry(timeout: .milliseconds(100))
        XCTAssertFalse(secondEntered)
        validation.releaseAll()

        let finished = await waitForModelOperation(model, sourceID: sourceID)
        XCTAssertTrue(finished)
        XCTAssertEqual(validation.count, validationsBeforeEnable + 1)
        let enabledSource = try await store.sources().first
        XCTAssertTrue(enabledSource?.enabled ?? false)
    }

    // Catches a pause control that only changes its label: a forced scan while paused must not
    // submit, and the same queued source must submit once the model resumes its real runtime.
    func testPauseBlocksSubmissionUntilResume() async throws {
        let fixture = try await makeAppModelFixture()

        fixture.model.togglePause()
        let paused = await waitForPauseState(in: fixture.model, expected: true)
        XCTAssertTrue(paused)
        // The scan forwarding itself has a separate positive test. Await the real runtime
        // here so zero submissions means the paused scan completed, not merely that it was slow.
        await fixture.runtime.tick(force: true)
        await fixture.runtime.waitForRound()
        let whilePaused = await fixture.photos.createCount
        XCTAssertEqual(whilePaused, 0)

        fixture.model.togglePause()
        let resumedAndImported = try await waitForImportedFile(in: fixture)
        let importCount = await fixture.photos.createCount
        XCTAssertTrue(resumedAndImported)
        XCTAssertFalse(fixture.model.state.snapshot.isPaused)
        XCTAssertEqual(importCount, 1)
    }

    // Catches headline text leaking a raw system failure rather than reserving it for hover help.
    func testBlockingHeadlineKeepsRawFailureDetailOutOfVisibleText() async throws {
        let fixture = try await makeAppModelFixture()
        fixture.model.state.snapshot.blockingSummary = "本地同步数据库暂时不可用，正在等待恢复。"
        fixture.model.state.snapshot.blockingError = "SQLite error 14: unable to open database file"

        XCTAssertEqual(fixture.model.syncDetail, "本地同步数据库暂时不可用，正在等待恢复。")
        XCTAssertEqual(fixture.model.syncDetailHelp, "SQLite error 14: unable to open database file")
    }

    private func makeAppModelFixture(
        authorized: @escaping @Sendable () -> Bool = { true },
        requestAuthorization: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> AppModelFixture {
        let engineFixture = try await makeEngineFixture(sourceCount: 1)
        let runtime = SyncRuntime(
            store: engineFixture.store,
            engine: engineFixture.engine,
            now: { Date() },
            authorized: authorized,
            requestAuthorization: requestAuthorization,
            notificationsEnabled: { false }
        )
        try await runtime.prepareInjectedRuntime()
        let model = AppModel(runtime: runtime, initialState: await runtime.current())
        let root = engineFixture.databaseURL.deletingLastPathComponent()
        addTeardownBlock { [runtime, root] in
            await runtime.stop()
            await runtime.waitForRound()
            try? FileManager.default.removeItem(at: root)
        }
        return AppModelFixture(
            model: model,
            runtime: runtime,
            store: engineFixture.store,
            photos: engineFixture.photos,
            sourceID: engineFixture.sourceIDs[0]
        )
    }

    private func importInitialSource(from fixture: AppModelFixture) async throws {
        fixture.model.scan()
        let imported = try await waitForImportedFile(in: fixture)
        let importCount = await fixture.photos.createCount
        XCTAssertTrue(imported)
        let stored = try await fixture.store.file(sourceID: fixture.sourceID, relativePath: "same.jpg")
        XCTAssertEqual(stored?.state, .imported)
        XCTAssertEqual(importCount, 1)
    }

    private func waitForImportedFile(in fixture: AppModelFixture) async throws -> Bool {
        try await engineEventually {
            guard let stored = try await fixture.store.file(
                sourceID: fixture.sourceID,
                relativePath: "same.jpg"
            ) else {
                return false
            }
            return stored.state == .imported
        }
    }

    private func waitForModelOperation(_ model: AppModel, sourceID: UUID) async -> Bool {
        for _ in 0..<500 {
            if !model.changingSources.contains(sourceID) { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return !model.changingSources.contains(sourceID)
    }

    private func waitForPauseState(in model: AppModel, expected: Bool) async -> Bool {
        for _ in 0..<500 {
            if model.state.snapshot.isPaused == expected { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return model.state.snapshot.isPaused == expected
    }


}

private struct AppModelFixture {
    let model: AppModel
    let runtime: SyncRuntime
    let store: SyncStore
    let photos: FakePhotosGateway
    let sourceID: UUID
}

private final class AuthorizationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    private var requests = 0

    var isGranted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func grant() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        granted = true
        return true
    }
}

private final class BlockingSourceValidation: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private let entered = DispatchSemaphore(value: 0)
    private var blocksValidation = false
    private var validations = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return validations
    }

    func blockNextValidation() {
        lock.lock()
        blocksValidation = true
        lock.unlock()
    }

    func validate(_ url: URL) throws -> URL {
        lock.lock()
        validations += 1
        let shouldBlock = blocksValidation
        if shouldBlock {
            lock.unlock()
            entered.signal()
            release.wait()
        } else {
            lock.unlock()
        }
        return try SourceRegistry.normalizedURL(url)
    }

    func waitForEntry(timeout: DispatchTimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.entered.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    func releaseAll() {
        for _ in 0..<4 { release.signal() }
    }
}
