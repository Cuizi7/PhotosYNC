import Foundation

public enum AdvancedDuplicatePolicy {
    public static func evaluate(sourceSize: PixelSize?, candidates: [ScoredCandidate],
                                configuration: DedupConfiguration) throws -> DuplicateEvaluation {
        guard configuration.policyVersion == DedupConfiguration.computePolicyVersion(
            fingerprintVersion: configuration.fingerprint.version,
            threshold: configuration.threshold, backend: configuration.backend),
            candidates.allSatisfy({ $0.fingerprintVersion == configuration.fingerprint.version &&
                                     $0.score.isFinite && !$0.key.isEmpty }) else {
            throw AdvancedDedupError.modelMismatch
        }
        // The caller supplies a complete, valid candidate view. Never infer a missing read as uniqueness.
        let matches = candidates.filter { $0.score >= configuration.threshold }
            .sorted { $0.score == $1.score ? $0.key < $1.key : $0.score > $1.score }
        guard !matches.isEmpty else {
            return DuplicateEvaluation(content: .notDuplicate, action: .importFile, reason: .noMatch,
                                       matchedKeys: [], coveringKeys: [])
        }
        let covering = matches.filter { candidate in
            guard let source = sourceSize, let size = candidate.size else { return false }
            return min(size.width, size.height) >= min(source.width, source.height) &&
                   max(size.width, size.height) >= max(source.width, source.height)
        }
        if !covering.isEmpty {
            return DuplicateEvaluation(content: .duplicate, action: .skip, reason: .covered,
                                       matchedKeys: matches.map(\.key), coveringKeys: covering.map(\.key))
        }
        let upgrade = sourceSize != nil && matches.allSatisfy { candidate in
            guard let source = sourceSize, let size = candidate.size else { return false }
            return min(source.width, source.height) > min(size.width, size.height) &&
                   max(source.width, source.height) > max(size.width, size.height)
        }
        return DuplicateEvaluation(content: .duplicate, action: .importFile,
                                   reason: upgrade ? .resolutionUpgrade : .insufficientSizeEvidence,
                                   matchedKeys: matches.map(\.key), coveringKeys: [])
    }
}
