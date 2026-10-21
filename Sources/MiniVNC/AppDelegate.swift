import AppKit
import VNCCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConnectionStore()
    private let passwords: PasswordStore = KeychainPasswordStore()
    private let connectionsMenu = NSMenu(title: "Connections")
    private let statusMenu = NSMenu()
    private var statusItem: NSStatusItem?
    private var viewers: [UUID: ViewerWindowController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(connections: connectionsMenu)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.image
        item.button?.toolTip = "MiniVNC"
        item.menu = statusMenu
        statusItem = item
        rebuildMenus()
        NSApp.activate()
        if store.connections.isEmpty { newConnection(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, store.connections.isEmpty { newConnection(nil) }
        return true
    }

    // MARK: - Menus

    /// The app's Connections menu and the menu bar icon's menu list the same connections.
    private func rebuildMenus() {
        addConnectionItems(to: connectionsMenu)
        connectionsMenu.addItem(.separator())
        connectionsMenu.addItem(withTitle: "Send Ctrl-Alt-Delete", action: #selector(FramebufferView.sendCtrlAltDelete(_:)), keyEquivalent: "")
        connectionsMenu.addItem(withTitle: "Disconnect", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        addConnectionItems(to: statusMenu)
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit MiniVNC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Saved connections (✓ when open), then New / Edit ▸ / Delete ▸.
    private func addConnectionItems(to menu: NSMenu) {
        menu.removeAllItems()
        if store.connections.isEmpty {
            menu.addItem(withTitle: "No Saved Connections", action: nil, keyEquivalent: "").isEnabled = false
        }
        for connection in store.connections {
            let item = menu.addItem(withTitle: connection.displayName, action: #selector(connect(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = connection.id
            item.state = viewers[connection.id] == nil ? .off : .on
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Connection…", action: #selector(newConnection(_:)), keyEquivalent: "n").target = self
        menu.addItem(listItem("Edit", action: #selector(editConnection(_:))))
        menu.addItem(listItem("Delete", action: #selector(deleteConnection(_:))))
    }

    /// Submenu listing every saved connection, e.g. Edit ▸ / Delete ▸.
    private func listItem(_ title: String, action: Selector) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        for connection in store.connections {
            let item = submenu.addItem(withTitle: connection.displayName + "…", action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = connection.id
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isHidden = store.connections.isEmpty
        return item
    }

    // MARK: - Actions

    // Choices from the menu bar icon can arrive while another app is active, so each action comes forward first.

    @objc private func connect(_ sender: NSMenuItem) {
        NSApp.activate()
        if let id = sender.representedObject as? UUID { open(id) }
    }

    @objc private func newConnection(_ sender: Any?) {
        NSApp.activate()
        guard let connection = ConnectionEditor.run(editing: nil, passwords: passwords) else { return }
        store.save(connection)
        rebuildMenus()
        open(connection.id)
    }

    @objc private func editConnection(_ sender: NSMenuItem) {
        NSApp.activate()
        guard let id = sender.representedObject as? UUID, let existing = store.connection(id: id),
              let connection = ConnectionEditor.run(editing: existing, passwords: passwords)
        else { return }
        store.save(connection)
        viewers[id]?.update(connection)
        rebuildMenus()
    }

    @objc private func deleteConnection(_ sender: NSMenuItem) {
        NSApp.activate()
        guard let id = sender.representedObject as? UUID, let connection = store.connection(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(connection.displayName)”?"
        alert.informativeText = "Its saved password is removed from your Keychain."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        viewers[id]?.close()
        store.delete(id: id)
        passwords.deletePassword(for: id)
        NSWindow.removeFrame(usingName: ViewerWindowController.autosaveName(for: id))
        rebuildMenus()
    }

    private func open(_ id: UUID) {
        if let viewer = viewers[id] {
            viewer.showWindow(nil)
            viewer.reconnectIfIdle()
            return
        }
        guard let connection = store.connection(id: id) else { return }
        let viewer = ViewerWindowController(connection: connection, passwords: passwords)
        viewer.onClose = { [weak self] in
            self?.viewers[id] = nil
            self?.rebuildMenus()
        }
        viewers[id] = viewer
        rebuildMenus()
        viewer.showWindow(nil)
        viewer.connect()
    }
}
