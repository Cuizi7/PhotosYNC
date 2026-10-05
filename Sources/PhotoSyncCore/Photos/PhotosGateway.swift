import Foundation

public enum ImportEvidence: Equatable, Sendable {
    case found(identifier: String)
    case definitelyNotCommitted
    case unknown
}

public protocol PhotosCandidateValidity: Sendable {
    /// Runs the supplied synchronous commit only while the snapshot generation remains valid.
    /// The closure must not perform Photos I/O or suspend.
    func commitIfCurrent(_ commit: @escaping @Sendable () throws -> Void) throws -> Bool
}

public struct AlwaysValidPhotosCandidateValidity: PhotosCandidateValidity, Sendable {
    public init() {}

    public func commitIfCurrent(_ commit: @escaping @Sendable () throws -> Void) throws -> Bool {
        try commit()
        return true
    }
}

public struct PhotosCandidateSnapshot: Equatable, Sendable {
    public let generation: Int
    private let candidatesByFilename: [String: [MatchCandidate]]
    private let validity: any PhotosCandidateValidity

    public init(
        generation: Int,
        candidates: [MatchCandidate],
        validity: any PhotosCandidateValidity = AlwaysValidPhotosCandidateValidity()
    ) {
        self.generation = generation
        self.candidatesByFilename = Dictionary(grouping: candidates, by: { $0.metadata.filename })
        self.validity = validity
    }

    init(
        generation: Int,
        candidatesByFilename: [String: [MatchCandidate]],
        validity: any PhotosCandidateValidity = AlwaysValidPhotosCandidateValidity()
    ) {
        self.generation = generation
        self.candidatesByFilename = candidatesByFilename
        self.validity = validity
    }

    var candidateValidity: any PhotosCandidateValidity { validity }

    public func candidates(named filename: String) -> [MatchCandidate] {
        candidatesByFilename[filename] ?? []
    }

    public var allCandidates: [MatchCandidate] {
        candidatesByFilename.keys.sorted().flatMap { candidatesByFilename[$0] ?? [] }
    }

    public static func == (lhs: PhotosCandidateSnapshot, rhs: PhotosCandidateSnapshot) -> Bool {
        lhs.generation == rhs.generation && lhs.candidatesByFilename == rhs.candidatesByFilename
    }
}

/// Proof supplied only when a guarded gateway did not create any asset request.
/// Timeout, cancellation, and an in-flight/unknown request must never use this.
struct PhotosAdmissionDeferred: Error, Sendable {}

public protocol PhotosGateway: Sendable {
    /// Returns an immutable candidate view and its admission generation.
    ///
    /// The view is valid only for decisions made before the gateway reports a
    /// library change. Implementations must not return a snapshot that became
    /// stale while it was being loaded; they should retry or throw
    /// `PhotoKitGatewayError.libraryChanged` instead.
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot

    /// Submits one source file only if `expectedGeneration` still names the
    /// snapshot used for admission. Implementations must reject a stale token
    /// before touching the Photos mutation boundary.
    func create(
        fileURL: URL,
        kind: MediaKind,
        expectedGeneration: Int,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String
    /// The predicate is checked synchronously at the actual mutation boundary,
    /// after all gateway awaits. A default implementation fails closed.
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int,
                beforeMutation: @escaping @Sendable () throws -> Bool,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String
    func reconcile(placeholder: String?) async throws -> ImportEvidence
}

public extension PhotosGateway {
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int,
                beforeMutation: @escaping @Sendable () throws -> Bool,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        throw PhotosAdmissionDeferred()
    }

    func loadCandidates() async throws -> [MatchCandidate] {
        try await candidateSnapshot().allCandidates
    }

    func create(fileURL: URL, kind: MediaKind, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        let snapshot = try await candidateSnapshot()
        return try await create(fileURL: fileURL, kind: kind, expectedGeneration: snapshot.generation, onPlaceholder: onPlaceholder)
    }
}

public enum PhotoKitGatewayError: Error, Equatable, LocalizedError, Sendable {
    case authorizationRequired
    case libraryUnavailable
    case libraryChanged
    case definitelyNotCommitted(String)
    case resultUnknown(String)
    case checkpointFailed(String)

    public var recoveryEvidence: ImportEvidence {
        switch self {
        case .definitelyNotCommitted:
            return .definitelyNotCommitted
        case .authorizationRequired, .libraryUnavailable, .libraryChanged, .resultUnknown, .checkpointFailed:
            return .unknown
        }
    }

    public var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            return "Read-write access to the system Photos library is required."
        case .libraryUnavailable:
            return "The system Photos library is unavailable."
        case .libraryChanged:
            return "The system Photos library changed while it was being queried."
        case .definitelyNotCommitted(let detail):
            return "The Photos change was not committed: \(detail)"
        case .resultUnknown(let detail), .checkpointFailed(let detail):
            return "The Photos import outcome is unknown: \(detail)"
        }
    }
}
