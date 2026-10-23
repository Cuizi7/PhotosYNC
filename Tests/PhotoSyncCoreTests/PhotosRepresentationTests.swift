import XCTest
import AppKit
import Photos
import CoreGraphics
import ImageIO
import Darwin
@testable import PhotoSyncCore

final class PhotosRepresentationTests: XCTestCase {
    func testChangingImageBudgetDoesNotReleaseExistingPhysicalOwnership() async throws {
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 128)
        let old = try await budget.acquireMaximum()
        await budget.setMaximumBytes(64)
        let held = await budget.snapshot(), admission = await budget.canAcquireMaximum()
        XCTAssertEqual(held.bytes, 128); XCTAssertEqual(old.reservedBytes, 128); XCTAssertFalse(admission)
        do { _ = try await budget.acquireMaximum(); XCTFail("Old physical owner must block a new reservation") }
        catch { XCTAssertEqual(error as? ImageWorkBudgetError, .exhausted) }
        await old.finishPhysicalWork()
        let reduced = try await budget.acquireMaximum()
        XCTAssertEqual(reduced.reservedBytes, 64)
        await reduced.finishPhysicalWork()
        await budget.setMaximumBytes(256)
        let increased = try await budget.acquireMaximum()
        XCTAssertEqual(increased.reservedBytes, 256)
        await increased.finishPhysicalWork()
    }

    func testPhotoAndSourceDecodingUseTheSharedCurrentBudget() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.png"), config = try configuration()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try bitmap(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1024)
        let source = try await MetadataReader(executor: ReadExecutor()).readForFingerprint(url: file, configuration: config, budget: budget)
        XCTAssertEqual(source.lease.reservedBytes, 1024); XCTAssertEqual(source.value.eligibility, .safeSingleFrame)
        await source.lease.finishPhysicalWork()
        let requester = ControlledRepresentationRequester()
        requester.immediateEvent = .image(try bitmap(), orientation: .up, eligibility: .safeSingleFrame)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: config,
            storage: PhotosResourceStorage(root: root.appendingPathComponent("raw")))
        let result = try await reader.read(descriptor(), isCurrent: { true })
        XCTAssertEqual(result.lease.reservedBytes, 1024)
        await result.lease.finishPhysicalWork()
    }

    func testDescriptorCarriesExactModificationDateAndRejectsNonfiniteDate() throws {
        let date = Date(timeIntervalSince1970: 123.125)
        for value in [date, nil, Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
            let asset = PhotoKitRepresentationAsset(identifier: "date", modificationDate: value, playbackStyle: .image, resources: [])
            let descriptor = asset.descriptor(kind: .original, context: .init(id: UUID(), epoch: 1))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
            XCTAssertEqual(json["modificationDate"] as? Double, value?.timeIntervalSince1970.isFinite == true ? value?.timeIntervalSinceReferenceDate : nil)
        }
    }

    func testLogicalTimeoutAndAdmissionRemainResponsiveDuringSynchronousRequestStart() async throws {
        let timeout = expectation(description: "deadline handler fired")
        let returned = expectation(description: "logical timeout returned with startup held")
        let queried = expectation(description: "admission and competing read completed with startup held")
        let release = DispatchSemaphore(value: 0), requester = ControlledRepresentationRequester()
        requester.beforeReturn = { _ = release.wait(timeout: .now() + 5) }
        defer { release.signal() }
        let c = try configuration(timeout: 0.02), budget = ImageWorkBudget(limits: c.resources)
        let diagnostic = IndexDiagnostics(sink: { if $0["event"] == "timeout" { timeout.fulfill() } })
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: c, indexDiagnostics: diagnostic)
        let work = Task {
            do { _ = try await reader.read(descriptor(), isCurrent: { true }); XCTFail("expected logical timeout") }
            catch { XCTAssertEqual(error as? ReadExecutorError, .timedOut) }
            returned.fulfill()
        }
        await requester.started()
        await fulfillment(of: [timeout], timeout: 2)
        let query = Task {
            let admission = await reader.admission(), owners = await reader.physicalRequestCount
            XCTAssertEqual(admission, .draining); XCTAssertEqual(owners, 1)
            do { _ = try await reader.read(descriptor(), isCurrent: { true }); XCTFail("startup still owns physical slot") }
            catch { XCTAssertEqual(error as? ReadExecutorError, .resourceExhausted) }
            queried.fulfill()
        }
        // The gate establishes the interleaving; this bound only checks responsiveness.
        await fulfillment(of: [returned, queried], timeout: 0.3)
        let held = await budget.snapshot(); XCTAssertEqual(held.images, 1)
        release.signal(); await work.value; await query.value
        await requester.cancellationRequested(); XCTAssertEqual(requester.cancellationCount, 1)
        requester.send(.cancelled); requester.send(.cancelled)
        await waitForDrain(reader, budget: budget)
    }

    func testLogicalCancellationReturnsWhileSynchronousStartHasNoCancellationHandle() async throws {
        let returned = expectation(description: "cancelled caller returned before startup")
        let queried = expectation(description: "cancelled startup admission remains responsive")
        let release = DispatchSemaphore(value: 0), requester = ControlledRepresentationRequester()
        requester.beforeReturn = { _ = release.wait(timeout: .now() + 5) }
        defer { release.signal() }
        let c = try configuration(), budget = ImageWorkBudget(limits: c.resources)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: c)
        let work = Task {
            do { _ = try await reader.read(descriptor(), isCurrent: { true }); XCTFail("expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            returned.fulfill()
        }
        await requester.started(); work.cancel()
        let query = Task {
            let admission = await reader.admission(); XCTAssertEqual(admission, .draining)
            queried.fulfill()
        }
        await fulfillment(of: [returned, queried], timeout: 0.3)
        XCTAssertEqual(requester.cancellationCount, 0, "the framework handle has not returned")
        let held = await budget.snapshot(); XCTAssertEqual(held.images, 1)
        release.signal(); await work.value; await query.value
        await requester.cancellationRequested(); XCTAssertEqual(requester.cancellationCount, 1)
        requester.send(.cancelled); await waitForDrain(reader, budget: budget)
    }

    func testSynchronousTerminalCannotReleaseOwnerBeforeRequestStartReturns() async throws {
        let terminal = expectation(description: "terminal delivered synchronously inside request")
        let returned = expectation(description: "logical cancellation returned while startup still held")
        let queried = expectation(description: "owner remains held after synchronous terminal")
        let release = DispatchSemaphore(value: 0), requester = ControlledRepresentationRequester()
        requester.immediateEvent = .cancelled
        requester.beforeReturn = { _ = release.wait(timeout: .now() + 5) }
        defer { release.signal() }
        let c = try configuration(), budget = ImageWorkBudget(limits: c.resources)
        let diagnostic = IndexDiagnostics(sink: { if $0["event"] == "terminal" { terminal.fulfill() } })
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: c, indexDiagnostics: diagnostic)
        let work = Task {
            do { _ = try await reader.read(descriptor(), isCurrent: { true }); XCTFail("expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            returned.fulfill()
        }
        await fulfillment(of: [terminal], timeout: 2)
        work.cancel()
        await fulfillment(of: [returned], timeout: 0.3)
        let query = Task {
            let owners = await reader.physicalRequestCount
            XCTAssertEqual(owners, 1, "synchronous terminal does not end a still-blocked startup")
            queried.fulfill()
        }
        await fulfillment(of: [queried], timeout: 0.3)
        let held = await budget.snapshot(); XCTAssertEqual(held.images, 1)
        release.signal(); await work.value; await query.value
        await waitForDrain(reader, budget: budget)
        XCTAssertEqual(requester.cancellationCount, 0, "a terminal stream needs no late cancellation")
    }

    func testAdmissionRetainsDrainingOwnerThenStallsAndLateDuplicateTerminalReleasesOnce() async throws {
        let releasedSignal = expectation(description: "physical lease released exactly once")
        let diagnostic = IndexDiagnostics(sink: { if $0["event"] == "lease-released" { releasedSignal.fulfill() } })
        let clock = RepresentationClock(), requester = ControlledRepresentationRequester()
        let c = try configuration(timeout: 0.01), budget = ImageWorkBudget(limits: c.resources)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: c, monotonic: { clock.now }, indexDiagnostics: diagnostic)
        let work = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started()
        let busy = await reader.admission(); XCTAssertEqual(busy, .busy)
        do { _ = try await work.value; XCTFail("logical timeout") } catch { XCTAssertEqual(error as? ReadExecutorError, .timedOut) }
        let draining = await reader.admission(); XCTAssertEqual(draining, .draining)
        clock.now = 59
        for _ in 0..<100 { let state = await reader.admission(); XCTAssertEqual(state, .draining) }
        clock.now = 60
        let stalled = await reader.admission(); XCTAssertEqual(stalled, .stalled)
        let occupied = await budget.snapshot(); XCTAssertEqual(occupied.images, 1)
        requester.send(.cancelled); requester.send(.cancelled)
        await fulfillment(of: [releasedSignal], timeout: 2)
        let available = await reader.admission(); XCTAssertEqual(available, .available)
        let released = await budget.snapshot(); XCTAssertEqual(released.images, 0)
    }

    func testAdmissionBlocksAfterTerminalUntilSuccessfulConsumerLeaseFinishes() async throws {
        let requester = ControlledRepresentationRequester(), c = try configuration()
        let budget = ImageWorkBudget(limits: c.resources)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: c)
        let work = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started(); requester.send(.image(try bitmap(), orientation: .up, eligibility: .safeSingleFrame))
        let loaded = try await work.value
        let active = await reader.physicalRequestCount; XCTAssertEqual(active, 0)
        let held = await reader.admission(); XCTAssertEqual(held, .busy)
        await loaded.lease.finishPhysicalWork()
        let available = await reader.admission(); XCTAssertEqual(available, .available)
    }

    func testLateRequestAndConsumerLeaseKeepOriginalIssuanceAfterReplacement() async throws {
        for heldLease in [false, true] {
            for changedDescriptor in [false, true] {
                let released = expectation(description: "old lease physically released")
                let rows = RepresentationDiagnosticRows(), diagnostic = IndexDiagnostics(sink: {
                    rows.append($0)
                    if $0["event"] == "lease-released" { released.fulfill() }
                })
                let requester = ControlledRepresentationRequester(), c = try configuration(timeout: heldLease ? 30 : 0.01)
                let budget = ImageWorkBudget(limits: c.resources), original = descriptor()
                func issuance(_ descriptor: RepresentationDescriptor, generation: Int64) -> RepresentationTask {
                    .init(descriptor: descriptor, retryCount: 0, nextRetryAt: nil,
                        fingerprintVersion: c.fingerprint.version, indexGeneration: generation)
                }
                diagnostic.operation("work").record(["phase": "index-task", "event": "attempt"], task: issuance(original, generation: 1))
                let oldHandle = try XCTUnwrap(rows.values.last?["issuanceHandle"])
                let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: c, indexDiagnostics: diagnostic)
                let work = Task { try await reader.read(original, isCurrent: { true }) }
                await requester.started()
                var loaded: LoadedRepresentation?
                if heldLease {
                    requester.send(.image(try bitmap(), orientation: .up, eligibility: .safeSingleFrame))
                    loaded = try await work.value
                } else {
                    await requester.cancellationRequested()
                    do { _ = try await work.value; XCTFail("timeout") } catch { XCTAssertEqual(error as? ReadExecutorError, .timedOut) }
                }
                let replacement = RepresentationDescriptor(key: original.key, context: original.context,
                    revision: changedDescriptor ? "replacement" : original.revision, size: original.size,
                    equivalentToOriginal: original.equivalentToOriginal, revisionIsReliable: original.revisionIsReliable)
                diagnostic.operation("work").record(["phase": "index-task", "event": "attempt"], task: issuance(replacement, generation: 2))
                let newHandle = try XCTUnwrap(rows.values.last?["issuanceHandle"])
                XCTAssertNotEqual(oldHandle, newHandle)
                if heldLease { await loaded!.lease.finishPhysicalWork(); loaded = nil }
                else { requester.send(.cancelled) }
                await fulfillment(of: [released], timeout: 2)
                let events = rows.values.filter { $0["phase"] == "photos-reader" }
                XCTAssertTrue(events.contains { $0["event"] == "lease-released" })
                XCTAssertTrue(events.allSatisfy { $0["issuanceHandle"] == oldHandle }, "old callbacks cannot consult replacement identity")
                XCTAssertEqual(Set(events.compactMap { $0["descriptorHandle"] }).count, 1)
                let physical = await budget.snapshot(); XCTAssertEqual(physical.images, 0)
            }
        }
    }

    func testAnonymousReaderLifecycleJoinsTaskIssuanceAndReleasesOnlyOnce() async throws {
        let rows = RepresentationDiagnosticRows(), diagnostic = IndexDiagnostics(sink: { rows.append($0) })
        let requester = ControlledRepresentationRequester(), c = try configuration()
        let budget = ImageWorkBudget(limits: c.resources)
        let descriptor = RepresentationDescriptor(key: .init(assetID: "PRIVATE-ID-SENTINEL", kind: .original),
            context: .init(id: UUID(), epoch: 1), revision: "PRIVATE-EXIF-PATH-SENTINEL", size: nil, equivalentToOriginal: false, revisionIsReliable: true)
        let task = RepresentationTask(descriptor: descriptor, retryCount: 0, nextRetryAt: nil,
            fingerprintVersion: c.fingerprint.version, indexGeneration: 1, issuanceRevision: "PRIVATE-ISSUANCE-SENTINEL")
        diagnostic.operation("work").record(["phase": "index-task", "event": "attempt"], task: task)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: c, indexDiagnostics: diagnostic)
        let read = Task { try await reader.read(descriptor, isCurrent: { true }) }
        await requester.started()
        requester.send(.failure(NSError(domain: NSCocoaErrorDomain, code: -1)))
        do { _ = try await read.value; XCTFail("terminal failure expected") } catch {}
        requester.send(.failure(NSError(domain: NSCocoaErrorDomain, code: -1)))
        diagnostic.flushObservations()
        let events = rows.values.filter { $0["phase"] == "photos-reader" }
        XCTAssertEqual(events.compactMap { $0["event"] }, ["admission", "request", "terminal", "drain", "lease-released"])
        XCTAssertEqual(Set(events.compactMap { $0["issuanceHandle"] }), Set(rows.values.filter { $0["phase"] == "index-task" }.compactMap { $0["issuanceHandle"] }))
        let physical = await budget.snapshot(); XCTAssertEqual(physical.images, 0)
        let output = String(decoding: try JSONSerialization.data(withJSONObject: rows.values), as: UTF8.self)
        XCTAssertFalse(output.contains("PRIVATE-"))
    }

    func testEncodedStreamUsesIdenticalSourceTensorAndUnappliedOrientation() async throws {
        let configuration = try p8Configuration()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for type in ["public.jpeg", "public.png"] {
            let url = root.appendingPathComponent(type == "public.jpeg" ? "fixture.jpg" : "fixture.png")
            let context = try XCTUnwrap(CGContext(data: nil, width: 41, height: 23, bitsPerComponent: 8, bytesPerRow: 164,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 21, height: 23))
            context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 21, y: 0, width: 20, height: 23))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyOrientation: 6] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let sourceBudget = ImageWorkBudget(limits: configuration.resources)
            let source = try await MetadataReader().readForFingerprint(url: url, configuration: configuration, budget: sourceBudget)
            if type == "public.jpeg" { XCTAssertEqual(source.value.orientation, .right) }
            let requester = ControlledRepresentationRequester()
            let budget = ImageWorkBudget(limits: configuration.resources)
            let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: configuration)
            let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
            await requester.started()
            let data = try Data(contentsOf: url)
            requester.send(.chunk(data.prefix(data.count / 2)))
            requester.send(.chunk(data.suffix(data.count - data.count / 2)))
            requester.send(.complete(eligibility: .safeSingleFrame))
            let photos = try await task.value
            XCTAssertEqual(photos.orientation, source.value.orientation)
            XCTAssertEqual(photos.returnedSize, try PixelSize(width: 41, height: 23))
            XCTAssertEqual(photos.eligibility, source.value.eligibility)
            let a = try ImagePreprocessor.prepare(image: source.value.image, orientation: source.value.orientation, configuration: configuration.fingerprint)
            let b = try ImagePreprocessor.prepare(image: photos.image, orientation: photos.orientation, configuration: configuration.fingerprint)
            XCTAssertEqual(Data(bytes: a.dataPointer, count: a.count * 4), Data(bytes: b.dataPointer, count: b.count * 4))
            await source.lease.finishPhysicalWork(); await photos.lease.finishPhysicalWork()
        }
    }

    func testTerminalCocoaCallbackPreservesErrorAndReleasesPhysicalLease() async throws {
        let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
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
            let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
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
        for cloudError in [NSError(domain: NSCocoaErrorDomain, code: -1), NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)] {
            let inCloud = SystemPhotosRepresentationRequester.classifyUnavailable(error: cloudError, inCloud: true)
            guard case .iCloudUnavailable = inCloud as? PhotosRepresentationError else { return XCTFail("cloud wait must remain waiting") }
        }
    }

    func testNestedProtectedCallbacksKeepControlMeaningAndTopLevelDiagnostics() async throws {
        let cases: [(NSError, String)] = [
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                userInfo: [NSLocalizedDescriptionKey: "synthetic network cause"]), "network"),
            (NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.accessUserDenied.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "synthetic authorization cause"]), "blocking"),
            (NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.libraryVolumeOffline.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "synthetic library cause"]), "blocking"),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), "cancelled")]
        for (cause, meaning) in cases {
            for depth in [1, 3] {
                var outer = cause
                for _ in 0..<depth {
                    outer = NSError(domain: NSCocoaErrorDomain, code: -1,
                        userInfo: [NSUnderlyingErrorKey: outer, NSLocalizedDescriptionKey: "synthetic outer callback detail"])
                }
                let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
                let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
                let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
                await requester.started(); requester.send(.failure(outer))
                do { _ = try await task.value; XCTFail("nested terminal failure") }
                catch {
                    XCTAssertFalse((error as? PhotosRepresentationError)?.isIsolatableReadFailure == true, meaning)
                    if meaning == "cancelled" { XCTAssertTrue(error is CancellationError) }
                    else if meaning == "network" {
                        guard case .iCloudUnavailable(let detail) = error as? PhotosRepresentationError else { return XCTFail("network must remain waiting") }
                        XCTAssertTrue(detail.contains("synthetic outer callback detail")); XCTAssertTrue(detail.contains("synthetic network cause"))
                        XCTAssertTrue(detail.contains(NSCocoaErrorDomain)); XCTAssertTrue(detail.contains(NSURLErrorDomain))
                    } else {
                        let preserved = error as NSError
                        XCTAssertEqual(preserved.domain, NSCocoaErrorDomain); XCTAssertEqual(preserved.code, -1)
                        XCTAssertTrue(String(describing: preserved).contains("synthetic outer callback detail"))
                        XCTAssertNotNil(preserved.userInfo[NSUnderlyingErrorKey])
                    }
                }
                let released = await budget.snapshot(); XCTAssertEqual(released.images, 0)
            }
        }
    }

    func testUnknownFiniteCauseRemainsSoftButCyclesAndUnverifiedDeepChainsDoNot() throws {
        let unknown = NSError(domain: "Synthetic.UnknownImageError", code: 123)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: -1, userInfo: [NSUnderlyingErrorKey: unknown])
        let allowed = SystemPhotosRepresentationRequester.classifyUnavailable(error: wrapped, inCloud: false)
        XCTAssertTrue((allowed as? PhotosRepresentationError)?.isIsolatableReadFailure == true)
        let cyclic = CyclicRepresentationCallbackError(domain: NSCocoaErrorDomain, code: -1)
        let guarded = SystemPhotosRepresentationRequester.classifyUnavailable(error: cyclic, inCloud: false)
        XCTAssertFalse((guarded as? PhotosRepresentationError)?.isIsolatableReadFailure == true)
        let malformed = NSError(domain: NSCocoaErrorDomain, code: -1, userInfo: [NSUnderlyingErrorKey: "unverified cause"])
        let rejected = SystemPhotosRepresentationRequester.classifyUnavailable(error: malformed, inCloud: false)
        XCTAssertFalse((rejected as? PhotosRepresentationError)?.isIsolatableReadFailure == true)
        var deep = unknown
        for _ in 0..<128 { deep = NSError(domain: NSCocoaErrorDomain, code: -1, userInfo: [NSUnderlyingErrorKey: deep]) }
        let unverified = SystemPhotosRepresentationRequester.classifyUnavailable(error: deep, inCloud: false)
        XCTAssertFalse((unverified as? PhotosRepresentationError)?.isIsolatableReadFailure == true)
    }

    func testPreRequestInvalidImageErrorHasNoCallbackAuthorization() async throws {
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: ValidationFailingRepresentationRequester(), budget: budget,
            configuration: try configuration())
        do { _ = try await reader.read(descriptor(), isCurrent: { true }); XCTFail("pre-request validation") }
        catch { XCTAssertFalse((error as? PhotosRepresentationError)?.isIsolatableReadFailure == true) }
        let released = await budget.snapshot(); XCTAssertEqual(released.images, 0)
    }

    func testChunksThenTerminalPublishesOnce() async throws {
        let requester = ControlledRepresentationRequester()
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started()
        requester.send(.chunk(Data()))
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
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
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
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
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

    func testPublicHistoryFailureRetainsThePersistentObjectNamespace() async throws {
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
        XCTAssertEqual(fresh?.context, oldContext)
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

    func testErrorAndCancellationFinishWithoutPublishing() async throws {
        for event in [TestRepresentationCallback.failure(PhotosRepresentationError.invalidImage), .cancelled] {
            let requester = ControlledRepresentationRequester()
            let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
            let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
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

    func testTimeoutAfterChunksKeepsPhysicalRequestUntilLateTerminal() async throws {
        let releasedSignal = expectation(description: "physical lease released")
        let diagnostic = IndexDiagnostics(sink: { if $0["event"] == "lease-released" { releasedSignal.fulfill() } })
        let requester = ControlledRepresentationRequester()
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration(timeout: 0.01), indexDiagnostics: diagnostic)
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started()
        requester.send(.chunk(Data()))
        do { _ = try await task.value; XCTFail("chunks without terminal completion are not ready") }
        catch { XCTAssertEqual(error as? ReadExecutorError, .timedOut) }
        let occupied = await reader.physicalRequestCount
        XCTAssertEqual(occupied, 1)
        requester.send(.cancelled)
        await fulfillment(of: [releasedSignal], timeout: 2)
        let released = await budget.snapshot()
        XCTAssertEqual(released.images, 0)
    }

    func testGatewayChangeRejectsLateImageThroughSameGenerationGate() async throws {
        let requester = ControlledRepresentationRequester()
        let lifecycle = RepresentationLifecycle()
        lifecycle.assets = [PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image,
            resources: [PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a", size: nil)])]
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
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
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
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
            let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
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
            let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
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

    func testUnconsumedHistoryIDsDoNotOverrideReliableCatalogMetadata() async throws {
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
        XCTAssertEqual(page.invalidatedAssetIDs, [], "history IDs require catalog verification, not unconditional input invalidation")
        XCTAssertFalse(page.invalidateAllCachedRepresentations)
        try await gateway.acknowledgeReconciliation(expectedGeneration: snapshot.generation)
        let acknowledged = try await gateway.representationCatalog(offset: 0, limit: 128, expectedGeneration: snapshot.generation)
        XCTAssertEqual(acknowledged.invalidatedAssetIDs, [])
    }

    func testUnknownReplayScopeIsStickyInPagesUntilCurrentAcknowledgement() async throws {
        let lifecycle = RepresentationLifecycle()
        lifecycle.assets = [PhotoKitRepresentationAsset(identifier: "a", modificationDate: Date(), playbackStyle: .image,
            resources: [PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "a", size: nil)])]
        lifecycle.replayChanges = [.fullReconcileRequired, fixtureIndexChange(changed: ["a", "b"]), fixtureIndexChange(changed: ["a"]) ]
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

    private func configuration(timeout: Double = 30, allowance: Int64 = 1_000_000) throws -> DedupConfiguration {
        let c = try p8Configuration()
        let f = try FingerprintConfiguration(modelSHA256: c.fingerprint.modelSHA256, inputSide: 32,
            resizeMode: c.fingerprint.resizeMode, colorSpace: c.fingerprint.colorSpace, mean: c.fingerprint.mean, std: c.fingerprint.std)
        return try DedupConfiguration(fingerprint: f,
            policyVersion: DedupConfiguration.computePolicyVersion(fingerprintVersion: f.version, threshold: c.threshold, backend: c.backend), threshold: c.threshold,
            backend: c.backend, resources: ResourceLimits(decodeConcurrency: 1, photoRequestConcurrency: 1, maxDecodedBytes: allowance,
                requestTimeoutSeconds: timeout, retryDelaysSeconds: [5, 15, 30, 60], catalogBatchSize: 128,
                maxInFlightTasks: 2, progressPublishIntervalSeconds: 1, inferenceConcurrency: 1, batchSize: 1),
            evidenceCandidateLimit: c.evidenceCandidateLimit, acceptanceID: c.acceptanceID)
    }

    func testEncodedCapAndLateChunkRetainPartialUntilTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration(),
            resourceLimits: PhotosResourceLimits(maxEncodedBytes: 4, freeSpaceReserveBytes: 0), storage: PhotosResourceStorage(root: root))
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started()
        requester.send(.chunk(Data([1, 2, 3])))
        requester.send(.chunk(Data([4, 5])))
        do { _ = try await task.value; XCTFail("encoded cap") }
        catch { XCTAssertEqual(error as? PhotosRepresentationError, .encodedResourceLimit) }
        requester.send(.chunk(Data([9])))
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(entries.first).appendingPathComponent("encoded")
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
        let held = await budget.snapshot(), occupied = await reader.physicalRequestCount
        XCTAssertEqual(held.images, 1); XCTAssertEqual(occupied, 1)
        requester.send(.cancelled); requester.send(.cancelled)
        await waitForDrain(reader, budget: budget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSpaceShortageWaitsAndDoesNotGenerateImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = PhotosRepresentationReader(requester: ValidationFailingRepresentationRequester(),
            budget: ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000), configuration: try configuration(),
            resourceLimits: PhotosResourceLimits(maxEncodedBytes: 4, freeSpaceReserveBytes: 128),
            storage: PhotosResourceStorage(root: root, availableBytes: { 127 }))
        do { _ = try await reader.read(descriptor(), isCurrent: { true }); XCTFail("insufficient space") }
        catch { guard case .resourceStorageUnavailable = error as? PhotosRepresentationError else { return XCTFail("storage wait: \(error)") } }
    }

    func testCleanupPreservesReplacedEncodedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PhotosResourceStorage(root: root)
        let resource = try storage.create(limits: PhotosResourceLimits(freeSpaceReserveBytes: 0))
        try resource.append(Data([1, 2])); try resource.closeStream()
        let moved = root.appendingPathComponent("original-preserved")
        try FileManager.default.moveItem(at: resource.url, to: moved)
        try Data([9]).write(to: resource.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resource.url.path)
        resource.remove()
        XCTAssertEqual(try Data(contentsOf: resource.url), Data([9]), "cleanup must not remove a substituted file")
        let next = try storage.create(limits: PhotosResourceLimits(freeSpaceReserveBytes: 0))
        next.remove()
        XCTAssertEqual(try Data(contentsOf: resource.url), Data([9]), "startup cleanup must also prove encoded file ownership")
    }

    func testDecodeAndCancellationKeepPhysicalOwnerThroughActualDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "real decoder entered"), release = DispatchSemaphore(value: 0)
        let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration(),
            storage: PhotosResourceStorage(root: root), decode: { url, configuration, allowance in
                entered.fulfill(); release.wait()
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                return try EncodedImageDecoder.decode(url: url, configuration: configuration, decodedAllowance: allowance)
            })
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started(); requester.send(.image(try bitmap(), orientation: .right, eligibility: .safeSingleFrame))
        await fulfillment(of: [entered], timeout: 2)
        let occupied = await reader.physicalRequestCount
        XCTAssertEqual(occupied, 1, "terminal callback alone cannot release decode slot")
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled during decoder") } catch { XCTAssertTrue(error is CancellationError) }
        let held = await budget.snapshot(); XCTAssertEqual(held.bytes, 1_000_000)
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(entries.first).appendingPathComponent("encoded")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        release.signal(); await waitForDrain(reader, budget: budget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancellationBeforeRequestReturnsIsSentOnceAndDoesNotInventTerminal() async throws {
        let requester = ControlledRepresentationRequester(), release = DispatchSemaphore(value: 0)
        requester.beforeReturn = { release.wait() }
        let budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started(); task.cancel(); release.signal()
        do { _ = try await task.value; XCTFail("cancelled before cancellation ID") } catch { XCTAssertTrue(error is CancellationError) }
        await requester.cancellationRequested()
        XCTAssertEqual(requester.cancellationCount, 1)
        let occupied = await reader.physicalRequestCount, held = await budget.snapshot()
        XCTAssertEqual(occupied, 1); XCTAssertEqual(held.images, 1)
        requester.send(.chunk(Data([7]))); requester.send(.cancelled); requester.send(.cancelled)
        await waitForDrain(reader, budget: budget)
        await requester.cancellationRequested()
        XCTAssertEqual(requester.cancellationCount, 1)
    }

    func testSuccessfulLeaseProtectsPrivateLazyBackingAndCleansIdempotently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let requester = ControlledRepresentationRequester(), c = try configuration()
        let budget = ImageWorkBudget(limits: c.resources)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: c, storage: PhotosResourceStorage(root: root))
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started(); requester.send(.image(try bitmap(), orientation: .right, eligibility: .safeSingleFrame))
        let loaded = try await task.value
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let file = directory.appendingPathComponent("encoded")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // Real common preprocessing may trigger lazy ImageIO file consumption.
        _ = try ImagePreprocessor.prepare(image: loaded.image, orientation: loaded.orientation, configuration: c.fingerprint)
        let other = try PhotosResourceStorage(root: root).create(limits: PhotosResourceLimits())
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "startup cleanup must skip an active owner")
        other.remove()
        await loaded.lease.finishPhysicalWork(); await loaded.lease.finishPhysicalWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let released = await budget.snapshot(); XCTAssertEqual(released.images, 0)
    }

    func testPrivateStorageRejectsSymlinkAndPreservesUnknownDirectories() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
        XCTAssertThrowsError(try PhotosResourceStorage(root: link).create(limits: PhotosResourceLimits()))
        let root = base.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let unknown = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = unknown.appendingPathComponent("personal-file")
        try Data([3]).write(to: file)
        let active = try PhotosResourceStorage(root: root).create(limits: PhotosResourceLimits())
        active.remove()
        XCTAssertEqual(try Data(contentsOf: file), Data([3]))
    }

    func testOnlyInactiveKnownOwnedRemnantIsCleaned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        for filename in ["encoded", "encoded.mov"] {
            let old = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let encoded = old.appendingPathComponent(filename), owner = old.appendingPathComponent("owner")
            try Data([1]).write(to: encoded)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: encoded.path)
            let fd = open(encoded.path, O_RDONLY)
            XCTAssertGreaterThanOrEqual(fd, 0)
            let marker = try PhotosResourceStorage.ownerMarker(encodedFD: fd); close(fd)
            try marker.write(to: owner)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owner.path)
            let next = try PhotosResourceStorage(root: root).create(limits: PhotosResourceLimits())
            next.remove()
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        }
    }

    func testDiskSpaceLossDuringChunkStaysWaitingUntilTerminalDrain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capacity = LockedRepresentationFlag()
        let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration(),
            resourceLimits: PhotosResourceLimits(maxEncodedBytes: 1000, freeSpaceReserveBytes: 100),
            storage: PhotosResourceStorage(root: root, availableBytes: { capacity.value ? 1000 : 100 }))
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started(); requester.send(.chunk(Data([1, 2]))); capacity.invalidate()
        requester.send(.chunk(Data([3])))
        do { _ = try await task.value; XCTFail("volume reserve") }
        catch {
            XCTAssertFalse((error as? PhotosRepresentationError)?.isIsolatableReadFailure == true)
            guard case .resourceStorageUnavailable = error as? PhotosRepresentationError else { return XCTFail("storage waiting: \(error)") }
        }
        await requester.cancellationRequested()
        XCTAssertEqual(requester.cancellationCount, 1)
        let held = await budget.snapshot(); XCTAssertEqual(held.images, 1)
        requester.send(.cancelled); await waitForDrain(reader, budget: budget)
    }

    func testProductEncodedAllowanceAdmitsSelfMadeImageLargerThan64MiB() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.png")
        try autoreleasepool {
            let side = 5000
            var bytes = Data(count: side * side * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let words = buffer.bindMemory(to: UInt32.self)
                var state: UInt32 = 123456789
                for i in 0..<words.count {
                    state ^= state << 13; state ^= state >> 17; state ^= state << 5
                    words[i] = state | 0xff000000
                }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
            let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let encodedBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
        XCTAssertGreaterThan(encodedBytes, 67108864)
        XCTAssertLessThan(encodedBytes, PhotosResourceLimits().maxEncodedBytes)
        let c = try p8Configuration(), requester = ControlledRepresentationRequester()
        let budget = ImageWorkBudget(limits: c.resources)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: c,
            storage: PhotosResourceStorage(root: root.appendingPathComponent("scratch")))
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started()
        let input = try FileHandle(forReadingFrom: url)
        while let chunk = try input.read(upToCount: 1048576), !chunk.isEmpty { requester.send(.chunk(chunk)) }
        try input.close(); requester.send(.complete(eligibility: .safeSingleFrame))
        let result = try await task.value
        XCTAssertEqual(result.returnedSize, try PixelSize(width: 4096, height: 4096))
        XCTAssertEqual(result.eligibility, .safeSingleFrame)
        _ = try ImagePreprocessor.prepare(image: result.image, orientation: result.orientation, configuration: c.fingerprint)
        await result.lease.finishPhysicalWork()
    }

    func testLogicalCancellationDoesNotWaitForBlockedPhysicalWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writing = expectation(description: "physical space check blocked")
        let cancelled = expectation(description: "logical cancellation returned")
        let release = DispatchSemaphore(value: 0), gate = LockedRepresentationFlag()
        let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration(),
            resourceLimits: PhotosResourceLimits(maxEncodedBytes: 1000, freeSpaceReserveBytes: 0),
            storage: PhotosResourceStorage(root: root, availableBytes: {
                if !gate.value { writing.fulfill(); release.wait() }; return 1000
            }))
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started(); gate.invalidate()
        let write = Task.detached { requester.send(.chunk(Data([1]))) }
        await fulfillment(of: [writing], timeout: 2)
        let observer = Task {
            do { _ = try await task.value; XCTFail("logical cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        DispatchQueue.global().async { task.cancel() }
        await fulfillment(of: [cancelled], timeout: 1)
        let held = await budget.snapshot(); XCTAssertEqual(held.images, 1)
        release.signal(); await write.value; await observer.value
        requester.send(.cancelled); await waitForDrain(reader, budget: budget)
    }

    func testConcurrentLeaseFinishCannotReleaseBudgetBeforeOwnedCleanupEnds() async throws {
        let entered = expectation(description: "owned cleanup entered"), release = DispatchSemaphore(value: 0)
        let secondStarted = expectation(description: "second release entered")
        let secondFinished = expectation(description: "second release must remain blocked")
        secondFinished.isInverted = true
        let budget = ImageWorkBudget(maxImages: 1, maxBytes: 64)
        let lease = try await budget.acquire(bytes: 64)
        lease.retainPhysicalResource { entered.fulfill(); release.wait() }
        let first = Task.detached { await lease.finishPhysicalWork() }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task.detached { secondStarted.fulfill(); await lease.finishPhysicalWork(); secondFinished.fulfill() }
        await fulfillment(of: [secondStarted], timeout: 2)
        await fulfillment(of: [secondFinished], timeout: 0.1)
        let held = await budget.snapshot(); XCTAssertEqual(held.images, 1)
        release.signal(); await first.value; await second.value
        let final = await budget.snapshot(); XCTAssertEqual(final.images, 0)
    }

    func testCorruptEncodedResourceIsIsolatedOnlyAfterTerminalAndDrains() async throws {
        let requester = ControlledRepresentationRequester(), budget = ImageWorkBudget(maxImages: 2, maxBytes: 1_000_000)
        let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: try configuration())
        let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
        await requester.started(); requester.send(.chunk(Data([1, 2, 3])))
        let occupied = await reader.physicalRequestCount; XCTAssertEqual(occupied, 1)
        requester.send(.complete(eligibility: .safeSingleFrame))
        do { _ = try await task.value; XCTFail("corrupt encoded image") }
        catch { XCTAssertEqual(error as? PhotosRepresentationError, .invalidImage) }
        await waitForDrain(reader, budget: budget)
    }

    func testExactResourceSelectionNeverBorrowsMissingOrAmbiguousEditedBytes() throws {
        let original = PhotoKitRepresentationResource(type: .photo, uti: "public.jpeg", filename: "same.jpg", size: try PixelSize(width: 41, height: 23))
        let edit = PhotoKitRepresentationResource(type: .fullSizePhoto, uti: "public.png", filename: "same.jpg", size: try PixelSize(width: 17, height: 13))
        let context = LibraryContext(id: UUID(), epoch: 1)
        let unedited = PhotoKitRepresentationAsset(identifier: "asset", modificationDate: Date(), playbackStyle: .image, resources: [original])
        XCTAssertEqual(unedited.selected(.current), original)
        XCTAssertTrue(unedited.descriptor(kind: .current, context: context).equivalentToOriginal)
        let edited = PhotoKitRepresentationAsset(identifier: "asset", modificationDate: Date(), playbackStyle: .image, resources: [original, edit])
        XCTAssertEqual(edited.selected(.original), original); XCTAssertEqual(edited.selected(.current), edit)
        XCTAssertFalse(edited.descriptor(kind: .current, context: context).equivalentToOriginal)
        let ambiguous = PhotoKitRepresentationAsset(identifier: "asset", modificationDate: Date(), playbackStyle: .image, resources: [original, edit, edit])
        XCTAssertNil(ambiguous.selected(.current)); XCTAssertEqual(try ambiguous.eligibility(.current), .conservative(.ambiguousResource))
        let ambiguousOriginal = PhotoKitRepresentationAsset(identifier: "asset", modificationDate: Date(), playbackStyle: .image, resources: [original, original])
        XCTAssertNil(ambiguousOriginal.selected(.original))
    }

    func testDecoderDiscoveredConservativeResourceNeverPublishesAndDrains() async throws {
        for (type, count, allowance, reason) in [("public.png", 1, Int64(256), RepresentationConservativeReason.decodedResourceLimit),
                                                 ("com.compuserve.gif", 2, Int64(1_000_000), .multiFrameOrCompound)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = root.appendingPathComponent("fixture")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(fixture as CFURL, type as CFString, count, nil))
            for _ in 0..<count { CGImageDestinationAddImage(destination, try bitmap(), nil) }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let c = try configuration(allowance: allowance)
            let source = try EncodedImageDecoder.decode(url: fixture, configuration: c, decodedAllowance: allowance)
            XCTAssertEqual(source.eligibility, .conservative(reason), "Source's eligibility is preserved")
            let scratch = root.appendingPathComponent("scratch"), requester = ControlledRepresentationRequester()
            let budget = ImageWorkBudget(limits: c.resources)
            let reader = PhotosRepresentationReader(requester: requester, budget: budget, configuration: c,
                storage: PhotosResourceStorage(root: scratch))
            let task = Task { try await reader.read(descriptor(), isCurrent: { true }) }
            await requester.started(); requester.send(.chunk(try Data(contentsOf: fixture)))
            requester.send(.complete(eligibility: .safeSingleFrame))
            do {
                let result = try await task.value
                await result.lease.finishPhysicalWork()
                XCTFail("decoder conservative result cannot become a fingerprint image")
            } catch { XCTAssertEqual(error as? PhotosRepresentationError, .unsupportedRepresentation(reason)) }
            await waitForDrain(reader, budget: budget)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        }
    }

    private func waitForDrain(_ reader: PhotosRepresentationReader, budget: ImageWorkBudget) async {
        for _ in 0..<10000 {
            if await budget.snapshot().images == 0, await reader.physicalRequestCount == 0 { return }
            await Task.yield()
        }
        XCTFail("physical work did not drain")
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

private enum TestRepresentationCallback {
    // Convenience for existing fixtures: encode real PNG bytes for the stream.
    case image(CGImage, orientation: CGImagePropertyOrientation, eligibility: RepresentationEligibility)
    case chunk(Data)
    case complete(eligibility: RepresentationEligibility)
    case failure(Error)
    case cancelled
}

private final class ControlledRepresentationRequester: PhotosRepresentationRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (PhotosRepresentationCallback) -> Void)?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var immediateEvent: TestRepresentationCallback?
    var beforeReturn: (@Sendable () -> Void)?
    private var cancellations = 0
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    func request(_ descriptor: RepresentationDescriptor,
                 completion: @escaping @Sendable (PhotosRepresentationCallback) -> Void) throws -> @Sendable () -> Void {
        lock.lock(); callback = completion; let pending = waiters; waiters = []; lock.unlock()
        for waiter in pending { waiter.resume() }
        if let immediateEvent { send(immediateEvent) }
        beforeReturn?()
        return { [self] in
            lock.lock(); cancellations += 1; let pending = cancellationWaiters; cancellationWaiters = []; lock.unlock()
            for waiter in pending { waiter.resume() }
        }
    }
    func cancellationRequested() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if cancellations > 0 { lock.unlock(); continuation.resume() }
            else { cancellationWaiters.append(continuation); lock.unlock() }
        }
    }
    func started() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if callback != nil { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    func send(_ event: TestRepresentationCallback) {
        lock.lock(); let callback = callback; lock.unlock()
        switch event {
        case .chunk(let data): callback?(.chunk(data))
        case .complete(let eligibility): callback?(.complete(eligibility: eligibility))
        case .failure(let error): callback?(.failure(error))
        case .cancelled: callback?(.cancelled)
        case .image(let image, let orientation, let eligibility):
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { callback?(.failure(PhotosRepresentationError.invalidImage)); return }
            callback?(.chunk(data as Data)); callback?(.complete(eligibility: eligibility))
        }
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

private struct ValidationFailingRepresentationRequester: PhotosRepresentationRequesting {
    func request(_ descriptor: RepresentationDescriptor,
                 completion: @escaping @Sendable (PhotosRepresentationCallback) -> Void) throws -> @Sendable () -> Void {
        throw PhotosRepresentationError.invalidImage
    }
}

private final class CyclicRepresentationCallbackError: NSError, @unchecked Sendable {
    override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
    override var description: String { "synthetic cyclic callback" }
}

private final class RepresentationDiagnosticRows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[String: String]] = []
    func append(_ row: [String: String]) { lock.lock(); rows.append(row); lock.unlock() }
    var values: [[String: String]] { lock.lock(); defer { lock.unlock() }; return rows }
}

private final class RepresentationClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: TimeInterval = 0
    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
