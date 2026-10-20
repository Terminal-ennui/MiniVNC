import CoreGraphics
import Foundation
import Testing
import zlib
@testable import VNCCore

@Suite(.timeLimit(.minutes(1)))
struct RFBSessionTests {
    @Test func sendsSetupAfterHandshake() async throws {
        let h = try await Harness.connect(width: 64, height: 48)
        #expect(Array(h.transport.sent.suffix(3)) == [
            ClientMessage.setPixelFormat(.bgrx32),
            ClientMessage.setEncodings(RFBSession.encodings),
            ClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: 64, height: 48),
        ])
    }

    @Test func rawRectUpdatesFrameAndRequestsIncremental() async throws {
        var h = try await Harness.connect(width: 4, height: 4)
        h.feed(Server.update([Server.rect(x: 1, y: 2, w: 2, h: 1, .raw, raw([0xFF0000, 0x00FF00]))]))
        let frame = try #require(await h.nextFrame())
        #expect(frame.width == 4 && frame.height == 4)
        #expect(rgb(frame, 1, 2) == 0xFF0000)
        #expect(rgb(frame, 2, 2) == 0x00FF00)
        #expect(rgb(frame, 0, 0) == 0)
        #expect(await h.waitForSent(ClientMessage.framebufferUpdateRequest(incremental: true, x: 0, y: 0, width: 4, height: 4)))
    }

    @Test func copyRectMovesPixels() async throws {
        var h = try await Harness.connect(width: 4, height: 4)
        h.feed(Server.update([
            Server.rect(x: 0, y: 0, w: 1, h: 1, .raw, raw([0x123456])),
            Server.rect(x: 3, y: 3, w: 1, h: 1, .copyRect, u16(0) + u16(0)),
        ]))
        let frame = try #require(await h.nextFrame())
        #expect(rgb(frame, 3, 3) == 0x123456)
    }

    @Test func zrleRect() async throws {
        var h = try await Harness.connect(width: 8, height: 8)
        let tile = Data([1, 0x56, 0x34, 0x12]) // solid tile, CPIXEL B,G,R
        let compressed = deflateSync(tile)
        h.feed(Server.update([Server.rect(x: 0, y: 0, w: 8, h: 8, .zrle, u32(UInt32(compressed.count)) + compressed)]))
        let frame = try #require(await h.nextFrame())
        #expect(rgb(frame, 7, 7) == 0x123456)
    }

    @Test func extendedDesktopSizeAnnouncesThenResizesOnRequest() async throws {
        var h = try await Harness.connect(width: 800, height: 600)
        let screen = Screen(id: 7, x: 0, y: 0, width: 800, height: 600, flags: 0)
        h.feed(Server.update([Server.extendedDesktopSize(reason: 0, status: 0, w: 800, h: 600, [screen])]))
        #expect(await h.next() == .desktopResizeSupport(true))
        _ = await h.nextFrame()

        await h.session.requestDesktopSize(width: 1280, height: 720)
        let expected = ClientMessage.setDesktopSize(
            width: 1280, height: 720, screens: [Screen(id: 7, x: 0, y: 0, width: 1280, height: 720, flags: 0)]
        )
        #expect(await h.waitForSent(expected))

        let resized = Screen(id: 7, x: 0, y: 0, width: 1280, height: 720, flags: 0)
        h.feed(Server.update([Server.extendedDesktopSize(reason: 1, status: 0, w: 1280, h: 720, [resized])]))
        #expect(await h.next() == .resized(width: 1280, height: 720))
        let frame = try #require(await h.nextFrame())
        #expect(frame.width == 1280 && frame.height == 720)
        #expect(await h.waitForSent(ClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: 1280, height: 720)))
    }

    @Test func firstUpdateWithoutAnnouncementReportsNoResizeSupport() async throws {
        var h = try await Harness.connect(width: 4, height: 4)
        h.feed(Server.update([Server.rect(x: 0, y: 0, w: 1, h: 1, .raw, raw([1]))]))
        #expect(await h.next() == .desktopResizeSupport(false))
        h.feed(Server.update([Server.rect(x: 0, y: 0, w: 1, h: 1, .raw, raw([2]))]) + Server.bell())
        #expect(await h.next() == .bell)
    }

    @Test func lateAnnouncementEnablesResize() async throws {
        var h = try await Harness.connect(width: 800, height: 600)
        h.feed(Server.update([Server.rect(x: 0, y: 0, w: 1, h: 1, .raw, raw([1]))]))
        #expect(await h.next() == .desktopResizeSupport(false))
        let screen = Screen(id: 1, x: 0, y: 0, width: 800, height: 600, flags: 0)
        h.feed(Server.update([Server.extendedDesktopSize(reason: 0, status: 0, w: 800, h: 600, [screen])]))
        #expect(await h.next() == .desktopResizeSupport(true))
    }

    @Test func resizeFailureOtherThanProhibitedKeepsSupport() async throws {
        var h = try await Harness.connect(width: 800, height: 600)
        let screen = Screen(id: 1, x: 0, y: 0, width: 800, height: 600, flags: 0)
        h.feed(Server.update([Server.extendedDesktopSize(reason: 0, status: 0, w: 800, h: 600, [screen])]))
        #expect(await h.next() == .desktopResizeSupport(true))
        h.feed(Server.update([Server.extendedDesktopSize(reason: 1, status: 3, w: 800, h: 600, [screen])]) + Server.bell())
        #expect(await h.next() == .bell)
        await h.session.requestDesktopSize(width: 1024, height: 768)
        #expect(await h.waitForSent(ClientMessage.setDesktopSize(
            width: 1024, height: 768, screens: [Screen(id: 1, x: 0, y: 0, width: 1024, height: 768, flags: 0)]
        )))
    }

    @Test func multiScreenLayoutIsNotAutoResized() async throws {
        var h = try await Harness.connect(width: 1600, height: 600)
        let screens = [
            Screen(id: 1, x: 0, y: 0, width: 800, height: 600, flags: 0),
            Screen(id: 2, x: 800, y: 0, width: 800, height: 600, flags: 0),
        ]
        h.feed(Server.update([Server.extendedDesktopSize(reason: 0, status: 0, w: 1600, h: 600, screens)]))
        #expect(await h.next() == .desktopResizeSupport(true))
        await h.session.requestDesktopSize(width: 1024, height: 768)
        await h.settle()
        #expect(!h.sentDesktopSize)
    }

    @Test func unknownEncodingDisconnects() async throws {
        var h = try await Harness.connect()
        var wr = ByteWriter()
        wr.u8(0); wr.padding(1); wr.u16(1)
        wr.u16(0); wr.u16(0); wr.u16(1); wr.u16(1); wr.s32(7)
        h.feed(wr.data)
        guard case .disconnected(let error) = await h.next() else { Issue.record("expected disconnect"); return }
        #expect(error as? SessionError == .unknownEncoding(7))
    }

    @Test func oversizedCutTextDisconnects() async throws {
        var h = try await Harness.connect()
        h.feed(Data([3, 0, 0, 0]) + u32(0x7FFF_FFFF))
        guard case .disconnected(let error) = await h.next() else { Issue.record("expected disconnect"); return }
        guard case .malformed? = error as? SessionError else { Issue.record("expected malformed, got \(String(describing: error))"); return }
    }

    @Test func emptyCursorHidesIt() async throws {
        var h = try await Harness.connect()
        h.feed(Server.update([Server.rect(x: 0, y: 0, w: 0, h: 0, .cursor, Data())]))
        guard case .cursor(let shape) = await h.next() else { Issue.record("expected cursor"); return }
        #expect(shape.image == nil)
    }

    @Test func sendClipboardBeforeConnectIsRejected() async {
        let session = RFBSession(transport: ScriptedTransport())
        #expect(await session.sendClipboard("x") == false)
    }

    @Test func prohibitedResizeDisablesSupport() async throws {
        var h = try await Harness.connect(width: 800, height: 600)
        let screen = Screen(id: 1, x: 0, y: 0, width: 800, height: 600, flags: 0)
        h.feed(Server.update([Server.extendedDesktopSize(reason: 0, status: 0, w: 800, h: 600, [screen])]))
        #expect(await h.next() == .desktopResizeSupport(true))
        h.feed(Server.update([Server.extendedDesktopSize(reason: 1, status: 1, w: 800, h: 600, [screen])]))
        #expect(await h.next() == .desktopResizeSupport(false))

        await h.session.requestDesktopSize(width: 1024, height: 768)
        await h.settle()
        #expect(!h.sentDesktopSize)
    }

    @Test func requestDesktopSizeIgnoredWithoutAnnouncement() async throws {
        let h = try await Harness.connect(width: 800, height: 600)
        await h.session.requestDesktopSize(width: 1024, height: 768)
        await h.settle()
        #expect(!h.sentDesktopSize)
    }

    @Test func desktopSizePseudoEncodingResizes() async throws {
        var h = try await Harness.connect(width: 100, height: 100)
        h.feed(Server.update([Server.rect(x: 0, y: 0, w: 200, h: 150, .desktopSize, Data())]))
        #expect(await h.next() == .resized(width: 200, height: 150))
        let frame = try #require(await h.nextFrame())
        #expect(frame.width == 200 && frame.height == 150)
    }

    @Test func cursorShape() async throws {
        var h = try await Harness.connect()
        // 2×1 cursor, hotspot (1, 0): left pixel opaque red, right pixel transparent.
        h.feed(Server.update([Server.rect(x: 1, y: 0, w: 2, h: 1, .cursor, raw([0xFF0000, 0x00FF00]) + Data([0b1000_0000]))]))
        guard case .cursor(let shape) = await h.next() else { Issue.record("expected cursor"); return }
        let image = try #require(shape.image)
        #expect(image.width == 2 && image.height == 1)
        #expect(shape.hotspot == CGPoint(x: 1, y: 0))
    }

    @Test func lastRectEndsUpdateEarly() async throws {
        var h = try await Harness.connect(width: 2, height: 2)
        h.feed(Server.update(count: 0xFFFF, [
            Server.rect(x: 0, y: 0, w: 1, h: 1, .raw, raw([0xABCDEF])),
            Server.rect(x: 0, y: 0, w: 0, h: 0, .lastRect, Data()),
        ]) + Server.bell())
        let frame = try #require(await h.nextFrame())
        #expect(rgb(frame, 0, 0) == 0xABCDEF)
        #expect(await h.next() == .desktopResizeSupport(false))
        #expect(await h.next() == .bell)
    }

    @Test func legacyClipboardBothWays() async throws {
        var h = try await Harness.connect()
        h.feed(Server.cutText(Data([0x68, 0xE9])))
        #expect(await h.next() == .clipboard("hé"))
        await h.session.sendClipboard("a€")
        #expect(await h.waitForSent(ClientMessage.clientCutText(Data("a?".utf8))))
    }

    @Test func extendedClipboardFlow() async throws {
        var h = try await Harness.connect()
        let serverCaps: ExtendedClipboard.Flags = [.caps, .request, .peek, .notify, .provide, .text]
        h.feed(Server.extendedCutText(.caps(serverCaps, maxSizes: [1 << 20])))
        #expect(await h.waitForSent(ClientMessage.extendedClientCutText(ExtendedClipboard.encode(ExtendedClipboard.clientCaps))))

        // Remote → local: notify → we request → server provides.
        h.feed(Server.extendedCutText(.notify(.text)))
        #expect(await h.waitForSent(ClientMessage.extendedClientCutText(ExtendedClipboard.encode(.request(.text)))))
        h.feed(Server.extendedCutText(.provide(text: "日本 ✓")))
        #expect(await h.next() == .clipboard("日本 ✓"))

        // Local → remote: we notify → server requests → we provide.
        await h.session.sendClipboard("héllo 🙂")
        #expect(await h.waitForSent(ClientMessage.extendedClientCutText(ExtendedClipboard.encode(.notify(.text)))))
        h.feed(Server.extendedCutText(.request(.text)))
        #expect(await h.waitForSent(ClientMessage.extendedClientCutText(ExtendedClipboard.encode(.provide(text: "héllo 🙂")))))
    }

    @Test func peekIsAnsweredWithNotify() async throws {
        let h = try await Harness.connect()
        h.feed(Server.extendedCutText(.caps([.caps, .request, .peek, .notify, .provide, .text], maxSizes: [1 << 20])))
        h.feed(Server.extendedCutText(.peek))
        #expect(await h.waitForSent(ClientMessage.extendedClientCutText(ExtendedClipboard.encode(.notify([])))))
        await h.session.sendClipboard("x")
        h.feed(Server.extendedCutText(.peek))
        let notifyText = ClientMessage.extendedClientCutText(ExtendedClipboard.encode(.notify(.text)))
        for _ in 0..<200 where h.transport.sent.filter({ $0 == notifyText }).count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(h.transport.sent.filter { $0 == notifyText }.count == 2)
    }

    @Test func notifyIsIgnoredWhenServerCannotBeAsked() async throws {
        var h = try await Harness.connect()
        h.feed(Server.extendedCutText(.caps([.caps, .notify, .provide, .text], maxSizes: [1 << 20])))
        h.feed(Server.extendedCutText(.notify(.text)) + Server.bell())
        #expect(await h.next() == .bell)
        await h.settle()
        #expect(!h.transport.sent.contains(ClientMessage.extendedClientCutText(ExtendedClipboard.encode(.request(.text)))))
    }

    @Test func clipboardOfferedBeforeCapsIsReofferedAfterCaps() async throws {
        let h = try await Harness.connect()
        await h.session.sendClipboard("✓ ok")
        #expect(await h.waitForSent(ClientMessage.clientCutText(Data("? ok".utf8))))

        h.feed(Server.extendedCutText(.caps([.caps, .request, .notify, .provide, .text], maxSizes: [1 << 20])))
        #expect(await h.waitForSent(ClientMessage.extendedClientCutText(ExtendedClipboard.encode(.notify(.text)))))
        h.feed(Server.extendedCutText(.request(.text)))
        #expect(await h.waitForSent(ClientMessage.extendedClientCutText(ExtendedClipboard.encode(.provide(text: "✓ ok")))))
    }

    @Test func colourMapIsSkippedAndBellReported() async throws {
        var h = try await Harness.connect()
        h.feed(Data([1, 0]) + u16(0) + u16(2) + Data(count: 12) + Server.bell())
        #expect(await h.next() == .bell)
    }

    @Test func inputIsForwarded() async throws {
        let h = try await Harness.connect()
        h.session.sendKey(0x61, down: true)
        h.session.sendPointer(buttonMask: 1, x: 10, y: 20)
        #expect(Array(h.transport.sent.suffix(2)) == [
            ClientMessage.keyEvent(down: true, keysym: 0x61),
            ClientMessage.pointerEvent(buttonMask: 1, x: 10, y: 20),
        ])
    }

    @Test func disconnectsAtEndOfStream() async throws {
        var h = try await Harness.connect()
        h.transport.finish()
        guard case .disconnected(let error) = await h.next() else { Issue.record("expected disconnect"); return }
        #expect(error as? TransportError == .closed)
        #expect(await h.next() == nil)
    }

    @Test func unknownMessageDisconnects() async throws {
        var h = try await Harness.connect()
        h.feed(Data([99]))
        guard case .disconnected(let error) = await h.next() else { Issue.record("expected disconnect"); return }
        #expect(error as? SessionError == .unknownMessage(99))
    }

    @Test func handshakeFailureIsReported() async throws {
        let t = ScriptedTransport(Data("RFB 003.008\n".utf8) + Data([0]) + u32(4) + Data("nope".utf8))
        let session = RFBSession(transport: t)
        var events = session.events.makeAsyncIterator()
        Task { await session.run(password: { nil }) }
        guard case .disconnected(let error) = await events.next() else { Issue.record("expected disconnect"); return }
        #expect(error as? HandshakeError == .serverRefused("nope"))
    }
}

