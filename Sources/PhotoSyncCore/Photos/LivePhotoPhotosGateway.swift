import Foundation

public enum LivePhotoReadPurpose: Sendable { case inventory, completion }

/// No observation was accepted; retry through ordinary scheduling, never a global failure cooldown.
public enum LivePhotoReadDeferred: Error, Equatable, Sendable {
    case classificationPending
    case resourceChanged
}

public enum LivePhotoResourceReadError: Error, Equatable, Sendable {
    case requestTimedOut
    case resourceLimit(bytes: Int64)
    case budgetBusy(resourceBytes: Int64)
    case workingSetLimit
}

public protocol LivePhotoPhotosGateway: PhotosIndexGateway {
    func createLivePhoto(photoURL: URL, motionURL: URL, photoFilename: String?, motionFilename: String?, preservation: LivePhotoPreservationSnapshot, expectedGeneration: Int,
                         beforeMutation: @escaping @Sendable () throws -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String
    func retireLivePhotoComponents(assetIDs: [String], expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool) async throws
    func verifyLivePhoto(assetID: String, operation: LivePhotoOperation) async throws -> LivePhotoVerification
    func setLivePhotoRecoveryBlocks(_ operationIDs: Set<UUID>) async

    func verifyLivePhotoContext(context: LibraryContext, anchorAssetIDs: [String], allowUnanchored: Bool) async throws -> Bool
    func livePhotoLibraryContext() async throws -> LibraryContext
    func livePhotoAssetCatalog(session: PhotosCatalogSession, offset: Int, limit: Int) async throws -> LivePhotoAssetPage
    func livePhotoAssets(assetIDs: [String], context: LibraryContext) async throws -> [LivePhotoAssetDescriptor]
    func readLivePhotoResource(_ ref: LivePhotoResourceRef, purpose: LivePhotoReadPurpose, budget: LivePhotoResourceBudget) async throws -> LivePhotoResourceLease
    func livePhotoReadAdmission() async -> PhotosReaderAdmission
    /// Releases completed inventory results retained for continuation and invalidates
    /// in-flight attempts to retain them later. Active physical requests keep ownership
    /// until their terminal callback; this hook must not release that ownership early.
    func discardPendingLivePhotoReads() async
    func livePhotoPreservationSnapshot(assetID: String, context: LibraryContext) async throws -> LivePhotoPreservationSnapshot
    func resourcesEqual(_ lhs: LivePhotoResourceRef, _ rhs: LivePhotoResourceRef, budget: LivePhotoResourceBudget) async throws -> Bool
}

extension LivePhotoPhotosGateway {
    /// Gateways that never retain completed inventory reads need no cleanup.
    public func discardPendingLivePhotoReads() async {}
}

public final class LivePhotoResourceBudget: @unchecked Sendable {
    public static let shared = LivePhotoResourceBudget()
    let limits: PhotosResourceLimits
    private let lock = NSLock()
    private var held: Int64 = 0
    public init(maxBytes: Int64 = 536870912, freeSpaceReserveBytes: Int64 = 134217728) {
        precondition(maxBytes > 0 && maxBytes <= 536870912 && freeSpaceReserveBytes >= 134217728)
        limits = .init(maxEncodedBytes: maxBytes, freeSpaceReserveBytes: freeSpaceReserveBytes)
    }
    public var reservedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return held }
    func reserve(_ bytes: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, bytes <= limits.maxEncodedBytes - held else { throw PhotosRepresentationError.encodedResourceLimit }
        held += bytes
    }
    func release(_ bytes: Int64) { lock.lock(); held -= bytes; assert(held >= 0); lock.unlock() }
}

/// An observation keeps its asset ticket through parsing/commit without retaining encoded bytes.
final class LivePhotoResourceValidity: @unchecked Sendable {
    private let validate: @Sendable () throws -> Void
    private let release: @Sendable () -> Void
    init(validate: @escaping @Sendable () -> Bool, release: @escaping @Sendable () -> Void) {
        self.validate = { guard validate() else { throw PhotoKitGatewayError.libraryChanged } }; self.release = release
    }
    init(check: @escaping @Sendable () throws -> Void, release: @escaping @Sendable () -> Void) { validate = check; self.release = release }
    func requireCurrent() throws { try validate() }
    var isCurrent: Bool { (try? validate()) != nil }
    deinit { release() }
}

