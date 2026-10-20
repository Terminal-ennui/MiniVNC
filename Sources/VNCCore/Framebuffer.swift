import CoreGraphics
import Foundation

/// BGRX pixels (PixelFormat.bgrx32) in a CGBitmapContext; origin top-left, memory row 0 = top row.
/// Pixel values are R<<16 | G<<8 | B. Every operation clips to bounds and tolerates any input values.
/// Sizes are capped at 16384 per side and 2^27 pixels in total.
/// Not thread-safe: confine each Framebuffer to its owning actor.
public final class Framebuffer {
    private static let maxSide = 16384
    private static let maxPixels = 1 << 27

    public private(set) var width: Int
    public private(set) var height: Int
    private var context: CGContext
    private var base: UnsafeMutablePointer<UInt32>

    /// Sizes < 1 are treated as 1; over-cap sizes are clamped (height first gives way to the pixel cap).
    /// Falls back to 1×1 if the bitmap can't be allocated.
    public init(width: Int, height: Int) {
        let w = min(max(width, 1), Self.maxSide)
        let h = min(max(height, 1), Self.maxSide, Self.maxPixels / w)
        let made = Self.makeBitmap(w, h) ?? Self.makeBitmap(1, 1)
        guard let made else { fatalError("Framebuffer: cannot allocate a 1×1 bitmap") }
        context = made.context
        base = made.base
        self.width = made.context.width
        self.height = made.context.height
    }

    /// Sizes < 1 are treated as 1. An over-cap size or failed allocation leaves the framebuffer unchanged.
    public func resize(width newWidth: Int, height newHeight: Int) {
        let w = max(newWidth, 1), h = max(newHeight, 1)
        guard w != width || h != height,
              w <= Self.maxSide, h <= Self.maxSide, w * h <= Self.maxPixels,
              let made = Self.makeBitmap(w, h) else { return }
        let cols = min(width, w)
        for row in 0..<min(height, h) {
            memcpy(made.base + row * w, base + row * width, cols * 4)
        }
        context = made.context
        base = made.base
        width = w
        height = h
    }

    public func fill(x: Int, y: Int, width w: Int, height h: Int, pixel: UInt32) {
        guard let cols = Self.span(count: w, limit: width, origins: x, x),
              let rows = Self.span(count: h, limit: height, origins: y, y) else { return }
        let first = base + ((y + rows.lowerBound) * width + (x + cols.lowerBound))
        let rowBytes = cols.count * 4
        withUnsafeBytes(of: pixel.littleEndian) { memset_pattern4(first, $0.baseAddress, rowBytes) }
        for r in 1..<rows.count {
            memcpy(first + r * width, first, rowBytes)
        }
    }

    /// `pixels` holds `height` tightly packed rows of `width` 4-byte little-endian pixels (RFB Raw).
    /// Rows the buffer is too short for are skipped.
    public func blit(x: Int, y: Int, width w: Int, height h: Int, pixels: UnsafeRawBufferPointer) {
        guard w > 0, h > 0, let src = pixels.baseAddress else { return }
        let (srcRowBytes, overflow) = w.multipliedReportingOverflow(by: 4)
        guard !overflow else { return }
        let available = min(h, pixels.count / srcRowBytes)
        guard let cols = Self.span(count: w, limit: width, origins: x, x),
              let rows = Self.span(count: available, limit: height, origins: y, y) else { return }
        let dx = x + cols.lowerBound, rowBytes = cols.count * 4
        for r in rows {
            memcpy(base + ((y + r) * width + dx), src + (r * srcRowBytes + cols.lowerBound * 4), rowBytes)
        }
    }

    /// Overlap-safe (memmove semantics); only pixels whose source and destination are both in bounds are copied.
    public func copyRect(srcX: Int, srcY: Int, x: Int, y: Int, width w: Int, height h: Int) {
        guard srcX != x || srcY != y,
              let cols = Self.span(count: w, limit: width, origins: srcX, x),
              let rows = Self.span(count: h, limit: height, origins: srcY, y) else { return }
        let sx = srcX + cols.lowerBound, dx = x + cols.lowerBound, rowBytes = cols.count * 4
        let downward = y > srcY
        for i in 0..<rows.count {
            let r = downward ? rows.upperBound - 1 - i : rows.lowerBound + i
            memmove(base + ((y + r) * width + dx), base + ((srcY + r) * width + sx), rowBytes)
        }
    }

    public func pixel(x: Int, y: Int) -> UInt32 {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return 0 }
        return UInt32(littleEndian: base[y * width + x]) & 0x00FF_FFFF
    }

    /// Relies on CoreGraphics' copy-on-write snapshot: later writes don't alter the returned image.
    public func makeImage() -> CGImage? {
        context.makeImage()
    }

    /// Zeroed (black) memory owned by the context, freed by its release callback.
    private static func makeBitmap(_ w: Int, _ h: Int) -> (context: CGContext, base: UnsafeMutablePointer<UInt32>)? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let raw = calloc(w * h, 4) else { return nil }
        guard let ctx = CGContext(
            data: raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue,
            releaseCallback: { _, data in free(data) }, releaseInfo: nil)
        else {
            free(raw)
            return nil
        }
        return (ctx, raw.bindMemory(to: UInt32.self, capacity: w * h))
    }

    /// Offsets k in 0..<count for which both a + k and b + k lie in 0..<limit; overflow-safe for any input.
    private static func span(count: Int, limit: Int, origins a: Int, _ b: Int) -> Range<Int>? {
        let lo = max(0, minus(0, a), minus(0, b))
        let hi = min(count, minus(limit, a), minus(limit, b))
        return lo < hi ? lo..<hi : nil
    }

    private static func minus(_ a: Int, _ b: Int) -> Int {
        let (r, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? (b < 0 ? .max : .min) : r
    }
}
