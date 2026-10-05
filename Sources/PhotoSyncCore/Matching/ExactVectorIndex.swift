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
        var next = [Float]()
        next.reserveCapacity(entries.count * 1024)
        for entry in entries { next.append(contentsOf: entry.fingerprint.values) }
        vectors = next
        metadata = entries.map { Metadata(key: $0.key, origin: $0.origin, size: $0.size) }
        self.generation = generation
    }

    /// Publication must match both the installed generation and its full vector count.
    public func containsGeneration(_ generation: Int64, entryCount: Int) -> Bool {
        self.generation == generation && metadata.count == entryCount && vectors.count == entryCount * 1024
    }

    public func search(query: Fingerprint, minimumScore: Double, generation: Int64) throws -> [ScoredCandidate] {
        guard self.generation == generation, query.version == version else {
            throw AdvancedDedupError.modelMismatch
        }
        return try Self.scan(query: query, vectors: vectors, metadata: metadata,
                             minimumScore: minimumScore)
    }

    /// Same Float32 Accelerate path used for an unindexed local/history candidate view.
    public nonisolated static func score(query: Fingerprint, entries: [VectorEntry],
                                         minimumScore: Double) throws -> [ScoredCandidate] {
        guard entries.allSatisfy({ !$0.key.isEmpty && $0.fingerprint.version == query.version }),
              Set(entries.map(\.key)).count == entries.count else {
            throw AdvancedDedupError.modelMismatch
        }
        var vectors = [Float]()
        vectors.reserveCapacity(entries.count * 1024)
        for entry in entries { vectors.append(contentsOf: entry.fingerprint.values) }
        let metadata = entries.map { Metadata(key: $0.key, origin: $0.origin, size: $0.size) }
        return try scan(query: query, vectors: vectors, metadata: metadata,
                        minimumScore: minimumScore)
    }

    private nonisolated static func scan(query: Fingerprint, vectors: [Float], metadata: [Metadata],
                                         minimumScore: Double) throws -> [ScoredCandidate] {
        guard minimumScore.isFinite, (-1...1).contains(minimumScore),
              vectors.count == metadata.count * 1024 else {
            throw AdvancedDedupError.invalidConfiguration
        }
        var matches = [ScoredCandidate]()
        query.values.withUnsafeBufferPointer { q in
            vectors.withUnsafeBufferPointer { data in
                for index in metadata.indices {
                    var dot: Float = 0
                    vDSP_dotpr(q.baseAddress!, 1, data.baseAddress!.advanced(by: index * 1024),
                               1, &dot, 1024)
                    let score = Double(dot)
                    if score.isFinite && score >= minimumScore {
                        let item = metadata[index]
                        matches.append(ScoredCandidate(key: item.key, origin: item.origin,
                            score: score, size: item.size, fingerprintVersion: query.version))
                    }
                }
            }
        }
        return matches.sorted { $0.score == $1.score ? $0.key < $1.key : $0.score > $1.score }
    }
}
