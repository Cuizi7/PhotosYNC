import XCTest
import AVFoundation
@testable import PhotoSyncCore

final class SourceReaderTests: XCTestCase {
    func testEntryAttributeFailurePreservesSystemCause() async throws {
        let folder = try sourceFixtureDirectory()
        let cause = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
            NSLocalizedDescriptionKey: "attribute wrapper",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                                          userInfo: [NSLocalizedDescriptionKey: "fixture permission denied"])
        ])
        let entries = try await DirectoryReader(attributes: { url, keys in
            if url.lastPathComponent == "normal.jpg" { throw cause }
            return try url.resourceValues(forKeys: keys)
        }).entries(in: folder)
        let failed = try XCTUnwrap(entries.first { $0.url.lastPathComponent == "normal.jpg" })
        XCTAssertEqual(failed.failureCause?.domain, NSCocoaErrorDomain)
        XCTAssertEqual((failed.failureCause?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code, Int(EACCES))
        XCTAssertEqual(failed.failure, "attribute wrapper")
        XCTAssertNotNil(entries.first { $0.url.lastPathComponent == "no-exif.png" }?.stamp)
    }

    func testVideoMetadataFailureReportsExactRequiredStage() async throws {
        let leaf = NSError(domain: "Fixture.Deep", code: 42, userInfo: [NSLocalizedDescriptionKey: "deep cause"])
        let os = NSError(domain: NSOSStatusErrorDomain, code: -12979,
                         userInfo: [NSLocalizedDescriptionKey: "status cause", NSUnderlyingErrorKey: leaf])
        let av = NSError(domain: AVFoundationErrorDomain, code: -11800,
                         userInfo: [NSLocalizedDescriptionKey: "asset cause", NSUnderlyingErrorKey: os])
        let cases: [(VideoMetadataStage, String)] = [
            (.duration, "读取时长"), (.creationDate, "读取创建日期"),
            (.commonMetadata, "读取公共元数据"), (.creationDateStringValue, "读取拍摄时间文本")
        ]
        for (stage, expected) in cases {
            do {
                let _: Int = try await MetadataReader.loadVideoMetadata(stage) { throw av }
                XCTFail("Required metadata load must fail")
            } catch {
                let issue = SourceIssueText.fileUnreadable(relativePath: "sample.mpg", url: URL(fileURLWithPath: "/fixture/sample.mpg"), error: error)
                XCTAssertEqual(MetadataReader.videoMetadataStage(error), expected)
                XCTAssertTrue(issue.detail.contains(expected))
                for text in ["AVFoundationErrorDomain -11800", "asset cause", "NSOSStatusErrorDomain -12979", "status cause", "Fixture.Deep 42", "deep cause"] {
                    XCTAssertTrue(issue.detail.contains(text), text)
                }
                XCTAssertEqual(issue.summary, "视频元数据读取失败，具体原因尚无法确定。")
            }
        }
        XCTAssertNil(MetadataReader.videoMetadataStage(MetadataReader.videoMetadataError(av)))
    }

    func testFileDiagnosticClassifiesKnownCauseWithoutGuessingUnknownVideo() {
        let url = URL(fileURLWithPath: "/fixture/clip.mpg")
        let cases: [(Int, String)] = [(Int(EACCES), "权限"), (Int(ENOENT), "路径不可用"), (Int(ENETDOWN), "网络共享连接已中断")]
        for (code, expected) in cases {
            let cause = NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "fixture leaf"])
            let outer = NSError(domain: "Fixture.Wrapper", code: 7, userInfo: [NSUnderlyingErrorKey: cause])
            let issue = SourceIssueText.fileUnreadable(relativePath: "clip.mpg", url: url, error: MetadataReader.videoMetadataError(outer))
            XCTAssertEqual(issue.kind, .file)
            XCTAssertTrue(issue.summary.contains(expected), issue.summary)
            XCTAssertTrue(issue.detail.contains("fixture leaf"))
        }
        let plain = SourceIssueText.fileUnreadable(relativePath: "clip.mpg", url: url, error: MetadataError.unreadable)
        XCTAssertEqual(plain.summary, "文件暂时无法读取，具体原因尚无法确定。")
        let unknown = SourceIssueText.fileUnreadable(relativePath: "clip.mpg", url: url,
            error: MetadataReader.videoMetadataError(NSError(domain: AVFoundationErrorDomain, code: -11800)))
        XCTAssertEqual(unknown.summary, "视频元数据读取失败，具体原因尚无法确定。")
    }

    func testSystemDiagnosticKeepsEveryAvailableCause() {
        var failure = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: "deepest permission"])
        for depth in 1...8 {
            failure = NSError(domain: "Fixture.Layer", code: depth,
                userInfo: [NSLocalizedDescriptionKey: "layer \(depth)", NSUnderlyingErrorKey: failure])
        }
        let diagnostic = SourceIssueText.systemDiagnostic(failure)
        XCTAssertTrue(diagnostic.contains("NSPOSIXErrorDomain 13: deepest permission"))
        for depth in 1...8 { XCTAssertTrue(diagnostic.contains("Fixture.Layer \(depth): layer \(depth)")) }
        let issue = SourceIssueText.fileUnreadable(relativePath: "photo.jpg", url: URL(fileURLWithPath: "/fixture/photo.jpg"), error: failure)
        XCTAssertTrue(issue.summary.contains("权限"))
    }

    func testDirectoryReaderExcludesHiddenLinksAndPackages() async throws {
        let directory = try sourceFixtureDirectory()

        let entries = try await DirectoryReader(sourceID: UUID()).entries(in: directory)
        let names = Set(entries.map { $0.url.lastPathComponent })

        XCTAssertEqual(names, ["corrupt.jpg", "no-exif.png", "normal.jpg", "photo.CR3", "subdirectory"])
        XCTAssertEqual(entries.first(where: { $0.url.lastPathComponent == "subdirectory" })?.isDirectory, true)
        XCTAssertNil(entries.first(where: { $0.url.lastPathComponent == "subdirectory" })?.stamp)
        XCTAssertNotNil(entries.first(where: { $0.url.lastPathComponent == "no-exif.png" })?.stamp)
    }

    func testMetadataReaderMissingExifIsNotFailureAndDoesNotMutateSource() async throws {
        let directory = try sourceFixtureDirectory()
        let url = directory.appendingPathComponent("no-exif.png")
        let before = try sourceSnapshot(url)

        let value = try await MetadataReader(sourceID: UUID()).read(url: url, filename: "no-exif.png")

        XCTAssertNil(value.captureSecond)
        XCTAssertNil(value.make)
        XCTAssertNotNil(value.width)
        let after = try sourceSnapshot(url)
        XCTAssertEqual(after.data, before.data)
        XCTAssertEqual(after.modified, before.modified)
    }

    func testMetadataReaderReadsGeneratedJPEGExifAndTiffProperties() async throws {
        let directory = try sourceFixtureDirectory()
        let metadata = try await MetadataReader(sourceID: UUID()).read(
            url: directory.appendingPathComponent("normal.jpg"),
            filename: "normal.jpg"
        )

        XCTAssertEqual(metadata.rawCaptureTime, "2026:09:13 10:15:30")
        XCTAssertEqual(metadata.rawCaptureOffset, "+08:00")
        XCTAssertEqual(metadata.make, "Fixture Make")
        XCTAssertEqual(metadata.model, "Fixture Model")
        XCTAssertNotNil(metadata.captureSecond)
    }

    func testVideoMetadataErrorKeepsNestedSystemCodes() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12979)
        let failure = NSError(domain: AVFoundationErrorDomain, code: -11800,
                              userInfo: [NSUnderlyingErrorKey: underlying])

        let wrapped = MetadataReader.videoMetadataError(failure)

        XCTAssertTrue(wrapped.localizedDescription.contains("AVFoundationErrorDomain -11800"))
        XCTAssertTrue(wrapped.localizedDescription.contains("NSOSStatusErrorDomain -12979"))
        XCTAssertEqual((wrapped.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain, AVFoundationErrorDomain)
    }

    func testUnreadableMPGRemainsAMediaReadFailure() async throws {
        let directory = try temporaryDirectory()
        let video = directory.appendingPathComponent("unreadable.mpg")
        try Data("not an MPEG program stream".utf8).write(to: video)

        do {
            _ = try await MetadataReader(sourceID: UUID()).read(url: video, filename: "unreadable.mpg")
            XCTFail("Unreadable video should not produce guessed metadata")
        } catch {
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "PhotoSync.VideoMetadata")
            XCTAssertNotNil(failure.userInfo[NSUnderlyingErrorKey])
        }
    }

    func testCorruptImageThrows() async throws {
        let directory = try sourceFixtureDirectory()
        let url = directory.appendingPathComponent("corrupt.jpg")

        await XCTAssertThrowsErrorAsync {
            _ = try await MetadataReader(sourceID: UUID()).read(url: url, filename: "corrupt.jpg")
        }
    }

    func testRawIsUnsupported() async throws {
        let directory = try sourceFixtureDirectory()

        await XCTAssertThrowsErrorAsync {
            _ = try await MetadataReader(sourceID: UUID()).read(url: directory.appendingPathComponent("photo.CR3"), filename: "photo.CR3")
        }
    }

    func testBroadRawExtensionIsUnsupported() async throws {
        let directory = try sourceFixtureDirectory()

        await XCTAssertThrowsErrorAsync {
            _ = try await MetadataReader(sourceID: UUID()).read(url: directory.appendingPathComponent("photo.CR3"), filename: "photo.CR3")
        }
        try Data("raw marker".utf8).write(to: directory.appendingPathComponent("photo.x3f"))
        await XCTAssertThrowsErrorAsync {
            _ = try await MetadataReader(sourceID: UUID()).read(url: directory.appendingPathComponent("photo.x3f"), filename: "photo.x3f")
        }
    }

    func testExplicitTimezoneConvertsFractionalTimeByFlooringUnixSecond() {
        XCTAssertEqual(
            MetadataReader.captureSecond(rawCaptureTime: "1970:01:01 00:00:00.900", offsetTimeOriginal: "+00:00"),
            0
        )
        XCTAssertEqual(
            MetadataReader.captureSecond(rawCaptureTime: "1969:12:31 23:59:59.900", offsetTimeOriginal: "+00:00"),
            -1
        )
        XCTAssertEqual(
            MetadataReader.captureSecond(rawCaptureTime: "2026:09:13 10:15:30.999999999", offsetTimeOriginal: "+08:00"),
            1_789_265_730
        )
        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2026:09:13 10:15:30", offsetTimeOriginal: nil))
    }

    func testMalformedExifOffsetsRemainUncertain() {
        let captureTime = "2026:09:13 10:15:30"

        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: captureTime, offsetTimeOriginal: "+00x00"))
        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: captureTime, offsetTimeOriginal: "+00:60"))
        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: captureTime, offsetTimeOriginal: "+２３:００"))
    }

    func testExplicitOffsetVideoTimestampUsesUnixSecond() {
        XCTAssertEqual(
            MetadataReader.videoCaptureSecond(rawCaptureTime: "2026-09-13T10:15:30+08:00"),
            1_789_265_730
        )
        XCTAssertNil(MetadataReader.videoCaptureSecond(rawCaptureTime: "2026-09-13T10:15:30"))
    }

    func testInvalidCalendarDatesStayUncertain() {
        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2024:02:30 03:04:05", offsetTimeOriginal: "+00:00"))
        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2023:02:29 03:04:05", offsetTimeOriginal: "+00:00"))
        XCTAssertNotNil(MetadataReader.captureSecond(rawCaptureTime: "2024:02:29 03:04:05", offsetTimeOriginal: "+00:00"))
        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2024:01:02 03:04", offsetTimeOriginal: "+00:00"))
        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2024:01:02 24:00:00", offsetTimeOriginal: "+00:00"))
        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2024:01:02 03:04:60", offsetTimeOriginal: "+00:00"))
        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2024:01:02 03:04:05.123junk", offsetTimeOriginal: "+00:00"))
    }

    func testVideoFractionalSecondsPreserveReliableSecond() {
        XCTAssertEqual(MetadataReader.videoCaptureSecond(rawCaptureTime: "1970-01-01T00:00:00.123Z"), 0)
        XCTAssertEqual(MetadataReader.videoCaptureSecond(rawCaptureTime: "1970-01-01T08:00:00.999+08:00"), 0)
        XCTAssertEqual(MetadataReader.videoCaptureSecond(rawCaptureTime: "1969-12-31T23:59:59.900Z"), -1)
        XCTAssertEqual(MetadataReader.videoCaptureSecond(rawCaptureTime: "2026-09-13T10:15:30.999999999+08:00"), 1_789_265_730)
        XCTAssertNil(MetadataReader.videoCaptureSecond(rawCaptureTime: "1970-01-01T00:00:00.123"))
    }

    func testVideoCaptureSecondAcceptsFractionalPrecisionAndRejectsMalformedTimestamps() {
        for timestamp in [
            "1970-01-01T00:00:00.1Z",
            "1970-01-01T00:00:00.123Z",
            "1970-01-01T00:00:00.123456Z",
            "1970-01-01T00:00:00.123456789Z",
            "2024-02-29T23:59:59Z",
        ] {
            XCTAssertNotNil(MetadataReader.videoCaptureSecond(rawCaptureTime: timestamp), timestamp)
        }

        for timestamp in [
            "2023-02-29T00:00:00Z",
            "2024-01-02T24:00:00Z",
            "2024-01-02T03:04:60Z",
            "2024-01-02T03:04:05Zjunk",
            "2024-01-02T03:04:05+00:60",
        ] {
            XCTAssertNil(MetadataReader.videoCaptureSecond(rawCaptureTime: timestamp), timestamp)
        }
    }

    func testReadExecutorKeepsTimedOutSlotOccupiedUntilBlockingWorkReturns() async throws {
        let executor = ReadExecutor(maxConcurrentOperations: 2, defaultTimeout: .milliseconds(20))
        let latch = TestLatch()
        let source = UUID()

        async let timedOut: Int = executor.execute(sourceID: source) {
                latch.wait()
                return 1
        }
        try await waitUntil { await executor.snapshot().physicalOccupancy == 1 }
        let independent = try await executor.execute(sourceID: UUID()) { 2 }
        XCTAssertEqual(independent, 2)
        do {
            _ = try await timedOut
            XCTFail("expected the blocked operation to time out")
        } catch {
        }
        let timedOutSnapshot = await executor.snapshot()
        XCTAssertEqual(timedOutSnapshot.physicalOccupancy, 1)

        await XCTAssertThrowsReadExecutorError(.sourceBusy) {
            _ = try await executor.execute(sourceID: source) { 3 }
        }

        latch.release()
        try await waitUntil { await executor.snapshot().physicalOccupancy == 0 }
        let retry = try await executor.execute(sourceID: source) { 4 }
        XCTAssertEqual(retry, 4)
    }

    func testReadExecutorHasTwoPhysicalSlotsAndDoesNotDoubleCompleteTimeoutRace() async throws {
        let executor = ReadExecutor(maxConcurrentOperations: 2, defaultTimeout: .milliseconds(20))
        let first = TestLatch()
        let second = TestLatch()
        let thirdStarted = TestLatch()

        async let firstResult: Int = executor.execute(sourceID: UUID()) { first.wait(); return 1 }
        async let secondResult: Int = executor.execute(sourceID: UUID()) { second.wait(); return 2 }
        try await waitUntil { await executor.snapshot().physicalOccupancy == 2 }
        await XCTAssertThrowsReadExecutorError(.resourceExhausted) {
            _ = try await executor.execute(sourceID: UUID()) { thirdStarted.release(); return 3 }
        }
        let blockedSnapshot = await executor.snapshot()
        XCTAssertEqual(blockedSnapshot.physicalOccupancy, 2)
        XCTAssertFalse(thirdStarted.isReleased)

        first.release()
        second.release()
        _ = try? await firstResult
        _ = try? await secondResult
        try await waitUntil { await executor.snapshot().physicalOccupancy == 0 }
        XCTAssertFalse(thirdStarted.isReleased)
    }

    func testReadExecutorKeepsOneSourceOccupiedAcrossDifferentURLsAfterTimeout() async throws {
        let executor = ReadExecutor(maxConcurrentOperations: 2, defaultTimeout: .milliseconds(20))
        let source = UUID()
        let latch = TestLatch()

        async let timedOut: Int = executor.execute(sourceID: source) { latch.wait(); return 1 }
        try await waitUntil { await executor.snapshot().physicalOccupancy == 1 }
        await XCTAssertThrowsReadExecutorError(.sourceBusy) {
            _ = try await executor.execute(sourceID: source) { 2 }
        }
        do {
            _ = try await timedOut
            XCTFail("expected timeout")
        } catch let error as ReadExecutorError {
            XCTAssertEqual(error, .timedOut)
        }

        latch.release()
        try await waitUntil { await executor.snapshot().physicalOccupancy == 0 }
    }

    func testReadExecutorCancellationBeforeAdmissionDoesNotStartWork() async throws {
        let executor = ReadExecutor()
        let started = TestLatch()
        let task = Task<Int, Error> {
            try await executor.execute(sourceID: UUID()) { started.release(); return 1 }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertFalse(started.isReleased)
        let snapshot = await executor.snapshot()
        XCTAssertEqual(snapshot.physicalOccupancy, 0)
    }

    func testReadExecutorCancellationDuringWorkRetainsSlotUntilReturn() async throws {
        let executor = ReadExecutor(maxConcurrentOperations: 1, defaultTimeout: .seconds(1))
        let started = TestLatch()
        let release = TestLatch()
        let source = UUID()
        let task = Task<Int, Error> {
            try await executor.execute(sourceID: source) { started.release(); release.wait(); return 1 }
        }
        try await started.waitAsync()

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        let occupiedSnapshot = await executor.snapshot()
        XCTAssertEqual(occupiedSnapshot.physicalOccupancy, 1)
        await XCTAssertThrowsReadExecutorError(.sourceBusy) {
            _ = try await executor.execute(sourceID: source) { 2 }
        }

        release.release()
        try await waitUntil { await executor.snapshot().physicalOccupancy == 0 }
    }

    func testReadExecutorAsyncCancellationAfterAdmissionBeforeChildWorkDoesNotStartOperation() async throws {
        let childTaskStarted = TestLatch()
        let allowChildTaskToProceed = TestLatch()
        let executor = ReadExecutor(
            maxConcurrentOperations: 2,
            defaultTimeout: .seconds(1),
            beforeAsyncOperationStart: {
                childTaskStarted.release()
                allowChildTaskToProceed.wait()
            }
        )
        let operationInvoked = TestLatch()
        let task = Task<Int, Error> {
            try await executor.executeAsync(sourceID: UUID()) {
                operationInvoked.release()
                return 1
            }
        }
        try await childTaskStarted.waitAsync()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        allowChildTaskToProceed.release()
        try await waitUntil { await executor.snapshot().physicalOccupancy == 0 }
        XCTAssertFalse(operationInvoked.isReleased)
    }
}

