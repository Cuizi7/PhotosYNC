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
    case unsupportedRepresentation(RepresentationConservativeReason)
    case oversized(width: Int, height: Int)
    case encodedResourceLimit
    case ambiguousResource
    case resourceStorageUnavailable(String)
    /// A terminal resource callback, never a pre-request/catalog/model failure.
    case imageReadFailed(domain: String, code: Int, detail: String)
    case requestFailed(String)

    var isIsolatableReadFailure: Bool {
        switch self {
        case .imageReadFailed, .invalidImage, .oversized, .encodedResourceLimit, .ambiguousResource, .unsupportedRepresentation: return true
        default: return false
        }
    }
}

enum PhotosRepresentationCallback: @unchecked Sendable {
    case chunk(Data)
    case complete(eligibility: RepresentationEligibility)
    case failure(Error)
    case cancelled
}

protocol PhotosRepresentationRequesting: Sendable {
    /// Throw only before starting physical work. Returned cancellation is a
    /// request, never evidence of completion; it may arrive after callbacks.
    func request(_ descriptor: RepresentationDescriptor,
                 completion: @escaping @Sendable (PhotosRepresentationCallback) -> Void) throws -> @Sendable () -> Void
}

public actor PhotosRepresentationReader {
    private let indexDiagnostics: IndexDiagnostics?
    private let requester: any PhotosRepresentationRequesting
    private let budget: ImageWorkBudget
    private let configuration: DedupConfiguration
    private let resourceLimits: PhotosResourceLimits
    private let storage: PhotosResourceStorage
    private let decode: @Sendable (URL, DedupConfiguration, Int64) throws -> SourceImage
    private var active: [UUID: RepresentationRequestState] = [:]
    public var physicalRequestCount: Int { active.count }

    init(requester: any PhotosRepresentationRequesting, budget: ImageWorkBudget, configuration: DedupConfiguration, indexDiagnostics: IndexDiagnostics? = nil,
         resourceLimits: PhotosResourceLimits = PhotosResourceLimits(), storage: PhotosResourceStorage = PhotosResourceStorage(),
         decode: @escaping @Sendable (URL, DedupConfiguration, Int64) throws -> SourceImage = {
             try EncodedImageDecoder.decode(url: $0, configuration: $1, decodedAllowance: $2)
         }) {
        self.indexDiagnostics = indexDiagnostics
        self.requester = requester; self.budget = budget; self.configuration = configuration
        self.resourceLimits = resourceLimits; self.storage = storage; self.decode = decode
    }

    public func read(_ descriptor: RepresentationDescriptor,
                     isCurrent: @escaping @Sendable () -> Bool) async throws -> LoadedRepresentation {
        try Task.checkCancellation()
        guard active.isEmpty else { throw ReadExecutorError.resourceExhausted }
        let diagnostic = indexDiagnostics?.operation("request")
        diagnostic?.record(["phase": "photos-reader", "event": "admission"], descriptor: descriptor)
        let lease = try await budget.acquire(bytes: configuration.resources.maxDecodedBytes)
        lease.setIndexDiagnostic(diagnostic, descriptor: descriptor)
        guard active.isEmpty else { await lease.finishPhysicalWork(); throw ReadExecutorError.resourceExhausted }
        guard !Task.isCancelled, isCurrent() else {
            await lease.finishPhysicalWork()
            if Task.isCancelled { throw CancellationError() }
            throw PhotoKitGatewayError.libraryChanged
        }
        let resource: OwnedPhotosResource
        do { resource = try storage.create(limits: resourceLimits) }
        catch { await lease.finishPhysicalWork(); throw PhotosRepresentationError.resourceStorageUnavailable(String(describing: error)) }
        let id = UUID()
        let state = RepresentationRequestState(descriptor: descriptor, lease: lease, resource: resource,
            configuration: configuration, decode: decode, isCurrent: isCurrent, diagnostic: diagnostic)
        // Retain state even if cancellation makes PhotoKit discard its callbacks.
        // Only trustworthy terminal completion removes the physical owner.
        active[id] = state
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation, timeout: .seconds(configuration.resources.requestTimeoutSeconds))
                let finish: @Sendable (Result<LoadedRepresentation, Error>) -> Void = { [self, state] result in
                    Task { await self.completed(id); await state.completePhysical(result) }
                }
                guard state.beginRequest() else { state.receive(.cancelled, finish: finish); return }
                do {
                    let cancel = try requester.request(descriptor) { [state] event in state.receive(event, finish: finish) }
                    state.installCancellation(cancel)
                } catch {
                    // No framework work started: a thrown validation error is not
                    // evidence authorizing isolation as a damaged image.
                    let requestError: Error = (error as? PhotosRepresentationError)?.isIsolatableReadFailure == true
                        ? PhotosRepresentationError.requestFailed(String(describing: error)) : error
                    state.receive(.failure(requestError), finish: finish)
                }
            }
        } onCancel: { state.cancel() }
    }
    private func completed(_ id: UUID) { active.removeValue(forKey: id) }
}

