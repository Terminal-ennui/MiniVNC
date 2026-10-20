/// macOS key events → X11 keysyms.
public enum Keysym {
    private static let specials: [UInt16: UInt32] = [
        36: 0xFF0D,  // Return
        48: 0xFF09,  // Tab
        51: 0xFF08,  // Delete → BackSpace
        53: 0xFF1B,  // Escape
        117: 0xFFFF, // ForwardDelete → Delete
        115: 0xFF50, // Home
        119: 0xFF57, // End
        116: 0xFF55, // PageUp
        121: 0xFF56, // PageDown
        123: 0xFF51, // Left
        126: 0xFF52, // Up
        124: 0xFF53, // Right
        125: 0xFF54, // Down
        114: 0xFF63, // Help → Insert
        76: 0xFF8D,  // KeypadEnter
        // F1…F20 → 0xFFBE…0xFFD1
        122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1, 96: 0xFFC2,
        97: 0xFFC3, 98: 0xFFC4, 100: 0xFFC5, 101: 0xFFC6, 109: 0xFFC7,
        103: 0xFFC8, 111: 0xFFC9, 105: 0xFFCA, 107: 0xFFCB, 113: 0xFFCC,
        106: 0xFFCD, 64: 0xFFCE, 79: 0xFFCF, 80: 0xFFD0, 90: 0xFFD1,
    ]

    private static let modifiers: [UInt16: UInt32] = [
        55: 0xFFE3, // Command → Control_L
        54: 0xFFE4, // RightCommand → Control_R
        59: 0xFFE3, // Control → Control_L
        62: 0xFFE4, // RightControl → Control_R
        56: 0xFFE1, // Shift_L
        60: 0xFFE2, // Shift_R
        58: 0xFFE9, // Option → Alt_L
        61: 0xFFEA, // RightOption → Alt_R
        57: 0xFFE5, // Caps_Lock
    ]

    /// Non-character keys by macOS virtual key code (Carbon kVK_*).
    public static func special(keyCode: UInt16) -> UInt32? {
        specials[keyCode]
    }

    /// Modifier keys by virtual key code. ⌘ is sent to the remote as Control.
    public static func modifier(keyCode: UInt16) -> UInt32? {
        modifiers[keyCode]
    }

    /// Keysym for typed text (caller passes `NSEvent.charactersIgnoringModifiers`), from the first Unicode scalar:
    /// Latin-1 printables map to themselves, others to 0x0100_0000 | scalar; control and Apple function-key chars → nil.
    public static func character(_ characters: String) -> UInt32? {
        guard let value = characters.unicodeScalars.first?.value else { return nil }
        switch value {
        case 0x20...0x7E, 0xA0...0xFF: return value
        case 0..<0x20, 0x7F...0x9F, 0xF700...0xF8FF: return nil
        default: return 0x0100_0000 | value
        }
    }

    private static let localLetters: Set<String> = ["q", "w", "h", "m"]

    /// ⌘-shortcuts kept by the Mac app: ⌘Q/⌘W/⌘H/⌘M (not with ⌃) and ⌃⌘F (full screen). ⌥/⇧ don't matter.
    public static func isLocalShortcut(_ characters: String, command: Bool, control: Bool) -> Bool {
        guard command else { return false }
        let key = characters.lowercased()
        return control ? key == "f" : localLetters.contains(key)
    }
}