/// The lease, not the caller's logical timeout, owns the encoded backing and its aggregate budget.
public final class LivePhotoResourceLease: @unchecked Sendable {
    public let url: URL
    private let owner: OwnedPhotosResource?
    private let budget: LivePhotoResourceBudget?
    private let bytes: Int64
    private let retaining: LivePhotoResourceLease?
    let validity: LivePhotoResourceValidity?
    var encodedBytes: Int64 { bytes }
    init(url: URL, owner: OwnedPhotosResource? = nil, budget: LivePhotoResourceBudget? = nil, bytes: Int64 = 0, retaining: LivePhotoResourceLease? = nil, validity: LivePhotoResourceValidity? = nil) {
        self.url = url; self.owner = owner; self.budget = budget; self.bytes = bytes; self.retaining = retaining; self.validity = validity
    }
    deinit { owner?.remove(); budget?.release(bytes) }

    static func filesEqual(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let a = try FileHandle(forReadingFrom: lhs), b = try FileHandle(forReadingFrom: rhs)
        defer { try? a.close(); try? b.close() }
        while true {
            let left = try a.read(upToCount: 65536) ?? Data(), right = try b.read(upToCount: 65536) ?? Data()
            guard left == right else { return false }
            if left.isEmpty { return true }
        }
    }
}

/// One completed inventory read may wait for notification classification. Its
/// lease still owns the real bytes/budget; it is never a persistent content cache.
final class LivePhotoPendingRead: @unchecked Sendable {
    struct Value: Sendable {
        let id = UUID()
        let ref: LivePhotoResourceRef
        let lease: LivePhotoResourceLease
        let budget: LivePhotoResourceBudget
        let expiresAt: TimeInterval
        var discarded: @Sendable (LivePhotoRetentionEvent) -> Void = { _ in }
    }
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var value: Value?
    private var revision: UInt64 = 0
    init(now: @escaping @Sendable () -> TimeInterval) { self.now = now }
    var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return revision }
    func take(_ ref: LivePhotoResourceRef, budget: LivePhotoResourceBudget) -> Value? {
        lock.lock(); let previous = value; value = nil; lock.unlock()
        guard let previous else { return nil }
        guard previous.ref == ref, previous.budget === budget, previous.expiresAt > now() else {
            previous.discarded(previous.expiresAt <= now() ? .rawExpired : .rawDiscarded); return nil
        }
        return previous
    }
    @discardableResult
    func retain(_ candidate: Value, generation: UInt64) -> Bool {
        let remaining = candidate.expiresAt - now()
        guard remaining > 0 else { candidate.discarded(.rawExpired); return false }
        lock.lock()
        guard generation == revision else { lock.unlock(); candidate.discarded(.rawDiscarded); return false }
        let previous = value; value = candidate
        lock.unlock()
        if let previous, previous.id != candidate.id { previous.discarded(.rawDiscarded) }
        withExtendedLifetime(previous) {}
        let id = candidate.id
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining) { [weak self] in
            self?.expire(id: id)
        }
        return true
    }
    func expire(id: UUID? = nil) {
        lock.lock()
        let previous: Value?
        if let current = value, (id == nil || current.id == id), current.expiresAt <= now() {
            previous = current; value = nil
        } else { previous = nil }
        lock.unlock()
        previous?.discarded(.rawExpired)
        withExtendedLifetime(previous) {}
    }
    func discard() {
        lock.lock(); revision &+= 1; let previous = value; value = nil; lock.unlock()
        previous?.discarded(.rawDiscarded)
        withExtendedLifetime(previous) {}
    }
}

struct LivePhotoResourceInfo: Sendable {
    var fileExtension: String?
    var assetKind: MediaKind?
    var resourceKind: MediaKind?
    var resourceType: Int?
    var duration: TimeInterval?
}

protocol LivePhotoResourceRequesting: Sendable {
    func resourceInfo(_ ref: LivePhotoResourceRef) throws -> LivePhotoResourceInfo
    func request(_ ref: LivePhotoResourceRef, allowNetwork: Bool, progress: @escaping @Sendable (Double) -> Void,
                 receive: @escaping @Sendable (Data) -> Void,
                 completion: @escaping @Sendable (Error?) -> Void) throws -> @Sendable () -> Void
}
extension LivePhotoResourceRequesting {
    func resourceInfo(_ ref: LivePhotoResourceRef) throws -> LivePhotoResourceInfo { .init() }
}

