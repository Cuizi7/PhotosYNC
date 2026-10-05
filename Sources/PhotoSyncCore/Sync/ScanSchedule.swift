import Foundation

public struct ScanSchedule: Sendable {
    public static let interval: TimeInterval = 1_800

    private var photosReconciling = false
    public private(set) var nextPhotosReconcileAt: Date?
    private var running = false
    private var paused = false
    private var lastObservedAt: Date?
    private var recoveryPollAt: Date?
    private var sourceFailures: [UUID: Int] = [:]
    private var sourceDeferrals: [UUID: Int] = [:]
    private var sourceFailureRetryAt: [UUID: Date] = [:]
    private var sourceDeferralRetryAt: [UUID: Date] = [:]
    public private(set) var nextScanAt: Date?
    public private(set) var nextRecoveryAt: Date?

    public init() {}

    public mutating func requestPhotosReconciliation(now: Date, force: Bool = false) -> Bool {
        observeClock(now)
        guard !paused else { return false }
        guard force || nextPhotosReconcileAt == nil || now >= nextPhotosReconcileAt! else { return false }
        // Observe and drop overdue periods even while busy: no catch-up burst.
        nextPhotosReconcileAt = now.addingTimeInterval(Self.interval)
        guard !photosReconciling else { return false }
        photosReconciling = true
        return true
    }

    public mutating func finishedPhotosReconciliation() { photosReconciling = false }

    public mutating func startup(now: Date) -> Bool {
        requestNow(now: now)
    }

    public mutating func request(now: Date) -> Bool {
        observeClock(now)
        guard !paused else { return false }
        guard nextScanAt == nil || now >= nextScanAt! else { return false }
        nextScanAt = now.addingTimeInterval(Self.interval)
        guard !running else { return false }
        running = true
        return true
    }

    public mutating func requestNow(now: Date) -> Bool {
        observeClock(now)
        guard !paused, !running else { return false }
        running = true
        if nextScanAt == nil { nextScanAt = now.addingTimeInterval(Self.interval) }
        return true
    }

    public mutating func finished(now: Date) {
        observeClock(now)
        running = false
    }

    public mutating func pause() {
        paused = true
    }

    public mutating func resume(now: Date) -> Bool {
        paused = false
        return requestNow(now: now)
    }

    public mutating func wake(now: Date) -> Bool {
        requestNow(now: now)
    }

    public mutating func requestRecovery(now: Date) -> Bool {
        observeClock(now)
        guard !paused else { return false }
        guard nextRecoveryAt == nil || now >= nextRecoveryAt! else { return false }
        recoveryPollAt = now.addingTimeInterval(60)
        refreshRecoveryDeadline()
        guard !running else { return false }
        running = true
        return true
    }

    @discardableResult
    public mutating func recordSourceFailure(_ sourceID: UUID, now: Date) -> Date {
        let count = (sourceFailures[sourceID] ?? 0) + 1
        sourceFailures[sourceID] = count
        let retryAt = now.addingTimeInterval(sourceRecoveryDelay(failureCount: count))
        sourceFailureRetryAt[sourceID] = retryAt
        refreshRecoveryDeadline()
        return retryAt
    }

    /// A read the bounded reader deferred left work behind, but nothing failed. It comes back
    /// within seconds and only backs off while the wait persists, so it neither shows an error nor
    /// waits on the failure curve.
    @discardableResult
    public mutating func recordSourceDeferral(_ sourceID: UUID, now: Date) -> Date {
        let count = (sourceDeferrals[sourceID] ?? 0) + 1
        sourceDeferrals[sourceID] = count
        let retryAt = now.addingTimeInterval(sourceDeferralDelay(count: count))
        sourceDeferralRetryAt[sourceID] = retryAt
        refreshRecoveryDeadline()
        return retryAt
    }

    /// Clears only the unavailable-source curve, preserving any independent read deferral.
    public mutating func recordSourceFailureRecovered(_ sourceID: UUID) {
        sourceFailures.removeValue(forKey: sourceID)
        sourceFailureRetryAt.removeValue(forKey: sourceID)
        refreshRecoveryDeadline()
    }

    /// Clears only the normal-waiting curve, preserving an unrelated source outage deadline.
    public mutating func recordSourceDeferralRecovered(_ sourceID: UUID) {
        sourceDeferrals.removeValue(forKey: sourceID)
        sourceDeferralRetryAt.removeValue(forKey: sourceID)
        refreshRecoveryDeadline()
    }

    public mutating func recordSourceRecovered(_ sourceID: UUID) {
        recordSourceFailureRecovered(sourceID)
        recordSourceDeferralRecovered(sourceID)
    }

    public func dueRecoverySources(now: Date) -> [UUID] {
        let failureSources = sourceFailureRetryAt.compactMap { sourceID, retryAt in retryAt <= now ? sourceID : nil }
        let deferredSources = sourceDeferralRetryAt.compactMap { sourceID, retryAt in retryAt <= now ? sourceID : nil }
        return Set(failureSources + deferredSources)
            .sorted { $0.uuidString < $1.uuidString }
    }

    private mutating func observeClock(_ now: Date) {
        if let lastObservedAt, now < lastObservedAt {
            nextScanAt = now.addingTimeInterval(Self.interval)
            nextPhotosReconcileAt = now.addingTimeInterval(Self.interval)
            recoveryPollAt = now.addingTimeInterval(60)
            sourceFailureRetryAt = sourceFailureRetryAt.mapValues { _ in now.addingTimeInterval(60) }
            sourceDeferralRetryAt = sourceDeferralRetryAt.mapValues { _ in now.addingTimeInterval(60) }
            refreshRecoveryDeadline()
        }
        lastObservedAt = now
    }

    private mutating func refreshRecoveryDeadline() {
        nextRecoveryAt = (Array(sourceFailureRetryAt.values) + Array(sourceDeferralRetryAt.values) + [recoveryPollAt].compactMap { $0 }).min()
    }
}

/// Retry backoff for one file record's next submission attempt. Unchanged by the source recovery
/// curve: a file that can still be submitted must keep its short cadence.
public func retryDelay(failureCount: Int) -> TimeInterval {
    switch failureCount {
    case ..<2: return 5
    case 2: return 15
    case 3: return 30
    default: return 60
    }
}

/// Delay before re-attempting work a bounded reader deferred. Short enough that a contended
/// read feels immediate, long enough that a source held busy for minutes does not spin.
public func sourceDeferralDelay(count: Int) -> TimeInterval {
    switch count {
    case ..<3: return 5
    case 3, 4: return 15
    default: return 60
    }
}

/// Recovery backoff for an unavailable source. The first attempts stay quick so a remounted
/// volume resumes within seconds; once a source has failed five times in a row, probing settles
/// at five minutes instead of retrying a missing volume every minute forever. Recovery is still
/// bounded by the regular scan interval and by wake/activation ticks.
public func sourceRecoveryDelay(failureCount: Int) -> TimeInterval {
    switch failureCount {
    case ..<2: return 5
    case 2: return 15
    case 3: return 30
    case 4: return 60
    default: return 300
    }
}
