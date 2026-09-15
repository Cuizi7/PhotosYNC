import Foundation
import Photos
import PhotoSyncCore

enum GUIQAReadOnlyAccess: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

protocol GUIQAReadOnlyPhotosAccessing: Sendable {
    func currentAccess() -> GUIQAReadOnlyAccess
    func requestAuthorization() async -> GUIQAReadOnlyAccess
    func loadCandidates() throws -> [MatchCandidate]
}

final class GUIQAReadOnlyPhotosGateway: PhotosGateway, @unchecked Sendable {
    private let access: any GUIQAReadOnlyPhotosAccessing

    init(access: any GUIQAReadOnlyPhotosAccessing = SystemGUIQAReadOnlyPhotosAccess()) {
        self.access = access
    }

    var isAuthorized: Bool { access.currentAccess() == .authorized }

    func requestAuthorization() async -> Bool {
        await access.requestAuthorization() == .authorized
    }

    func loadCandidates() async throws -> [MatchCandidate] {
        guard access.currentAccess() == .authorized else {
            throw PhotoKitGatewayError.authorizationRequired
        }
        return try access.loadCandidates()
    }

    func create(
        fileURL: URL,
        kind: MediaKind,
        onPlaceholder: @escaping @Sendable (String) throws -> Void
    ) async throws -> String {
        throw PhotoKitGatewayError.definitelyNotCommitted("GUI QA readonly mode prohibits all Photos writes.")
    }

    func reconcile(placeholder: String?) async throws -> ImportEvidence { .unknown }
}

private struct SystemGUIQAReadOnlyPhotosAccess: GUIQAReadOnlyPhotosAccessing {
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
