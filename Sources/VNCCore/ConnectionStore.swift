import Foundation

public struct SavedConnection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16

    public init(id: UUID = UUID(), name: String, host: String, port: UInt16) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }

    /// `name`, or the formatted address when the name is blank.
    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? HostParser.format(HostAddress(host: host, port: port))
            : name
    }

    /// Keychain Access label for this connection's password, e.g. "MiniVNC: Office (office.local:5900)".
    public var keychainLabel: String {
        let address = HostParser.format(HostAddress(host: host, port: port))
        return displayName == address ? "MiniVNC: \(address)" : "MiniVNC: \(displayName) (\(address))"
    }
}

/// Saved connections persisted as JSON in user defaults, in insertion order. Unreadable data loads as empty.
public final class ConnectionStore {
    private let defaults: UserDefaults
    private let key: String
    public private(set) var connections: [SavedConnection]

    public init(defaults: UserDefaults = .standard, key: String = "savedConnections") {
        self.defaults = defaults
        self.key = key
        connections = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([SavedConnection].self, from: $0) } ?? []
    }

    /// Replaces the connection with the same id in place, or appends it.
    public func save(_ connection: SavedConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        persist()
    }

    public func delete(id: UUID) {
        connections.removeAll { $0.id == id }
        persist()
    }

    public func connection(id: UUID) -> SavedConnection? {
        connections.first { $0.id == id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: key)
        }
    }
}
