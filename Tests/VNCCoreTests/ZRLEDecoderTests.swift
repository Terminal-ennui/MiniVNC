import Foundation
import Testing
import zlib
@testable import VNCCore

/// One deflate stream for a whole "connection", flushed with Z_SYNC_FLUSH per rect
/// (zlib header only in the first chunk).
private final class TestDeflater {
    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)

    init() {
        stream.initialize(to: z_stream())
        let status = deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        precondition(status == Z_OK)
    }

    deinit {
        deflateEnd(stream)
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    func compress(_ bytes: [UInt8]) -> Data {
        var input = bytes
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var result = Data()
        input.withUnsafeMutableBufferPointer { inBuf in
            stream.pointee.next_in = inBuf.baseAddress
            stream.pointee.avail_in = uInt(inBuf.count)
            repeat {
                chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.pointee.next_out = outBuf.baseAddress
                    stream.pointee.avail_out = uInt(outBuf.count)
                    let status = deflate(stream, Z_SYNC_FLUSH)
                    precondition(status == Z_OK || status == Z_BUF_ERROR)
                    result.append(outBuf.baseAddress!, count: outBuf.count - Int(stream.pointee.avail_out))
                }
            } while stream.pointee.avail_out == 0
        }
        return result
    }
}

private enum TileKind {
    case raw, solid, packed, plainRLE, paletteRLE
}

struct ZRLEDecoderTests {
    // MARK: Test-side encoder

    private static func cpixel(_ p: UInt32) -> [UInt8] {
        [UInt8(p & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p >> 16 & 0xFF)]
    }

    private static func runLength(_ n: Int) -> [UInt8] {
        [UInt8](repeating: 255, count: (n - 1) / 255) + [UInt8((n - 1) % 255)]
    }

    private static func palette(of pixels: [UInt32]) -> [UInt32] {
        var seen = [UInt32]()
        for p in pixels where !seen.contains(p) { seen.append(p) }
        return seen
    }

    private static func runs(of pixels: [UInt32]) -> [(pixel: UInt32, count: Int)] {
        var result = [(pixel: UInt32, count: Int)]()
        for p in pixels {
            if let last = result.last, last.pixel == p {
                result[result.count - 1].count += 1
            } else {
                result.append((p, 1))
            }
        }
        return result
    }

    /// Packs indices MSB-first via an explicit bit list, each row padded to a whole byte.
    private static func pack(_ indices: [Int], width: Int, bits: Int) -> [UInt8] {
        var bytes = [UInt8]()
        for row in stride(from: 0, to: indices.count, by: width) {
            var bitList = [UInt8]()
            for index in indices[row..<row + width] {
                for b in (0..<bits).reversed() { bitList.append(UInt8(index >> b & 1)) }
            }
            while bitList.count % 8 != 0 { bitList.append(0) }
            for i in stride(from: 0, to: bitList.count, by: 8) {
                bytes.append(bitList[i..<i + 8].reduce(0) { $0 << 1 | $1 })
            }
        }
        return bytes
    }

    private static func encodeTile(_ px: [UInt32], width: Int, _ kind: TileKind) -> [UInt8] {
        switch kind {
        case .raw:
            return [0] + px.flatMap(cpixel)
        case .solid:
            precondition(Set(px).count == 1)
            return [1] + cpixel(px[0])
        case .packed:
            let pal = palette(of: px)
            precondition((2...16).contains(pal.count))
            let bits = pal.count == 2 ? 1 : pal.count <= 4 ? 2 : 4
            let indices = px.map { pal.firstIndex(of: $0)! }
            return [UInt8(pal.count)] + pal.flatMap(cpixel) + pack(indices, width: width, bits: bits)
        case .plainRLE:
            return [128] + runs(of: px).flatMap { cpixel($0.pixel) + runLength($0.count) }
        case .paletteRLE:
            let pal = palette(of: px)
            precondition((2...127).contains(pal.count))
            return [UInt8(128 + pal.count)] + pal.flatMap(cpixel) + runs(of: px).flatMap { run -> [UInt8] in
                let index = UInt8(pal.firstIndex(of: run.pixel)!)
                return run.count == 1 ? [index] : [index | 0x80] + runLength(run.count)
            }
        }
    }

    /// Splits a row-major rect into 64×64 tiles (left→right, top→bottom) and encodes each with `kind(tileIndex)`.
    private static func encodeRect(_ px: [UInt32], width: Int, height: Int, kind: (Int) -> TileKind) -> [UInt8] {
        var bytes = [UInt8]()
        var tileIndex = 0
        for ty in stride(from: 0, to: height, by: 64) {
            for tx in stride(from: 0, to: width, by: 64) {
                let tw = min(64, width - tx), th = min(64, height - ty)
                var tile = [UInt32]()
                for row in ty..<ty + th { tile += px[row * width + tx..<row * width + tx + tw] }
                bytes += encodeTile(tile, width: tw, kind(tileIndex))
                tileIndex += 1
            }
        }
        return bytes
    }

