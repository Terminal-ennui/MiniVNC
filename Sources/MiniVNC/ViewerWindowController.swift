import AppKit
import Network
import VNCCore

/// One window per connection. Keeps the remote desktop sized to the window when the server allows it,
/// otherwise sizes the window to the remote desktop and scales.
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private var connection: SavedConnection
    private let passwords: PasswordStore
    private let framebufferView: FramebufferView
    private let clipboard = ClipboardSync()
    private var session: RFBSession?
    private var isConnected = false
    private var remoteSize: CGSize = .zero
    private var resizeSupported = false
    private let hasSavedFrame: Bool
    private var resizeTask: Task<Void, Never>?
    private var isClosing = false
    private var skipSavedPassword = false
    private var enteredPassword: String?
    private var authError: String?

    static func autosaveName(for id: UUID) -> String { "MiniVNC.\(id.uuidString)" }

    init(connection: SavedConnection, passwords: PasswordStore) {
        self.connection = connection
        self.passwords = passwords
        let view = FramebufferView()
        framebufferView = view

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = connection.displayName
        window.backgroundColor = .black
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        let autosaveName = Self.autosaveName(for: connection.id)
        hasSavedFrame = window.setFrameUsingName(autosaveName)
        if !hasSavedFrame { window.center() }
        super.init(window: window)
        window.setFrameAutosaveName(autosaveName)
        window.delegate = self
        window.makeFirstResponder(view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Takes effect on the next (re)connect.
    func update(_ connection: SavedConnection) {
        self.connection = connection
        window?.title = connection.displayName
    }

    func connect() {
        let transport = NWTransport(host: connection.host, port: connection.port, onLocalNetworkWait: { [weak self] in
            Task { @MainActor in self?.window?.subtitle = "Waiting for Local Network permission…" }
        })
        let session = RFBSession(transport: transport)
        self.session = session
        framebufferView.session = session
        isConnected = false
        enteredPassword = nil
        window?.subtitle = "Connecting…"

        Task {
            for await frame in session.frames { framebufferView.display(frame) }
        }
        Task {
            for await event in session.events { handle(event, from: session) }
        }
        let password: @Sendable () async -> String? = { [weak self] in await self?.password() }
        Task { await session.run(password: password) }
    }

    // MARK: - Session events

    private func handle(_ event: SessionEvent, from source: RFBSession) {
        guard source === session else { return }
        switch event {
        case .connected(let info):
            isConnected = true
            window?.subtitle = info.name
            if let enteredPassword { try? passwords.setPassword(enteredPassword, for: connection.id, label: connection.keychainLabel) }
            enteredPassword = nil
            authError = nil
            skipSavedPassword = false
            remoteSize = CGSize(width: Int(info.width), height: Int(info.height))
            if !hasSavedFrame { fitWindowToRemote() }
            clipboard.pushIfChanged(to: source)
        case .resized(let width, let height):
            remoteSize = CGSize(width: width, height: height)
            if !resizeSupported { fitWindowToRemote() }
        case .desktopResizeSupport(let supported):
            resizeSupported = supported
            if supported {
                window?.contentResizeIncrements = NSSize(width: 1, height: 1) // clears any aspect-ratio lock
                requestRemoteSize()
            } else {
                fitWindowToRemote()
            }
        case .cursor(let shape):
            framebufferView.setRemoteCursor(shape)
        case .clipboard(let text):
            clipboard.receive(text)
        case .bell:
            NSSound.beep()
        case .disconnected(let error):
            sessionEnded(error)
        }
    }

    private func password() async -> String? {
        if !skipSavedPassword, let saved = passwords.password(for: connection.id) { return saved }
        guard let window else { return nil }
        let entered = await PasswordPrompt.ask(for: connection.displayName, error: authError, in: window)
        enteredPassword = entered
        return entered
    }

    private func sessionEnded(_ error: Error?) {
        let wasConnected = isConnected
        session = nil
        framebufferView.session = nil
        isConnected = false
        resizeSupported = false
        guard !isClosing else { return }

        switch error as? HandshakeError {
        case .cancelled?:
            close()
        case .authenticationFailed(let reason)?:
            // Wrong or missing password: ask again (the saved one is replaced only once a new one works).
            authError = reason
            skipSavedPassword = true
            connect()
        default:
            showDisconnected(error, wasConnected: wasConnected)
        }
    }

    private func showDisconnected(_ error: Error?, wasConnected: Bool) {
        guard let window else { return }
        window.subtitle = wasConnected ? "Disconnected" : "Not connected"
        let alert = NSAlert()
        alert.messageText = wasConnected
            ? "Disconnected from \(connection.displayName)"
            : "Couldn't connect to \(connection.displayName)"
        alert.informativeText = Self.describe(error, host: connection.host)
        alert.addButton(withTitle: wasConnected ? "Reconnect" : "Try Again")
        let needsLocalNetwork = (error as? TransportError) == .localNetworkDenied
        if needsLocalNetwork { alert.addButton(withTitle: "Open Privacy Settings") }
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window) { [weak self] response in
            // Ended by windowWillClose: the window is already going away.
            guard let self, !isClosing else { return }
            switch response {
            case .alertFirstButtonReturn:
                skipSavedPassword = false
                authError = nil
                connect()
            case .alertSecondButtonReturn where needsLocalNetwork:
                NSWorkspace.shared.open(Self.localNetworkSettings)
                showDisconnected(error, wasConnected: wasConnected) // keep Try Again at hand
            default:
                close()
            }
        }
    }

    private static let localNetworkSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    /// Picking the connection again from a menu retries it if the window sits disconnected.
    func reconnectIfIdle() {
        if session == nil, window?.attachedSheet == nil { connect() }
    }

    private static func describe(_ error: Error?, host: String) -> String {
        switch error {
        case let error as TransportError:
            switch error {
            case .closed: return "The server closed the connection."
            case .localNetworkDenied:
                return "macOS hasn't let MiniVNC reach your local network. Turn MiniVNC on under Privacy & Security › Local Network. "
                    + "If it isn't listed, quit and reopen MiniVNC and connect again, then choose Allow when macOS asks."
            }
        case let error as HandshakeError:
            switch error {
            case .unsupportedVersion(let greeting): return "The server doesn't speak a supported VNC protocol (“\(greeting)”)."
            case .serverRefused(let reason), .authenticationFailed(let reason): return reason
            case .noSupportedSecurity: return "The server requires an authentication method MiniVNC doesn't support (only VNC password or none)."
            case .malformed, .cancelled: return "The server sent unexpected data."
            case .timedOut: return "The server didn't respond. Check that \(host) runs a VNC server on this port."
            }
        case let error as NWError:
            switch error {
            case .posix(let code): return String(cString: strerror(code.rawValue)) + "."
            case .dns: return "Couldn't find “\(host)”."
            default: return error.localizedDescription
            }
        case nil:
            return "The connection ended."
        default:
            return "The server sent unexpected data."
        }
    }

    // MARK: - Sizing

    /// Window content = remote size (shrunk to fit the screen), aspect-locked unless the server resizes to us.
    private func fitWindowToRemote() {
        guard let window, remoteSize.width > 0, remoteSize.height > 0,
              !window.styleMask.contains(.fullScreen), let screen = window.screen ?? NSScreen.main
        else { return }
        if !resizeSupported { window.contentAspectRatio = remoteSize }
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let available = CGSize(width: screen.visibleFrame.width, height: screen.visibleFrame.height - chrome)
        let content = DesktopSize.windowSize(remote: remoteSize, available: available)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(window.constrainFrameRect(frame, to: screen), display: true)
    }

    private func requestRemoteSize() {
        guard resizeSupported, let session, let size = window?.contentView?.bounds.size else { return }
        let request = DesktopSize.request(for: size)
        Task { await session.requestDesktopSize(width: request.width, height: request.height) }
    }

    func windowDidResize(_ notification: Notification) {
        guard resizeSupported else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.requestRemoteSize()
        }
    }

    // MARK: - Window

    func windowDidBecomeKey(_ notification: Notification) {
        if isConnected, let session { clipboard.pushIfChanged(to: session) }
    }

    func windowDidResignKey(_ notification: Notification) {
        framebufferView.releaseAllInput()
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        // A pending password sheet must answer, or the session would wait on it forever.
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .cancel) }
        resizeTask?.cancel()
        session?.disconnect()
        onClose?()
    }
}
