import Foundation

/// Owns one bounded work loop and the durable-inventory → derived-index → Photos
/// acknowledgement barrier. SQLite never waits for Photos or model work.
public actor PhotosIndexCoordinator {
    private let store: SyncStore
    private let photos: any PhotosIndexGateway
    private let fingerprinter: any ImageFingerprinting
    private let configuration: DedupConfiguration
    private var observer: Task<Void, Never>?
    private var started = false, paused = false, reconciling = false, processing = false
    private var pendingDelta: PhotosIndexDelta?
    private var pendingReinsertedIDs = Set<String>()
    private var reconciledContext: LibraryContext?
    private var applyingDelta = false
    private var needsReconciliation = true
    private var forceCacheInvalidation = true
    private var changeSerial: UInt64 = 0
    private var reconciledGeneration: Int?
    private var acknowledgedGeneration: Int?
    private var issue: String?
    // A successful catalog does not resolve failed reads. Retain explicit cloud
    // classification only while the same descriptor remains a current failed fact.
    private var cloudWaiting: [String: RepresentationDescriptor] = [:]
    private let diagnostics: @Sendable ([String: String]) -> Void

    public init(store: SyncStore, photos: any PhotosIndexGateway, fingerprinter: any ImageFingerprinting,
                configuration: DedupConfiguration,
                diagnostics: @escaping @Sendable ([String: String]) -> Void = { _ in }) {
        self.store = store; self.photos = photos; self.fingerprinter = fingerprinter
        self.configuration = configuration; self.diagnostics = diagnostics
    }

    deinit { observer?.cancel() }

    public func reconcile() async throws {
        guard !paused else { throw CancellationError() }
        guard !reconciling else { throw PhotoKitGatewayError.libraryChanged }
        reconciling = true; acknowledgedGeneration = nil; pendingDelta = nil; pendingReinsertedIDs.removeAll()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var counts = IndexMutationCounts()
        var complete = false
        defer {
            reconciling = false
            diagnostics(["phase": "index-reconcile", "unit": "representationRows", "batch": complete ? "completed" : "aborted",
                "added": String(counts.added), "changed": String(counts.changed), "deleted": String(counts.deleted),
                "timingMS.catalogReconciliation": String((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)])
        }
        do {
            if !started {
                started = true
                // Subscribe before replay. Pages, not stream delivery order, own
                // authoritative content invalidation for this reconciliation.
                let events = photos.changes()
                observer = Task { [weak self] in
                    for await event in events {
                        guard !Task.isCancelled else { break }
                        await self?.libraryChanged(event)
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
            var seenKeys = Set<RepresentationKey>()
            var context: LibraryContext?
            var allInvalidated = false
            repeat {
                // Pause may arrive while the previous page/transaction was in flight.
                // Preserve that page, but do not start another catalog request.
                guard !paused else { throw CancellationError() }
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
                let mutations = try await store.upsertRepresentations(page.descriptors, generation: current)
                counts.added += mutations.added; counts.changed += mutations.changed
                seenKeys.formUnion(page.descriptors.map(\.key))
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
            guard let finish = try await store.finishIndexReconciliation(generation: generation!, seenKeys: seenKeys, checkpoint: checkpoint,
                excludedAssetIDs: excludedAssets.subtracting(eligibleAssets)) else { throw PhotoKitGatewayError.libraryChanged }
            counts.deleted += finish.deleted
            complete = true
            let retainedCloudFailures = try await store.currentFailedRepresentations(Array(cloudWaiting.values),
                fingerprintVersion: configuration.fingerprint.version)
            guard !paused else { throw CancellationError() }
            let after = try await photos.candidateSnapshot()
            guard after.generation == snapshot.generation, changeSerial == serial else { throw PhotoKitGatewayError.libraryChanged }
            needsReconciliation = false; forceCacheInvalidation = false
            reconciledGeneration = snapshot.generation; reconciledContext = context; issue = nil
            cloudWaiting = Dictionary(uniqueKeysWithValues: retainedCloudFailures.map { (Self.waitKey($0), $0) })
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
        var completed = 0, failed = 0
        defer {
            processing = false
            if completed > 0 || failed > 0 {
                diagnostics(["phase": "index-work", "unit": "representationTasks", "completed": String(completed),
                             "failed": String(failed), "batch": paused || needsReconciliation ? "interrupted" : "completed"])
            }
        }
        do {
            try await updateInventory()
            guard !paused, !needsReconciliation, !reconciling else { return }
            while !paused && !needsReconciliation && !reconciling {
                try await updateInventory()
                guard !paused, !needsReconciliation, !reconciling, pendingDelta == nil else { break }
                // Serial consumer keeps physical image/model concurrency at one,
                // below every configured limit. Polling itself never claims work.
                let tasks = try await store.nextRepresentationTasks(now: now,
                    limit: min(configuration.resources.catalogBatchSize, configuration.resources.maxInFlightTasks))
                guard !tasks.isEmpty else { break }
                let batchGeneration = reconciledGeneration
                for task in tasks {
                    guard !paused, !needsReconciliation, !reconciling, pendingDelta == nil, reconciledGeneration == batchGeneration else { break }
                    let expected = reconciledGeneration
                    let snapshot = try await photos.candidateSnapshot()
                    // Snapshot acquisition suspends this actor. Admit no new
                    // physical work if pause or reconciliation changed meanwhile.
                    guard !paused, !needsReconciliation, !reconciling,
                          reconciledGeneration == expected else { break }
                    guard snapshot.generation == expected else {
                        if pendingDelta == nil { needsReconciliation = true }
                        acknowledgedGeneration = nil; break
                    }
                    // An unstructured owned Task does not inherit later caller
                    // cancellation. Pause cannot cancel already-started consumers.
                    let photos = photos, model = fingerprinter, diagnostics = diagnostics
                    let work = Task { () throws -> Fingerprint in
                        var fields = ["phase": "index-representation-timing", "asset": task.descriptor.key.assetID,
                                      "representation": task.descriptor.key.kind.rawValue]
                        let readStarted = ProcessInfo.processInfo.systemUptime
                        defer {
                            if fields["timingMS.representationReadWait"] == nil {
                                fields["timingMS.representationReadWait"] = String((ProcessInfo.processInfo.systemUptime - readStarted) * 1000)
                            }
                            diagnostics(fields)
                        }
                        var loaded: LoadedRepresentation? = try await photos.readRepresentation(task.descriptor)
                        fields["timingMS.representationReadWait"] = String((ProcessInfo.processInfo.systemUptime - readStarted) * 1000)
                        let lease = loaded!.lease
                        do {
                            guard loaded?.descriptor == task.descriptor,
                                  loaded?.eligibility == .safeSingleFrame else { throw PhotoKitGatewayError.libraryChanged }
                            let fingerprintStarted = ProcessInfo.processInfo.systemUptime
                            let fingerprint: Fingerprint
                            do {
                                defer { fields["timingMS.fingerprintPreprocessInference"] = String((ProcessInfo.processInfo.systemUptime - fingerprintStarted) * 1000) }
                                fingerprint = try await model.fingerprint(image: loaded!.image, orientation: loaded!.orientation)
                            }
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
                    let waitKey = Self.waitKey(task.descriptor)
                    do {
                        let fingerprint = try await work.value
                        // Resolve observed changes before deciding whether this *task* is stale.
                        // SQLite issuance/descriptor checks accept unaffected work across generations.
                        if !paused { try await updateInventory() }
                        let latest = try await photos.candidateSnapshot()
                        guard !needsReconciliation, !reconciling, pendingDelta == nil,
                              latest.generation == reconciledGeneration else {
                            acknowledgedGeneration = nil; continue
                        }
                        if try await store.completeRepresentation(task, fingerprint: fingerprint) {
                            completed += 1; cloudWaiting.removeValue(forKey: waitKey)
                        }
                    } catch {
                        let latest = try? await photos.candidateSnapshot()
                        if needsReconciliation || reconciling || pendingDelta != nil || latest?.generation != reconciledGeneration {
                            if pendingDelta == nil { needsReconciliation = true }; acknowledgedGeneration = nil
                        } else {
                            let delays = configuration.resources.retryDelaysSeconds
                            let delay = delays[min(task.retryCount, delays.count - 1)]
                            if try await store.failRepresentation(task, nextRetryAt: now.addingTimeInterval(delay), detail: String(describing: error)) {
                                failed += 1
                                diagnostics(["phase": "index-representation", "result": "waiting", "asset": task.descriptor.key.assetID,
                                    "representation": task.descriptor.key.kind.rawValue, "error": String(describing: error)])
                                if case .iCloudUnavailable = error as? PhotosRepresentationError { cloudWaiting[waitKey] = task.descriptor }
                                else { cloudWaiting.removeValue(forKey: waitKey) }
                            }
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
            let representationIssue = stored.state == .waiting
                ? (cloudWaiting.isEmpty ? stored.issue : "正在等待 iCloud 图像，连接恢复后自动继续") : nil
            let aggregateIssue = issue ?? representationIssue
            let state: IndexState = ready ? .ready : (paused ? .paused :
                (aggregateIssue != nil || stored.state == .waiting ? .waiting : (stored.totalsKnown ? .updating : .preparing)))
            return IndexProgress(state: state, totalsKnown: stored.totalsKnown && !needsReconciliation,
                totalAssets: stored.totalAssets, readyAssets: stored.readyAssets,
                totalRepresentations: stored.totalRepresentations, readyRepresentations: stored.readyRepresentations,
                excludedAssets: stored.excludedAssets, issue: aggregateIssue)
        } catch {
            return IndexProgress(state: paused ? .paused : .waiting, totalsKnown: false, totalAssets: 0,
                readyAssets: 0, totalRepresentations: 0, readyRepresentations: 0, excludedAssets: 0,
                issue: "图库索引正在等待恢复。")
        }
    }

    public func readyToken() async throws -> IndexToken? {
        guard !needsReconciliation, !reconciling, !applyingDelta, pendingDelta == nil, let acknowledgedGeneration else { return nil }
        guard let publication = try await store.indexReadiness(),
              publication.token.photosGeneration == acknowledgedGeneration,
              try await store.indexIsReady(token: publication.token) else { return nil }
        let snapshot = try await photos.candidateSnapshot()
        if snapshot.generation != acknowledgedGeneration {
            if pendingDelta == nil { needsReconciliation = true }; self.acknowledgedGeneration = nil
            try await store.invalidateIndexPublication()
            return nil
        }
        guard !needsReconciliation, !reconciling, pendingDelta == nil,
              self.acknowledgedGeneration == acknowledgedGeneration else { return nil }
        return publication.token
    }

    private static func waitKey(_ descriptor: RepresentationDescriptor) -> String {
        "\(descriptor.key.assetID.utf8.count):\(descriptor.key.assetID):\(descriptor.key.kind.rawValue)"
    }

    /// Both runtime wakeups and this actor's subscription may deliver the same event.
    /// A fully covered incremental delivery is idempotent; gaps/overlap/overflow are full.
    public func libraryChanged(_ event: PhotosIndexChange) async {
        if case .incremental(let delta) = event, delta.isValid,
           delta.changedAssetIDs.count + delta.deletedAssetIDs.count <= configuration.resources.catalogBatchSize {
            let through = pendingDelta?.toGeneration ?? reconciledGeneration
            if delta.context == reconciledContext, let through, delta.toGeneration <= through { return }
        }
        changeSerial &+= 1; acknowledgedGeneration = nil
        switch event {
        case .incremental(let delta):
            if !needsReconciliation, !reconciling, delta.isValid, delta.context == reconciledContext,
               delta.fromGeneration == (pendingDelta?.toGeneration ?? reconciledGeneration) {
                pendingReinsertedIDs.formUnion(Set(pendingDelta?.deletedAssetIDs ?? []).intersection(delta.changedAssetIDs))
                var changed = Set(pendingDelta?.changedAssetIDs ?? [])
                var deleted = Set(pendingDelta?.deletedAssetIDs ?? [])
                changed.subtract(delta.deletedAssetIDs); deleted.formUnion(delta.deletedAssetIDs)
                deleted.subtract(delta.changedAssetIDs); changed.formUnion(delta.changedAssetIDs)
                if changed.count + deleted.count <= configuration.resources.catalogBatchSize {
                    pendingDelta = .init(context: delta.context, fromGeneration: pendingDelta?.fromGeneration ?? delta.fromGeneration,
                        toGeneration: delta.toGeneration, changedAssetIDs: changed.sorted(), deletedAssetIDs: deleted.sorted())
                } else { pendingDelta = nil; pendingReinsertedIDs.removeAll(); needsReconciliation = true }
            } else { pendingDelta = nil; pendingReinsertedIDs.removeAll(); needsReconciliation = true }
        case .fullReconcileRequired, .contextInvalidated:
            pendingDelta = nil; pendingReinsertedIDs.removeAll(); needsReconciliation = true
        }
        try? await store.invalidateIndexPublication()
    }

    private func updateInventory() async throws {
        guard !paused, !applyingDelta else { return }
        if needsReconciliation { try await reconcile(); return }
        guard let delta = pendingDelta else { return }
        applyingDelta = true
        defer { applyingDelta = false }
        let serial = changeSerial
        let reinserted = pendingReinsertedIDs
        do {
            let checkpoint = try await photos.contextCheckpoint()
            guard !paused, serial == changeSerial else { throw PhotoKitGatewayError.libraryChanged }
            let page = try await photos.representationDelta(delta)
            guard !paused, serial == changeSerial,
                  page.descriptors.count + page.exclusions.count <= configuration.resources.catalogBatchSize else { throw PhotoKitGatewayError.libraryChanged }
            let effectivePage = RepresentationPage(context: page.context, generation: page.generation, descriptors: page.descriptors,
                nextOffset: page.nextOffset, exclusions: page.exclusions,
                invalidatedAssetIDs: Set(page.invalidatedAssetIDs).union(reinserted.intersection(delta.changedAssetIDs)).sorted(),
                invalidateAllCachedRepresentations: page.invalidateAllCachedRepresentations)
            _ = try await store.applyIndexDelta(delta, page: effectivePage,
                fingerprintVersion: configuration.fingerprint.version, checkpoint: checkpoint)
            guard !paused, serial == changeSerial else { throw PhotoKitGatewayError.libraryChanged }
            let snapshot = try await photos.candidateSnapshot()
            guard !paused, serial == changeSerial, snapshot.generation == delta.toGeneration else { throw PhotoKitGatewayError.libraryChanged }
            let affected = Set(delta.changedAssetIDs + delta.deletedAssetIDs)
            let retained = try await store.currentFailedRepresentations(cloudWaiting.values.filter { affected.contains($0.key.assetID) },
                fingerprintVersion: configuration.fingerprint.version)
            guard !paused, serial == changeSerial else { throw PhotoKitGatewayError.libraryChanged }
            cloudWaiting = cloudWaiting.filter { !affected.contains($0.value.key.assetID) }
            for descriptor in retained { cloudWaiting[Self.waitKey(descriptor)] = descriptor }
            pendingDelta = nil; pendingReinsertedIDs.removeAll(); reconciledGeneration = delta.toGeneration; issue = nil
        } catch {
            pendingDelta = nil; pendingReinsertedIDs.removeAll(); needsReconciliation = true; acknowledgedGeneration = nil
            try? await store.invalidateIndexPublication()
            // Missing IDs, partial pages and racing generations never imply deletion.
            // A bounded full pass is the authoritative recovery, including empty deltas.
            if !paused { try await reconcile() } else { throw error }
        }
    }

    private func publishIfComplete() async throws {
        if try await readyToken() != nil { return }
        guard !needsReconciliation, pendingDelta == nil, let publication = try await store.indexPublication(),
              publication.token.photosGeneration == reconciledGeneration else { return }
        let snapshot = try await photos.candidateSnapshot()
        guard !needsReconciliation, pendingDelta == nil, snapshot.generation == publication.token.photosGeneration else { throw PhotoKitGatewayError.libraryChanged }
        guard !needsReconciliation, pendingDelta == nil, try await store.markIndexPublished(token: publication.token) else { throw PhotoKitGatewayError.libraryChanged }
        try await photos.acknowledgeReconciliation(expectedGeneration: publication.token.photosGeneration)
        let latest = try await photos.candidateSnapshot()
        guard !needsReconciliation, pendingDelta == nil, latest.generation == publication.token.photosGeneration,
              try await store.indexIsReady(token: publication.token) else { throw PhotoKitGatewayError.libraryChanged }
        acknowledgedGeneration = publication.token.photosGeneration; issue = nil; cloudWaiting.removeAll()
    }
}
