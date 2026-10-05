import XCTest
@testable import PhotoSyncCore

final class DedupLoggingTests: XCTestCase {
    func testLogsBelowThresholdScoreAndSignedMarginWithoutRounding() throws {
        let c = try p8Configuration()
        let score = 0.979987654321
        let candidate = ScoredCandidate(key: "near", origin: .photosCurrent, score: score,
            size: try PixelSize(width: 4000, height: 3000), fingerprintVersion: c.fingerprint.version)
        let e = p8Evidence(configuration: c, diagnostics: [candidate])
        let fields = DedupDecisionLog.fields(evidence: e, configuration: c)
        XCTAssertEqual(Double(fields["diagnostic.0.score"] ?? ""), score)
        XCTAssertEqual(Double(fields["diagnostic.0.margin"] ?? ""), score - c.threshold)
        XCTAssertEqual(fields["acceptanceID"], c.acceptanceID)
        XCTAssertEqual(fields["diagnostic.0.width"], "4000")
        XCTAssertNil(fields["vector"])
    }

    func testDiagnosticCapNeverDropsDecisiveCandidate() throws {
        let c = try p8Configuration()
        let candidates = (0..<20).map { ScoredCandidate(key: "near-\($0)", origin: .localPending,
            score: 0.99, size: nil, fingerprintVersion: c.fingerprint.version) }
        let decisive = ScoredCandidate(key: "cover-outside-ten", origin: .photosOriginal,
            score: 0.981, size: nil, fingerprintVersion: c.fingerprint.version)
        let fields = DedupDecisionLog.fields(evidence: p8Evidence(configuration: c,
            decisive: [decisive], diagnostics: candidates), configuration: c)
        XCTAssertEqual(fields["diagnosticCount"], "10")
        XCTAssertEqual(fields["decisive.0.key"], decisive.key)
        XCTAssertNil(fields["diagnostic.10.key"])
    }

    func testNoCandidateIsAbsentNotZeroScore() throws {
        let c = try p8Configuration()
        let fields = DedupDecisionLog.fields(evidence: p8Evidence(configuration: c), configuration: c)
        XCTAssertEqual(fields["diagnosticCount"], "0")
        XCTAssertEqual(fields["candidateAbsence"], "noCandidates")
        XCTAssertNil(fields["diagnostic.0.score"])
        XCTAssertEqual(fields["content"], "notDuplicate")
    }

