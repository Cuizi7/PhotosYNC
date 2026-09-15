import XCTest
import Darwin
@testable import PhotoSyncCore

// XCTest marks fork unavailable. The child below only uses raw POSIX calls and
// _exit so the test can verify cross-process flock behavior without an app.
@_silgen_name("fork")
private func rawFork() -> Int32

final class SingleInstanceLockTests: XCTestCase {
    func testDifferentApplicationIdentitiesUseDifferentLockPaths() throws {
        let support = try temporaryDirectory()

        let production = try SingleInstanceLock.lockURL(
            applicationIdentifier: "com.example.PhotoSync",
            applicationSupportDirectory: support
        )
        let guiQA = try SingleInstanceLock.lockURL(
            applicationIdentifier: "local.photosync.guiqa",
            applicationSupportDirectory: support
        )

        XCTAssertNotEqual(production, guiQA)
        XCTAssertFalse(production.deletingLastPathComponent().path.hasPrefix(guiQA.deletingLastPathComponent().path + "/"))
        XCTAssertFalse(guiQA.deletingLastPathComponent().path.hasPrefix(production.deletingLastPathComponent().path + "/"))
    }

    func testLockReleasesWhenHolderIsDeallocated() throws {
        let lockURL = try lockURL()
        try acquireThenRelease(lockURL)

        switch SingleInstanceLock.acquire(at: lockURL) {
        case .acquired:
            break
        case .alreadyRunning:
            XCTFail("A released lock must be acquirable again.")
        case .failed(let error):
            XCTFail("Unexpected lock failure: \(error.localizedDescription)")
        }
    }

    func testOtherProcessBlocksAcquisitionAndReportsItsOwnerPID() throws {
        let lockURL = try lockURL()
        let readiness = try makePipe()
        let release = try makePipe()
        let path = strdup(lockURL.path)
        guard let path else { throw POSIXError(.ENOMEM) }
        defer { free(path) }

        let child = rawFork()
        guard child >= 0 else { throw currentPOSIXError() }
        if child == 0 {
            close(readiness.read)
            close(release.write)

            let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            var status: UInt8 = 0
            if descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                status = 1
            }
            withUnsafePointer(to: &status) { pointer in
                _ = write(readiness.write, pointer, MemoryLayout<UInt8>.size)
            }
            guard status == 1 else {
                if descriptor >= 0 { close(descriptor) }
                _exit(EXIT_FAILURE)
            }

            var ignored: UInt8 = 0
            withUnsafeMutablePointer(to: &ignored) { pointer in
                _ = read(release.read, pointer, MemoryLayout<UInt8>.size)
            }
            if descriptor >= 0 { close(descriptor) }
            _exit(status == 1 ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        close(readiness.write)
        close(release.read)
        var childNeedsRelease = true
        var childReaped = false
        defer {
            if childNeedsRelease {
                var releaseByte: UInt8 = 1
                withUnsafePointer(to: &releaseByte) { pointer in
                    _ = write(release.write, pointer, MemoryLayout<UInt8>.size)
                }
            }
            if !childReaped {
                var exitStatus: Int32 = 0
                _ = waitpid(child, &exitStatus, 0)
            }
            close(readiness.read)
            close(release.write)
        }

        var status: UInt8 = 0
        let bytesRead = withUnsafeMutablePointer(to: &status) { pointer in
            read(readiness.read, pointer, MemoryLayout<UInt8>.size)
        }
        guard bytesRead == MemoryLayout<UInt8>.size, status == 1 else {
            XCTFail("The fixture child could not acquire its lock.")
            return
        }

        let ownerDescriptor = open(lockURL.path, O_RDWR)
        guard ownerDescriptor >= 0 else { throw currentPOSIXError() }
        defer { close(ownerDescriptor) }
        XCTAssertEqual(ftruncate(ownerDescriptor, 0), 0)
        XCTAssertGreaterThanOrEqual(lseek(ownerDescriptor, 0, SEEK_SET), 0)
        let ownerData = Data("\(child)\n".utf8)
        let writeCount = ownerData.withUnsafeBytes { buffer in
            write(ownerDescriptor, buffer.baseAddress, buffer.count)
        }
        XCTAssertEqual(writeCount, ownerData.count)
        switch SingleInstanceLock.acquire(at: lockURL) {
        case .acquired:
            XCTFail("A lock held by another process must reject a second process.")
        case .alreadyRunning(let ownerPID):
            XCTAssertEqual(ownerPID, child)
        case .failed(let error):
            XCTFail("Unexpected lock failure: \(error.localizedDescription)")
        }

        var releaseByte: UInt8 = 1
        withUnsafePointer(to: &releaseByte) { pointer in
            _ = write(release.write, pointer, MemoryLayout<UInt8>.size)
        }
        childNeedsRelease = false
        var exitStatus: Int32 = 0
        XCTAssertEqual(waitpid(child, &exitStatus, 0), child)
        XCTAssertEqual(exitStatus, 0)
        childReaped = true

        switch SingleInstanceLock.acquire(at: lockURL) {
        case .acquired:
            break
        case .alreadyRunning:
            XCTFail("The lock must be available after the holder process exits.")
        case .failed(let error):
            XCTFail("Unexpected lock failure: \(error.localizedDescription)")
        }
    }

    private func lockURL() throws -> URL {
        try SingleInstanceLock.lockURL(
            applicationIdentifier: "fixture.photosync.single-instance.\(UUID().uuidString)",
            applicationSupportDirectory: try temporaryDirectory()
        )
    }

    private func acquireThenRelease(_ lockURL: URL) throws {
        switch SingleInstanceLock.acquire(at: lockURL) {
        case .acquired(let lock):
            _ = lock
        case .alreadyRunning:
            XCTFail("Fresh fixture lock should be available.")
        case .failed(let error):
            XCTFail("Unexpected lock failure: \(error.localizedDescription)")
        }
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw currentPOSIXError() }
        return (descriptors[0], descriptors[1])
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
