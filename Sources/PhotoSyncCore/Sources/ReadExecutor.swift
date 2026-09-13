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
        try Task.checkCancellation()
        guard !inFlightSources.contains(sourceID) else { throw ReadExecutorError.sourceBusy }
        guard physicalOccupancy < maxConcurrentOperations else { throw ReadExecutorError.resourceExhausted }
        inFlightSources.insert(sourceID)
        physicalOccupancy += 1

        let state = ReadOperationState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                queue.addOperation { [weak self] in
                    if state.beginPhysicalWork() {
                        state.finish(Result { try operation() })
                    }
                    Task { await self?.completed(source: sourceID) }
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
                    if state.beginPhysicalWork() {
                        do {
                            state.finish(.success(try await operation()))
                        } catch {
                            state.finish(.failure(error))
                        }
                    }
                    await self?.completed(source: sourceID)
                }
                state.startTimeout(after: timeout ?? self.defaultTimeout)
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }

    private func completed(source: UUID) {
        inFlightSources.remove(source)
        physicalOccupancy -= 1
    }
}

private final class ReadOperationState<Value>: @unchecked Sendable {
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

    func startTimeout(after duration: Duration) {
        lock.lock()
        guard terminalResult == nil, timeoutTask == nil else {
            lock.unlock()
            return
        }
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
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