extension SessionEvent: Equatable {
    public static func == (a: SessionEvent, b: SessionEvent) -> Bool {
        switch (a, b) {
        case let (.connected(x), .connected(y)): x == y
        case let (.resized(w1, h1), .resized(w2, h2)): w1 == w2 && h1 == h2
        case let (.desktopResizeSupport(x), .desktopResizeSupport(y)): x == y
        case let (.clipboard(x), .clipboard(y)): x == y
        case (.bell, .bell): true
        default: false
        }
    }
}

private struct Harness {
    let transport: ScriptedTransport
    let session: RFBSession
    private var events: AsyncStream<SessionEvent>.Iterator
    private var frames: AsyncStream<CGImage>.Iterator

    static func connect(width: UInt16 = 64, height: UInt16 = 48) async throws -> Harness {
        var init_ = ByteWriter()
        init_.u16(width)
        init_.u16(height)
        PixelFormat.bgrx32.encode(into: &init_)
        let t = ScriptedTransport(Data("RFB 003.008\n".utf8) + Data([1, 1]) + u32(0) + init_.data + u32(0))
        let s = RFBSession(transport: t)
        var h = Harness(transport: t, session: s, events: s.events.makeAsyncIterator(), frames: s.frames.makeAsyncIterator())
        Task { await s.run(password: { nil }) }
        guard case .connected = await h.next() else { throw HarnessError.notConnected }
        return h
    }

