import Foundation
import Testing
import zlib
@testable import VNCCore

private typealias DecodeError = ExtendedClipboard.DecodeError

private let inflateLimit = ExtendedClipboard.inflateLimit

private func zlibCompress(_ data: Data) -> Data {
    let input = [UInt8](data)
    var length = compressBound(uLong(input.count))
    var output = [UInt8](repeating: 0, count: Int(length))
    let status = compress2(&output, &length, input, uLong(input.count), 1)
    precondition(status == Z_OK)
    return Data(output[0..<Int(length)])
}

private func zlibUncompress(_ data: Data, capacity: Int = 1 << 20) -> Data? {
    let input = [UInt8](data)
    var length = uLong(capacity)
    var output = [UInt8](repeating: 0, count: capacity)
    guard uncompress(&output, &length, input, uLong(input.count)) == Z_OK else { return nil }
    return Data(output[0..<Int(length)])
}

/// Like TigerVNC's ZlibOutStream: Z_SYNC_FLUSH only, the stream is never finished.
private func zlibSyncFlush(_ data: Data) -> Data {
    let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    stream.initialize(to: z_stream())
    defer {
        deflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }
    precondition(deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
    var input = [UInt8](data)
    var output = [UInt8](repeating: 0, count: Int(deflateBound(stream, uLong(input.count))) + 16)
    let produced = input.withUnsafeMutableBufferPointer { inBuf in
        output.withUnsafeMutableBufferPointer { outBuf in
            stream.pointee.next_in = inBuf.baseAddress
            stream.pointee.avail_in = uInt(inBuf.count)
            stream.pointee.next_out = outBuf.baseAddress
            stream.pointee.avail_out = uInt(outBuf.count)
            precondition(deflate(stream, Z_SYNC_FLUSH) == Z_OK)
            precondition(stream.pointee.avail_in == 0 && stream.pointee.avail_out > 0)
            return outBuf.count - Int(stream.pointee.avail_out)
        }
    }
    return Data(output[0..<produced])
}

private func payload(_ flags: ExtendedClipboard.Flags, _ compressed: Data) -> Data {
    var w = ByteWriter()
    w.u32(flags.rawValue)
    w.bytes(compressed)
    return w.data
}

private func providePayload(flags: ExtendedClipboard.Flags, content: Data) -> Data {
    payload(flags, zlibCompress(content))
}

private func sized(_ bytes: Data) -> Data {
    var w = ByteWriter()
    w.u32(UInt32(bytes.count))
    w.bytes(bytes)
    return w.data
}

private func sized(_ string: String) -> Data {
    sized(Data(string.utf8))
}

/// A format section whose declared size is larger than its bytes.
private func shortSection(declaredSize: UInt32, _ bytes: String) -> Data {
    var w = ByteWriter()
    w.u32(declaredSize)
    w.bytes(Data(bytes.utf8))
    return w.data
}

/// Inflated provide content of `payload`.
private func inflatedContent(of payload: Data) throws -> Data? {
    var r = ByteReader(payload)
    try r.skip(4)
    return zlibUncompress(try r.bytes(r.remaining))
}

private func decodeText(_ text: Data) throws -> ExtendedClipboard.Message {
    try ExtendedClipboard.decode(providePayload(flags: [.provide, .text], content: sized(text)))
}

struct ExtendedClipboardTests {
    @Test func flagValues() {
        typealias F = ExtendedClipboard.Flags
        #expect([F.text, .rtf, .html, .dib, .files].map(\.rawValue) == [1, 2, 4, 8, 16])
        #expect([F.caps, .request, .peek, .notify, .provide].map(\.rawValue)
            == [0x0100_0000, 0x0200_0000, 0x0400_0000, 0x0800_0000, 0x1000_0000])
    }

    // MARK: encode / decode of control messages

    @Test func encodesRequest() {
        #expect(ExtendedClipboard.encode(.request(.text)) == Data([0x02, 0x00, 0x00, 0x01]))
    }

    @Test func encodesNotify() {
        #expect(ExtendedClipboard.encode(.notify([.text, .html])) == Data([0x08, 0x00, 0x00, 0x05]))
    }

    @Test func encodesPeek() {
        #expect(ExtendedClipboard.encode(.peek) == Data([0x04, 0x00, 0x00, 0x00]))
    }

    @Test func clientCapsValueAndBytes() {
        #expect(ExtendedClipboard.clientCaps
            == .caps([.caps, .request, .peek, .notify, .provide, .text], maxSizes: [10 << 20]))
        #expect(ExtendedClipboard.encode(ExtendedClipboard.clientCaps)
            == Data([0x1F, 0x00, 0x00, 0x01, 0x00, 0xA0, 0x00, 0x00]))
    }

    @Test func encodeCapsRequiresOneSizePerFormat() async {
        await #expect(processExitsWith: .failure) {
            _ = ExtendedClipboard.encode(.caps([.caps, .text, .html], maxSizes: [1]))
        }
    }

    @Test func decodesCapsWithThreeFormats() throws {
        var w = ByteWriter()
        w.u32(0x1F00_0007)
        w.u32(1000)
        w.u32(2000)
        w.u32(3000)
        let message = try ExtendedClipboard.decode(w.data)
        #expect(message == .caps(
            [.caps, .request, .peek, .notify, .provide, .text, .rtf, .html], maxSizes: [1000, 2000, 3000]))
    }

    @Test func decodesSimpleActions() throws {
        #expect(try ExtendedClipboard.decode(Data([0x02, 0x00, 0x00, 0x01])) == .request(.text))
        #expect(try ExtendedClipboard.decode(Data([0x04, 0x00, 0x00, 0x00])) == .peek)
        #expect(try ExtendedClipboard.decode(Data([0x08, 0x00, 0x00, 0x05])) == .notify([.text, .html]))
    }

    // MARK: provide encoding

    @Test func encodedProvideIsStandaloneZlibStreamWithCRLFAndNUL() throws {
        let encoded = ExtendedClipboard.encode(.provide(text: "a\nb"))
        #expect(encoded.prefix(4) == Data([0x10, 0x00, 0x00, 0x01]))
        #expect(encoded.dropFirst(4).first == 0x78)
        #expect(try inflatedContent(of: encoded) == sized("a\r\nb\0"))
        #expect(ExtendedClipboard.encode(.provide(text: "a\nb")) == encoded)
    }

    @Test func encodeDoesNotDoubleExistingCRLF() throws {
        let encoded = ExtendedClipboard.encode(.provide(text: "a\r\nb\nc"))
        #expect(try inflatedContent(of: encoded) == sized("a\r\nb\r\nc\0"))
    }

    @Test func provideRoundTripsUnicodeMultilineText() throws {
        let text = "héllo\n✓ 日本 🙂"
        #expect(try ExtendedClipboard.decode(ExtendedClipboard.encode(.provide(text: text))) == .provide(text: text))
    }

    @Test func provideRoundTripsLargeText() throws {
        let text = (0..<12_000).map { "line \($0) ✓ 日本 🙂" }.joined(separator: "\n")
        #expect(text.count > 190_000)
        #expect(try ExtendedClipboard.decode(ExtendedClipboard.encode(.provide(text: text))) == .provide(text: text))
    }

    @Test func provideEmptyTextRoundTrips() throws {
        let encoded = ExtendedClipboard.encode(.provide(text: ""))
        #expect(try inflatedContent(of: encoded) == sized("\0"))
        #expect(try ExtendedClipboard.decode(encoded) == .provide(text: ""))
    }

    @Test func provideNilRoundTrips() throws {
        let encoded = ExtendedClipboard.encode(.provide(text: nil))
        #expect(encoded.prefix(4) == Data([0x10, 0x00, 0x00, 0x00]))
        #expect(try inflatedContent(of: encoded) == Data())
        #expect(try ExtendedClipboard.decode(encoded) == .provide(text: nil))
    }

    // MARK: provide decoding

    @Test func decodesProvideWithTextAndHTML() throws {
        let payload = providePayload(
            flags: [.provide, .text, .html], content: sized("hi\r\nthere\0") + sized("<b>x</b>\0"))
        #expect(try ExtendedClipboard.decode(payload) == .provide(text: "hi\nthere"))
    }

    @Test func decodesProvideWithOnlyHTMLAsNilText() throws {
        let payload = providePayload(flags: [.provide, .html], content: sized("<b>x</b>\0"))
        #expect(try ExtendedClipboard.decode(payload) == .provide(text: nil))
    }

    @Test func truncatesTextAtFirstNUL() throws {
        #expect(try decodeText(Data("abc\0def\0".utf8)) == .provide(text: "abc"))
    }

    @Test func acceptsTextWithoutTerminatingNUL() throws {
        #expect(try decodeText(Data("no nul".utf8)) == .provide(text: "no nul"))
    }

    @Test func normalizesCRLFAndLoneCRToLF() throws {
        #expect(try decodeText(Data("a\rb\r\nc\nd\r\0".utf8)) == .provide(text: "a\nb\nc\nd\n"))
    }

    @Test func replacesInvalidUTF8() throws {
        #expect(try decodeText(Data([0x61, 0xFF, 0x62, 0x00])) == .provide(text: "a\u{FFFD}b"))
    }

    @Test func decodesTigerVNCUnfinishedProvideStream() throws {
        // u32(6) + "hello\0" via python zlib.compressobj() + Z_SYNC_FLUSH, matching TigerVNC's ZlibOutStream output.
        let payload = Data([0x10, 0x00, 0x00, 0x01, 0x78, 0x9C, 0x62, 0x60, 0x60, 0x60, 0xCB, 0x48, 0xCD,
                            0xC9, 0xC9, 0x67, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF])
        #expect(try ExtendedClipboard.decode(payload) == .provide(text: "hello"))
    }

    @Test func decodesSyncFlushedProvideWithTextAndHTML() throws {
        let compressed = zlibSyncFlush(sized("multi\r\nline ✓\0") + sized("<i>y</i>\0"))
        #expect(compressed.suffix(4) == Data([0x00, 0x00, 0xFF, 0xFF]))
        #expect(try ExtendedClipboard.decode(payload([.provide, .text, .html], compressed))
            == .provide(text: "multi\nline ✓"))
    }

    /// Inflated sizes around the 64 KiB inflate chunk.
    @Test(arguments: [65_535, 65_536, 65_537])
    func decodesSyncFlushedProvideAroundChunkSize(inflatedSize: Int) throws {
        let text = String(repeating: "a", count: inflatedSize - 5)
        let compressed = zlibSyncFlush(sized(text + "\0"))
        #expect(try ExtendedClipboard.decode(payload([.provide, .text], compressed)) == .provide(text: text))
    }

    @Test func acceptsInflatedContentAtLimit() throws {
        let atLimit = providePayload(flags: .provide, content: Data(count: inflateLimit))
        #expect(try ExtendedClipboard.decode(atLimit) == .provide(text: nil))
    }

    // MARK: errors

    @Test func throwsWithoutActionOrWithMultipleActions() {
        #expect(throws: DecodeError.invalidAction(0x0000_0001)) {
            try ExtendedClipboard.decode(Data([0x00, 0x00, 0x00, 0x01]))
        }
        #expect(throws: DecodeError.invalidAction(0x0A00_0001)) {
            try ExtendedClipboard.decode(Data([0x0A, 0x00, 0x00, 0x01]))
        }
    }

    @Test func throwsOnTruncatedHeaderOrCaps() {
        #expect(throws: DecodeError.truncatedStream) { try ExtendedClipboard.decode(Data()) }
        #expect(throws: DecodeError.truncatedStream) { try ExtendedClipboard.decode(Data([0x02, 0x00])) }
        var w = ByteWriter()
        w.u32(0x0100_0003)
        w.u32(1000)
        #expect(throws: DecodeError.truncatedStream) { try ExtendedClipboard.decode(w.data) }
    }

    @Test func throwsOnMissingOrTooShortStream() {
        #expect(throws: DecodeError.truncatedStream) { try ExtendedClipboard.decode(Data([0x10, 0x00, 0x00, 0x01])) }
        #expect(throws: DecodeError.truncatedStream) {
            try ExtendedClipboard.decode(Data([0x10, 0x00, 0x00, 0x00, 0x78]))
        }
    }

    @Test func throwsOnGarbageStream() {
        #expect(throws: DecodeError.malformedStream) {
            try ExtendedClipboard.decode(Data([0x10, 0x00, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02]))
        }
    }

    @Test func throwsOnTruncatedFinishedStream() {
        let full = ExtendedClipboard.encode(.provide(text: String(repeating: "lorem ipsum ", count: 50)))
        #expect(throws: DecodeError.truncatedStream) { try ExtendedClipboard.decode(full.prefix(full.count - 6)) }
    }

    @Test func throwsWhenInflatedContentIsShort() {
        let short = shortSection(declaredSize: 100, "short")
        #expect(throws: DecodeError.truncatedStream) {
            try ExtendedClipboard.decode(providePayload(flags: [.provide, .text], content: short))
        }
        #expect(throws: DecodeError.truncatedStream) {
            try ExtendedClipboard.decode(payload([.provide, .text], zlibSyncFlush(short)))
        }
    }

    @Test func throwsWhenSkippedFormatIsShort() {
        let sections = sized("text\0") + shortSection(declaredSize: 100, "<b>")
        #expect(throws: DecodeError.truncatedStream) {
            try ExtendedClipboard.decode(providePayload(flags: [.provide, .text, .html], content: sections))
        }
    }

    @Test func throwsWhenInflatedContentExceedsLimit() {
        let bomb = providePayload(flags: [.provide, .text], content: Data(count: inflateLimit + 1))
        #expect(throws: DecodeError.tooLarge) { try ExtendedClipboard.decode(bomb) }
    }
}
