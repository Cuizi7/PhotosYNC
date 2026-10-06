import XCTest
import CryptoKit
import ImageIO
import Darwin
import SQLite3
import TestSQLiteMetrics
@testable import PhotoSyncCore

final class AdvancedDedupRegressionTests: XCTestCase {
    func testBundledApprovedConfigurationAndExactModel() throws {
        let root = try DedupConfiguration.bundledResourceDirectory()
        let configuration = try DedupConfiguration.loadValidated(resourceDirectory: root)
        XCTAssertEqual(configuration.threshold, 0.98)
        XCTAssertEqual(configuration.resources.maxDecodedBytes, 536870912)
        XCTAssertEqual(CoreMLFingerprinter.packageSHA256(root.appendingPathComponent("SSCDLarge.mlpackage")), configuration.fingerprint.modelSHA256)
        let notice = try Data(contentsOf: root.appendingPathComponent("LICENSE-SSCD.txt"))
        XCTAssertEqual(SHA256.hash(data: notice).map { String(format: "%02x", $0) }.joined(), "da6d3703ed11cbe42bd212c725957c98da23cbff1998c05fa4b3d976d1a58e93")
    }
}

extension AdvancedDedupRegressionTests {
    /// Local saved-vector replay, separate from the opt-in new model inference below.
    func testExistingVectorReplayUsesSQLiteBackend() async throws {
        guard let batchPath = ProcessInfo.processInfo.environment["PHOTOSYNC_SQLITE_REPLAY_BATCH"],
              let profilePath = ProcessInfo.processInfo.environment["PHOTOSYNC_SQLITE_REPLAY_PROFILE"] else {
            throw XCTSkip("Saved-vector replay requires explicit local inputs")
        }
        let config = try JSONDecoder().decode(DedupConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: profilePath)))
        let batch = try p9JSON(URL(fileURLWithPath: batchPath))
        let cases = try XCTUnwrap(batch["queries"] as? [[String: Any]])
        var results = [[String: Any]]()
        func vector(_ record: [String: Any]) throws -> Fingerprint {
            let url = URL(fileURLWithPath: record["vector"] as! String)
            XCTAssertEqual(try p9Hash(url), record["vectorSHA256"] as? String)
            return try Fingerprint(version: config.fingerprint.version, littleEndianFloat32: Data(contentsOf: url))
        }
        func size(_ record: [String: Any]) throws -> PixelSize? {
            guard let pixels = record["size"] as? [String: Int] else { return nil }
            return try PixelSize(width: XCTUnwrap(pixels["width"]), height: XCTUnwrap(pixels["height"]))
        }
        for item in cases {
            let query = try vector(item)
            let candidates = try XCTUnwrap(item["candidates"] as? [[String: Any]])
            let entries = try candidates.map { record in
                VectorEntry(key: record["key"] as! String, origin: .photosOriginal, fingerprint: try vector(record), size: try size(record))
            }
            let actual = try await p10SQLiteSearch(query: query, entries: entries, configuration: config)
            let framed = entries.map { VectorEntry(key: "photos:\($0.key.utf8.count):\($0.key):original", origin: $0.origin, fingerprint: $0.fingerprint, size: $0.size) }
            let oracle = try ExactVectorIndex.scoreWithDiagnostics(query: query, entries: framed, minimumScore: config.threshold, diagnosticLimit: 10)
            XCTAssertEqual(actual, oracle)
            let decision = try AdvancedDuplicatePolicy.evaluate(sourceSize: size(item), candidates: actual.matches, configuration: config)
            results.append(["id": item["id"]!, "content": decision.content.rawValue,
                "action": decision.action.rawValue, "queryVectorSHA256": item["vectorSHA256"]!,
                "candidates": actual.diagnostics.map { candidate in
                    let original = entries.first { "photos:\($0.key.utf8.count):\($0.key):original" == candidate.key }!
                    return ["key": candidate.key, "origin": candidate.origin.rawValue, "score": candidate.score,
                            "vectorSHA256": SHA256.hash(data: original.fingerprint.littleEndianFloat32).map { String(format: "%02x", $0) }.joined()] as [String: Any]
                }])
        }
        XCTAssertEqual(results.count, 33)
        try p9WriteEvidence("sqlite-vector-replay.json", ["backend": config.backend, "policyVersion": config.policyVersion,
            "fingerprintVersion": config.fingerprint.version, "newImageInference": false,
            "independentValidation": false, "cases": results, "batchSHA256": try p9Hash(URL(fileURLWithPath: batchPath))])
    }

    /// Local opt-in only: canonical validation supplies the authorized fixture path.
    /// Ordinary tests never load user photographs; public CI must not opt in.
    func testFrozenCorpusContentAndActions() async throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTOSYNC_REGRESSION_DATASET"] else {
            throw XCTSkip("Local 33-case corpus requires explicit validation environment")
        }
        let corpus = URL(fileURLWithPath: path), root = try DedupConfiguration.bundledResourceDirectory()
        let config = try DedupConfiguration.loadValidated(resourceDirectory: root)
        let decision = try p9JSON(root.appendingPathComponent("decision.json"))
        let binding = try XCTUnwrap(decision["activeSuite"] as? [String: Any])
        for (name, key) in [("active-suite.json", "sha256"), ("manifest.json", "manifestSHA256"),
                            ("expected-results.json", "expectedResultsSHA256"), ("human-review.json", "humanReviewSHA256")] {
            guard try p9Hash(corpus.appendingPathComponent(name)) == binding[key] as? String else {
                return XCTFail("Frozen corpus binding mismatch: \(name)")
            }
        }
        let active = try p9JSON(corpus.appendingPathComponent("active-suite.json"))
        let ids = Set(try XCTUnwrap(active["kept_case_ids"] as? [String]))
        let truth = try XCTUnwrap(p9JSON(corpus.appendingPathComponent("expected-results.json"))["cases"] as? [[String: Any]])
            .filter { ids.contains($0["id"] as! String) }
        XCTAssertEqual(truth.count, 33)
        let images = try XCTUnwrap(p9JSON(corpus.appendingPathComponent("manifest.json"))["images"] as? [[String: Any]])
        let records = Dictionary(uniqueKeysWithValues: images.map { ($0["id"] as! String, $0) })
        let used = Set(truth.flatMap { [$0["query"] as! String] + ($0["candidates"] as! [String]) })
        XCTAssertEqual(used.count, 42)
        let coldStart = ProcessInfo.processInfo.systemUptime
        let model = try CoreMLFingerprinter(modelURL: root.appendingPathComponent("SSCDLarge.mlpackage"), configuration: config.fingerprint)
        let loadMS = (ProcessInfo.processInfo.systemUptime - coldStart) * 1000
        var vectors = [String: Fingerprint](), sizes = [String: PixelSize](), timings = [Double]()
        var inputs = [[String: Any]]()
        let reader = MetadataReader(), budget = ImageWorkBudget(limits: config.resources)
        for id in used.sorted() {
            let record = try XCTUnwrap(records[id])
            let url = corpus.appendingPathComponent(record["file"] as! String)
            guard try p9Hash(url) == record["sha256"] as? String else {
                return XCTFail("Frozen image bytes mismatch: \(id)")
            }
            let loaded = try await reader.readForFingerprint(url: url, configuration: config, budget: budget)
            let start = ProcessInfo.processInfo.systemUptime
            vectors[id] = try await model.fingerprint(image: loaded.value.image, orientation: loaded.value.orientation)
            inputs.append(["id": id, "input_sha256": record["sha256"]!,
                "vector_sha256": SHA256.hash(data: vectors[id]!.littleEndianFloat32).map { String(format: "%02x", $0) }.joined(),
                "decoded_width": loaded.value.image.width, "decoded_height": loaded.value.image.height,
                "orientation": loaded.value.orientation.rawValue,
                "color_space": loaded.value.image.colorSpace?.name as String? ?? "unknown"])
            await loaded.lease.finishPhysicalWork()
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            sizes[id] = try PixelSize(width: record["width"] as! Int, height: record["height"] as! Int)
        }
        var results = [[String: Any]](), duplicates = 0, skips = 0
        for item in truth {
            let query = item["query"] as! String, expected = item["expected"] as! [String: String]
            let entries = try (item["candidates"] as! [String]).map { id in
                VectorEntry(key: id, origin: .photosOriginal, fingerprint: try XCTUnwrap(vectors[id]), size: sizes[id])
            }
            let search = try await p10SQLiteSearch(query: XCTUnwrap(vectors[query]), entries: entries, configuration: config)
            let oracle = try ExactVectorIndex.scoreWithDiagnostics(query: XCTUnwrap(vectors[query]), entries: entries.map {
                VectorEntry(key: "photos:\($0.key.utf8.count):\($0.key):original", origin: $0.origin, fingerprint: $0.fingerprint, size: $0.size)
            }, minimumScore: config.threshold, diagnosticLimit: 10)
            XCTAssertEqual(search, oracle)
            let result = try AdvancedDuplicatePolicy.evaluate(sourceSize: sizes[query], candidates: search.matches, configuration: config)
            let content = result.content == .duplicate ? "duplicate" : "not_duplicate"
            let action = result.action == .skip ? "skip" : "import"
            XCTAssertEqual(content, expected["content_result"], item["id"] as! String)
            XCTAssertEqual(action, expected["action"], item["id"] as! String)
            duplicates += result.content == .duplicate ? 1 : 0; skips += result.action == .skip ? 1 : 0
            results.append(["id": item["id"]!, "content": content, "action": action,
                            "candidate_scores": search.diagnostics.map(\.score)])
        }
        XCTAssertEqual(duplicates, 14); XCTAssertEqual(33 - duplicates, 19)
        XCTAssertEqual(skips, 11); XCTAssertEqual(33 - skips, 22)
        try p9WriteEvidence("model-regression.json", ["cases": results, "case_count": results.count,
            "duplicate_count": duplicates, "skip_count": skips, "unique_images": used.count,
            "model_load_compile_ms": loadMS, "fingerprint_ms": p9Percentiles(timings),
            "model_sha256": config.fingerprint.modelSHA256, "acceptance_id": config.acceptanceID,
            "inputs": inputs, "backend": config.backend, "policy_version": config.policyVersion,
            "new_image_inference": true, "statistical_acceptance": "not_performed", "rss_peak_bytes": p9PeakRSS()])
    }
}

