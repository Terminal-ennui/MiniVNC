import AppKit
import VNCCore

@MainActor
enum ConnectionEditor {
    /// Add/edit dialog. Saves the password to `passwords` and returns the connection, or nil if cancelled.
    static func run(editing existing: SavedConnection?, passwords: PasswordStore) -> SavedConnection? {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "New Connection" : "Edit Connection"
        alert.informativeText = "Host can be host, host:display or host::port."
        alert.addButton(withTitle: existing == nil ? "Connect" : "Save")
        alert.addButton(withTitle: "Cancel")

        let host = field(NSTextField(), row: 2, placeholder: "Host",
                         value: existing.map { HostParser.format(HostAddress(host: $0.host, port: $0.port)) })
        let name = field(NSTextField(), row: 1, placeholder: "Name (optional)", value: existing?.name)
        let password = field(NSSecureTextField(), row: 0, placeholder: "Password",
                             value: existing.flatMap { passwords.password(for: $0.id) })
        host.nextKeyView = name
        name.nextKeyView = password
        password.nextKeyView = host

        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 88))
        [host, name, password].forEach(fields.addSubview)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = host

        while alert.runModal() == .alertFirstButtonReturn {
            guard let address = HostParser.parse(host.stringValue) else {
                alert.informativeText = "“\(host.stringValue)” isn't a valid host. Use host, host:display or host::port."
                NSSound.beep()
                continue
            }
            var connection = existing ?? SavedConnection(name: "", host: address.host, port: address.port)
            connection.name = name.stringValue.trimmingCharacters(in: .whitespaces)
            connection.host = address.host
            connection.port = address.port
            if password.stringValue.isEmpty {
                passwords.deletePassword(for: connection.id)
            } else {
                try? passwords.setPassword(password.stringValue, for: connection.id, label: connection.keychainLabel)
            }
            return connection
        }
        return nil
    }

    private static func field<Field: NSTextField>(_ field: Field, row: Int, placeholder: String, value: String?) -> Field {
        field.frame = NSRect(x: 0, y: CGFloat(row) * 32, width: 260, height: 24)
        field.placeholderString = placeholder
        field.stringValue = value ?? ""
        return field
    }
}

@MainActor
enum PasswordPrompt {
    static func ask(for name: String, error: String?, in window: NSWindow) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Password for \(name)"
        alert.informativeText = error ?? "It will be saved in your Keychain."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = await alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
