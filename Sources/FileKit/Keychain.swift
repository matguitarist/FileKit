import Foundation
import os
import Security

/// Secrets in the Keychain (API keys, tokens, passwords), as generic passwords under one service, one item per
/// account. `Keychain.inMemory(service:)` keeps them in memory instead, for tests and test runs that must never touch
/// the person's Keychain. Safe from any thread.
///
/// ```swift
/// let keychain = Keychain(service: "com.mathieuares.hangar")
/// try keychain.set(token, for: "steam")     // nil or "" removes it
/// let token = keychain.string(for: "steam")
/// ```
public struct Keychain: Sendable, Equatable {
    /// When the item can be read (`kSecAttrAccessible`). Nil leaves the system's default (when unlocked).
    public enum Accessible: Sendable, Equatable {
        case whenUnlocked, whenUnlockedThisDeviceOnly
        /// For a background sync that runs while the screen is locked.
        case afterFirstUnlock, afterFirstUnlockThisDeviceOnly

        var value: CFString {
            switch self {
            case .whenUnlocked: kSecAttrAccessibleWhenUnlocked
            case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
            case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    /// The Keychain said no; `status` is its OSStatus.
    public struct Failure: Error, LocalizedError, Equatable, Sendable {
        public let status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    public let service: String
    /// The name Keychain Access shows (`kSecAttrLabel`); nil shows the service.
    public var label: String?
    public var accessible: Accessible?
    /// Shared through iCloud Keychain. Needs the data protection keychain, so an app signed with a team.
    public var synchronizable: Bool
    /// A keychain access group shared by several apps of one team; on the Mac it uses the data protection keychain.
    public var accessGroup: String?
    private let inMemory: Bool

    public init(service: String, label: String? = nil, accessible: Accessible? = nil, synchronizable: Bool = false,
                accessGroup: String? = nil) {
        self.service = service
        self.label = label
        self.accessible = accessible
        self.synchronizable = synchronizable
        self.accessGroup = accessGroup
        self.inMemory = false
    }

    private init(memoryService: String) {
        service = memoryService
        synchronizable = false
        inMemory = true
    }

    /// The same calls on a store in memory, shared by every `Keychain` of that service in this process.
    public static func inMemory(service: String) -> Keychain { Keychain(memoryService: service) }

    // MARK: Strings

    /// The secret as text, nil when there is none (or the Keychain is locked or said no).
    public func string(for account: String?) -> String? {
        data(for: account).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Stores `value`, replacing the old one. Nil or an empty string removes the item.
    public func set(_ value: String?, for account: String?) throws {
        guard let value, !value.isEmpty else { return try remove(account) }
        try set(Data(value.utf8), for: account)
    }

    // MARK: Data

    /// The secret's bytes, nil when there is none.
    public func data(for account: String?) -> Data? {
        if inMemory { return Self.memory.withLock { $0[service]?[account ?? ""] } }
        var search = query(account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Stores `data`, replacing the old one and keeping the item (so its access list stays). Nil removes the item.
    public func set(_ data: Data?, for account: String?) throws {
        guard let data else { return try remove(account) }
        if inMemory { Self.memory.withLock { $0[service, default: [:]][account ?? ""] = data }; return }
        var changes = attributes
        changes[kSecValueData as String] = data
        let status = SecItemUpdate(query(account) as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var item = query(account).merging(changes) { _, new in new }
        item[kSecValueData as String] = data
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    // MARK: Items

    /// True when there is a secret for the account.
    public func contains(_ account: String?) -> Bool { data(for: account) != nil }

    /// Removes the account's secret; nothing happens when there is none. A nil account removes every item of the service.
    public func remove(_ account: String?) throws {
        if inMemory {
            Self.memory.withLock { store in
                if let account { store[service]?[account] = nil } else { store[service] = nil }
            }
            return
        }
        // The Mac's login keychain deletes one matching item per call.
        for _ in 0..<10_000 {
            let status = SecItemDelete(query(account) as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw Failure(status: status) }
        }
    }

    /// Moves a secret saved under another service (an app's old name) to this one. True when there was one.
    /// Reading another app's item can make macOS ask the person; an app tries it once.
    @discardableResult
    public func adopt(_ account: String?, from old: Keychain) throws -> Bool {
        guard let data = old.data(for: account) else { return false }
        try set(data, for: account)
        try? old.remove(account)
        return true
    }

    // MARK: Queries

    /// What finds the item: class, service, account, and where it lives.
    func query(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        if synchronizable { query[kSecAttrSynchronizable as String] = true }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            #if os(macOS)
            query[kSecUseDataProtectionKeychain as String] = true
            #endif
        }
        #if os(macOS)
        if synchronizable { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    /// What is written with the secret.
    var attributes: [String: Any] {
        var attributes: [String: Any] = [:]
        if let label { attributes[kSecAttrLabel as String] = label }
        if let accessible { attributes[kSecAttrAccessible as String] = accessible.value }
        return attributes
    }

    private static let memory = OSAllocatedUnfairLock(initialState: [String: [String: Data]]())

    public static func == (a: Keychain, b: Keychain) -> Bool {
        a.service == b.service && a.label == b.label && a.accessible == b.accessible && a.synchronizable == b.synchronizable
            && a.accessGroup == b.accessGroup && a.inMemory == b.inMemory
    }
}
