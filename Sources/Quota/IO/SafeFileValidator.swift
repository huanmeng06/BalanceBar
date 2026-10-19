import Darwin
import Foundation

/// Tunable limits shared by the quota IO components.
public struct QuotaIOConfiguration: Equatable {
    /// Window used to merge bursts of directory events into one notification.
    public var watchCoalescingInterval: TimeInterval

    /// Maximum bytes consumed from one file by a single incremental read.
    public var maximumBytesPerRead: Int

    /// Maximum complete lines returned by a single incremental read.
    public var maximumLinesPerRead: Int

    /// Maximum remembered deduplication keys per file before the oldest are evicted.
    public var maximumDeduplicationKeys: Int

    public init(
        watchCoalescingInterval: TimeInterval = 1,
        maximumBytesPerRead: Int = 4 * 1_024 * 1_024,
        maximumLinesPerRead: Int = 10_000,
        maximumDeduplicationKeys: Int = 50_000
    ) {
        self.watchCoalescingInterval = watchCoalescingInterval
        self.maximumBytesPerRead = maximumBytesPerRead
        self.maximumLinesPerRead = maximumLinesPerRead
        self.maximumDeduplicationKeys = maximumDeduplicationKeys
    }

    /// Defaults used when a caller does not inject its own limits.
    public static let `default` = Self()
}

/// Reasons a file is rejected before quota code reads it.
public enum SafeFileValidationError: Error, Equatable {
    case outsideAllowedDirectories
    case notRegularFile
    case tooLarge(size: Int, limit: Int)
    case wrongOwner(uid: uid_t)
    case writableByOthers
    case unreadable(errno: Int32)
}

/// Rejects files that resolve outside allowed directories, are too large,
/// are owned by another user, or are writable by group/others.
///
/// All methods perform blocking file-system work; call them off the main thread.
public struct SafeFileValidator: FileValidating {
    public let allowedDirectories: [URL]
    public let maximumFileSize: Int?
    public let ownerUID: uid_t

    /// - Parameters:
    ///   - allowedDirectories: Directories a resolved file must live under.
    ///   - maximumFileSize: Byte limit, or `nil` for growing logs read incrementally.
    ///   - ownerUID: Required owner; defaults to the current user.
    public init(
        allowedDirectories: [URL],
        maximumFileSize: Int? = QuotaConstants.snapshotMaximumSizeBytes,
        ownerUID: uid_t = getuid()
    ) {
        self.allowedDirectories = allowedDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.maximumFileSize = maximumFileSize
        self.ownerUID = ownerUID
    }

    /// Checks only the byte-size limit of already-read data.
    public func validate(data: Data) throws {
        if let limit = maximumFileSize, data.count > limit {
            throw SafeFileValidationError.tooLarge(size: data.count, limit: limit)
        }
    }

    /// Resolves symlinks and validates location, type, owner, permissions and size.
    /// - Returns: The resolved file URL.
    @discardableResult
    public func validateFile(at url: URL) throws -> URL {
        let resolved = try resolveAllowed(url)
        let (handle, _) = try openValidatedFile(resolved: resolved)
        try? handle.close()
        return resolved
    }

    /// Validates and reads the file through a single descriptor, avoiding a
    /// check-then-open race on the final path component.
    public func readValidatedFile(at url: URL) throws -> Data {
        let (handle, _) = try openValidatedFile(at: url)
        defer { try? handle.close() }
        let data = try handle.readToEnd() ?? Data()
        try validate(data: data)
        return data
    }

    /// Validates and returns the still-open descriptor, so callers read exactly
    /// the file that passed the checks instead of reopening the path.
    func openValidatedFile(at url: URL) throws -> (FileHandle, stat) {
        try openValidatedFile(resolved: resolveAllowed(url))
    }

    private func openValidatedFile(resolved: URL) throws -> (FileHandle, stat) {
        let fd = try openNoFollow(resolved)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return (handle, try checkDescriptor(fd))
    }

    func resolveAllowed(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let components = resolved.pathComponents
        let allowed = allowedDirectories.contains { directory in
            let prefix = directory.pathComponents
            return components.count > prefix.count && Array(components.prefix(prefix.count)) == prefix
        }
        guard allowed else { throw SafeFileValidationError.outsideAllowedDirectories }
        return resolved
    }

    private func openNoFollow(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw SafeFileValidationError.notRegularFile }
            throw SafeFileValidationError.unreadable(errno: errno)
        }
        return fd
    }

    private func checkDescriptor(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SafeFileValidationError.unreadable(errno: errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw SafeFileValidationError.notRegularFile }
        guard info.st_uid == ownerUID else { throw SafeFileValidationError.wrongOwner(uid: info.st_uid) }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw SafeFileValidationError.writableByOthers }
        if let limit = maximumFileSize, Int(info.st_size) > limit {
            throw SafeFileValidationError.tooLarge(size: Int(info.st_size), limit: limit)
        }
        return info
    }
}
