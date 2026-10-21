import XCTest
@testable import PhotoSyncCore

final class LivePhotoResourceTests: XCTestCase {
    func testKnownResourceLimitSurvivesLogicalTimeoutBeforeTerminal() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "started"), cancelled = expectation(description: "cancelled")
        let requester = ControlledCloudRequester(started: started, cancelled: cancelled), executor = ReadExecutor()
        let reader = LivePhotoRawResourceReader(requester: requester, storage: .init(root: root.appendingPathComponent("raw")), executor: executor, requestTimeout: .seconds(1), logicalTimeout: .milliseconds(40))
        let budget = LivePhotoResourceBudget(maxBytes: 2)
        let ref = LivePhotoResourceRef.photos(contextID: UUID(), assetID: "oversized", resourceKey: "original", revision: "r1")
        let task = Task { try await reader.read(resource: ref, purpose: .inventory, budget: budget) }
        await fulfillment(of: [started, cancelled], timeout: 2)
        do { _ = try await task.value; XCTFail("Expected known limit") }
        catch { XCTAssertEqual(error as? LivePhotoResourceReadError, .resourceLimit(bytes: 3)) }
        let held = await executor.snapshot(); XCTAssertEqual(held.physicalOccupancy, 1)
        requester.finish()
        let released = await engineEventually { await executor.snapshot().physicalOccupancy == 0 }; XCTAssertTrue(released)
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
    func resourceFileExtension(_ ref: LivePhotoResourceRef) throws -> String? { fileExtension }
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
