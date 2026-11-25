import Foundation

/// A folder under the temporary directory, removed by `clean()`. Tests never touch anything else.
struct Scratch {
    let root: URL

    init(_ name: String = #function) throws {
        let safe = name.filter { $0.isLetter || $0.isNumber }
        root = FileManager.default.temporaryDirectory
            .appending(path: "FileKitTests-\(safe)-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ path: String) -> URL { root.appending(path: path) }

    @discardableResult
    func file(_ path: String, bytes: Int = 1, byte: UInt8 = 7) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: byte, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func link(_ path: String, to destination: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    func clean() {
        // Unlock anything a test locked, then remove it all.
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in walker {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: path).path)
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    static func allocated(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }
}
