import XCTest
@testable import PhotoSyncCore

final class LivePhotoResourceTests: XCTestCase {
    func testPhysicalReadTraceSeparatesDeliveryAndCallbackWaitWithoutChangingBytes() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = ResourceTraceRows(), clock = ResourceTraceClock(), logger = try RunLogger(directory: root.appendingPathComponent("logs"))
        let diagnostics = IndexDiagnostics(sink: { rows.append($0); logger.log($0) }, monotonic: { clock.now })
        let ref = LivePhotoResourceRef.photos(contextID: UUID(), assetID: "private-asset", resourceKey: "private-name.mov", revision: "private-revision")
        let reader = LivePhotoRawResourceReader(requester: TimedResourceRequester(clock: clock), storage: .init(root: root.appendingPathComponent("raw")))
        let budget = LivePhotoResourceBudget()
        var lease: LivePhotoResourceLease? = try await reader.read(resource: ref, purpose: .inventory, budget: budget,
            trace: diagnostics.livePhotoResourceTrace(ref, purpose: .inventory))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(lease).url), Data([1, 2, 3, 4, 5]))
        let terminal = rows.values.filter { $0["event"] == "terminal" }
        XCTAssertEqual(terminal.count, 1, "Late data and duplicate completion cannot emit another terminal")
        let row = try XCTUnwrap(terminal.first)
        for (key, expected) in ["firstDataMS": 2000.0, "deliverySpanMS": 3000.0, "completionGapMS": 4000.0, "totalMS": 9000.0] {
            XCTAssertEqual(Double(row[key] ?? ""), expected, key)
        }
        XCTAssertEqual(row["receivedBytes"], "5"); XCTAssertEqual(row["writtenBytes"], "5"); XCTAssertEqual(row["chunks"], "2")
        XCTAssertEqual(row["resourceKind"], "video"); XCTAssertEqual(row["durationSeconds"], "3.0")
        lease = nil; XCTAssertEqual(budget.reservedBytes, 0)
        logger.flushForTesting()
        let journal = try String(contentsOf: root.appendingPathComponent("logs/photo-sync.jsonl"), encoding: .utf8)
        XCTAssertTrue(journal.contains("live-photo-resource")); XCTAssertFalse(journal.contains("private-"))
    }

    func testReadTraceWaitAndCancellationStayBoundedUntilPhysicalTerminal() throws {
        let rows = ResourceTraceRows(), clock = ResourceTraceClock()
        let diagnostics = IndexDiagnostics(sink: { rows.append($0) }, monotonic: { clock.now })
        let trace = diagnostics.livePhotoResourceTrace(resource(), purpose: .completion)
        trace.start(.init(assetKind: .video, resourceKind: .video, resourceType: 2, duration: .nan))
        clock.set(129); trace.heartbeat()
        XCTAssertFalse(rows.values.contains { $0["event"] == "waiting" })
        clock.set(130); trace.heartbeat(); trace.heartbeat(); trace.cancelRequested(); trace.cancelRequested()
        clock.set(160); trace.heartbeat()
        XCTAssertEqual(rows.values.filter { $0["event"] == "waiting" }.count, 2)
        XCTAssertEqual(rows.values.filter { $0["event"] == "cancel-requested" }.count, 1)
        XCTAssertFalse(rows.values.contains { $0["event"] == "terminal" })
        trace.complete(error: CancellationError(), callbackAt: 160, finalizeSeconds: 0)
        clock.set(200); trace.heartbeat(); trace.complete(error: nil, callbackAt: 200, finalizeSeconds: 0)
        let final = try XCTUnwrap(rows.values.last { $0["event"] == "terminal" })
        XCTAssertEqual(final["firstDataMS"], "unavailable"); XCTAssertEqual(final["durationSeconds"], "unknown")
        XCTAssertEqual(final["result"], "cancelled")
        XCTAssertEqual(rows.values.filter { $0["event"] == "terminal" }.count, 1)
    }

    func testKnownResourceLimitSurvivesLogicalTimeoutBeforeTerminal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = ResourceTraceRows(), diagnostics = IndexDiagnostics(sink: { rows.append($0) })
        let started = expectation(description: "started"), cancelled = expectation(description: "cancelled")
        let requester = ControlledCloudRequester(started: started, cancelled: cancelled), executor = ReadExecutor()
        let reader = LivePhotoRawResourceReader(requester: requester, storage: .init(root: root.appendingPathComponent("raw")), executor: executor, requestTimeout: .seconds(1), logicalTimeout: .milliseconds(40))
        let budget = LivePhotoResourceBudget(maxBytes: 2)
        let ref = LivePhotoResourceRef.photos(contextID: UUID(), assetID: "oversized", resourceKey: "original", revision: "r1")
        let task = Task { try await reader.read(resource: ref, purpose: .inventory, budget: budget, trace: diagnostics.livePhotoResourceTrace(ref, purpose: .inventory)) }
        await fulfillment(of: [started, cancelled], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected known limit") }
        catch { XCTAssertEqual(error as? LivePhotoResourceReadError, .resourceLimit(bytes: 3)) }
        let held = await executor.snapshot(); XCTAssertEqual(held.physicalOccupancy, 1)
        XCTAssertFalse(rows.values.contains { $0["event"] == "terminal" })
        requester.finish()
        let released = await engineEventually { await executor.snapshot().physicalOccupancy == 0 }; XCTAssertTrue(released)
        let terminal = try XCTUnwrap(rows.values.last { $0["event"] == "terminal" })
        XCTAssertEqual(terminal["result"], "resource-limit"); XCTAssertEqual(terminal["receivedBytes"], "3")
        XCTAssertEqual(terminal["writtenBytes"], "0")
    }

    func testCancelBeforeRequestHandleRegistrationIsSentExactlyOnce() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "request entered"), cancelled = expectation(description: "late cancel handle")
        let gate = DispatchSemaphore(value: 0)
        let requester = ControlledCloudRequester(started: started, cancelled: cancelled, returnGate: gate)
        let budget = LivePhotoResourceBudget()
        let executor = ReadExecutor(maxConcurrentOperations: 1)
        let reader = LivePhotoRawResourceReader(requester: requester, storage: .init(root: root.appendingPathComponent("raw")), executor: executor)
        let task = Task { try await reader.read(resource: resource(), purpose: .inventory, budget: budget) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
        gate.signal()
        await fulfillment(of: [cancelled], timeout: 2)
        requester.sendLateData(); XCTAssertEqual(budget.reservedBytes, 3)
        requester.finish()
        let drained = await engineEventually { await executor.snapshot().physicalOccupancy == 0 && budget.reservedBytes == 0 }
        XCTAssertTrue(drained); XCTAssertEqual(requester.cancelCount, 1)
    }
    func testInvalidContainerHintCannotCreatePathsOrStartResourceRequest() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let requester = BufferedLivePhotoRequester(chunks: [Data([1])], fileExtension: "../mov")
        let raw = LivePhotoRawResourceReader(requester: requester, storage: .init(root: root.appendingPathComponent("raw")))
        do { _ = try await raw.read(resource: resource(), purpose: .inventory, budget: LivePhotoResourceBudget()); XCTFail("Invalid hint accepted") } catch { }
        XCTAssertTrue(requester.networkFlags.isEmpty)
    }
    func testTypedTemporaryResourceKeepsPhysicalOwnershipAndIsRemoved() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = PhotosResourceStorage(root: root.appendingPathComponent("raw")), budget = LivePhotoResourceBudget()
        let raw = LivePhotoRawResourceReader(requester: BufferedLivePhotoRequester(chunks: [Data([1,2,3])], fileExtension: "mov"), storage: storage)
        var lease: LivePhotoResourceLease? = try await raw.read(resource: resource(), purpose: .inventory, budget: budget)
        let url = try XCTUnwrap(lease).url
        XCTAssertEqual(url.pathExtension, "mov")
        let other = try storage.create(limits: PhotosResourceLimits())
        XCTAssertEqual(try Data(contentsOf: url), Data([1,2,3]), "Cleanup cannot reclaim a typed active owner")
        other.remove(); lease = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)); XCTAssertEqual(budget.reservedBytes, 0)
    }
    func testStreamedMovieRetainsContainerHintForNativeMetadataReader() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.mov"), identifier = UUID().uuidString
        try await makeLivePhotoMotion(at: original, identifier: identifier, audio: true)
        let bytes = try Data(contentsOf: original), budget = LivePhotoResourceBudget()
        let raw = LivePhotoRawResourceReader(requester: BufferedLivePhotoRequester(chunks: [bytes], fileExtension: "mov"),
            storage: .init(root: root.appendingPathComponent("raw")))
        var lease: LivePhotoResourceLease? = try await raw.read(resource: resource(), purpose: .inventory, budget: budget)
        let url = try XCTUnwrap(lease).url
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let result = try await LivePhotoMetadataReader().inspect(resource: lease!, kind: .video)
        guard case .identified(let identity) = result else { return XCTFail("Native reader did not recognize exported motion") }
        XCTAssertEqual(identity.contentIdentifier, identifier); XCTAssertNotNil(identity.stillImageTime); XCTAssertEqual(identity.hasAudio, true)
        lease = nil
        XCTAssertEqual(budget.reservedBytes, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testLivePhotoObjectCallbacksIgnoreDegradedAndRepeatedResults() async throws {
        let size: CGSize = try await withCheckedThrowingContinuation { continuation in
            let result = LivePhotoObjectResult { continuation.resume(with: $0) }
            result.receive(size: CGSize(width: 16, height: 16), degraded: true, error: nil)
            result.receive(size: CGSize(width: 32, height: 32), degraded: false, error: nil)
            result.receive(size: CGSize(width: 64, height: 64), degraded: false, error: nil)
        }
        XCTAssertEqual(size, CGSize(width: 32, height: 32))
    }
    func testMetadataTimeoutRetainsEncodedBackingUntilPhysicalReadReturns() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("fixture.jpg")
        try makeLivePhotoImage(at: image, identifier: UUID().uuidString)
        let bytes = try Data(contentsOf: image), budget = LivePhotoResourceBudget()
        let raw = LivePhotoRawResourceReader(requester: BufferedLivePhotoRequester(chunks: [bytes]), storage: .init(root: root.appendingPathComponent("raw")))
        var lease: LivePhotoResourceLease? = try await raw.read(resource: resource(), purpose: .inventory, budget: budget)
        let entered = expectation(description: "physical metadata read"), release = DispatchSemaphore(value: 0)
        let executor = ReadExecutor(maxConcurrentOperations: 1, defaultTimeout: .seconds(0.05))
        let reader = LivePhotoMetadataReader(executor: executor, beforeRead: { entered.fulfill(); _ = release.wait(timeout: .now() + 5) })
        let task = Task { [owned = lease!] in try await reader.inspect(resource: owned, kind: .image) }
        lease = nil
        await fulfillment(of: [entered], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected metadata timeout") } catch is ReadExecutorError { }
        XCTAssertEqual(budget.reservedBytes, Int64(bytes.count), "Backing must remain while physical metadata read is occupied")
        release.signal()
        let drained = await engineEventually { await executor.snapshot().physicalOccupancy == 0 && budget.reservedBytes == 0 }
        XCTAssertTrue(drained)
        XCTAssertEqual(budget.reservedBytes, 0)
    }
    func testInventoryAndCompletionAllowCloudOriginals() async throws {
        let requester = BufferedLivePhotoRequester(chunks: [Data([1,2,3])])
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = LivePhotoRawResourceReader(requester: requester, storage: PhotosResourceStorage(root: root.appendingPathComponent("raw")))
        let lease = try await reader.read(resource: resource(), purpose: .inventory, budget: LivePhotoResourceBudget())
        XCTAssertEqual(try Data(contentsOf: lease.url), Data([1,2,3]))
        _ = try await reader.read(resource: resource(), purpose: .completion, budget: LivePhotoResourceBudget())
        XCTAssertEqual(requester.networkFlags, [true, true])
    }

    func testCallerCancellationReachesPhysicalRequestAndRetainsOwnership() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "physical request"), cancelled = expectation(description: "physical cancel")
        let requester = ControlledCloudRequester(started: started, cancelled: cancelled)
        let executor = ReadExecutor(maxConcurrentOperations: 1)
        let budget = LivePhotoResourceBudget()
        let reader = LivePhotoRawResourceReader(requester: requester, storage: .init(root: root.appendingPathComponent("raw")), executor: executor)
        let task = Task { try await reader.read(resource: resource(), purpose: .inventory, budget: budget) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled caller succeeded") } catch is CancellationError { }
        await fulfillment(of: [cancelled], timeout: 0.5)
        XCTAssertEqual(budget.reservedBytes, 3)
        let occupied = await executor.snapshot(); XCTAssertEqual(occupied.physicalOccupancy, 1)
        requester.finish(); requester.finish()
        let drained = await engineEventually { await executor.snapshot().physicalOccupancy == 0 && budget.reservedBytes == 0 }
        XCTAssertTrue(drained); XCTAssertEqual(requester.cancelCount, 1)
    }

    func testCombinedResourcesRespect512MiB() async throws {
        // Scaled budget exercises the same aggregate accounting without allocating half a gigabyte.
        let budget = LivePhotoResourceBudget(maxBytes: 8)
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = LivePhotoRawResourceReader(requester: BufferedLivePhotoRequester(chunks: [Data(repeating: 1, count: 6)]), storage: .init(root: root.appendingPathComponent("raw")))
        var first: LivePhotoResourceLease? = try await reader.read(resource: resource(), purpose: .inventory, budget: budget)
        XCTAssertEqual(budget.reservedBytes, 6)
        do { _ = try await reader.read(resource: resource(), purpose: .inventory, budget: budget); XCTFail("Aggregate limit ignored") } catch { }
        XCTAssertEqual(budget.reservedBytes, 6)
        first = nil
        XCTAssertNil(first); XCTAssertEqual(budget.reservedBytes, 0)
    }

    func testFreeSpaceReserve128MiB() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = LivePhotoRawResourceReader(requester: BufferedLivePhotoRequester(chunks: [Data([1])]),
            storage: .init(root: root.appendingPathComponent("raw"), availableBytes: { 134217728 }))
        do { _ = try await reader.read(resource: resource(), purpose: .inventory, budget: LivePhotoResourceBudget()); XCTFail("Reserve consumed") } catch { }
    }

    func testTimeoutRetainsPhysicalLease() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "physical request started")
        let requester = HeldLivePhotoRequester(started: started)
        let executor = ReadExecutor(maxConcurrentOperations: 1, defaultTimeout: .seconds(0.05))
        let budget = LivePhotoResourceBudget()
        let reader = LivePhotoRawResourceReader(requester: requester, storage: .init(root: root.appendingPathComponent("raw")), executor: executor,
            requestTimeout: .seconds(0.02), logicalTimeout: .seconds(0.05))
        let task = Task { try await reader.read(resource: resource(), purpose: .inventory, budget: budget) }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected logical timeout") } catch { }
        XCTAssertEqual(budget.reservedBytes, 3)
        let occupied = await executor.snapshot(); XCTAssertEqual(occupied.physicalOccupancy, 1)
        requester.finish()
        let released = await engineEventually { budget.reservedBytes == 0 }
        XCTAssertTrue(released)
    }

    func testCloudDeadlineCancelsOnceAndDrainsUntilTerminal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "request"), cancelled = expectation(description: "deadline cancel")
        let requester = ControlledCloudRequester(started: started, cancelled: cancelled)
        let executor = ReadExecutor(maxConcurrentOperations: 1, defaultTimeout: .seconds(0.01))
        let budget = LivePhotoResourceBudget()
        let reader = LivePhotoRawResourceReader(requester: requester, storage: .init(root: root.appendingPathComponent("raw")), executor: executor,
            requestTimeout: .seconds(0.05), logicalTimeout: .seconds(0.1))
        let task = Task { try await reader.read(resource: resource(), purpose: .inventory, budget: budget) }
        await fulfillment(of: [started, cancelled], timeout: 2)
        XCTAssertEqual(budget.reservedBytes, 3)
        let admission = await reader.admission(); XCTAssertEqual(admission, .draining)
        requester.sendLateData(); XCTAssertEqual(budget.reservedBytes, 3)
        do { _ = try await task.value; XCTFail("Expected bounded logical timeout") } catch { }
        do { _ = try await reader.read(resource: resource(), purpose: .inventory, budget: budget); XCTFail("Draining request was replaced") }
        catch let error as ReadExecutorError { XCTAssertEqual(error, .sourceBusy) }
        requester.finish()
        let drained = await engineEventually { await executor.snapshot().physicalOccupancy == 0 && budget.reservedBytes == 0 }
        XCTAssertTrue(drained)
        let final = await reader.admission(); XCTAssertEqual(final, .available)
        XCTAssertEqual(requester.cancelCount, 1)
    }

    func testCloudReadOutlivesExecutorDefaultWithoutLosingSuccess() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "request")
        let requester = ControlledCloudRequester(started: started)
        let executor = ReadExecutor(maxConcurrentOperations: 1, defaultTimeout: .zero)
        let reader = LivePhotoRawResourceReader(requester: requester, storage: .init(root: root.appendingPathComponent("raw")), executor: executor)
        let task = Task { try await reader.read(resource: resource(), purpose: .inventory, budget: LivePhotoResourceBudget()) }
        await fulfillment(of: [started], timeout: 2)
        requester.finish()
        let lease = try await task.value
        XCTAssertEqual(try Data(contentsOf: lease.url), Data([1,2,3]))
        XCTAssertEqual(requester.cancelCount, 0)
    }

    func testExactComparisonRejectsSameIDWithDifferentBytes() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data([1,2,3]).write(to: a); try Data([1,2,4]).write(to: b)
        XCTAssertFalse(try LivePhotoResourceLease.filesEqual(a, b))
        try Data([1,2,3]).write(to: b); XCTAssertTrue(try LivePhotoResourceLease.filesEqual(a, b))
    }

    func testUnsupportedProtectedFieldIsUnknown() {
        var snapshot = knownLivePhotoSnapshot()
        XCTAssertTrue(snapshot.retirementInformationIsKnown)
        snapshot.caption = .unknown
        XCTAssertFalse(snapshot.retirementInformationIsKnown)
        snapshot.caption = .emptyOrNotApplicable; snapshot.title = .unknown
        XCTAssertTrue(snapshot.retirementInformationIsKnown)
    }

    private func resource() -> LivePhotoResourceRef { .photos(contextID: UUID(), assetID: "asset", resourceKey: "original", revision: "r1") }
}

