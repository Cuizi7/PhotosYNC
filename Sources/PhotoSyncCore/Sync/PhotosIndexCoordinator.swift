import Foundation

/// Owns one bounded work loop and the durable-inventory → derived-index → Photos
/// acknowledgement barrier. SQLite never waits for Photos or model work.
public actor PhotosIndexCoordinator {
    private let store: SyncStore
    private let photos: any PhotosIndexGateway
    private let fingerprinter: any ImageFingerprinting
    private let index: ExactVectorIndex
    private let configuration: DedupConfiguration
    private var observer: Task<Void, Never>?
    private var started = false, paused = false, reconciling = false, processing = false
    private var needsReconciliation = true
    private var forceCacheInvalidation = true
    private var changeSerial: UInt64 = 0
    private var reconciledGeneration: Int?
    private var acknowledgedGeneration: Int?
    private var issue: String?

    public init(store: SyncStore, photos: any PhotosIndexGateway, fingerprinter: any ImageFingerprinting,
                index: ExactVectorIndex, configuration: DedupConfiguration) {
        self.store = store; self.photos = photos; self.fingerprinter = fingerprinter
        self.index = index; self.configuration = configuration
    }

    deinit { observer?.cancel() }

    public func reconcile() async throws {
        guard !reconciling else { throw PhotoKitGatewayError.libraryChanged }
        reconciling = true; acknowledgedGeneration = nil
        defer { reconciling = false }
        do {
            if !started {
                started = true
                // Subscribe before replay. Pages, not stream delivery order, own
                // authoritative content invalidation for this reconciliation.
                let events = photos.changes()
                observer = Task { [weak self] in
                    for await event in events {
                        guard !Task.isCancelled else { break }
                        await self?.observe(event)
                    }
                }
                if let checkpoint = try await store.libraryResumeCheckpoint() {
                    forceCacheInvalidation = try await !photos.resumeContext(checkpoint)
                }
            }
            let serial = changeSerial
            let checkpoint = try await photos.contextCheckpoint()
            let snapshot = try await photos.candidateSnapshot()
            var offset = 0
            var generation: Int64?
            var eligibleAssets = Set<String>(), excludedAssets = Set<String>()
            var context: LibraryContext?
            var allInvalidated = false
            repeat {
                let page = try await photos.representationCatalog(offset: offset,
                    limit: configuration.resources.catalogBatchSize, expectedGeneration: snapshot.generation)
                guard page.generation == snapshot.generation, context == nil || context == page.context,
                      checkpoint == nil || checkpoint?.context == page.context else { throw PhotoKitGatewayError.libraryChanged }
                guard page.descriptors.count + page.exclusions.count <= configuration.resources.catalogBatchSize,
                      page.invalidatedAssetIDs.count <= configuration.resources.catalogBatchSize,
                      page.descriptors.allSatisfy({ $0.context == page.context }),
                      page.exclusions.allSatisfy({ $0.descriptor.context == page.context }) else { throw AdvancedDedupError.invalidConfiguration }
                if generation == nil {
                    context = page.context
                    generation = try await store.beginIndexReconciliation(context: page.context,
                        photosGeneration: snapshot.generation, fingerprintVersion: configuration.fingerprint.version)
                }
                let current = generation!
                if (forceCacheInvalidation || page.invalidateAllCachedRepresentations) && !allInvalidated {
                    try await store.invalidateRepresentations(assetIDs: nil, generation: current)
                    allInvalidated = true
                } else if !allInvalidated && !page.invalidatedAssetIDs.isEmpty {
                    try await store.invalidateRepresentations(assetIDs: page.invalidatedAssetIDs, generation: current)
                }
                try await store.upsertRepresentations(page.descriptors, generation: current)
                eligibleAssets.formUnion(page.descriptors.map { $0.key.assetID })
                excludedAssets.formUnion(page.exclusions.map { $0.descriptor.key.assetID })
                if let next = page.nextOffset {
                    guard next > offset else { throw AdvancedDedupError.invalidConfiguration }
                    offset = next
                } else { break }
            } while true
            let latest = try await photos.candidateSnapshot()
            guard latest.generation == snapshot.generation, changeSerial == serial else { throw PhotoKitGatewayError.libraryChanged }
            // Commit continuity even when the long initial fingerprint build is
            // unfinished; this checkpoint proves inventory history, never readiness.
            try await store.finishIndexReconciliation(generation: generation!, checkpoint: checkpoint,
                excludedAssets: excludedAssets.subtracting(eligibleAssets).count)
            let after = try await photos.candidateSnapshot()
            guard after.generation == snapshot.generation, changeSerial == serial else { throw PhotoKitGatewayError.libraryChanged }
            needsReconciliation = false; forceCacheInvalidation = false
            reconciledGeneration = snapshot.generation; issue = nil
            try await publishIfComplete()
        } catch {
            needsReconciliation = true; issue = "图库索引正在等待重新核对。"
            try? await store.invalidateIndexPublication()
            throw error
        }
    }

    public func processDueWork(now: Date) async {
        guard !processing, !paused else { return }
        processing = true
        defer { processing = false }
        do {
            if needsReconciliation { try await reconcile() }
            guard !paused, !needsReconciliation, !reconciling else { return }
            while !paused && !needsReconciliation && !reconciling {
                // Serial consumer keeps physical image/model concurrency at one,
                // below every configured limit. Polling itself never claims work.
                let tasks = try await store.nextRepresentationTasks(now: now,
                    limit: min(configuration.resources.catalogBatchSize, configuration.resources.maxInFlightTasks))
                guard !tasks.isEmpty else { break }
                for task in tasks {
                    guard !paused, !needsReconciliation, !reconciling else { break }
                    let expected = reconciledGeneration
                    let snapshot = try await photos.candidateSnapshot()
                    guard snapshot.generation == expected else { needsReconciliation = true; acknowledgedGeneration = nil; break }
                    // An unstructured owned Task does not inherit later caller
                    // cancellation. Pause cannot cancel already-started consumers.
                    let photos = photos, model = fingerprinter
                    let work = Task { () throws -> Fingerprint in
                        var loaded: LoadedRepresentation? = try await photos.readRepresentation(task.descriptor)
                        let lease = loaded!.lease
                        do {
                            guard loaded?.descriptor == task.descriptor,
                                  loaded?.eligibility == .safeSingleFrame else { throw PhotoKitGatewayError.libraryChanged }
                            let fingerprint = try await model.fingerprint(image: loaded!.image, orientation: loaded!.orientation)
                            // Release the last owned bitmap reference before making
                            // its physical budget slot available to another consumer.
                            loaded = nil
                            await lease.finishPhysicalWork()
                            return fingerprint
                        } catch {
                            loaded = nil
                            await lease.finishPhysicalWork()
                            throw error
                        }
                    }
                    do {
                        let fingerprint = try await work.value
                        let latest = try await photos.candidateSnapshot()
                        guard !needsReconciliation, !reconciling, latest.generation == expected else {
                            needsReconciliation = true; acknowledgedGeneration = nil; continue
                        }
                        _ = try await store.completeRepresentation(task, fingerprint: fingerprint)
                    } catch {
                        let latest = try? await photos.candidateSnapshot()
                        if needsReconciliation || reconciling || latest?.generation != expected {
                            needsReconciliation = true; acknowledgedGeneration = nil
                        } else {
                            let delays = configuration.resources.retryDelaysSeconds
                            let delay = delays[min(task.retryCount, delays.count - 1)]
                            try await store.failRepresentation(task, nextRetryAt: now.addingTimeInterval(delay), detail: String(describing: error))
                            issue = "部分图库图像暂时无法读取，正在等待重试。"
                        }
                    }
                }
            }
            if !needsReconciliation && !reconciling { try await publishIfComplete() }
        } catch {
            acknowledgedGeneration = nil; needsReconciliation = true
            issue = "图库索引正在等待恢复。"
            try? await store.invalidateIndexPublication()
        }
    }

    public func setPaused(_ paused: Bool) async { self.paused = paused }

    public func progress() async -> IndexProgress {
        do {
            let stored = try await store.indexProgress()
            let ready = try await readyToken() != nil
            let state: IndexState = ready ? .ready : (paused ? .paused :
                (issue != nil || stored.state == .waiting ? .waiting : (stored.totalsKnown ? .updating : .preparing)))
            return IndexProgress(state: state, totalsKnown: stored.totalsKnown && !needsReconciliation,
                totalAssets: stored.totalAssets, readyAssets: stored.readyAssets,
                totalRepresentations: stored.totalRepresentations, readyRepresentations: stored.readyRepresentations,
                excludedAssets: stored.excludedAssets, issue: issue)
        } catch {
            return IndexProgress(state: paused ? .paused : .waiting, totalsKnown: false, totalAssets: 0,
                readyAssets: 0, totalRepresentations: 0, readyRepresentations: 0, excludedAssets: 0,
                issue: "图库索引正在等待恢复。")
        }
    }

    public func readyToken() async throws -> IndexToken? {
        guard !needsReconciliation, !reconciling, let acknowledgedGeneration else { return nil }
        guard let publication = try await store.indexReadiness(),
              publication.token.photosGeneration == acknowledgedGeneration,
              await index.containsGeneration(publication.token.indexGeneration, entryCount: publication.entryCount),
              try await store.indexIsReady(token: publication.token) else { return nil }
        let snapshot = try await photos.candidateSnapshot()
        if snapshot.generation != acknowledgedGeneration {
            needsReconciliation = true; self.acknowledgedGeneration = nil
            try await store.invalidateIndexPublication()
            return nil
        }
        guard !needsReconciliation, !reconciling,
              self.acknowledgedGeneration == acknowledgedGeneration else { return nil }
        return publication.token
    }

    private func observe(_ event: PhotosIndexChange) async {
        changeSerial &+= 1; needsReconciliation = true; acknowledgedGeneration = nil
        try? await store.invalidateIndexPublication()
    }

    private func publishIfComplete() async throws {
        if try await readyToken() != nil { return }
        guard !needsReconciliation, let publication = try await store.indexPublication(),
              publication.token.photosGeneration == reconciledGeneration else { return }
        let snapshot = try await photos.candidateSnapshot()
        guard !needsReconciliation, snapshot.generation == publication.token.photosGeneration else { throw PhotoKitGatewayError.libraryChanged }
        if await !index.containsGeneration(publication.token.indexGeneration, entryCount: publication.entries.count) {
            try await index.replace(entries: publication.entries, generation: publication.token.indexGeneration)
        }
        guard !needsReconciliation, try await store.markIndexPublished(token: publication.token) else { throw PhotoKitGatewayError.libraryChanged }
        try await photos.acknowledgeReconciliation(expectedGeneration: publication.token.photosGeneration)
        let latest = try await photos.candidateSnapshot()
        guard !needsReconciliation, latest.generation == publication.token.photosGeneration,
              try await store.indexIsReady(token: publication.token) else { throw PhotoKitGatewayError.libraryChanged }
        acknowledgedGeneration = publication.token.photosGeneration; issue = nil
    }
}
