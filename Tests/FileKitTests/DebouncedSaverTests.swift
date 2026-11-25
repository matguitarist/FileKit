import Foundation
import os
import Testing
@testable import FileKit

/// Every value a saver wrote, in order, from any thread.
final class Saved: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [Int]())
    private let threads = OSAllocatedUnfairLock(initialState: [Bool]())
    func add(_ value: Int) {
        values.withLock { $0.append(value) }
        threads.withLock { $0.append(Thread.isMainThread) }
    }
    var all: [Int] { values.withLock { $0 } }
    var onMain: [Bool] { threads.withLock { $0 } }
}

struct Refused: Error {}

@MainActor
@Suite struct DebouncedSaverTests {
    @Test func aRunOfChangesIsSavedOnceWithTheLastValue() async throws {
        let saved = Saved()
        let saver = DebouncedSaver<Int>(delay: .milliseconds(80)) { saved.add($0) }
        for value in 1...10 { saver.schedule(value) }
        #expect(saver.hasPending)
        try await Task.sleep(for: .milliseconds(400))
        #expect(saved.all == [10])
        #expect(saved.onMain == [false])
        #expect(!saver.isBusy)
    }

    @Test func nothingIsSavedBeforeChangesSettle() async throws {
        let saved = Saved()
        let saver = DebouncedSaver<Int>(delay: .milliseconds(300)) { saved.add($0) }
        saver.schedule(1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(saved.all.isEmpty)
        await saver.flush()
        #expect(saved.all == [1])
    }

    @Test func flushSavesNowAndWaitsForEverySave() async {
        let saved = Saved()
        let saver = DebouncedSaver<Int>(delay: .seconds(60)) { value in
            try? await Task.sleep(for: .milliseconds(50))
            saved.add(value)
        }
        saver.schedule(1)
        await saver.flush()
        saver.schedule(2)
        await saver.flush()
        #expect(saved.all == [1, 2])
        await saver.flush()
        #expect(saved.all == [1, 2])
    }

    @Test func savesRunOneAtATimeInOrder() async {
        let saved = Saved()
        // The first save is slow; the second must still land after it.
        let saver = DebouncedSaver<Int>(delay: .milliseconds(1)) { value in
            if value == 1 { try? await Task.sleep(for: .milliseconds(200)) }
            saved.add(value)
        }
        saver.schedule(1)
        try? await Task.sleep(for: .milliseconds(50))
        saver.schedule(2)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(saver.isBusy)
        await saver.flush()
        #expect(saved.all == [1, 2])
    }

    @Test func maxWaitSavesWhileChangesKeepComing() async throws {
        let saved = Saved()
        let saver = DebouncedSaver<Int>(delay: .milliseconds(150), maxWait: .milliseconds(250)) { saved.add($0) }
        for value in 1...12 {
            saver.schedule(value)
            try await Task.sleep(for: .milliseconds(50))
        }
        // 600 ms of changes every 50 ms: never settled, yet saved along the way.
        #expect(!saved.all.isEmpty)
        await saver.flush()
        #expect(saved.all.last == 12)
        #expect(saved.all == saved.all.sorted())
    }

    @Test func takePendingHandsBackTheValueForAQuit() async throws {
        let saved = Saved()
        let saver = DebouncedSaver<Int>(delay: .milliseconds(50)) { saved.add($0) }
        saver.schedule(7)
        #expect(saver.takePending() == 7)
        #expect(saver.takePending() == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(saved.all.isEmpty)
        saver.schedule(8)
        saver.cancel()
        await saver.flush()
        #expect(saved.all.isEmpty)
    }

    @Test func aFailedSaveIsReportedOnTheMainActor() async {
        var errors: [String] = []
        let saver = DebouncedSaver<Int>(delay: .milliseconds(1), save: { _ in throw Refused() }) { error in
            MainActor.assertIsolated()
            errors.append("\(error)")
        }
        saver.schedule(1)
        await saver.flush()
        #expect(errors.count == 1)
    }

    @Test func savesAJSONFile() async throws {
        let s = try Scratch()
        defer { s.clean() }
        let file = JSONFile<[String]>(s.url("library.json"))
        let saver = DebouncedSaver(file, delay: .milliseconds(20))
        saver.schedule(["a"])
        saver.schedule(["a", "b"])
        await saver.flush()
        #expect(try file.load() == ["a", "b"])
    }
}