private final class RepresentationRequestState: @unchecked Sendable {
    private let diagnostic: IndexDiagnosticOperation?
    private let lock = NSLock()
    private let writerLock = NSLock()
    private let descriptor: RepresentationDescriptor
    private let lease: ImageLease
    private let resource: OwnedPhotosResource
    private let configuration: DedupConfiguration
    private let decode: @Sendable (URL, DedupConfiguration, Int64) throws -> SourceImage
    private let isCurrent: @Sendable () -> Bool
    private var continuation: CheckedContinuation<LoadedRepresentation, Error>?
    private var logicalError: Error?
    private var streamError: Error?
    private var streamEnded = false
    private var delivered = false
    private var cancelRequest: (@Sendable () -> Void)?
    private var cancelSent = false
    private var timeoutTask: Task<Void, Never>?

    init(descriptor: RepresentationDescriptor, lease: ImageLease, resource: OwnedPhotosResource,
         configuration: DedupConfiguration, decode: @escaping @Sendable (URL, DedupConfiguration, Int64) throws -> SourceImage, isCurrent: @escaping @Sendable () -> Bool, diagnostic: IndexDiagnosticOperation? = nil) {
        self.diagnostic = diagnostic
        self.descriptor = descriptor; self.lease = lease; self.resource = resource
        self.configuration = configuration; self.decode = decode; self.isCurrent = isCurrent
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
        lock.lock(); let begins = logicalError == nil; lock.unlock()
        if begins { diagnostic?.record(["phase": "photos-reader", "event": "request"], descriptor: descriptor) }
        return begins
    }
    func installCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        lock.lock(); cancelRequest = cancellation
        let cancel = takeCancellation(); lock.unlock()
        if let cancel { DispatchQueue.global(qos: .utility).async(execute: cancel) }
    }
    private func takeCancellation() -> (@Sendable () -> Void)? {
        guard logicalError != nil, !streamEnded, !cancelSent, let cancelRequest else { return nil }
        cancelSent = true; return cancelRequest
    }
    func cancel(_ error: Error = CancellationError()) {
        lock.lock()
        guard !delivered, logicalError == nil else { lock.unlock(); return }
        logicalError = error
        let continuation = self.continuation; self.continuation = nil
        let timer = timeoutTask; timeoutTask = nil
        let cancel = takeCancellation(); lock.unlock()
        diagnostic?.record(["phase": "photos-reader", "event": error as? ReadExecutorError == .timedOut ? "timeout" : "cancel", "physical": "retained"], descriptor: descriptor)
        timer?.cancel(); continuation?.resume(throwing: error)
        // A framework cancel can reenter its terminal handler; keep this logical
        // handler independent of the writer and callback drain.
        if let cancel { DispatchQueue.global(qos: .utility).async(execute: cancel) }
    }
    func receive(_ event: PhotosRepresentationCallback, finish: @escaping @Sendable (Result<LoadedRepresentation, Error>) -> Void) {
        // Publication/cancellation never waits for local disk I/O. This lock
        // serializes writes with terminal closure while the separate state lock
        // only protects short continuation and request-state transitions.
        writerLock.lock(); lock.lock()
        guard !streamEnded else { lock.unlock(); writerLock.unlock(); return }
        if case .chunk(let data) = event {
            guard logicalError == nil, streamError == nil else { lock.unlock(); writerLock.unlock(); return }
            lock.unlock()
            do { try resource.append(data); writerLock.unlock() }
            catch {
                lock.lock(); streamError = error; lock.unlock()
                writerLock.unlock(); cancel(error)
            }
            return
        }
        streamEnded = true
        var error = streamError
        switch event {
        case .failure(let failure):
            if error == nil { error = SystemPhotosRepresentationRequester.classifyUnavailable(error: failure, inCloud: false) }
        case .cancelled: if error == nil { error = CancellationError() }
        case .complete: break
        case .chunk: break
        }
        lock.unlock()
        do { try resource.closeStream() } catch let closeError { if error == nil { error = closeError } }
        lock.lock(); let finalError = error ?? logicalError; lock.unlock()
        writerLock.unlock()
        diagnostic?.record(["phase": "photos-reader", "event": "terminal", "result": finalError == nil ? "complete" : "failure"], descriptor: descriptor)
        // Physical ownership includes close, real decode and every lazy pixel
        // consumer. Decoding never runs on the actor or framework callback queue.
        DispatchQueue.global(qos: .utility).async { [self] in
            if let finalError { resource.remove(); finish(.failure(finalError)); return }
            let result: Result<LoadedRepresentation, Error> = Result {
                let decoded: SourceImage
                do { decoded = try decode(resource.url, configuration, lease.reservedBytes) }
                catch { throw PhotosRepresentationError.invalidImage }
                guard case .complete(let eligibility) = event else { throw PhotosRepresentationError.invalidImage }
                if case .conservative(let reason) = decoded.eligibility {
                    // Header/decode evidence can be narrower than catalog facts.
                    // Retain the exact reason as an item gap, never a vector or
                    // a global library-change claim; Source policy is unchanged.
                    throw PhotosRepresentationError.unsupportedRepresentation(reason)
                }
                let combined = eligibility == .safeSingleFrame ? decoded.eligibility : eligibility
                lease.retainPhysicalResource { [resource] in resource.remove() }
                return LoadedRepresentation(image: decoded.image, orientation: decoded.orientation,
                    descriptor: descriptor, lease: lease, eligibility: combined)
            }
            if case .failure = result { resource.remove() }
            finish(result)
        }
    }
    func completePhysical(_ result: Result<LoadedRepresentation, Error>) async {
        let publication = takePublication(result)
        diagnostic?.record(["phase": "photos-reader", "event": "drain"], descriptor: descriptor)
        switch publication {
        case .success(let value, let continuation):
            diagnostic?.record(["phase": "photos-reader", "event": "lease-returned", "physical": "consumer-owned"], descriptor: descriptor)
            continuation.resume(returning: value)
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
            delivered = true; return .success(value, continuation)
        case .failure(let error): return .failure(error, continuation)
        }
    }
}

