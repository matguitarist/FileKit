import Foundation

/// Saves a value a moment after the last change, off the main thread, one save at a time and in order. Typing,
/// sliders and a run of changes in a row then cost one write instead of dozens.
///
/// ```swift
/// let saver = DebouncedSaver(JSONFile<[Game]>(url)) { error in notice = error.localizedDescription }
/// saver.schedule(games)          // after every change
/// await saver.flush()            // before reading the file again
/// if let last = saver.takePending() { try? file.save(last) }   // at quit, synchronously
/// ```
@MainActor
public final class DebouncedSaver<Value: Sendable> {
    public typealias Save = @Sendable (Value) async throws -> Void

    /// How long after the last change the value is saved.
    public let delay: Duration
    /// With changes that never settle, the longest a change waits. Nil waits for them to settle.
    public let maxWait: Duration?
    private let save: Save
    private let failed: @MainActor (any Error) -> Void

    private var pending: Value?
    private var waitingSince: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var lastSave: Task<Void, Never>?
    private var saving = 0

    /// `save` runs off the main thread with the newest value. `failed` runs on the main actor with its error.
    public init(delay: Duration = .milliseconds(400), maxWait: Duration? = nil,
                save: @escaping Save, failed: @escaping @MainActor (any Error) -> Void = { _ in }) {
        self.delay = delay
        self.maxWait = maxWait
        self.save = save
        self.failed = failed
    }

    /// Saves to a JSON file.
    public convenience init(_ file: JSONFile<Value>, delay: Duration = .milliseconds(400), maxWait: Duration? = nil,
                            failed: @escaping @MainActor (any Error) -> Void = { _ in }) where Value: Codable {
        self.init(delay: delay, maxWait: maxWait, save: { try file.save($0) }, failed: failed)
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

    /// The waiting value, taken so it won't be saved here: for saving synchronously when the app quits.
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
        saving += 1
        lastSave = Task { [weak self] in
            await previous?.value
            do {
                try await Task.detached(priority: .utility) { try await save(value) }.value
            } catch {
                self?.failed(error)
            }
            self?.saving -= 1
        }
    }
}
