import Foundation

public actor LivePhotoInventoryCoordinator {
    private let store: SyncStore
    private let photos: any LivePhotoPhotosGateway
    private let metadata: any LivePhotoMetadataReading
    private let budget: LivePhotoResourceBudget
    private let batchSize: Int
    private var context: LibraryContext?
    private var paused = false, working = false
    private var session: PhotosCatalogSession?
    private var offset = 0

    public init(store: SyncStore, photos: any LivePhotoPhotosGateway, metadata: any LivePhotoMetadataReading = LivePhotoMetadataReader(),
                budget: LivePhotoResourceBudget = .shared, batchSize: Int = 128) {
        self.store = store; self.photos = photos; self.metadata = metadata; self.budget = budget; self.batchSize = max(1, batchSize)
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
        let readGeneration = try await photos.candidateSnapshot().generation
        var observations = [LivePhotoObservation]()
        for (index, ref) in item.resources.enumerated() {
            guard index < item.resourceKinds.count, let kind = item.resourceKinds[index] else { continue }
            guard !paused else { return false }
            do {
                let lease = try await photos.readLivePhotoResource(ref, purpose: .inventory, budget: budget)
                let result = try await metadata.inspect(resource: lease, kind: kind)
                observations.append(.init(resource: ref, inspection: result))
            } catch {
                if error is ReadExecutorError || error is CancellationError { throw error }
                observations.append(.init(resource: ref, inspection: .unresolved("原资源暂不可读：" + SourceIssueText.systemDiagnostic(error))))
            }
        }
        guard !paused, try await photos.livePhotoLibraryContext() == context else { return false }
        guard try await photos.candidateSnapshot().generation == readGeneration else { throw PhotoKitGatewayError.libraryChanged }
        try await store.recordLivePhotoInventoryResult(context: context, assetID: item.assetID, revision: item.revision, observations: observations)
        try await finishIfReady(context: context)
        return true
    }

    private func finishIfReady(context: LibraryContext) async throws {
        let snapshot = try await photos.candidateSnapshot()
        // Typed producer facts are durable before this snapshot can be returned. New queued rows keep completion closed.
        let current = try await store.livePhotoInventorySummary(context: context)
        guard current.phase != .enumerating else { return }
        try await store.finishLivePhotoEnumeration(context: context, generation: snapshot.generation)
        _ = try await store.completeLivePhotoInventory(context: context, expectedGeneration: snapshot.generation)
    }
    public func summary() async throws -> LivePhotoInventorySummary {
        guard let context else { return .init() }
        return try await store.livePhotoInventorySummary(context: context)
    }
}