private struct SourceSnapshot {
    let data: Data
    let modified: Date
}

private func sourceSnapshot(_ url: URL) throws -> SourceSnapshot {
    let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
    return SourceSnapshot(data: try Data(contentsOf: url), modified: try XCTUnwrap(values.contentModificationDate))
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !(await condition()) {
        guard clock.now < deadline else {
            throw FixtureError.unavailable("timed out waiting for condition")
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @escaping @Sendable () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
    }
}

private func XCTAssertThrowsReadExecutorError<T>(
    _ expected: ReadExecutorError,
    _ expression: @escaping @Sendable () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as ReadExecutorError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}

private final class TestLatch: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    var isReleased: Bool {
        condition.lock()
        defer { condition.unlock() }
        return released
    }

    func wait() {
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func waitAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                self.wait()
                continuation.resume()
            }
        }
    }
}

extension SourceReaderTests {
    func testAncestorLinkAndReplacedRootAreRejected() async throws {
        let root = try temporaryDirectory().resolvingSymlinksInPath()
        let real = root.appendingPathComponent("real")
        let child = real.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try SourceRegistry.normalizedURL(link.appendingPathComponent("child")))
        _ = try SourceRegistry.normalizedURL(child)
        try FileManager.default.removeItem(at: child)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: root)
        await XCTAssertThrowsErrorAsync { _ = try await DirectoryReader().entries(in: child) }
    }

    func testChildAttributeFailureDoesNotDiscardHealthySiblings() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let bad = fixture.directories[0].appendingPathComponent("bad.jpg")
        try Data().write(to: bad)
        let engine = SyncEngine(store: fixture.store, photos: fixture.photos, directory: { id in
            DirectoryReader(sourceID: id, attributes: { url, keys in
                if url.lastPathComponent == "bad.jpg" { throw FixtureError.unavailable("child attributes denied") }
                return try url.resourceValues(forKeys: keys)
            })
        })
        await engine.scan(sourceIDs: fixture.sourceIDs)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.summary?.imported, 1)
        XCTAssertEqual(snapshot.latestScan.failed, 1)
        XCTAssertNotNil(snapshot.waitingSources[fixture.sourceIDs[0]])
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_record", at: fixture.databaseURL), 1)
        XCTAssertEqual(try engineSQLInteger("SELECT complete FROM scan_run", at: fixture.databaseURL), 0)
    }

    func testUnreadableUnknownChildDirectoryIsAnErrorWithoutBecomingACandidate() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        let unreadableDirectory = fixture.directories[0].appendingPathComponent("unreadable-child")
        try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true)
        let pendingURL = unreadableDirectory.appendingPathComponent("gone.jpg")
        let pending = SourceFile(sourceID: fixture.sourceIDs[0], relativePath: "unreadable-child/gone.jpg", url: pendingURL,
                                 stamp: FileStamp(size: 1, modifiedNanoseconds: 1), metadata: try await MetadataReader().read(url: fixture.directories[0].appendingPathComponent("same.jpg"), filename: "gone.jpg"))
        let pendingID = try await fixture.store.save(pending, decision: .importNew)
        // Keep this absent descendant pending without scheduling an unrelated submission read.
        try await fixture.store.recordRetry(fileID: pendingID, attemptID: nil, nextRetry: .distantFuture,
                                             error: "held pending fixture", definitelyNotCommitted: true)
        let engine = SyncEngine(store: fixture.store, photos: fixture.photos, directory: { id in
            DirectoryReader(sourceID: id, attributes: { url, keys in
                if url.lastPathComponent == "unreadable-child" {
                    throw FixtureError.unavailable("child attributes denied")
                }
                return try url.resourceValues(forKeys: keys)
            })
        })

        await engine.scan(sourceIDs: fixture.sourceIDs)

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.summary?.imported, 1)
        let details = try XCTUnwrap(snapshot.sourceIssueDetails[fixture.sourceIDs[0]])
        let normalizedChild = try SourceRegistry.normalizedURL(unreadableDirectory)
        let item = try XCTUnwrap(details.first { $0.path == normalizedChild.path })
        XCTAssertEqual(item.stage, "读取目录项属性")
        XCTAssertTrue(item.summary.contains("目录项"))
        XCTAssertFalse(item.summary.contains("损坏"))
        let retained = try await fixture.store.file(sourceID: fixture.sourceIDs[0], relativePath: "unreadable-child/gone.jpg")
        XCTAssertNotNil(retained)
        XCTAssertEqual(snapshot.latestScan.checkedCandidates, 1)
        XCTAssertEqual(snapshot.latestScan.failed, 1)
        XCTAssertEqual(snapshot.latestScan.state, .interrupted)
        XCTAssertNotNil(snapshot.waitingSources[fixture.sourceIDs[0]])
        XCTAssertEqual(try engineSQLInteger("SELECT checked FROM scan_run", at: fixture.databaseURL), 1)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_record", at: fixture.databaseURL), 2)
    }

    func testAuxiliaryFilesDoNotBecomeCandidatesOrSkippedRecords() async throws {
        let fixture = try await makeEngineFixture(sourceCount: 1)
        for name in ["same.xmp", "capture.ARW", "notes.txt", "capture.CR3"] {
            try Data("auxiliary".utf8).write(to: fixture.directories[0].appendingPathComponent(name))
        }
        await fixture.engine.scan(sourceIDs: fixture.sourceIDs)
        let snapshot = await fixture.engine.snapshot()
        XCTAssertEqual(snapshot.summary, SyncStatusSummary(imported: 1, skipped: 0, pending: 0, importing: 0))
        XCTAssertEqual(snapshot.latestScan.state, .completed)
        XCTAssertEqual(snapshot.latestScan.checkedCandidates, 1)
        XCTAssertEqual(snapshot.latestScan.newlyImported, 1)
        XCTAssertEqual(snapshot.latestScan.failed, 0)
        XCTAssertTrue(snapshot.waitingSources.isEmpty)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM non_media_skip", at: fixture.databaseURL), 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM file_record", at: fixture.databaseURL), 1)
        await fixture.engine.scan(sourceIDs: fixture.sourceIDs)
        let again = await fixture.engine.snapshot()
        XCTAssertTrue(again.waitingSources.isEmpty)
        XCTAssertEqual(again.summary, SyncStatusSummary(imported: 1, skipped: 0, pending: 0, importing: 0))
        XCTAssertEqual(again.latestScan.checkedCandidates, 1)
        XCTAssertEqual(again.latestScan.newlyImported, 0)
        XCTAssertEqual(try engineSQLInteger("SELECT COUNT(*) FROM non_media_skip", at: fixture.databaseURL), 0)
    }
}
