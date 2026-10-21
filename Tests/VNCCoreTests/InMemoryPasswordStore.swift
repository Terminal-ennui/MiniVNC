import Foundation
import VNCCore

/// Test double for code that takes a `PasswordStore`.
final class InMemoryPasswordStore: PasswordStore {
    private var passwords: [UUID: String] = [:]

    func password(for id: UUID) -> String? {
        passwords[id]
    }

    func setPassword(_ password: String, for id: UUID, label: String) {
        passwords[id] = password
    }

    func deletePassword(for id: UUID) {
        passwords[id] = nil
    }
}
