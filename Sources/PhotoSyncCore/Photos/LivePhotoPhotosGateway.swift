import Foundation

public enum LivePhotoReadPurpose: Sendable { case inventory, completion }

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
    func livePhotoPreservationSnapshot(assetID: String, context: LibraryContext) async throws -> LivePhotoPreservationSnapshot
    func resourcesEqual(_ lhs: LivePhotoResourceRef, _ rhs: LivePhotoResourceRef, budget: LivePhotoResourceBudget) async throws -> Bool
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

/// The lease, not the caller's logical timeout, owns the encoded backing and its aggregate budget.
public final class LivePhotoResourceLease: @unchecked Sendable {
    public let url: URL
    private let owner: OwnedPhotosResource?
    private let budget: LivePhotoResourceBudget?
    private let bytes: Int64
    init(url: URL, owner: OwnedPhotosResource? = nil, budget: LivePhotoResourceBudget? = nil, bytes: Int64 = 0) {
        self.url = url; self.owner = owner; self.budget = budget; self.bytes = bytes
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

protocol LivePhotoResourceRequesting: Sendable {
    func resourceFileExtension(_ ref: LivePhotoResourceRef) throws -> String?
    func request(_ ref: LivePhotoResourceRef, allowNetwork: Bool,
                 receive: @escaping @Sendable (Data) -> Void,
                 completion: @escaping @Sendable (Error?) -> Void) throws -> @Sendable () -> Void
}
extension LivePhotoResourceRequesting {
    func resourceFileExtension(_ ref: LivePhotoResourceRef) throws -> String? { nil }
}

struct LivePhotoRawResourceReader: Sendable {
    let requester: any LivePhotoResourceRequesting
    let storage: PhotosResourceStorage
    let executor: ReadExecutor
    private let sourceID = UUID()
    init(requester: any LivePhotoResourceRequesting, storage: PhotosResourceStorage = .init(), executor: ReadExecutor = .shared) {
        self.requester = requester; self.storage = storage; self.executor = executor
    }
    func read(resource: LivePhotoResourceRef, purpose: LivePhotoReadPurpose, budget: LivePhotoResourceBudget) async throws -> LivePhotoResourceLease {
        try await executor.executeAsync(sourceID: sourceID) {
            let owner = try storage.create(limits: budget.limits, fileExtension: requester.resourceFileExtension(resource))
            let stream = LivePhotoResourceStream(owner: owner, budget: budget)
            return try await withCheckedThrowingContinuation { continuation in
                stream.install(continuation)
                do {
                    let cancel = try requester.request(resource, allowNetwork: purpose == .completion,
                        receive: { stream.receive($0) }, completion: { stream.complete($0) })
                    stream.installCancel(cancel)
                } catch { stream.complete(error) }
            }
        }
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
    init(owner: OwnedPhotosResource, budget: LivePhotoResourceBudget) { self.owner = owner; self.budget = budget }
    func install(_ value: CheckedContinuation<LivePhotoResourceLease, Error>) { lock.lock(); continuation = value; lock.unlock() }
    func installCancel(_ value: @escaping @Sendable () -> Void) {
        lock.lock(); cancel = finished ? nil : value; let needsCancel = failure != nil && !finished; lock.unlock()
        if needsCancel { value() }
    }
    func receive(_ data: Data) {
        lock.lock()
        guard !finished, failure == nil, let owner else { lock.unlock(); return }
        do {
            try budget.reserve(Int64(data.count))
            do { try owner.append(data); bytes += Int64(data.count) }
            catch { budget.release(Int64(data.count)); throw error }
        } catch { failure = error }
        let action = failure == nil ? nil : cancel
        lock.unlock(); action?()
    }
    func complete(_ error: Error?) {
        lock.lock()
        guard !finished, let owner else { lock.unlock(); return }
        finished = true
        var result: Result<LivePhotoResourceLease, Error>
        if let error = failure ?? error {
            owner.remove(); budget.release(bytes); result = .failure(error)
        } else {
            do { try owner.closeStream(); result = .success(.init(url: owner.url, owner: owner, budget: budget, bytes: bytes)) }
            catch { owner.remove(); budget.release(bytes); result = .failure(error) }
        }
        self.owner = nil; cancel = nil
        let call = continuation; continuation = nil
        lock.unlock(); call?.resume(with: result)
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
    func verifyLivePhotoContext(context: LibraryContext, anchorAssetIDs: [String], allowUnanchored: Bool) async throws -> Bool { false }
    func createLivePhoto(photoURL: URL, motionURL: URL, preservation: LivePhotoPreservationSnapshot, expectedGeneration: Int,
                         beforeMutation: @escaping @Sendable () throws -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        try await createLivePhoto(photoURL: photoURL, motionURL: motionURL, photoFilename: nil, motionFilename: nil, preservation: preservation,
            expectedGeneration: expectedGeneration, beforeMutation: beforeMutation, onPlaceholder: onPlaceholder)
    }
}