private func p10SQLiteSearch(query: Fingerprint, entries: [VectorEntry], configuration: DedupConfiguration) async throws -> VectorSearchResult {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SyncStore(url: root.appendingPathComponent("query.sqlite"))
    let source = try await store.registerSource(url: root)
    let incoming = SourceFile(sourceID: source, relativePath: "query.jpg", url: root.appendingPathComponent("query.jpg"),
        stamp: .init(size: 1, modifiedNanoseconds: 1), metadata: .init(filename: "query.jpg", kind: .image,
            captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: nil, height: nil, duration: nil))
    let fileID = try await store.save(incoming, decision: .importNew)
    let context = LibraryContext(id: UUID(), epoch: 1)
    let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: query.version)
    try await store.upsertRepresentations(entries.map {
        RepresentationDescriptor(key: .init(assetID: $0.key, kind: .original), context: context, revision: "fixed-replay",
            size: $0.size, equivalentToOriginal: false, revisionIsReliable: true)
    }, generation: generation)
    let tasks = try await store.nextRepresentationTasks(now: Date(), limit: max(1, entries.count))
    for task in tasks {
        let fingerprint = try XCTUnwrap(entries.first { $0.key == task.descriptor.key.assetID }?.fingerprint)
        let completed = try await store.completeRepresentation(task, fingerprint: fingerprint)
        XCTAssertTrue(completed)
    }
    try await store.finishIndexReconciliation(generation: generation, seenKeys: Set((entries.map {
        RepresentationDescriptor(key: .init(assetID: $0.key, kind: .original), context: context, revision: "fixed-replay",
            size: $0.size, equivalentToOriginal: false, revisionIsReliable: true)
    }).map(\.key)))
    let value = try await store.indexPublication(), publication = try XCTUnwrap(value)
    let published = try await store.markIndexPublished(token: publication.token); XCTAssertTrue(published)
    let result = try await store.vectorCandidates(for: fileID, query: query, token: publication.token,
        threshold: configuration.threshold, diagnosticLimit: 10)
    return try XCTUnwrap(result)
}

