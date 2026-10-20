import Foundation
import Testing
@testable import VNCCore

struct ByteWriterTests {
    @Test func writesBigEndianIntegers() {
        var w = ByteWriter()
        w.u8(0x01)
        w.u16(0x0203)
        w.u32(0x0405_0607)
        w.s32(-2)
        #expect(w.data == Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0xFF, 0xFF, 0xFF, 0xFE]))
    }

    @Test func writesBytesAndPadding() {
        var w = ByteWriter()
        w.bytes(Data([0xAA, 0xBB]))
        w.padding(3)
        #expect(w.data == Data([0xAA, 0xBB, 0x00, 0x00, 0x00]))
    }
}

struct ByteReaderTests {
    @Test func readsBigEndianIntegers() throws {
        var r = ByteReader(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0xFF, 0xFF, 0xFF, 0xFE]))
        #expect(try r.u8() == 0x01)
        #expect(try r.u16() == 0x0203)
        #expect(try r.u32() == 0x0405_0607)
        #expect(try r.s32() == -2)
        #expect(r.isAtEnd)
    }

    @Test func readsBytesAndSkips() throws {
        var r = ByteReader(Data([1, 2, 3, 4, 5]))
        try r.skip(1)
        #expect(try r.bytes(3) == Data([2, 3, 4]))
        #expect(r.remaining == 1)
        #expect(r.offset == 4)
    }

    @Test func throwsOnUnderflow() {
        var r = ByteReader(Data([1]))
        #expect(throws: ByteError.underflow(needed: 2, available: 1)) { try r.u16() }
    }

    @Test func handlesDataSlicesWithNonZeroStartIndex() throws {
        let base = Data([9, 9, 0xAB, 0xCD])
        var r = ByteReader(base[2...])
        #expect(try r.u16() == 0xABCD)
    }
}