final class ControlledCloudRequester: LivePhotoResourceRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private let started: XCTestExpectation
    private let cancelled: XCTestExpectation?
    private let returnGate: DispatchSemaphore?
    private var completion: (@Sendable (Error?) -> Void)?
    private var receive: (@Sendable (Data) -> Void)?
    private var cancellations = 0
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    init(started: XCTestExpectation, cancelled: XCTestExpectation? = nil, returnGate: DispatchSemaphore? = nil) { self.started = started; self.cancelled = cancelled; self.returnGate = returnGate }
    func request(_ ref: LivePhotoResourceRef, allowNetwork: Bool, receive: @escaping @Sendable (Data) -> Void,
                 completion: @escaping @Sendable (Error?) -> Void) throws -> @Sendable () -> Void {
        lock.lock(); self.completion = completion; self.receive = receive; lock.unlock()
        receive(Data([1,2,3])); started.fulfill()
        if let returnGate { _ = returnGate.wait(timeout: .now() + 5) }
        return { [self] in
            lock.lock(); cancellations += 1; lock.unlock()
            cancelled?.fulfill()
        }
    }
    func finish(_ error: Error? = nil) { lock.lock(); let callback = completion; completion = nil; lock.unlock(); callback?(error) }
    func sendLateData() { lock.lock(); let callback = receive; lock.unlock(); callback?(Data([4,5,6])) }
}

