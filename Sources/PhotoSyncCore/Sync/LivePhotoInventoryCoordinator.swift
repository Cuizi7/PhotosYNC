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

    public init(store: SyncStore, photos: any LivePhotoPhotosGateway, metadata: any LivePhotoMetadataReading = LivePhotoMetadataReader(),
                budget: LivePhotoResourceBudget = .shared, batchSize: Int = 128, wallNow: @escaping @Sendable () -> Date = { Date() }, diagnostics: IndexDiagnostics? = nil) {
        self.diagnostics = diagnostics ?? IndexDiagnostics(sink: { _ in })
        self.store = store; self.photos = photos; self.metadata = metadata; self.budget = budget; self.batchSize = max(1, batchSize); self.wallNow = wallNow
        photos.attachIndexStore(store)
    }
    public func setPaused(_ paused: Bool) { self.paused = paused }
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
        let context = try await prepareContext()
        let refresh = try await store.livePhotoAssetsNeedingDescriptor(context: context, now: now, limit: batchSize)
        if !refresh.isEmpty {
            let assets = try await photos.livePhotoAssets(assetIDs: refresh, context: context)
            guard !paused else { return false }
            try await store.enqueueLivePhotoAssets(context: context, assets: assets)
            for id in refresh where !assets.contains(where: { $0.assetID == id }) {
                try await store.markLivePhotoDescriptorUnresolved(context: context, assetID: id)
            }
        }
        guard let item = try await store.nextLivePhotoInventoryItem(context: context, now: now) else {
            try await finishIfReady(context: context)
            return false
        }
        guard !paused, try await photos.livePhotoLibraryContext() == context else { return false }
        active = true; defer { active = false }
        do {
            var requiresAttention = item.resources.isEmpty
            var observations = [LivePhotoObservation]()
            var validities = [LivePhotoResourceValidity]()
            for (index, ref) in item.resources.enumerated() {
                guard index < item.resourceKinds.count, let kind = item.resourceKinds[index] else { continue }
                guard !paused else { return false }
                if !validities.isEmpty {
                    try Task.checkCancellation()
                    try validities.forEach { try $0.requireCurrent() }
                }
                do {
                    let lease = try await photos.readLivePhotoResource(ref, purpose: .inventory, budget: budget)
                    guard !paused else { return false }
                    let result = try await diagnostics.measureLivePhoto(.metadata, assetID: item.assetID) {
                        try await self.metadata.inspect(resource: lease, kind: kind)
                    }
                    try Task.checkCancellation()
                    guard !paused else { return false }
                    if let validity = lease.validity { try validity.requireCurrent(); validities.append(validity) }
                    if case .unresolved = result { requiresAttention = true }
                    observations.append(.init(resource: ref, inspection: result))
                } catch {
                    if error is ReadExecutorError || error is CancellationError || error is LivePhotoReadDeferred { throw error }
                    if case .libraryChanged = error as? PhotoKitGatewayError { throw error }
                    if case .budgetBusy = error as? LivePhotoResourceReadError { throw error }
                    if case .resourceLimit = error as? LivePhotoResourceReadError { requiresAttention = true }
                    if case .workingSetLimit = error as? LivePhotoResourceReadError { requiresAttention = true }
                    observations.append(.init(resource: ref, inspection: .unresolved("原资源暂不可读：" + SourceIssueText.systemDiagnostic(error))))
                }
            }
            guard !paused, try await photos.livePhotoLibraryContext() == context else { return false }
            // The read already used its one bounded classification wait. A later pending
            // event defers immediately; never enqueue another unbounded snapshot behind it.
            try Task.checkCancellation()
            try validities.forEach { try $0.requireCurrent() }
            try await diagnostics.measureLivePhoto(.descriptorValidation, assetID: item.assetID) {
                guard let current = try await self.photos.livePhotoAssets(assetIDs: [item.assetID], context: context).first,
                      current == item else { throw LivePhotoReadDeferred.resourceChanged }
                try validities.forEach { try $0.requireCurrent() }
            }
            try Task.checkCancellation()
            guard !paused else { return false }
            let tickets = validities
            try await diagnostics.measureLivePhoto(.observationCommit, assetID: item.assetID) {
                try await self.store.recordLivePhotoInventoryResult(context: context, assetID: item.assetID, revision: item.revision, observations: observations, retryPolicy: (requiresAttention || observations.isEmpty) ? .requiresAttention : .automatic(nextRetryAt: self.wallNow().addingTimeInterval(60)), observationsAreCurrent: { try tickets.forEach { try $0.requireCurrent() }; return true })
            }
            try await finishIfReady(context: context)
            return true
        } catch LivePhotoReadDeferred.resourceChanged {
            try store.recordLivePhotoChanges(context: context, changed: [item.assetID], deleted: [])
            throw LivePhotoReadDeferred.resourceChanged
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
        if !paused, admission == .available, due { return .queued(.identification) }
        if summary.requiresAttention > 0 { return .requiresAttention(SourceIssue(summary: "部分 Live Photo 无法自动分析，请重新尝试或查看诊断。", detail: "Inventory has held unresolved resources", kind: .file)) }
        if summary.phase != .completed || summary.pending > 0 || summary.retryWaiting > 0 { return .waiting(nextRetryAt: summary.nextRetryAt) }
        return .idle
    }
    public func summary() async throws -> LivePhotoInventorySummary {
        guard let context else { return .init() }
        return try await store.livePhotoInventorySummary(context: context)
    }
}