    mutating func next() async -> SessionEvent? { await events.next() }
    mutating func nextFrame() async -> CGImage? { await frames.next() }
    func feed(_ data: Data) { transport.feed(data) }

    var sentDesktopSize: Bool { transport.sent.contains { $0.first == 251 } }

    func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

    func waitForSent(_ message: Data) async -> Bool {
        for _ in 0..<200 {
            if transport.sent.contains(message) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    enum HarnessError: Error { case notConnected }
}

private enum Server {
    enum Kind { case raw, copyRect, zrle, cursor, desktopSize, lastRect }

    static func update(count: UInt16? = nil, _ rects: [Data]) -> Data {
        Data([0, 0]) + u16(count ?? UInt16(rects.count)) + rects.reduce(Data(), +)
    }

    static func rect(x: UInt16, y: UInt16, w: UInt16, h: UInt16, _ kind: Kind, _ body: Data) -> Data {
        let encoding: Int32 = switch kind {
        case .raw: EncodingType.raw
        case .copyRect: EncodingType.copyRect
        case .zrle: EncodingType.zrle
        case .cursor: EncodingType.cursor
        case .desktopSize: EncodingType.desktopSize
        case .lastRect: EncodingType.lastRect
        }
        var wr = ByteWriter()
        wr.u16(x); wr.u16(y); wr.u16(w); wr.u16(h); wr.s32(encoding)
        return wr.data + body
    }

    static func extendedDesktopSize(reason: UInt16, status: UInt16, w: UInt16, h: UInt16, _ screens: [Screen]) -> Data {
        var wr = ByteWriter()
        wr.u16(reason); wr.u16(status); wr.u16(w); wr.u16(h); wr.s32(EncodingType.extendedDesktopSize)
        wr.u8(UInt8(screens.count)); wr.padding(3)
        for s in screens { s.encode(into: &wr) }
        return wr.data
    }

    static func cutText(_ latin1: Data) -> Data {
        Data([3, 0, 0, 0]) + u32(UInt32(latin1.count)) + latin1
    }

    static func extendedCutText(_ message: ExtendedClipboard.Message) -> Data {
        let payload = ExtendedClipboard.encode(message)
        var wr = ByteWriter()
        wr.u8(3); wr.padding(3); wr.s32(-Int32(payload.count))
        return wr.data + payload
    }

    static func bell() -> Data { Data([2]) }
}

private func u16(_ v: UInt16) -> Data {
    var w = ByteWriter()
    w.u16(v)
    return w.data
}

private func u32(_ v: UInt32) -> Data {
    var w = ByteWriter()
    w.u32(v)
    return w.data
}

/// Raw-encoding pixels (bgrx32, little-endian) from 0xRRGGBB values.
private func raw(_ pixels: [UInt32]) -> Data {
    Data(pixels.flatMap { [UInt8($0 & 0xFF), UInt8(($0 >> 8) & 0xFF), UInt8(($0 >> 16) & 0xFF), 0] })
}

private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> UInt32 {
    var pixel: UInt32 = 0
    let ctx = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return pixel & 0xFFFFFF
}

/// zlib stream as a ZRLE server emits it: header + sync-flushed data, never finished.
private func deflateSync(_ input: Data) -> Data {
    let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    stream.initialize(to: z_stream())
    defer { deflateEnd(stream); stream.deallocate() }
    deflateInit_(stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    var source = [UInt8](input)
    var output = [UInt8](repeating: 0, count: 1024)
    let produced = source.withUnsafeMutableBufferPointer { src in
        output.withUnsafeMutableBufferPointer { dst in
            stream.pointee.next_in = src.baseAddress
            stream.pointee.avail_in = uInt(src.count)
            stream.pointee.next_out = dst.baseAddress
            stream.pointee.avail_out = uInt(dst.count)
            deflate(stream, Z_SYNC_FLUSH)
            return dst.count - Int(stream.pointee.avail_out)
        }
    }
    return Data(output[..<produced])
}
