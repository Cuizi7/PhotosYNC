import Darwin
import Foundation

/// Encoding storage limits are independent of the decoded-image budget.
struct PhotosResourceLimits: Sendable {
    let maxEncodedBytes: Int64
    let freeSpaceReserveBytes: Int64
    init(maxEncodedBytes: Int64 = 536870912, freeSpaceReserveBytes: Int64 = 134217728) {
        precondition(maxEncodedBytes > 0 && freeSpaceReserveBytes >= 0)
        self.maxEncodedBytes = maxEncodedBytes; self.freeSpaceReserveBytes = freeSpaceReserveBytes
    }
}

struct PhotosResourceStorage: Sendable {
    let root: URL
    private let availableBytes: (@Sendable () throws -> Int64)?
    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosYNC-encoded-resources"),
         availableBytes: (@Sendable () throws -> Int64)? = nil) {
        self.root = root; self.availableBytes = availableBytes
    }

    func create(limits: PhotosResourceLimits) throws -> OwnedPhotosResource {
        // Only the documented system /tmp and /var aliases may normalize.
        let parent = try SourceRegistry.normalizedURL(root.deletingLastPathComponent())
        let root = parent.appendingPathComponent(root.lastPathComponent)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw storageError("private directory creation") }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw storageError("private directory open") }
        defer { close(rootFD) }
        guard Self.isPrivate(rootFD, directory: true) else { throw storageError("private directory ownership") }
        Self.cleanInactiveOwners(root: root, rootFD: rootFD)
        let name = UUID().uuidString
        guard mkdirat(rootFD, name, 0o700) == 0 else { throw storageError("exclusive request directory") }
        let directoryFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw storageError("request directory open") }
        let ownerFD = openat(directoryFD, "owner", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard ownerFD >= 0 else { close(directoryFD); throw storageError("exclusive owner creation") }
        guard flock(ownerFD, LOCK_EX | LOCK_NB) == 0 else {
            close(ownerFD); close(directoryFD); throw storageError("owner lock")
        }
        let streamFD = openat(directoryFD, "encoded", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard streamFD >= 0 else { close(ownerFD); close(directoryFD); throw storageError("exclusive encoded file") }
        let marker: Data
        do { marker = try Self.ownerMarker(encodedFD: streamFD) }
        catch { close(streamFD); close(ownerFD); close(directoryFD); throw error }
        let written = marker.withUnsafeBytes { Darwin.write(ownerFD, $0.baseAddress, $0.count) }
        guard written == marker.count else {
            close(streamFD); close(ownerFD); close(directoryFD); throw storageError("owner marker")
        }
        let resource = OwnedPhotosResource(directory: root.appendingPathComponent(name), directoryFD: directoryFD,
            ownerFD: ownerFD, streamFD: streamFD, marker: marker, limits: limits, availableBytes: availableBytes)
        do { try resource.ensureSpace(for: 0); return resource }
        catch { resource.remove(); throw error }
    }

    static func ownerMarker(encodedFD: Int32) throws -> Data {
        var st = stat()
        guard fstat(encodedFD, &st) == 0 else { throw storageError("encoded ownership identity") }
        return Data("PhotosYNC encoded resource v1\n\(st.st_dev):\(st.st_ino)\n".utf8)
    }
    fileprivate static func isPrivate(_ fd: Int32, directory: Bool) -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid() else { return false }
        return st.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) && st.st_mode & 0o777 == (directory ? 0o700 : 0o600)
    }
    /// Require the exact private marker, owner UID/modes, inactive flock, and
    /// only our two known regular files. Unknown paths are left untouched.
    private static func cleanInactiveOwners(root: URL, rootFD: Int32) {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in children where UUID(uuidString: name) != nil {
            let fd = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard isPrivate(fd, directory: true),
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(name).path),
                  Set(entries) == Set(["owner", "encoded"]) else { continue }
            let owner = openat(fd, "owner", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard owner >= 0 else { continue }
            defer { close(owner) }
            guard isPrivate(owner, directory: false), flock(owner, LOCK_EX | LOCK_NB) == 0 else { continue }
            let encoded = openat(fd, "encoded", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard encoded >= 0 else { continue }
            let expected = try? ownerMarker(encodedFD: encoded)
            let valid = isPrivate(encoded, directory: false); close(encoded)
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = read(owner, &bytes, bytes.count)
            guard valid, count > 0, Data(bytes.prefix(count)) == expected, directoryStillMatches(fd, path: root.appendingPathComponent(name).path) else { continue }
            guard unlinkat(fd, "encoded", 0) == 0, unlinkat(fd, "owner", 0) == 0 else { continue }
            _ = unlinkat(rootFD, name, AT_REMOVEDIR)
        }
    }
    fileprivate static func directoryStillMatches(_ fd: Int32, path: String) -> Bool {
        var held = stat(), current = stat()
        return fstat(fd, &held) == 0 && lstat(path, &current) == 0 &&
            held.st_dev == current.st_dev && held.st_ino == current.st_ino && current.st_mode & S_IFMT == S_IFDIR
    }
}