    /// Asserts every framebuffer pixel equals the rect's pixel where covered, else `background`.
    private static func expectRect(
        _ fb: Framebuffer, _ px: [UInt32], x: Int, y: Int, width: Int, height: Int, background: UInt32 = 0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var mismatches = 0
        for fy in 0..<fb.height {
            for fx in 0..<fb.width {
                // An overflowing fx - x means the origin is astronomically far away, i.e. outside.
                let (col, colOverflow) = fx.subtractingReportingOverflow(x)
                let (row, rowOverflow) = fy.subtractingReportingOverflow(y)
                let inside = !colOverflow && !rowOverflow
                    && (0..<width).contains(col) && (0..<height).contains(row)
                if fb.pixel(x: fx, y: fy) != (inside ? px[row * width + col] : background) { mismatches += 1 }
            }
        }
        #expect(mismatches == 0, sourceLocation: sourceLocation)
    }

    private static func isMalformed(_ error: ZRLEError?) -> Bool {
        if case .malformed = error { return true }
        return false
    }

    // MARK: Encoder self-checks (hand-computed bytes)

    @Test func encoderProducesSpecBytes() {
        #expect(Self.runLength(1) == [0])
        #expect(Self.runLength(255) == [254])
        #expect(Self.runLength(256) == [255, 0])
        #expect(Self.runLength(300) == [255, 44])
        #expect(Self.runLength(511) == [255, 255, 0])
        #expect(Self.pack([1, 0, 1, 0, 1, 1], width: 3, bits: 1) == [0b1010_0000, 0b0110_0000])
        #expect(Self.pack([3, 0, 2], width: 3, bits: 2) == [0b1100_1000])
        #expect(Self.pack([4, 0, 15], width: 3, bits: 4) == [0x40, 0xF0])
        #expect(Self.cpixel(0x123456) == [0x56, 0x34, 0x12])
    }

    // MARK: Decoding

