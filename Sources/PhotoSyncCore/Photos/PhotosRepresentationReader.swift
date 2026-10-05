import AppKit
import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

public enum PhotosRepresentationError: Error, Equatable, Sendable {
    case unavailable
    case iCloudUnavailable(String)
    case invalidPage
    case unsupportedRAW
    case invalidImage
    case oversized(width: Int, height: Int)
}

enum PhotosRepresentationCallback: @unchecked Sendable {
    case degraded
    case image(CGImage, orientation: CGImagePropertyOrientation, eligibility: RepresentationEligibility)
    case failure(Error)
    case cancelled
}

protocol PhotosRepresentationRequesting: Sendable {
    func request(_ descriptor: RepresentationDescriptor, targetSide: Int,
                 completion: @escaping @Sendable (PhotosRepresentationCallback) -> Void) throws
}

public actor PhotosRepresentationReader {
    private let requester: any PhotosRepresentationRequesting
    private let budget: ImageWorkBudget
    private let limits: ResourceLimits
    private let targetSide: Int
    private var occupied = 0
    public var physicalRequestCount: Int { occupied }

    init(requester: any PhotosRepresentationRequesting, budget: ImageWorkBudget, limits: ResourceLimits, targetSide: Int) {
        precondition(targetSide > 0 && targetSide <= 4096)
        self.requester = requester; self.budget = budget; self.limits = limits; self.targetSide = targetSide
    }

    public func read(_ descriptor: RepresentationDescriptor,
                     isCurrent: @escaping @Sendable () -> Bool) async throws -> LoadedRepresentation {
        try Task.checkCancellation()
        guard occupied < limits.photoRequestConcurrency else { throw ReadExecutorError.resourceExhausted }
        // Aggregate exposed input rasters plus two normalized RGBA footprints.
        let lease = try await budget.acquire(bytes: Int64(targetSide) * Int64(targetSide) * 20)
        guard occupied < limits.photoRequestConcurrency else {
            await lease.finishPhysicalWork(); throw ReadExecutorError.resourceExhausted
        }
        guard !Task.isCancelled, isCurrent() else {
            await lease.finishPhysicalWork()
            if Task.isCancelled { throw CancellationError() }
            throw PhotoKitGatewayError.libraryChanged
        }
        occupied += 1
        let state = RepresentationRequestState(descriptor: descriptor, lease: lease, side: targetSide, isCurrent: isCurrent)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation, timeout: .seconds(limits.requestTimeoutSeconds))
                do {
                    guard state.beginRequest() else {
                        if let final = state.receive(.cancelled) {
                            Task { self.completed(); await state.completePhysical(final) }
                        }
                        return
                    }
                    try requester.request(descriptor, targetSide: targetSide) { [self, state] event in
                        guard let final = state.receive(event) else { return }
                        Task {
                            await self.completed()
                            await state.completePhysical(final)
                        }
                    }
                } catch {
                    if let final = state.receive(.failure(error)) {
                        Task {
                            self.completed()
                            await state.completePhysical(final)
                        }
                    }
                }
            }
        } onCancel: { state.cancel() }
    }
    private func completed() { occupied -= 1 }
}

