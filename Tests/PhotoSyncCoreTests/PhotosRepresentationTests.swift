import XCTest
import AppKit
import Photos
import CoreGraphics
import ImageIO
@testable import PhotoSyncCore

final class PhotosRepresentationTests: XCTestCase {
    func testTerminalCocoaCallbackPreservesErrorAndReleasesPhysicalLease() async throws {
        let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(), targetSide: 32)
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started()
        requester.send(.failure(NSError(domain: NSCocoaErrorDomain, code: -1,
            userInfo: [NSLocalizedDescriptionKey: "synthetic callback detail"])))
        do { _ = try await task.value; XCTFail("terminal failure") }
        catch {
            guard case .imageReadFailed(let domain, let code, let detail) = error as? PhotosRepresentationError else { return XCTFail("explicit callback error: \(error)") }
            XCTAssertEqual(domain, NSCocoaErrorDomain); XCTAssertEqual(code, -1)
            XCTAssertTrue(detail.contains("synthetic callback detail"))
        }
        let occupied = await reader.physicalRequestCount, released = await budget.snapshot()
        XCTAssertEqual(occupied, 0); XCTAssertEqual(released.images, 0)
    }

    func testKnownGlobalNetworkAndCancellationCallbacksCannotBeSoft() async throws {
        let photosCodes: [PHPhotosError.Code] = [.libraryVolumeOffline, .relinquishingLibraryBundleToWriter,
            .switchingSystemPhotoLibrary, .accessRestricted, .accessUserDenied, .operationInterrupted,
            .identifierNotFound, .multipleIdentifiersFound, .networkAccessRequired, .networkError, .userCancelled]
        let errors = photosCodes.map { NSError(domain: PHPhotosErrorDomain, code: $0.rawValue) } + [
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)]
        for native in errors {
            let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
            let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(), targetSide: 32)
            let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
            await requester.started(); requester.send(.failure(native))
            do { _ = try await task.value; XCTFail("callback failed") }
            catch {
                XCTAssertFalse((error as? PhotosRepresentationError)?.isIsolatableReadFailure == true, "\(native)")
                if native.code == 3072 || native.code == -999 {
                    XCTAssertTrue(error is CancellationError)
                } else if native.code == 3164 || native.code == 3169 || native.code == -1005 {
                    guard case .iCloudUnavailable = error as? PhotosRepresentationError else { return XCTFail("network wait: \(native)") }
                } else {
                    XCTAssertEqual((error as NSError).domain, native.domain)
                    XCTAssertEqual((error as NSError).code, native.code)
                }
            }
            let released = await budget.snapshot(); XCTAssertEqual(released.images, 0)
        }
        let inCloud = SystemPhotosRepresentationRequester.classifyUnavailable(error: NSError(domain: NSCocoaErrorDomain, code: -1), inCloud: true)
        guard case .iCloudUnavailable = inCloud as? PhotosRepresentationError else { return XCTFail("cloud wait must remain waiting") }
    }

    func testPreRequestInvalidImageErrorHasNoCallbackAuthorization() async throws {
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: ValidationFailingRepresentationRequester(), budget: budget,
            limits: try limits(), targetSide: 32)
        do { _ = try await reader.read(descriptor(), isCurrent: { true }); XCTFail("pre-request validation") }
        catch { XCTAssertFalse((error as? PhotosRepresentationError)?.isIsolatableReadFailure == true) }
        let released = await budget.snapshot(); XCTAssertEqual(released.images, 0)
    }

    func testDegradedThenFinalPublishesOnce() async throws {
        let requester = ControlledRepresentationRequester()
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(), targetSide: 32)
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started()
        requester.send(.degraded)
        let occupied = await reader.physicalRequestCount
        XCTAssertEqual(occupied, 1)
        requester.send(.image(try bitmap(), orientation: .up, eligibility: .safeSingleFrame))
        let loaded = try await task.value
        requester.send(.image(try bitmap(), orientation: .down, eligibility: .safeSingleFrame))
        XCTAssertEqual(loaded.orientation, .up)
        let afterFinal = await reader.physicalRequestCount
        XCTAssertEqual(afterFinal, 0)
        let held = await budget.snapshot()
        XCTAssertEqual(held.images, 1, "consumer still owns the decoded image")
        await loaded.lease.finishPhysicalWork()
    }

    func testCancelThenLateFinalDoesNotPublishOrFreeEarly() async throws {
        let requester = ControlledRepresentationRequester()
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(), targetSide: 32)
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started()
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled caller cannot publish") } catch { XCTAssertTrue(error is CancellationError) }
        let occupied = await reader.physicalRequestCount
        let bytes = await budget.snapshot()
        XCTAssertEqual(occupied, 1)
        XCTAssertEqual(bytes.images, 1)
        do { _ = try await reader.read(descriptor(), isCurrent: { true }); XCTFail("replacement request") }
        catch { XCTAssertEqual(error as? ReadExecutorError, .resourceExhausted) }
        requester.send(.image(try bitmap(), orientation: .up, eligibility: .safeSingleFrame))
        for _ in 0..<10_000 {
            if await budget.snapshot().images == 0 { break }
            await Task.yield()
        }
        let released = await budget.snapshot()
        XCTAssertEqual(released.images, 0)
    }

    func testStaleFinalCannotPublish() async throws {
        let requester = ControlledRepresentationRequester()
        let current = LockedRepresentationFlag()
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(), targetSide: 32)
        let task = Task { try await reader.read(descriptor(), isCurrent: { current.value }) }
        await requester.started()
        current.invalidate()
        requester.send(.image(try bitmap(), orientation: .up, eligibility: .safeSingleFrame))
        do { _ = try await task.value; XCTFail("stale image") }
        catch { XCTAssertEqual(error as? PhotoKitGatewayError, .libraryChanged) }
        let released = await budget.snapshot()
        XCTAssertEqual(released.images, 0)
    }

    func testEditedDimensionsBelongToEditedRepresentation() throws {
        let asset = PhotoKitRepresentationAsset(identifier: "asset", modificationDate: Date(), playbackStyle: .image, resources: [
            PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "original.jpg", size: try PixelSize(width: 4000, height: 3000)),
            PhotoKitRepresentationResource(type: .fullSizePhoto, uti: "public.jpeg", filename: "edited.jpg", size: try PixelSize(width: 1000, height: 1000))
        ])
        let context = LibraryContext(id: UUID(), epoch: 0)
        XCTAssertEqual(asset.descriptor(kind: .original, context: context).size, try PixelSize(width: 4000, height: 3000))
        XCTAssertEqual(asset.descriptor(kind: .current, context: context).size, try PixelSize(width: 1000, height: 1000))
        XCTAssertFalse(asset.descriptor(kind: .current, context: context).equivalentToOriginal)
    }

    func testUnknownRevisionCannotReuseCachedImage() throws {
        let asset = PhotoKitRepresentationAsset(identifier: "asset", modificationDate: nil, playbackStyle: .image, resources: [
            PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a.jpg", size: nil)
        ])
        let descriptor = asset.descriptor(kind: .original, context: LibraryContext(id: UUID(), epoch: 0))
        XCTAssertFalse(descriptor.revisionIsReliable)
        XCTAssertNil(descriptor.size)
    }

    func testUnsupportedAndMultiFrameAreExplicitlyClassified() throws {
        for uti in ["com.compuserve.gif", "public.tiff", "com.adobe.photoshop-image"] {
            let asset = PhotoKitRepresentationAsset(identifier: "asset", modificationDate: Date(), playbackStyle: .image,
                resources: [PhotoKitRepresentationResource(type: .photo, uti: uti, filename: "a", size: nil)])
            guard case .conservative = try asset.eligibility(.original) else { return XCTFail("flattened container must not skip") }
        }
        for uti in ["public.heic", "public.png", "public.jpeg"] {
            let resource = PhotoKitRepresentationResource(type: .photo, uti: uti, filename: "a", size: nil)
            for style in [PHAsset.PlaybackStyle.image, .livePhoto] {
                let asset = PhotoKitRepresentationAsset(identifier: "asset", modificationDate: Date(), playbackStyle: style, resources: [resource])
                XCTAssertEqual(try asset.eligibility(.original), .safeSingleFrame)
            }
            let animated = PhotoKitRepresentationAsset(identifier: "asset", modificationDate: Date(), playbackStyle: .imageAnimated, resources: [resource])
            XCTAssertEqual(try animated.eligibility(.original), .conservative(.multiFrameOrCompound))
        }
    }

    func testNativeDrawingNormalizesAllEXIFOrientations() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 96,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (rect, color) in [(CGRect(x: 0, y: 0, width: 12, height: 8), NSColor.red),
                              (CGRect(x: 12, y: 0, width: 12, height: 8), NSColor.green),
                              (CGRect(x: 0, y: 8, width: 12, height: 8), NSColor.blue),
                              (CGRect(x: 12, y: 8, width: 12, height: 8), NSColor.yellow)] {
            context.setFillColor(color.cgColor); context.fill(rect)
        }
        let raw = try XCTUnwrap(context.makeImage())
        for orientation in 1...8 {
            let bytes = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, raw, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes, nil))
            let expected = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary))
            let expectedDrawn = try PhotosBitmapNormalizer.normalize(NSImage(cgImage: expected, size: NSSize(width: expected.width, height: expected.height)), targetSide: 32)
            let actual = try PhotosBitmapNormalizer.normalize(try XCTUnwrap(NSImage(data: bytes as Data)), targetSide: 32)
            XCTAssertEqual(actual.width, expectedDrawn.width, "orientation \(orientation)")
            XCTAssertEqual(actual.height, expectedDrawn.height, "orientation \(orientation)")
            let actualBytes = try XCTUnwrap(actual.dataProvider?.data) as Data
            let expectedBytes = try XCTUnwrap(expectedDrawn.dataProvider?.data) as Data
            XCTAssertEqual(actualBytes.count, expectedBytes.count)
            // Sample quadrant centers, avoiding JPEG edge interpolation differences.
            if actual.width == expectedDrawn.width && actual.height == expectedDrawn.height {
                for y in [actual.height / 4, actual.height * 3 / 4] {
                    for x in [actual.width / 4, actual.width * 3 / 4] {
                        for c in 0..<3 {
                            let a = Int(actualBytes[y * actual.bytesPerRow + x * 4 + c])
                            let b = Int(expectedBytes[y * expectedDrawn.bytesPerRow + x * 4 + c])
                            XCTAssertLessThan(abs(a - b), 24, "orientation \(orientation), corner \(x),\(y), channel \(c)")
                        }
                    }
                }
            }
        }
    }

    func testCatalogPinsGenerationAndNeverBorrowsDimensions() async throws {
        let lifecycle = RepresentationLifecycle()
        lifecycle.assets = [PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image,
            resources: [PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a", size: nil)])]
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 1)
        let snapshot = try await gateway.candidateSnapshot()
        let first = try await gateway.representationCatalog(offset: 0, limit: 1, expectedGeneration: snapshot.generation)
        XCTAssertEqual(first.descriptors.count, 1)
        XCTAssertEqual(first.nextOffset, 1)
        XCTAssertNil(first.descriptors[0].size)
        gateway.recordLibraryChangeForTesting()
        do { _ = try await gateway.representationCatalog(offset: 1, limit: 1, expectedGeneration: snapshot.generation); XCTFail("stale page") }
        catch { XCTAssertEqual(error as? PhotoKitGatewayError, .libraryChanged) }
    }

    func testOverflowRemainsFullReconcileUntilAcknowledged() async {
        let channel = PhotosIndexChangeChannel(capacity: 1)
        var iterator = channel.stream().makeAsyncIterator()
        channel.send(fixtureIndexChange(changed: ["a"]))
        channel.send(fixtureIndexChange(deleted: ["b"]))
        channel.send(fixtureIndexChange(changed: ["c"]))
        let event = await iterator.next()
        XCTAssertEqual(event, .fullReconcileRequired)
        channel.send(fixtureIndexChange(changed: ["d"]))
        let sticky = await iterator.next()
        XCTAssertEqual(sticky, .fullReconcileRequired)
        channel.reconciled()
        channel.send(fixtureIndexChange(changed: ["e"]))
        let clean = await iterator.next()
        XCTAssertEqual(clean, fixtureIndexChange(changed: ["e"]))
    }

    func testResumeRequiresPublicHistoryAndReplaysExplicitChanges() async throws {
        let lifecycle = RepresentationLifecycle()
        lifecycle.replayChanges = [fixtureIndexChange(changed: ["same-revision"]), fixtureIndexChange(deleted: ["deleted"])]
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
        var events = gateway.changes().makeAsyncIterator()
        let oldContext = LibraryContext(id: UUID(), epoch: 4)
        let checkpoint = LibraryResumeCheckpoint(context: oldContext, archivedChangeToken: Data([1]))
        let resumed = try await gateway.resumeContext(checkpoint)
        XCTAssertTrue(resumed)
        let change = await events.next()
        XCTAssertEqual(change, .fullReconcileRequired)
        let snapshot = try await gateway.candidateSnapshot()
        let page = try await gateway.representationCatalog(offset: 0, limit: 128, expectedGeneration: snapshot.generation)
        XCTAssertEqual(page.context, oldContext)
        lifecycle.replaySucceeds = false
        let failed = try await gateway.resumeContext(checkpoint)
        XCTAssertFalse(failed)
        let fresh = try await gateway.contextCheckpoint()
        XCTAssertNotEqual(fresh?.context, oldContext)
    }

    func testSourceCancellationKeepsSharedBudgetAndDecodeSlotOccupied() async throws {
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 64)
        let executor = ReadExecutor(maxConcurrentOperations: 2)
        let entered = expectation(description: "physical source decode entered")
        let release = DispatchSemaphore(value: 0)
        let resourceLimits = try limits()
        let source = UUID()
        let task = Task {
            try await executor.executeImage(sourceID: source, budget: budget, bytes: 32, limits: resourceLimits) {
                entered.fulfill(); release.wait(); return 1
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("logical cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let held = await budget.snapshot()
        XCTAssertEqual(held.images, 1)
        do { _ = try await executor.executeImage(sourceID: UUID(), budget: budget, bytes: 32, limits: resourceLimits) { 2 }; XCTFail("decode replacement") }
        catch { XCTAssertEqual(error as? ReadExecutorError, .resourceExhausted) }
        release.signal()
        for _ in 0..<10_000 {
            if await budget.snapshot().images == 0 { break }
            await Task.yield()
        }
        let released = await budget.snapshot()
        XCTAssertEqual(released.images, 0)
    }

    func testStaleAcknowledgementCannotClearStickyReconciliation() async throws {
        let lifecycle = RepresentationLifecycle()
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 1)
        var events = gateway.changes().makeAsyncIterator()
        let old = try await gateway.candidateSnapshot()
        gateway.recordLibraryChangeForTesting()
        let change = await events.next()
        XCTAssertEqual(change, .fullReconcileRequired)
        do { try await gateway.acknowledgeReconciliation(expectedGeneration: old.generation); XCTFail("stale ack") }
        catch { XCTAssertEqual(error as? PhotoKitGatewayError, .libraryChanged) }
        var stillDirty = gateway.changes().makeAsyncIterator()
        let dirty = await stillDirty.next()
        XCTAssertEqual(dirty, .fullReconcileRequired)
        let current = try await gateway.candidateSnapshot()
        try await gateway.acknowledgeReconciliation(expectedGeneration: current.generation)
        // Direct channel test above proves later narrow events remain narrow after
        // acknowledgement; this test covers the gateway's shared generation gate.
    }

    func testErrorNilCancellationAndOversizeFinishWithoutPublishing() async throws {
        for event in [PhotosRepresentationCallback.failure(PhotosRepresentationError.invalidImage), .cancelled,
                      .image(try largeBitmap(), orientation: .up, eligibility: .safeSingleFrame)] {
            let requester = ControlledRepresentationRequester()
            let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
            let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(), targetSide: 32)
            let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
            await requester.started()
            requester.send(event)
            do { _ = try await task.value; XCTFail("terminal failure cannot publish") } catch {}
            let count = await reader.physicalRequestCount
            let bytes = await budget.snapshot()
            XCTAssertEqual(count, 0)
            XCTAssertEqual(bytes.images, 0)
        }
    }

    private func largeBitmap() throws -> CGImage {
        try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    }

    func testTimeoutAfterDegradedKeepsPhysicalRequestUntilLateTerminal() async throws {
        let requester = ControlledRepresentationRequester()
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(timeout: 0.01), targetSide: 32)
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started()
        requester.send(.degraded)
        do { _ = try await task.value; XCTFail("only degraded is not ready") }
        catch { XCTAssertEqual(error as? ReadExecutorError, .timedOut) }
        let occupied = await reader.physicalRequestCount
        XCTAssertEqual(occupied, 1)
        requester.send(.cancelled)
        for _ in 0..<10_000 {
            if await budget.snapshot().images == 0 { break }
            await Task.yield()
        }
        let released = await budget.snapshot()
        XCTAssertEqual(released.images, 0)
    }

    func testGatewayChangeRejectsLateImageThroughSameGenerationGate() async throws {
        let requester = ControlledRepresentationRequester()
        let lifecycle = RepresentationLifecycle()
        lifecycle.assets = [PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image,
            resources: [PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a", size: nil)])]
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(), targetSide: 32)
        let gateway = PhotoKitGateway(lifecycle: lifecycle, representationReader: reader, catalogBatchSize: 128)
        let snapshot = try await gateway.candidateSnapshot()
        let page = try await gateway.representationCatalog(offset: 0, limit: 128, expectedGeneration: snapshot.generation)
        let task = Task { try await gateway.readRepresentation(page.descriptors[0]) }
        await requester.started()
        gateway.recordLibraryChangeForTesting()
        XCTAssertFalse(try snapshot.candidateValidity.commitIfCurrent({}))
        requester.send(.image(try bitmap(), orientation: .up, eligibility: .safeSingleFrame))
        do { _ = try await task.value; XCTFail("late image from invalid generation") }
        catch { XCTAssertEqual(error as? PhotoKitGatewayError, .libraryChanged) }
    }

    func testNoSubscriberCannotLoseReplayChange() async {
        let channel = PhotosIndexChangeChannel(capacity: 128)
        channel.send(fixtureIndexChange(changed: ["changed while offline"]))
        var events = channel.stream().makeAsyncIterator()
        let event = await events.next()
        XCTAssertEqual(event, .fullReconcileRequired)
    }

    func testRAWOriginalIsExplicitAndMissingEditedResourceHasNoBorrowedSize() throws {
        let original = PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a.jpg", size: try PixelSize(width: 4000, height: 3000))
        let raw = PhotoKitRepresentationResource(type: .alternatePhoto, uti: "public.camera-raw-image", filename: "a.raw", size: nil)
        let compound = PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image, resources: [original, raw])
        XCTAssertThrowsError(try compound.eligibility(.original)) { XCTAssertEqual($0 as? PhotosRepresentationError, .unsupportedRAW) }
        let adjusted = PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image, resources: [original,
            PhotoKitRepresentationResource(type: .adjustmentData, uti: "public.data", filename: "adjustments", size: nil)])
        let current = adjusted.descriptor(kind: .current, context: LibraryContext(id: UUID(), epoch: 0))
        XCTAssertNil(current.size)
        XCTAssertEqual(try adjusted.eligibility(.current), .conservative(.ambiguousResource))
        XCTAssertFalse(current.revisionIsReliable)
    }

    func testSnapshotAcquiredDuringResumeCannotSurviveContextAdoption() async throws {
        let lifecycle = RepresentationLifecycle()
        let entered = expectation(description: "public history replay entered")
        let release = DispatchSemaphore(value: 0)
        lifecycle.onReplay = { entered.fulfill(); release.wait() }
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
        let checkpoint = LibraryResumeCheckpoint(context: LibraryContext(id: UUID(), epoch: 3), archivedChangeToken: Data([1]))
        let task = Task { try await gateway.resumeContext(checkpoint) }
        await fulfillment(of: [entered], timeout: 2)
        let duringReplay = try await gateway.candidateSnapshot()
        do { _ = try await gateway.representationCatalog(offset: 0, limit: 128, expectedGeneration: duringReplay.generation)
            XCTFail("incomplete replay must block catalog evidence") } catch {}
        do { try await gateway.acknowledgeReconciliation(expectedGeneration: duringReplay.generation); XCTFail("replay is in progress") } catch {}
        release.signal()
        let resumed = try await task.value
        XCTAssertTrue(resumed)
        XCTAssertFalse(try duringReplay.candidateValidity.commitIfCurrent({}), "context adoption must invalidate work captured during replay")
    }

    func testAbsentResourcesAreUnknownRatherThanConfirmedExcluded() throws {
        let asset = PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image, resources: [])
        XCTAssertThrowsError(try asset.eligibility(.original)) { XCTAssertEqual($0 as? PhotosRepresentationError, .unavailable) }
    }

    func testSynchronousFinalBeforeRequestReturnsIsDeliveredOnce() async throws {
        let requester = ControlledRepresentationRequester()
        requester.immediateEvent = .image(try bitmap(), orientation: .up, eligibility: .safeSingleFrame)
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(), targetSide: 32)
        let loaded = try await reader.read(descriptor(), isCurrent: { true })
        XCTAssertEqual(loaded.returnedSize, try PixelSize(width: 4, height: 4))
        let physical = await reader.physicalRequestCount
        XCTAssertEqual(physical, 0)
        await loaded.lease.finishPhysicalWork()
    }

    func testReadCallbackWaitsForDelayedClassificationAndKeepsNeutralResult() async throws {
        for affected in [false, true] {
            let lifecycle = RepresentationLifecycle()
            let facts = PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image,
                resources: [.init(type: .photo, uti: "public.jpeg", filename: "a.jpg", size: nil)])
            lifecycle.assets = [facts]
            let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
            let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(), targetSide: 32)
            let gateway = PhotoKitGateway(lifecycle: lifecycle, representationReader: reader, catalogBatchSize: 128)
            _ = try await gateway.candidateSnapshot()
            let capturedCheckpoint = try await gateway.contextCheckpoint()
            let checkpoint = try XCTUnwrap(capturedCheckpoint)
            let d = facts.descriptor(kind: .original, context: checkpoint.context)
            let read = Task { try await gateway.readRepresentation(d) }
            await requester.started()
            let entered = expectation(description: "details entered"), release = DispatchSemaphore(value: 0)
            lifecycle.onChangeDetails = { entered.fulfill(); release.wait() }
            lifecycle.nextIndexChange = .incremental(removedAssetIDs: [], insertedAssets: [],
                changedAssets: [.init(identifier: "a", candidates: [], inputUnchanged: !affected)])
            gateway.recordLibraryChangeForTesting()
            await fulfillment(of: [entered], timeout: 2)
            requester.send(.image(try bitmap(), orientation: .up, eligibility: .safeSingleFrame))
            release.signal()
            do {
                let loaded = try await read.value
                await loaded.lease.finishPhysicalWork()
                XCTAssertFalse(affected)
            } catch { XCTAssertTrue(affected) }
            let released = await budget.snapshot(); XCTAssertEqual(released.images, 0)
        }
    }

    func testContentDetailClassificationRequiresIdenticalRepresentationInputs() throws {
        let photo = PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a.jpg", size: try PixelSize(width: 4000, height: 3000))
        let before = PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(timeIntervalSince1970: 1), playbackStyle: .image, resources: [photo])
        let metadata = PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(timeIntervalSince1970: 2), playbackStyle: .image, resources: [photo])
        XCTAssertTrue(metadata.inputsUnchanged(from: before, assetContentChanged: false))
        XCTAssertFalse(metadata.inputsUnchanged(from: before, assetContentChanged: true))
        for changed in [
            PhotoKitRepresentationAsset(identifier: "a", modificationDate: before.modificationDate, playbackStyle: .imageAnimated, resources: [photo]),
            PhotoKitRepresentationAsset(identifier: "a", modificationDate: before.modificationDate, playbackStyle: .image, resources: [photo,
                .init(type: .adjustmentData, uti: "public.data", filename: "edit", size: nil)])
        ] { XCTAssertFalse(changed.inputsUnchanged(from: before, assetContentChanged: false)) }
    }

    func testGatewayReadTicketSurvivesUnrelatedChangeButRejectsAffectedAsset() async throws {
        for affected in [false, true] {
            let lifecycle = RepresentationLifecycle()
            let facts = PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image,
                resources: [.init(type: .photo, uti: "public.jpeg", filename: "a.jpg", size: nil)])
            lifecycle.assets = [facts]
            let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
            let reader = PhotosRepresentationReader(requester: requester, budget: budget, limits: try limits(), targetSide: 32)
            let gateway = PhotoKitGateway(lifecycle: lifecycle, representationReader: reader, catalogBatchSize: 128)
            _ = try await gateway.candidateSnapshot()
            let checkpoint = try await gateway.contextCheckpoint()
            let d = facts.descriptor(kind: .original, context: try XCTUnwrap(checkpoint).context)
            let read = Task { try await gateway.readRepresentation(d) }
            await requester.started()
            lifecycle.nextIndexChange = affected
                ? .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [.init(identifier: "a", candidates: [])])
                : .incremental(removedAssetIDs: [], insertedAssets: [.init(identifier: "b", candidates: [])], changedAssets: [])
            gateway.recordLibraryChangeForTesting()
            _ = try await gateway.candidateSnapshot()
            requester.send(.image(try bitmap(), orientation: .up, eligibility: .safeSingleFrame))
            do {
                let loaded = try await read.value
                await loaded.lease.finishPhysicalWork()
                XCTAssertFalse(affected)
            } catch {
                XCTAssertTrue(affected); XCTAssertEqual(error as? PhotoKitGatewayError, .libraryChanged)
            }
            let released = await budget.snapshot(); XCTAssertEqual(released.images, 0)
        }
    }

    func testUnconsumedReplayEventsStillInvalidateMatchingCatalogRevision() async throws {
        let lifecycle = RepresentationLifecycle()
        let facts = PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(timeIntervalSince1970: 1), playbackStyle: .image,
            resources: [PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a", size: nil)])
        lifecycle.assets = [facts]
        lifecycle.replayChanges = [fixtureIndexChange(changed: ["a"])]
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
        let context = LibraryContext(id: UUID(), epoch: 0)
        let old = facts.descriptor(kind: .original, context: context)
        let resumed = try await gateway.resumeContext(LibraryResumeCheckpoint(context: context, archivedChangeToken: Data([1])))
        XCTAssertTrue(resumed)
        let snapshot = try await gateway.candidateSnapshot()
        let page = try await gateway.representationCatalog(offset: 0, limit: 128, expectedGeneration: snapshot.generation)
        XCTAssertEqual(page.descriptors[0].revision, old.revision)
        XCTAssertTrue(page.descriptors[0].revisionIsReliable)
        XCTAssertEqual(page.invalidatedAssetIDs, ["a"], "catalog safety cannot depend on draining AsyncStream")
        XCTAssertFalse(page.invalidateAllCachedRepresentations)
        try await gateway.acknowledgeReconciliation(expectedGeneration: snapshot.generation)
        let acknowledged = try await gateway.representationCatalog(offset: 0, limit: 128, expectedGeneration: snapshot.generation)
        XCTAssertEqual(acknowledged.invalidatedAssetIDs, [])
    }

    func testBoundedInvalidationOverflowIsStickyInPagesUntilCurrentAcknowledgement() async throws {
        let lifecycle = RepresentationLifecycle()
        lifecycle.assets = [PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image,
            resources: [PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a", size: nil)])]
        lifecycle.replayChanges = [fixtureIndexChange(changed: ["a", "b"]), fixtureIndexChange(changed: ["a"])]
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 1)
        let context = LibraryContext(id: UUID(), epoch: 0)
        let before = try await gateway.candidateSnapshot()
        _ = try await gateway.resumeContext(LibraryResumeCheckpoint(context: context, archivedChangeToken: Data([1])))
        let snapshot = try await gateway.candidateSnapshot()
        do { try await gateway.acknowledgeReconciliation(expectedGeneration: before.generation); XCTFail("stale acknowledgement") } catch {}
        let page = try await gateway.representationCatalog(offset: 0, limit: 1, expectedGeneration: snapshot.generation)
        XCTAssertTrue(page.invalidateAllCachedRepresentations)
        try await gateway.acknowledgeReconciliation(expectedGeneration: snapshot.generation)
        let clean = try await gateway.representationCatalog(offset: 0, limit: 1, expectedGeneration: snapshot.generation)
        XCTAssertFalse(clean.invalidateAllCachedRepresentations)
    }

    func testLargeConfirmedInsertDeleteHistoryDoesNotInvalidateSurvivingImages() async throws {
        let lifecycle = RepresentationLifecycle()
        lifecycle.assets = [PhotoKitRepresentationAsset(identifier: "survivor", modificationDate: Date(), playbackStyle: .image,
            resources: [PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a", size: nil)])]
        lifecycle.replayChanges = [fixtureIndexChange(changed: ["inserted1", "inserted2", "inserted3"]), fixtureIndexChange(deleted: ["deleted1", "deleted2"])]
        lifecycle.replayContentChanges = []
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 1)
        _ = try await gateway.resumeContext(LibraryResumeCheckpoint(context: LibraryContext(id: UUID(), epoch: 0), archivedChangeToken: Data([1])))
        let snapshot = try await gateway.candidateSnapshot()
        let page = try await gateway.representationCatalog(offset: 0, limit: 1, expectedGeneration: snapshot.generation)
        XCTAssertFalse(page.invalidateAllCachedRepresentations)
        XCTAssertEqual(page.invalidatedAssetIDs, [])
    }

    func testPendingChangeDetailsCannotPermitReuseOrAcknowledgement() async throws {
        let lifecycle = RepresentationLifecycle()
        lifecycle.assets = [PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image,
            resources: [PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a", size: nil)])]
        let entered = expectation(description: "observer details pending")
        let release = DispatchSemaphore(value: 0)
        lifecycle.onChangeDetails = { entered.fulfill(); release.wait() }
        lifecycle.nextIndexChange = .incremental(removedAssetIDs: [], insertedAssets: [], changedAssets: [])
        let gateway = PhotoKitGateway(lifecycle: lifecycle, catalogBatchSize: 128)
        let before = try await gateway.candidateSnapshot()
        gateway.recordLibraryChangeForTesting()
        await fulfillment(of: [entered], timeout: 2)
        do { _ = try await gateway.representationCatalog(offset: 0, limit: 128, expectedGeneration: before.generation + 1)
            XCTFail("unclassified details cannot become content evidence") } catch {}
        do { try await gateway.acknowledgeReconciliation(expectedGeneration: before.generation + 1); XCTFail("details still pending") } catch {}
        release.signal()
        let after = try await gateway.candidateSnapshot()
        let resolved = try await gateway.representationCatalog(offset: 0, limit: 128, expectedGeneration: after.generation)
        XCTAssertFalse(resolved.invalidateAllCachedRepresentations)
        try await gateway.acknowledgeReconciliation(expectedGeneration: after.generation)
    }

    func testPaddedMultipleBitmapBackingsRejectBeforeDrawing() throws {
        let image = RecordingDrawImage(size: NSSize(width: 2, height: 32))
        for width in [1, 2] {
            let representation = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32))
            let single = RecordingDrawImage(size: image.size)
            single.addRepresentation(representation)
            XCTAssertNoThrow(try PhotosBitmapNormalizer.normalize(single, targetSide: 32))
            XCTAssertEqual(single.drawCount, 1, "each 8 KiB backing fits the 12 KiB input allowance")
            image.addRepresentation(representation)
        }
        XCTAssertEqual(image.representations.count, 2)
        XCTAssertThrowsError(try PhotosBitmapNormalizer.normalize(image, targetSide: 32))
        XCTAssertEqual(image.drawCount, 0, "reject retained backing before normalized bitmap drawing")
    }

    func testPlanarBackingCountsEveryPlaneBeforeDrawing() throws {
        let image = RecordingDrawImage(size: NSSize(width: 8, height: 32))
        let representation = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: true,
            colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 8))
        XCTAssertEqual(representation.numberOfPlanes, 4)
        image.addRepresentation(representation)
        XCTAssertThrowsError(try PhotosBitmapNormalizer.normalize(image, targetSide: 32))
        XCTAssertEqual(image.drawCount, 0)
    }

    func testUnavailablePublicRasterRejectsBeforeNativeImageDrawing() throws {
        let image = RecordingDrawImage(size: NSSize(width: 8, height: 8))
        image.addRepresentation(AccountingRasterRepresentation(raster: nil, width: 8, height: 8))
        XCTAssertThrowsError(try PhotosBitmapNormalizer.normalize(image, targetSide: 32))
        XCTAssertEqual(image.drawCount, 0)
    }

    func testOrdinaryCGImageBackedNSImageRemainsSupported() throws {
        let raw = try bitmap()
        let image = NSImage(cgImage: raw, size: NSSize(width: raw.width, height: raw.height))
        let normalized = try PhotosBitmapNormalizer.normalize(image, targetSide: 32)
        XCTAssertEqual(normalized.width, 32)
        XCTAssertEqual(normalized.height, 32)
        XCTAssertLessThanOrEqual(normalized.bytesPerRow * normalized.height, 32 * 32 * 4)
    }

    func testPublicRasterDimensionsAreIndependentOfRepresentationDisplayScale() throws {
        let image = RecordingDrawImage(size: NSSize(width: 24, height: 16))
        let raw = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 96,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        // NSImage(cgImage:size:) can expose 2x display-derived rep dimensions
        // while its public accessor still returns the original 24x16 raster.
        image.addRepresentation(AccountingRasterRepresentation(raster: raw, width: 48, height: 32))
        let normalized = try PhotosBitmapNormalizer.normalize(image, targetSide: 32)
        XCTAssertEqual(normalized.width, 32)
        XCTAssertEqual(normalized.height, 21)
        XCTAssertEqual(image.drawCount, 1)
    }

    func testOversizedBitmapBackingRejectsBeforeNativeImageDrawing() throws {
        let image = RecordingDrawImage(size: NSSize(width: 24, height: 16))
        let representation = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 192, bitsPerPixel: 32))
        image.addRepresentation(representation)
        XCTAssertThrowsError(try PhotosBitmapNormalizer.normalize(image, targetSide: 32)) { error in
            XCTAssertEqual(error as? PhotosRepresentationError, .oversized(width: 48, height: 32))
        }
        XCTAssertEqual(image.drawCount, 0)
    }

    func testPublicRasterActualDimensionsOverrideSmallRepresentationHints() throws {
        let image = RecordingDrawImage(size: NSSize(width: 8, height: 8))
        image.addRepresentation(AccountingRasterRepresentation(raster: try largeBitmap(), width: 8, height: 8))
        XCTAssertThrowsError(try PhotosBitmapNormalizer.normalize(image, targetSide: 32)) { error in
            XCTAssertEqual(error as? PhotosRepresentationError, .oversized(width: 64, height: 64))
        }
        XCTAssertEqual(image.drawCount, 0)
    }

    func testPublicRasterAndBitmapBackingShareOneAggregateLimit() throws {
        let image = RecordingDrawImage(size: NSSize(width: 2, height: 32))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32))
        image.addRepresentation(bitmap)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 0, count: 256 * 32) as CFData))
        let raster = try XCTUnwrap(CGImage(width: 2, height: 32, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        image.addRepresentation(AccountingRasterRepresentation(raster: raster, width: 2, height: 32))
        for representation in image.representations {
            let single = RecordingDrawImage(size: image.size)
            single.addRepresentation(representation)
            XCTAssertNoThrow(try PhotosBitmapNormalizer.normalize(single, targetSide: 32))
            XCTAssertEqual(single.drawCount, 1, "each 8 KiB backing fits the 12 KiB input allowance")
        }
        XCTAssertThrowsError(try PhotosBitmapNormalizer.normalize(image, targetSide: 32))
        XCTAssertEqual(image.drawCount, 0)
    }

    private func limits(timeout: Double = 30) throws -> ResourceLimits {
        try ResourceLimits(decodeConcurrency: 1, photoRequestConcurrency: 1, maxDecodedBytes: 134217728,
                           requestTimeoutSeconds: timeout, retryDelaysSeconds: [5, 15, 30, 60], catalogBatchSize: 128,
                           maxInFlightTasks: 2, progressPublishIntervalSeconds: 1, inferenceConcurrency: 1, batchSize: 1)
    }
    private func descriptor() -> RepresentationDescriptor {
        RepresentationDescriptor(key: RepresentationKey(assetID: "fixture", kind: .original),
                                 context: LibraryContext(id: UUID(), epoch: 0), revision: "r1", size: try! PixelSize(width: 4, height: 4),
                                 equivalentToOriginal: true, revisionIsReliable: true)
    }
    private func bitmap() throws -> CGImage {
        try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    }

    func testBudgetHoldsBytesAndSlotUntilPhysicalFinishAndReleaseIsIdempotent() async throws {
        let budget = ImageWorkBudget(maxImages: 1, maxBytes: 64)
        let lease = try await budget.acquire(bytes: 64)
        do { _ = try await budget.acquire(bytes: 1); XCTFail("occupied lease must block replacement") }
        catch { XCTAssertEqual(error as? ImageWorkBudgetError, .exhausted) }
        let occupied = await budget.snapshot()
        XCTAssertEqual(occupied.images, 1)
        XCTAssertEqual(occupied.bytes, 64)
        await lease.finishPhysicalWork()
        await lease.finishPhysicalWork()
        let released = await budget.snapshot()
        XCTAssertEqual(released.images, 0)
        XCTAssertEqual(released.bytes, 0)
    }

    func testBudgetRejectsOversizeAndInvalidReservations() async throws {
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 64)
        for bytes: Int64 in [0, -1, 65, Int64.max] {
            do { _ = try await budget.acquire(bytes: bytes); XCTFail("invalid reservation") }
            catch { XCTAssertEqual(error as? ImageWorkBudgetError, .invalidReservation) }
        }
    }
}