/// One physical request owns its stream and a locked, private directory. The
/// successful lease retains this object until the last lazy pixel consumer ends.
final class OwnedPhotosResource: @unchecked Sendable {
    let url: URL
    private let directory: URL
    private let directoryFD: Int32
    private let ownerFD: Int32
    private var streamFD: Int32
    private let limits: PhotosResourceLimits
    private let marker: Data
    private let availableBytes: (@Sendable () throws -> Int64)?
    private var bytes: Int64 = 0
    private var removed = false

    fileprivate init(directory: URL, directoryFD: Int32, ownerFD: Int32, streamFD: Int32, marker: Data,
                     limits: PhotosResourceLimits, availableBytes: (@Sendable () throws -> Int64)?) {
        self.directory = directory; self.directoryFD = directoryFD; self.ownerFD = ownerFD; self.streamFD = streamFD
        self.limits = limits; self.availableBytes = availableBytes; self.marker = marker
        url = directory.appendingPathComponent("encoded")
    }

    func append(_ data: Data) throws {
        guard streamFD >= 0 else { throw storageError("closed encoded stream") }
        guard Int64(data.count) <= limits.maxEncodedBytes - bytes else { throw PhotosRepresentationError.encodedResourceLimit }
        try ensureSpace(for: Int64(data.count))
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(streamFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw storageError("encoded stream write") }
                offset += result; bytes += Int64(result)
            }
        }
    }
    func closeStream() throws {
        guard streamFD >= 0 else { return }
        let fd = streamFD; streamFD = -1
        guard close(fd) == 0 else { throw storageError("encoded stream close") }
    }
    fileprivate func ensureSpace(for chunk: Int64) throws {
        let available: Int64
        if let availableBytes { available = try availableBytes() }
        else {
            var info = statfs()
            guard fstatfs(directoryFD, &info) == 0 else { throw storageError("same-volume space check") }
            let (size, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
            guard !overflow, size <= UInt64(Int64.max) else { throw storageError("same-volume space accounting") }
            available = Int64(size)
        }
        guard available >= limits.freeSpaceReserveBytes, chunk <= available - limits.freeSpaceReserveBytes else {
            throw PhotosRepresentationError.resourceStorageUnavailable("insufficient temporary volume space")
        }
    }
    func remove() {
        guard !removed else { return }; removed = true
        try? closeStream()
        // Never follow a replaced directory; only unlink known children through
        // the held directory handle. Unknown children prevent directory removal.
        let encoded = openat(directoryFD, "encoded", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let unchanged = encoded >= 0 && (try? PhotosResourceStorage.ownerMarker(encodedFD: encoded)) == marker
        if encoded >= 0 { close(encoded) }
        var owner = stat(), currentOwner = stat()
        let ownerUnchanged = fstat(ownerFD, &owner) == 0 && fstatat(directoryFD, "owner", &currentOwner, AT_SYMLINK_NOFOLLOW) == 0 &&
            owner.st_dev == currentOwner.st_dev && owner.st_ino == currentOwner.st_ino
        if unchanged, ownerUnchanged, PhotosResourceStorage.directoryStillMatches(directoryFD, path: directory.path) {
            _ = unlinkat(directoryFD, "encoded", 0)
            _ = unlinkat(directoryFD, "owner", 0)
            _ = rmdir(directory.path)
        }
        close(ownerFD); close(directoryFD)
    }
    deinit { remove() }
}

private func storageError(_ stage: String) -> PhotosRepresentationError {
    .resourceStorageUnavailable("\(stage): \(String(cString: strerror(errno)))")
}
