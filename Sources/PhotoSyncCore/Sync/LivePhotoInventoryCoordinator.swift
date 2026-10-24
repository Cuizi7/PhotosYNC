import Foundation

public actor LivePhotoInventoryCoordinator {
    private let store: SyncStore
    private let photos: any LivePhotoPhotosGateway
    private let metadata: any LivePhotoMetadataReading
    private let budget: LivePhotoResourceBudget
    private let batchSize: Int
    private let wallNow: @Sendable () -> Date
    private let diagnostics: IndexDiagnostics
    private var context: LibraryContext?
    private var paused = false, working = false
    private var active = false
    private var session: PhotosCatalogSession?
    private var offset = 0
    private let uptime: @Sendable () -> TimeInterval
    private let retentionSleep: @Sendable (TimeInterval) async throws -> Void
    private struct PendingItem {
        let id = UUID()
        let item: LivePhotoAssetDescriptor
        var observations = [LivePhotoObservation]()
        var validities = [LivePhotoResourceValidity]()
        var nextResource = 0
        var requiresAttention: Bool
        var expiresAt: TimeInterval?
    }
    private var pendingItem: PendingItem? {
        didSet { schedulePendingExpiry() }
    }
    private var pendingExpiry: Task<Void, Never>?
    private var consecutiveNativeItems = 0

    public init(store: SyncStore, photos: any LivePhotoPhotosGateway, metadata: any LivePhotoMetadataReading = LivePhotoMetadataReader(),
                budget: LivePhotoResourceBudget = .shared, batchSize: Int = 128, wallNow: @escaping @Sendable () -> Date = { Date() }, diagnostics: IndexDiagnostics? = nil,
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                retentionSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.uptime = uptime
        self.retentionSleep = retentionSleep
        self.diagnostics = diagnostics ?? IndexDiagnostics(sink: { _ in })
        self.store = store; self.photos = photos; self.metadata = metadata; self.budget = budget; self.batchSize = max(1, batchSize); self.wallNow = wallNow
        photos.attachIndexStore(store)
    }
    deinit { pendingExpiry?.cancel() }

    private func schedulePendingExpiry() {
        pendingExpiry?.cancel(); pendingExpiry = nil
        guard let retained = pendingItem, let deadline = retained.expiresAt else { return }
        let id = retained.id, delay = max(0, deadline - uptime()), sleep = retentionSleep
        // Neither the coordinator nor its observation/ticket owners are captured
        // across the wait. Replacing the continuation cancels this timer.
        pendingExpiry = Task { [weak self] in
            do { try await sleep(delay); try Task.checkCancellation() }
            catch { return }
            await self?.expirePendingItem(id: id)
        }
    }

    private func expirePendingItem(id: UUID) {
        guard let retained = pendingItem, retained.id == id, let deadline = retained.expiresAt else { return }
        guard deadline <= uptime() else { schedulePendingExpiry(); return }
        diagnostics.recordLivePhotoRetention(.parsedDiscarded)
        pendingItem = nil
    }

    public func setPaused(_ paused: Bool) async {
        self.paused = paused
        if paused {
            if pendingItem != nil { diagnostics.recordLivePhotoRetention(.parsedDiscarded) }
            pendingItem = nil; await photos.discardPendingLivePhotoReads()
        }
    }
    public func prepareContext() async throws -> LibraryContext {
        guard !paused else { throw CancellationError() }
        let indexContext = try await store.inventoryContext()
        let saved: LibraryContext?
        if let context { saved = context } else if let indexContext { saved = indexContext } else { saved = try await store.livePhotoSavedContext() }
        let binding: (anchors: [String], requiresProof: Bool)?
        if let saved { binding = try await store.livePhotoIdentityBinding(context: saved) } else { binding = nil }
        guard !paused else { throw CancellationError() }
        if context == nil, let saved { try await photos.restoreInventoryContext(saved) }
        guard !paused else { throw CancellationError() }
        let current = try await photos.livePhotoLibraryContext()
        guard saved == nil || saved?.id == current.id,
              try await photos.verifyLivePhotoContext(context: current, anchorAssetIDs: binding?.anchors ?? [], allowUnanchored: !(binding?.requiresProof ?? false)) else { throw PhotoKitGatewayError.libraryChanged }
        guard !paused else { throw CancellationError() }
        try await store.ensureLivePhotoInventory(context: current)
        if context == nil { try await store.refreshLegacyLivePhotoVideoDescriptors(context: current) }
        context = current
        return current
    }
    public func resumeInitialInventory() async throws {
        guard !paused, !working else { return }
        working = true; defer { working = false }
        let context = try await prepareContext()
        let summary = try await store.livePhotoInventorySummary(context: context)
        guard summary.phase == .enumerating else { return }
        active = true; defer { active = false }
        do {
            if session == nil {
                let snapshot = try await photos.candidateSnapshot()
                session = try await photos.beginCatalogSession(expectedGeneration: snapshot.generation)
                offset = 0
            }
            guard let session else { return }
            while !paused, !Task.isCancelled {
                let page = try await photos.livePhotoAssetCatalog(session: session, offset: offset, limit: batchSize)
                guard page.context == context else { throw PhotoKitGatewayError.libraryChanged }
                try await store.enqueueLivePhotoAssets(context: context, assets: page.assets)
                if let next = page.nextOffset { offset = next; await Task.yield(); continue }
                let endpoint = try await photos.catalogCoverage(session: session)
                var after: String?
                repeat {
                    let changes = try await photos.catalogChanges(baselineGeneration: session.baselineGeneration, throughGeneration: endpoint, afterAssetID: after, limit: batchSize)
                    if !changes.changedAssetIDs.isEmpty || !changes.deletedAssetIDs.isEmpty {
                        try await store.applyLivePhotoDelta(.init(context: context, fromGeneration: session.baselineGeneration, toGeneration: endpoint, changedAssetIDs: changes.changedAssetIDs, deletedAssetIDs: changes.deletedAssetIDs))
                    }
                    if !changes.changedAssetIDs.isEmpty {
                        let changed = try await photos.livePhotoAssets(assetIDs: changes.changedAssetIDs, context: context)
                        try await store.enqueueLivePhotoAssets(context: context, assets: changed)
                    }
                    after = changes.nextAssetID
                } while after != nil && !paused
                guard !paused, try await photos.candidateSnapshot().generation == endpoint else { throw PhotoKitGatewayError.libraryChanged }
                try await store.finishLivePhotoEnumeration(context: context, generation: endpoint)
                self.session = nil; offset = 0
                return
            }
        } catch {
            session = nil; offset = 0
            throw error
        }
    }

    public func processNextInventoryItem(now: Date) async throws -> Bool {
        guard !paused, !working else { return false }
        working = true; defer { working = false }
        let context: LibraryContext
        do { context = try await prepareContext() }
        catch { pendingItem = nil; await photos.discardPendingLivePhotoReads(); throw error }
        let refresh = try await store.livePhotoAssetsNeedingDescriptor(context: context, now: now, limit: batchSize)
        if !refresh.isEmpty {
            let assets = try await photos.livePhotoAssets(assetIDs: refresh, context: context)
            guard !paused else { return false }
            try await store.enqueueLivePhotoAssets(context: context, assets: assets)
            for id in refresh where !assets.contains(where: { $0.assetID == id }) {
                try await store.markLivePhotoDescriptorUnresolved(context: context, assetID: id)
            }
        }
        if let retained = pendingItem, retained.item.context != context || (retained.expiresAt ?? 0) <= uptime() {
            diagnostics.recordLivePhotoRetention(.parsedDiscarded)
            pendingItem = nil; await photos.discardPendingLivePhotoReads()
        }
        let next: LivePhotoAssetDescriptor?
        if let retained = pendingItem { next = retained.item }
        else { next = try await store.nextLivePhotoInventoryItem(context: context, now: now, preferNative: consecutiveNativeItems < 8) }
        guard let item = next else {
            try await finishIfReady(context: context)
            return false
        }
        guard !paused, try await photos.livePhotoLibraryContext() == context else { return false }
        active = true; defer { active = false }
        var work = pendingItem ?? PendingItem(item: item, requiresAttention: item.resources.isEmpty)
        let resuming = pendingItem != nil
        pendingItem = nil
        do {
            try work.validities.forEach { try $0.requireCurrent() }
            if resuming { diagnostics.recordLivePhotoRetention(.parsedResumed) }
            if LivePhotoIdentificationPolicy.excludesVideo(kind: item.mediaKind, duration: item.duration, isLivePhoto: item.isLivePhoto), !item.resources.isEmpty,
               try await !store.hasCurrentLivePhotoIdentity(context: context, assetID: item.assetID, revision: item.revision) {
                guard !paused, try await photos.livePhotoAssets(assetIDs: [item.assetID], context: context).first == item else { throw LivePhotoReadDeferred.resourceChanged }
                guard !paused else { return false }
                try await store.recordLivePhotoInventoryResult(context: context, assetID: item.assetID, revision: item.revision,
                    observations: item.resources.map { .init(resource: $0, inspection: .excludedByDuration) }, retryPolicy: .requiresAttention)
                consecutiveNativeItems = 0
                try await finishIfReady(context: context)
                return true
            }
            for (index, ref) in item.resources.enumerated() {
                guard index >= work.nextResource else { continue }
                guard index < item.resourceKinds.count, let kind = item.resourceKinds[index] else { continue }
                guard !paused else { return false }
                if !work.validities.isEmpty {
                    try Task.checkCancellation()
                    try work.validities.forEach { try $0.requireCurrent() }
                }
                do {
                    let lease = try await photos.readLivePhotoResource(ref, purpose: .inventory, budget: budget)
                    guard !paused else { return false }
                    let result = try await diagnostics.measureLivePhoto(.metadata, assetID: item.assetID) {
                        try await self.metadata.inspect(resource: lease, kind: kind)
                    }
                    try Task.checkCancellation()
                    guard !paused else { return false }
                    if let validity = lease.validity { work.validities.append(validity) }
                    if case .unresolved = result { work.requiresAttention = true }
                    work.observations.append(.init(resource: ref, inspection: result))
                    work.nextResource = index + 1
                    try work.validities.forEach { try $0.requireCurrent() }
                } catch {
                    if error is ReadExecutorError || error is CancellationError || error is LivePhotoReadDeferred { throw error }
                    if case .libraryChanged = error as? PhotoKitGatewayError { throw error }
                    if case .budgetBusy = error as? LivePhotoResourceReadError { throw error }
                    let limited: Bool
                    switch error as? LivePhotoResourceReadError { case .resourceLimit, .workingSetLimit: limited = true; default: limited = false }
                    if limited { work.requiresAttention = true }
                    let detail = limited ? "资源读取超过 \(budget.limits.maxEncodedBytes / 1_048_576) MiB 上限，已跳过 Live Photo 识别。" : "原资源暂不可读：" + SourceIssueText.systemDiagnostic(error)
                    work.observations.append(.init(resource: ref, inspection: .unresolved(detail), resourceLimitBytes: limited ? budget.limits.maxEncodedBytes : nil))
                    work.nextResource = index + 1
                }
            }
            guard !paused, try await photos.livePhotoLibraryContext() == context else { return false }
            // The read already used its one bounded classification wait. A later pending
            // event defers immediately; never enqueue another unbounded snapshot behind it.
            try Task.checkCancellation()
            try work.validities.forEach { try $0.requireCurrent() }
            try await diagnostics.measureLivePhoto(.descriptorValidation, assetID: item.assetID) {
                guard let current = try await self.photos.livePhotoAssets(assetIDs: [item.assetID], context: context).first,
                      current == item else { throw LivePhotoReadDeferred.resourceChanged }
                try work.validities.forEach { try $0.requireCurrent() }
            }
            try Task.checkCancellation()
            guard !paused else { return false }
            let tickets = work.validities
            try await diagnostics.measureLivePhoto(.observationCommit, assetID: item.assetID) {
                try await self.store.recordLivePhotoInventoryResult(context: context, assetID: item.assetID, revision: item.revision, observations: work.observations, retryPolicy: (work.requiresAttention || work.observations.isEmpty) ? .requiresAttention : .automatic(nextRetryAt: self.wallNow().addingTimeInterval(60)), observationsAreCurrent: { try tickets.forEach { try $0.requireCurrent() }; return true })
            }
            consecutiveNativeItems = item.isLivePhoto ? min(8, consecutiveNativeItems + 1) : 0
            try await finishIfReady(context: context)
            return true
        } catch LivePhotoReadDeferred.classificationPending {
            if !paused, !Task.isCancelled {
                if work.expiresAt == nil { work.expiresAt = uptime() + 30 }
                if work.expiresAt! > uptime() { pendingItem = work; diagnostics.recordLivePhotoRetention(.parsedRetained) }
                else { await photos.discardPendingLivePhotoReads() }
            } else { await photos.discardPendingLivePhotoReads() }
            throw LivePhotoReadDeferred.classificationPending
        } catch LivePhotoReadDeferred.resourceChanged {
            await photos.discardPendingLivePhotoReads()
            try store.recordLivePhotoChanges(context: context, changed: [item.assetID], deleted: [])
            throw LivePhotoReadDeferred.resourceChanged
        } catch {
            await photos.discardPendingLivePhotoReads()
            throw error
        }
    }

    public func retryAttention(now: Date) async throws {
        let context = try await prepareContext()
        _ = try await store.retryLivePhotoInventoryAttention(context: context, now: now)
    }

    private func finishIfReady(context: LibraryContext) async throws {
        let snapshot = try await photos.candidateSnapshot()
        // Typed producer facts are durable before this snapshot can be returned. New queued rows keep completion closed.
        let current = try await store.livePhotoInventorySummary(context: context)
        guard current.phase != .enumerating else { return }
        try await store.finishLivePhotoEnumeration(context: context, generation: snapshot.generation)
        _ = try await store.completeLivePhotoInventory(context: context, expectedGeneration: snapshot.generation)
    }
    public func activity(now: Date? = nil, summary provided: LivePhotoInventorySummary? = nil) async -> LivePhotoActivity {
        let summary: LivePhotoInventorySummary
        if let provided { summary = provided }
        else if let stored = try? await self.summary() { summary = stored }
        else { return .waiting(nextRetryAt: nil) }
        let unfinished = summary.phase != .completed || summary.pending > 0 || summary.unresolved > 0
        if !unfinished && !active { return .idle }
        let admission = await photos.livePhotoReadAdmission()
        if admission == .draining || admission == .stalled { return .draining }
        if active { return .working(.identification) }
        let due = summary.phase != .completed || summary.pending > 0 || summary.nextRetryAt.map { $0 <= (now ?? wallNow()) } == true
        if !paused, admission == .available || admission == .busy, due { return .queued(.identification) }
        if summary.requiresAttention > 0 { return .requiresAttention(SourceIssue(summary: "部分项目无法自动识别配对关系，请查看任务说明。", detail: "Inventory has held unresolved resources", kind: .file)) }
        if summary.phase != .completed || summary.pending > 0 || summary.retryWaiting > 0 { return .waiting(nextRetryAt: summary.nextRetryAt) }
        return .idle
    }
    public func summary() async throws -> LivePhotoInventorySummary {
        guard let context else { return .init() }
        return try await store.livePhotoInventorySummary(context: context)
    }
}