func knownLivePhotoSnapshot(revision: String = "r1") -> LivePhotoPreservationSnapshot {
    var value = LivePhotoPreservationSnapshot(revision: revision)
    value.creationDate = .emptyOrNotApplicable; value.location = .emptyOrNotApplicable
    value.favorite = .value(false); value.hidden = .value(false); value.rating = .emptyOrNotApplicable
    value.title = .emptyOrNotApplicable; value.caption = .emptyOrNotApplicable; value.keywords = .value([])
    value.albumIDs = .value([]); value.hasAdjustments = .value(false); value.hasExtraResources = .value(false); value.isSharedAlbum = .value(false)
    return value
}

final class BufferedLivePhotoRequester: LivePhotoResourceRequesting, @unchecked Sendable {
    let chunks: [Data]
    let fileExtension: String?
    private(set) var networkFlags = [Bool]()
    init(chunks: [Data], fileExtension: String? = nil) { self.chunks = chunks; self.fileExtension = fileExtension }
    func resourceInfo(_ ref: LivePhotoResourceRef) throws -> LivePhotoResourceInfo { .init(fileExtension: fileExtension) }
    func request(_ ref: LivePhotoResourceRef, allowNetwork: Bool, receive: @escaping @Sendable (Data) -> Void,
                 completion: @escaping @Sendable (Error?) -> Void) throws -> @Sendable () -> Void {
        networkFlags.append(allowNetwork)
        chunks.forEach(receive); completion(nil)
        return {}
    }
}

