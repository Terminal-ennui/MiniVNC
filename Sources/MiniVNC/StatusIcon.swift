import AppKit

/// Menu bar icon: a small monitor showing the ^_^ face from the app icon. A template image, so it
/// follows the menu bar's light/dark appearance.
@MainActor
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            NSColor.black.set()
            let screen = NSBezierPath(roundedRect: NSRect(x: 2.25, y: 1.75, width: 14.5, height: 10), xRadius: 2.5, yRadius: 2.5)
            screen.lineWidth = 1.5
            screen.stroke()
            NSRect(x: 8.5, y: 12.5, width: 2, height: 1.5).fill() // neck
            NSBezierPath(roundedRect: NSRect(x: 5.5, y: 14, width: 8, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
            // ^_^ on a 1 pt pixel grid (11 × 3), centred in the screen and on whole points so it stays sharp at 1×.
            let face = [(1, 0), (0, 1), (2, 1), (4, 2), (5, 2), (6, 2), (9, 0), (8, 1), (10, 1)]
            for (x, y) in face {
                NSRect(x: 4 + CGFloat(x), y: 5 + CGFloat(y), width: 1, height: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MiniVNC"
        return image
    }()
}
