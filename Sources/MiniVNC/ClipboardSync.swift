import AppKit
import VNCCore

/// Mirrors plain text between the Mac pasteboard and the remote clipboard.
@MainActor
final class ClipboardSync {
    private var lastChangeCount: Int?
    private var pendingChangeCount: Int?
    /// nspasteboard.org markers that password managers set on secrets.
    private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
    ]

    /// Sends the pasteboard if it changed since we last saw it. Called on connect and whenever the viewer
    /// becomes key: anything copied elsewhere must have happened while another app was active.
    func pushIfChanged(to session: RFBSession) {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount, changeCount != pendingChangeCount else { return }
        guard Self.privateTypes.isDisjoint(with: pasteboard.types ?? []),
              let text = pasteboard.string(forType: .string)
        else {
            lastChangeCount = changeCount
            return
        }
        pendingChangeCount = changeCount
        Task {
            let accepted = await session.sendClipboard(text)
            if pendingChangeCount == changeCount { pendingChangeCount = nil }
            // max: a remote copy may have advanced the count while we were sending.
            if accepted { lastChangeCount = max(lastChangeCount ?? 0, changeCount) }
        }
    }

    func receive(_ text: String) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) != text {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        lastChangeCount = pasteboard.changeCount
    }
}
