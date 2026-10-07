import Foundation
import CoreGraphics
import ImageIO

public enum PhotosIndexChange: Equatable, Sendable {
    case incremental(PhotosIndexDelta)
    case fullReconcileRequired
    case contextInvalidated
}

/// One complete change interval in a single library context, continuous from the
/// caller's inventory generation to `toGeneration > fromGeneration`. ID arrays
/// contain unique, nonempty, disjoint IDs: changed IDs require inventory inspection;
/// deleted IDs require affirmative deletion evidence, never a missing fetch result.
/// Both arrays may be empty for a valid advancing interval. Emit the whole interval,
/// not independent batches. Large producer scopes are durably journaled before a
/// catalog-reconcile wakeup; bounded persistence uses PhotosIndexDeltaBatch.
/// Lost continuity or an absent complete baseline requires reconciliation. Subscribers may
/// receive the same interval more than once; duplicate delivery adds no new facts.
public struct PhotosIndexDelta: Equatable, Sendable {
    public let context: LibraryContext
    public let fromGeneration: Int
    public let toGeneration: Int
    public let changedAssetIDs: [String]
    public let deletedAssetIDs: [String]
    public init(context: LibraryContext, fromGeneration: Int, toGeneration: Int,
                changedAssetIDs: [String], deletedAssetIDs: [String]) {
        self.context = context; self.fromGeneration = fromGeneration; self.toGeneration = toGeneration
        self.changedAssetIDs = changedAssetIDs; self.deletedAssetIDs = deletedAssetIDs
    }
    var isValid: Bool {
        fromGeneration >= 0 && toGeneration > fromGeneration &&
        changedAssetIDs.allSatisfy { !$0.isEmpty } && deletedAssetIDs.allSatisfy { !$0.isEmpty } &&
        Set(changedAssetIDs).count == changedAssetIDs.count && Set(deletedAssetIDs).count == deletedAssetIDs.count &&
        Set(changedAssetIDs).isDisjoint(with: deletedAssetIDs)
    }
}

/// One bounded page from a fixed Photos generation, including excluded version
/// slots. Before upserting, invalidate matching cached facts for the listed IDs
/// (or all cached representations when flagged), even if metadata revisions match.
public struct RepresentationPage: Equatable, Sendable {
    public let context: LibraryContext
    public let generation: Int
    public let descriptors: [RepresentationDescriptor]
    public let nextOffset: Int?
    public let exclusions: [RepresentationCatalogExclusion]
    /// Assets whose cached content must be invalidated even when descriptor revisions
    /// match. Delta pages restrict these IDs to the delta's changed IDs; merely being
    /// in changedAssetIDs does not itself establish same-revision content validity.
    public let invalidatedAssetIDs: [String]
    public let invalidateAllCachedRepresentations: Bool
    public let inputUnchangedAssetIDs: [String]
    public init(context: LibraryContext, generation: Int, descriptors: [RepresentationDescriptor], nextOffset: Int?, exclusions: [RepresentationCatalogExclusion] = [],
                invalidatedAssetIDs: [String] = [], invalidateAllCachedRepresentations: Bool = false, inputUnchangedAssetIDs: [String] = []) {
        self.context = context; self.generation = generation; self.descriptors = descriptors; self.nextOffset = nextOffset; self.exclusions = exclusions
        self.invalidatedAssetIDs = invalidatedAssetIDs; self.invalidateAllCachedRepresentations = invalidateAllCachedRepresentations
        self.inputUnchangedAssetIDs = inputUnchangedAssetIDs
    }
}

