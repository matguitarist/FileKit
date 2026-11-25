import Foundation
import Testing
@testable import FileKit

@Suite struct FileCloneTests {
    @Test func clonesAFolderOnOneDisk() throws {
        let s = try Scratch()
        defer { s.clean() }
        try s.file("game/game/script.rpy", bytes: 2_000)
        try s.file("game/renpy/a.py", bytes: 30)
        try s.link("game/current", to: "game")
        let copy = s.url("copies/one/game")
        #expect(try FileClone.clone(s.url("game"), to: copy) == .cloned)
        #expect(FolderMove.listFiles(in: copy) == FolderMove.listFiles(in: s.url("game")))
        // Writing to the clone leaves the original as it was.
        try Data("changed".utf8).write(to: copy.appending(path: "game/script.rpy"))
        #expect(try Data(contentsOf: s.url("game/game/script.rpy")).count == 2_000)
    }

    @Test func clonesAFile() throws {
        let s = try Scratch()
        defer { s.clean() }
        let file = try s.file("a.bin", bytes: 64)
        #expect(try FileClone.clone(file, to: s.url("b.bin")) == .cloned)
        #expect(try Data(contentsOf: s.url("b.bin")).count == 64)
    }

    @Test func refusesATargetThatExists() throws {
        let s = try Scratch()
        defer { s.clean() }
        try s.file("a/x.txt")
        let busy = try s.file("b/x.txt", bytes: 5)
        #expect(throws: FileClone.Failure.targetExists(s.url("b").path)) { try FileClone.clone(s.url("a"), to: s.url("b")) }
        #expect(throws: FileClone.Failure.targetExists(s.url("b").path)) { try FileClone.copy(s.url("a"), to: s.url("b")) }
        // Nothing of the person's is removed.
        #expect(try Data(contentsOf: busy).count == 5)
    }

    @Test func copyKeepsLinksFoldersAndPermissions() throws {
        let s = try Scratch()
        defer { s.clean() }
        let tool = try s.file("src/bin/tool", bytes: 100)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try s.folder("src/empty")
        try s.link("src/latest", to: "bin/tool")
        try s.file("src/.hidden", bytes: 3)
        var sizes: [Int64] = []
        try FileClone.copy(s.url("src"), to: s.url("dst"), copied: { sizes.append($0) })
        #expect(sizes.sorted() == [3, 100])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.url("dst/latest").path) == "bin/tool")
        #expect(FileManager.default.fileExists(atPath: s.url("dst/empty").path))
        let mode = try FileManager.default.attributesOfItem(atPath: s.url("dst/bin/tool").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(FolderMove.listFiles(in: s.url("dst")) == FolderMove.listFiles(in: s.url("src")))
    }

    @Test func aStoppedCopyLeavesNothingBehind() throws {
        let s = try Scratch()
        defer { s.clean() }
        for index in 0..<20 { try s.file("src/f\(index)", bytes: 10) }
        var count = 0
        #expect(throws: CancellationError.self) {
            try FileClone.copy(s.url("src"), to: s.url("dst"), stop: { count += 1; return count > 5 })
        }
        #expect(!FileManager.default.fileExists(atPath: s.url("dst").path))
        #expect(FolderMove.listFiles(in: s.url("src")).count == 20)
    }

    @Test func aFailedCopyLeavesNothingBehind() throws {
        let s = try Scratch()
        defer { s.clean() }
        try s.file("src/a.txt")
        let unreadable = try s.file("src/z.txt", bytes: 4)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        #expect(throws: (any Error).self) { try FileClone.copy(s.url("src"), to: s.url("dst")) }
        #expect(!FileManager.default.fileExists(atPath: s.url("dst").path))
    }

    @Test func aMissingSourceThrows() throws {
        let s = try Scratch()
        defer { s.clean() }
        #expect(throws: (any Error).self) { try FileClone.clone(s.url("nothing"), to: s.url("copy")) }
        #expect(!FileManager.default.fileExists(atPath: s.url("copy").path))
    }

    @Test func sameVolumeReadsFoldersThatDontExistYet() throws {
        let s = try Scratch()
        defer { s.clean() }
        #expect(FileClone.sameVolume(s.root, s.url("not/yet/there")))
        #expect(FileClone.sameVolume(s.root, FileManager.default.temporaryDirectory))
    }

    @Test func failuresReadWellInALog() {
        #expect(FileClone.Failure.targetExists("/x/y").description == "Already exists: /x/y")
        #expect(FileClone.Failure.cannotClone(.EXDEV).reason == "Cross-device link")
        #expect(FileClone.Failure.cannotClone(.EXDEV).localizedDescription == "Can't clone: Cross-device link")
        #expect("\(FileClone.Failure.cannotClone(.ENOTSUP))" == "Can't clone: Operation not supported")
    }
}
