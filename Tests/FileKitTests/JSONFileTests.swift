import Foundation
import Testing
@testable import FileKit

struct Library: Codable, Equatable, Sendable {
    var games: [String]
    var added: Date
}

@Suite struct JSONFileTests {
    let sample = Library(games: ["Katawa Shoujo", "Doki Doki"], added: Date(timeIntervalSince1970: 1_700_000_000))

    @Test func savesAndLoadsMakingTheFolder() throws {
        let s = try Scratch()
        defer { s.clean() }
        let file = JSONFile<Library>(s.url("deep/folder/library.json"))
        #expect(try file.load() == nil)
        #expect(try file.load(or: Library(games: [], added: .distantPast)).games.isEmpty)
        try file.save(sample)
        #expect(file.exists)
        #expect(try file.load() == sample)
    }

    @Test func writesReadableISODatesWithSortedKeys() throws {
        let s = try Scratch()
        defer { s.clean() }
        let file = JSONFile<Library>(s.url("library.json"))
        try file.save(sample)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("\"2023-11-14T22:13:20Z\""))
        #expect(text.firstRange(of: "added")!.lowerBound < text.firstRange(of: "games")!.lowerBound)
        #expect(text.contains("\n"))
    }

    @Test func otherDateStylesAndCompactFiles() throws {
        let s = try Scratch()
        defer { s.clean() }
        let file = JSONFile<Library>(s.url("library.json"), dates: .secondsSince1970, pretty: false)
        try file.save(sample)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("1700000000"))
        #expect(!text.contains("\n"))
        #expect(try file.load() == sample)
        let foundation = JSONFile<Library>(s.url("f.json"), dates: .foundation)
        try foundation.save(sample)
        #expect(try foundation.load() == sample)
        // What JSONEncoder() writes with no settings reads back the same.
        try JSONEncoder().encode(sample).write(to: s.url("plain.json"))
        #expect(try JSONFile<Library>(s.url("plain.json"), dates: .foundation).load() == sample)
    }

    @Test func aDamagedFileThrowsAndStaysWhereItIs() throws {
        let s = try Scratch()
        defer { s.clean() }
        let file = JSONFile<Library>(s.url("library.json"))
        try Data("{\"games\": [1, 2]".utf8).write(to: file.url)
        #expect(throws: JSONFile<Library>.Damaged.self) { try file.load() }
        #expect(file.exists)
    }

    @Test func aDamagedFileCanBeSetAsideSoASaveCantEraseIt() throws {
        let s = try Scratch()
        defer { s.clean() }
        let file = JSONFile<Library>(s.url("library.json"))
        try Data("{\"games\": \"not a list\", \"added\": \"2023-11-14T22:13:20Z\"}".utf8).write(to: file.url)
        do {
            _ = try file.load(setAsideDamaged: true)
            Issue.record("a damaged file loaded")
        } catch let damaged as JSONFile<Library>.Damaged {
            #expect(damaged.reason.contains("games"))
            let kept = try #require(damaged.keptAt)
            #expect(kept.lastPathComponent.hasPrefix("library (damaged "))
            #expect(kept.pathExtension == "json")
            #expect(try String(contentsOf: kept, encoding: .utf8).contains("not a list"))
        }
        #expect(!file.exists)
        #expect(try file.load() == nil)
    }

    @Test func aSaveReplacesTheWholeFile() throws {
        let s = try Scratch()
        defer { s.clean() }
        let file = JSONFile<[String]>(s.url("list.json"))
        try file.save(Array(repeating: "a long line of text", count: 500))
        try file.save(["short"])
        #expect(try file.load() == ["short"])
        // Atomic: no temporary file is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.root.path) == ["list.json"])
        try file.remove()
        try file.remove()
        #expect(!file.exists)
    }
}
