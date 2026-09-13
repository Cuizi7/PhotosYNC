import Foundation
import Photos

public final class PhotoKitGateway: NSObject, PhotosGateway, @unchecked Sendable {
    private let photoLibrary: PHPhotoLibrary
    private let state = PhotoKitState()

    public override convenience init() {
        self.init(photoLibrary: .shared())
    }

    init(photoLibrary: PHPhotoLibrary) {
        self.photoLibrary = photoLibrary
        super.init()
        photoLibrary.register(self as PHPhotoLibraryChangeObserver)
        photoLibrary.register(self as PHPhotoLibraryAvailabilityObserver)
    }

    deinit {
        photoLibrary.unregisterChangeObserver(self)
        photoLibrary.unregisterAvailabilityObserver(self)
    }

    public func loadCandidates() async throws -> [MatchCandidate] {
        let startGeneration = try await usableGeneration(requestAuthorization: true)
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true

        let assets = PHAsset.fetchAssets(with: options)
        var candidates: [MatchCandidate] = []
        candidates.reserveCapacity(assets.count)

        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            for resource in resources where !resource.originalFilename.isEmpty {
                candidates.append(
                    MatchCandidate(
                        key: "photos:\(asset.localIdentifier):\(resource.originalFilename)",
                        metadata: Self.metadata(asset: asset, filename: resource.originalFilename)
                    )
                )
            }
        }

        try verifyUsable(generation: startGeneration)
        guard state.markIndexed(generation: startGeneration) else {
            throw PhotoKitGatewayError.libraryChanged
        }
        return candidates
    }

    public func create(
        fileURL: URL,
        kind: MediaKind,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        let startGeneration = try await usableGeneration(requestAuthorization: true)
        switch state.admission(generation: startGeneration) {
        case .ready:
            break
        case .libraryChanged:
            throw PhotoKitGatewayError.libraryChanged
        case .blockedAfterUnknown:
            throw PhotoKitGatewayError.resultUnknown("New imports are blocked until the prior PhotoKit outcome is reconciled.")
        }
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PhotoKitGatewayError.definitelyNotCommitted("The source file was unavailable before PhotoKit submission.")
        }

        let result = ChangeResult()
        do {
            try await photoLibrary.performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(
                    with: kind == .image ? .photo : .video,
                    fileURL: fileURL,
                    options: options
                )

                guard let identifier = request.placeholderForCreatedAsset?.localIdentifier else {
                    result.recordUnknown("PhotoKit did not provide a placeholder identifier.")
                    return
                }
                result.record(identifier: identifier)
                do {
                    try onPlaceholder(identifier)
                } catch {
                    result.recordUnknown("The placeholder checkpoint failed: \(error.localizedDescription)")
                }
            }
        } catch {
            if let message = result.snapshot().unknownMessage {
                state.blockAdditions()
                throw PhotoKitGatewayError.resultUnknown(message)
            }
            throw classifyChangeFailure(error)
        }

        let resultSnapshot = result.snapshot()
        if let message = resultSnapshot.unknownMessage {
            state.blockAdditions()
            throw PhotoKitGatewayError.resultUnknown(message)
        }
        guard let identifier = resultSnapshot.identifier else {
            state.blockAdditions()
            throw PhotoKitGatewayError.resultUnknown("PhotoKit completed without a persisted placeholder identifier.")
        }
        try verifyUsable(generation: nil)

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard fetched.count == 1 else {
            state.blockAdditions()
            throw PhotoKitGatewayError.resultUnknown("The committed placeholder could not be fetched for confirmation.")
        }
        return identifier
    }

    public func reconcile(placeholder: String?) async throws -> ImportEvidence {
        _ = try await usableGeneration(requestAuthorization: true)
        guard let placeholder, !placeholder.isEmpty else { return .unknown }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [placeholder], options: nil)
        guard fetched.count == 1, let asset = fetched.firstObject, asset.localIdentifier == placeholder else {
            return .unknown
        }
        return .found(identifier: placeholder)
    }

    private func usableGeneration(requestAuthorization: Bool) async throws -> Int {
        if requestAuthorization, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw PhotoKitGatewayError.authorizationRequired
        }
        guard photoLibrary.unavailabilityReason == nil else {
            throw PhotoKitGatewayError.libraryUnavailable
        }
        let snapshot = state.snapshot()
        guard snapshot.available else { throw PhotoKitGatewayError.libraryUnavailable }
        return snapshot.generation
    }

    private func verifyUsable(generation expectedGeneration: Int?) throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw PhotoKitGatewayError.authorizationRequired
        }
        guard photoLibrary.unavailabilityReason == nil else {
            throw PhotoKitGatewayError.libraryUnavailable
        }
        let snapshot = state.snapshot()
        guard snapshot.available else { throw PhotoKitGatewayError.libraryUnavailable }
        if let expectedGeneration, snapshot.generation != expectedGeneration {
            throw PhotoKitGatewayError.libraryChanged
        }
    }

    private func classifyChangeFailure(_ error: Error) -> PhotoKitGatewayError {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain,
              let code = PHPhotosError.Code(rawValue: nsError.code) else {
            return .definitelyNotCommitted(nsError.localizedDescription)
        }

        switch code {
        case .accessRestricted, .accessUserDenied:
            return .authorizationRequired
        case .libraryVolumeOffline, .relinquishingLibraryBundleToWriter, .switchingSystemPhotoLibrary:
            return .libraryUnavailable
        default:
            return .definitelyNotCommitted(nsError.localizedDescription)
        }
    }

    private static func metadata(asset: PHAsset, filename: String) -> MediaMetadata {
        MediaMetadata(
            filename: filename,
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
    }
}

extension PhotoKitGateway: PHPhotoLibraryChangeObserver, PHPhotoLibraryAvailabilityObserver {
    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        state.recordChange()
    }

    public func photoLibraryDidBecomeUnavailable(_ photoLibrary: PHPhotoLibrary) {
        state.recordUnavailable()
    }
}

private final class ChangeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: String?
    private var unknownMessage: String?

    func record(identifier: String) {
        lock.lock()
        self.identifier = identifier
        lock.unlock()
    }

    func recordUnknown(_ message: String) {
        lock.lock()
        unknownMessage = message
        lock.unlock()
    }

    func snapshot() -> (identifier: String?, unknownMessage: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (identifier, unknownMessage)
    }
}

private final class PhotoKitState: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    private var generation = 0
    private var indexedGeneration: Int?
    private var additionsBlocked = false

    func snapshot() -> (available: Bool, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (available, generation)
    }

    func recordChange() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func recordUnavailable() {
        lock.lock()
        available = false
        generation += 1
        lock.unlock()
    }

    func markIndexed(generation expectedGeneration: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available, generation == expectedGeneration else { return false }
        indexedGeneration = expectedGeneration
        return true
    }

    enum Admission {
        case ready
        case libraryChanged
        case blockedAfterUnknown
    }

    func admission(generation expectedGeneration: Int) -> Admission {
        lock.lock()
        defer { lock.unlock() }
        if additionsBlocked { return .blockedAfterUnknown }
        guard available, generation == expectedGeneration, indexedGeneration == expectedGeneration else {
            return .libraryChanged
        }
        return .ready
    }

    func blockAdditions() {
        lock.lock()
        additionsBlocked = true
        lock.unlock()
    }
}