private func p9JSON(_ url: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}
private func p9Hash(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
func p9Percentiles(_ values: [Double]) -> [String: Double] {
    let ordered = values.sorted()
    return ["p50": ordered[max(0, Int(ceil(Double(ordered.count) * 0.5)) - 1)],
            "p95": ordered[max(0, Int(ceil(Double(ordered.count) * 0.95)) - 1)],
            "p99": ordered[max(0, Int(ceil(Double(ordered.count) * 0.99)) - 1)]]
}
func p9WriteEvidence(_ name: String, _ value: [String: Any]) throws {
    guard let root = ProcessInfo.processInfo.environment["PHOTOSYNC_ACCEPTANCE_OUTPUT"] else { return }
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        .write(to: URL(fileURLWithPath: root).appendingPathComponent(name))
}
func p9PeakRSS() -> Int64 {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Int64(usage.ru_maxrss)
}

extension AdvancedDedupRegressionTests {
    func testNonemptyRuntimeGraphReopensLegacyAndMeasuresControlledWork() async throws {
        let root = try temporaryDirectory(), source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let c = try DedupConfiguration.loadValidated(resourceDirectory: DedupConfiguration.bundledResourceDirectory())
        let executor = ReadExecutor(), budget = ImageWorkBudget(limits: c.resources)
        let db = root.appendingPathComponent("test.sqlite"), store = try SyncStore(url: db, readExecutor: executor)
        let sourceID = try await store.registerSource(url: source)
        let directory = DirectoryReader(sourceID: sourceID, executor: executor)
        let metadata = MetadataReader(sourceID: sourceID, executor: executor)
        let a = try p9Image(style: 0), b = try p9Image(style: 1)
        let legacyURL = source.appendingPathComponent("legacy.png")
        try p9PNG(b, at: legacyURL)
        let legacy = SourceFile(sourceID: sourceID, relativePath: "legacy.png", url: legacyURL,
            stamp: try await directory.stamp(of: legacyURL), metadata: try await metadata.read(url: legacyURL, filename: "legacy.png"))
        let legacyID = try await store.save(legacy, decision: .importNew)
        try await store.markSkipped(fileID: legacyID, reason: .suspectedDuplicate, candidates: [])
        let initialHash = try p9Hash(legacyURL)
        let resources = try DedupConfiguration.bundledResourceDirectory()
        let model = P9MeasuredModel(try CoreMLFingerprinter(modelURL: resources.appendingPathComponent("SSCDLarge.mlpackage"), configuration: c.fingerprint))
        let photos = P9FixturePhotos(image: a, budget: budget)
        let holder = P9GraphHolder(), logger = try RunLogger(directory: root.appendingPathComponent("Logs"))
        let runtime = SyncRuntime(store: store, executor: executor, advancedFactory: { store, executor, directory, now, _ in
            let graph = AdvancedRuntimeGraph(store: store, photos: photos, model: model, configuration: c,
                executor: executor, budget: budget, directory: directory, now: now, logger: logger)
            await holder.set(graph); return graph
        }, now: { Date(timeIntervalSince1970: 1000) }, authorized: { true })
        addTeardownBlock { await runtime.stop(); await runtime.waitForRound(); try? FileManager.default.removeItem(at: root) }
        try await runtime.prepareInjectedRuntime()
        let started = ProcessInfo.processInfo.systemUptime
        await runtime.tick(force: true); await runtime.waitForRound()
        let initialMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let state = try await store.state(of: legacyID), creates = await photos.creates
        XCTAssertEqual(state, .imported, "runtime must reopen old skip and submit through normal guarded engine")
        XCTAssertEqual(creates, 1)
        let initialReads = await photos.reads, initialCalls = await model.calls
        XCTAssertEqual(initialReads, 16)
        XCTAssertEqual(initialCalls, 17)
        await runtime.tick(force: true); await runtime.waitForRound()
        let unchangedReads = await photos.reads, unchangedCalls = await model.calls
        XCTAssertEqual(unchangedReads, initialReads); XCTAssertEqual(unchangedCalls, initialCalls)
        await photos.changeOne()
        await runtime.tick(force: true); await runtime.waitForRound()
        let changedReads = await photos.reads, changedCalls = await model.calls
        XCTAssertEqual(changedReads - unchangedReads, 1); XCTAssertEqual(changedCalls - unchangedCalls, 1)
        let capturedGraph = await holder.value
        let graph = try XCTUnwrap(capturedGraph)
        var cold = [Double](), hot = [Double](), stages = [String: [Double]]()
        var lastEvidence: AdvancedEvidence?
        for n in 0..<20 {
            let url = source.appendingPathComponent("load-\(n).png"); try p9PNG(b, at: url)
            let file = SourceFile(sourceID: sourceID, relativePath: url.lastPathComponent, url: url,
                stamp: try await directory.stamp(of: url), metadata: try await metadata.read(url: url, filename: url.lastPathComponent))
            let id = try await store.save(file, decision: .importNew)
            for cached in [false, true] {
                let begin = ProcessInfo.processInfo.systemUptime
                let prepared = try await graph.service.prepare(fileID: id, file: file)
                let elapsed = (ProcessInfo.processInfo.systemUptime - begin) * 1000
                guard case .ready(let admission) = prepared else { return XCTFail("controlled source unexpectedly waiting") }
                lastEvidence = admission.evidence
                if cached { hot.append(elapsed) } else {
                    cold.append(elapsed)
                    for (key, value) in admission.evidence.timingsMS { stages[key, default: []].append(value) }
                }
                logger.logDecision(admission.evidence, configuration: c)
            }
        }
        // Include retained per-file signatures in measured RSS, not just per-event JSON.
        let evidence = try XCTUnwrap(lastEvidence)
        for _ in 0..<5000 {
            logger.logDecision(AdvancedEvidence(eventID: UUID(), fileID: UUID(), stamp: evidence.stamp,
                token: evidence.token, policyVersion: evidence.policyVersion, evaluation: evidence.evaluation,
                decisiveCandidates: evidence.decisiveCandidates, diagnostics: evidence.diagnostics, timingsMS: [:]), configuration: c)
        }
        logger.flushForTesting()
        let lease = await budget.snapshot()
        XCTAssertEqual(lease.images, 0); XCTAssertEqual(lease.bytes, 0)
        XCTAssertEqual(try p9Hash(legacyURL), initialHash)
        XCTAssertLessThan(p9PeakRSS(), 4 * 1024 * 1024 * 1024)
        XCTAssertLessThan(p9Percentiles(hot)["p95"]!, 250)
        XCTAssertLessThan(p9Percentiles(cold)["p95"]!, 2000)
        let diskBytes = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        try p9WriteEvidence("runtime-load.json", ["scope": "injected actual AdvancedRuntimeGraph; synthetic local 256px PNG; fake Photos; real CPU-only model",
            "assets": 16, "representation_rows": 32, "source_samples": 20, "logger_unique_files": 5020,
            "initial_runtime_ms": initialMS, "source_incremental_ms": p9Percentiles(cold), "hot_preparation_ms": p9Percentiles(hot),
            "stages_ms": stages.mapValues(p9Percentiles), "rss_peak_bytes": p9PeakRSS(), "persistent_fixture_bytes": diskBytes,
            "model_timings_ms": p9Percentiles(await model.timings), "unchanged_inferences": unchangedCalls - initialCalls,
            "one_changed_inferences": changedCalls - unchangedCalls, "legacy_imports": creates,
            "real_photos": false, "real_100k_assets": false, "source_unchanged": true])
    }
}

private actor P9GraphHolder {
    var value: AdvancedRuntimeGraph?
    func set(_ graph: AdvancedRuntimeGraph) { value = graph }
}
private actor P9MeasuredModel: ImageFingerprinting {
    let model: CoreMLFingerprinter
    var calls = 0, timings = [Double]()
    var lastInput = [String: Int]()
    init(_ model: CoreMLFingerprinter) { self.model = model }
    func fingerprint(image: CGImage, orientation: CGImagePropertyOrientation) async throws -> Fingerprint {
        let start = ProcessInfo.processInfo.systemUptime
        lastInput = ["width": image.width, "height": image.height, "bits_per_component": image.bitsPerComponent,
                     "bytes_per_row": image.bytesPerRow, "backing_bytes": image.bytesPerRow * image.height]
        let result = try await model.fingerprint(image: image, orientation: orientation)
        calls += 1; timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000); return result
    }
}
private actor P9FixturePhotos: PhotosIndexGateway {
    let context = LibraryContext(id: UUID(), epoch: 1), image: CGImage, budget: ImageWorkBudget
    var generation = 1, reads = 0, creates = 0
    init(image: CGImage, budget: ImageWorkBudget) { self.image = image; self.budget = budget }
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { AsyncStream { _ in } }
    func changeOne() { generation += 1 }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot { .init(generation: generation, candidates: []) }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage {
        let all = (0..<16).flatMap { n in [RepresentationKind.original, .current].map { kind in
            RepresentationDescriptor(key: .init(assetID: "synthetic-\(n)", kind: kind), context: context,
                revision: n == 0 ? "r\(generation)" : "r1", size: try! PixelSize(width: 256, height: 256),
                equivalentToOriginal: true, revisionIsReliable: true)
        } }
        let end = min(offset + limit, all.count)
        return .init(context: context, generation: generation, descriptors: Array(all[offset..<end]), nextOffset: end < all.count ? end : nil)
    }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation {
        reads += 1
        return LoadedRepresentation(image: image, orientation: .up, descriptor: descriptor,
            lease: try await budget.acquire(bytes: Int64(image.bytesPerRow * image.height)), eligibility: .safeSingleFrame)
    }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { throw PhotosAdmissionDeferred() }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int, beforeMutation: @escaping @Sendable () throws -> Bool,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String {
        guard expectedGeneration == generation, try beforeMutation() else { throw PhotosAdmissionDeferred() }
        let id = "synthetic-import-\(creates)"; try onPlaceholder(id); creates += 1; return id
    }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}
