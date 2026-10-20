import Testing
@testable import VNCCore

private let specialKeys: [(name: String, code: UInt16, keysym: UInt32)] = [
    ("kVK_Return", 36, 0xFF0D), ("kVK_Tab", 48, 0xFF09), ("kVK_Delete", 51, 0xFF08),
    ("kVK_Escape", 53, 0xFF1B), ("kVK_ForwardDelete", 117, 0xFFFF),
    ("kVK_Home", 115, 0xFF50), ("kVK_End", 119, 0xFF57), ("kVK_PageUp", 116, 0xFF55), ("kVK_PageDown", 121, 0xFF56),
    ("kVK_LeftArrow", 123, 0xFF51), ("kVK_UpArrow", 126, 0xFF52),
    ("kVK_RightArrow", 124, 0xFF53), ("kVK_DownArrow", 125, 0xFF54),
    ("kVK_Help", 114, 0xFF63), ("kVK_ANSI_KeypadEnter", 76, 0xFF8D),
    ("kVK_F1", 122, 0xFFBE), ("kVK_F2", 120, 0xFFBF), ("kVK_F3", 99, 0xFFC0), ("kVK_F4", 118, 0xFFC1),
    ("kVK_F5", 96, 0xFFC2), ("kVK_F6", 97, 0xFFC3), ("kVK_F7", 98, 0xFFC4), ("kVK_F8", 100, 0xFFC5),
    ("kVK_F9", 101, 0xFFC6), ("kVK_F10", 109, 0xFFC7), ("kVK_F11", 103, 0xFFC8), ("kVK_F12", 111, 0xFFC9),
    ("kVK_F13", 105, 0xFFCA), ("kVK_F14", 107, 0xFFCB), ("kVK_F15", 113, 0xFFCC), ("kVK_F16", 106, 0xFFCD),
    ("kVK_F17", 64, 0xFFCE), ("kVK_F18", 79, 0xFFCF), ("kVK_F19", 80, 0xFFD0), ("kVK_F20", 90, 0xFFD1),
]

private let modifierKeys: [(name: String, code: UInt16, keysym: UInt32)] = [
    ("kVK_Command", 55, 0xFFE3), ("kVK_RightCommand", 54, 0xFFE4),
    ("kVK_Control", 59, 0xFFE3), ("kVK_RightControl", 62, 0xFFE4),
    ("kVK_Shift", 56, 0xFFE1), ("kVK_RightShift", 60, 0xFFE2),
    ("kVK_Option", 58, 0xFFE9), ("kVK_RightOption", 61, 0xFFEA),
    ("kVK_CapsLock", 57, 0xFFE5),
]

struct KeysymTests {
    private struct Shortcut: Sendable, CustomTestStringConvertible {
        let characters: String
        var command = true, control = false
        var testDescription: String { (control ? "⌃" : "") + (command ? "⌘" : "") + characters }
    }

    @Test(arguments: specialKeys)
    func specialKey(name: String, code: UInt16, keysym: UInt32) {
        #expect(Keysym.special(keyCode: code) == keysym, "\(name)")
        #expect(Keysym.modifier(keyCode: code) == nil, "\(name)")
    }

    @Test(arguments: modifierKeys)
    func modifierKey(name: String, code: UInt16, keysym: UInt32) {
        #expect(Keysym.modifier(keyCode: code) == keysym, "\(name)")
        #expect(Keysym.special(keyCode: code) == nil, "\(name)")
    }

    @Test func unknownKeyCodesAreNil() {
        let known = Set(specialKeys.map(\.code) + modifierKeys.map(\.code))
        for code in UInt16(0)...200 where !known.contains(code) {
            #expect(Keysym.special(keyCode: code) == nil, "special \(code)")
            #expect(Keysym.modifier(keyCode: code) == nil, "modifier \(code)")
        }
        #expect(Keysym.special(keyCode: .max) == nil)
    }

    @Test(arguments: [
        ("a", 0x61), ("A", 0x41), (" ", 0x20), ("~", 0x7E), ("é", 0xE9), ("\u{A0}", 0xA0), ("ÿ", 0xFF),
        ("€", 0x0100_20AC), ("🙂", 0x0101_F642), ("ab", 0x61),
    ] as [(String, UInt32)])
    func character(_ characters: String, keysym: UInt32) {
        #expect(Keysym.character(characters) == keysym)
    }

    @Test(arguments: ["", "\r", "\u{1B}", "\u{7F}", "\u{9F}", "\u{F700}", "\u{F8FF}"])
    func characterWithoutKeysym(_ characters: String) {
        #expect(Keysym.character(characters) == nil)
    }

    @Test(arguments: [
        Shortcut(characters: "q"), Shortcut(characters: "Q"), Shortcut(characters: "W"),
        Shortcut(characters: "h"), Shortcut(characters: "m"),
        Shortcut(characters: "f", control: true), Shortcut(characters: "F", control: true),
    ])
    private func localShortcut(_ s: Shortcut) {
        #expect(Keysym.isLocalShortcut(s.characters, command: s.command, control: s.control))
    }

    @Test(arguments: [
        Shortcut(characters: "c"), Shortcut(characters: "v"), Shortcut(characters: "a"),
        Shortcut(characters: "f"), Shortcut(characters: ""), Shortcut(characters: "qq"),
        Shortcut(characters: "q", command: false, control: true),
        Shortcut(characters: "q", control: true), Shortcut(characters: "q", command: false),
    ])
    private func remoteShortcut(_ s: Shortcut) {
        #expect(!Keysym.isLocalShortcut(s.characters, command: s.command, control: s.control))
    }
}
