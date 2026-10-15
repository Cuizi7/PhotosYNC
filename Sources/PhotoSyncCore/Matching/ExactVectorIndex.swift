import Accelerate
import Foundation

public struct VectorEntry: Sendable {
    public let key: String
    public let origin: CandidateOrigin
    public let fingerprint: Fingerprint
    public let size: PixelSize?

    public init(key: String, origin: CandidateOrigin, fingerprint: Fingerprint, size: PixelSize?) {
        self.key = key
        self.origin = origin
        self.fingerprint = fingerprint
        self.size = size
    }
}

/// An exact, immutable-generation view. Callers must replace the complete valid view before searching.
public actor ExactVectorIndex {
    private struct Metadata {
        let key: String
        let origin: CandidateOrigin
        let size: PixelSize?
    }

    private let version: String
    private var generation: Int64?
    private var metadata = [Metadata]()
    private var vectors = [Float]()

    public init(version: String) {
        self.version = version
    }

    public func replace(entries: [VectorEntry], generation: Int64) throws {
        if let current = self.generation, generation <= current {
            throw AdvancedDedupError.modelMismatch
        }
        guard !version.isEmpty, entries.allSatisfy({ !$0.key.isEmpty && $0.fingerprint.version == version }),
              Set(entries.map(\.key)).count == entries.count else {
            throw AdvancedDedupError.modelMismatch
        }
        // Every rejection is above this point. This actor method never suspends
        // and the buffer is private, so no search can observe a partial replacement.
        let count = entries.count * 1024
        vectors.removeAll(keepingCapacity: vectors.capacity >= count)
        vectors.reserveCapacity(count)
        for entry in entries { vectors.append(contentsOf: entry.fingerprint.values) }
        metadata = entries.map { Metadata(key: $0.key, origin: $0.origin, size: $0.size) }
        self.generation = generation
    }

    /// Publication must match both the installed generation and its full vector count.
    public func containsGeneration(_ generation: Int64, entryCount: Int) -> Bool {
        self.generation == generation && metadata.count == entryCount && vectors.count == entryCount * 1024
    }

    public func search(query: Fingerprint, minimumScore: Double, generation: Int64) throws -> [ScoredCandidate] {
        try searchWithDiagnostics(query: query, minimumScore: minimumScore,
                                  generation: generation, diagnosticLimit: 0).matches
    }

    /// Same Float32 Accelerate path used for an unindexed local/history candidate view.
    public nonisolated static func score(query: Fingerprint, entries: [VectorEntry],
                                         minimumScore: Double) throws -> [ScoredCandidate] {
        try scoreWithDiagnostics(query: query, entries: entries,
                                 minimumScore: minimumScore, diagnosticLimit: 0).matches
    }

    public func searchWithDiagnostics(query: Fingerprint, minimumScore: Double, generation: Int64,
                                      diagnosticLimit: Int) throws -> VectorSearchResult {
        guard self.generation == generation, query.version == version else { throw AdvancedDedupError.modelMismatch }
        return try Self.scan(query: query, vectors: vectors, metadata: metadata,
                             minimumScore: minimumScore, diagnosticLimit: diagnosticLimit)
    }

    public nonisolated static func scoreWithDiagnostics(query: Fingerprint, entries: [VectorEntry],
                                                        minimumScore: Double, diagnosticLimit: Int) throws -> VectorSearchResult {
        guard entries.allSatisfy({ !$0.key.isEmpty && $0.fingerprint.version == query.version }),
              Set(entries.map(\.key)).count == entries.count else { throw AdvancedDedupError.modelMismatch }
        guard diagnosticLimit >= 0, minimumScore.isFinite, (-1...1).contains(minimumScore) else {
            throw AdvancedDedupError.invalidConfiguration
        }
        var matches = [ScoredCandidate]()
        var diagnostics = [ScoredCandidate]()
        query.values.withUnsafeBufferPointer { q in
            for entry in entries {
                var dot: Float = 0
                entry.fingerprint.values.withUnsafeBufferPointer { data in
                    vDSP_dotpr(q.baseAddress!, 1, data.baseAddress!, 1, &dot, 1024)
                }
                collect(dot: dot, item: Metadata(key: entry.key, origin: entry.origin, size: entry.size),
                        version: query.version, minimumScore: minimumScore, diagnosticLimit: diagnosticLimit,
                        matches: &matches, diagnostics: &diagnostics)
            }
        }
        return VectorSearchResult(matches: matches.sorted(by: ranked), diagnostics: diagnostics)
    }

    private nonisolated static func scan(query: Fingerprint, vectors: [Float], metadata: [Metadata],
                                         minimumScore: Double, diagnosticLimit: Int) throws -> VectorSearchResult {
        guard diagnosticLimit >= 0, minimumScore.isFinite, (-1...1).contains(minimumScore),
              vectors.count == metadata.count * 1024 else {
            throw AdvancedDedupError.invalidConfiguration
        }
        var matches = [ScoredCandidate]()
        var diagnostics = [ScoredCandidate]()
        query.values.withUnsafeBufferPointer { q in
            vectors.withUnsafeBufferPointer { data in
                for index in metadata.indices {
                    var dot: Float = 0
                    vDSP_dotpr(q.baseAddress!, 1, data.baseAddress!.advanced(by: index * 1024),
                               1, &dot, 1024)
                    collect(dot: dot, item: metadata[index], version: query.version,
                            minimumScore: minimumScore, diagnosticLimit: diagnosticLimit,
                            matches: &matches, diagnostics: &diagnostics)
                }
            }
        }
        return VectorSearchResult(matches: matches.sorted(by: ranked), diagnostics: diagnostics)
    }

    private nonisolated static func collect(dot: Float, item: Metadata, version: String,
                                            minimumScore: Double, diagnosticLimit: Int,
                                            matches: inout [ScoredCandidate], diagnostics: inout [ScoredCandidate]) {
        let score = Double(dot)
        guard score.isFinite else { return }
        let candidate = ScoredCandidate(key: item.key, origin: item.origin,
            score: score, size: item.size, fingerprintVersion: version)
        if score >= minimumScore { matches.append(candidate) }
        if diagnosticLimit > 0 {
            diagnostics.append(candidate)
            diagnostics.sort(by: ranked)
            if diagnostics.count > diagnosticLimit { diagnostics.removeLast() }
        }
    }

    private nonisolated static func ranked(_ lhs: ScoredCandidate, _ rhs: ScoredCandidate) -> Bool {
        lhs.score == rhs.score ? lhs.key < rhs.key : lhs.score > rhs.score
    }
}
