import Foundation
import Photos

enum PhotoKitAccess: Sendable, Equatable { case notDetermined, authorized, denied }

struct PhotoKitCreateCommand: Equatable, Sendable {
    let fileURL: URL
    let kind: MediaKind
    let shouldMoveFile: Bool
}

enum PhotoKitSubmissionResult: Sendable {
    case committed(identifier: String)
    case checkpointFailed
    case preventedBeforeMutation
}

enum PhotoKitSubmissionError: Error {
    case checkpointFailed(Error)
}

struct PhotoKitCandidateAsset: Sendable {
    let identifier: String
    let candidates: [MatchCandidate]
}

enum PhotoKitCandidateIndexChange: Sendable {
    case incremental(
        removedAssetIDs: Set<String>,
        insertedAssets: [PhotoKitCandidateAsset],
        changedAssets: [PhotoKitCandidateAsset]
    )
    case reload
}

protocol PhotoKitLifecycle: Sendable {
    func currentAccess() -> PhotoKitAccess
    func requestReadWriteAuthorization() async -> PhotoKitAccess
    func isAvailable() -> Bool
    func loadCandidateAssets() throws -> [PhotoKitCandidateAsset]
    func candidateIndexChange(for change: PHChange?) throws -> PhotoKitCandidateIndexChange
    func submit(
        _ command: PhotoKitCreateCommand,
        beforeMutation: @escaping @Sendable () -> Bool,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> PhotoKitSubmissionResult
    func fetch(identifier: String) throws -> Bool
    func representationCatalog(offset: Int, limit: Int, context: LibraryContext, generation: Int) throws -> RepresentationPage
    func archivedChangeToken() throws -> Data?
    func replayPersistentChanges(_ token: Data, onChange: (PhotosIndexChange) -> Void, onContentChange: ([String]) -> Void) throws -> Bool
}

extension PhotoKitLifecycle {
    func representationCatalog(offset: Int, limit: Int, context: LibraryContext, generation: Int) throws -> RepresentationPage {
        throw PhotosRepresentationError.unavailable
    }
    func archivedChangeToken() throws -> Data? { nil }
    func replayPersistentChanges(_ token: Data, onChange: (PhotosIndexChange) -> Void, onContentChange: ([String]) -> Void) throws -> Bool { false }
}

public final class PhotoKitGateway: NSObject, PhotosIndexGateway, @unchecked Sendable {
    private static let candidateLoadAttempts = 3
    private let lifecycle: any PhotoKitLifecycle
    private let photoLibrary: PHPhotoLibrary?
    private let state = PhotoKitState()
    private let candidateIndex = PhotoKitCandidateIndex()
    private let representationReader: PhotosRepresentationReader?
    private let catalogBatchSize: Int
    private let changeChannel: PhotosIndexChangeChannel

    public override convenience init() {
        let library = PHPhotoLibrary.shared()
        self.init(lifecycle: SystemPhotoKitLifecycle(photoLibrary: library), observedLibrary: library)
    }

    public convenience init(configuration: DedupConfiguration, imageBudget: ImageWorkBudget) {
        let library = PHPhotoLibrary.shared()
        let reader = PhotosRepresentationReader(requester: SystemPhotosRepresentationRequester(), budget: imageBudget,
                                                limits: configuration.resources, targetSide: configuration.fingerprint.inputSide)
        self.init(lifecycle: SystemPhotoKitLifecycle(photoLibrary: library, eventBatchSize: configuration.resources.catalogBatchSize), observedLibrary: library,
                  representationReader: reader, catalogBatchSize: configuration.resources.catalogBatchSize)
    }

    init(lifecycle: any PhotoKitLifecycle, representationReader: PhotosRepresentationReader? = nil, catalogBatchSize: Int = 0) {
        self.representationReader = representationReader
        self.catalogBatchSize = catalogBatchSize
        changeChannel = PhotosIndexChangeChannel(capacity: max(1, catalogBatchSize))
        self.lifecycle = lifecycle
        photoLibrary = nil
        super.init()
    }