    @Test func rawThenSolidShareOneZlibStream() throws {
        let deflater = TestDeflater(), decoder = ZRLEDecoder()
        let fb = Framebuffer(width: 8, height: 6)
        let raw: [UInt32] = [0x112233, 0x445566, 0x778899, 0xAABBCC, 0xDDEEFF, 0x010203]
        let first = deflater.compress([0] + raw.flatMap(Self.cpixel))
        let second = deflater.compress([1] + Self.cpixel(0xFEDCBA))
        try decoder.decode(first, x: 1, y: 1, width: 3, height: 2, into: fb)
        try decoder.decode(second, x: 5, y: 3, width: 2, height: 2, into: fb)
        for (i, p) in raw.enumerated() { #expect(fb.pixel(x: 1 + i % 3, y: 1 + i / 3) == p) }
        for (px, py) in [(5, 3), (6, 3), (5, 4), (6, 4)] { #expect(fb.pixel(x: px, y: py) == 0xFEDCBA) }
        #expect(fb.pixel(x: 4, y: 3) == 0 && fb.pixel(x: 7, y: 5) == 0 && fb.pixel(x: 0, y: 0) == 0)
        // The second chunk has no zlib header, so it is only decodable by the persistent stream.
        #expect(throws: ZRLEError.self) {
            try ZRLEDecoder().decode(second, x: 0, y: 0, width: 2, height: 2, into: Framebuffer(width: 2, height: 2))
        }
    }

    @Test func packedPaletteLiteralBytes() throws {
        let deflater = TestDeflater(), decoder = ZRLEDecoder()
        let fb = Framebuffer(width: 3, height: 2)
        // p=2, 1 bit/px, width 3 → rows [1,0,1] = 0xA0 and [0,1,1] = 0x60.
        let tile: [UInt8] = [2] + Self.cpixel(0x0000FF) + Self.cpixel(0xFF0000) + [0xA0, 0x60]
        try decoder.decode(deflater.compress(tile), x: 0, y: 0, width: 3, height: 2, into: fb)
        let expected: [UInt32] = [0xFF0000, 0x0000FF, 0xFF0000, 0x0000FF, 0xFF0000, 0xFF0000]
        Self.expectRect(fb, expected, x: 0, y: 0, width: 3, height: 2)
        // p=5, 4 bits/px, width 3 → row [4,0,2] = 0x40 0x20.
        let pal: [UInt32] = [0x10, 0x20, 0x30, 0x40, 0x50]
        let tile4: [UInt8] = [5] + pal.flatMap(Self.cpixel) + [0x40, 0x20]
        try decoder.decode(deflater.compress(tile4), x: 0, y: 1, width: 3, height: 1, into: fb)
        #expect([fb.pixel(x: 0, y: 1), fb.pixel(x: 1, y: 1), fb.pixel(x: 2, y: 1)] == [0x50, 0x10, 0x30])
    }

    @Test func packedPaletteAllSizesAndOddWidths() throws {
        let deflater = TestDeflater(), decoder = ZRLEDecoder()
        for p in [2, 3, 4, 5, 7, 16] {
            for width in [1, 3, 5, 7, 9, 63, 64] {
                let height = 3
                let pal = (0..<p).map { UInt32($0 * 0x0F0E0D + 0x010101) }
                let px = (0..<width * height).map { pal[($0 * 7 + $0 / width) % p] }
                let fb = Framebuffer(width: 66, height: 4)
                fb.fill(x: 0, y: 0, width: 66, height: 4, pixel: 0x777777)
                let bytes = Self.encodeRect(px, width: width, height: height) { _ in
                    Self.palette(of: px).count >= 2 ? .packed : .raw
                }
                try decoder.decode(deflater.compress(bytes), x: 1, y: 1, width: width, height: height, into: fb)
                Self.expectRect(fb, px, x: 1, y: 1, width: width, height: height, background: 0x777777)
            }
        }
    }

    @Test func plainRLEWithLongRuns() throws {
        let deflater = TestDeflater(), decoder = ZRLEDecoder()
        let fb = Framebuffer(width: 32, height: 16)
        // 512 px: run 256 ([255, 0]), run 255 ([254]), run 1 ([0]).
        let tile: [UInt8] = [128]
            + Self.cpixel(0x0A0B0C) + [255, 0]
            + Self.cpixel(0x112233) + [254]
            + Self.cpixel(0xFFFFFF) + [0]
        try decoder.decode(deflater.compress(tile), x: 0, y: 0, width: 32, height: 16, into: fb)
        let px = [UInt32](repeating: 0x0A0B0C, count: 256) + [UInt32](repeating: 0x112233, count: 255) + [0xFFFFFF]
        Self.expectRect(fb, px, x: 0, y: 0, width: 32, height: 16)
        // A single run covering a whole 64×64 tile: 4096 - 1 = 16·255 + 15.
        let fb2 = Framebuffer(width: 64, height: 64)
        let full: [UInt8] = [128] + Self.cpixel(0x123456) + [UInt8](repeating: 255, count: 16) + [15]
        try decoder.decode(deflater.compress(full), x: 0, y: 0, width: 64, height: 64, into: fb2)
        Self.expectRect(fb2, [UInt32](repeating: 0x123456, count: 4096), x: 0, y: 0, width: 64, height: 64)
    }

    @Test func paletteRLEMixesSinglesAndRuns() throws {
        let deflater = TestDeflater(), decoder = ZRLEDecoder()
        let fb = Framebuffer(width: 20, height: 20)
        let pal: [UInt32] = [0xAA0000, 0x00BB00, 0x0000CC]
        // 400 px: single 0, run 1×5, single 2, run 0×300 ([255, 44]),
        // run 2 of length 1 with bit 7 set ([0], explicit), run 1×92.
        let tile: [UInt8] = [131] + pal.flatMap(Self.cpixel)
            + [0x00] + [0x81, 4] + [0x02] + [0x80, 255, 44] + [0x82, 0] + [0x81, 91]
        try decoder.decode(deflater.compress(tile), x: 0, y: 0, width: 20, height: 20, into: fb)
        var px: [UInt32] = [pal[0]] + [UInt32](repeating: pal[1], count: 5) + [pal[2]]
        px += [UInt32](repeating: pal[0], count: 300) + [pal[2]] + [UInt32](repeating: pal[1], count: 92)
        Self.expectRect(fb, px, x: 0, y: 0, width: 20, height: 20)
    }

    @Test func multiTileRectAtOffset() throws {
        let deflater = TestDeflater(), decoder = ZRLEDecoder()
        let width = 70, height = 65, ox = 3, oy = 2
        let fb = Framebuffer(width: 80, height: 70)
        // Four tiles: 64×64, 6×64, 64×1, 6×1 — each with content suited to a different subencoding.
        var px = [UInt32](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                let p: UInt32 = switch (col < 64, row < 64) {
                case (true, true): [0x100000, 0x200000, 0x300000][(col / 5 + row) % 3]
                case (false, true): UInt32(row << 8 | col)
                case (true, false): 0x00ABCD
                case (false, false): col % 2 == 0 ? 0x111111 : 0x222222
                }
                px[row * width + col] = p
            }
        }
        let kinds: [TileKind] = [.paletteRLE, .raw, .solid, .packed]
        let first = Self.encodeRect(px, width: width, height: height) { kinds[$0] }
        try decoder.decode(deflater.compress(first), x: ox, y: oy, width: width, height: height, into: fb)
        Self.expectRect(fb, px, x: ox, y: oy, width: width, height: height)
        // Same content again with other subencodings on the same streams.
        let alternate: [TileKind] = [.packed, .plainRLE, .plainRLE, .paletteRLE]
        fb.fill(x: 0, y: 0, width: 80, height: 70, pixel: 0)
        let second = Self.encodeRect(px, width: width, height: height) { alternate[$0] }
        try decoder.decode(deflater.compress(second), x: ox, y: oy, width: width, height: height, into: fb)
        Self.expectRect(fb, px, x: ox, y: oy, width: width, height: height)
    }