private func p9Image(style: Int) throws -> CGImage {
    var pixels = [UInt8](repeating: 255, count: 256 * 256 * 4)
    for y in 0..<256 { for x in 0..<256 {
        let i = (y * 256 + x) * 4
        if style == 0 {
            pixels[i] = UInt8((x * 17 + y * 7) % 256); pixels[i + 1] = UInt8((x ^ y) % 256); pixels[i + 2] = 32
        } else {
            let v: UInt8 = (x / 32 + y / 32) % 2 == 0 ? 230 : 15
            pixels[i] = v; pixels[i + 1] = 40; pixels[i + 2] = 255 - v
        }
    } }
    return try XCTUnwrap(CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}
private func p9PNG(_ image: CGImage, at url: URL) throws {
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
}

extension AdvancedDedupRegressionTests {
    /// Separate process per size prevents a prior size's peak RSS contaminating the next.
    /// Catalog and vectors are synthetic; the graph, database, model and source path are real.
    func testControlledScaleThroughActualGraph() async throws {
        guard let raw = ProcessInfo.processInfo.environment["PHOTOSYNC_SCALE_REPRESENTATIONS"],
              let count = Int(raw), [100000, 150000, 200000].contains(count) else {
            throw XCTSkip("Scale sampling is an explicit canonical subprocess")
        }
        let historyCount = Int(ProcessInfo.processInfo.environment["PHOTOSYNC_SCALE_HISTORY"] ?? "0") ?? 0
        guard historyCount == 0 || (count == 200000 && historyCount == 100000) else { return XCTFail("Unsupported scale fixture") }
        try await runControlledScale(count: count, historyCount: historyCount)
    }

    /// Exercise the measurement/row-audit/restart workflow on two generated rows.
    /// This verifies harness wiring, not any production-scale performance claim.
    func testControlledDeltaMeasurementHarnessSmoke() async throws {
        try await runControlledScale(count: 2, historyCount: 0)
    }

    private func runControlledScale(count: Int, historyCount: Int) async throws {
        let sampleName = historyCount == 0 ? "scale-\(count)" : "scale-\(count)-history-\(historyCount)"
        let root = try temporaryDirectory(), source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var largeURLs = [URL]()
        if count == 200000 {
            for (name, width, height, depth) in [("50mp-8bit.jpg", 8192, 6144, 8), ("61mp-16bit.png", 9600, 6400, 16)] {
                let url = source.appendingPathComponent(name)
                try p9LargeFixture(at: url, width: width, height: height, depth: depth)
                largeURLs.append(url)
            }
        }
        if count == 2 {
            // The smoke must traverse the same post-restart preparation loop as
            // the 200k large-input samples, without allocating a huge fixture.
            let url = source.appendingPathComponent("post-restart-smoke.png")
            try p9PNG(p9Image(style: 1), at: url)
            largeURLs.append(url)
        }
        let resources = try DedupConfiguration.bundledResourceDirectory()
        let c = try DedupConfiguration.loadValidated(resourceDirectory: resources)
        let executor = ReadExecutor(), budget = ImageWorkBudget(limits: c.resources)
        let db = root.appendingPathComponent("scale.sqlite")
        let metrics = try P11SQLiteMetrics(path: db.path)
        let store = try SyncStore(url: db, readExecutor: executor)
        defer { withExtendedLifetime(store) { metrics.stop() } }
        let sourceID = try await store.registerSource(url: source)
        let image = try p9Image(style: 1)
        let model = P9MeasuredModel(try CoreMLFingerprinter(modelURL: resources.appendingPathComponent("SSCDLarge.mlpackage"), configuration: c.fingerprint))
        let seed = try await model.fingerprint(image: image, orientation: .up)
        if historyCount > 0 {
            let historicalRoot = root.appendingPathComponent("retired-source")
            try FileManager.default.createDirectory(at: historicalRoot, withIntermediateDirectories: true)
            let historySource = try await store.registerSource(url: historicalRoot)
            try await store.disableSource(id: historySource)
            try p9SeedHistory(db: db, count: historyCount, sourceID: historySource, seed: seed)
        }
        let photos = P9ScalePhotos(count: count, image: image, budget: budget)
        let context = photos.context
        let generation = try await store.beginIndexReconciliation(context: context, photosGeneration: 1, fingerprintVersion: c.fingerprint.version)
        let seedStart = ProcessInfo.processInfo.systemUptime
        try p9SeedScale(db: db, count: count, context: context, generation: generation, seed: seed)
        let seedMS = (ProcessInfo.processInfo.systemUptime - seedStart) * 1000
        try await store.finishIndexReconciliation(generation: generation, seenKeys: Set((0..<count).map { RepresentationKey(assetID: "asset-\($0 % 100000)", kind: $0 < 100000 ? .original : .current) }),
            checkpoint: LibraryResumeCheckpoint(context: context, archivedChangeToken: Data([9]), photosGeneration: 1))
        let logger = try RunLogger(directory: root.appendingPathComponent("Logs"))
        let graph = AdvancedRuntimeGraph(store: store, photos: photos, model: model, configuration: c,
            executor: executor, budget: budget, directory: { DirectoryReader(sourceID: $0, executor: executor) }, now: { Date() }, logger: logger)
        let publishStart = ProcessInfo.processInfo.systemUptime
        try await graph.coordinator.reconcile()
        let initialEndpoint = try await p9RequireReadyEndpoint(graph.coordinator, store: store,
            expectedPhotosGeneration: 1, expectedRepresentations: count)
        let publishMS = (ProcessInfo.processInfo.systemUptime - publishStart) * 1000
        let readsBefore = await photos.reads, callsBefore = await model.calls
        XCTAssertEqual(readsBefore, 0); XCTAssertEqual(callsBefore, 1)
        var cold = [Double](), hot = [Double](), stages = [String: [Double]](), hotStages = [String: [Double]]()
        var lastEvidence: AdvancedEvidence?
        for n in 0..<20 {
            let url = source.appendingPathComponent("sample-\(n).png"); try p9PNG(image, at: url)
            let directory = DirectoryReader(sourceID: sourceID, executor: executor)
            let metadata = MetadataReader(sourceID: sourceID, executor: executor)
            let file = SourceFile(sourceID: sourceID, relativePath: url.lastPathComponent, url: url,
                stamp: try await directory.stamp(of: url), metadata: try await metadata.read(url: url, filename: url.lastPathComponent))
            let id = try await store.save(file, decision: .importNew)
            for cached in [false, true] {
                let start = ProcessInfo.processInfo.systemUptime
                guard case .ready(let admission) = try await graph.service.prepare(fileID: id, file: file) else {
                    return XCTFail("scale graph source admission not ready")
                }
                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                lastEvidence = admission.evidence
                if cached {
                    hot.append(ms)
                    for (key, value) in admission.evidence.timingsMS { hotStages[key, default: []].append(value) }
                } else {
                    cold.append(ms)
                    for (key, value) in admission.evidence.timingsMS { stages[key, default: []].append(value) }
                }
            }
        }
        let evidence = try XCTUnwrap(lastEvidence)
        var queryTimes: [Double] = []
        let queryBefore = try metrics.snapshot(), queryProcessBefore = try p11ProcessMetrics()
        for _ in 0..<20 {
            let value = try await store.indexReadiness()?.token
            let token = try XCTUnwrap(value)
            let start = ProcessInfo.processInfo.systemUptime
            _ = try await store.vectorCandidates(for: evidence.fileID, query: seed, token: token, threshold: c.threshold, diagnosticLimit: 10)
            queryTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let queryIO = try p11MetricDifference(metrics.snapshot(), queryBefore)
        let queryProcessIO = try p11MetricDifference(p11ProcessMetrics(), queryProcessBefore)
        XCTAssertEqual(queryIO["vfs.write_calls"], 0)
        var changeSamples: [String: [Double]] = [:], changeEndpoints: [String: [String: Int64]] = [:]
        var deltaWrites: [[String: Int64]] = []
        let deltaBefore = try metrics.snapshot(), deltaProcessBefore = try p11ProcessMetrics()
        let filesBefore = try p11PersistentSizes(db)
        let catalogsBefore = await photos.catalogRequests
        for _ in 0..<5 {
            for operation in ["edited", "added", "deleted"] {
                let start = ProcessInfo.processInfo.systemUptime
                let delta: PhotosIndexDelta
                switch operation {
                case "edited": delta = await photos.changeOne()
                case "added": delta = await photos.addOne()
                default: delta = await photos.removeAdded()
                }
                await graph.coordinator.libraryChanged(.incremental(delta))
                await graph.coordinator.processDueWork(now: Date())
                changeEndpoints[operation] = try await p9RequireReadyEndpoint(graph.coordinator, store: store,
                    expectedPhotosGeneration: delta.toGeneration, expectedRepresentations: operation == "added" ? count + 1 : count)
                changeSamples[operation, default: []].append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        let catalogsAfter = await photos.catalogRequests
        XCTAssertEqual(catalogsAfter, catalogsBefore, "Timed deltas must not fall back to a catalog")
        let deltaIO = try p11MetricDifference(metrics.snapshot(), deltaBefore)
        let deltaProcessIO = try p11MetricDifference(p11ProcessMetrics(), deltaProcessBefore)
        let filesAfter = try p11PersistentSizes(db)
        let deletedCalls = await model.calls, deletedReads = await photos.reads
        XCTAssertEqual(deletedReads, 10); XCTAssertEqual(deletedCalls, 31)
        let stableBefore = try metrics.snapshot(), stableProcessBefore = try p11ProcessMetrics()
        let stableStart = ProcessInfo.processInfo.systemUptime
        try await graph.coordinator.reconcile()
        var finalGeneration = await photos.generation
        let stableEndpoint = try await p9RequireReadyEndpoint(graph.coordinator, store: store,
            expectedPhotosGeneration: finalGeneration, expectedRepresentations: count)
        let stableMS = (ProcessInfo.processInfo.systemUptime - stableStart) * 1000
        let stableIO = try p11MetricDifference(metrics.snapshot(), stableBefore)
        let stableProcessIO = try p11MetricDifference(p11ProcessMetrics(), stableProcessBefore)
        let stableReads = await photos.reads, stableCalls = await model.calls
        XCTAssertEqual(stableReads, deletedReads); XCTAssertEqual(stableCalls, deletedCalls)
        // Separate actual row-write audit. Its trigger writes are intentionally
        // absent from every resource/latency sample above and from idle below.
        try p11StartRowAudit(db)
        var auditBefore = try p11RowAudit(db)
        let auditValue = try await store.indexReadiness()?.token
        _ = try await store.vectorCandidates(for: evidence.fileID, query: seed, token: XCTUnwrap(auditValue), threshold: c.threshold, diagnosticLimit: 10)
        let queryRows = try p11MetricDifference(p11RowAudit(db), auditBefore)
        XCTAssertEqual(queryRows.values.reduce(0, +), 0)
        for operation in ["edited", "added", "deleted"] {
            auditBefore = try p11RowAudit(db)
            let delta: PhotosIndexDelta
            switch operation {
            case "edited": delta = await photos.changeOne()
            case "added": delta = await photos.addOne()
            default: delta = await photos.removeAdded()
            }
            await graph.coordinator.libraryChanged(.incremental(delta)); await graph.coordinator.processDueWork(now: Date())
            _ = try await p9RequireReadyEndpoint(graph.coordinator, store: store, expectedPhotosGeneration: delta.toGeneration,
                expectedRepresentations: operation == "added" ? count + 1 : count)
            deltaWrites.append(try p11MetricDifference(p11RowAudit(db), auditBefore))
        }
        auditBefore = try p11RowAudit(db)
        try await graph.coordinator.reconcile()
        let fullRows = try p11MetricDifference(p11RowAudit(db), auditBefore)
        XCTAssertEqual(fullRows["rows.photos_representation"], 0); XCTAssertEqual(fullRows["rows.fingerprint_task"], 0)
        try p11StopRowAudit(db)
        finalGeneration = await photos.generation
        let readsBeforeRestart = await photos.reads
        let originalTokenBeforeRestart = try await graph.coordinator.readyToken()
        XCTAssertNotNil(originalTokenBeforeRestart)
        let restartStart = ProcessInfo.processInfo.systemUptime
        let reopened = try SyncStore(url: db, readExecutor: executor)
        let restarted = PhotosIndexCoordinator(store: reopened, photos: photos, fingerprinter: model, configuration: c)
        try await restarted.reconcile(); await restarted.processDueWork(now: Date())
        let restartedEndpoint = try await p9RequireReadyEndpoint(restarted, store: reopened,
            expectedPhotosGeneration: finalGeneration, expectedRepresentations: count)
        let restartMS = (ProcessInfo.processInfo.systemUptime - restartStart) * 1000
        let restartedReads = await photos.reads; XCTAssertEqual(restartedReads, readsBeforeRestart)
        // A reopened connection owns the new publication proof. All subsequent
        // preparations must use its coordinator/store pair, with the same model/budget.
        let restartedService = AdvancedDedupService(store: reopened, photos: photos, coordinator: restarted,
            fingerprinter: model, configuration: c, executor: executor, budget: budget)
        let originalTokenAfterRestart = try await graph.coordinator.readyToken()
        XCTAssertNil(originalTokenAfterRestart, "The old connection must not adopt the restarted store's publication proof")
        var idle: [String: Any] = [:]
        if historyCount == 100000 {
            let value = try await reopened.indexReadiness()?.token
            let token = try XCTUnwrap(value)
            _ = try await reopened.vectorCandidates(for: evidence.fileID, query: seed, token: token, threshold: c.threshold, diagnosticLimit: 10)
            let beforeIdle = try p11ProcessMetrics(), idleStart = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(60))
            let afterIdle = try p11ProcessMetrics(), afterIdleStart = ProcessInfo.processInfo.systemUptime
            _ = try await reopened.vectorCandidates(for: evidence.fileID, query: seed, token: token, threshold: c.threshold, diagnosticLimit: 10)
            idle = ["elapsed_seconds": afterIdleStart - idleStart, "before": beforeIdle, "after": afterIdle,
                "resume_query_ms": (ProcessInfo.processInfo.systemUptime - afterIdleStart) * 1000,
                "resume_process_io": try p11MetricDifference(p11ProcessMetrics(), afterIdle)]
        }
        for n in 0..<100000 {
            logger.logDecision(AdvancedEvidence(eventID: UUID(), fileID: UUID(), stamp: evidence.stamp,
                token: evidence.token, policyVersion: evidence.policyVersion, evaluation: evidence.evaluation,
                decisiveCandidates: evidence.decisiveCandidates, diagnostics: evidence.diagnostics, timingsMS: [:]), configuration: c)
            // Model a serial producer, not an artificial 100k-closure dispatch burst.
            if n.isMultiple(of: 128) { logger.flushForTesting() }
        }
        logger.flushForTesting()
        var largeSamples = [[String: Any]]()
        for url in largeURLs {
            let beforeHash = try p9Hash(url)
            let metadata = try await MetadataReader(sourceID: sourceID, executor: executor).read(url: url, filename: url.lastPathComponent)
            let file = SourceFile(sourceID: sourceID, relativePath: url.lastPathComponent, url: url,
                stamp: try await DirectoryReader(sourceID: sourceID, executor: executor).stamp(of: url), metadata: metadata)
            let id = try await reopened.save(file, decision: .importNew)
            if count == 2 {
                let callsBefore = await model.calls, readsBefore = await photos.reads
                let stalePreparation = try await graph.service.prepare(fileID: id, file: file)
                guard case .waiting(let reason) = stalePreparation else { return XCTFail("Old service must reject a replaced publication before image work") }
                let callsAfter = await model.calls, readsAfter = await photos.reads
                XCTAssertEqual(reason, "来源或图库索引正在等待确认。")
                XCTAssertEqual(callsAfter, callsBefore); XCTAssertEqual(readsAfter, readsBefore)
                try p9WriteEvidence("restart-handoff-2.json", [
                    "before_index_generation": originalTokenBeforeRestart!.indexGeneration,
                    "after_index_generation": restartedEndpoint["index_generation"]!,
                    "original_ready_after_restart": originalTokenAfterRestart != nil,
                    "restarted_endpoint": restartedEndpoint, "stale_preparation_reason": reason,
                    "model_calls_before": callsBefore, "model_calls_after": callsAfter,
                    "photos_reads_before": readsBefore, "photos_reads_after": readsAfter])
            }
            let beforePeak = p9PeakRSS(), started = ProcessInfo.processInfo.systemUptime
            let preparation = try await restartedService.prepare(fileID: id, file: file)
            let admission: AdvancedAdmission
            switch preparation {
            case .ready(let value): admission = value
            case .waiting(let reason): return XCTFail("Post-restart preparation waited: \(reason)")
            case .conservative(let value): return XCTFail("Post-restart preparation was not compared: \(value.reason)")
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let actualInput = await model.lastInput
            largeSamples.append(["name": url.lastPathComponent, "original_width": metadata.width!, "original_height": metadata.height!,
                "prepared_ms": elapsed, "stages_ms": admission.evidence.timingsMS, "model_input_raster": actualInput,
                "process_peak_rss_before_bytes": beforePeak, "process_peak_rss_after_bytes": p9PeakRSS(),
                "sample_count": 1, "percentile_claim": false, "is_large_fixture": count == 200000])
            XCTAssertEqual(try p9Hash(url), beforeHash)
        }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let logFiles = files.filter { $0.pathExtension == "jsonl" }
        XCTAssertLessThanOrEqual(logFiles.count, 10)
        let leases = await budget.snapshot(); XCTAssertEqual(leases.images, 0); XCTAssertEqual(leases.bytes, 0)
        let peak = p9PeakRSS(), hot95 = p9Percentiles(hot)["p95"]!, cold95 = p9Percentiles(cold)["p95"]!
        let changeWithinBudget = changeSamples.values.flatMap { $0 }.allSatisfy { $0 <= 2000 }
        // Record even a failed budget so it cannot be laundered as a missing sample.
        try p9WriteEvidence("\(sampleName).json", ["representations": count, "synthetic_assets": min(count, 100000), "success_history_vectors": historyCount,
            "build_configuration": ProcessInfo.processInfo.environment["PHOTOSYNC_SCALE_BUILD_CONFIGURATION"] ?? "Debug",
            "edited_fraction": Double(max(0, count - 100000)) / Double(min(count, 100000)), "scope": "actual graph; synthetic persisted vectors and fake Photos; 20 real local synthetic-image CPU-only inferences",
            "vector_generation": "unit basis cycling 1024 dimensions with real seed every 10000 rows; no accuracy claim",
            "seed_sqlite_ms": seedMS, "catalog_and_publication_ms": publishMS,
            "source_incremental_ms": p9Percentiles(cold), "hot_preparation_ms": p9Percentiles(hot),
            "stages_ms": stages.mapValues(p9Percentiles), "hot_stages_ms": hotStages.mapValues(p9Percentiles),
            "raw_query_ms": p9Percentiles(queryTimes), "raw_query_sample_count": queryTimes.count,
            "change_to_ready_ms": changeSamples.mapValues(p9Percentiles),
            "one_changed_catalog_inference_publication_ms": p9Percentiles(changeSamples["edited"]!)["p95"]!,
            "one_added_catalog_inference_publication_ms": p9Percentiles(changeSamples["added"]!)["p95"]!,
            "one_deleted_catalog_publication_ms": p9Percentiles(changeSamples["deleted"]!)["p95"]!,
            "index_change_ready_within_2s": changeWithinBudget, "delta_path_verified": catalogsAfter == catalogsBefore,
            "index_change_sample_count_per_operation": 5, "index_change_percentile_claim": true,
            "readiness_endpoints": changeEndpoints.merging(["initial": initialEndpoint, "unchanged": stableEndpoint, "restart": restartedEndpoint]) { _, rhs in rhs },
            "restart_catalog_publication_ms": restartMS, "idle_60s": idle,
            "query_io": queryIO.merging(queryRows) { _, rhs in rhs }, "query_process_io": queryProcessIO, "delta_io": deltaIO, "delta_process_io": deltaProcessIO,
            "unchanged_full_io": stableIO.merging(fullRows) { _, rhs in rhs }, "unchanged_full_process_io": stableProcessIO, "per_delta_row_writes": deltaWrites,
            "delta_file_sizes_before": filesBefore, "delta_file_sizes_after": filesAfter,
            "io_scope": "fixture DB/sidecar VFS logical requests and process accounting; row counts from separate audit pass; resource timings have no triggers; mmap fetch sizes are not physical reads",
            "unchanged_catalog_publication_ms": stableMS, "one_changed_inferences": 1, "unchanged_inferences": stableCalls - deletedCalls,
            "large_source_samples": largeSamples, "logger_unique_files": 100000, "logger_flush_interval": 128, "persistent_fixture_bytes": bytes,
            "rss_peak_bytes": peak, "budget_pass": peak <= 4 * 1024 * 1024 * 1024 && hot95 <= 250 && cold95 <= 2000 && changeWithinBudget,
            "real_photos": false, "real_100k_assets": false])
        XCTAssertLessThanOrEqual(peak, 4 * 1024 * 1024 * 1024)
        XCTAssertLessThanOrEqual(hot95, 250)
        XCTAssertLessThanOrEqual(cold95, 2000)
        XCTAssertTrue(changeWithinBudget, "At least one verified Photos change-to-ready observation exceeds 2 seconds")
    }

    func testScaleResourceHooksAreReadOnlyAndCountOnlyTheFixture() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("metrics.sqlite"), metrics = try P11SQLiteMetrics(path: root.appendingPathComponent("metrics.sqlite").path)
        let store = try SyncStore(url: db)
        defer { withExtendedLifetime(store) { metrics.stop() } }
        let before = try metrics.snapshot()
        let generation = try await store.beginIndexReconciliation(context: .init(id: UUID(), epoch: 0), photosGeneration: 1, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: generation, seenKeys: [])
        let written = try p11MetricDifference(metrics.snapshot(), before)
        XCTAssertGreaterThan(written["vfs.write_bytes"] ?? 0, 0)
        let readBefore = try metrics.snapshot()
        _ = try await store.indexReadiness()
        let readAfter = try p11MetricDifference(metrics.snapshot(), readBefore)
        XCTAssertEqual(readAfter["vfs.write_calls"], 0)
        let other = try SyncStore(url: root.appendingPathComponent("other.sqlite"))
        let afterOther = try metrics.snapshot(); XCTAssertEqual(afterOther, try metrics.snapshot())
        XCTAssertEqual(try p11MetricDifference(afterOther, readBefore)["vfs.write_calls"], 0)
        withExtendedLifetime(other) {}
        let process = try p11ProcessMetrics(); XCTAssertGreaterThan(process["footprint_bytes"] ?? 0, 0)
        XCTAssertGreaterThan(try p11PersistentSizes(db)["database"] ?? 0, 0)
        try p11StartRowAudit(db)
        let auditBefore = try p11RowAudit(db)
        let next = try await store.beginIndexReconciliation(context: .init(id: UUID(), epoch: 0), photosGeneration: 2, fingerprintVersion: "v1")
        try await store.finishIndexReconciliation(generation: next, seenKeys: [])
        XCTAssertEqual(try p11MetricDifference(p11RowAudit(db), auditBefore)["rows.dedup_index_state"], 2)
        try p11StopRowAudit(db)
    }

    func testReadinessEndpointRejectsAcknowledgementFailureAfterCompletedInference() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try DedupConfiguration.loadValidated(resourceDirectory: DedupConfiguration.bundledResourceDirectory())
        let executor = ReadExecutor(), budget = ImageWorkBudget(limits: configuration.resources)
        let store = try SyncStore(url: root.appendingPathComponent("endpoint.sqlite"), readExecutor: executor)
        let photos = P9ScalePhotos(count: 1, image: try p9Image(style: 1), budget: budget)
        let model = P9MeasuredModel(CoreMLFingerprinter(configuration: configuration.fingerprint,
            predict: { _ in [1] + [Float](repeating: 0, count: 1023) }))
        let coordinator = PhotosIndexCoordinator(store: store, photos: photos, fingerprinter: model,
            configuration: configuration)
        await photos.setAcknowledgementFailure(true)
        // processDueWork deliberately catches publication/acknowledgement errors.
        await coordinator.processDueWork(now: Date())
        let firstCalls = await model.calls, firstReads = await photos.reads
        XCTAssertEqual(firstCalls, 1); XCTAssertEqual(firstReads, 1)
        do {
            _ = try await p9RequireReadyEndpoint(coordinator, store: store, expectedPhotosGeneration: 1, expectedRepresentations: 1)
            XCTFail("Normal work-loop return and completed inference did not establish readiness")
        } catch FixtureError.unavailable {}
        await photos.setAcknowledgementFailure(false)
        await coordinator.processDueWork(now: Date())
        _ = try await p9RequireReadyEndpoint(coordinator, store: store, expectedPhotosGeneration: 1, expectedRepresentations: 1)
        for (generation, count) in [(2, 1), (1, 2)] {
            do {
                _ = try await p9RequireReadyEndpoint(coordinator, store: store, expectedPhotosGeneration: generation, expectedRepresentations: count)
                XCTFail("Readiness must match both expected generation and representation count")
            } catch FixtureError.unavailable {}
        }
        let delta = await photos.changeOne(); await photos.setAcknowledgementFailure(true)
        await coordinator.libraryChanged(.incremental(delta))
        await coordinator.processDueWork(now: Date())
        let changedCalls = await model.calls, changedReads = await photos.reads
        XCTAssertEqual(changedCalls, 2); XCTAssertEqual(changedReads, 2)
        do {
            _ = try await p9RequireReadyEndpoint(coordinator, store: store, expectedPhotosGeneration: 2, expectedRepresentations: 1)
            XCTFail("Completed changed-asset inference cannot substitute for acknowledgement")
        } catch FixtureError.unavailable {}
    }
}

private func p9RequireReadyEndpoint(_ coordinator: PhotosIndexCoordinator, store: SyncStore,
                                   expectedPhotosGeneration: Int, expectedRepresentations: Int) async throws -> [String: Int64] {
    guard let token = try await coordinator.readyToken(),
          token.photosGeneration == expectedPhotosGeneration,
          let publication = try await store.indexReadiness(), publication.token == token,
          publication.entryCount == expectedRepresentations else {
        throw FixtureError.unavailable("Timed endpoint lacks the expected published, acknowledged generation/count")
    }
    return ["photos_generation": Int64(token.photosGeneration), "index_generation": token.indexGeneration,
            "representation_count": Int64(publication.entryCount)]
}

private actor P9ScalePhotos: PhotosIndexGateway {
    let context = LibraryContext(id: UUID(), epoch: 1), count: Int, image: CGImage, budget: ImageWorkBudget
    nonisolated let channel = PhotosIndexChangeChannel(capacity: 128)
    var generation = 1, originalRevision = 1, reads = 0, hasAdded = false, acknowledgementFails = false
    var catalogRequests = 0
    init(count: Int, image: CGImage, budget: ImageWorkBudget) { self.count = count; self.image = image; self.budget = budget }
    nonisolated func changes() -> AsyncStream<PhotosIndexChange> { channel.stream() }
    private func change(changed: [String] = [], deleted: [String] = []) -> PhotosIndexDelta {
        let from = generation; generation += 1
        let delta = PhotosIndexDelta(context: context, fromGeneration: from, toGeneration: generation,
            changedAssetIDs: changed, deletedAssetIDs: deleted)
        channel.send(.incremental(delta)); return delta
    }
    @discardableResult func changeOne() -> PhotosIndexDelta { originalRevision += 1; return change(changed: ["asset-0"]) }
    @discardableResult func addOne() -> PhotosIndexDelta { hasAdded = true; return change(changed: ["added-asset"]) }
    @discardableResult func removeAdded() -> PhotosIndexDelta { hasAdded = false; return change(deleted: ["added-asset"]) }
    func setAcknowledgementFailure(_ fails: Bool) { acknowledgementFails = fails }
    func acknowledgeReconciliation(expectedGeneration: Int) async throws {
        guard !acknowledgementFails, expectedGeneration == generation else { throw PhotoKitGatewayError.libraryChanged }
        channel.reconciled()
    }
    func candidateSnapshot() async throws -> PhotosCandidateSnapshot { .init(generation: generation, candidates: []) }
    func contextCheckpoint() async throws -> LibraryResumeCheckpoint? { .init(context: context, archivedChangeToken: Data([9]), photosGeneration: generation) }
    func resumeContext(_ checkpoint: LibraryResumeCheckpoint) async throws -> Bool { checkpoint.context == context }
    func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage {
        catalogRequests += 1
        let total = count + (hasAdded ? 1 : 0)
        let end = min(offset + limit, total)
        let descriptors = (offset..<end).map { n in
            RepresentationDescriptor(key: .init(assetID: n == count ? "added-asset" : "asset-\(n % 100000)", kind: n < 100000 || n == count ? .original : .current), context: context,
                revision: n == 0 ? "r\(originalRevision)" : "r1", size: try! PixelSize(width: 256, height: 256),
                equivalentToOriginal: false, revisionIsReliable: true)
        }
        return .init(context: context, generation: generation, descriptors: descriptors, nextOffset: end < total ? end : nil)
    }
    func representationDelta(_ delta: PhotosIndexDelta) async throws -> RepresentationPage {
        guard delta.context == context, delta.toGeneration == generation else { throw PhotoKitGatewayError.libraryChanged }
        var descriptors: [RepresentationDescriptor] = []
        for id in delta.changedAssetIDs {
            guard id == "asset-0" || (id == "added-asset" && hasAdded) else { throw PhotoKitGatewayError.libraryChanged }
            let kinds: [RepresentationKind] = id == "asset-0" && count > 100000 ? [.original, .current] : [.original]
            for kind in kinds {
                descriptors.append(.init(key: .init(assetID: id, kind: kind), context: context,
                    revision: id == "asset-0" && kind == .original ? "r\(originalRevision)" : "r1",
                    size: try PixelSize(width: 256, height: 256), equivalentToOriginal: false, revisionIsReliable: true))
            }
        }
        return .init(context: context, generation: generation, descriptors: descriptors, nextOffset: nil)
    }
    func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation {
        reads += 1
        return LoadedRepresentation(image: image, orientation: .up, descriptor: descriptor,
            lease: try await budget.acquire(bytes: Int64(image.bytesPerRow * image.height)), eligibility: .safeSingleFrame)
    }
    func create(fileURL: URL, kind: MediaKind, expectedGeneration: Int,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> String { throw PhotosAdmissionDeferred() }
    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}

private func p9SeedScale(db url: URL, count: Int, context: LibraryContext, generation: Int64, seed: Fingerprint) throws {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw FixtureError.unavailable("scale sqlite open") }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK,
          sqlite3_prepare_v2(db, "INSERT INTO photos_representation VALUES(?,1,?,?, 'r1',256,256,0,1,?,'ready',?,?,0)", -1, &statement, nil) == SQLITE_OK else {
        throw FixtureError.unavailable("scale sqlite prepare")
    }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    var basis = [Data](); basis.reserveCapacity(1024)
    for n in 0..<1024 {
        var values = [Float](repeating: 0, count: 1024); values[n] = 1
        basis.append(try Fingerprint(version: seed.version, values: values).littleEndianFloat32)
    }
    let seedBytes = seed.littleEndianFloat32
    for n in 0..<count {
        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, context.id.uuidString, -1, transient)
        sqlite3_bind_text(statement, 2, "asset-\(n % 100000)", -1, transient)
        sqlite3_bind_text(statement, 3, n < 100000 ? "original" : "current", -1, transient)
        sqlite3_bind_int64(statement, 4, generation)
        sqlite3_bind_text(statement, 5, seed.version, -1, transient)
        let bytes = n.isMultiple(of: 10000) ? seedBytes : basis[n % 1024]
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.unavailable("scale sqlite insert") }
    }
    guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw FixtureError.unavailable("scale sqlite commit") }
}

