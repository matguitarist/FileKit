import Foundation

/// Saves a value a moment after the last change, off the main thread, one save at a time and in order. Typing,
/// sliders and a run of changes in a row then cost one write instead of dozens.
///
/// ```swift
/// let saver = DebouncedSaver(JSONFile<[Game]>(url)) { error in notice = error.localizedDescription }
/// saver.schedule(games)          // after every change
/// await saver.flush()            // before reading the file again
/// try saver.finish()             // at quit, synchronously: no older save can land after it
/// ```
@MainActor
public final class DebouncedSaver<Value: Sendable> {
    public typealias Save = @Sendable (Value) async throws -> Void
    public typealias Write = @Sendable (Value) throws -> Void

    /// `finish` waited `timeout` and a save was still running, so it wrote nothing: writing now could let the older
    /// save land after the newest. The newest value is waiting again (`hasPending`, `takePending`).
    public struct StillSaving: Error, LocalizedError, Sendable {
        public var errorDescription: String? { "A save was still running" }
    }

    /// How long after the last change the value is saved.
    public let delay: Duration
    /// With changes that never settle, the longest a change waits. Nil waits for them to settle.
    public let maxWait: Duration?
    private let save: Save
    private let write: Write?
    private let failed: @MainActor (any Error) -> Void
    private let gate = SaveGate()

    private var pending: Value?
    private var waitingSince: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var lastSave: Task<Void, Never>?
    private var saving = 0
    private var nextTicket = 0
    private var latest: (ticket: Int, value: Value)?

    /// `save` runs off the main thread with the newest value. `failed` runs on the main actor with its error.
    public init(delay: Duration = .milliseconds(400), maxWait: Duration? = nil,
                save: @escaping Save, failed: @escaping @MainActor (any Error) -> Void = { _ in }) {
        self.delay = delay
        self.maxWait = maxWait
        self.save = save
        self.write = nil
        self.failed = failed
    }

    /// `write` is synchronous (a file, UserDefaults): saves run it off the main thread, and `finish()` runs it on the
    /// caller's thread at quit.
    public init(delay: Duration = .milliseconds(400), maxWait: Duration? = nil,
                write: @escaping Write, failed: @escaping @MainActor (any Error) -> Void = { _ in }) {
        self.delay = delay
        self.maxWait = maxWait
        self.save = { try write($0) }
        self.write = write
        self.failed = failed
    }

    /// Saves to a JSON file.
    public convenience init(_ file: JSONFile<Value>, delay: Duration = .milliseconds(400), maxWait: Duration? = nil,
                            failed: @escaping @MainActor (any Error) -> Void = { _ in }) where Value: Codable {
        self.init(delay: delay, maxWait: maxWait, write: { try file.save($0) }, failed: failed)
    }

    /// True while a value waits to be saved or a save runs.
    public var isBusy: Bool { pending != nil || saving > 0 }

    /// True while a value waits to be saved.
    public var hasPending: Bool { pending != nil }

    /// Saves `value` once changes settle; a newer value replaces one still waiting.
    public func schedule(_ value: Value) {
        pending = value
        let now = ContinuousClock.now
        if waitingSince == nil { waitingSince = now }
        var wait = delay
        if let maxWait, let waitingSince {
            wait = max(.zero, min(delay, waitingSince + maxWait - now))
        }
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.startSave()
        }
    }

    /// Saves the waiting value now, and returns once every save has finished.
    public func flush() async {
        startSave()
        await lastSave?.value
    }

    /// At quit, or before reading the file again from synchronous code: saves the newest value not yet saved now and
    /// returns once it is saved. A save already running is waited for first, and older saves that haven't started
    /// are dropped, so none can land after this one. With a `write` (or a `JSONFile`) the value is written on this
    /// thread; with an async `save`, it runs off it while this thread waits. Waits at most `timeout` for a save
    /// still running: past it, throws `StillSaving` and writes nothing. Throws the save's own error too.
    public func finish(timeout: Duration = .seconds(10)) throws {
        let deadline = Date.now.addingTimeInterval(timeout.seconds)
        var value = takePending()
        let begun = gate.close(below: nextTicket)
        if value == nil, let latest, latest.ticket > begun { value = latest.value }
        guard let value else {
            if !gate.waitIdle(until: deadline) { throw StillSaving() }
            return
        }
        guard gate.waitIdle(until: deadline) else {
            pending = value
            throw StillSaving()
        }
        latest = nil
        if let write {
            try write(value)
            return
        }
        let outcome = SaveOutcome()
        let save = self.save
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { try await save(value) } catch { outcome.set(error) }
            done.signal()
        }
        if done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut { throw StillSaving() }
        if let error = outcome.error { throw error }
    }

    /// The waiting value, taken so it won't be saved here. At quit, prefer `finish()`: a save already running could
    /// land after one the app makes with this value.
    public func takePending() -> Value? {
        timer?.cancel()
        timer = nil
        waitingSince = nil
        defer { pending = nil }
        return pending
    }

    /// Forgets the waiting value.
    public func cancel() {
        _ = takePending()
    }

    private func startSave() {
        guard let value = takePending() else { return }
        let previous = lastSave
        let save = self.save
        let gate = self.gate
        let ticket = nextTicket
        nextTicket += 1
        latest = (ticket, value)
        saving += 1
        lastSave = Task { [weak self] in
            await previous?.value
            do {
                try await Task.detached(priority: .utility) {
                    // A save that `finish` overtook doesn't run: the newest value is already saved.
                    guard gate.begin(ticket) else { return }
                    defer { gate.end() }
                    try await save(value)
                }.value
            } catch {
                self?.failed(error)
            }
            self?.saving -= 1
        }
    }
}

/// Which saves may still start, and whether one is running; read from any thread, so `finish` can wait for it.
final class SaveGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var floor = 0
    private var running = 0
    private var lastBegun = -1

    /// False when `finish` closed the gate on this save.
    func begin(_ ticket: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard ticket >= floor else { return false }
        running += 1
        lastBegun = max(lastBegun, ticket)
        return true
    }

    func end() {
        condition.lock()
        running -= 1
        condition.broadcast()
        condition.unlock()
    }

    /// Saves with a ticket below `ticket` won't start; returns the newest ticket that did.
    func close(below ticket: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        floor = max(floor, ticket)
        return lastBegun
    }

    /// False when a save still runs at `deadline`.
    func waitIdle(until deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while running > 0 {
            if !condition.wait(until: deadline) { return running == 0 }
        }
        return true
    }
}

private final class SaveOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?
    func set(_ error: any Error) { lock.withLock { stored = error } }
    var error: (any Error)? { lock.withLock { stored } }
}

extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
