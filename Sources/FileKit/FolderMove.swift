import Foundation

/// Moves an app's data folder somewhere else, such as an external drive, without ever losing data.
///
/// Same disk: each item is renamed, and the renames are undone if one fails. Another disk: everything is copied into
/// a hidden staging folder beside the destination, checked file by file (sizes, and where each link points), and
/// only then put in place and deleted from the old folder. If anything fails before the old items are deleted, the
/// old folder stays as it was and nothing is left at the destination.
///
/// Synchronous and slow on another disk: call it off the main thread. Safe from any thread.
public enum FolderMove {
    public enum Failure: Error, Equatable, Sendable {
        /// The chosen folder already has an item of that name where the data would go (a path relative to it).
        case destinationExists(String)
        /// The chosen folder is the data folder or inside it.
        case insideItself
        case notEnoughSpace(needed: Int64, available: Int64)
        /// A copy or a rename failed; the old folder is unchanged.
        case copyFailed(String)
        /// A copied file doesn't match the original (its path relative to the folder); the old folder is unchanged.
        case verifyFailed(String)
    }

    /// One regular file or symbolic link, with its path relative to the folder.
    public struct File: Equatable, Sendable {
        public var path: String
        /// Bytes in the file; 0 for a link.
        public var size: Int64
        /// Where a symbolic link points, as written in the link; nil for a file.
        public var link: String?

        public init(path: String, size: Int64, link: String? = nil) {
            self.path = path
            self.size = size
            self.link = link
        }
    }

    /// Moves `source` into `parent`, keeping its name, and returns the new location. Top-level items named in
    /// `keeping` stay where they are (a database the app has open, see `databaseFiles`). The new folder may already
    /// exist (moving back into the default folder that kept the database) as long as none of the moved items is in
    /// it. `progress` gets (bytes done, bytes in all) from this thread.
    @discardableResult
    public static func move(_ source: URL, into parent: URL, keeping: Set<String> = [],
                            progress: (@Sendable (Int64, Int64) -> Void)? = nil) throws(Failure) -> URL {
        try move(source, into: parent, keeping: keeping, alwaysCopy: false, progress: progress)
    }

    /// `alwaysCopy` takes the other-disk path on one disk, for tests.
    static func move(_ source: URL, into parent: URL, keeping: Set<String>, alwaysCopy: Bool,
                     progress: (@Sendable (Int64, Int64) -> Void)?) throws(Failure) -> URL {
        let fm = FileManager.default
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let parent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let destination = parent.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        if parent.path == source.path || parent.path.hasPrefix(source.path + "/") { throw .insideItself }
        if destination.path == source.path { return source }

        let items = ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).filter { !keeping.contains($0) }.sorted()
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isFolder) || FileClone.isLink(destination) {
            guard isFolder.boolValue, !FileClone.isLink(destination) else { throw .destinationExists(source.lastPathComponent) }
            if let clash = items.first(where: { fm.fileExists(atPath: destination.appending(path: $0).path)
                                                || FileClone.isLink(destination.appending(path: $0)) }) {
                throw .destinationExists(source.lastPathComponent + "/" + clash)
            }
        }

        let files = listFiles(in: source, excluding: keeping)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        progress?(0, total)

        // Same disk: a rename is instant. Undo the renames done so far if one fails.
        if !alwaysCopy, FileClone.sameVolume(source, parent) {
            let made = !fm.fileExists(atPath: destination.path)
            var moved: [String] = []
            do {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for item in items {
                    try fm.moveItem(at: source.appending(path: item), to: destination.appending(path: item))
                    moved.append(item)
                }
            } catch {
                for item in moved.reversed() { try? fm.moveItem(at: destination.appending(path: item), to: source.appending(path: item)) }
                if made { removeIfEmpty(destination) }
                throw .copyFailed(error.localizedDescription)
            }
            removeIfEmpty(source)
            progress?(total, total)
            return destination
        }

        let available = (try? parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        if available < total { throw .notEnoughSpace(needed: total, available: available) }

        // A name of our own, so nothing the person keeps there is ever replaced.
        let staging = parent.appending(path: ".\(source.lastPathComponent)-moving-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var done: Int64 = 0
            for item in items {
                try FileClone.copy(source.appending(path: item), to: staging.appending(path: item), stop: { false }) { size in
                    done += size
                    progress?(done, total)
                }
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw .copyFailed(error.localizedDescription)
        }
        let copied = Dictionary(listFiles(in: staging).map { ($0.path, $0) }) { first, _ in first }
        for file in files where copied[file.path] != file {
            try? fm.removeItem(at: staging)
            throw .verifyFailed(file.path)
        }
        do {
            if fm.fileExists(atPath: destination.path) {
                // Into the existing folder: the staging folder is on the same disk, so these are renames.
                var moved: [String] = []
                do {
                    for item in items {
                        try fm.moveItem(at: staging.appending(path: item), to: destination.appending(path: item))
                        moved.append(item)
                    }
                } catch {
                    for item in moved { try? fm.removeItem(at: destination.appending(path: item)) }
                    throw error
                }
                try? fm.removeItem(at: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw .copyFailed(error.localizedDescription)
        }
        for item in items { try? fm.removeItem(at: source.appending(path: item)) }
        removeIfEmpty(source)
        progress?(total, total)
        return destination
    }

    /// The files of an SQLite database (`store`, `-shm`, `-wal`) when it sits right in `folder`, for `keeping`:
    /// the app has it open, so it stays where it is. Empty when the database is elsewhere.
    public static func databaseFiles(store: URL, in folder: URL) -> Set<String> {
        guard store.deletingLastPathComponent().fileKitPath == folder.fileKitPath else { return [] }
        let name = store.lastPathComponent
        return [name, name + "-shm", name + "-wal"]
    }

    /// Every regular file and symbolic link under `folder`, with paths relative to it, sorted, leaving out the
    /// top-level items named in `excluding`. Links are listed, not followed.
    public static func listFiles(in folder: URL, excluding: Set<String> = []) -> [File] {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: Array(keys)) else { return [] }
        var files: [File] = []
        for case let url as URL in walker {
            let relative = relativePath(of: url, in: base)
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if walker.level == 1, excluding.contains(relative) {
                // skipDescendants after a file would skip the last folder seen instead.
                if values.isDirectory == true, values.isSymbolicLink != true { walker.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                files.append(File(path: relative, size: 0, link: target))
            } else if values.isRegularFile == true {
                files.append(File(path: relative, size: Int64(values.fileSize ?? 0)))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Bytes in the files under `folder` (what a move copies), leaving out the top-level items in `excluding`.
    public static func size(of folder: URL, excluding: Set<String> = []) -> Int64 {
        listFiles(in: folder, excluding: excluding).reduce(0) { $0 + $1.size }
    }

    private static func relativePath(of url: URL, in base: URL) -> String {
        let path = url.standardizedFileURL.path, root = base.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
    }

    private static func removeIfEmpty(_ folder: URL) {
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if left.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: folder) }
    }
}