/// Same generated gradient family used in the approved P4 resource probe. Build
/// before loading the large index; fixture construction is not product decoding.
private func p9LargeFixture(at url: URL, width: Int, height: Int, depth: Int) throws {
    try autoreleasepool {
        let componentBytes = depth / 8, rowBytes = width * 4 * componentBytes
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let offset = y * rowBytes + x * 4 * componentBytes
                let channels = [UInt16(x * 65535 / (width - 1)), UInt16(y * 65535 / (height - 1)), UInt16((x ^ y) & 65535), UInt16.max]
                for channel in 0..<4 {
                    if depth == 8 { bytes[offset + channel] = UInt8(channels[channel] >> 8) }
                    else { bytes[offset + channel * 2] = UInt8(channels[channel] >> 8); bytes[offset + channel * 2 + 1] = UInt8(channels[channel] & 255) }
                }
            } }
        }
        let order: CGBitmapInfo = depth == 16 ? .byteOrder16Big : .byteOrder32Big
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: depth, bitsPerPixel: depth * 4,
            bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: order.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let type = depth == 8 ? "public.jpeg" : "public.png"
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private func p9SeedHistory(db url: URL, count: Int, sourceID: UUID, seed: Fingerprint) throws {
    var db: OpaquePointer?, file: OpaquePointer?, vector: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw FixtureError.unavailable("history open") }
    defer { sqlite3_finalize(file); sqlite3_finalize(vector); sqlite3_close(db) }
    let fileSQL = "INSERT INTO file_record(id,created_order,source_id,relative_path,filename,size,modified_ns,metadata_json,state,rule_version,success_id,success_metadata_json,succeeded_at) VALUES(?,?,?,?,'historical.png',1,1,?,'imported',1,?,?,1)"
    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK,
          sqlite3_prepare_v2(db, fileSQL, -1, &file, nil) == SQLITE_OK,
          sqlite3_prepare_v2(db, "INSERT INTO file_fingerprint VALUES(?,1,1,?,'success',256,256,?,'')", -1, &vector, nil) == SQLITE_OK else {
        throw FixtureError.unavailable("history prepare")
    }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let metadata = String(data: try JSONEncoder().encode(MediaMetadata(filename: "historical.png", kind: .image,
        captureSecond: nil, rawCaptureTime: nil, make: nil, model: nil, width: 256, height: 256, duration: nil)), encoding: .utf8)!
    let seedBytes = seed.littleEndianFloat32
    var basis = [Data]()
    for n in 0..<1024 {
        var values = [Float](repeating: 0, count: 1024); values[n] = 1
        basis.append(try Fingerprint(version: seed.version, values: values).littleEndianFloat32)
    }
    for n in 0..<count {
        let id = UUID().uuidString
        sqlite3_reset(file); sqlite3_clear_bindings(file)
        sqlite3_bind_text(file, 1, id, -1, transient); sqlite3_bind_int64(file, 2, Int64(n + 1))
        sqlite3_bind_text(file, 3, sourceID.uuidString, -1, transient); sqlite3_bind_text(file, 4, "historical-\(n).png", -1, transient)
        sqlite3_bind_text(file, 5, metadata, -1, transient); sqlite3_bind_text(file, 6, "historical-success-\(n)", -1, transient)
        sqlite3_bind_text(file, 7, metadata, -1, transient)
        guard sqlite3_step(file) == SQLITE_DONE else { throw FixtureError.unavailable("history file insert") }
        sqlite3_reset(vector); sqlite3_clear_bindings(vector)
        sqlite3_bind_text(vector, 1, id, -1, transient); sqlite3_bind_text(vector, 2, seed.version, -1, transient)
        let bytes = n.isMultiple(of: 10000) ? seedBytes : basis[n % 1024]
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(vector, 3, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(vector) == SQLITE_DONE else { throw FixtureError.unavailable("history vector insert") }
    }
    guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw FixtureError.unavailable("history commit") }
}

