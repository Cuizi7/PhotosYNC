import Foundation

public enum RecoveryAction: Equatable, Sendable {
    case markImported
    case retry
    case keepImporting
}

public func recoveryAction(_ evidence: ImportEvidence) -> RecoveryAction {
    switch evidence {
    case .found:
        return .markImported
    case .definitelyNotCommitted:
        return .retry
    case .unknown:
        return .keepImporting
    }
}
