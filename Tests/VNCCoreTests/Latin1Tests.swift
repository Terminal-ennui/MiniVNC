import Foundation
import Testing
@testable import VNCCore

struct Latin1Tests {
    @Test func encodesLatin1() {
        #expect(Latin1.encode("café") == Data([0x63, 0x61, 0x66, 0xE9]))
        #expect(Latin1.encode("e\u{301}") == Data([0xE9]))
    }

    @Test func replacesCharactersOutsideLatin1() {
        #expect(Latin1.encode("5€ 🙂") == Data([0x35, 0x3F, 0x20, 0x3F]))
    }

    @Test func encodeNormalizesLineEndings() {
        #expect(Latin1.encode("a\r\nb\rc\nd") == Data("a\nb\nc\nd".utf8))
    }

    @Test func encodeDropsNULs() {
        #expect(Latin1.encode("\0a\0b\0") == Data("ab".utf8))
    }

    @Test func decodesLatin1() {
        #expect(Latin1.decode(Data([0x63, 0x61, 0x66, 0xE9, 0xFF])) == "café\u{FF}")
    }

    @Test func decodeNormalizesLineEndings() {
        #expect(Latin1.decode(Data("a\r\nb\rc\nd\r".utf8)) == "a\nb\nc\nd\n")
    }
}
