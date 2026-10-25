import XCTest
@testable import PhotoSyncCore

final class RuntimeEventSequenceTests: XCTestCase {
    func testDurableLivePhotoCrashBoundariesAcrossProcesses() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let phase = environment["PHOTOSYNC_SYNTHETIC_PHASE"], let path = environment["PHOTOSYNC_SYNTHETIC_SESSION"], let checkpoint = environment["PHOTOSYNC_SYNTHETIC_CHECKPOINT"] {
            try await crashPhase(root: URL(fileURLWithPath: path), phase: phase, checkpoint: checkpoint)
            return
        }
        let checkpoints = ["intent", "placeholder", "system-committed", "verified", "retirement-unconfirmed", "retirement-confirmed"]
        var reports = [[String: Any]]()
        for checkpoint in checkpoints {
            let root = try PortableRuntimeSession.create(); defer { try? FileManager.default.removeItem(at: root) }
            let bundle = Bundle(for: Self.self).bundleURL
            for (phase, exitCode) in [("seed", Int32(86)), ("resume", 0)] {
                let result = try await Task.detached {
                    try StartupRecoveryTests.runChildSynchronously(root: root, phase: phase, bundle: bundle,
                        test: "RuntimeEventSequenceTests/testDurableLivePhotoCrashBoundariesAcrossProcesses", checkpoint: checkpoint)
                }.value
                XCTAssertEqual(result.0, exitCode, "\(checkpoint)/\(phase): \(result.1)")
                guard result.0 == exitCode else { throw FixtureError.unavailable("Crash host failed") }
            }
            reports.append(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("recovery.json"))) as! [String: Any])
        }
        if let output = environment["PHOTOSYNC_ACCEPTANCE_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output).appendingPathComponent("runtime-crash-boundaries.json"))
        }
    }

    private func crashPhase(root: URL, phase: String, checkpoint: String) async throws {
        try PortableRuntimeSession.validate(root)
        let context = LibraryContext(id: UUID(uuidString: String(root.lastPathComponent.dropFirst("PhotoSyncTests-".count)))!, epoch: 1)
        let store = try SyncStore(url: root.appendingPathComponent("state.sqlite"))
        let photos = CompletionPhotos(context: context, root: root)
        if phase == "seed" {
            for (id, role) in [("old-photo", LivePhotoRole.photo), ("old-motion", .motion)] {
                let asset = livePhotoAsset(context: context, id: id, kind: role == .photo ? .image : .video)
                await photos.add(asset)
                try await store.enqueueLivePhotoAssets(context: context, assets: [asset])
                try await store.recordLivePhotoInventoryResult(context: context, assetID: id, revision: asset.revision,
                    observations: [.init(resource: asset.resources[0], inspection: .identified(.init(contentIdentifier: "pair", role: role)))], retryPolicy: .requiresAttention)
            }
            try await completeEmptyInventory(store, context)
        }
        try await photos.attachNativeJournal(root: root, restore: phase == "resume", checkpoint: phase == "seed" ? checkpoint : nil)
        let c = LivePhotoCoordinator(store: store, photos: photos, metadata: CompletionMetadata())
        try await c.recover()
        if phase == "seed" {
            _ = try await c.advanceNext(now: Date(), refreshDiscovery: false)
            _ = try await c.advanceNext(now: Date(), refreshDiscovery: false)
            if checkpoint == "verified" { _exit(86) }
            _ = try await c.advanceNext(now: Date(), refreshDiscovery: false)
            if checkpoint == "retirement-confirmed" { _exit(86) }
            XCTFail("Checkpoint did not terminate the owned test process: \(checkpoint)")
        } else {
            for _ in 0..<5 { _ = try await c.advanceNext(now: Date(), refreshDiscovery: false) }
            let summary = try await c.summary(), creates = await photos.creates, retires = await photos.retires
            let unknown = ["intent", "placeholder", "retirement-unconfirmed"].contains(checkpoint)
            XCTAssertEqual(summary.unknownMutation, unknown)
            XCTAssertEqual(creates, checkpoint == "intent" ? 0 : 1, "Never repeat a system create")
            XCTAssertEqual(retires, ["intent", "placeholder"].contains(checkpoint) ? 0 : 1, "Never repeat an unconfirmed deletion")
            if !unknown {
                XCTAssertEqual(summary.activeGroups, 0); XCTAssertEqual(summary.retryWaitingGroups, 0)
                XCTAssertEqual(summary.awaitingVerification, 0); XCTAssertEqual(summary.awaitingRetirement, 0)
            }
            try JSONSerialization.data(withJSONObject: ["checkpoint": checkpoint, "creates": creates, "retires": retires,
                "unknown": unknown, "pid": ProcessInfo.processInfo.processIdentifier], options: [.sortedKeys])
                .write(to: root.appendingPathComponent("recovery.json"))
        }
    }

    func testTwentySeedsOfFortyRecoveryEventsKeepMutationInvariants() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        var reports = [[String: Any]]()
        for seed in 1...20 {
            let f = try await makeEngineFixture(sourceCount: 1)
            defer { try? FileManager.default.removeItem(at: f.databaseURL.deletingLastPathComponent()) }
            var store = f.store, engine = f.engine, random = PortableSequence(seed: UInt64(seed)), prefix = [String]()
            await f.photos.setCreationError(.resultUnknown("synthetic unknown result"))
            await engine.scan(sourceIDs: f.sourceIDs)
            let first = await f.photos.createCount; XCTAssertEqual(first, 1)
            var confirmed = false
            for step in 0..<40 {
                let event = step == 30 ? 6 : Int(random.next() % 6)
                switch event {
                case 0: prefix.append("pause"); await engine.pause()
                case 1: prefix.append("resume"); await engine.resume()
                case 2: prefix.append("scan"); await engine.scan(sourceIDs: f.sourceIDs)
                case 3: prefix.append("candidate-change"); await f.photos.bumpCandidateGeneration()
                case 4:
                    prefix.append("reopen-store")
                    store = try SyncStore(url: f.databaseURL)
                    engine = SyncEngine(store: store, photos: f.photos)
                case 5: prefix.append("snapshot"); _ = await engine.snapshot()
                default:
                    prefix.append("positive-confirmation"); confirmed = true
                    await f.photos.setEvidence(.found(identifier: "fake-1"))
                    await f.photos.setCreationError(nil)
                    await engine.resume(); await engine.scan(sourceIDs: f.sourceIDs)
                }
                let creates = await f.photos.createCount
                let state = try await store.activeSourceSummary()
                guard creates == 1, state.imported + state.importing == 1,
                      confirmed || state.imported == 0 else {
                    XCTFail("seed=\(seed), first failing prefix=\(prefix)")
                    break
                }
            }
            await engine.resume(); await engine.scan(sourceIDs: f.sourceIDs)
            let settled = await engine.snapshot(), final = try await store.activeSourceSummary()
            XCTAssertNil(settled.blockingError, "seed=\(seed)")
            XCTAssertEqual(final.imported, 1); XCTAssertEqual(final.importing, 0); XCTAssertEqual(final.pending, 0)
            reports.append(["seed": seed, "events": prefix, "creates": await f.photos.createCount])
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 30)
        if let output = ProcessInfo.processInfo.environment["PHOTOSYNC_ACCEPTANCE_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output).appendingPathComponent("runtime-sequences.json"))
        }
    }
}

/// Fixed SplitMix64 transition; no system random input and no mirrored business model.
private struct PortableSequence {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed &+= 0x9E3779B97F4A7C15
        var value = seed
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
