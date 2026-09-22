import Foundation
import Photos
import PhotoSyncCore

enum GUIQAReadOnlyAccess: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

protocol GUIQAReadOnlyPhotosAccessing: AnyObject, Sendable {
    func currentAccess() -> GUIQAReadOnlyAccess
    func requestAuthorization() async -> GUIQAReadOnlyAccess
    func loadCandidates() throws -> [MatchCandidate]
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void)
}

final class GUIQAReadOnlyPhotosGateway: PhotosGateway, @unchecked Sendable {
    private static let candidateLoadAttempts = 3
    private let access: any GUIQAReadOnlyPhotosAccessing
    private let lock = NSLock()
    private var cache: PhotosCandidateSnapshot?
    private var generation = 0

    init(access: any GUIQAReadOnlyPhotosAccessing = SystemGUIQAReadOnlyPhotosAccess()) {
        self.access = access
        access.setChangeHandler { [weak self] in self?.invalidateCache() }
    }

    var isAuthorized: Bool { access.currentAccess() == .authorized }

    func requestAuthorization() async -> Bool {
        await access.requestAuthorization() == .authorized
    }

    func candidateSnapshot() async throws -> PhotosCandidateSnapshot {
        for attempt in 0..<Self.candidateLoadAttempts {
            guard access.currentAccess() == .authorized else {
                throw PhotoKitGatewayError.authorizationRequired
            }
            let cached = cachedSnapshot()
            if let snapshot = cached.snapshot {
                guard currentGeneration() == cached.generation,
                      access.currentAccess() == .authorized else { continue }
                return snapshot
            }

            let loaded = try access.loadCandidates()
            let snapshot = PhotosCandidateSnapshot(
                generation: cached.generation,
                candidates: loaded,
                validity: GUIQAGenerationValidity(gateway: self, generation: cached.generation)
            )
            guard cache(snapshot, ifGeneration: cached.generation) else {
                guard attempt + 1 < Self.candidateLoadAttempts else {
                    throw PhotoKitGatewayError.libraryChanged
                }
                continue
            }
            return snapshot
        }
        throw PhotoKitGatewayError.libraryChanged
    }

    func create(
        fileURL: URL,
        kind: MediaKind,
        expectedGeneration: Int,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        let currentGeneration = currentGeneration()
        guard currentGeneration == expectedGeneration else {
            throw PhotoKitGatewayError.definitelyNotCommitted("The Photos candidate index was stale before PhotoKit submission.")
        }
        throw PhotoKitGatewayError.definitelyNotCommitted("GUI QA readonly mode prohibits all Photos writes.")
    }

    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }

    private func cachedSnapshot() -> (snapshot: PhotosCandidateSnapshot?, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (cache, generation)
    }

    private func cache(_ snapshot: PhotosCandidateSnapshot, ifGeneration expected: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { return false }
        cache = snapshot
        return true
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func invalidateCache() {
        lock.lock()
        generation += 1
        cache = nil
        lock.unlock()
    }

    fileprivate func commitIfCurrent(
        generation expected: Int,
        _ commit: @escaping @Sendable () throws -> Void
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected, access.currentAccess() == .authorized else { return false }
        try commit()
        return true
    }
}

private final class GUIQAGenerationValidity: PhotosCandidateValidity, @unchecked Sendable {
    private weak var gateway: GUIQAReadOnlyPhotosGateway?
    private let generation: Int

    init(gateway: GUIQAReadOnlyPhotosGateway, generation: Int) {
        self.gateway = gateway
        self.generation = generation
    }

    func commitIfCurrent(_ commit: @escaping @Sendable () throws -> Void) throws -> Bool {
        try gateway?.commitIfCurrent(generation: generation, commit) ?? false
    }
}

private final class SystemGUIQAReadOnlyPhotosAccess: NSObject, @unchecked Sendable, GUIQAReadOnlyPhotosAccessing, PHPhotoLibraryChangeObserver {
    private let lock = NSLock()
    private var changeHandler: (@Sendable () -> Void)?

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); changeHandler = handler; lock.unlock()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock(); let handler = changeHandler; lock.unlock()
        handler?()
    }

    func currentAccess() -> GUIQAReadOnlyAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        default: return .denied
        }
    }

    func requestAuthorization() async -> GUIQAReadOnlyAccess {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return currentAccess()
    }

    func loadCandidates() throws -> [MatchCandidate] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let assets = PHAsset.fetchAssets(with: options)
        var result: [MatchCandidate] = []
        assets.enumerateObjects { asset, _, _ in
            for resource in PHAssetResource.assetResources(for: asset) where !resource.originalFilename.isEmpty {
                result.append(
                    MatchCandidate(
                        key: "photos-readonly:\(asset.localIdentifier):\(resource.originalFilename)",
                        metadata: MediaMetadata(
                            filename: resource.originalFilename,
                            kind: asset.mediaType == .video ? .video : .image,
                            captureSecond: nil,
                            rawCaptureTime: nil,
                            rawCaptureOffset: nil,
                            make: nil,
                            model: nil,
                            width: asset.pixelWidth == 0 ? nil : asset.pixelWidth,
                            height: asset.pixelHeight == 0 ? nil : asset.pixelHeight,
                            duration: asset.mediaType == .video ? asset.duration : nil
                        )
                    )
                )
            }
        }
        return result
    }
}
