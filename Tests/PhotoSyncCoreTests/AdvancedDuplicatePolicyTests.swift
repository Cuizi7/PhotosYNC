import XCTest
@testable import PhotoSyncCore

final class AdvancedDuplicatePolicyTests: XCTestCase {
    private func configuration() throws -> DedupConfiguration {
        let fingerprint = try FingerprintConfiguration(modelSHA256: String(repeating: "a", count: 64),
            inputSide: 320, resizeMode: .stretchFullFrame, colorSpace: "sRGB",
            mean: [0, 0, 0], std: [1, 1, 1])
        let resources = try ResourceLimits(decodeConcurrency: 1, photoRequestConcurrency: 1,
            maxDecodedBytes: 1, requestTimeoutSeconds: 1, retryDelaysSeconds: [1],
            catalogBatchSize: 1, maxInFlightTasks: 1, progressPublishIntervalSeconds: 1,
            inferenceConcurrency: 1, batchSize: 1)
        return try DedupConfiguration(fingerprint: fingerprint,
            policyVersion: DedupConfiguration.computePolicyVersion(fingerprintVersion: fingerprint.version,
                threshold: 0.8, backend: "exact-f32-v1"), threshold: 0.8,
            backend: "exact-f32-v1", resources: resources, evidenceCandidateLimit: 5,
            acceptanceID: "research:test")
    }

    private func candidate(_ key: String, _ score: Double, _ size: PixelSize?,
                           _ version: String) -> ScoredCandidate {
        ScoredCandidate(key: key, origin: .photosOriginal, score: score,
                        size: size, fingerprintVersion: version)
    }

    func testFindsCoveringCandidateBeyondTopOne() throws {
        let config = try configuration()
        let decision = try AdvancedDuplicatePolicy.evaluate(sourceSize: PixelSize(width: 2000, height: 1500),
            candidates: [candidate("small", 0.99, PixelSize(width: 640, height: 480), config.fingerprint.version),
                         candidate("cover", 0.95, PixelSize(width: 4000, height: 3000), config.fingerprint.version)],
            configuration: config)
        XCTAssertEqual(decision.action, .skip)
        XCTAssertEqual(decision.matchedKeys, ["small", "cover"])
        XCTAssertEqual(decision.coveringKeys, ["cover"])
    }

    func testHighResolutionCopyImports() throws {
        let config = try configuration()
        let upgrade = try AdvancedDuplicatePolicy.evaluate(sourceSize: PixelSize(width: 4000, height: 3000),
            candidates: [candidate("lower", 0.95, PixelSize(width: 2000, height: 1500), config.fingerprint.version)],
            configuration: config)
        XCTAssertEqual(upgrade.content, .duplicate)
        XCTAssertEqual(upgrade.action, .importFile)
        XCTAssertEqual(upgrade.reason, .resolutionUpgrade)
    }

    func testUnknownOrCrossedSizesImport() throws {
        let config = try configuration()
        let source = try PixelSize(width: 2000, height: 1500)
        for size in [nil, try PixelSize(width: 3000, height: 1000)] {
            let result = try AdvancedDuplicatePolicy.evaluate(sourceSize: source,
                candidates: [candidate("match", 0.9, size, config.fingerprint.version)], configuration: config)
            XCTAssertEqual(result.action, .importFile)
            XCTAssertEqual(result.reason, .insufficientSizeEvidence)
        }
        let unknownSource = try AdvancedDuplicatePolicy.evaluate(sourceSize: nil,
            candidates: [candidate("match", 0.9, try PixelSize(width: 4000, height: 3000),
                                   config.fingerprint.version)], configuration: config)
        XCTAssertEqual(unknownSource.action, .importFile)
        XCTAssertEqual(unknownSource.reason, .insufficientSizeEvidence)
    }

    func testOneEqualEdgeIsResolutionUpgradeInEitherOrientation() throws {
        let config = try configuration()
        for source in [try PixelSize(width: 4000, height: 2000),
                       try PixelSize(width: 2000, height: 4000)] {
            let result = try AdvancedDuplicatePolicy.evaluate(sourceSize: source,
                candidates: [candidate("lower", 0.9,
                                       try PixelSize(width: 3000, height: 2000),
                                       config.fingerprint.version)], configuration: config)
            XCTAssertEqual(result.content, .duplicate)
            XCTAssertEqual(result.action, .importFile)
            XCTAssertEqual(result.reason, .resolutionUpgrade)
        }
    }
}
