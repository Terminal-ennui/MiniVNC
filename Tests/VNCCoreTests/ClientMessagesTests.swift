import Foundation
import Testing
@testable import VNCCore

struct ClientMessagesTests {
    @Test func pixelFormatBGRX32Values() {
        let f = PixelFormat.bgrx32
        #expect(f.bitsPerPixel == 32 && f.depth == 24)
        #expect(!f.bigEndian && f.trueColor)
        #expect(f.redMax == 255 && f.greenMax == 255 && f.blueMax == 255)
        #expect(f.redShift == 16 && f.greenShift == 8 && f.blueShift == 0)
    }

    @Test func pixelFormatEncodesSixteenBytes() {
        var w = ByteWriter()
        PixelFormat.bgrx32.encode(into: &w)
        #expect(w.data == Data([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]))
    }

    @Test func pixelFormatRoundTrips() throws {
        let f = PixelFormat(
            bitsPerPixel: 16, depth: 16, bigEndian: true, trueColor: true,
            redMax: 31, greenMax: 63, blueMax: 0x1F2,
            redShift: 11, greenShift: 5, blueShift: 0)
        var w = ByteWriter()
        f.encode(into: &w)
        #expect(w.data.count == 16)
        var r = ByteReader(w.data)
        #expect(try PixelFormat(from: &r) == f)
        #expect(r.isAtEnd)
    }

    @Test func pixelFormatDecodeThrowsOnShortInput() {
        var r = ByteReader(Data(repeating: 0, count: 15))
        #expect(throws: ByteError.self) { try PixelFormat(from: &r) }
    }

    @Test func screenEncodesAndRoundTrips() throws {
        let s = Screen(id: 0x0102_0304, x: 5, y: 6, width: 1920, height: 1080, flags: 0xA0B0_C0D0)
        var w = ByteWriter()
        s.encode(into: &w)
        #expect(w.data == Data([1, 2, 3, 4, 0, 5, 0, 6, 0x07, 0x80, 0x04, 0x38, 0xA0, 0xB0, 0xC0, 0xD0]))
        var r = ByteReader(w.data)
        #expect(try Screen(from: &r) == s)
        #expect(r.isAtEnd)
    }

    @Test func encodingTypeConstants() {
        #expect(EncodingType.raw == 0 && EncodingType.copyRect == 1 && EncodingType.zrle == 16)
        #expect(EncodingType.cursor == -239 && EncodingType.desktopSize == -223)
        #expect(EncodingType.lastRect == -224 && EncodingType.extendedDesktopSize == -308)
        #expect(EncodingType.extendedClipboard == -1_063_131_698)
    }

    @Test func setPixelFormat() {
        #expect(ClientMessage.setPixelFormat(.bgrx32) == Data([
            0, 0, 0, 0,
            32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0,
        ]))
    }

    @Test func setEncodings() {
        #expect(ClientMessage.setEncodings([EncodingType.zrle, EncodingType.raw, EncodingType.cursor]) == Data([
            2, 0, 0, 3,
            0, 0, 0, 16,
            0, 0, 0, 0,
            0xFF, 0xFF, 0xFF, 0x11,
        ]))
        #expect(ClientMessage.setEncodings([]) == Data([2, 0, 0, 0]))
    }

    @Test func framebufferUpdateRequest() {
        #expect(ClientMessage.framebufferUpdateRequest(incremental: true, x: 1, y: 0x0203, width: 1920, height: 1080)
            == Data([3, 1, 0, 1, 2, 3, 0x07, 0x80, 0x04, 0x38]))
        #expect(ClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: 1, height: 2)
            == Data([3, 0, 0, 0, 0, 0, 0, 1, 0, 2]))
    }

    @Test func keyEvent() {
        #expect(ClientMessage.keyEvent(down: true, keysym: 0xFF0D) == Data([4, 1, 0, 0, 0, 0, 0xFF, 0x0D]))
        #expect(ClientMessage.keyEvent(down: false, keysym: 0x0102_0304) == Data([4, 0, 0, 0, 1, 2, 3, 4]))
    }

    @Test func pointerEvent() {
        #expect(ClientMessage.pointerEvent(buttonMask: 0b101, x: 0x0102, y: 0xFFFF)
            == Data([5, 5, 1, 2, 0xFF, 0xFF]))
    }

    @Test func clientCutText() {
        #expect(ClientMessage.clientCutText(Data("hi".utf8)) == Data([6, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69]))
        #expect(ClientMessage.clientCutText(Data()) == Data([6, 0, 0, 0, 0, 0, 0, 0]))
    }

    @Test func extendedClientCutText() {
        #expect(ClientMessage.extendedClientCutText(Data([0x10, 0, 0, 0x01, 0xAA]))
            == Data([6, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFB, 0x10, 0, 0, 0x01, 0xAA]))
    }

    @Test func extendedClientCutTextRequiresFlagsWord() async {
        await #expect(processExitsWith: .failure) {
            _ = ClientMessage.extendedClientCutText(Data([1, 2, 3]))
        }
    }

    @Test func setEncodingsTruncatesToU16Count() {
        let msg = ClientMessage.setEncodings([Int32](repeating: 7, count: 70_000))
        #expect(msg.count == 4 + 4 * 65535)
        #expect(Array(msg.prefix(4)) == [2, 0, 0xFF, 0xFF])
    }

    @Test func setDesktopSizeTruncatesToU8Count() {
        let screens = [Screen](repeating: Screen(id: 1, x: 0, y: 0, width: 1, height: 1, flags: 0), count: 300)
        let msg = ClientMessage.setDesktopSize(width: 1, height: 1, screens: screens)
        #expect(msg.count == 8 + 16 * 255)
        #expect(msg[6] == 255)
    }

    @Test func setDesktopSize() {
        let screens = [
            Screen(id: 1, x: 0, y: 0, width: 800, height: 600, flags: 0),
            Screen(id: 2, x: 800, y: 0, width: 1024, height: 768, flags: 7),
        ]
        var expected = Data([251, 0, 0x07, 0x20, 0x02, 0x58, 2, 0])
        expected += Data([0, 0, 0, 1, 0, 0, 0, 0, 0x03, 0x20, 0x02, 0x58, 0, 0, 0, 0])
        expected += Data([0, 0, 0, 2, 0x03, 0x20, 0, 0, 0x04, 0x00, 0x03, 0x00, 0, 0, 0, 7])
        #expect(ClientMessage.setDesktopSize(width: 1824, height: 600, screens: screens) == expected)
    }
}
