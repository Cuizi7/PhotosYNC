import Foundation
import Darwin

public enum SingleInstanceLockError: Error, LocalizedError {
    case invalidApplicationIdentifier
    case cannotCreateDirectory(path: String, code: Int32)
    case cannotOpen(path: String, code: Int32)
    case cannotWriteOwner(path: String, code: Int32)
    case cannotLock(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidApplicationIdentifier:
            return "PhotosYNC cannot create an instance lock without an application identifier."
        case .cannotCreateDirectory(let path, let code):
            return "PhotosYNC cannot prepare its instance lock directory at \(path): \(description(for: code))."
        case .cannotOpen(let path, let code):
            return "PhotosYNC cannot open its instance lock at \(path): \(description(for: code))."
        case .cannotWriteOwner(let path, let code):
            return "PhotosYNC cannot record its instance owner at \(path): \(description(for: code))."
        case .cannotLock(let path, let code):
            return "PhotosYNC cannot lock \(path): \(description(for: code))."
        }
    }

    private func description(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Holds a non-blocking, process-owned advisory lock for one app identity.
/// Releasing the object closes its descriptor, which releases the lock.
public final class SingleInstanceLock {
    public enum Acquisition {
        case acquired(SingleInstanceLock)
        case alreadyRunning(ownerPID: Int32?)
        case failed(SingleInstanceLockError)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    /// Returns an identity-scoped location separate from PhotoSync's runtime database.
    public static func lockURL(
        applicationIdentifier: String,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !applicationIdentifier.isEmpty else { throw SingleInstanceLockError.invalidApplicationIdentifier }
        let support = applicationSupportDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support
            .appendingPathComponent("PhotoSync Instance Locks", isDirectory: true)
            .appendingPathComponent(lockPathComponent(for: applicationIdentifier), isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SingleInstanceLockError.cannotCreateDirectory(path: directory.path, code: errno)
        }
        return directory.appendingPathComponent("instance.lock", isDirectory: false)
    }

    public static func acquire(
        at lockURL: URL,
        ownerPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> Acquisition {
        let descriptor = lockURL.path.withCString {
            open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            return .failed(.cannotOpen(path: lockURL.path, code: errno))
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            if let code = writeOwnerPID(ownerPID, to: descriptor) {
                _ = flock(descriptor, LOCK_UN)
                _ = close(descriptor)
                return .failed(.cannotWriteOwner(path: lockURL.path, code: code))
            }
            return .acquired(SingleInstanceLock(descriptor: descriptor))
        }

        let code = errno
        if code == EWOULDBLOCK || code == EAGAIN {
            let ownerPID = readOwnerPID(from: descriptor)
            _ = close(descriptor)
            return .alreadyRunning(ownerPID: ownerPID)
        }

        _ = close(descriptor)
        return .failed(.cannotLock(path: lockURL.path, code: code))
    }

    private static func lockPathComponent(for applicationIdentifier: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return applicationIdentifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? applicationIdentifier
    }

    private static func writeOwnerPID(_ ownerPID: Int32, to descriptor: Int32) -> Int32? {
        guard ftruncate(descriptor, 0) == 0 else { return errno }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { return errno }

        let data = Data("\(ownerPID)\n".utf8)
        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return EIO }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                guard count > 0 else { return EIO }
                offset += count
            }
            return nil
        }
    }

    private static func readOwnerPID(from descriptor: Int32) -> Int32? {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            read(descriptor, pointer.baseAddress, pointer.count - 1)
        }
        guard count > 0 else { return nil }
        return Int32(String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