struct LivePhotoRawResourceReader: Sendable {
    let requester: any LivePhotoResourceRequesting
    let storage: PhotosResourceStorage
    let executor: ReadExecutor
    private let sourceID = UUID()
    private let requestTimeout: Duration
    private let logicalTimeout: Duration
    private let tracker = LivePhotoReadTracker()
    init(requester: any LivePhotoResourceRequesting, storage: PhotosResourceStorage = .init(), executor: ReadExecutor = .shared,
         requestTimeout: Duration = .seconds(600), logicalTimeout: Duration = .seconds(610)) {
        self.requester = requester; self.storage = storage; self.executor = executor
        self.requestTimeout = requestTimeout; self.logicalTimeout = logicalTimeout
    }
    func admission() async -> PhotosReaderAdmission { tracker.admission() }
    func read(resource: LivePhotoResourceRef, purpose: LivePhotoReadPurpose, budget: LivePhotoResourceBudget, trace: LivePhotoResourceTrace? = nil) async throws -> LivePhotoResourceLease {
        let cancellation = LivePhotoReadCancellation()
        trace?.enqueued()
        return try await withTaskCancellationHandler {
            do { return try await executor.executeAsync(sourceID: sourceID, timeout: logicalTimeout) {
                trace?.admitted()
                let info = try requester.resourceInfo(resource)
                let owner = try storage.create(limits: budget.limits, fileExtension: info.fileExtension)
                let stream = LivePhotoResourceStream(owner: owner, budget: budget, trace: trace)
                tracker.install(stream); cancellation.install(stream)
                defer { tracker.finish(stream) }
                return try await withCheckedThrowingContinuation { continuation in
                    stream.install(continuation)
                    guard stream.begin(timeout: requestTimeout) else { stream.complete(CancellationError()); return }
                    // Reuse the same resource lookup that supplies the container hint.
                    trace?.start(info)
                    do {
                        let cancel = try requester.request(resource, allowNetwork: true, progress: { trace?.downloadProgress($0) },
                            receive: { stream.receive($0) }, completion: { stream.complete($0) })
                        stream.installCancel(cancel)
                    } catch { stream.complete(error) }
                }
            }
            } catch ReadExecutorError.timedOut {
                // The logical waiter may finish before PhotoKit's terminal callback. Preserve
                // already-known capacity facts, but leave physical ownership with that Task.
                let failure = cancellation.knownFailure
                cancellation.cancel(with: LivePhotoResourceReadError.requestTimedOut)
                throw failure ?? LivePhotoResourceReadError.requestTimedOut
            }
        } onCancel: { cancellation.cancel() }
    }
}

/// This bridge is installed outside executeAsync's unstructured physical Task.
private final class LivePhotoReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var stream: LivePhotoResourceStream?
    func install(_ value: LivePhotoResourceStream) {
        lock.lock(); stream = value; let cancelled = cancelled; lock.unlock()
        if cancelled { value.requestCancellation(CancellationError()) }
    }
    var knownFailure: Error? { lock.lock(); let stream = stream; lock.unlock(); return stream?.knownFailure }
    func cancel(with error: Error = CancellationError()) {
        lock.lock(); cancelled = true; let stream = stream; lock.unlock()
        stream?.requestCancellation(error)
    }
}

private final class LivePhotoReadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: LivePhotoResourceStream?
    func install(_ value: LivePhotoResourceStream) { lock.lock(); stream = value; lock.unlock() }
    func finish(_ value: LivePhotoResourceStream) { lock.lock(); if stream === value { stream = nil }; lock.unlock() }
    func admission() -> PhotosReaderAdmission {
        lock.lock(); let stream = stream; lock.unlock()
        return stream?.admission() ?? .available
    }
}

