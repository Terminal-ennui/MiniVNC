import CoreGraphics

/// Maps between a view and framebuffer content drawn aspect-fit (letterboxed) inside it.
public struct FitTransform: Equatable, Sendable {
    public let viewSize: CGSize
    public let contentSize: CGSize

    public init(viewSize: CGSize, contentSize: CGSize) {
        self.viewSize = viewSize
        self.contentSize = contentSize
    }

    /// Aspect-fit rect of the content, centered, in top-left-origin view space. Scales up and down;
    /// any zero or negative size gives `.zero`.
    public var contentRect: CGRect {
        guard isPositive(viewSize), isPositive(contentSize) else { return .zero }
        let size = aspectFit(contentSize, in: viewSize)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// View point (top-left origin) → framebuffer pixel, clamped to the framebuffer, so points in the
    /// letterbox map to the nearest edge.
    public func framebufferPoint(for viewPoint: CGPoint) -> (x: UInt16, y: UInt16) {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        return (
            Self.pixel((viewPoint.x - rect.minX) * contentSize.width / rect.width, extent: contentSize.width),
            Self.pixel((viewPoint.y - rect.minY) * contentSize.height / rect.height, extent: contentSize.height)
        )
    }

    private static func pixel(_ value: CGFloat, extent: CGFloat) -> UInt16 {
        guard !value.isNaN else { return 0 }
        let last = min(max(extent.rounded(.down) - 1, 0), CGFloat(UInt16.max))
        return UInt16(min(max(value.rounded(.down), 0), last))
    }
}

public enum DesktopSize {
    public static let minimum = 400
    public static let maximum = 8192

    /// Size to ask the server for, given the window's content size in points: each side floored and
    /// clamped to `minimum...maximum`.
    public static func request(for size: CGSize) -> (width: UInt16, height: UInt16) {
        (clamp(size.width), clamp(size.height))
    }

    /// Window content size that shows a `remote`-sized desktop without upscaling, shrunk (aspect
    /// preserved) to fit inside `available`, rounded down to whole points. Degenerate sizes give `.zero`.
    public static func windowSize(remote: CGSize, available: CGSize) -> CGSize {
        guard isPositive(remote), isPositive(available) else { return .zero }
        let size = remote.width <= available.width && remote.height <= available.height
            ? remote
            : aspectFit(remote, in: available)
        return CGSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
    }

    private static func clamp(_ value: CGFloat) -> UInt16 {
        guard !value.isNaN else { return UInt16(minimum) }
        return UInt16(min(max(value.rounded(.down), CGFloat(minimum)), CGFloat(maximum)))
    }
}

private func isPositive(_ size: CGSize) -> Bool {
    size.width > 0 && size.height > 0
}

/// Largest size with `content`'s aspect ratio inside `bounds`. The constraining side is taken from
/// `bounds` exactly and the other side computed with a single division, so whole-number results stay exact.
private func aspectFit(_ content: CGSize, in bounds: CGSize) -> CGSize {
    bounds.width * content.height <= bounds.height * content.width
        ? CGSize(width: bounds.width, height: content.height * bounds.width / content.width)
        : CGSize(width: content.width * bounds.height / content.height, height: bounds.height)
}
