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

protocol PhotoKitLifecycle: Sendable {
    func currentAccess() -> PhotoKitAccess
    func requestReadWriteAuthorization() async -> PhotoKitAccess
    func isAvailable() -> Bool
    func loadCandidates() throws -> [MatchCandidate]
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

    public func loadCandidates() async throws -> [MatchCandidate] {
        for attempt in 0..<Self.candidateLoadAttempts {
            let generation = try await usableGeneration()
            let candidates = try lifecycle.loadCandidates()
            do {
                try verifyUsable(generation: generation)
                guard state.markIndexed(generation: generation) else {
                    // A change can arrive between verification and indexing. Recheck so
                    // unavailability and permission loss do not become retryable races.
                    try verifyUsable(generation: generation)
                    throw PhotoKitGatewayError.libraryChanged
                }
                return candidates
            } catch let error as PhotoKitGatewayError where error == .libraryChanged {
                guard attempt + 1 < Self.candidateLoadAttempts else { throw error }
                await Task.yield()
            }
        }
        throw PhotoKitGatewayError.libraryChanged
    }

    public func create(
        fileURL: URL,
        kind: MediaKind,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        let generation = try await usableGeneration()
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

    public func reconcile(placeholder: String?) async throws -> ImportEvidence {
        let generation = try await usableGeneration()
        guard let placeholder, !placeholder.isEmpty else { return .unknown }
        let found = try lifecycle.fetch(identifier: placeholder)
        try verifyUsable(generation: generation)
        return found ? .found(identifier: placeholder) : .unknown
    }

    func recordLibraryChangeForTesting() { state.recordChange() }

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
    public func photoLibraryDidChange(_ changeInstance: PHChange) { state.recordChange() }
    public func photoLibraryDidBecomeUnavailable(_ photoLibrary: PHPhotoLibrary) { state.recordUnavailable() }
}

private final class SystemPhotoKitLifecycle: @unchecked Sendable, PhotoKitLifecycle {
    private let photoLibrary: PHPhotoLibrary
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
    func loadCandidates() throws -> [MatchCandidate] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let assets = PHAsset.fetchAssets(with: options)
        var result: [MatchCandidate] = []
        assets.enumerateObjects { asset, _, _ in
            for resource in PHAssetResource.assetResources(for: asset) where !resource.originalFilename.isEmpty {
                result.append(MatchCandidate(key: "photos:\(asset.localIdentifier):\(resource.originalFilename)", metadata: Self.metadata(asset: asset, filename: resource.originalFilename)))
            }
        }
        return result
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
    func recordChange() { lock.lock(); generation += 1; lock.unlock() }
    func recordUnavailable() { lock.lock(); available = false; generation += 1; lock.unlock() }
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
}
