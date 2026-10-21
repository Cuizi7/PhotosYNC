import Foundation
import Photos
import UniformTypeIdentifiers

/// All references use public descriptor facts and are revalidated. Their revision is an observation token, not a content hash.
struct PhotoKitLivePhotoReader: Sendable {
    static func fetchAsset(_ id: String) -> PHAsset? {
        let options = PHFetchOptions(); options.includeHiddenAssets = true; options.includeAllBurstAssets = true
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject
    }
    static func descriptor(_ asset: PHAsset, context: LibraryContext) -> LivePhotoAssetDescriptor {
        let resources = PHAssetResource.assetResources(for: asset)
        let keys = resources.enumerated().map { resourceKey($0.element, index: $0.offset) }
        let date = asset.modificationDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "unknown"
        let revision = ([asset.localIdentifier, date, String(asset.mediaSubtypes.rawValue), String(asset.hasAdjustments)] + keys).joined(separator: "|")
        return .init(context: context, assetID: asset.localIdentifier, revision: revision, isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                     mediaKind: asset.mediaType == .video ? .video : .image,
                     resources: keys.map { .photos(contextID: context.id, assetID: asset.localIdentifier, resourceKey: $0, revision: revision) },
                     originalFilenames: resources.map(\.originalFilename),
                     resourceKinds: resources.map { resource in
                         if resource.type == .photo { return .image }
                         if resource.type == .video || resource.type == .pairedVideo { return .video }
                         return nil
                     })
    }
    static func resourceKey(_ resource: PHAssetResource, index: Int) -> String {
        "\(index):\(resource.type.rawValue):\(resource.originalFilename.utf8.count):\(resource.originalFilename):\(resource.uniformTypeIdentifier):\(resource.pixelWidth)x\(resource.pixelHeight)"
    }
    static func selected(_ ref: LivePhotoResourceRef) throws -> (PHAsset, PHAssetResource) {
        guard case .photos(let contextID, let id, let key, let revision) = ref,
              let asset = fetchAsset(id) else { throw PhotosRepresentationError.unavailable }
        let current = descriptor(asset, context: .init(id: contextID, epoch: 0))
        guard current.revision == revision else { throw PhotoKitGatewayError.libraryChanged }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let selected = resources.enumerated().first(where: { resourceKey($0.element, index: $0.offset) == key })?.element else { throw PhotosRepresentationError.ambiguousResource }
        return (asset, selected)
    }
    static func snapshot(assetID: String, context: LibraryContext) throws -> LivePhotoPreservationSnapshot {
        guard let asset = fetchAsset(assetID) else { throw PhotosRepresentationError.unavailable }
        var value = LivePhotoPreservationSnapshot(revision: descriptor(asset, context: context).revision)
        value.creationDate = asset.creationDate.map(PreservedField.value) ?? .emptyOrNotApplicable
        value.location = asset.location.map { .value(.init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: $0.altitude)) } ?? .emptyOrNotApplicable
        value.favorite = .value(asset.isFavorite); value.hidden = .value(asset.isHidden)
        value.hasAdjustments = .value(asset.hasAdjustments)
        let resources = PHAssetResource.assetResources(for: asset)
        value.hasExtraResources = .value(resources.contains { ![PHAssetResourceType.photo, .video, .pairedVideo].contains($0.type) } || resources.count != (asset.mediaSubtypes.contains(.photoLive) ? 2 : 1))
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var ordinary = [String](), shared = asset.sourceType.contains(.typeCloudShared), unknownCollection = false
        albums.enumerateObjects { album, _, _ in
            if album.assetCollectionSubtype == .albumCloudShared { shared = true }
            else if album.canPerform(.addContent) { ordinary.append(album.localIdentifier) }
            else { unknownCollection = true }
        }
        value.isSharedAlbum = .value(shared)
        value.albumIDs = unknownCollection ? .unknown : .value(ordinary.sorted())
        if #available(macOS 27, *) {
            value.rating = .value(asset.rating.rawValue)
            value.caption = asset.extendedMetadata.caption.map(PreservedField.value) ?? .emptyOrNotApplicable
            value.keywords = .value(asset.extendedMetadata.keywords)
        }
        // Photos exposes no public title accessor, even in the macOS 27 SDK. Absence cannot be assumed.
        value.title = .unknown
        return value
    }
}

final class SystemLivePhotoResourceRequester: LivePhotoResourceRequesting, @unchecked Sendable {
    private let manager = PHAssetResourceManager.default()
    func resourceFileExtension(_ ref: LivePhotoResourceRef) throws -> String? {
        let (_, resource) = try PhotoKitLivePhotoReader.selected(ref)
        return UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension
    }
    func request(_ ref: LivePhotoResourceRef, allowNetwork: Bool, receive: @escaping @Sendable (Data) -> Void,
                 completion: @escaping @Sendable (Error?) -> Void) throws -> @Sendable () -> Void {
        let (_, selected) = try PhotoKitLivePhotoReader.selected(ref)
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowNetwork
        let id = manager.requestData(for: selected, options: options, dataReceivedHandler: receive) { error in
            if let error { completion(error); return }
            do { _ = try PhotoKitLivePhotoReader.selected(ref); completion(nil) }
            catch { completion(error) }
        }
        return { [manager] in manager.cancelDataRequest(id) }
    }
}

final class PhotoKitLivePhotoCatalog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhotoSync.LivePhoto.catalog")
    private var sessionID: UUID?
    private var assets: PHFetchResult<PHAsset>?
    func page(session: PhotosCatalogSession, context: LibraryContext, offset: Int, limit: Int) throws -> LivePhotoAssetPage {
        try queue.sync {
            if sessionID != session.id {
                guard offset == 0 else { throw PhotoKitGatewayError.libraryChanged }
                let options = PHFetchOptions(); options.includeHiddenAssets = true; options.includeAllBurstAssets = true
                options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
                assets = PHAsset.fetchAssets(with: options); sessionID = session.id
            }
            guard let assets, offset >= 0, offset <= assets.count, limit > 0 else { throw PhotosRepresentationError.invalidPage }
            let end = min(assets.count, offset + limit)
            let rows = (offset..<end).map { PhotoKitLivePhotoReader.descriptor(assets.object(at: $0), context: context) }
            return .init(context: context, generation: session.baselineGeneration, assets: rows, nextOffset: end < assets.count ? end : nil)
        }
    }
    func descriptors(ids: [String], context: LibraryContext) -> [LivePhotoAssetDescriptor] {
        queue.sync {
            let options = PHFetchOptions(); options.includeHiddenAssets = true; options.includeAllBurstAssets = true
            let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
            return (0..<result.count).map { PhotoKitLivePhotoReader.descriptor(result.object(at: $0), context: context) }
        }
    }
}

/// A Live Photo request can deliver degraded and repeated callbacks; only the first final result resumes its waiter.
final class LivePhotoObjectResult: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<CGSize, Error>) -> Void)?
    init(_ completion: @escaping @Sendable (Result<CGSize, Error>) -> Void) { self.completion = completion }
    func receive(size: CGSize?, degraded: Bool, error: Error?) {
        guard !degraded else { return }
        lock.lock(); let call = completion; completion = nil; lock.unlock()
        if let error { call?(.failure(error)) } else { call?(.success(size ?? .zero)) }
    }
}
