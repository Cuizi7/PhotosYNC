import Foundation
import CoreGraphics
import ImageIO

public enum PhotosIndexChange: Equatable, Sendable {
    case assetsChanged([String])
    case assetsDeleted([String])
    case fullReconcileRequired
    case contextInvalidated
}

public struct RepresentationPage: Equatable, Sendable {
    public let context: LibraryContext
    public let generation: Int
    public let descriptors: [RepresentationDescriptor]
    public let nextOffset: Int?
    public let exclusions: [RepresentationCatalogExclusion]
    public let invalidatedAssetIDs: [String]
    public let invalidateAllCachedRepresentations: Bool
    public init(context: LibraryContext, generation: Int, descriptors: [RepresentationDescriptor], nextOffset: Int?, exclusions: [RepresentationCatalogExclusion] = [],
                invalidatedAssetIDs: [String] = [], invalidateAllCachedRepresentations: Bool = false) {
        self.context = context; self.generation = generation; self.descriptors = descriptors; self.nextOffset = nextOffset; self.exclusions = exclusions
        self.invalidatedAssetIDs = invalidatedAssetIDs; self.invalidateAllCachedRepresentations = invalidateAllCachedRepresentations
    }
}

public protocol PhotosIndexGateway: PhotosGateway {
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage
    func changes() -> AsyncStream<PhotosIndexChange>
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation
    /// Capture BEFORE catalog/snapshot acquisition, persist only alongside a
    /// successful reconciliation of that same generation. Replay is continuity
    /// evidence, never a stable physical-library identity or an index-ready flag.
    func contextCheckpoint() async throws -> LibraryResumeCheckpoint?
    func resumeContext(_ checkpoint: LibraryResumeCheckpoint) async throws -> Bool
    func acknowledgeReconciliation(expectedGeneration: Int) async throws
}

public enum RepresentationConservativeReason: String, Equatable, Sendable {
    case multiFrameOrCompound
    case unverifiedContainer
    case ambiguousResource
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
}

/// A bounded wake-up stream. Once any buffer overflows, every subsequent event
/// becomes full-reconcile until a complete generation is explicitly acknowledged.
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
        switch event {
        case .assetsChanged(let ids) where ids.count > capacity:
            for start in stride(from: 0, to: ids.count, by: capacity) { send(.assetsChanged(Array(ids[start..<min(start + capacity, ids.count)]))) }
            return
        case .assetsDeleted(let ids) where ids.count > capacity:
            for start in stride(from: 0, to: ids.count, by: capacity) { send(.assetsDeleted(Array(ids[start..<min(start + capacity, ids.count)]))) }
            return
        default: break
        }
        lock.lock(); defer { lock.unlock() }
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
    public init(context: LibraryContext, archivedChangeToken: Data) {
        self.context = context; self.archivedChangeToken = archivedChangeToken
    }
}

public extension PhotosIndexGateway {
    func resumeContext(_ checkpoint: LibraryResumeCheckpoint) async throws -> Bool { false }
    func contextCheckpoint() async throws -> LibraryResumeCheckpoint? { nil }
    func acknowledgeReconciliation(expectedGeneration: Int) async throws {}
}

public enum RepresentationExclusionReason: Equatable, Sendable {
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
