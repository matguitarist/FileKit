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

// One at a time: `finish` blocks the main actor while it waits, which would throw off the other tests' timing.
@MainActor
@Suite(.serialized) struct DebouncedSaverTests {
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

    @Test func finishWaitsForASaveRunningSoNoOlderOneLandsAfter() async throws {
        let s = try Scratch()
        defer { s.clean() }
        let url = s.url("library.json")
        let saved = Saved()
        // The first write is slow, as a big library on a slow disk: the final one must still land last.
        let saver = DebouncedSaver<Int>(delay: .milliseconds(1), write: { value in
            if value == 1 { Thread.sleep(forTimeInterval: 0.3) }
            try JSONFile<Int>(url).save(value)
            saved.add(value)
        })
        saver.schedule(1)
        try await Task.sleep(for: .milliseconds(80))
        saver.schedule(2)
        try saver.finish()
        #expect(saved.all == [1, 2])
        #expect(saved.onMain == [false, true])
        try await Task.sleep(for: .milliseconds(400))
        #expect(saved.all == [1, 2])
        #expect(try JSONFile<Int>(url).load() == 2)
        #expect(!saver.isBusy)
    }

    @Test func finishWritesAValueQueuedBehindARunningSaveAndDropsTheQueuedSave() async throws {
        let saved = Saved()
        let saver = DebouncedSaver<Int>(delay: .milliseconds(1), write: { value in
            if value == 1 { Thread.sleep(forTimeInterval: 0.3) }
            saved.add(value)
        })
        saver.schedule(1)
        try await Task.sleep(for: .milliseconds(80))
        saver.schedule(2)
        try await Task.sleep(for: .milliseconds(80))
        // 2 waits behind 1, not started: finish writes it, and its own save never runs.
        #expect(!saver.hasPending)
        try saver.finish()
        try await Task.sleep(for: .milliseconds(400))
        #expect(saved.all == [1, 2])
    }

    @Test func finishWithNothingWaitingWritesNothing() async throws {
        let saved = Saved()
        let saver = DebouncedSaver<Int>(delay: .milliseconds(1), write: { saved.add($0) })
        try saver.finish()
        saver.schedule(1)
        await saver.flush()
        try saver.finish()
        #expect(saved.all == [1])
    }

    @Test func finishRunsAnAsyncSaveAndWaitsForIt() async throws {
        let saved = Saved()
        let saver = DebouncedSaver<Int>(delay: .seconds(60)) { value in
            try? await Task.sleep(for: .milliseconds(50))
            saved.add(value)
        }
        saver.schedule(3)
        try saver.finish()
        #expect(saved.all == [3])
    }

    @Test func finishGivesUpOnASaveThatRunsTooLongAndKeepsTheValue() async throws {
        let saved = Saved()
        let saver = DebouncedSaver<Int>(delay: .milliseconds(1), write: { value in
            if value == 1 { Thread.sleep(forTimeInterval: 0.5) }
            saved.add(value)
        })
        saver.schedule(1)
        try await Task.sleep(for: .milliseconds(80))
        saver.schedule(2)
        #expect(throws: DebouncedSaver<Int>.StillSaving.self) { try saver.finish(timeout: .milliseconds(50)) }
        #expect(saver.hasPending)
        await saver.flush()
        #expect(saved.all == [1, 2])
    }

    @Test func finishReportsAFailedWrite() throws {
        let saver = DebouncedSaver<Int>(delay: .seconds(60), write: { _ in throw Refused() })
        saver.schedule(1)
        #expect(throws: Refused.self) { try saver.finish() }
    }

    @Test func finishSavesAJSONFile() throws {
        let s = try Scratch()
        defer { s.clean() }
        let file = JSONFile<[String]>(s.url("library.json"))
        let saver = DebouncedSaver(file, delay: .seconds(60))
        saver.schedule(["a"])
        try saver.finish()
        #expect(try file.load() == ["a"])
    }
}
