import Foundation
import os
import Testing
@testable import FileKit

/// Both ways a move goes: renames on one disk, and copy, check, delete (forced here with `alwaysCopy`, since a
/// test has one disk). Set MOVE_VOLUME=/Volumes/<disk> to also run a real move to another disk.
@Suite struct FolderMoveTests {
    let fm = FileManager.default
    static let database: Set<String> = ["App.store", "App.store-shm", "App.store-wal"]

    /// A data folder like the launchers': profiles with a link, downloads, an empty folder, and the database.
    func makeData(_ s: Scratch) throws -> URL {
        try s.file("App/Profiles/A/game/supermetroid", bytes: 5_000)
        try s.file("App/Profiles/A/game/saves/sram.srm", bytes: 4)
        try s.file("App/Downloads/0.4.6/game.zip", bytes: 3)
        try s.folder("App/Logs")
        try s.link("App/Profiles/A/game/current", to: "saves")
        try s.file("App/App.store", bytes: 2)
        return s.url("App")
    }

    func move(_ source: URL, into parent: URL, keeping: Set<String> = [], copying: Bool,
              progress: (@Sendable (Int64, Int64) -> Void)? = nil) throws(FolderMove.Failure) -> URL {
        try FolderMove.move(source, into: parent, keeping: keeping, alwaysCopy: copying, progress: progress)
    }

    @Test(arguments: [false, true])
    func movesEverythingAndRemovesTheOldFolder(copying: Bool) throws {
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        try fm.removeItem(at: data.appending(path: "App.store"))
        let before = FolderMove.listFiles(in: data)
        let target = try s.folder("External")
        let moved = try move(data, into: target, copying: copying)
        #expect(moved.lastPathComponent == "App")
        #expect(FolderMove.listFiles(in: moved) == before)
        #expect(!fm.fileExists(atPath: data.path))
        #expect(FolderMove.size(of: moved) == 5_000 + 4 + 3)
        #expect(try fm.destinationOfSymbolicLink(atPath: moved.appending(path: "Profiles/A/game/current").path) == "saves")
        // Nothing of ours is left beside it.
        #expect(try fm.contentsOfDirectory(atPath: target.path) == ["App"])
    }

    @Test(arguments: [false, true])
    func leavesTheDatabaseAndMovesBackIntoItsFolder(copying: Bool) throws {
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        let before = FolderMove.listFiles(in: data)
        let target = try s.folder("External")
        let moved = try move(data, into: target, keeping: Self.database, copying: copying)
        #expect(!fm.fileExists(atPath: moved.appending(path: "App.store").path))
        #expect(try fm.contentsOfDirectory(atPath: data.path) == ["App.store"])
        #expect(FolderMove.size(of: data, excluding: Self.database) == 0)
        let back = try move(moved, into: s.root, keeping: Self.database, copying: copying)
        #expect(back.path == data.path)
        #expect(FolderMove.listFiles(in: back) == before)
        #expect(!fm.fileExists(atPath: moved.path))
    }

    @Test func progressReachesTheTotal() throws {
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        let seen = OSAllocatedUnfairLock(initialState: [Int64]())
        let moved = try move(data, into: try s.folder("External"), keeping: Self.database, copying: true) { done, total in
            #expect(total == 5_007)
            seen.withLock { $0.append(done) }
        }
        let steps = seen.withLock { $0 }
        #expect(steps.first == 0)
        #expect(steps.last == 5_007)
        #expect(steps == steps.sorted())
        #expect(fm.fileExists(atPath: moved.path))
    }

    @Test func refusesAFolderThatAlreadyHasTheData() throws {
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        try s.folder("Busy/App/Profiles")
        let before = FolderMove.listFiles(in: data)
        #expect(throws: FolderMove.Failure.destinationExists("App/Profiles")) {
            try FolderMove.move(data, into: s.url("Busy"), keeping: Self.database)
        }
        #expect(FolderMove.listFiles(in: data) == before)
    }

    @Test func refusesAFileWithTheFolderName() throws {
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        try s.file("Busy/App")
        #expect(throws: FolderMove.Failure.destinationExists("App")) { try FolderMove.move(data, into: s.url("Busy")) }
    }

    @Test func refusesAFolderInsideItself() throws {
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        #expect(throws: FolderMove.Failure.insideItself) { try FolderMove.move(data, into: data.appending(path: "Profiles")) }
        #expect(throws: FolderMove.Failure.insideItself) { try FolderMove.move(data, into: data) }
    }

    @Test func movingIntoItsOwnParentDoesNothing() throws {
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        let before = FolderMove.listFiles(in: data)
        #expect(try FolderMove.move(data, into: s.root).path == data.path)
        #expect(FolderMove.listFiles(in: data) == before)
    }

    /// A rename that can't happen on one disk is undone, and the old folder stays as it was.
    @Test func aFailedRenameLeavesTheOldFolderIntact() throws {
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        let before = FolderMove.listFiles(in: data)
        let target = try s.folder("Locked")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: data.path)
        #expect(throws: FolderMove.Failure.self) { try move(data, into: target, keeping: Self.database, copying: false) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
        #expect(FolderMove.listFiles(in: data) == before)
        #expect(!fm.fileExists(atPath: target.appending(path: "App").path))
    }

    /// A file that can't be read stops the copy; nothing is left at the destination.
    @Test func aFailedCopyLeavesTheOldFolderIntact() throws {
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        let unreadable = data.appending(path: "Downloads/0.4.6/game.zip")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        let before = FolderMove.listFiles(in: data)
        let target = try s.folder("External")
        #expect(throws: FolderMove.Failure.self) { try move(data, into: target, copying: true) }
        #expect(FolderMove.listFiles(in: data) == before)
        #expect(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func aStagingFolderOfThePersonsIsNeverTouched() throws {
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        let mine = try s.file("External/App.partial/notes.txt", bytes: 11)
        _ = try move(data, into: s.url("External"), copying: true)
        #expect(try Data(contentsOf: mine).count == 11)
    }

    @Test func databaseFilesOnlyWhenTheStoreIsInTheFolder() throws {
        let s = try Scratch()
        defer { s.clean() }
        let folder = try s.folder("Data")
        #expect(FolderMove.databaseFiles(store: folder.appending(path: "App.store"), in: folder) == Self.database)
        // Through /tmp and /private/tmp, the same folder.
        let spelled = URL(filePath: folder.path + "/./App.store")
        #expect(FolderMove.databaseFiles(store: spelled, in: folder) == Self.database)
        #expect(FolderMove.databaseFiles(store: s.url("Elsewhere/App.store"), in: folder).isEmpty)
    }

    @Test func listFilesLeavesOutExcludedFoldersOnly() throws {
        let s = try Scratch()
        defer { s.clean() }
        try s.file("a/Cache/x", bytes: 1)
        try s.file("a/Cache.txt", bytes: 2)
        try s.file("a/b/Cache/y", bytes: 3)
        let files = FolderMove.listFiles(in: s.url("a"), excluding: ["Cache"]).map(\.path)
        #expect(files == ["Cache.txt", "b/Cache/y"])
    }

    @Test func movesToAnotherDisk() throws {
        guard let volume = ProcessInfo.processInfo.environment["MOVE_VOLUME"] else { return }
        let s = try Scratch()
        defer { s.clean() }
        let data = try makeData(s)
        let target = URL(filePath: volume).appending(path: "FileKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: target) }
        let before = FolderMove.listFiles(in: data)
        let moved = try FolderMove.move(data, into: target)
        #expect(FolderMove.listFiles(in: moved) == before)
        #expect(!fm.fileExists(atPath: data.path))
    }
}
