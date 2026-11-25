import Darwin
import Foundation

/// Copies that cost no space on APFS: a clone shares the original's blocks until one side changes.
/// Safe from any thread; call it off the main thread for anything bigger than a few files.
public enum FileClone {
    public enum Outcome: Equatable, Sendable {
        /// One clone of the whole item: instant, and no extra space.
        case cloned
        /// Copied file by file, each file cloned where the disk can.
        case copied
    }

    public enum Fallback: Equatable, Sendable {
        /// When the item can't be cloned (another disk, a disk that isn't APFS), copy it.
        case copy
        /// Throw `Failure.cannotClone` instead, so the app can ask before a full copy.
        case none
    }

    public enum Failure: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
        /// Something is already at the target; nothing was touched.
        case targetExists(String)
        /// The item can't be cloned there: another disk, or a disk that isn't APFS.
        case cannotClone(POSIXErrorCode)

        /// The system's words for the reason ("Cross-device link"), for a log line.
        public var reason: String {
            switch self {
            case .targetExists: String(cString: strerror(EEXIST))
            case .cannotClone(let code): String(cString: strerror(code.rawValue))
            }
        }

        /// For logs, in English: "Already exists: /path", "Can't clone: Cross-device link".
        public var description: String {
            switch self {
            case .targetExists(let path): "Already exists: \(path)"
            case .cannotClone: "Can't clone: \(reason)"
            }
        }

        public var errorDescription: String? { description }
    }

    /// Clones `source` (a file or a whole folder) to `target`, which must not exist yet; its folder is made.
    /// A symbolic link at `source` itself is followed. When the clone can't be made there, `fallback` decides.
    @discardableResult
    public static func clone(_ source: URL, to target: URL, fallback: Fallback = .copy) throws -> Outcome {
        if FileManager.default.fileExists(atPath: target.path) || isLink(target) { throw Failure.targetExists(target.path) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if clonefile(source.path, target.path, 0) == 0 { return .cloned }
        let reason = errno
        guard reason == EXDEV || reason == ENOTSUP || reason == ENOTTY else {
            throw POSIXError(POSIXErrorCode(rawValue: reason) ?? .EIO)
        }
        guard fallback == .copy else { throw Failure.cannotClone(POSIXErrorCode(rawValue: reason) ?? .ENOTSUP) }
        try copy(source.resolvingSymlinksInPath(), to: target)
        return .copied
    }

    /// Copies a file, link or folder to `target`, which must not exist yet. Each file is cloned where the disk can,
    /// links stay links, and permissions, extended attributes and tags come along. `copied` gets each file's size
    /// as it lands. Stops with `CancellationError` between files when `stop` says so (by default, when the current
    /// task is cancelled). On any failure, what was copied so far is removed.
    public static func copy(_ source: URL, to target: URL, stop: () -> Bool = { Task.isCancelled },
                            copied: (Int64) -> Void = { _ in }) throws {
        if FileManager.default.fileExists(atPath: target.path) || isLink(target) { throw Failure.targetExists(target.path) }
        do {
            try copyTree(source, to: target, stop: stop, copied: copied)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// True when both are on one volume, where a clone costs no space and a move is a rename. An item that doesn't
    /// exist yet is read from the nearest folder above it that does.
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let left = volume(of: a), let right = volume(of: b) else { return false }
        return left.isEqual(right)
    }

    static func volume(of url: URL) -> NSObject? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func copyTree(_ source: URL, to target: URL, stop: () -> Bool, copied: (Int64) -> Void) throws {
        if stop() { throw CancellationError() }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isDirectory == true, values.isSymbolicLink != true {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let children = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
            for name in children {
                try copyTree(source.appending(path: name), to: target.appending(path: name), stop: stop, copied: copied)
            }
            // Permissions, extended attributes and tags, once the folder is full.
            _ = copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_METADATA))
        } else {
            let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
            guard copyfile(source.path, target.path, nil, flags) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if values.isSymbolicLink != true { copied(Int64(values.fileSize ?? 0)) }
        }
    }
}