    private init(lifecycle: any PhotoKitLifecycle, observedLibrary: PHPhotoLibrary,
                 representationReader: PhotosRepresentationReader? = nil, catalogBatchSize: Int = 0) {
        self.representationReader = representationReader
        self.catalogBatchSize = catalogBatchSize
        changeChannel = PhotosIndexChangeChannel(capacity: max(1, catalogBatchSize))
        self.lifecycle = lifecycle
        photoLibrary = observedLibrary
        super.init()
        observedLibrary.register(self as PHPhotoLibraryChangeObserver)
        observedLibrary.register(self as PHPhotoLibraryAvailabilityObserver)
    }

    deinit {
        photoLibrary?.unregisterChangeObserver(self)
        photoLibrary?.unregisterAvailabilityObserver(self)
    }

    public func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        for attempt in 0..<Self.candidateLoadAttempts {
            let generation = try await usableGeneration()
            do {
                let snapshot = try candidateIndex.snapshot(
                    generation: generation,
                    lifecycle: lifecycle,
                    validity: state.validity(generation: generation),
                    needsRebuild: { [state] in state.needsReindex(generation: generation) }
                )
                try verifyUsable(generation: generation)
                guard state.markIndexed(generation: generation) else {
                    // A change can arrive between verification and indexing. Recheck so
                    // unavailability and permission loss do not become retryable races.
                    try verifyUsable(generation: generation)
                    throw PhotoKitGatewayError.libraryChanged
                }
                return snapshot
            } catch let error as PhotoKitGatewayError where error == .libraryChanged {
                guard attempt + 1 < Self.candidateLoadAttempts else { throw error }
                await Task.yield()
            }
        }
        throw PhotoKitGatewayError.libraryChanged
    }

    public func changes() -> AsyncStream<PhotosIndexChange> { changeChannel.stream() }

    public func representationCatalog(offset: Int, limit: Int, expectedGeneration: Int) async throws -> RepresentationPage {
        guard offset >= 0, limit > 0, limit <= catalogBatchSize else { throw PhotosRepresentationError.invalidPage }
        let generation = try await usableGeneration()
        guard generation == expectedGeneration else { throw PhotoKitGatewayError.libraryChanged }
        let context = state.snapshot().context
        let page = try lifecycle.representationCatalog(offset: offset, limit: limit, context: context, generation: generation)
        try verifyUsable(generation: generation)
        guard page.context == context, page.generation == generation, page.descriptors.count + page.exclusions.count <= limit,
              (page.descriptors + page.exclusions.map(\.descriptor)).allSatisfy({ $0.context == context }),
              page.nextOffset.map({ $0 > offset }) ?? true else { throw PhotosRepresentationError.invalidPage }
        // Reconciliation acknowledgement belongs to the caller after all pages,
        // persisted facts and derived index publish succeed; fetching a last page
        // alone is not sufficient to clear the sticky dirty bit.
        let evidence = try state.invalidationEvidence(generation: generation,
            pageAssetIDs: Set((page.descriptors + page.exclusions.map(\.descriptor)).map { $0.key.assetID }))
        return RepresentationPage(context: page.context, generation: page.generation, descriptors: page.descriptors,
                                  nextOffset: page.nextOffset, exclusions: page.exclusions,
                                  invalidatedAssetIDs: evidence.ids, invalidateAllCachedRepresentations: evidence.all)
    }

    public func acknowledgeReconciliation(expectedGeneration: Int) async throws {
        let generation = try await usableGeneration()
        guard generation == expectedGeneration,
              state.acknowledgeReconciliation(generation: expectedGeneration, { [changeChannel] in changeChannel.reconciled() }) else {
            throw PhotoKitGatewayError.libraryChanged
        }
    }