// Test-host-only VFS: logical calls for the named fixture DB/sidecars.
// mmap fetch sizes are requested ranges, not measured resident/physical reads.
private final class P11SQLiteMetrics {
    init(path: String) throws {
        let status = p11_metrics_start(path)
        guard status == SQLITE_OK else { throw FixtureError.unavailable("SQLite fixture VFS status \(status)") }
    }
    func stop() { p11_metrics_stop() }
    func snapshot() throws -> [String: Int64] {
        let names = ["vfs.read_calls", "vfs.read_bytes", "vfs.write_calls", "vfs.write_bytes",
            "vfs.fetch_calls", "vfs.fetch_bytes", "vfs.fetch_hits", "vfs.fetch_hit_bytes"]
        return Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, Int64(p11_metrics_counter(Int32($0.offset)))) })
    }
}

private func p11ProcessMetrics() throws -> [String: Int64] {
    var vm = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &vm) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    var usage = rusage_info_v4()
    let ioStatus = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    guard status == KERN_SUCCESS, ioStatus == 0 else { throw FixtureError.unavailable("process resource accounting") }
    return ["rss_bytes": Int64(vm.resident_size), "footprint_bytes": Int64(vm.phys_footprint),
        "diskread_bytes": Int64(usage.ri_diskio_bytesread), "diskwritten_bytes": Int64(usage.ri_diskio_byteswritten),
        "logical_writes": Int64(usage.ri_logical_writes), "pageins": Int64(usage.ri_pageins)]
}

