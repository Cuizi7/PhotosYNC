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
/// slots. Notification scopes require inspection of the listed IDs; successful dates
/// own per-item analysis reuse. An unknown whole scope requires metadata verification of each
/// row, not discarded successful inference.
public struct RepresentationPage: Equatable, Sendable {
    public let context: LibraryContext
    public let generation: Int
    public let descriptors: [RepresentationDescriptor]
    public let nextOffset: Int?
    public let exclusions: [RepresentationCatalogExclusion]
    /// Legacy name for notification content scope, used for bounded discovery and
    /// diagnostics only. It never overrides a matching successful date/contract.
    /// Delta pages restrict these IDs to the delta's changed IDs.
    public let invalidatedAssetIDs: [String]
    /// Legacy name for unknown inventory continuity. Requires complete metadata
    /// reconciliation, never bulk analysis invalidation.
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

/// Advisory, level-triggered capacity of the physical reader and shared image budget.
/// Polling never reserves capacity or cancels/releases physical work. Available is
/// only an observation; a later read can still lose the capacity race. Busy includes
/// requests, cleanup and consumer-held shared-budget leases. Draining means logical
/// waiting ended while physical request/cleanup ownership remains. Stalled means
/// draining lasted at least 60 monotonic seconds, without forced release or a
/// guarantee of recovery if the system never completes the request.
public enum PhotosReaderAdmission: String, Equatable, Sendable {
    case available, busy, draining, stalled
}

/// One full inventory's history-continuity decision. False preservation requires
/// independent per-row metadata verification, never unconditional inference loss.
/// The observer fence belongs to one gateway lifetime and must not be persisted.
public struct PhotosInventoryContinuity: Sendable {
    public let checkpoint: LibraryResumeCheckpoint?
    public let preservesCachedRepresentations: Bool
    let observerFence: UUID?
    public init(checkpoint: LibraryResumeCheckpoint?, preservesCachedRepresentations: Bool) {
        self.checkpoint = checkpoint
        self.preservesCachedRepresentations = preservesCachedRepresentations
        self.observerFence = nil
    }
    init(checkpoint: LibraryResumeCheckpoint?, preservesCachedRepresentations: Bool, observerFence: UUID) {
        self.checkpoint = checkpoint
        self.preservesCachedRepresentations = preservesCachedRepresentations
        self.observerFence = observerFence
    }
}

public protocol PhotosIndexGateway: PhotosGateway {
    /// Restore the same-device persistent PhotoKit object domain independently of
    /// a history token. This is not a claim about a system library UUID.
    func restoreInventoryContext(_ context: LibraryContext) async throws
    /// Synchronously revoke active observer continuity when the runtime observes
    /// a permission gap, including while no Photos request is being issued.
    func invalidateObservationContinuity()
    /// Continuous observer sessions retain the last recovered durable token.
    /// Startup and actual coverage gaps use conservative persistent recovery.
    func prepareInventoryReconciliation(previousCheckpoint: LibraryResumeCheckpoint?) async throws -> PhotosInventoryContinuity
    /// Establish continuous observation only after this decision's complete inventory
    /// has been committed, and only if its gateway fence is still current.
    func acknowledgeInventory(expectedGeneration: Int, continuity: PhotosInventoryContinuity) async throws
    func beginCatalogSession(expectedGeneration: Int) async throws -> PhotosCatalogSession
    func representationCatalog(session: PhotosCatalogSession, offset: Int, limit: Int) async throws -> RepresentationPage
    func catalogCoverage(session: PhotosCatalogSession) async throws -> Int
    /// Called after the durable reconciliation publication barrier is established.
    /// Cached rows are verified individually before that barrier can be reopened.
    func catalogInvalidationTransferred(session: PhotosCatalogSession) async throws
    /// Full-session merge facts may retain an older transferred verification obligation;
    /// a new unknown event still invalidates the session. Normal deltas stay strict.
    func representationCatalogDelta(session: PhotosCatalogSession, delta: PhotosIndexDelta) async throws -> RepresentationPage
    /// Installed before subscription. Producer obligations share the fact database.
    func attachIndexStore(_ store: SyncStore)
    /// Confirms durable inventory coverage and clears covered notification-delivery
    /// dirtiness even while fingerprints remain pending. Does not admit history or
    /// publish readiness; stale generations and unfinished details must be rejected.
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
    /// Supply invalidatedAssetIDs as diagnostic/discovery scope; successful dates own
    /// analysis freshness. Unknown scope, incomplete/oversized results, pagination, or context/
    /// generation drift must throw for caller-owned full reconciliation; do not turn
    /// uncertainty into exclusion/deletion or set invalidateAllCachedRepresentations
    /// as a usable incremental result. This fetch neither advances a persistent-history
    /// checkpoint nor acknowledges readiness. Incremental persistence retains the token
    /// from the previous whole-inventory acquisition; its covered observer endpoint
    /// advances independently. Publish/acknowledge only complete ready facts.
    func representationDelta(_ delta: PhotosIndexDelta) async throws -> RepresentationPage
    func changes() -> AsyncStream<PhotosIndexChange>
    /// Return a prompt, non-reserving advisory snapshot; do not wait for a slot.
    /// Include physical ownership, pending cleanup and consumer-held shared-budget
    /// leases, even when the active request set is empty. Recheck ownership after
    /// awaits. Callers poll on runtime ticks and must still handle capacity errors
    /// from a later read: `.available` is not an acquisition guarantee. Polling must
    /// not claim, cancel or release work; draining/stalled retain physical ownership.
    func representationReadAdmission() async -> PhotosReaderAdmission
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation
    /// Recovery primitives: capture a proposal before the complete recovery
    /// inventory. Replay IDs identify possible updates, not confirmed pixel changes.
    /// The full inventory verifies them; false means unknown coverage, never empty history. Neither operation
    /// acknowledges readiness or advances the store on its own.
    /// Active full/delta inventories retain the last recovered checkpoint; only
    /// prepareInventoryReconciliation decides when new recovery is necessary.
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
    /// inference use. For encoded Photos resources the same lease also retains
    /// private backing bytes through any lazy ImageIO consumption. Logical cancellation or timeout never proves that use ended.
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
            continuation.onTermination = { [weak self] _ in
                // Cancellation may hold Swift's task-status lock while yield waits
                // for it. Never acquire our delivery lock from that callback.
                DispatchQueue.global(qos: .utility).async { [weak self] in self?.remove(id) }
            }
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
    func restoreInventoryContext(_ context: LibraryContext) async throws {}
    func invalidateObservationContinuity() {}
    func prepareInventoryReconciliation(previousCheckpoint: LibraryResumeCheckpoint?) async throws -> PhotosInventoryContinuity {
        let checkpoint = try await contextCheckpoint()
        let covered: Bool
        if let previousCheckpoint, let checkpoint {
            covered = try await coverPersistentHistory(from: previousCheckpoint, through: checkpoint)
        } else {
            // Resource-free adapters without checkpoints retain their existing
            // page-based contract; per-item dates still own analysis reuse.
            covered = checkpoint == nil && previousCheckpoint == nil
        }
        return .init(checkpoint: checkpoint, preservesCachedRepresentations: covered)
    }
    func acknowledgeInventory(expectedGeneration: Int, continuity: PhotosInventoryContinuity) async throws {
        try await acknowledgeInventory(expectedGeneration: expectedGeneration)
    }

    /// Convenience only for resource-free fakes. Real adapters must report their
    /// actual reader/shared-budget capacity, including cleanup and held leases.
    func representationReadAdmission() async -> PhotosReaderAdmission { .available }
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
