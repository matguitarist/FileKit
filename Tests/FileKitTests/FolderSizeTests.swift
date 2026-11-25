import Foundation
import Testing
@testable import FileKit

@Suite struct FolderSizeTests {
    @Test func allocatedSizeCountsHiddenFilesAtEveryDepth() async throws {
        let s = try Scratch()
        defer { s.clean() }
        let small = try s.file("a.txt")
        let big = try s.file("inner/deeper/b.bin", bytes: 100_000)
        let hidden = try s.file("inner/.hidden", bytes: 5_000)
        let expected = Scratch.allocated(small) + Scratch.allocated(big) + Scratch.allocated(hidden)
        #expect(expected >= 105_001)
        #expect(await FolderSize.allocated(of: s.root) == expected)
        #expect(await FolderSize.logical(of: s.root) == 105_001)
    }

    @Test func hardLinksCountOnce() async throws {
        let s = try Scratch()
        defer { s.clean() }
        let photo = try s.file("inner/photo.raw", bytes: 200_000)
        let before = try await FolderSize.measure(s.root)
        try FileManager.default.linkItem(at: photo, to: s.url("inner/same photo.raw"))
        try FileManager.default.linkItem(at: photo, to: s.url("again.raw"))
        let after = try await FolderSize.measure(s.root)
        #expect(after.allocated == before.allocated)
        #expect(after.logical == 200_000)
        #expect(after.files == 1)
        #expect(after.items == before.items + 2)
    }

    @Test func symbolicLinksAreNotFollowed() async throws {
        let s = try Scratch()
        defer { s.clean() }
        try s.file("outside/big.bin", bytes: 300_000)
        try s.file("data/a.txt", bytes: 10)
        try s.link("data/link", to: s.url("outside").path)
        try s.link("data/file-link", to: s.url("outside/big.bin").path)
        let summary = try FolderSize.summary(of: s.url("data"))
        #expect(summary.logical == 10)
        #expect(summary.files == 1)
        #expect(summary.items == 3)
        #expect(await FolderSize.logical(of: s.url("data/link")) == 0)
    }

    @Test func aSingleFileHasItsOwnSize() async throws {
        let s = try Scratch()
        defer { s.clean() }
        let file = try s.file("one.bin", bytes: 12_345)
        let summary = try await FolderSize.measure(file)
        #expect(summary.logical == 12_345)
        #expect(summary.allocated == Scratch.allocated(file))
        #expect(summary.files == 1)
        #expect(summary.items == 0)
    }

    @Test func itemsCountEveryEntryInside() throws {
        let s = try Scratch()
        defer { s.clean() }
        try s.file("a.txt")
        try s.file("inner/deeper/b.txt")
        try s.file("inner/.hidden")
        try s.folder("empty")
        // inner, inner/deeper, empty, three files
        let summary = try FolderSize.summary(of: s.root)
        #expect(summary.items == 6)
        #expect(summary.files == 3)
    }

    @Test func excludedTopLevelItemsAreLeftOut() throws {
        let s = try Scratch()
        defer { s.clean() }
        try s.file("Profiles/a/save.srm", bytes: 4)
        try s.file("Library.store", bytes: 1_000)
        try s.file("Library.store-wal", bytes: 500)
        try s.file("Cache/Library.store", bytes: 7)
        let summary = try FolderSize.summary(of: s.root, options: .init(excluding: ["Library.store", "Library.store-wal", "Profiles"]))
        #expect(summary.logical == 7)
    }

    @Test func skippedFoldersAreLeftOutWithEverythingInThem() throws {
        let s = try Scratch()
        defer { s.clean() }
        try s.file("Library/Containers/other.app/big.bin", bytes: 50_000)
        try s.file("Library/Preferences/mine.plist", bytes: 20)
        // Spelled through /tmp-style links or not, the same folder is skipped.
        let skip = URL(filePath: s.root.path + "/Library/./Containers")
        let summary = try FolderSize.summary(of: s.root, options: .init(skipping: [skip]))
        #expect(summary.logical == 20)
    }

    @Test func otherAppsDataIsInTheHomeLibrary() {
        let paths = FolderSize.otherAppsData.map(\.path)
        #expect(paths.contains { $0.hasSuffix("/Library/Containers") })
        #expect(paths.contains { $0.hasSuffix("/Library/Group Containers") })
    }

    @Test func aFolderThatCantBeReadHasNoSize() async throws {
        let s = try Scratch()
        defer { s.clean() }
        let locked = try s.folder("locked")
        try s.file("locked/a.txt", bytes: 9)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(throws: FolderSize.Failure.unreadable) { try FolderSize.summary(of: locked) }
        await #expect(throws: FolderSize.Failure.unreadable) { try await FolderSize.measure(locked) }
        #expect(await FolderSize.allocated(of: locked) == 0)
        #expect(throws: FolderSize.Failure.unreadable) { try FolderSize.summary(of: s.url("missing")) }
    }

    @Test func anUnreadableFolderInsideIsSkipped() throws {
        let s = try Scratch()
        defer { s.clean() }
        try s.file("ok.txt", bytes: 3)
        let locked = try s.folder("locked")
        try s.file("locked/a.txt", bytes: 9)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(try FolderSize.summary(of: s.root).logical == 3)
    }

    @Test func measuringStopsWhenCancelled() async throws {
        let s = try Scratch()
        defer { s.clean() }
        for index in 0..<3_000 { try s.file("inner/f\(index)") }
        let task = Task.detached { try FolderSize.summary(of: s.root) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let outer = Task { try await FolderSize.measure(s.root) }
        outer.cancel()
        await #expect(throws: CancellationError.self) { try await outer.value }
    }

    @Test func staysOnVolumeKeepsEverythingOnOneDisk() throws {
        let s = try Scratch()
        defer { s.clean() }
        try s.file("a.bin", bytes: 1_000)
        // One disk here: the option changes nothing.
        let summary = try FolderSize.summary(of: s.root, options: .init(staysOnVolume: true))
        #expect(summary.logical == 1_000)
    }
}