private final class LivePhotoResourceStream: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LivePhotoResourceLease, Error>?
    private var owner: OwnedPhotosResource?
    private let budget: LivePhotoResourceBudget
    private var bytes: Int64 = 0
    private var failure: Error?
    private var finished = false
    private var cancel: (@Sendable () -> Void)?
    private var cancelSent = false
    private var drainingSince: TimeInterval?
    private var deadline: Task<Void, Never>?
    private let trace: LivePhotoResourceTrace?
    init(owner: OwnedPhotosResource, budget: LivePhotoResourceBudget, trace: LivePhotoResourceTrace?) { self.owner = owner; self.budget = budget; self.trace = trace }
    var knownFailure: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    func install(_ value: CheckedContinuation<LivePhotoResourceLease, Error>) { lock.lock(); continuation = value; lock.unlock() }
    func begin(timeout: Duration) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, !finished else { return false }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout); self?.requestCancellation(LivePhotoResourceReadError.requestTimedOut) } catch { }
        }
        return true
    }
    func admission() -> PhotosReaderAdmission {
        lock.lock(); defer { lock.unlock() }
        if finished { return .available }
        guard let since = drainingSince else { return .busy }
        return ProcessInfo.processInfo.systemUptime - since >= 60 ? .stalled : .draining
    }
    private func takeCancel() -> (@Sendable () -> Void)? {
        guard !finished, failure != nil, !cancelSent, let cancel else { return nil }
        cancelSent = true; return cancel
    }
    func requestCancellation(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if failure == nil { failure = error; drainingSince = ProcessInfo.processInfo.systemUptime }
        let action = takeCancel(); lock.unlock()
        trace?.cancelRequested()
        action?()
    }
    func installCancel(_ value: @escaping @Sendable () -> Void) {
        lock.lock(); cancel = finished ? nil : value; let action = takeCancel(); lock.unlock()
        action?()
    }
    func receive(_ data: Data) {
        trace?.received(data.count)
        lock.lock()
        guard !finished, failure == nil, let owner else { lock.unlock(); return }
        do {
            let attempted = bytes + Int64(data.count)
            guard attempted <= budget.limits.maxEncodedBytes else { throw LivePhotoResourceReadError.resourceLimit(bytes: attempted) }
            do { try budget.reserve(Int64(data.count)) }
            catch { throw LivePhotoResourceReadError.budgetBusy(resourceBytes: attempted) }
            let start = trace?.now()
            do {
                try owner.append(data); bytes += Int64(data.count)
                if let start { trace?.wrote(data.count, seconds: (trace?.now() ?? start) - start) }
            }
            catch {
                if let start { trace?.wrote(0, seconds: (trace?.now() ?? start) - start) }
                budget.release(Int64(data.count)); throw error
            }
        } catch { failure = error; drainingSince = ProcessInfo.processInfo.systemUptime }
        let action = takeCancel(), failed = failure != nil
        lock.unlock()
        if failed { trace?.cancelRequested() }
        action?()
    }
    func complete(_ error: Error?) {
        let callbackAt = trace?.now()
        lock.lock()
        guard !finished, let owner else { lock.unlock(); return }
        finished = true
        deadline?.cancel(); deadline = nil
        var result: Result<LivePhotoResourceLease, Error>
        if let error = failure ?? error {
            owner.remove(); budget.release(bytes); result = .failure(error)
        } else {
            do { try owner.closeStream(); result = .success(.init(url: owner.url, owner: owner, budget: budget, bytes: bytes)) }
            catch { owner.remove(); budget.release(bytes); result = .failure(error) }
        }
        self.owner = nil; cancel = nil
        let call = continuation; continuation = nil
        lock.unlock()
        if let callbackAt {
            let terminalError: Error?
            if case .failure(let error) = result { terminalError = error } else { terminalError = nil }
            trace?.complete(error: terminalError, callbackAt: callbackAt, finalizeSeconds: (trace?.now() ?? callbackAt) - callbackAt)
        }
        call?.resume(with: result)
    }
}

extension LivePhotoPreservationSnapshot {
    public var retirementInformationIsKnown: Bool {
        creationDate.isKnown && location.isKnown && favorite.isKnown && hidden.isKnown && rating.isKnown &&
        caption.isKnown && keywords.isKnown && albumIDs.isKnown && hasAdjustments.isKnown &&
        hasExtraResources.isKnown && isSharedAlbum.isKnown
    }
}

public extension LivePhotoPhotosGateway {
    func livePhotoReadAdmission() async -> PhotosReaderAdmission { .available }
    func verifyLivePhotoContext(context: LibraryContext, anchorAssetIDs: [String], allowUnanchored: Bool) async throws -> Bool { false }
    func createLivePhoto(photoURL: URL, motionURL: URL, preservation: LivePhotoPreservationSnapshot, expectedGeneration: Int,
                         beforeMutation: @escaping @Sendable () throws -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        try await createLivePhoto(photoURL: photoURL, motionURL: motionURL, photoFilename: nil, motionFilename: nil, preservation: preservation,
            expectedGeneration: expectedGeneration, beforeMutation: beforeMutation, onPlaceholder: onPlaceholder)
    }
}
