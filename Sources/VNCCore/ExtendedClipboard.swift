import Foundation
import zlib

/// RFB Extended Clipboard pseudo-encoding (0xC0A1E5CE), as implemented by TigerVNC and noVNC.
public enum ExtendedClipboard {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let text = Flags(rawValue: 1 << 0)
        public static let rtf = Flags(rawValue: 1 << 1)
        public static let html = Flags(rawValue: 1 << 2)
        public static let dib = Flags(rawValue: 1 << 3)
        public static let files = Flags(rawValue: 1 << 4)

        public static let caps = Flags(rawValue: 1 << 24)
        public static let request = Flags(rawValue: 1 << 25)
        public static let peek = Flags(rawValue: 1 << 26)
        public static let notify = Flags(rawValue: 1 << 27)
        public static let provide = Flags(rawValue: 1 << 28)

        fileprivate static let formatMask = Flags(rawValue: 0x0000_FFFF)
        fileprivate static let actionMask = Flags(rawValue: 0xFF00_0000)
    }

    public enum Message: Equatable, Sendable {
        /// Flags contain `.caps`, the supported actions and formats; one max size per format bit 0–15, ascending.
        case caps(Flags, maxSizes: [UInt32])
        case request(Flags)
        case peek
        case notify(Flags)
        /// Only text is carried; other formats are skipped on decode.
        case provide(text: String?)
    }

    public enum DecodeError: Error, Equatable {
        case invalidAction(UInt32)
        case malformedStream
        case truncatedStream
        case tooLarge
    }

    public static let clientCaps = Message.caps(
        [.caps, .request, .peek, .notify, .provide, .text], maxSizes: [10 << 20])

    /// Bound on decompressed provide content (we advertise 10 MiB of text).
    static let inflateLimit = 16 << 20

    /// `payload` = everything after the s32 (negative) length of an extended ServerCutText: u32 flags + data.
    /// Throws only `DecodeError`.
    public static func decode(_ payload: Data) throws -> Message {
        do {
            return try message(from: payload)
        } catch is ByteError {
            throw DecodeError.truncatedStream
        }
    }

    private static func message(from payload: Data) throws -> Message {
        var r = ByteReader(payload)
        let flags = Flags(rawValue: try r.u32())
        let action = flags.intersection(.actionMask)
        if action.contains(.caps) {
            let sizes = try formatBits(flags).map { _ in try r.u32() }
            return .caps(flags, maxSizes: sizes)
        }
        switch action {
        case .request: return .request(flags.intersection(.formatMask))
        case .peek: return .peek
        case .notify: return .notify(flags.intersection(.formatMask))
        case .provide:
            var content = ByteReader(try inflated(try r.bytes(r.remaining)))
            var text: String?
            for bit in formatBits(flags) {
                let size = Int(try content.u32())
                if bit == .text {
                    text = decodeText(try content.bytes(size))
                } else {
                    try content.skip(size)
                }
            }
            return .provide(text: text)
        default:
            throw DecodeError.invalidAction(flags.rawValue)
        }
    }

    /// Inverse of `decode`: u32 flags + data. The caller frames it as a ClientCutText with negative length.
    public static func encode(_ message: Message) -> Data {
        var w = ByteWriter()
        switch message {
        case let .caps(flags, maxSizes):
            precondition(maxSizes.count == formatBits(flags).count, "caps needs one max size per format")
            w.u32(flags.union(.caps).rawValue)
            maxSizes.forEach { w.u32($0) }
        case let .request(formats):
            w.u32(Flags.request.union(formats.intersection(.formatMask)).rawValue)
        case .peek:
            w.u32(Flags.peek.rawValue)
        case let .notify(formats):
            w.u32(Flags.notify.union(formats.intersection(.formatMask)).rawValue)
        case let .provide(text):
            var content = ByteWriter()
            if let text {
                let bytes = encodeText(text)
                content.u32(UInt32(bytes.count))
                content.bytes(Data(bytes))
            }
            w.u32((text == nil ? Flags.provide : [.provide, .text]).rawValue)
            w.bytes(deflated(content.data))
        }
        return w.data
    }

    private static func formatBits(_ flags: Flags) -> [Flags] {
        (0..<16).map { Flags(rawValue: 1 << $0) }.filter { flags.contains($0) }
    }

    /// UTF-8, CRLF line endings (existing CRLF kept), terminating NUL (counted in the size).
    private static func encodeText(_ text: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(text.utf8.count + 1)
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A && previous != 0x0D { out.append(0x0D) }
            out.append(byte)
            previous = byte
        }
        out.append(0)
        return out
    }

    /// C string semantics (stops at the first NUL); CRLF and lone CR become LF; invalid UTF-8 → U+FFFD.
    private static func decodeText(_ data: Data) -> String {
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0 { break }
            if !(byte == 0x0A && previous == 0x0D) { out.append(byte == 0x0D ? 0x0A : byte) }
            previous = byte
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// A complete zlib-format stream (fresh per message).
    private static func deflated(_ data: Data) -> Data {
        let input = [UInt8](data)
        var length = compressBound(uLong(input.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = compress2(&output, &length, input, uLong(input.count), Z_DEFAULT_COMPRESSION)
        precondition(status == Z_OK, "compress2 failed: \(status)")
        return Data(output[0..<Int(length)])
    }

    private static func inflated(_ data: Data) throws -> Data {
        guard data.count >= 2 else { throw DecodeError.truncatedStream }
        // zlib keeps a back-pointer to the z_stream, so it needs a stable address.
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer {
            stream.deinitialize(count: 1)
            stream.deallocate()
        }
        guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DecodeError.malformedStream
        }
        defer { inflateEnd(stream) }

        var input = [UInt8](data)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var output = Data()
        return try input.withUnsafeMutableBufferPointer { inBuf in
            stream.pointee.next_in = inBuf.baseAddress
            stream.pointee.avail_in = uInt(inBuf.count)
            while true {
                let (status, produced) = chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.pointee.next_out = outBuf.baseAddress
                    stream.pointee.avail_out = uInt(outBuf.count)
                    let status = inflate(stream, Z_NO_FLUSH)
                    return (status, outBuf.count - Int(stream.pointee.avail_out))
                }
                guard output.count + produced <= inflateLimit else { throw DecodeError.tooLarge }
                output.append(contentsOf: chunk[0..<produced])
                switch status {
                case Z_STREAM_END:
                    return output
                case Z_OK, Z_BUF_ERROR:
                    // TigerVNC only Z_SYNC_FLUSHes and never finishes the stream: accept it once input runs out.
                    if stream.pointee.avail_in == 0 && stream.pointee.avail_out > 0 { return output }
                    // Unreachable in practice: Z_BUF_ERROR means no progress,
                    // which with avail_out > 0 implies avail_in == 0.
                    if status == Z_BUF_ERROR { throw DecodeError.truncatedStream }
                default:
                    throw DecodeError.malformedStream
                }
            }
        }
    }
}
