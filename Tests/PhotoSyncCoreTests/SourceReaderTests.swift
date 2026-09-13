import XCTest
import PhotoSyncCore

final class SourceReaderTests: XCTestCase {
    func testDirectoryReaderExcludesHiddenLinksAndPackages() async throws {
        let directory = try sourceFixtureDirectory()

        let entries = try await DirectoryReader().entries(in: directory)
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

        let value = try await MetadataReader().read(url: url, filename: "no-exif.png")

        XCTAssertNil(value.captureSecond)
        XCTAssertNil(value.make)
        XCTAssertNotNil(value.width)
        let after = try sourceSnapshot(url)
        XCTAssertEqual(after.data, before.data)
        XCTAssertEqual(after.modified, before.modified)
    }

    func testCorruptImageThrows() async throws {
        let directory = try sourceFixtureDirectory()
        let url = directory.appendingPathComponent("corrupt.jpg")

        await XCTAssertThrowsErrorAsync {
            _ = try await MetadataReader().read(url: url, filename: "corrupt.jpg")
        }
    }

    func testRawIsUnsupported() async throws {
        let directory = try sourceFixtureDirectory()

        await XCTAssertThrowsErrorAsync {
            _ = try await MetadataReader().read(url: directory.appendingPathComponent("photo.CR3"), filename: "photo.CR3")
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
        XCTAssertNil(MetadataReader.captureSecond(rawCaptureTime: "2026:09:13 10:15:30", offsetTimeOriginal: nil))
    }

    func testReadExecutorKeepsTimedOutSlotOccupiedUntilBlockingWorkReturns() async throws {
        let executor = ReadExecutor(maxConcurrentOperations: 2, defaultTimeout: .milliseconds(20))
        let latch = TestLatch()
        let source = UUID()

        async let timedOut: Int = executor.execute(sourceID: source) {
                latch.wait()
                return 1
        }
        try? await Task.sleep(for: .milliseconds(5))
        let independent = try await executor.execute(sourceID: UUID()) { 2 }
        XCTAssertEqual(independent, 2)
        do {
            _ = try await timedOut
            XCTFail("expected the blocked operation to time out")
        } catch {
        }
        let timedOutSnapshot = await executor.snapshot()
        XCTAssertEqual(timedOutSnapshot.physicalOccupancy, 1)

        await XCTAssertThrowsErrorAsync {
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
        try? await Task.sleep(for: .milliseconds(5))
        await XCTAssertThrowsErrorAsync {
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
}
