import Foundation
import zlib

public enum ZRLEError: Error, Equatable {
    case zlib(Int32)
    case malformed(String)
}

/// ZRLE (RFB encoding 16) decoder for the bgrx32 pixel format (3-byte CPIXELs).
public final class ZRLEDecoder {
    /// Heap-allocated so its address never changes: zlib keeps a back-pointer to it.
    private let stream: UnsafeMutablePointer<z_stream>
    private var streamReady = false
    private var output = [UInt8]()
    /// One decoded tile (≤ 64×64), little-endian pixels ready for `Framebuffer.blit`.
    private let tile = UnsafeMutablePointer<UInt32>.allocate(capacity: 64 * 64)
    /// The current tile's palette, little-endian; 128 entries so any 7-bit index stays in bounds.
    private let palette = UnsafeMutablePointer<UInt32>.allocate(capacity: 128)

    private static let paletteIndexError = ZRLEError.malformed("palette index out of range")

    public init() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        tile.initialize(repeating: 0, count: 64 * 64)
        palette.initialize(repeating: 0, count: 128)
    }

    deinit {
        if streamReady { inflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
        tile.deallocate()
        palette.deallocate()
    }

    /// `compressed` = bytes following the u32 length of one ZRLE rectangle.
    /// One zlib stream persists for the whole connection. Bytes left over after the last tile are ignored.
    /// After a `.zlib` error the stream is unusable and the caller should drop the connection.
    public func decode(_ compressed: Data, x: Int, y: Int, width: Int, height: Int, into fb: Framebuffer) throws {
        let w = max(width, 0), h = max(height, 0)
        let produced = try inflateRect(compressed, limit: Self.outputLimit(w, h))
        try output.withUnsafeBufferPointer { buf in
            var cursor = Cursor(bytes: UnsafeBufferPointer(rebasing: buf[0..<produced]))
            for ty in stride(from: 0, to: h, by: 64) {
                for tx in stride(from: 0, to: w, by: 64) {
                    // Out-of-range origins can only wrap to far-negative values, which the framebuffer clips.
                    try decodeTile(&cursor, x: x &+ tx, y: y &+ ty, width: min(64, w - tx), height: min(64, h - ty),
                                   into: fb)
                }
            }
        }
    }

    /// Worst case a conforming encoder can emit for the rect (1 + 4 bytes/px for plain RLE of single pixels,
    /// 1 + 127·3 + 2 bytes/px for palette RLE), capped at 256 MiB.
    private static func outputLimit(_ w: Int, _ h: Int) -> Int {
        let cap = 256 << 20
        guard w <= cap, h <= cap else { return cap }
        let tiles = ((w + 63) / 64) * ((h + 63) / 64)
        return min(cap, 4 * w * h + 382 * tiles)
    }

    /// Inflates all of `input` into `output` and returns the number of bytes produced.
    private func inflateRect(_ input: Data, limit: Int) throws -> Int {
        if !streamReady {
            let status = inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else { throw ZRLEError.zlib(status) }
            streamReady = true
        }
        guard input.count <= Int(UInt32.max) else { throw ZRLEError.malformed("compressed rectangle too large") }
        var produced = 0
        var status = Z_OK
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.pointee.avail_in = uInt(src.count)
            defer {
                stream.pointee.next_in = nil
                stream.pointee.avail_in = 0
            }
            repeat {
                if produced == output.count {
                    let grown = min(max(output.count * 2, 1 << 16), limit + 1)
                    output.append(contentsOf: repeatElement(0, count: grown - output.count))
                }
                let space = min(output.count, limit + 1) - produced
                status = output.withUnsafeMutableBufferPointer { out in
                    stream.pointee.next_out = out.baseAddress! + produced
                    stream.pointee.avail_out = uInt(space)
                    return inflate(stream, Z_SYNC_FLUSH)
                }
                produced += space - Int(stream.pointee.avail_out)
                guard produced <= limit else {
                    throw ZRLEError.malformed("decompressed rectangle exceeds \(limit) bytes")
                }
            } while status == Z_OK && (stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0)
        }
        guard status == Z_OK || status == Z_BUF_ERROR || status == Z_STREAM_END else { throw ZRLEError.zlib(status) }
        return produced
    }

    private func decodeTile(
        _ c: inout Cursor, x: Int, y: Int, width tw: Int, height th: Int, into fb: Framebuffer
    ) throws {
        let subencoding = try c.u8()
        if subencoding == 1 {
            fb.fill(x: x, y: y, width: tw, height: th, pixel: try c.cpixel())
            return
        }
        switch subencoding {
        case 0: try decodeRaw(&c, count: tw * th)
        case 2...16: try decodePacked(&c, paletteSize: Int(subencoding), width: tw, height: th)
        case 128: try decodePlainRLE(&c, count: tw * th)
        case 130...255: try decodePaletteRLE(&c, paletteSize: Int(subencoding) - 128, count: tw * th)
        default: throw ZRLEError.malformed("invalid ZRLE subencoding \(subencoding)")
        }
        fb.blit(x: x, y: y, width: tw, height: th, pixels: UnsafeRawBufferPointer(start: tile, count: tw * th * 4))
    }

    private func readPalette(_ c: inout Cursor, count: Int) throws {
        let src = try c.take(count * 3)
        for i in 0..<count { palette[i] = Cursor.cpixel(at: src + 3 * i).littleEndian }
    }

    private func decodeRaw(_ c: inout Cursor, count n: Int) throws {
        let src = try c.take(n * 3)
        for i in 0..<n { tile[i] = Cursor.cpixel(at: src + 3 * i).littleEndian }
    }

    /// Indices of 1, 2 or 4 bits, MSB-first, each row padded to a whole byte.
    private func decodePacked(_ c: inout Cursor, paletteSize count: Int, width tw: Int, height th: Int) throws {
        try readPalette(&c, count: count)
        let bits = count == 2 ? 1 : count <= 4 ? 2 : 4
        let perByte = 8 / bits, rowBytes = (tw + perByte - 1) / perByte
        let src = try c.take(rowBytes * th)
        var maxIndex: UInt8 = 0
        for row in 0..<th {
            let line = src + row * rowBytes, out = tile + row * tw
            var col = 0, b = 0
            while col < tw {
                var byte = line[b]
                b += 1
                for j in 0..<min(perByte, tw - col) {
                    let index = byte &>> (8 - bits)
                    byte &<<= bits
                    maxIndex = max(maxIndex, index)
                    out[col + j] = palette[Int(index)]
                }
                col += perByte
            }
        }
        guard Int(maxIndex) < count else { throw Self.paletteIndexError }
    }

    private func decodePlainRLE(_ c: inout Cursor, count n: Int) throws {
        var i = 0
        while i < n {
            let pixel = try c.cpixel().littleEndian
            let run = try c.runLength(max: n - i)
            (tile + i).update(repeating: pixel, count: run)
            i += run
        }
    }

    private func decodePaletteRLE(_ c: inout Cursor, paletteSize count: Int, count n: Int) throws {
        try readPalette(&c, count: count)
        var i = 0, maxIndex: UInt8 = 0
        while i < n {
            let byte = try c.u8()
            let index = byte & 0x7F
            maxIndex = max(maxIndex, index)
            if byte & 0x80 == 0 {
                tile[i] = palette[Int(index)]
                i += 1
            } else {
                let run = try c.runLength(max: n - i)
                (tile + i).update(repeating: palette[Int(index)], count: run)
                i += run
            }
        }
        guard Int(maxIndex) < count else { throw Self.paletteIndexError }
    }

    private struct Cursor {
        let bytes: UnsafeBufferPointer<UInt8>
        var offset = 0

        func require(_ count: Int) throws {
            guard count >= 0, count <= bytes.count - offset else { throw ZRLEError.malformed("truncated ZRLE data") }
        }

        /// Returns a pointer to the next `count` bytes and advances past them.
        mutating func take(_ count: Int) throws -> UnsafePointer<UInt8> {
            try require(count)
            guard let base = bytes.baseAddress else { throw ZRLEError.malformed("truncated ZRLE data") }
            defer { offset += count }
            return base + offset
        }

        mutating func u8() throws -> UInt8 {
            try require(1)
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func cpixel() throws -> UInt32 {
            Self.cpixel(at: try take(3))
        }

        /// CPIXEL for bgrx32: bytes B, G, R.
        static func cpixel(at p: UnsafePointer<UInt8>) -> UInt32 {
            UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16
        }

        /// Sum of bytes up to and including the first byte != 255, plus 1; must not exceed `limit`.
        mutating func runLength(max limit: Int) throws -> Int {
            var length = 1
            while true {
                let byte = try u8()
                length += Int(byte)
                guard length <= limit else { throw ZRLEError.malformed("run length exceeds tile") }
                if byte != 255 { return length }
            }
        }
    }
}