private final class RepresentationRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: RepresentationDescriptor
    private let lease: ImageLease
    private let side: Int
    private let isCurrent: @Sendable () -> Bool
    private var continuation: CheckedContinuation<LoadedRepresentation, Error>?
    private var logicalError: Error?
    private var physicalEnded = false
    private var delivered = false
    private var timeoutTask: Task<Void, Never>?

    init(descriptor: RepresentationDescriptor, lease: ImageLease, side: Int, isCurrent: @escaping @Sendable () -> Bool) {
        self.descriptor = descriptor; self.lease = lease; self.side = side; self.isCurrent = isCurrent
    }
    func install(_ continuation: CheckedContinuation<LoadedRepresentation, Error>, timeout: Duration) {
        lock.lock()
        if let logicalError { lock.unlock(); continuation.resume(throwing: logicalError); return }
        self.continuation = continuation
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout); self?.cancel(ReadExecutorError.timedOut) } catch {}
        }
        lock.unlock()
    }
    func beginRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }; return logicalError == nil
    }
    func cancel(_ error: Error = CancellationError()) {
        lock.lock()
        guard !delivered, logicalError == nil else { lock.unlock(); return }
        logicalError = error
        let continuation = self.continuation; self.continuation = nil
        let timer = timeoutTask; timeoutTask = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(throwing: error)
        // Do not cancelImageRequest: PhotoKit may suppress all callbacks. A late
        // terminal callback is the evidence which releases the physical slot.
    }
    func receive(_ event: PhotosRepresentationCallback) -> Result<LoadedRepresentation, Error>? {
        lock.lock(); defer { lock.unlock() }
        guard !physicalEnded else { return nil }
        if case .degraded = event { return nil }
        physicalEnded = true
        switch event {
        case .image(let image, let orientation, let eligibility):
            guard image.width <= side, image.height <= side,
                  image.bytesPerRow <= Int(lease.reservedBytes) / max(image.height, 1) else {
                return .failure(PhotosRepresentationError.oversized(width: image.width, height: image.height))
            }
            return .success(LoadedRepresentation(image: image, orientation: orientation, descriptor: descriptor,
                                                 lease: lease, eligibility: eligibility))
        case .failure(let error): return .failure(error)
        case .cancelled: return .failure(CancellationError())
        case .degraded: return nil
        }
    }
    func completePhysical(_ result: Result<LoadedRepresentation, Error>) async {
        let publication = takePublication(result)
        switch publication {
        case .success(let value, let continuation): continuation.resume(returning: value)
        case .failure(let error, let continuation):
            await lease.finishPhysicalWork()
            continuation?.resume(throwing: error)
        }
    }
    private enum Publication {
        case success(LoadedRepresentation, CheckedContinuation<LoadedRepresentation, Error>)
        case failure(Error, CheckedContinuation<LoadedRepresentation, Error>?)
    }
    private func takePublication(_ result: Result<LoadedRepresentation, Error>) -> Publication {
        lock.lock(); defer { lock.unlock() }
        timeoutTask?.cancel(); timeoutTask = nil
        let continuation = self.continuation; self.continuation = nil
        if let logicalError { return .failure(logicalError, continuation) }
        guard isCurrent() else { return .failure(PhotoKitGatewayError.libraryChanged, continuation) }
        switch result {
        case .success(let value):
            guard let continuation else { return .failure(CancellationError(), nil) }
            delivered = true
            return .success(value, continuation)
        case .failure(let error): return .failure(error, continuation)
        }
    }
}

/// Draw the NSImage's displayed content rather than extracting an un-oriented
/// backing representation. The destination has known sRGB/8-bit RGBA pixels.
enum PhotosBitmapNormalizer {
    static func normalize(_ image: NSImage, targetSide: Int) throws -> CGImage {
        try autoreleasepool { try normalizeCallbackImage(image, targetSide: targetSide) }
    }