    public func readRepresentation(_ descriptor: RepresentationDescriptor) async throws -> LoadedRepresentation {
        let generation = try await usableGeneration()
        guard descriptor.context == state.snapshot().context else { throw PhotoKitGatewayError.libraryChanged }
        guard let representationReader else { throw PhotosRepresentationError.unavailable }
        let loaded = try await representationReader.read(descriptor) { [state, lifecycle] in
            let snapshot = state.snapshot()
            return snapshot.available && snapshot.generation == generation && snapshot.context == descriptor.context &&
                lifecycle.currentAccess() == .authorized && lifecycle.isAvailable()
        }
        do { try verifyUsable(generation: generation); return loaded }
        catch { await loaded.lease.finishPhysicalWork(); throw error }
    }

    public func contextCheckpoint() async throws -> LibraryResumeCheckpoint? {
        let generation = try await usableGeneration()
        guard let token = try lifecycle.archivedChangeToken() else { return nil }
        try verifyUsable(generation: generation)
        return LibraryResumeCheckpoint(context: state.snapshot().context, archivedChangeToken: token)
    }

    public func resumeContext(_ checkpoint: LibraryResumeCheckpoint) async throws -> Bool {
        do {
            _ = try await usableGeneration()
            let generation = state.recordChange(expectingDetails: true)
            defer { state.finishChangeDetails() }
            guard try lifecycle.replayPersistentChanges(checkpoint.archivedChangeToken, onChange: { [state, changeChannel] event in
                if event == .fullReconcileRequired || event == .contextInvalidated { state.invalidateAllRepresentations() }
                changeChannel.send(event)
            }, onContentChange: { [state, catalogBatchSize] ids in
                state.recordContentChanges(ids, capacity: max(1, catalogBatchSize))
            }), let adoptedGeneration = state.adoptContext(checkpoint.context, generation: generation) else {
                state.invalidateContext(); changeChannel.send(.contextInvalidated); return false
            }
            try verifyUsable(generation: adoptedGeneration)
            return true
        } catch {
            state.invalidateContext(); changeChannel.send(.contextInvalidated)
            return false
        }
    }

    public func loadCandidates() async throws -> [MatchCandidate] {
        try await candidateSnapshot().allCandidates
    }

    public func create(
        fileURL: URL,
        kind: MediaKind,
        expectedGeneration: Int,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        let generation = try await usableGeneration()
        guard generation == expectedGeneration else {
            throw PhotoKitGatewayError.definitelyNotCommitted("The Photos candidate index was stale before PhotoKit submission.")
        }
        do {
            try requireAdmission(generation: generation)
        } catch PhotoKitGatewayError.libraryChanged {
            throw PhotoKitGatewayError.definitelyNotCommitted("The Photos candidate index was stale before PhotoKit submission.")
        }
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PhotoKitGatewayError.definitelyNotCommitted("The source file was unavailable before PhotoKit submission.")
        }

        let result: PhotoKitSubmissionResult
        do {
            result = try await lifecycle.submit(
                PhotoKitCreateCommand(fileURL: fileURL, kind: kind, shouldMoveFile: false),
                beforeMutation: { [state, lifecycle] in
                    lifecycle.currentAccess() == .authorized && lifecycle.isAvailable() && state.isReady(generation: generation)
                },
                onPlaceholder: onPlaceholder
            )
        } catch {
            if case .checkpointFailed = error as? PhotoKitSubmissionError {
                state.blockAdditions(.checkpointFailed)
                throw PhotoKitGatewayError.checkpointFailed("The placeholder checkpoint failed.")
            }
            throw classifyChangeFailure(error)
        }

