import Foundation

public enum ImportEvidence: Equatable, Sendable {
    case found(identifier: String)
    case definitelyNotCommitted
    case unknown
}

public protocol PhotosGateway: Sendable {
    func loadCandidates() async throws -> [MatchCandidate]
    func create(
        fileURL: URL,
        kind: MediaKind,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String
    func reconcile(placeholder: String?) async throws -> ImportEvidence
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
