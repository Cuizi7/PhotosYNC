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