        switch result {
        case .preventedBeforeMutation:
            throw PhotoKitGatewayError.definitelyNotCommitted("The Photos submission was prevented before mutation.")
        case .checkpointFailed:
            state.blockAdditions(.checkpointFailed)
            throw PhotoKitGatewayError.checkpointFailed("The placeholder checkpoint failed.")
        case .committed(let identifier):
            // A successful PhotoKit completion is the durable success signal. Later
            // fetch or permission loss is health evidence that blocks additions only.
            postCommitHealthCheck(identifier: identifier)
            return identifier
        }
    }

    public func create(
        fileURL: URL,
        kind: MediaKind,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        let snapshot = try await candidateSnapshot()
        return try await create(fileURL: fileURL, kind: kind, expectedGeneration: snapshot.generation, onPlaceholder: onPlaceholder)
    }

    public func reconcile(placeholder: String?) async throws -> ImportEvidence {
        let generation = try await usableGeneration()
        guard let placeholder, !placeholder.isEmpty else { return .unknown }
        let found = try lifecycle.fetch(identifier: placeholder)
        try verifyUsable(generation: generation)
        return found ? .found(identifier: placeholder) : .unknown
    }

    func recordLibraryChangeForTesting() { enqueueLibraryChange(nil) }

    private func enqueueLibraryChange(_ change: PHChange?) {
        let generation = state.recordChange(expectingDetails: true)
        candidateIndex.enqueueChange(
            change,
            generation: generation,
            lifecycle: lifecycle,
            didIndex: { [weak self] generation in
                guard let self else { return false }
                return self.state.markIndexed(generation: generation)
            },
            onChange: { [state, changeChannel] event in
                if event == .fullReconcileRequired || event == .contextInvalidated { state.invalidateAllRepresentations() }
                changeChannel.send(event)
            },
            onContentChange: { [state, catalogBatchSize] ids in state.recordContentChanges(ids, capacity: max(1, catalogBatchSize)) },
            didFinishDetails: { [state] in state.finishChangeDetails() }
        )
    }

    private func usableGeneration() async throws -> Int {
        var access = lifecycle.currentAccess()
        if access == .notDetermined { access = await lifecycle.requestReadWriteAuthorization() }
        guard access == .authorized else { throw PhotoKitGatewayError.authorizationRequired }
        guard lifecycle.isAvailable() else { throw PhotoKitGatewayError.libraryUnavailable }
        let snapshot = state.snapshot()
        guard snapshot.available else { throw PhotoKitGatewayError.libraryUnavailable }
        return snapshot.generation
    }

    private func verifyUsable(generation: Int) throws {
        guard lifecycle.currentAccess() == .authorized else { throw PhotoKitGatewayError.authorizationRequired }
        guard lifecycle.isAvailable() else { throw PhotoKitGatewayError.libraryUnavailable }
        let snapshot = state.snapshot()
        guard snapshot.available else { throw PhotoKitGatewayError.libraryUnavailable }
        guard snapshot.generation == generation else { throw PhotoKitGatewayError.libraryChanged }
    }

    private func requireAdmission(generation: Int) throws {
        switch state.admission(generation: generation) {
        case .ready: return
        case .libraryChanged: throw PhotoKitGatewayError.libraryChanged
        case .blockedAfterCheckpointFailure:
            throw PhotoKitGatewayError.checkpointFailed("New imports are blocked until the gateway is recreated after reconciliation.")
        case .blockedAfterUnknownOutcome:
            throw PhotoKitGatewayError.resultUnknown("New imports are blocked until the gateway is recreated after reconciliation.")
        }
    }

    private func postCommitHealthCheck(identifier: String) {
        do {
            guard lifecycle.currentAccess() == .authorized,
                  lifecycle.isAvailable(),
                  try lifecycle.fetch(identifier: identifier) else {
                state.blockAdditions(.unknownOutcome)
                return
            }
        } catch {
            state.blockAdditions(.unknownOutcome)
        }
    }

    private func classifyChangeFailure(_ error: Error) -> PhotoKitGatewayError {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain,
              let code = PHPhotosError.Code(rawValue: nsError.code) else {
            return .definitelyNotCommitted(nsError.localizedDescription)
        }
        switch code {
        case .accessRestricted, .accessUserDenied: return .authorizationRequired
        case .libraryVolumeOffline, .relinquishingLibraryBundleToWriter, .switchingSystemPhotoLibrary: return .libraryUnavailable
        default: return .definitelyNotCommitted(nsError.localizedDescription)
        }
    }
}

extension PhotoKitGateway: PHPhotoLibraryChangeObserver, PHPhotoLibraryAvailabilityObserver {
    public func photoLibraryDidChange(_ changeInstance: PHChange) { enqueueLibraryChange(changeInstance) }
    public func photoLibraryDidBecomeUnavailable(_ photoLibrary: PHPhotoLibrary) { state.recordUnavailable(); changeChannel.send(.contextInvalidated) }
}

