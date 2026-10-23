import Foundation

public enum ReadExecutorError: Error, Equatable {
    case timedOut
    case sourceBusy
    case resourceExhausted
}

public actor ReadExecutor {
    public struct Snapshot: Equatable, Sendable {
        public let physicalOccupancy: Int
        public let pendingOperations: Int
    }

    public static let shared = ReadExecutor()

    private let queue: OperationQueue
    private let maxConcurrentOperations: Int
    private let defaultTimeout: Duration
    private let beforeAsyncOperationStart: (@Sendable () -> Void)?
    private var inFlightSources = Set<UUID>()
    private var physicalOccupancy = 0
    private var imageDecodeSources = Set<UUID>()

    public init(maxConcurrentOperations: Int = 2, defaultTimeout: Duration = .seconds(60)) {
        self.init(
            maxConcurrentOperations: maxConcurrentOperations,
            defaultTimeout: defaultTimeout,
            beforeAsyncOperationStart: nil
        )
    }

    init(
        maxConcurrentOperations: Int,
        defaultTimeout: Duration,
        beforeAsyncOperationStart: (@Sendable () -> Void)?
    ) {
        self.maxConcurrentOperations = maxConcurrentOperations
        self.defaultTimeout = defaultTimeout
        self.beforeAsyncOperationStart = beforeAsyncOperationStart
        queue = OperationQueue()
        queue.name = "PhotoSyncCore.ReadExecutor"
        queue.maxConcurrentOperationCount = maxConcurrentOperations
        queue.qualityOfService = .utility
    }

    public func snapshot() -> Snapshot {
        Snapshot(physicalOccupancy: physicalOccupancy, pendingOperations: max(queue.operationCount - physicalOccupancy, 0))
    }

    public func execute<Value: Sendable>(
        sourceID: UUID,
        timeout: Duration? = nil,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await executeReserved(sourceID: sourceID, timeout: timeout, imageDecodeLimit: nil, operation: operation)
    }

    /// Shares the normal source fairness and physical occupancy. The image lease
    /// travels with the result through inference; a timeout never releases a
    /// still-running decode's reservation.
    public func executeImage<Value: Sendable>(
        sourceID: UUID, budget: ImageWorkBudget, bytes: Int64, limits: ResourceLimits,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> ImageWorkResult<Value> {
        let lease = try await budget.acquire(bytes: bytes)
        return try await executeReserved(sourceID: sourceID, timeout: .seconds(limits.requestTimeoutSeconds),
                                         imageDecodeLimit: limits.decodeConcurrency) {
            ImageWorkResult(value: try operation(), lease: lease)
        }
    }

    /// The decoder uses its lease's frozen allowance even if settings change.
    public func executeImage<Value: Sendable>(
        sourceID: UUID, budget: ImageWorkBudget, limits: ResourceLimits,
        operation: @escaping @Sendable (Int64) throws -> Value
    ) async throws -> ImageWorkResult<Value> {
        let lease = try await budget.acquireMaximum()
        return try await executeReserved(sourceID: sourceID, timeout: .seconds(limits.requestTimeoutSeconds),
                                         imageDecodeLimit: limits.decodeConcurrency) {
            ImageWorkResult(value: try operation(lease.reservedBytes), lease: lease)
        }
    }

    private func executeReserved<Value: Sendable>(
        sourceID: UUID, timeout: Duration?, imageDecodeLimit: Int?,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !inFlightSources.contains(sourceID) else { throw ReadExecutorError.sourceBusy }
        guard physicalOccupancy < maxConcurrentOperations else { throw ReadExecutorError.resourceExhausted }
        if let imageDecodeLimit {
            guard imageDecodeSources.count < imageDecodeLimit else { throw ReadExecutorError.resourceExhausted }
            imageDecodeSources.insert(sourceID)
        }
        inFlightSources.insert(sourceID)
        physicalOccupancy += 1

        let state = ReadOperationState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                queue.addOperation { [weak self] in
                    let result = state.beginPhysicalWork() ? Result { try operation() } : nil
                    Task {
                        await self?.completed(source: sourceID)
                        if let result { state.finish(result) }
                    }
                }
                state.startTimeout(after: timeout ?? self.defaultTimeout)
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }

    public func executeAsync<Value: Sendable>(
        sourceID: UUID,
        timeout: Duration? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !inFlightSources.contains(sourceID) else { throw ReadExecutorError.sourceBusy }
        guard physicalOccupancy < maxConcurrentOperations else { throw ReadExecutorError.resourceExhausted }
        inFlightSources.insert(sourceID)
        physicalOccupancy += 1

        let state = ReadOperationState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                Task { [weak self] in
                    self?.beforeAsyncOperationStart?()
                    let result: Result<Value, Error>?
                    if state.beginPhysicalWork() {
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                    } else { result = nil }
                    await self?.completed(source: sourceID)
                    if let result { state.finish(result) }
                }
                state.startTimeout(after: timeout ?? self.defaultTimeout)
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }

    private func completed(source: UUID) {
        inFlightSources.remove(source)
        imageDecodeSources.remove(source)
        physicalOccupancy -= 1
    }
}

final class ReadOperationState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var terminalResult: Result<Value, Error>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func startTimeout(after duration: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        lock.lock()
        guard terminalResult == nil, timeoutTask == nil else {
            lock.unlock()
            return
        }
        let task = Task { [weak self] in
            do {
                try await sleep(duration)
                self?.finish(.failure(ReadExecutorError.timedOut))
            } catch is CancellationError {
            } catch {
            }
        }
        timeoutTask = task
        lock.unlock()
    }

    func beginPhysicalWork() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalResult == nil
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        terminalResult = result
        let continuation = self.continuation
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}