    @Test func rectPartiallyOutsideFramebuffer() throws {
        let deflater = TestDeflater(), decoder = ZRLEDecoder()
        let width = 70, height = 65
        let px = (0..<width * height).map { UInt32(($0 % 251) << 8 | $0 % 7) }
        let kinds: [TileKind] = [.raw, .plainRLE, .raw, .paletteRLE]
        let origins = [
            (5, 5), (-10, -3), (-69, 64), (100, 100), (-100, -100),
            (Int.max, Int.max), (Int.min, Int.min), (Int.max - 10, 0),
        ]
        for (x, y) in origins {
            let fb = Framebuffer(width: 10, height: 10)
            let bytes = Self.encodeRect(px, width: width, height: height) { kinds[$0] }
            try decoder.decode(deflater.compress(bytes), x: x, y: y, width: width, height: height, into: fb)
            Self.expectRect(fb, px, x: x, y: y, width: width, height: height)
        }
    }

    @Test func largeRectGrowsOutputBufferThenSmallRectFollows() throws {
        let deflater = TestDeflater(), decoder = ZRLEDecoder()
        let width = 256, height = 192
        let px = (0..<width * height).map { UInt32(truncatingIfNeeded: $0 &* 2_654_435_761) & 0xFF_FFFF }
        let bytes = Self.encodeRect(px, width: width, height: height) { _ in .raw }
        #expect(bytes.count == 12 * (1 + 64 * 64 * 3))
        let fb = Framebuffer(width: width, height: height)
        try decoder.decode(deflater.compress(bytes), x: 0, y: 0, width: width, height: height, into: fb)
        Self.expectRect(fb, px, x: 0, y: 0, width: width, height: height)
        try decoder.decode(deflater.compress([1] + Self.cpixel(0x5A5A5A)), x: 10, y: 20, width: 3, height: 2, into: fb)
        for (fx, fy) in [(10, 20), (12, 21)] { #expect(fb.pixel(x: fx, y: fy) == 0x5A5A5A) }
        #expect(fb.pixel(x: 13, y: 20) == px[20 * width + 13] && fb.pixel(x: 9, y: 21) == px[21 * width + 9])
    }

    @Test func fullPaletteRLEWithHighIndices() throws {
        let deflater = TestDeflater(), decoder = ZRLEDecoder()
        let width = 23, height = 11  // 253 px = 64 singles (indices 0–63) + 63 runs of 3 (indices 64–126)
        let pal = (0..<127).map { UInt32($0) << 16 | UInt32(255 - $0) }
        var tile: [UInt8] = [255] + pal.flatMap(Self.cpixel)
        var px = [UInt32]()
        for i in 0..<64 {
            tile.append(UInt8(i))
            px.append(pal[i])
        }
        for i in 64..<127 {
            tile += [0x80 | UInt8(i), 2]
            px += [pal[i], pal[i], pal[i]]
        }
        #expect(tile.contains(0x80 | 64) && tile.contains(0x80 | 126) && px.count == width * height)
        let fb = Framebuffer(width: width, height: height)
        try decoder.decode(deflater.compress(tile), x: 0, y: 0, width: width, height: height, into: fb)
        Self.expectRect(fb, px, x: 0, y: 0, width: width, height: height)
    }

    @Test func worstCaseLegitimateEncodingsFitTheOutputBound() throws {
        let deflater = TestDeflater(), decoder = ZRLEDecoder()
        let width = 128, height = 128
        let fb = Framebuffer(width: width, height: height)
        // Plain RLE of all-distinct single pixels: 1 + 4 bytes/px per tile.
        let distinct = (0..<width * height).map { UInt32($0) }
        let plain = Self.encodeRect(distinct, width: width, height: height) { _ in .plainRLE }
        #expect(plain.count == 4 * (1 + 4 * 64 * 64))
        try decoder.decode(deflater.compress(plain), x: 0, y: 0, width: width, height: height, into: fb)
        Self.expectRect(fb, distinct, x: 0, y: 0, width: width, height: height)
        // Palette RLE with a full 127-colour palette, every pixel an explicit run of 1: 1 + 381 + 2 bytes/px.
        let pal = (0..<127).map { UInt32($0 * 0x010203) }
        var tile: [UInt8] = [255] + pal.flatMap(Self.cpixel)
        for i in 0..<64 * 64 { tile += [0x80 | UInt8(i % 127), 0] }
        let bytes = [UInt8]((0..<4).map { _ in tile }.joined())
        try decoder.decode(deflater.compress(bytes), x: 0, y: 0, width: width, height: height, into: fb)
        let tilePx = (0..<64 * 64).map { pal[$0 % 127] }
        let rectPx = (0..<width * height).map { tilePx[($0 / width % 64) * 64 + $0 % width % 64] }
        Self.expectRect(fb, rectPx, x: 0, y: 0, width: width, height: height)
    }

    @Test func invalidSubencodingsThrow() {
        for sub: UInt8 in [17, 64, 127, 129] {
            let tile = [sub] + [UInt8](repeating: 0, count: 16 * 3)
            let error = #expect(throws: ZRLEError.self) {
                try ZRLEDecoder().decode(
                    TestDeflater().compress(tile), x: 0, y: 0, width: 4, height: 4,
                    into: Framebuffer(width: 4, height: 4))
            }
            #expect(Self.isMalformed(error), "subencoding \(sub)")
        }
    }

