import CoreGraphics
import Testing
@testable import VNCCore

struct FitTransformTests {
    private func rect(view: CGSize, content: CGSize) -> CGRect {
        FitTransform(viewSize: view, contentSize: content).contentRect
    }

    @Test func letterboxesWideContentInTallView() {
        #expect(rect(view: CGSize(width: 1000, height: 1000), content: CGSize(width: 2000, height: 1000))
            == CGRect(x: 0, y: 250, width: 1000, height: 500))
    }

    @Test func pillarboxesTallContentInWideView() {
        #expect(rect(view: CGSize(width: 1000, height: 1000), content: CGSize(width: 500, height: 1000))
            == CGRect(x: 250, y: 0, width: 500, height: 1000))
    }

    @Test func exactFitFillsView() {
        #expect(rect(view: CGSize(width: 800, height: 600), content: CGSize(width: 800, height: 600))
            == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(rect(view: CGSize(width: 400, height: 300), content: CGSize(width: 800, height: 600))
            == CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    @Test func scalesUp() {
        #expect(rect(view: CGSize(width: 1600, height: 1200), content: CGSize(width: 800, height: 600))
            == CGRect(x: 0, y: 0, width: 1600, height: 1200))
        #expect(rect(view: CGSize(width: 2000, height: 1200), content: CGSize(width: 800, height: 600))
            == CGRect(x: 200, y: 0, width: 1600, height: 1200))
    }

    @Test func degenerateSizesGiveZeroRect() {
        let size = CGSize(width: 800, height: 600)
        #expect(rect(view: .zero, content: size) == .zero)
        #expect(rect(view: size, content: .zero) == .zero)
        #expect(rect(view: size, content: CGSize(width: 0, height: 600)) == .zero)
        #expect(rect(view: CGSize(width: 800, height: -1), content: size) == .zero)
        #expect(rect(view: size, content: CGSize(width: -800, height: 600)) == .zero)
    }

    // View 1000x1000, content 2000x1000 → rect (0, 250, 1000, 500), 2 pixels per point.
    private let wide = FitTransform(viewSize: CGSize(width: 1000, height: 1000),
                                    contentSize: CGSize(width: 2000, height: 1000))

    private func map(_ t: FitTransform, _ x: CGFloat, _ y: CGFloat) -> [UInt16] {
        let p = t.framebufferPoint(for: CGPoint(x: x, y: y))
        return [p.x, p.y]
    }

    @Test func mapsCorners() {
        #expect(map(wide, 0, 250) == [0, 0])
        #expect(map(wide, 999.75, 250) == [1999, 0])
        #expect(map(wide, 0, 749.75) == [0, 999])
        #expect(map(wide, 999.75, 749.75) == [1999, 999])
        #expect(map(wide, 1000, 750) == [1999, 999])
    }

    @Test func mapsCenter() {
        #expect(map(wide, 500, 500) == [1000, 500])
    }

    @Test func clampsLetterboxToNearestEdge() {
        #expect(map(wide, 500, 100) == [1000, 0])
        #expect(map(wide, 500, 900) == [1000, 999])
        let tall = FitTransform(viewSize: CGSize(width: 1000, height: 1000), contentSize: CGSize(width: 500, height: 1000))
        #expect(map(tall, 100, 10) == [0, 10])
        #expect(map(tall, 900, 10) == [499, 10])
    }

    @Test func clampsFarOutOfBoundsAndNonFinitePoints() {
        #expect(map(wide, -1e9, 1e9) == [0, 999])
        #expect(map(wide, 1e300, -1e300) == [1999, 0])
        #expect(map(wide, .infinity, -.infinity) == [1999, 0])
        #expect(map(wide, .nan, 500) == [0, 500])
    }

    @Test func mapsWhenUpscaled() {
        let t = FitTransform(viewSize: CGSize(width: 1600, height: 1200), contentSize: CGSize(width: 800, height: 600))
        #expect(map(t, 3, 5) == [1, 2])
        #expect(map(t, 1599, 1199) == [799, 599])
    }

    @Test func mapsCornersAtNonIntegerScale() {
        let t = FitTransform(viewSize: CGSize(width: 1000, height: 1000), contentSize: CGSize(width: 1366, height: 768))
        let r = t.contentRect
        #expect(map(t, r.minX, r.minY) == [0, 0])
        #expect(map(t, r.maxX, r.maxY) == [1365, 767])
        #expect(map(t, r.maxX - 0.5, r.maxY - 0.5) == [1365, 767])
    }

    @Test func degenerateTransformMapsToOrigin() {
        let t = FitTransform(viewSize: .zero, contentSize: CGSize(width: 800, height: 600))
        #expect(map(t, 10, 10) == [0, 0])
        let u = FitTransform(viewSize: CGSize(width: 800, height: 600), contentSize: .zero)
        #expect(map(u, 10, 10) == [0, 0])
    }

    @Test func clampsToUInt16Range() {
        let t = FitTransform(viewSize: CGSize(width: 100, height: 100), contentSize: CGSize(width: 100_000, height: 100_000))
        #expect(map(t, 100, 100) == [UInt16.max, UInt16.max])
    }
}