final class HeldLivePhotoRequester: LivePhotoResourceRequesting, @unchecked Sendable {
    let started: XCTestExpectation
    private let lock = NSLock()
    private var done: (@Sendable (Error?) -> Void)?
    init(started: XCTestExpectation) { self.started = started }
    func request(_ ref: LivePhotoResourceRef, allowNetwork: Bool, receive: @escaping @Sendable (Data) -> Void,
                 completion: @escaping @Sendable (Error?) -> Void) throws -> @Sendable () -> Void {
        lock.lock(); done = completion; lock.unlock()
        receive(Data([1,2,3])); started.fulfill(); return {}
    }
    func finish() { lock.lock(); let call = done; done = nil; lock.unlock(); call?(nil) }
}

private final class ResourceTraceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: TimeInterval) { lock.lock(); self.value = value; lock.unlock() }
}
private final class ResourceTraceRows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows = [[String: String]]()
    var values: [[String: String]] { lock.lock(); defer { lock.unlock() }; return rows }
    func append(_ row: [String: String]) { lock.lock(); rows.append(row); lock.unlock() }
}
private struct TimedResourceRequester: LivePhotoResourceRequesting {
    let clock: ResourceTraceClock
    func resourceInfo(_ ref: LivePhotoResourceRef) throws -> LivePhotoResourceInfo {
        .init(assetKind: .video, resourceKind: .video, resourceType: 2, duration: 3)
    }
    func request(_ ref: LivePhotoResourceRef, allowNetwork: Bool, receive: @escaping @Sendable (Data) -> Void,
                 completion: @escaping @Sendable (Error?) -> Void) throws -> @Sendable () -> Void {
        clock.set(102); receive(Data([1, 2]))
        clock.set(105); receive(Data([3, 4, 5]))
        clock.set(109); completion(nil)
        receive(Data([6])); completion(nil)
        return {}
    }
}
