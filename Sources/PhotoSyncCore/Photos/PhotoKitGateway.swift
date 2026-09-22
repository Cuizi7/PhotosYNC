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
}

public final class PhotoKitGateway: NSObject, PhotosGateway, @unchecked Sendable {
    private static let candidateLoadAttempts = 3
    private let lifecycle: any PhotoKitLifecycle
    private let photoLibrary: PHPhotoLibrary?
    private let state = PhotoKitState()
    private let candidateIndex = PhotoKitCandidateIndex()

    public override convenience init() {
        let library = PHPhotoLibrary.shared()
        self.init(lifecycle: SystemPhotoKitLifecycle(photoLibrary: library), observedLibrary: library)
    }

    init(lifecycle: any PhotoKitLifecycle) {
        self.lifecycle = lifecycle
        photoLibrary = nil
        super.init()
    }

    private init(lifecycle: any PhotoKitLifecycle, observedLibrary: PHPhotoLibrary) {
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
        let generation = state.recordChange()
        candidateIndex.enqueueChange(
            change,
            generation: generation,
            lifecycle: lifecycle,
            didIndex: { [weak self] generation in
                guard let self else { return false }
                return self.state.markIndexed(generation: generation)
            }
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
    public func photoLibraryDidBecomeUnavailable(_ photoLibrary: PHPhotoLibrary) { state.recordUnavailable() }
}

private final class SystemPhotoKitLifecycle: @unchecked Sendable, PhotoKitLifecycle {
    private let photoLibrary: PHPhotoLibrary
    private var fetchedAssets: PHFetchResult<PHAsset>?
    init(photoLibrary: PHPhotoLibrary) { self.photoLibrary = photoLibrary }

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

    func enqueueChange(_ change: PHChange?, generation: Int, lifecycle: any PhotoKitLifecycle, didIndex: @escaping @Sendable (Int) -> Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard case let .incremental(removed, inserted, changed) = (try? lifecycle.candidateIndexChange(for: change)) else { return }
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
                  changed.allSatisfy({ self.byAsset[$0.identifier] != nil }) else { return }
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
    func snapshot() -> (available: Bool, generation: Int) { lock.lock(); defer { lock.unlock() }; return (available, generation) }
    func validity(generation expected: Int) -> any PhotosCandidateValidity {
        PhotoKitGenerationValidity(state: self, generation: expected)
    }
    func needsReindex(generation expected: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return indexedGeneration != expected }
    func recordChange() -> Int { lock.lock(); generation += 1; indexedGeneration = nil; let value = generation; lock.unlock(); return value }
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
