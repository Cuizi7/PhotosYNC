import Foundation

public enum ImageWorkBudgetError: Error, Equatable, Sendable {
    case invalidReservation
    case exhausted
}

/// Accounts for app-owned decoded images; not PhotoKit caches or network buffers.
/// Exhaustion is deferred work, not permission to start a replacement physical task.
public actor ImageWorkBudget {
    public struct Snapshot: Equatable, Sendable {
        public let images: Int
        public let bytes: Int64
    }
    private let maxImages: Int
    private let maxBytes: Int64
    private var reservations: [UUID: Int64] = [:]
    private var bytes: Int64 = 0

    public init(maxImages: Int, maxBytes: Int64) {
        precondition(maxImages > 0 && maxBytes > 0)
        self.maxImages = maxImages
        self.maxBytes = maxBytes
    }

    public init(limits: ResourceLimits) {
        self.init(maxImages: limits.maxInFlightTasks, maxBytes: limits.maxDecodedBytes)
    }

    public func acquire(bytes requested: Int64) async throws -> ImageLease {
        try Task.checkCancellation()
        guard requested > 0, requested <= maxBytes else { throw ImageWorkBudgetError.invalidReservation }
        guard reservations.count < maxImages, requested <= maxBytes - bytes else { throw ImageWorkBudgetError.exhausted }
        let id = UUID()
        reservations[id] = requested
        bytes += requested
        return ImageLease(budget: self, id: id, reservedBytes: requested)
    }

    /// Matches acquire without reserving; callers must still handle a racing claim.
    public func canAcquire(bytes requested: Int64) -> Bool {
        requested > 0 && requested <= maxBytes && reservations.count < maxImages && requested <= maxBytes - bytes
    }

    public func snapshot() -> Snapshot { Snapshot(images: reservations.count, bytes: bytes) }

    fileprivate func release(_ id: UUID) -> Bool {
        guard let released = reservations.removeValue(forKey: id) else { return false }
        bytes -= released
        return true
    }
}

/// Keep alive through the final physical consumer, including inference. Calling
/// finish after a timeout while that consumer still runs would violate the lease.
public final class ImageLease: @unchecked Sendable {
    public let reservedBytes: Int64
    private let budget: ImageWorkBudget
    private let id: UUID
    private let ownershipLock = NSLock()
    private var cleanup: (@Sendable () -> Void)?
    private var finished = false
    private var indexDiagnostic: IndexDiagnosticOperation?
    private var diagnosticDescriptor: RepresentationDescriptor?

    fileprivate init(budget: ImageWorkBudget, id: UUID, reservedBytes: Int64) {
        self.budget = budget; self.id = id; self.reservedBytes = reservedBytes
    }
    /// Attached before publication. Reporting follows actual cleanup and budget
    /// release, and never invokes a sink while holding the ownership lock.
    func setIndexDiagnostic(_ diagnostic: IndexDiagnosticOperation?, descriptor: RepresentationDescriptor) {
        ownershipLock.lock(); indexDiagnostic = diagnostic; diagnosticDescriptor = descriptor; ownershipLock.unlock()
    }
    private func diagnosticFacts() -> (IndexDiagnosticOperation?, RepresentationDescriptor?) {
        ownershipLock.lock(); defer { ownershipLock.unlock() }
        return (indexDiagnostic, diagnosticDescriptor)
    }
    /// Attach encoded backing while a lazy decoded image can still consume it.
    func retainPhysicalResource(cleanup: @escaping @Sendable () -> Void) {
        ownershipLock.lock()
        precondition(!finished && self.cleanup == nil)
        self.cleanup = cleanup
        ownershipLock.unlock()
    }
    private func finishOwnership() {
        ownershipLock.lock()
        guard !finished else { ownershipLock.unlock(); return }
        let cleanup = self.cleanup; self.cleanup = nil
        // A concurrent idempotent finish must also wait for backing cleanup,
        // otherwise it could return the shared budget while cleanup still runs.
        cleanup?()
        finished = true
        ownershipLock.unlock()
    }
    public func finishPhysicalWork() async {
        finishOwnership()
        let released = await budget.release(id)
        let (diagnostic, descriptor) = diagnosticFacts()
        if released { diagnostic?.record(["phase": "photos-reader", "event": "lease-released"], descriptor: descriptor) }
    }
    deinit {
        finishOwnership()
        let budget = budget, id = id
        let (diagnostic, descriptor) = diagnosticFacts()
        Task {
            if await budget.release(id) { diagnostic?.record(["phase": "photos-reader", "event": "lease-released"], descriptor: descriptor) }
        }
    }
}

/// Source reads retain the lease in both the physical closure and returned value.
public struct ImageWorkResult<Value: Sendable>: Sendable {
    public let value: Value
    public let lease: ImageLease
}