/// A bounded slice of ONE complete interval. Its offset is durable sequencing,
/// never another claim that a partial ID list covers fromGeneration...toGeneration.
public struct PhotosIndexDeltaBatch: Sendable {
    public let interval: PhotosIndexDelta
    public let offset: Int
    public let count: Int
    public init(interval: PhotosIndexDelta, offset: Int, count: Int) {
        self.interval = interval; self.offset = offset; self.count = count
    }
    var total: Int { interval.changedAssetIDs.count + interval.deletedAssetIDs.count }
    var first: Bool { offset == 0 }
    var last: Bool { offset + count == total }
    var valid: Bool { interval.isValid && offset >= 0 && count >= 0 && offset <= total && count <= total - offset && (count > 0 || total == 0) }
    var request: PhotosIndexDelta {
        let ids = interval.changedAssetIDs + interval.deletedAssetIDs
        let selected = Set(ids[offset..<offset + count])
        return .init(context: interval.context, fromGeneration: interval.fromGeneration, toGeneration: interval.toGeneration,
            changedAssetIDs: interval.changedAssetIDs.filter { selected.contains($0) },
            deletedAssetIDs: interval.deletedAssetIDs.filter { selected.contains($0) })
    }
}

public struct PhotosCatalogSession: Equatable, Sendable {
    public let id: UUID
    public let baselineGeneration: Int
    public init(id: UUID = UUID(), baselineGeneration: Int) {
        self.id = id; self.baselineGeneration = baselineGeneration
    }
}

/// One ascending, exclusive-cursor page from a completely classified interval.
/// The caller owns the complete baseline...endpoint interval; a page never claims
/// interval completion. Deleted IDs require affirmative deletion evidence. Return
/// nil only on the final page; throw if coverage or the stable session is lost.
public struct PhotosCatalogChangeBatch: Sendable {
    public let changedAssetIDs: [String]
    public let deletedAssetIDs: [String]
    /// Last visited asset ID; pass it as afterAssetID to request strictly later IDs.
    public let nextAssetID: String?
    public init(changedAssetIDs: [String], deletedAssetIDs: [String], nextAssetID: String?) {
        self.changedAssetIDs = changedAssetIDs; self.deletedAssetIDs = deletedAssetIDs; self.nextAssetID = nextAssetID
    }
}

public protocol PhotosIndexGateway: PhotosGateway {
    func beginCatalogSession(expectedGeneration: Int) async throws -> PhotosCatalogSession
    func representationCatalog(session: PhotosCatalogSession, offset: Int, limit: Int) async throws -> RepresentationPage
    func catalogCoverage(session: PhotosCatalogSession) async throws -> Int
    /// Called only after prior unknown obligations were durably marked non-queryable.
    func catalogInvalidationTransferred(session: PhotosCatalogSession) async throws
    /// Full-session merge facts may retain an older transferred verification obligation;
    /// a new unknown event still invalidates the session. Normal deltas stay strict.
    func representationCatalogDelta(session: PhotosCatalogSession, delta: PhotosIndexDelta) async throws -> RepresentationPage
    /// Installed before subscription. Producer obligations share the fact database.
    func attachIndexStore(_ store: SyncStore)
    func acknowledgeInventory(expectedGeneration: Int) async throws
    /// The original generation identifies a stable enumeration; this endpoint may advance.
    func catalogCoverage(baselineGeneration: Int) async throws -> Int
    func catalogChanges(baselineGeneration: Int, throughGeneration: Int, afterAssetID: String?, limit: Int) async throws -> PhotosCatalogChangeBatch
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage
    /// Fetch only changed IDs and return their COMPLETE representation eligibility
    /// inventory at delta.context/toGeneration: all eligible descriptors (including
    /// unchanged original/current slots) plus confirmed exclusions. Returning only
    /// the edited slot would remove an omitted original from the candidate inventory.
    /// Every changed ID must be accounted for; keys are unique, nextOffset is nil,
    /// and descriptors + exclusions fit catalogBatchSize. Deletions come exclusively
    /// from delta.deletedAssetIDs, not omitted/unknown/unavailable fetch results.
    /// Supply invalidatedAssetIDs whenever matching revisions cannot prove content
    /// unchanged. Unknown scope, incomplete/oversized results, pagination, or context/
    /// generation drift must throw for caller-owned full reconciliation; do not turn
    /// uncertainty into exclusion/deletion or set invalidateAllCachedRepresentations
    /// as a usable incremental result. This fetch neither advances a persistent-history
    /// checkpoint nor acknowledges readiness. Incremental persistence retains the token
    /// from the previous whole-inventory acquisition; its covered observer endpoint
    /// advances independently. Publish/acknowledge only complete ready facts.
    func representationDelta(_ delta: PhotosIndexDelta) async throws -> RepresentationPage
    func changes() -> AsyncStream<PhotosIndexChange>
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation
    /// Capture BEFORE the complete catalog acquisition; nil means no resumable
    /// checkpoint is available. The caller persists a nonnil value only alongside
    /// successful inventory facts of its captured context. A full inventory may cover
    /// a later observer endpoint; its saved token remains the earlier pre-read token.
    /// Cached-vector reuse additionally requires complete coverPersistentHistory from
    /// the old durable token through this proposal; metadata equality is insufficient.
    /// Incremental inventory retains the previous durable token until another full pass.
    /// Replay is continuity evidence, never a stable physical-library identity or
    /// an index-ready flag. Fetching facts alone must not acknowledge reconciliation.
    /// Replay complete persistent history from the durable prior token after capturing
    /// `through`, durably retaining all affected IDs before allowing cached-vector reuse.
    /// False is unknown coverage, never an empty history. Context must not be reset.
    func coverPersistentHistory(from previous: LibraryResumeCheckpoint, through proposed: LibraryResumeCheckpoint) async throws -> Bool
    func contextCheckpoint() async throws -> LibraryResumeCheckpoint?
    func resumeContext(_ checkpoint: LibraryResumeCheckpoint) async throws -> Bool
    /// Call only after complete same-generation full/delta reconciliation, durable facts and
    /// derived publication succeed. Keep ready admission unavailable until this
    /// returns; stale/pending generations throw and retain invalidation evidence.
    func acknowledgeReconciliation(expectedGeneration: Int) async throws
}

