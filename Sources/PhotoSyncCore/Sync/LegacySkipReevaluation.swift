import Foundation

public struct LegacySkipCandidate: Sendable {
    public let file: StoredFile
    public let skipReason: SkipReason
    public let submittedAt: Date?
    public let definitelyNotCommitted: Bool
    public let decisionPolicyVersion: String?
}

struct LegacyRecheckWork: Sendable {
    let candidate: LegacySkipCandidate
    let revision: Int64
    let isRetry: Bool
    let retryCount: Int
}

/// Bounded migration of old duplicate decisions back to normal pending admission.
/// The owner schedules batches; this actor adds no timer or independent source reader.
public actor LegacySkipReevaluation {
    private let store: SyncStore
    private let stamp: @Sendable (SourceFile) async throws -> FileStamp
    private let policyVersion: String
    private let retryDelaysSeconds: [Double]
    private let now: @Sendable () -> Date
    private var initialized = false
    private var processing = false
    private var paused = false

    public init(store: SyncStore, stamp: @escaping @Sendable (SourceFile) async throws -> FileStamp,
                policyVersion: String, retryDelaysSeconds: [Double],
                now: @escaping @Sendable () -> Date = { Date() }) {
        precondition(!policyVersion.isEmpty && !retryDelaysSeconds.isEmpty && retryDelaysSeconds.allSatisfy { $0.isFinite && $0 > 0 })
        self.store = store; self.stamp = stamp; self.policyVersion = policyVersion
        self.retryDelaysSeconds = retryDelaysSeconds; self.now = now
    }

    public func setPaused(_ paused: Bool) { self.paused = paused }

    /// Returns successful pending transitions, not inspected files or new imports.
    public func processBatch(limit: Int) async throws -> Int {
        guard limit > 0, !processing, !paused else { return 0 }
        processing = true
        defer { processing = false }
        try Task.checkCancellation()
        if !initialized {
            try await store.beginLegacyRecheck(policyVersion: policyVersion)
            initialized = true
        }
        var reopened = 0
        for _ in 0..<limit {
            try Task.checkCancellation()
            guard !paused else { break }
            guard let work = try await store.nextLegacyRecheck(policyVersion: policyVersion, now: now()) else { break }
            try Task.checkCancellation()
            guard !paused else { break }
            let observed: FileStamp?
            do { observed = try await stamp(work.candidate.file.file) }
            catch is CancellationError { throw CancellationError() }
            catch { observed = nil }
            try Task.checkCancellation()
            guard !paused else { break }
            let delay = retryDelaysSeconds[min(work.retryCount, retryDelaysSeconds.count - 1)]
            guard let changed = try await store.finishLegacyRecheck(work, stamp: observed,
                policyVersion: policyVersion, nextRetryAt: now().addingTimeInterval(delay)) else {
                // Requeue won while source I/O was suspended. Next batch restarts at its cursor.
                break
            }
            if changed { reopened += 1 }
        }
        return reopened
    }
}
