import Foundation

public enum ReadExecutorError: Error, Equatable {
    case timedOut
    case sourceBusy
    case resourceExhausted
}

public actor ReadExecutor {
    public struct Snapshot: Equatable, Sendable {
        public let physicalOccupancy: Int
        public let queuedOperations: Int
    }

    public static let shared = ReadExecutor()

    private let queue: OperationQueue
    private let defaultTimeout: Duration
    private var inFlightSources = Set<String>()
    private var physicalOccupancy = 0

    public init(maxConcurrentOperations: Int = 2, defaultTimeout: Duration = .seconds(60)) {
        self.defaultTimeout = defaultTimeout
        queue = OperationQueue()
        queue.name = "PhotoSyncCore.ReadExecutor"
        queue.maxConcurrentOperationCount = maxConcurrentOperations
        queue.qualityOfService = .utility
    }

    public func snapshot() -> Snapshot {
        Snapshot(physicalOccupancy: physicalOccupancy, queuedOperations: queue.operationCount)
    }

    public func execute<Value: Sendable>(
        sourceID: some Hashable & Sendable,
        timeout: Duration? = nil,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let source = String(describing: sourceID)
        guard !inFlightSources.contains(source) else { throw ReadExecutorError.sourceBusy }
        guard queue.operationCount < queue.maxConcurrentOperationCount else { throw ReadExecutorError.resourceExhausted }
        inFlightSources.insert(source)
        physicalOccupancy += 1

        let state = ReadOperationState<Value>()
        return try await withCheckedThrowingContinuation { continuation in
            state.install(continuation)
            queue.addOperation { [weak self] in
                let result = Result { try operation() }
                state.finish(result)
                Task { await self?.completed(source: source) }
            }
            Task.detached {
                try? await Task.sleep(for: timeout ?? self.defaultTimeout)
                state.finish(.failure(ReadExecutorError.timedOut))
            }
        }
    }

    private func completed(source: String) {
        inFlightSources.remove(source)
        physicalOccupancy -= 1
    }
}

private final class ReadOperationState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
