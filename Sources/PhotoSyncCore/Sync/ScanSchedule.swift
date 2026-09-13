import Foundation

public struct ScanSchedule: Sendable {
    public static let interval: TimeInterval = 1_800

    private var running = false
    private var paused = false
    private var lastObservedAt: Date?
    private var nextRecoveryAt: Date?
    public private(set) var nextScanAt: Date?

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
        nextRecoveryAt = now.addingTimeInterval(60)
        guard !running else { return false }
        running = true
        return true
    }

    private mutating func observeClock(_ now: Date) {
        if let lastObservedAt, now < lastObservedAt {
            nextScanAt = now.addingTimeInterval(Self.interval)
            nextRecoveryAt = now.addingTimeInterval(60)
        }
        lastObservedAt = now
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