    private static func normalizeCallbackImage(_ image: NSImage, targetSide: Int) throws -> CGImage {
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0, !image.representations.isEmpty else {
            throw PhotosRepresentationError.invalidImage
        }
        let (targetPixels, pixelOverflow) = Int64(targetSide).multipliedReportingOverflow(by: Int64(targetSide))
        // The existing 20 B/target-pixel lease includes both the 4 B/px
        // CGContext and 4 B/px result: do not assume makeImage shares storage.
        let (incomingLimit, limitOverflow) = targetPixels.multipliedReportingOverflow(by: 12)
        guard targetSide > 0, !pixelOverflow, !limitOverflow else { throw PhotosRepresentationError.invalidImage }
        var incomingBytes: Int64 = 0
        // Public access can materialize an AppKit raster. Keep those accounted
        // temporaries local; only the normalized result crosses the async boundary.
        var materializations: [CGImage] = []
        for representation in image.representations {
            let width = representation.pixelsWide, height = representation.pixelsHigh
            guard width > 0, height > 0 else {
                throw PhotosRepresentationError.oversized(width: width, height: height)
            }
            let backingBytes: Int64
            if let bitmap = representation as? NSBitmapImageRep {
                guard width <= targetSide, height <= targetSide else {
                    throw PhotosRepresentationError.oversized(width: width, height: height)
                }
                // Count every existing bitmap plane/stride rather than replacing
                // its padded storage with an estimate from a smaller conversion.
                guard bitmap.bytesPerRow > 0, bitmap.bytesPerPlane > 0, bitmap.numberOfPlanes > 0 else {
                    throw PhotosRepresentationError.invalidImage
                }
                let (rowSpan, rowOverflow) = Int64(bitmap.bytesPerRow).multipliedReportingOverflow(by: Int64(height))
                guard !rowOverflow else { throw PhotosRepresentationError.invalidImage }
                let planeSpan = max(rowSpan, Int64(bitmap.bytesPerPlane))
                let (storage, planeOverflow) = planeSpan.multipliedReportingOverflow(by: Int64(bitmap.numberOfPlanes))
                guard !planeOverflow else { throw PhotosRepresentationError.invalidImage }
                backingBytes = storage
            } else {
                // Non-bitmap rep dimensions can reflect display scaling rather
                // than backing pixels (including NSImage(cgImage:size:)). Use
                // the public raster's actual dimensions for the same bound.
                // Accounting only: extraction does not establish orientation.
                // Hints are not a framework-allocation guarantee; validate the
                // exposed raster, and still use native drawing for final pixels.
                var proposed = NSRect(x: 0, y: 0, width: targetSide, height: targetSide)
                guard let raster = representation.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
                      raster.width > 0, raster.height > 0, raster.bytesPerRow > 0 else {
                    throw PhotosRepresentationError.invalidImage
                }
                guard raster.width <= targetSide, raster.height <= targetSide else {
                    throw PhotosRepresentationError.oversized(width: raster.width, height: raster.height)
                }
                let (storage, overflow) = Int64(raster.bytesPerRow).multipliedReportingOverflow(by: Int64(raster.height))
                guard !overflow else { throw PhotosRepresentationError.invalidImage }
                backingBytes = storage
                materializations.append(raster)
            }
            let (totalBytes, totalOverflow) = incomingBytes.addingReportingOverflow(backingBytes)
            guard !totalOverflow, totalBytes <= incomingLimit else {
                throw PhotosRepresentationError.oversized(width: width, height: height)
            }
            incomingBytes = totalBytes
        }
        let scale = min(CGFloat(targetSide) / image.size.width, CGFloat(targetSide) / image.size.height)
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PhotosRepresentationError.invalidImage
        }
        NSGraphicsContext.saveGraphicsState()
        defer {
            NSGraphicsContext.restoreGraphicsState()
            withExtendedLifetime(materializations) {}
        }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero,
                   operation: .copy, fraction: 1, respectFlipped: false,
                   hints: [.interpolation: NSImageInterpolation.high])
        guard let result = context.makeImage() else { throw PhotosRepresentationError.invalidImage }
        return result
    }
}

struct PhotoKitRepresentationResource: Sendable {
    let type: PHAssetResourceType
    let uti: String
    let filename: String
    let size: PixelSize?
}

/// Public resource facts, separated from PHAsset for deterministic catalog tests.
struct PhotoKitRepresentationAsset: Sendable {
    let identifier: String
    let modificationDate: Date?
    let playbackStyle: PHAsset.PlaybackStyle
    let resources: [PhotoKitRepresentationResource]

    func selected(_ kind: RepresentationKind) -> PhotoKitRepresentationResource? {
        let originals = resources.filter { $0.type == .photo }
        let edited = resources.filter { $0.type == .fullSizePhoto }
        if kind == .current {
            if !edited.isEmpty { return edited.count == 1 ? edited[0] : nil }
            if resources.contains(where: { [.adjustmentData, .adjustmentBasePhoto].contains($0.type) }) { return nil }
        }
        return originals.count == 1 ? originals[0] : nil
    }

    func eligibility(_ kind: RepresentationKind) throws -> RepresentationEligibility {
        let photos = resources.filter { [.photo, .alternatePhoto, .fullSizePhoto].contains($0.type) }
        guard !photos.isEmpty else { throw PhotosRepresentationError.unavailable }
        // .original can choose RAW from RAW+JPEG; never silently broaden RAW scope.
        if (kind == .original ? photos : selected(kind).map { [$0] } ?? []).contains(where: {
            UTType($0.uti)?.conforms(to: .rawImage) == true
        }) { throw PhotosRepresentationError.unsupportedRAW }
        guard let selected = selected(kind) else { return .conservative(.ambiguousResource) }
        guard playbackStyle == .image || playbackStyle == .livePhoto else { return .conservative(.multiFrameOrCompound) }
        guard !resources.contains(where: { $0.type == .alternatePhoto }) else { return .conservative(.multiFrameOrCompound) }
        let stillTypes = ["public.jpeg", "public.png", "public.heic", "public.heif"]
        guard stillTypes.contains(selected.uti) else {
            return .conservative(["com.compuserve.gif", "public.tiff"].contains(selected.uti) ? .multiFrameOrCompound : .unverifiedContainer)
        }
        return .safeSingleFrame
    }

