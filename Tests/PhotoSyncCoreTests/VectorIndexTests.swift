import XCTest
@testable import PhotoSyncCore

final class VectorIndexTests: XCTestCase {
    private func vector(_ first: Float, _ second: Float, version: String = "v1") throws -> Fingerprint {
        try Fingerprint(version: version, values: [first, second] + [Float](repeating: 0, count: 1022))
    }

    func testGenerationOrVersionMismatchThrows() async throws {
        let index = ExactVectorIndex(version: "v1")
        let entry = VectorEntry(key: "one", origin: .photosCurrent,
                                fingerprint: try vector(1, 0), size: nil)
        try await index.replace(entries: [entry], generation: 2)
        do {
            try await index.replace(entries: [], generation: 1)
            XCTFail("stale replacement displaced the current gallery")
        } catch AdvancedDedupError.modelMismatch {}
        do {
            _ = try await index.search(query: vector(1, 0), minimumScore: 0.8, generation: 1)
            XCTFail("stale generation returned an empty candidate view")
        } catch AdvancedDedupError.modelMismatch {}
        do {
            _ = try await index.search(query: vector(1, 0, version: "v2"), minimumScore: 0.8, generation: 2)
            XCTFail("different vector version returned an empty candidate view")
        } catch AdvancedDedupError.modelMismatch {}
    }

    func testRejectedReplacementPreservesPriorViewThenSupportsGrowthAndShrink() async throws {
        let index = ExactVectorIndex(version: "v1")
        let query = try vector(1, 0)
        let original = VectorEntry(key: "original", origin: .photosOriginal, fingerprint: query, size: nil)
        try await index.replace(entries: [original], generation: 4)
        for invalid in [[original, original],
                        [VectorEntry(key: "", origin: .photosCurrent, fingerprint: query, size: nil)],
                        [VectorEntry(key: "new", origin: .photosCurrent, fingerprint: try vector(1, 0, version: "v2"), size: nil)]] {
            do {
                try await index.replace(entries: invalid, generation: 5)
                XCTFail("Invalid replacement was accepted")
            } catch AdvancedDedupError.modelMismatch {}
            let current = try await index.search(query: query, minimumScore: 0.8, generation: 4)
            XCTAssertEqual(current.map(\.key), ["original"])
        }
        let grown = (0..<20).map { VectorEntry(key: "item-\($0)", origin: .photosCurrent, fingerprint: query, size: nil) }
        try await index.replace(entries: grown, generation: 5)
        let results = try await index.search(query: query, minimumScore: 0.8, generation: 5)
        XCTAssertEqual(results.count, 20)
        try await index.replace(entries: [], generation: 6)
        let empty = try await index.search(query: query, minimumScore: 0.8, generation: 6)
        XCTAssertTrue(empty.isEmpty)
        try await index.replace(entries: [original], generation: 7)
        let restored = try await index.search(query: query, minimumScore: 0.8, generation: 7)
        XCTAssertEqual(restored.map(\.key), ["original"])
    }

    func testLocalAndPublishedScoresRetainEveryMatchAndGlobalDiagnostics() async throws {
        let query = try vector(1, 0)
        var entries = (0..<14).reversed().map {
            VectorEntry(key: String(format: "tie-%02d", $0), origin: .successHistory, fingerprint: query, size: nil)
        }
        entries.append(VectorEntry(key: "below", origin: .localPending, fingerprint: try vector(0, 1), size: nil))
        let index = ExactVectorIndex(version: "v1")
        try await index.replace(entries: entries, generation: 1)
        let local = try ExactVectorIndex.scoreWithDiagnostics(query: query, entries: entries, minimumScore: 0.8, diagnosticLimit: 10)
        let published = try await index.searchWithDiagnostics(query: query, minimumScore: 0.8, generation: 1, diagnosticLimit: 10)
        XCTAssertEqual(local.matches.map(\.key), (0..<14).map { String(format: "tie-%02d", $0) })
        XCTAssertEqual(local.diagnostics.map(\.key), (0..<10).map { String(format: "tie-%02d", $0) })
        XCTAssertEqual(local.matches, published.matches)
        XCTAssertEqual(local.diagnostics, published.diagnostics)
        XCTAssertThrowsError(try ExactVectorIndex.scoreWithDiagnostics(query: query, entries: entries, minimumScore: .nan, diagnosticLimit: 10))
        XCTAssertThrowsError(try ExactVectorIndex.scoreWithDiagnostics(query: query, entries: entries, minimumScore: 0.8, diagnosticLimit: -1))
    }

    func testExactScoreReturnsEveryMatchInStableOrder() throws {
        let query = try vector(1, 0)
        let entries = [VectorEntry(key: "z", origin: .photosOriginal, fingerprint: query, size: nil),
                       VectorEntry(key: "a", origin: .photosCurrent, fingerprint: query, size: nil),
                       VectorEntry(key: "other", origin: .photosCurrent,
                                   fingerprint: try vector(0, 1), size: nil)]
        let scored = try ExactVectorIndex.score(query: query, entries: entries, minimumScore: 0.8)
        XCTAssertEqual(scored.map(\.key), ["a", "z"])
    }
}