private func p11MetricDifference(_ after: [String: Int64], _ before: [String: Int64]) -> [String: Int64] {
    Dictionary(uniqueKeysWithValues: Set(after.keys).union(before.keys).map { ($0, (after[$0] ?? 0) - (before[$0] ?? 0)) })
}

private func p11PersistentSizes(_ db: URL) throws -> [String: Int64] {
    var sizes: [String: Int64] = [:]
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let path = db.path + suffix
        sizes[suffix.isEmpty ? "database" : suffix] = FileManager.default.fileExists(atPath: path)
            ? (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0 : 0
    }
    return sizes
}

private let p11AuditedTables = ["photos_representation", "fingerprint_task", "photos_index_exclusion", "dedup_index_state"]
private func p11StartRowAudit(_ db: URL) throws {
    try injectEngineSQL("CREATE TABLE p11_writes (table_name TEXT);" + p11AuditedTables.flatMap { table in
        ["INSERT", "UPDATE", "DELETE"].map { operation in
            "CREATE TRIGGER p11_\(table)_\(operation) AFTER \(operation) ON \(table) BEGIN INSERT INTO p11_writes VALUES ('\(table)'); END;"
        }
    }.joined(), at: db)
}
private func p11RowAudit(_ db: URL) throws -> [String: Int64] {
    try Dictionary(uniqueKeysWithValues: p11AuditedTables.map { table in
        ("rows." + table, Int64(try engineSQLInteger("SELECT COUNT(*) FROM p11_writes WHERE table_name='\(table)'", at: db)))
    })
}
private func p11StopRowAudit(_ db: URL) throws {
    try injectEngineSQL(p11AuditedTables.flatMap { table in
        ["INSERT", "UPDATE", "DELETE"].map { "DROP TRIGGER p11_\(table)_\($0);" }
    }.joined() + "DROP TABLE p11_writes;", at: db)
}