    func testLogsImportsAsWellAsSkipsAndDeduplicatesSameEvidence() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = try RunLogger(directory: root), c = try p8Configuration()
        let e = p8Evidence(configuration: c)
        logger.logDecision(e, configuration: c)
        logger.logDecision(p8Evidence(configuration: c, fileID: e.fileID, token: e.token), configuration: c)
        let skip = p8Evidence(configuration: c, action: .skip)
        logger.logDecision(skip, configuration: c)
        logger.flushForTesting()
        let lines = try String(contentsOf: root.appendingPathComponent("photo-sync.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.contains { $0.contains("importFile") })
        XCTAssertTrue(lines.contains { $0.contains("skip") })
    }

    func testPolicyChangeCreatesNewDiagnosticEvent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = try RunLogger(directory: root), c = try p8Configuration()
        let e = p8Evidence(configuration: c)
        let changed = try p8Configuration(threshold: 0.97)
        logger.logDecision(e, configuration: c)
        logger.logDecision(p8Evidence(configuration: changed, fileID: e.fileID, token: e.token), configuration: changed)
        logger.flushForTesting()
        let lines = try String(contentsOf: root.appendingPathComponent("photo-sync.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
    }
}

func p8Configuration(threshold: Double = 0.98) throws -> DedupConfiguration {
    let f = try FingerprintConfiguration(modelSHA256: String(repeating: "a", count: 64), inputSide: 320,
        resizeMode: .stretchFullFrame, colorSpace: "sRGB", mean: [0.485, 0.456, 0.406], std: [0.229, 0.224, 0.225])
    return try DedupConfiguration(fingerprint: f,
        policyVersion: DedupConfiguration.computePolicyVersion(fingerprintVersion: f.version, threshold: threshold, backend: "exact-f32-v1"),
        threshold: threshold, backend: "exact-f32-v1",
        resources: ResourceLimits(decodeConcurrency: 1, photoRequestConcurrency: 1, maxDecodedBytes: 536870912,
            requestTimeoutSeconds: 30, retryDelaysSeconds: [5, 15, 30, 60], catalogBatchSize: 128,
            maxInFlightTasks: 2, progressPublishIntervalSeconds: 1, inferenceConcurrency: 1, batchSize: 1),
        evidenceCandidateLimit: 200000, acceptanceID: "test-user-decision")
}

private func p8Evidence(configuration c: DedupConfiguration, fileID: UUID = UUID(), token: IndexToken? = nil,
                        action: ImportAction = .importFile, decisive: [ScoredCandidate] = [], diagnostics: [ScoredCandidate] = []) -> AdvancedEvidence {
    AdvancedEvidence(eventID: UUID(), fileID: fileID, stamp: FileStamp(size: 123, modifiedNanoseconds: 456),
        token: token ?? IndexToken(context: LibraryContext(id: UUID(), epoch: 1), photosGeneration: 2,
            indexGeneration: 3, localRevision: 4, fingerprintVersion: c.fingerprint.version),
        policyVersion: c.policyVersion, evaluation: DuplicateEvaluation(content: action == .skip ? .duplicate : .notDuplicate,
            action: action, reason: action == .skip ? .covered : .noMatch, matchedKeys: [], coveringKeys: []),
        decisiveCandidates: decisive, diagnostics: diagnostics, timingsMS: ["total": 1.234567890123])
}

extension DedupLoggingTests {
    func testLogFailureReportsWarningWithoutThrowingDecision() throws {
        let root = try temporaryDirectory()
        let failed = expectation(description: "best-effort logging warning")
        let logger = try RunLogger(directory: root, onFailure: { _ in failed.fulfill() })
        try FileManager.default.removeItem(at: root)
        let c = try p8Configuration()
        logger.logDecision(p8Evidence(configuration: c), configuration: c)
        logger.flushForTesting()
        wait(for: [failed], timeout: 1)
    }

    func testCloudWaitRequiresExplicitCloudOrNetworkSignal() {
        let timeout = ReadExecutorError.timedOut
        XCTAssertEqual(SystemPhotosRepresentationRequester.classifyUnavailable(error: timeout, inCloud: false) as? ReadExecutorError, timeout)
        XCTAssertEqual(SystemPhotosRepresentationRequester.classifyUnavailable(error: PhotosRepresentationError.invalidImage, inCloud: false) as? PhotosRepresentationError, .invalidImage)
        for (error, inCloud) in [(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), false),
                                 (NSError(domain: "PhotoKit", code: 1), true)] {
            guard case .iCloudUnavailable = SystemPhotosRepresentationRequester.classifyUnavailable(error: error, inCloud: inCloud) as? PhotosRepresentationError else {
                return XCTFail("Explicit cloud/network evidence must survive to aggregate presentation")
            }
        }
    }

    func testReconcileDiagnosticCountsAreCommittedRepresentationMutations() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SyncStore(url: root.appendingPathComponent("test.sqlite"))
        let context = LibraryContext(id: UUID(), epoch: 1)
        func descriptor(_ id: String, revision: String = "one") -> RepresentationDescriptor {
            .init(key: .init(assetID: id, kind: .original), context: context, revision: revision,
                  size: nil, equivalentToOriginal: false, revisionIsReliable: true)
        }
        let first = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: "v1")
        let initial = try await store.upsertRepresentations([descriptor("a"), descriptor("b")], generation: first)
        XCTAssertEqual(initial.added, 2); XCTAssertEqual(initial.changed, 0)
        let firstEnd = try await store.finishIndexReconciliation(generation: first)
        XCTAssertEqual(firstEnd?.deleted, 0)
        let second = try await store.beginIndexReconciliation(context: context, photosGeneration: 2, fingerprintVersion: "v1")
        let changes = try await store.upsertRepresentations([descriptor("a", revision: "two"), descriptor("c")], generation: second)
        XCTAssertEqual(changes.added, 1); XCTAssertEqual(changes.changed, 1)
        let secondEnd = try await store.finishIndexReconciliation(generation: second)
        XCTAssertEqual(secondEnd?.deleted, 1)
        let stale = try await store.finishIndexReconciliation(generation: first)
        XCTAssertNil(stale, "Stale finalization must not manufacture committed zero counts")
    }
}