private final class SystemPhotoKitLifecycle: @unchecked Sendable, PhotoKitLifecycle {
    private let photoLibrary: PHPhotoLibrary
    private var fetchedAssets: PHFetchResult<PHAsset>?
    private let representationQueue = DispatchQueue(label: "PhotoSync.PhotoKitRepresentationCatalog")
    private var representationAssets: PHFetchResult<PHAsset>?
    private var representationGeneration: Int?
    private let eventBatchSize: Int
    init(photoLibrary: PHPhotoLibrary, eventBatchSize: Int = 1) { self.photoLibrary = photoLibrary; self.eventBatchSize = eventBatchSize }

    func currentAccess() -> PhotoKitAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        default: return .denied
        }
    }
    func requestReadWriteAuthorization() async -> PhotoKitAccess {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return currentAccess()
    }
    func isAvailable() -> Bool { photoLibrary.unavailabilityReason == nil }
    func loadCandidateAssets() throws -> [PhotoKitCandidateAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let assets = PHAsset.fetchAssets(with: options)
        fetchedAssets = assets
        var result: [PhotoKitCandidateAsset] = []
        assets.enumerateObjects { asset, _, _ in
            let candidates = PHAssetResource.assetResources(for: asset).compactMap { resource -> MatchCandidate? in
                guard !resource.originalFilename.isEmpty else { return nil }
                return MatchCandidate(key: "photos:\(asset.localIdentifier):\(resource.originalFilename)", metadata: Self.metadata(asset: asset, filename: resource.originalFilename))
            }
            result.append(PhotoKitCandidateAsset(identifier: asset.localIdentifier, candidates: candidates))
        }
        return result
    }

    func candidateIndexChange(for change: PHChange?) throws -> PhotoKitCandidateIndexChange {
        guard let change, let before = fetchedAssets,
              let details = change.changeDetails(for: before), details.hasIncrementalChanges,
              details.fetchResultBeforeChanges === before else { return .reload }
        let after = details.fetchResultAfterChanges
        let makeCandidate: (PHAsset) -> PhotoKitCandidateAsset = { asset in
            PhotoKitCandidateAsset(identifier: asset.localIdentifier, candidates: PHAssetResource.assetResources(for: asset).compactMap { resource in
                guard !resource.originalFilename.isEmpty else { return nil }
                return MatchCandidate(key: "photos:\(asset.localIdentifier):\(resource.originalFilename)", metadata: Self.metadata(asset: asset, filename: resource.originalFilename))
            })
        }
        fetchedAssets = after
        return .incremental(
            removedAssetIDs: Set(details.removedObjects.map(\.localIdentifier)),
            insertedAssets: details.insertedObjects.map(makeCandidate),
            changedAssets: details.changedObjects.map(makeCandidate)
        )
    }
    func representationCatalog(offset: Int, limit: Int, context: LibraryContext, generation: Int) throws -> RepresentationPage {
        try representationQueue.sync {
            if representationGeneration != generation {
                guard offset == 0 else { throw PhotoKitGatewayError.libraryChanged }
                let options = PHFetchOptions()
                options.includeHiddenAssets = true; options.includeAllBurstAssets = true
                options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                representationAssets = PHAsset.fetchAssets(with: options)
                representationGeneration = generation
            }
            guard let assets = representationAssets, offset <= assets.count * 2 else { throw PhotosRepresentationError.invalidPage }
            let end = min(offset + limit, assets.count * 2)
            var descriptors: [RepresentationDescriptor] = []
            var exclusions: [RepresentationCatalogExclusion] = []
            for position in offset..<end {
                let facts = PhotoKitRepresentationAsset(asset: assets.object(at: position / 2))
                let kind: RepresentationKind = position % 2 == 0 ? .original : .current
                let descriptor = facts.descriptor(kind: kind, context: context)
                do {
                    switch try facts.eligibility(kind) {
                    case .safeSingleFrame: descriptors.append(descriptor)
                    case .conservative(let reason): exclusions.append(RepresentationCatalogExclusion(descriptor: descriptor, reason: .conservative(reason)))
                    }
                } catch PhotosRepresentationError.unsupportedRAW {
                    exclusions.append(RepresentationCatalogExclusion(descriptor: descriptor, reason: .rawResource))
                }
            }
            return RepresentationPage(context: context, generation: generation, descriptors: descriptors,
                                      nextOffset: end < assets.count * 2 ? end : nil, exclusions: exclusions)
        }
    }
    func archivedChangeToken() throws -> Data? {
        try NSKeyedArchiver.archivedData(withRootObject: photoLibrary.currentChangeToken, requiringSecureCoding: true)
    }
    func replayPersistentChanges(_ token: Data, onChange: (PhotosIndexChange) -> Void, onContentChange: ([String]) -> Void) throws -> Bool {
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token) else { return false }
        let result = try photoLibrary.fetchPersistentChanges(since: token)
        for change in result {
            let details = try change.changeDetails(for: .asset)
            onContentChange(details.updatedLocalIdentifiers.sorted())
            let changed = details.insertedLocalIdentifiers.union(details.updatedLocalIdentifiers).sorted()
            let deleted = details.deletedLocalIdentifiers.sorted()
            // Event chunks keep the stream bounded even for a large history delta.
            for start in stride(from: 0, to: changed.count, by: eventBatchSize) { onChange(.assetsChanged(Array(changed[start..<min(start + eventBatchSize, changed.count)]))) }
            for start in stride(from: 0, to: deleted.count, by: eventBatchSize) { onChange(.assetsDeleted(Array(deleted[start..<min(start + eventBatchSize, deleted.count)]))) }
        }
        return true
    }
    func submit(_ command: PhotoKitCreateCommand, beforeMutation: @escaping @Sendable () -> Bool, onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> PhotoKitSubmissionResult {
        let state = SubmissionState()
        do {
            try await photoLibrary.performChanges {
                guard beforeMutation() else { state.prevent(); return }
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = command.shouldMoveFile
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: command.kind == .image ? .photo : .video, fileURL: command.fileURL, options: options)
                guard let identifier = request.placeholderForCreatedAsset?.localIdentifier else { state.checkpointFailed(); return }
                do { try onPlaceholder(identifier); state.commit(identifier: identifier) }
                catch { state.checkpointFailed() }
            }
        } catch {
            if state.isCheckpointFailed { throw PhotoKitSubmissionError.checkpointFailed(error) }
            throw error
        }
        return state.result()
    }
    func fetch(identifier: String) throws -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count == 1
    }
    private static func metadata(asset: PHAsset, filename: String) -> MediaMetadata {
        MediaMetadata(filename: filename, kind: asset.mediaType == .video ? .video : .image, captureSecond: nil, rawCaptureTime: nil, rawCaptureOffset: nil, make: nil, model: nil, width: asset.pixelWidth == 0 ? nil : asset.pixelWidth, height: asset.pixelHeight == 0 ? nil : asset.pixelHeight, duration: asset.mediaType == .video ? asset.duration : nil)
    }
}

