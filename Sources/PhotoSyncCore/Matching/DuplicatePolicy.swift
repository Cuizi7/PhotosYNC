import Foundation

public struct DuplicatePolicy: Sendable {
    public static let version = 1

    public init() {}

    public func evaluate(_ source: MediaMetadata, candidates: [MatchCandidate]) -> MatchDecision {
        let sameName = candidates.filter { $0.metadata.filename == source.filename }
        let unresolved = sameName.filter { candidate in
            let other = candidate.metadata
            if let left = source.captureSecond, let right = other.captureSecond, left != right {
                return false
            }
            return !deviceConflict(source, other)
        }

        return unresolved.isEmpty
            ? .importNew
            : .skip(candidateKeys: unresolved.map(\.key).sorted())
    }
}

private func normalizedDevicePart(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()
    return result.isEmpty ? nil : result
}

private func deviceConflict(_ left: MediaMetadata, _ right: MediaMetadata) -> Bool {
    guard let leftMake = normalizedDevicePart(left.make),
          let leftModel = normalizedDevicePart(left.model),
          let rightMake = normalizedDevicePart(right.make),
          let rightModel = normalizedDevicePart(right.model) else {
        return false
    }
    return leftMake != rightMake || leftModel != rightModel
}