    func descriptor(kind: RepresentationKind, context: LibraryContext) -> RepresentationDescriptor {
        let resource = selected(kind)
        let edited = resources.contains { [.fullSizePhoto, .adjustmentData, .adjustmentBasePhoto].contains($0.type) }
        let facts = resources.map { "\($0.type.rawValue):\($0.uti):\($0.filename.utf8.count):\($0.filename):\($0.size?.width ?? 0)x\($0.size?.height ?? 0)" }.sorted()
        let revision = ([identifier, kind.rawValue, modificationDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "unknown"] + facts).joined(separator: "|")
        return RepresentationDescriptor(key: RepresentationKey(assetID: identifier, kind: kind), context: context,
                                        revision: SHA256.hash(data: Data(revision.utf8)).map { String(format: "%02x", $0) }.joined(), size: resource?.size, equivalentToOriginal: kind == .original || !edited,
                                        revisionIsReliable: modificationDate != nil && resource != nil)
    }

    init(asset: PHAsset) {
        identifier = asset.localIdentifier
        modificationDate = asset.modificationDate
        playbackStyle = asset.playbackStyle
        resources = PHAssetResource.assetResources(for: asset).map {
            PhotoKitRepresentationResource(type: $0.type, uti: $0.uniformTypeIdentifier, filename: $0.originalFilename,
                size: $0.pixelWidth > 0 && $0.pixelHeight > 0 ? try? PixelSize(width: $0.pixelWidth, height: $0.pixelHeight) : nil)
        }
    }
    init(identifier: String, modificationDate: Date?, playbackStyle: PHAsset.PlaybackStyle, resources: [PhotoKitRepresentationResource]) {
        self.identifier = identifier; self.modificationDate = modificationDate; self.playbackStyle = playbackStyle; self.resources = resources
    }
}

final class SystemPhotosRepresentationRequester: PhotosRepresentationRequesting, @unchecked Sendable {
    private let manager: PHImageManager
    init(manager: PHImageManager = PHImageManager()) { self.manager = manager }
    static func classifyUnavailable(error: Error, inCloud: Bool) -> Error {
        let native = error as NSError
        let networkCodes = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost]
        if inCloud || (native.domain == NSURLErrorDomain && networkCodes.contains(native.code)) {
            return PhotosRepresentationError.iCloudUnavailable(String(describing: error))
        }
        return error
    }

    func request(_ descriptor: RepresentationDescriptor, targetSide: Int,
                 completion: @escaping @Sendable (PhotosRepresentationCallback) -> Void) throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [descriptor.key.assetID], options: nil).firstObject,
              asset.mediaType == .image else { throw PhotosRepresentationError.unavailable }
        let facts = PhotoKitRepresentationAsset(asset: asset)
        guard facts.descriptor(kind: descriptor.key.kind, context: descriptor.context) == descriptor else {
            throw PhotoKitGatewayError.libraryChanged
        }
        let eligibility = try facts.eligibility(descriptor.key.kind)
        let options = PHImageRequestOptions()
        options.version = descriptor.key.kind == .original ? .original : .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let finalGate = RepresentationFinalCallbackGate()
        manager.requestImage(for: asset, targetSize: CGSize(width: targetSide, height: targetSide), contentMode: .aspectFit,
                             options: options) { image, info in
            let error = info?[PHImageErrorKey] as? Error
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            if error == nil, !cancelled, (info?[PHImageResultIsDegradedKey] as? Bool) == true { completion(.degraded); return }
            guard finalGate.take() else { return }
            if let error {
                completion(.failure(Self.classifyUnavailable(error: error,
                    inCloud: (info?[PHImageResultIsInCloudKey] as? Bool) == true)))
                return
            }
            if cancelled { completion(.cancelled); return }
            guard let image else {
                completion(.failure(Self.classifyUnavailable(error: PhotosRepresentationError.invalidImage,
                    inCloud: (info?[PHImageResultIsInCloudKey] as? Bool) == true)))
                return
            }
            do { completion(.image(try PhotosBitmapNormalizer.normalize(image, targetSide: targetSide), orientation: .up, eligibility: eligibility)) }
            catch { completion(.failure(error)) }
        }
    }
}

private final class RepresentationFinalCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return false }; ended = true; return true
    }
}