private final class PhotoKitCandidateIndex: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhotoSync.PhotoKitCandidateIndex")
    private var byAsset: [String: [MatchCandidate]] = [:]
    private var byFilename: [String: [MatchCandidate]] = [:]
    private var indexedGeneration: Int?

    func snapshot(
        generation: Int,
        lifecycle: any PhotoKitLifecycle,
        validity: any PhotosCandidateValidity,
        needsRebuild: @escaping @Sendable () -> Bool
    ) throws -> PhotosCandidateSnapshot {
        try queue.sync {
            if indexedGeneration != generation || needsRebuild() {
                let assets = try lifecycle.loadCandidateAssets()
                byAsset = Dictionary(uniqueKeysWithValues: assets.map { ($0.identifier, $0.candidates) })
                byFilename = Self.buckets(byAsset)
                indexedGeneration = generation
            }
            return PhotosCandidateSnapshot(generation: generation, candidatesByFilename: byFilename, validity: validity)
        }
    }

    func enqueueChange(_ change: PHChange?, generation: Int, lifecycle: any PhotoKitLifecycle,
                       didIndex: @escaping @Sendable (Int) -> Bool,
                       onChange: @escaping @Sendable (PhotosIndexChange) -> Void,
                       onContentChange: @escaping @Sendable ([String]) -> Void,
                       didFinishDetails: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            defer { didFinishDetails() }
            guard let self else { return }
            guard case let .incremental(removed, inserted, changed) = (try? lifecycle.candidateIndexChange(for: change)) else {
                onChange(.fullReconcileRequired); return
            }
            onContentChange(changed.map(\.identifier))
            if !removed.isEmpty { onChange(.assetsDeleted(removed.sorted())) }
            let updated = (inserted + changed).map(\.identifier)
            if !updated.isEmpty { onChange(.assetsChanged(updated)) }
            guard self.indexedGeneration == generation - 1 else { return }
            let insertedIDs = Set(inserted.map(\.identifier))
            let changedIDs = Set(changed.map(\.identifier))
            guard insertedIDs.count == inserted.count,
                  changedIDs.count == changed.count,
                  removed.isDisjoint(with: insertedIDs),
                  removed.isDisjoint(with: changedIDs),
                  insertedIDs.isDisjoint(with: changedIDs),
                  removed.allSatisfy({ self.byAsset[$0] != nil }),
                  inserted.allSatisfy({ self.byAsset[$0.identifier] == nil }),
                  changed.allSatisfy({ self.byAsset[$0.identifier] != nil }) else { onChange(.fullReconcileRequired); return }
            for id in removed { self.remove(id) }
            for asset in changed { self.remove(asset.identifier); self.insert(asset) }
            for asset in inserted { self.insert(asset) }
            self.indexedGeneration = generation
            _ = didIndex(generation)
        }
    }

    private func remove(_ identifier: String) {
        guard let old = byAsset.removeValue(forKey: identifier) else { return }
        for candidate in old {
            let filename = candidate.metadata.filename
            byFilename[filename]?.removeAll { $0.key == candidate.key }
            if byFilename[filename]?.isEmpty == true { byFilename.removeValue(forKey: filename) }
        }
    }

    private func insert(_ asset: PhotoKitCandidateAsset) {
        byAsset[asset.identifier] = asset.candidates
        for candidate in asset.candidates { byFilename[candidate.metadata.filename, default: []].append(candidate) }
    }

    private static func buckets(_ assets: [String: [MatchCandidate]]) -> [String: [MatchCandidate]] {
        var result: [String: [MatchCandidate]] = [:]
        for candidates in assets.values { for candidate in candidates { result[candidate.metadata.filename, default: []].append(candidate) } }
        return result
    }
}

