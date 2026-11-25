import Foundation

/// A Codable value kept in one JSON file: read whole, written whole and atomically, so a crash mid-write leaves the
/// last good file. Its folder is made on the first save. Safe from any thread; call it off the main thread for a
/// big value (a library of thousands of items takes tens of milliseconds to encode).
public struct JSONFile<Value: Codable>: Sendable {
    public enum Dates: Sendable, Equatable {
        /// "2026-11-24T21:30:00Z": readable, and what my apps write.
        case iso8601
        /// Foundation's default: seconds since 2001 as a number.
        case foundation
        case secondsSince1970
    }

    /// A file that couldn't be read as the value, or couldn't be read at all. With `setAsideDamaged`, it was renamed
    /// to `keptAt`, so the next save can't overwrite what the person had.
    public struct Damaged: Error, LocalizedError, Sendable {
        public enum Cause: Sendable, Equatable {
            /// The bytes were read but aren't the value: bad JSON, a missing key, a wrong type.
            case notTheValue
            /// The file couldn't be read at all: no permission, a folder in its place, a read error.
            case unreadable
        }

        public let url: URL
        public let keptAt: URL?
        public let reason: String
        public var cause: Cause = .notTheValue

        public var errorDescription: String? { reason }
    }

    public let url: URL
    public var dates: Dates
    /// Indented with sorted keys, so a diff of two versions is readable. False writes one compact line.
    public var pretty: Bool

    public init(_ url: URL, dates: Dates = .iso8601, pretty: Bool = true) {
        self.url = url
        self.dates = dates
        self.pretty = pretty
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The value, or nil when there is no file yet. Throws `Damaged` when the file can't be read as the value
    /// (`cause` `.notTheValue`) or can't be read at all (`.unreadable`: no permission, a folder in its place); with
    /// `setAsideDamaged` the file is first renamed to "<name> (damaged <date>).json" beside it, so the next save
    /// can't write over it.
    public func load(setAsideDamaged: Bool = false) throws -> Value? {
        guard exists || isLink else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw damaged(.unreadable, error, setAside: setAsideDamaged)
        }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw damaged(.notTheValue, error, setAside: setAsideDamaged)
        }
    }

    private var isLink: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil }

    private func damaged(_ cause: Damaged.Cause, _ error: any Error, setAside: Bool) -> Damaged {
        var kept: URL?
        if setAside {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
                .timeSeparator(.omitted).dateTimeSeparator(.space))
            let name = url.deletingPathExtension().lastPathComponent + " (damaged \(stamp))"
            let target = url.deletingLastPathComponent().appending(path: name).appendingPathExtension(url.pathExtension)
            if (try? FileManager.default.moveItem(at: url, to: target)) != nil { kept = target }
        }
        return Damaged(url: url, keptAt: kept, reason: Self.describe(error), cause: cause)
    }

    /// The value, or `fallback` when there is no file yet.
    public func load(or fallback: @autoclosure () -> Value, setAsideDamaged: Bool = false) throws -> Value {
        try load(setAsideDamaged: setAsideDamaged) ?? fallback()
    }

    /// Writes the value atomically, making the folder when needed.
    public func save(_ value: Value) throws {
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Deletes the file; nothing happens when there is none.
    public func remove() throws {
        guard exists else { return }
        try FileManager.default.removeItem(at: url)
    }

    public var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        switch dates {
        case .iso8601: encoder.dateEncodingStrategy = .iso8601
        case .foundation: encoder.dateEncodingStrategy = .deferredToDate
        case .secondsSince1970: encoder.dateEncodingStrategy = .secondsSince1970
        }
        return encoder
    }

    public var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        switch dates {
        case .iso8601: decoder.dateDecodingStrategy = .iso8601
        case .foundation: decoder.dateDecodingStrategy = .deferredToDate
        case .secondsSince1970: decoder.dateDecodingStrategy = .secondsSince1970
        }
        return decoder
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