public enum RepresentationConservativeReason: String, Equatable, Sendable {
    case multiFrameOrCompound
    case unverifiedContainer
    case ambiguousResource
    /// Readable source still whose estimated native backing exceeds the fixed
    /// decoded allowance. Import original bytes without producing a vector.
    case decodedResourceLimit
}

public enum RepresentationEligibility: Equatable, Sendable {
    case safeSingleFrame
    case conservative(RepresentationConservativeReason)
}

public struct LoadedRepresentation: @unchecked Sendable {
    public let image: CGImage
    public let orientation: CGImagePropertyOrientation
    public let descriptor: RepresentationDescriptor
    public let lease: ImageLease
    public let eligibility: RepresentationEligibility
    public var returnedSize: PixelSize { try! PixelSize(width: image.width, height: image.height) }

    /// Constructs a successful read of exactly `descriptor`'s asset/version.
    /// This initializer does not transform pixels: use `.up` for already oriented
    /// pixels, or the actual unapplied orientation, which consumers apply once.
    /// `eligibility` records verified static-component safety; conservative output
    /// must not become an ordinary ready/skippable fingerprint. Descriptor size
    /// remains representation metadata, separate from this bitmap's returnedSize.
    ///
    /// The producer must reserve sufficient bytes before creating/retaining the
    /// image. Ownership of that lease transfers with the result; the consumer
    /// calls `await lease.finishPhysicalWork()` only after its last real image/
    /// inference use. Logical cancellation or timeout never proves that use ended.
    public init(image: CGImage, orientation: CGImagePropertyOrientation, descriptor: RepresentationDescriptor,
                lease: ImageLease, eligibility: RepresentationEligibility) {
        self.image = image; self.orientation = orientation; self.descriptor = descriptor
        self.lease = lease; self.eligibility = eligibility
    }
}

