import CoreGraphics
import Foundation
import Testing
@testable import VNCCore

struct FramebufferTests {
    private static func snapshot(_ fb: Framebuffer) -> [[UInt32]] {
        (0..<fb.height).map { y in (0..<fb.width).map { x in fb.pixel(x: x, y: y) } }
    }

    /// Whether origin <= p < origin + count, without overflow (an overflowing p - origin exceeds any count).
    private static func inSpan(_ p: Int, _ origin: Int, _ count: Int) -> Bool {
        let (d, overflow) = p.subtractingReportingOverflow(origin)
        return p >= origin && !overflow && d < count
    }

    /// Every pixel gets a unique value (dimensions < 256).
    private static func makeGradient(width: Int, height: Int) -> Framebuffer {
        let fb = Framebuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                fb.fill(x: x, y: y, width: 1, height: 1, pixel: UInt32(y << 8 | x) + 0x01_0000)
            }
        }
        return fb
    }

    /// Little-endian 4-byte pixels, tightly packed, value(col, row) = 0xAB0000 | row << 8 | col.
    private static func blitSource(width: Int, height: Int, xByte: UInt8 = 0) -> [UInt8] {
        var bytes = [UInt8]()
        for row in 0..<height {
            for col in 0..<width {
                bytes += [UInt8(col), UInt8(row), 0xAB, xByte]
            }
        }
        return bytes
    }

    private static func blitValue(col: Int, row: Int) -> UInt32 {
        0xAB_0000 | UInt32(row) << 8 | UInt32(col)
    }

    @Test func initIsBlackAndClampsSize() {
        let fb = Framebuffer(width: 3, height: 2)
        #expect(fb.width == 3 && fb.height == 2)
        #expect(Self.snapshot(fb) == [[0, 0, 0], [0, 0, 0]])
        let tiny = Framebuffer(width: 0, height: -4)
        #expect(tiny.width == 1 && tiny.height == 1)
        #expect(tiny.pixel(x: 0, y: 0) == 0)
    }

    @Test func initClampsToPixelCap() {
        let wide = Framebuffer(width: 100_000, height: 1)
        #expect(wide.width == 16384 && wide.height == 1)
        let huge = Framebuffer(width: 16384, height: 16384)
        #expect(huge.width == 16384 && huge.height == 8192)
        let hostile = Framebuffer(width: Int.max, height: Int.max)
        #expect(hostile.width == 16384 && hostile.height == 8192)
    }

    @Test func pixelOutOfBoundsIsZero() {
        let fb = Framebuffer(width: 2, height: 2)
        fb.fill(x: 0, y: 0, width: 2, height: 2, pixel: 0xFFFFFF)
        for (x, y) in [(-1, 0), (0, -1), (2, 0), (0, 2), (Int.min, Int.max)] {
            #expect(fb.pixel(x: x, y: y) == 0)
        }
    }

    @Test func fillSetsRect() {
        let fb = Framebuffer(width: 4, height: 3)
        fb.fill(x: 1, y: 1, width: 2, height: 2, pixel: 0x123456)
        #expect(Self.snapshot(fb) == [
            [0, 0, 0, 0],
            [0, 0x123456, 0x123456, 0],
            [0, 0x123456, 0x123456, 0],
        ])
    }

    @Test func fillClips() {
        let p: UInt32 = 0x00FF00
        let cases: [(x: Int, y: Int, w: Int, h: Int)] = [
            (-2, -1, 4, 3), (3, 2, 10, 10), (-5, -5, 100, 100), (0, 0, 0, 3), (0, 0, 3, -1),
            (4, 0, 2, 2), (0, 3, 2, 2), (-3, 0, 3, 3),
            (Int.min, Int.min, Int.max, Int.max), (Int.max, Int.max, Int.max, Int.max),
            (-5, -5, Int.max, Int.max), (0, 0, Int.min, Int.min),
        ]
        for c in cases {
            let fb = Framebuffer(width: 4, height: 3)
            fb.fill(x: c.x, y: c.y, width: c.w, height: c.h, pixel: p)
            let expected = (0..<3).map { py in
                (0..<4).map { px -> UInt32 in
                    Self.inSpan(px, c.x, c.w) && Self.inSpan(py, c.y, c.h) ? p : 0
                }
            }
            #expect(Self.snapshot(fb) == expected, "fill \(c)")
        }
    }

    @Test func blitCopiesLittleEndianRows() {
        let fb = Framebuffer(width: 5, height: 4)
        let src = Self.blitSource(width: 3, height: 2)
        src.withUnsafeBytes { fb.blit(x: 1, y: 2, width: 3, height: 2, pixels: $0) }
        for y in 0..<4 {
            for x in 0..<5 {
                let inside = (1..<4).contains(x) && (2..<4).contains(y)
                #expect(fb.pixel(x: x, y: y) == (inside ? Self.blitValue(col: x - 1, row: y - 2) : 0))
            }
        }
    }

    @Test func pixelIgnoresPaddingByte() {
        let fb = Framebuffer(width: 1, height: 1)
        Self.blitSource(width: 1, height: 1, xByte: 0xFF).withUnsafeBytes {
            fb.blit(x: 0, y: 0, width: 1, height: 1, pixels: $0)
        }
        #expect(fb.pixel(x: 0, y: 0) == 0xAB_0000)
    }

    @Test func blitClipsAndOffsetsSource() {
        let cases: [(x: Int, y: Int)] = [(-2, -1), (3, 2), (-1, 3), (4, -2), (-10, 0), (0, 10)]
        for c in cases {
            let fb = Framebuffer(width: 5, height: 4)
            Self.blitSource(width: 4, height: 3).withUnsafeBytes {
                fb.blit(x: c.x, y: c.y, width: 4, height: 3, pixels: $0)
            }
            for y in 0..<4 {
                for x in 0..<5 {
                    let col = x - c.x, row = y - c.y
                    let inside = (0..<4).contains(col) && (0..<3).contains(row)
                    let expected = inside ? Self.blitValue(col: col, row: row) : 0
                    #expect(fb.pixel(x: x, y: y) == expected, "blit \(c) at \(x),\(y)")
                }
            }
        }
    }

    @Test func blitIgnoresRowsMissingFromShortBuffer() {
        let fb = Framebuffer(width: 4, height: 3)
        let src = Self.blitSource(width: 4, height: 3)
        src.withUnsafeBytes {
            fb.blit(x: 0, y: 0, width: 4, height: 3, pixels: UnsafeRawBufferPointer(rebasing: $0[0..<18]))
        }
        #expect((0..<4).allSatisfy { fb.pixel(x: $0, y: 0) == Self.blitValue(col: $0, row: 0) })
        #expect((0..<4).allSatisfy { fb.pixel(x: $0, y: 1) == 0 && fb.pixel(x: $0, y: 2) == 0 })
    }

    @Test func blitHostileSizesDoNotCrash() {
        let fb = Framebuffer(width: 4, height: 3)
        let src = Self.blitSource(width: 2, height: 2)
        src.withUnsafeBytes { buf in
            fb.blit(x: 0, y: 0, width: Int.max, height: Int.max, pixels: buf)
            fb.blit(x: 0, y: 0, width: Int.max / 4 + 1, height: 1, pixels: buf)
            fb.blit(x: Int.min, y: Int.min, width: 2, height: 2, pixels: buf)
            fb.blit(x: Int.max, y: Int.max, width: 2, height: 2, pixels: buf)
            fb.blit(x: 0, y: 0, width: 0, height: 2, pixels: buf)
            fb.blit(x: 0, y: 0, width: -2, height: -2, pixels: buf)
            fb.blit(x: 0, y: 0, width: 2, height: 2, pixels: UnsafeRawBufferPointer(start: nil, count: 0))
        }
        #expect(Self.snapshot(fb).allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test func copyRectMatchesReference() {
        let cases: [(sx: Int, sy: Int, x: Int, y: Int, w: Int, h: Int)] = [
            (2, 1, 5, 4, 8, 6),   // overlap, dst right/below
            (5, 4, 2, 1, 8, 6),   // overlap, dst left/above
            (0, 3, 3, 3, 10, 2),  // same rows, dst right
            (3, 3, 0, 3, 10, 2),  // same rows, dst left
            (2, 0, 2, 3, 5, 8),   // same columns, dst below
            (2, 3, 2, 0, 5, 8),   // same columns, dst above
            (1, 1, 1, 1, 6, 6),   // identity
            (-3, -2, 4, 4, 6, 6), // source partly outside top-left
            (4, 4, -3, -2, 6, 6), // dest partly outside top-left
            (14, 10, 0, 0, 5, 5), // source partly outside bottom-right
            (0, 0, 14, 10, 5, 5), // dest partly outside bottom-right
            (0, 0, 0, 0, 100, 100),
            (1, 0, 0, 0, Int.max, 1),
            (100, 100, 0, 0, 4, 4), (0, 0, 100, 100, 4, 4), (-50, 0, 0, 0, 10, 10),
            (0, 0, 2, 2, 0, 5), (0, 0, 2, 2, 5, -1),
        ]
        for c in cases {
            let fb = Self.makeGradient(width: 16, height: 12)
            let before = Self.snapshot(fb)
            fb.copyRect(srcX: c.sx, srcY: c.sy, x: c.x, y: c.y, width: c.w, height: c.h)
            let expected = (0..<12).map { py in
                (0..<16).map { px -> UInt32 in
                    let col = px - c.x, row = py - c.y
                    let sx = c.sx + col, sy = c.sy + row
                    guard col >= 0, row >= 0, col < c.w, row < c.h,
                          (0..<16).contains(sx), (0..<12).contains(sy) else { return before[py][px] }
                    return before[sy][sx]
                }
            }
            #expect(Self.snapshot(fb) == expected, "copyRect \(c)")
        }
    }

    @Test func copyRectHostileValuesDoNotCrash() {
        let fb = Self.makeGradient(width: 16, height: 12)
        let before = Self.snapshot(fb)
        fb.copyRect(srcX: Int.min, srcY: Int.min, x: 0, y: 0, width: Int.max, height: Int.max)
        fb.copyRect(srcX: 0, srcY: 0, x: Int.min, y: Int.min, width: Int.max, height: Int.max)
        fb.copyRect(srcX: Int.max, srcY: Int.max, x: 0, y: 0, width: Int.max, height: Int.max)
        fb.copyRect(srcX: 0, srcY: 0, x: Int.max, y: Int.max, width: Int.max, height: Int.max)
        fb.copyRect(srcX: Int.min, srcY: 0, x: Int.max, y: 0, width: 5, height: 5)
        fb.copyRect(srcX: 0, srcY: 0, x: 0, y: 0, width: Int.min, height: Int.min)
        fb.copyRect(srcX: 0, srcY: 0, x: 0, y: 0, width: Int.max, height: Int.max)
        #expect(Self.snapshot(fb) == before)
    }

    @Test func resizeKeepsTopLeftContent() {
        let fb = Self.makeGradient(width: 4, height: 3)
        let before = Self.snapshot(fb)
        fb.resize(width: 6, height: 2)
        #expect(fb.width == 6 && fb.height == 2)
        #expect(Self.snapshot(fb) == (0..<2).map { y in (0..<6).map { x in x < 4 ? before[y][x] : 0 } })
        fb.resize(width: 3, height: 5)
        #expect(fb.width == 3 && fb.height == 5)
        #expect(Self.snapshot(fb) == (0..<5).map { y in (0..<3).map { x in y < 2 ? before[y][x] : 0 } })
        fb.resize(width: 3, height: 5)
        #expect(Self.snapshot(fb) == (0..<5).map { y in (0..<3).map { x in y < 2 ? before[y][x] : 0 } })
        fb.resize(width: -1, height: 0)
        #expect(fb.width == 1 && fb.height == 1 && fb.pixel(x: 0, y: 0) == before[0][0])
    }

    @Test func overCapResizeKeepsOldBufferAndSize() throws {
        let fb = Self.makeGradient(width: 4, height: 3)
        let before = Self.snapshot(fb)
        for (w, h) in [(16385, 1), (1, 16385), (16384, 16384), (Int.max, Int.max), (Int.max, 2)] {
            fb.resize(width: w, height: h)
            try #require(fb.width == 4 && fb.height == 3, "resize \(w)×\(h)")
            #expect(Self.snapshot(fb) == before, "resize \(w)×\(h)")
        }
    }

    /// Draws the image into an sRGB RGBA8 context (memory bytes R,G,B,A; row 0 = top) and returns those bytes.
    private static func rgbaBytes(of image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    @Test func makeImageHasSizeAndColours() throws {
        let fb = Framebuffer(width: 7, height: 5)
        fb.fill(x: 5, y: 1, width: 1, height: 1, pixel: 0x123456)
        let image = try #require(fb.makeImage())
        #expect(image.width == 7 && image.height == 5)
        let rgba = Self.rgbaBytes(of: image)
        let i = (1 * 7 + 5) * 4
        #expect(Array(rgba[i..<i + 4]) == [0x12, 0x34, 0x56, 0xFF])
        let j = (3 * 7 + 5) * 4
        #expect(Array(rgba[j..<j + 4]) == [0, 0, 0, 0xFF])
    }

    @Test(arguments: [4, 1024])
    func makeImageIsASnapshot(size: Int) throws {
        let fb = Framebuffer(width: size, height: size)
        fb.fill(x: 0, y: 0, width: size, height: size, pixel: 0x0000FF)
        let image = try #require(fb.makeImage())
        fb.fill(x: size - 1, y: size - 1, width: 1, height: 1, pixel: 0xFF0000)
        #expect(Array(Self.rgbaBytes(of: image).suffix(4)) == [0, 0, 0xFF, 0xFF])
        fb.fill(x: 0, y: 0, width: size, height: size, pixel: 0xFF0000)
        let rgba = Self.rgbaBytes(of: image)
        #expect(Array(rgba[0..<4]) == [0, 0, 0xFF, 0xFF])
        #expect(Array(rgba[(rgba.count - 4)...]) == [0, 0, 0xFF, 0xFF])
        fb.resize(width: 2, height: 2)
        #expect(Array(Self.rgbaBytes(of: image)[0..<4]) == [0, 0, 0xFF, 0xFF])
    }
}