struct DesktopSizeTests {
    private func request(_ w: CGFloat, _ h: CGFloat) -> [UInt16] {
        let r = DesktopSize.request(for: CGSize(width: w, height: h))
        return [r.width, r.height]
    }

    @Test func floorsFractionalSizes() {
        #expect(request(1280.9, 800.2) == [1280, 800])
        #expect(request(399.99, 8192.5) == [400, 8192])
    }

    @Test func clampsToMinimum() {
        #expect(request(100, 50) == [400, 400])
        #expect(request(0, 0) == [400, 400])
        #expect(request(-10, 500) == [400, 500])
        #expect(request(400, 400) == [400, 400])
    }

    @Test func clampsToMaximum() {
        #expect(request(10_000, 9000) == [8192, 8192])
        #expect(request(300, 9000) == [400, 8192])
        #expect(request(8192, 8192) == [8192, 8192])
    }

    @Test func handlesNonFiniteSizes() {
        #expect(request(.nan, .infinity) == [400, 8192])
        #expect(request(-.infinity, .nan) == [400, 400])
    }

    private func window(_ remote: CGSize, _ available: CGSize) -> CGSize {
        DesktopSize.windowSize(remote: remote, available: available)
    }

    @Test func keepsRemoteSizeWhenItFits() {
        #expect(window(CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900)) == CGSize(width: 1280, height: 800))
        #expect(window(CGSize(width: 1440, height: 900), CGSize(width: 1440, height: 900)) == CGSize(width: 1440, height: 900))
    }

    @Test func shrinksTooWideRemote() {
        #expect(window(CGSize(width: 3000, height: 1000), CGSize(width: 1500, height: 1000)) == CGSize(width: 1500, height: 500))
    }

    @Test func shrinksTooTallRemote() {
        #expect(window(CGSize(width: 1000, height: 2000), CGSize(width: 1500, height: 1000)) == CGSize(width: 500, height: 1000))
    }

    @Test func shrinksWhenBothSidesTooLarge() {
        #expect(window(CGSize(width: 3840, height: 2160), CGSize(width: 1440, height: 875)) == CGSize(width: 1440, height: 810))
    }

    @Test func roundsDownToWholePoints() {
        #expect(window(CGSize(width: 1000, height: 999), CGSize(width: 500, height: 1000)) == CGSize(width: 500, height: 499))
        #expect(window(CGSize(width: 2880, height: 1800), CGSize(width: 1439.5, height: 900)) == CGSize(width: 1439, height: 899))
        #expect(window(CGSize(width: 3000, height: 1000), CGSize(width: 1000, height: 1000)) == CGSize(width: 1000, height: 333))
    }

    @Test func degenerateSizesGiveZero() {
        #expect(window(.zero, CGSize(width: 1440, height: 900)) == .zero)
        #expect(window(CGSize(width: 1280, height: 800), .zero) == .zero)
        #expect(window(CGSize(width: 1280, height: -1), CGSize(width: 1440, height: 900)) == .zero)
    }
}
