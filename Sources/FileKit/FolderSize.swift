import Foundation

/// How much room a file or folder takes: allocated (what the disk counts, as the Finder shows it) and logical (the
/// bytes in the files). Hidden files count, a file with several hard links counts once, symbolic links are not
/// followed. Safe from any thread; the async functions walk the folder off the caller's thread.
public enum FolderSize {
    /// What a walk found.
    public struct Summary: Sendable, Equatable {
        /// Bytes the disk gives the files: sparse, compressed and cloned files count as they are stored.
        public var allocated: Int64 = 0
        /// Bytes in the files, as a copy to another disk would need.
        public var logical: Int64 = 0
        /// Regular files, each hard-linked file once.
        public var files = 0
        /// Every item inside, at every depth: files, folders, links.
        public var items = 0

        public init(allocated: Int64 = 0, logical: Int64 = 0, files: Int = 0, items: Int = 0) {
            self.allocated = allocated
            self.logical = logical
            self.files = files
            self.items = items
        }
    }

    public struct Options: Sendable, Equatable {
        /// Names of items directly inside the folder that are left out (a database that stays behind).
        public var excluding: Set<String>
        /// Folders left out wherever they are, with everything in them ("FolderSize.otherAppsData").
        public var skipping: [URL]
        /// Leaves out other disks mounted inside the folder.
        public var staysOnVolume: Bool

        public init(excluding: Set<String> = [], skipping: [URL] = [], staysOnVolume: Bool = false) {
            self.excluding = excluding
            self.skipping = skipping
            self.staysOnVolume = staysOnVolume
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The folder itself can't be read: its size isn't known, which is not the same as zero.
        case unreadable
    }

    /// Other apps' data in ~/Library: reading it makes macOS ask the person for permission.
    public static var otherAppsData: [URL] {
        let library = URL.homeDirectory.appending(path: "Library", directoryHint: .isDirectory)
        return [library.appending(path: "Containers"), library.appending(path: "Group Containers")]
    }

    // MARK: Async, off the caller's thread

    /// Allocated bytes, as the Finder shows them. 0 when it can't be read or the task is cancelled.
    public static func allocated(of url: URL, options: Options = Options()) async -> Int64 {
        (try? await measure(url, options: options).allocated) ?? 0
    }

    /// Bytes in the files, as a copy needs. 0 when it can't be read or the task is cancelled.
    public static func logical(of url: URL, options: Options = Options()) async -> Int64 {
        (try? await measure(url, options: options).logical) ?? 0
    }

    /// Both sizes and the counts. Throws `Failure.unreadable` when the folder can't be read, and
    /// `CancellationError` when the task is cancelled.
    public static func measure(_ url: URL, options: Options = Options()) async throws -> Summary {
        let walk = Task.detached(priority: .utility) { try summary(of: url, options: options) }
        return try await withTaskCancellationHandler { try await walk.value } onCancel: { walk.cancel() }
    }

    // MARK: Sync, for code already off the main thread

    /// Both sizes and the counts, on this thread. Stops with `CancellationError` when the current task is cancelled.
    public static func summary(of url: URL, options: Options = Options()) throws -> Summary {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                         .fileAllocatedSizeKey, .fileSizeKey, .linkCountKey, .fileIdentifierKey,
                                         .volumeIdentifierKey]
        guard let top = try? url.resourceValues(forKeys: keys) else { throw Failure.unreadable }
        var result = Summary()
        if top.isSymbolicLink == true { return result }
        var linked: Set<UInt64> = []
        guard top.isDirectory == true else {
            add(top, to: &result, linked: &linked)
            return result
        }
        // The enumerator would skip a folder it can't open and answer zero.
        guard let handle = opendir(url.path) else { throw Failure.unreadable }
        closedir(handle)

        let skipped = Set(options.skipping.map(\.fileKitPath))
        let volume = top.volumeIdentifier as? NSObject
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                          errorHandler: { _, _ in true }) else { return result }
        var count = 0
        while let item = walker.nextObject() as? URL {
            count += 1
            if count % 256 == 0, Task.isCancelled { throw CancellationError() }
            guard let values = try? item.resourceValues(forKeys: keys) else { continue }
            let isFolder = values.isDirectory == true && values.isSymbolicLink != true
            if walker.level == 1, options.excluding.contains(item.lastPathComponent) {
                // skipDescendants after a file would skip the last folder seen instead.
                if isFolder { walker.skipDescendants() }
                continue
            }
            if isFolder {
                if !skipped.isEmpty, skipped.contains(item.fileKitPath) { walker.skipDescendants(); continue }
                if options.staysOnVolume, let volume, let other = values.volumeIdentifier as? NSObject, !volume.isEqual(other) {
                    walker.skipDescendants()
                    continue
                }
            }
            result.items += 1
            add(values, to: &result, linked: &linked)
        }
        if Task.isCancelled { throw CancellationError() }
        return result
    }

    private static func add(_ values: URLResourceValues, to result: inout Summary, linked: inout Set<UInt64>) {
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
        // A file with several names counts the first time only.
        if (values.linkCount ?? 1) > 1, let id = values.fileIdentifier, !linked.insert(id).inserted { return }
        result.files += 1
        result.allocated += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        result.logical += Int64(values.fileSize ?? 0)
    }
}

extension URL {
    /// The path with /tmp and /var read as /private/..., so two spellings of one folder compare equal.
    var fileKitPath: String {
        standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            .replacing(/\/$/, with: "")
    }
}