struct PhotoKitRepresentationResource: Equatable, Sendable {
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

    /// Content detail false is necessary but insufficient: compare every public
    /// input/eligibility fact used by this reader, excluding modification time.
    func inputsUnchanged(from before: PhotoKitRepresentationAsset, assetContentChanged: Bool) -> Bool {
        guard !assetContentChanged, identifier == before.identifier, playbackStyle == before.playbackStyle else { return false }
        let normalized = PhotoKitRepresentationAsset(identifier: identifier, modificationDate: before.modificationDate,
            playbackStyle: playbackStyle, resources: resources)
        let context = LibraryContext(id: UUID(), epoch: 0)
        return [RepresentationKind.original, .current].allSatisfy { kind in
            before.descriptor(kind: kind, context: context) == normalized.descriptor(kind: kind, context: context) &&
            (try? before.eligibility(kind)) == (try? normalized.eligibility(kind))
        }
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
    private let manager: PHAssetResourceManager
    init(manager: PHAssetResourceManager = PHAssetResourceManager.default()) { self.manager = manager }
    static func classifyUnavailable(error: Error, inCloud: Bool) -> Error {
        if error is CancellationError { return error }
        if let classified = error as? PhotosRepresentationError { return inCloud ? PhotosRepresentationError.iCloudUnavailable(String(describing: error)) : classified }
        if error is PhotoKitGatewayError || error is ReadExecutorError || error is ImageWorkBudgetError { return error }
        let native = error as NSError
        let global: [PHPhotosError.Code] = [.libraryVolumeOffline, .relinquishingLibraryBundleToWriter,
            .switchingSystemPhotoLibrary, .accessRestricted, .accessUserDenied, .operationInterrupted,
            .identifierNotFound, .multipleIdentifiersFound, .notEnoughSpace,
            .persistentChangeTokenExpired, .persistentChangeDetailsUnavailable, .libraryInFileProviderSyncRoot]
        let networkCodes = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost]
        var current: Error? = error
        var seen = Set<ObjectIdentifier>()
        var cancelled = false, blocking = false, network = inCloud, otherURLFailure = false
        // Bound malformed error graphs before formatting their recursive NSError
        // description. An unverified tail can never authorize an image-only gap.
        func unverifiedChain() -> Error {
            if cancelled { return CancellationError() }
            return PhotosRepresentationError.requestFailed("PhotoKit error chain could not be fully checked: \(native.domain)/\(native.code), \(native.localizedDescription)")
        }
        for _ in 0..<64 {
            guard let item = current else { break }
            let cause = item as NSError
            guard seen.insert(ObjectIdentifier(cause)).inserted else { return unverifiedChain() }
            if item is CancellationError { cancelled = true }
            if let classified = item as? PhotosRepresentationError {
                if case .iCloudUnavailable = classified { network = true }
                else if !classified.isIsolatableReadFailure { blocking = true }
            }
            if item is PhotoKitGatewayError || item is ReadExecutorError || item is ImageWorkBudgetError { blocking = true }
            if (cause.domain == NSCocoaErrorDomain && cause.code == NSUserCancelledError) ||
               (cause.domain == NSURLErrorDomain && cause.code == NSURLErrorCancelled) ||
               (cause.domain == PHPhotosErrorDomain && cause.code == PHPhotosError.Code.userCancelled.rawValue) {
                cancelled = true
            }
            if cause.domain == PHPhotosErrorDomain {
                if global.contains(where: { $0.rawValue == cause.code }) { blocking = true }
                if cause.code == PHPhotosError.Code.networkAccessRequired.rawValue ||
                   cause.code == PHPhotosError.Code.networkError.rawValue { network = true }
            }
            if cause.domain == NSURLErrorDomain {
                if networkCodes.contains(cause.code) { network = true }
                else if cause.code != NSURLErrorCancelled { otherURLFailure = true }
            }
            guard let underlying = cause.userInfo[NSUnderlyingErrorKey] else { current = nil; break }
            guard let underlyingError = underlying as? Error else { return unverifiedChain() }
            current = underlyingError
        }
        guard current == nil else { return unverifiedChain() }
        if cancelled { return CancellationError() }
        if blocking { return error }
        // Keep the original wrapper and complete verified cause chain in the
        // existing diagnostics, rather than substituting only the deepest cause.
        if network { return PhotosRepresentationError.iCloudUnavailable(String(describing: error)) }
        if otherURLFailure { return error }
        return PhotosRepresentationError.imageReadFailed(domain: native.domain, code: native.code,
            detail: String(describing: native))
    }