private final class SubmissionState: @unchecked Sendable {
    private let lock = NSLock(); private var value: PhotoKitSubmissionResult = .preventedBeforeMutation
    func prevent() { lock.lock(); value = .preventedBeforeMutation; lock.unlock() }
    func checkpointFailed() { lock.lock(); value = .checkpointFailed; lock.unlock() }
    func commit(identifier: String) { lock.lock(); value = .committed(identifier: identifier); lock.unlock() }
    func result() -> PhotoKitSubmissionResult { lock.lock(); defer { lock.unlock() }; return value }
    var isCheckpointFailed: Bool { lock.lock(); defer { lock.unlock() }; if case .checkpointFailed = value { return true }; return false }
}

private final class PhotoKitState: @unchecked Sendable {
    enum AdditionBlockReason { case checkpointFailed, unknownOutcome }
    private let lock = NSLock(); private var available = true; private var generation = 0; private var indexedGeneration: Int?; private var additionsBlocked: AdditionBlockReason?
    private var context = LibraryContext(id: UUID(), epoch: 0)
    private var contentChangedIDs = Set<String>()
    private var allRepresentationsInvalid = false
    private var pendingChangeDetails = 0

    func recordContentChanges(_ ids: [String], capacity: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !allRepresentationsInvalid else { return }
        for id in ids {
            contentChangedIDs.insert(id)
            if contentChangedIDs.count > capacity {
                allRepresentationsInvalid = true; contentChangedIDs.removeAll(); return
            }
        }
    }
    func invalidateAllRepresentations() {
        lock.lock(); allRepresentationsInvalid = true; contentChangedIDs.removeAll(); lock.unlock()
    }
    func finishChangeDetails() {
        lock.lock(); pendingChangeDetails -= 1; lock.unlock()
    }
    func invalidationEvidence(generation expected: Int, pageAssetIDs: Set<String>) throws -> (ids: [String], all: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard available, generation == expected else { throw PhotoKitGatewayError.libraryChanged }
        return (contentChangedIDs.intersection(pageAssetIDs).sorted(), allRepresentationsInvalid || pendingChangeDetails > 0)
    }
    func acknowledgeReconciliation(generation expected: Int, _ acknowledge: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard available, generation == expected, pendingChangeDetails == 0 else { return false }
        contentChangedIDs.removeAll(); allRepresentationsInvalid = false
        acknowledge()
        return true
    }
    func snapshot() -> (available: Bool, generation: Int, context: LibraryContext) { lock.lock(); defer { lock.unlock() }; return (available, generation, context) }
    func adoptContext(_ context: LibraryContext, generation expected: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard available, generation == expected else { return nil }
        self.context = context
        // Replay runs outside the lock. Snapshots acquired during that work
        // belong to the provisional context and must not survive adoption.
        generation += 1; indexedGeneration = nil
        return generation
    }
    func invalidateContext() {
        lock.lock(); defer { lock.unlock() }
        context = LibraryContext(id: UUID(), epoch: 0); generation += 1; indexedGeneration = nil
        allRepresentationsInvalid = true; contentChangedIDs.removeAll()
    }
    func validity(generation expected: Int) -> any PhotosCandidateValidity {
        PhotoKitGenerationValidity(state: self, generation: expected)
    }
    func needsReindex(generation expected: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return indexedGeneration != expected }
    func recordChange(expectingDetails: Bool = false) -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1; indexedGeneration = nil
        if expectingDetails { pendingChangeDetails += 1 }
        return generation
    }
    func recordUnavailable() { lock.lock(); available = false; generation += 1; indexedGeneration = nil; lock.unlock() }
    func markIndexed(generation expected: Int) -> Bool { lock.lock(); defer { lock.unlock() }; guard available, generation == expected else { return false }; indexedGeneration = expected; return true }
    enum Admission { case ready, libraryChanged, blockedAfterCheckpointFailure, blockedAfterUnknownOutcome }
    func admission(generation expected: Int) -> Admission {
        lock.lock(); defer { lock.unlock() }
        switch additionsBlocked {
        case .checkpointFailed: return .blockedAfterCheckpointFailure
        case .unknownOutcome: return .blockedAfterUnknownOutcome
        case nil: return available && generation == expected && indexedGeneration == expected ? .ready : .libraryChanged
        }
    }
    func isReady(generation expected: Int) -> Bool { admission(generation: expected) == .ready }
    func blockAdditions(_ reason: AdditionBlockReason) { lock.lock(); additionsBlocked = reason; lock.unlock() }

    func commitIfCurrent(generation expected: Int, _ commit: @escaping @Sendable () throws -> Void) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available, generation == expected else { return false }
        try commit()
        return true
    }
}

private final class PhotoKitGenerationValidity: PhotosCandidateValidity, @unchecked Sendable {
    private let state: PhotoKitState
    private let generation: Int

    init(state: PhotoKitState, generation: Int) {
        self.state = state
        self.generation = generation
    }

    func commitIfCurrent(_ commit: @escaping @Sendable () throws -> Void) throws -> Bool {
        try state.commitIfCurrent(generation: generation, commit)
    }
}