private final class LockedRepresentationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var value: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

private final class ControlledRepresentationRequester: PhotosRepresentationRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (PhotosRepresentationCallback) -> Void)?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var immediateEvent: PhotosRepresentationCallback?
    func request(_ descriptor: RepresentationDescriptor, targetSide: Int,
                 completion: @escaping @Sendable (PhotosRepresentationCallback) -> Void) throws {
        lock.lock(); callback = completion; let pending = waiters; waiters = []; lock.unlock()
        for waiter in pending { waiter.resume() }
        if let immediateEvent { completion(immediateEvent) }
    }
    func started() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if callback != nil { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    func send(_ event: PhotosRepresentationCallback) {
        lock.lock(); let callback = callback; lock.unlock()
        callback?(event)
    }
}

private final class RepresentationLifecycle: PhotoKitLifecycle, @unchecked Sendable {
    var assets: [PhotoKitRepresentationAsset] = []
    var replayChanges: [PhotosIndexChange] = []
    var nextIndexChange: PhotoKitCandidateIndexChange = .reload
    var onChangeDetails: (@Sendable () -> Void)?
    var replayContentChanges: [String]?
    var replaySucceeds = true
    var onReplay: (@Sendable () -> Void)?
    func currentAccess() -> PhotoKitAccess { .authorized }
    func requestReadWriteAuthorization() async -> PhotoKitAccess { .authorized }
    func isAvailable() -> Bool { true }
    func loadCandidateAssets() throws -> [PhotoKitCandidateAsset] { assets.map { .init(identifier: $0.identifier, candidates: []) } }
    func candidateIndexChange(for change: PHChange?) throws -> PhotoKitCandidateIndexChange { onChangeDetails?(); return nextIndexChange }
    func submit(_ command: PhotoKitCreateCommand, beforeMutation: @escaping @Sendable () -> Bool,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async throws -> PhotoKitSubmissionResult { .preventedBeforeMutation }
    func fetch(identifier: String) throws -> Bool { true }
    func representationCatalog(offset: Int, limit: Int, context: LibraryContext, generation: Int) throws -> RepresentationPage {
        let descriptors = assets.flatMap { asset in [RepresentationKind.original, .current].map { asset.descriptor(kind: $0, context: context) } }
        let end = min(offset + limit, descriptors.count)
        return RepresentationPage(context: context, generation: generation, descriptors: Array(descriptors[offset..<end]), nextOffset: end < descriptors.count ? end : nil)
    }
    func archivedChangeToken() throws -> Data? { Data([2]) }
    func replayPersistentChanges(_ token: Data, onChange: (PhotosIndexChange) -> Void, onContentChange: ([String]) -> Void) throws -> Bool {
        onReplay?()
        guard replaySucceeds else { return false }
        if let replayContentChanges { onContentChange(replayContentChanges) }
        else {
            for event in replayChanges { if case .incremental(let delta) = event { onContentChange(delta.changedAssetIDs) } }
        }
        for event in replayChanges { onChange(event) }
        return true
    }
}

private final class RecordingDrawCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class RecordingDrawImage: NSImage {
    private let counter = RecordingDrawCounter()
    var drawCount: Int { counter.value }
    override func draw(in rect: NSRect, from fromRect: NSRect, operation op: NSCompositingOperation,
                       fraction delta: CGFloat, respectFlipped: Bool, hints: [NSImageRep.HintKey: Any]?) {
        counter.increment()
    }
}

private final class AccountingRasterRepresentation: NSImageRep {
    private let raster: CGImage?
    init(raster: CGImage?, width: Int, height: Int) {
        self.raster = raster
        super.init()
        pixelsWide = width; pixelsHigh = height
        size = NSSize(width: width, height: height)
    }
    required init?(coder: NSCoder) { nil }
    override func cgImage(forProposedRect proposedDestRect: UnsafeMutablePointer<NSRect>?,
                          context: NSGraphicsContext?, hints: [NSImageRep.HintKey: Any]?) -> CGImage? { raster }
}

private struct ValidationFailingRepresentationRequester: PhotosRepresentationRequesting {
    func request(_ descriptor: RepresentationDescriptor, targetSide: Int,
                 completion: @escaping @Sendable (PhotosRepresentationCallback) -> Void) throws {
        throw PhotosRepresentationError.invalidImage
    }
}
