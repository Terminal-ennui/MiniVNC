import Foundation
import Security
import Testing
@testable import VNCCore

/// Behavior every PasswordStore must have.
private func exerciseContract(_ store: PasswordStore) throws {
    let a = UUID(), b = UUID(), c = UUID()
    #expect(store.password(for: a) == nil)

    try store.setPassword("secret", for: a)
    #expect(store.password(for: a) == "secret")

    try store.setPassword("changed", for: a)
    #expect(store.password(for: a) == "changed")

    try store.setPassword("other", for: b)
    #expect(store.password(for: a) == "changed")
    #expect(store.password(for: b) == "other")
    #expect(store.password(for: c) == nil)

    let unicode = "pässwörd 🔑 日本語"
    try store.setPassword(unicode, for: c)
    #expect(store.password(for: c) == unicode)

    store.deletePassword(for: a)
    #expect(store.password(for: a) == nil)
    #expect(store.password(for: b) == "other")
    store.deletePassword(for: a)

    try store.setPassword("again", for: a)
    #expect(store.password(for: a) == "again")
}

/// Unique keychain service whose items are all removed when the test ends, pass or fail.
private func withTestKeychainService(_ body: (String) throws -> Void) rethrows {
    let service = "MiniVNC.tests.\(UUID())"
    defer {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary
        var deleted = 0
        while deleted < 100, SecItemDelete(query) == errSecSuccess { deleted += 1 }
        #expect(SecItemCopyMatching(query, nil) == errSecItemNotFound)
    }
    try body(service)
}

private func keychainItems(service: String) -> [[String: Any]] {
    let query = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecMatchLimit: kSecMatchLimitAll,
        kSecReturnAttributes: true,
    ] as CFDictionary
    var result: CFTypeRef?
    guard SecItemCopyMatching(query, &result) == errSecSuccess else { return [] }
    return result as? [[String: Any]] ?? []
}

struct PasswordStoreTests {
    @Test func keychainErrorUsesSystemMessage() {
        let error: Error = KeychainError(status: errSecItemNotFound)
        #expect(error.localizedDescription == SecCopyErrorMessageString(errSecItemNotFound, nil) as String?)
        #expect(!error.localizedDescription.contains("KeychainError"))
    }

    @Test func inMemoryStoreContract() throws {
        try exerciseContract(InMemoryPasswordStore())
    }

    @Test func keychainStoreContract() throws {
        try withTestKeychainService { service in
            try exerciseContract(KeychainPasswordStore(service: service))
        }
    }

    @Test func keychainStoresOneLabeledItemPerConnection() throws {
        try withTestKeychainService { service in
            let store = KeychainPasswordStore(service: service)
            let id = UUID()
            try store.setPassword("one", for: id)
            try store.setPassword("two", for: id)
            let items = keychainItems(service: service)
            #expect(items.count == 1)
            #expect(items.first?[kSecAttrAccount as String] as? String == id.uuidString)
            #expect(items.first?[kSecAttrLabel as String] as? String == "MiniVNC")
        }
    }

    @Test func keychainStoresAreIsolatedByService() throws {
        try withTestKeychainService { first in
            try withTestKeychainService { second in
                let id = UUID()
                try KeychainPasswordStore(service: first).setPassword("first", for: id)
                #expect(KeychainPasswordStore(service: second).password(for: id) == nil)
                KeychainPasswordStore(service: second).deletePassword(for: id)
                #expect(KeychainPasswordStore(service: first).password(for: id) == "first")
            }
        }
    }
}