    @Test func malformedTilesThrow() {
        let cases: [(String, [UInt8])] = [
            ("plain RLE run past tile end", [128] + Self.cpixel(1) + [16]),
            ("plain RLE second run past end", [128] + Self.cpixel(1) + [9] + Self.cpixel(2) + [6]),
            ("palette RLE run past tile end", [130] + Self.cpixel(1) + Self.cpixel(2) + [0x81, 255, 0]),
            ("packed index out of range", [3] + Self.cpixel(1) + Self.cpixel(2) + Self.cpixel(3) + [0xC0] + [0, 0, 0]),
            ("truncated raw", [0] + [UInt8](repeating: 0, count: 47)),
            ("truncated solid", [1, 0, 0]),
            ("truncated run length", [128] + Self.cpixel(1) + [255]),
            ("missing tile", []),
        ]
        for (name, tile) in cases {
            let error = #expect(throws: ZRLEError.self, "\(name)") {
                try ZRLEDecoder().decode(
                    TestDeflater().compress(tile), x: 0, y: 0, width: 4, height: 4,
                    into: Framebuffer(width: 4, height: 4))
            }
            #expect(Self.isMalformed(error), "\(name)")
        }
    }

    /// Complete 4×4 tiles whose only defect is a palette index ≥ the palette size.
    @Test(arguments: [
        [0x82, 15],       // run of 16 with index 2
        [0x00, 0x82, 14], // one valid pixel, then a run of 15 with index 2
    ] as [[UInt8]])
    func paletteRLEIndexOutOfRangeThrows(_ pixels: [UInt8]) {
        let tile = [130] + Self.cpixel(1) + Self.cpixel(2) + pixels
        #expect(throws: ZRLEError.malformed("palette index out of range")) {
            try ZRLEDecoder().decode(
                TestDeflater().compress(tile), x: 0, y: 0, width: 4, height: 4,
                into: Framebuffer(width: 4, height: 4))
        }
    }

    @Test func corruptZlibDataThrowsZlibError() {
        #expect(throws: ZRLEError.zlib(Z_DATA_ERROR)) {
            try ZRLEDecoder().decode(Data([0x00, 0x01, 0x02, 0x03]), x: 0, y: 0, width: 1, height: 1,
                                     into: Framebuffer(width: 1, height: 1))
        }
    }

    @Test func decompressedOutputIsBounded() {
        let bomb = TestDeflater().compress([1] + [UInt8](repeating: 0, count: 1 << 20))
        let error = #expect(throws: ZRLEError.self) {
            try ZRLEDecoder().decode(bomb, x: 0, y: 0, width: 1, height: 1, into: Framebuffer(width: 1, height: 1))
        }
        #expect(Self.isMalformed(error))
    }
}
