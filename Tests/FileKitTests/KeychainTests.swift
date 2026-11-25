import Foundation
import Security
import Testing
@testable import FileKit

/// The real Keychain, under a service of its own that is removed after each test.
@Suite(.serialized) struct KeychainTests {
    static func service() -> String { "FileKitTests.\(UUID().uuidString)" }

    @Test func storesReadsReplacesAndRemovesAString() throws {
        let keychain = Keychain(service: Self.service(), label: "FileKit test")
        defer { try? keychain.remove(nil) }
        #expect(keychain.string(for: "api-key") == nil)
        try keychain.set("first", for: "api-key")
        #expect(keychain.string(for: "api-key") == "first")
        try keychain.set("second ✓", for: "api-key")
        #expect(keychain.string(for: "api-key") == "second ✓")
        #expect(keychain.contains("api-key"))
        try keychain.remove("api-key")
        #expect(keychain.string(for: "api-key") == nil)
        try keychain.remove("api-key")
    }

    @Test func nilOrAnEmptyStringRemoves() throws {
        let keychain = Keychain(service: Self.service())
        defer { try? keychain.remove(nil) }
        try keychain.set("x", for: "a")
        try keychain.set("", for: "a")
        #expect(!keychain.contains("a"))
        try keychain.set("x", for: "a")
        try keychain.set(nil as String?, for: "a")
        #expect(!keychain.contains("a"))
    }

    @Test func storesData() throws {
        let keychain = Keychain(service: Self.service(), accessible: .afterFirstUnlock)
        defer { try? keychain.remove(nil) }
        let key = Data((0..<32).map { UInt8($0) })
        try keychain.set(key, for: "sync-key")
        #expect(keychain.data(for: "sync-key") == key)
        try keychain.set(Data([1]), for: "sync-key")
        #expect(keychain.data(for: "sync-key") == Data([1]))
        try keychain.set(nil as Data?, for: "sync-key")
        #expect(keychain.data(for: "sync-key") == nil)
    }

    @Test func accountsAreApartAndANilAccountMeansTheWholeService() throws {
        let keychain = Keychain(service: Self.service())
        defer { try? keychain.remove(nil) }
        try keychain.set("one", for: "token-A")
        try keychain.set("two", for: "token-B")
        #expect(keychain.string(for: "token-A") == "one")
        #expect(keychain.string(for: "token-B") == "two")
        try keychain.remove(nil)
        #expect(keychain.string(for: "token-A") == nil && keychain.string(for: "token-B") == nil)
        // An item with no account, as Porthole keeps its token.
        try keychain.set("solo", for: nil)
        #expect(keychain.string(for: nil) == "solo")
    }

    @Test func adoptsASecretFromAnOldService() throws {
        let old = Keychain(service: Self.service())
        let new = Keychain(service: Self.service())
        defer { try? old.remove(nil); try? new.remove(nil) }
        try old.set("legacy", for: "user")
        #expect(try new.adopt("user", from: old))
        #expect(new.string(for: "user") == "legacy")
        #expect(old.string(for: "user") == nil)
        #expect(try !new.adopt("user", from: old))
    }

    @Test func inMemoryNeverTouchesTheKeychain() throws {
        let service = Self.service()
        let memory = Keychain.inMemory(service: service)
        defer { try? memory.remove(nil) }
        try memory.set("secret", for: "a")
        #expect(memory.string(for: "a") == "secret")
        #expect(Keychain.inMemory(service: service).string(for: "a") == "secret")
        #expect(Keychain(service: service).string(for: "a") == nil)
        #expect(Keychain.inMemory(service: Self.service()).string(for: "a") == nil)
        try memory.remove(nil)
        #expect(memory.string(for: "a") == nil)
    }

    @Test func queriesCarryWhereTheItemLives() {
        let plain = Keychain(service: "s").query("a")
        #expect(plain[kSecAttrService as String] as? String == "s")
        #expect(plain[kSecAttrAccount as String] as? String == "a")
        #expect(plain[kSecAttrSynchronizable as String] == nil)
        #expect(plain[kSecAttrAccessGroup as String] == nil)
        #expect(Keychain(service: "s").query(nil)[kSecAttrAccount as String] == nil)

        let shared = Keychain(service: "s", synchronizable: true, accessGroup: "TEAM.group").query("a")
        #expect(shared[kSecAttrSynchronizable as String] as? Bool == true)
        #expect(shared[kSecAttrAccessGroup as String] as? String == "TEAM.group")
        #if os(macOS)
        #expect(shared[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #endif

        let written = Keychain(service: "s", label: "Hangar – Steam", accessible: .afterFirstUnlockThisDeviceOnly).attributes
        #expect(written[kSecAttrLabel as String] as? String == "Hangar – Steam")
        #expect((written[kSecAttrAccessible as String] as! CFString) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    @Test func failuresSayWhatWentWrong() {
        let failure = Keychain.Failure(status: errSecDuplicateItem)
        #expect(failure.status == errSecDuplicateItem)
        #expect(failure.errorDescription?.isEmpty == false)
    }

    @Test func inMemoryStoresAreSharedPerServiceInTheProcess() throws {
        let service = "FileKitTests.\(UUID().uuidString)"
        let one = Keychain.inMemory(service: service)
        let two = Keychain.inMemory(service: service)
        let other = Keychain.inMemory(service: service + ".other")
        try one.set("secret", for: "a")
        #expect(two.string(for: "a") == "secret")
        #expect(other.string(for: "a") == nil)
        try one.remove(nil)
    }
}