    func request(_ descriptor: RepresentationDescriptor,
                 completion: @escaping @Sendable (PhotosRepresentationCallback) -> Void) throws -> @Sendable () -> Void {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [descriptor.key.assetID], options: nil).firstObject,
              asset.mediaType == .image else { throw PhotosRepresentationError.unavailable }
        let facts = PhotoKitRepresentationAsset(asset: asset)
        guard facts.descriptor(kind: descriptor.key.kind, context: descriptor.context) == descriptor else {
            throw PhotoKitGatewayError.libraryChanged
        }
        let eligibility = try facts.eligibility(descriptor.key.kind)
        guard let selected = facts.selected(descriptor.key.kind) else { throw PhotosRepresentationError.ambiguousResource }
        let resources = PHAssetResource.assetResources(for: asset)
        let exact = resources.filter {
            $0.type == selected.type && $0.uniformTypeIdentifier == selected.uti && $0.originalFilename == selected.filename &&
            ($0.pixelWidth > 0 && $0.pixelHeight > 0 ? try? PixelSize(width: $0.pixelWidth, height: $0.pixelHeight) : nil) == selected.size
        }
        guard exact.count == 1 else { throw PhotosRepresentationError.ambiguousResource }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        let requestID = manager.requestData(for: exact[0], options: options, dataReceivedHandler: { completion(.chunk($0)) }) { error in
            if let error { completion(.failure(Self.classifyUnavailable(error: error, inCloud: false))); return }
            guard let current = PHAsset.fetchAssets(withLocalIdentifiers: [descriptor.key.assetID], options: nil).firstObject else {
                completion(.failure(PhotoKitGatewayError.libraryChanged)); return
            }
            let after = PhotoKitRepresentationAsset(asset: current)
            guard after.descriptor(kind: descriptor.key.kind, context: descriptor.context) == descriptor,
                  (try? after.eligibility(descriptor.key.kind)) == eligibility else {
                completion(.failure(PhotoKitGatewayError.libraryChanged)); return
            }
            completion(.complete(eligibility: eligibility))
        }
        return { [manager] in manager.cancelDataRequest(requestID) }
    }
}