/// A bounded wake-up stream. Once any buffer overflows, every subsequent event
/// becomes full-reconcile until a complete generation is explicitly acknowledged.
/// This marks catalog delivery dirty only; the producer's durable journal retains
/// content obligations and does not reinterpret overflow as changed image pixels.
/// New subscribers also see the sticky dirty state, so a dropped event is never
/// silently replaced by a later, narrower update.
final class PhotosIndexChangeChannel: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var dirty = false
    private var continuations: [UUID: AsyncStream<PhotosIndexChange>.Continuation] = [:]
    init(capacity: Int) { precondition(capacity > 0); self.capacity = capacity }

    func stream() -> AsyncStream<PhotosIndexChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(capacity)) { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            if dirty { continuation.yield(.fullReconcileRequired) }
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }
    func send(_ event: PhotosIndexChange) {
        lock.lock(); defer { lock.unlock() }
        if case .incremental(let delta) = event,
           !delta.isValid { dirty = true }
        if event == .fullReconcileRequired || event == .contextInvalidated { dirty = true }
        guard !continuations.isEmpty else { dirty = true; return }
        var overflowed = false
        for continuation in continuations.values {
            let outgoing = event == .contextInvalidated ? event : (dirty ? .fullReconcileRequired : event)
            if case .dropped = continuation.yield(outgoing) {
                dirty = true
                overflowed = true
            }
        }
        if overflowed {
            for continuation in continuations.values { continuation.yield(.fullReconcileRequired) }
        }
    }
    func reconciled() { lock.lock(); dirty = false; lock.unlock() }
    private func remove(_ id: UUID) { lock.lock(); continuations.removeValue(forKey: id); lock.unlock() }
}

public struct LibraryResumeCheckpoint: Codable, Equatable, Sendable {
    public let context: LibraryContext
    public let archivedChangeToken: Data
    /// Process-local generation at token capture; old persisted checkpoints decode as nil.
    public let photosGeneration: Int?
    public init(context: LibraryContext, archivedChangeToken: Data, photosGeneration: Int? = nil) {
        self.context = context; self.archivedChangeToken = archivedChangeToken; self.photosGeneration = photosGeneration
    }
}

public extension PhotosIndexGateway {
    func beginCatalogSession(expectedGeneration: Int) async throws -> PhotosCatalogSession { .init(baselineGeneration: expectedGeneration) }
    func representationCatalog(session: PhotosCatalogSession, offset: Int, limit: Int) async throws -> RepresentationPage {
        try await representationCatalog(offset: offset, limit: limit, expectedGeneration: session.baselineGeneration)
    }
    func catalogCoverage(session: PhotosCatalogSession) async throws -> Int { try await catalogCoverage(baselineGeneration: session.baselineGeneration) }
    func catalogInvalidationTransferred(session: PhotosCatalogSession) async throws {}
    func representationCatalogDelta(session: PhotosCatalogSession, delta: PhotosIndexDelta) async throws -> RepresentationPage {
        try await representationDelta(delta)
    }
    func attachIndexStore(_ store: SyncStore) {}
    func acknowledgeInventory(expectedGeneration: Int) async throws {}
    func catalogCoverage(baselineGeneration: Int) async throws -> Int {
        let snapshot = try await candidateSnapshot()
        guard snapshot.generation == baselineGeneration else { throw PhotoKitGatewayError.libraryChanged }
        return baselineGeneration
    }
    func catalogChanges(baselineGeneration: Int, throughGeneration: Int, afterAssetID: String?, limit: Int) async throws -> PhotosCatalogChangeBatch {
        guard baselineGeneration == throughGeneration else { throw PhotoKitGatewayError.libraryChanged }
        return .init(changedAssetIDs: [], deletedAssetIDs: [], nextAssetID: nil)
    }
    func representationDelta(_ delta: PhotosIndexDelta) async throws -> RepresentationPage { throw PhotoKitGatewayError.libraryChanged }
    func resumeContext(_ checkpoint: LibraryResumeCheckpoint) async throws -> Bool { false }
    func coverPersistentHistory(from previous: LibraryResumeCheckpoint, through proposed: LibraryResumeCheckpoint) async throws -> Bool { false }
    func contextCheckpoint() async throws -> LibraryResumeCheckpoint? { nil }
    func acknowledgeReconciliation(expectedGeneration: Int) async throws {}
}

public enum RepresentationExclusionReason: Equatable, Sendable {
    case nonImage
    case rawResource
    case conservative(RepresentationConservativeReason)
}

public struct RepresentationCatalogExclusion: Equatable, Sendable {
    public let descriptor: RepresentationDescriptor
    public let reason: RepresentationExclusionReason
    public init(descriptor: RepresentationDescriptor, reason: RepresentationExclusionReason) {
        self.descriptor = descriptor; self.reason = reason
    }
}
