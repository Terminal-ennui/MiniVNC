import Foundation
import Security

/// Per-connection VNC passwords, keyed by `SavedConnection.id`.
public protocol PasswordStore: AnyObject {
    func password(for id: UUID) -> String?
    func setPassword(_ password: String, for id: UUID) throws
    func deletePassword(for id: UUID)
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

/// Generic-password items: kSecAttrService = service, kSecAttrAccount = id.uuidString, labeled "MiniVNC"
/// so they are recognizable in Keychain Access.
public final class KeychainPasswordStore: PasswordStore, Sendable {
    private static let label = "MiniVNC"
    private let service: String

    public init(service: String = "MiniVNC") {
        self.service = service
    }

    public func password(for id: UUID) -> String? {
        var query = itemQuery(id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, for id: UUID) throws {
        let query = itemQuery(id)
        let attributes: [CFString: Any] = [kSecValueData: Data(password.utf8), kSecAttrLabel: Self.label]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func deletePassword(for id: UUID) {
        SecItemDelete(itemQuery(id) as CFDictionary)
    }

    private func itemQuery(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
    }
}
