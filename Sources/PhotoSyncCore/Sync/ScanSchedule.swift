import Foundation

public struct ScanSchedule: Sendable {
    public static let interval: TimeInterval = 1_800

    private var running = false
    private var paused = false
    private var lastObservedAt: Date?
    private var recoveryPollAt: Date?
    private var sourceFailures: [UUID: Int] = [:]
    private var sourceRetryAt: [UUID: Date] = [:]
    public private(set) var nextScanAt: Date?
    public private(set) var nextRecoveryAt: Date?

    public init() {}

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
        let retryAt = now.addingTimeInterval(retryDelay(failureCount: count))
        sourceRetryAt[sourceID] = retryAt
        refreshRecoveryDeadline()
        return retryAt
    }

    public mutating func recordSourceRecovered(_ sourceID: UUID) {
        sourceFailures.removeValue(forKey: sourceID)
        sourceRetryAt.removeValue(forKey: sourceID)
        refreshRecoveryDeadline()
    }

    public func dueRecoverySources(now: Date) -> [UUID] {
        sourceRetryAt.compactMap { sourceID, retryAt in retryAt <= now ? sourceID : nil }
            .sorted { $0.uuidString < $1.uuidString }
    }

    private mutating func observeClock(_ now: Date) {
        if let lastObservedAt, now < lastObservedAt {
            nextScanAt = now.addingTimeInterval(Self.interval)
            recoveryPollAt = now.addingTimeInterval(60)
            sourceRetryAt = sourceRetryAt.mapValues { _ in now.addingTimeInterval(60) }
            refreshRecoveryDeadline()
        }
        lastObservedAt = now
    }

    private mutating func refreshRecoveryDeadline() {
        nextRecoveryAt = (sourceRetryAt.values + [recoveryPollAt].compactMap { $0 }).min()
    }
}

public func retryDelay(failureCount: Int) -> TimeInterval {
    switch failureCount {
    case ..<2: return 5
    case 2: return 15
    case 3: return 30
    default: return 60
    }
}
