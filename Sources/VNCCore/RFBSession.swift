import CoreGraphics
import Foundation
import Synchronization

public struct CursorShape: Sendable {
    /// nil hides the cursor.
    public let image: CGImage?
    public let hotspot: CGPoint
}

public enum SessionEvent: Sendable {
    case connected(ServerInit)
    case resized(width: Int, height: Int)
    /// true when the server announces ExtendedDesktopSize; false after a first update without it,
    /// or once the server prohibits our resize requests.
    case desktopResizeSupport(Bool)
    case cursor(CursorShape)
    case clipboard(String)
    case bell
    case disconnected(Error?)
}

public enum SessionError: Error, Equatable {
    case unknownMessage(UInt8)
    case unknownEncoding(Int32)
    case malformed(String)
}

/// One RFB connection: handshake, then the server message loop. Input may be sent from any thread.
public actor RFBSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    /// The framebuffer after each update; undelivered frames are replaced by newer ones.
    public nonisolated let frames: AsyncStream<CGImage>

    static let encodings: [Int32] = [
        EncodingType.zrle, EncodingType.copyRect, EncodingType.raw,
        EncodingType.cursor, EncodingType.extendedDesktopSize, EncodingType.desktopSize,
        EncodingType.lastRect, EncodingType.extendedClipboard,
    ]
    private static let maxPayload = 8192 * 8192 * 4

    private let transport: Transport
    private let eventSink: AsyncStream<SessionEvent>.Continuation
    private let frameSink: AsyncStream<CGImage>.Continuation
    private nonisolated let isReady = Atomic<Bool>(false)

    private var framebuffer = Framebuffer(width: 1, height: 1)
    private let zrle = ZRLEDecoder()
    private var screens: [Screen] = []
    private var resizeSupported = false
    private var resizeProhibited = false
    private var sawFirstUpdate = false
    private var serverClipboard: ExtendedClipboard.Flags?
    private var localClipboard: String?

    public init(transport: Transport) {
        self.transport = transport
        (events, eventSink) = AsyncStream.makeStream()
        (frames, frameSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Connects and runs until the connection ends, then emits `.disconnected` and finishes both streams.
    public func run(password: @escaping @Sendable () async -> String?) async {
        do {
            try await transport.open()
            let info = try await Handshake.run(on: transport, password: password)
            framebuffer = Framebuffer(width: Int(info.width), height: Int(info.height))
            transport.send(ClientMessage.setPixelFormat(.bgrx32))
            transport.send(ClientMessage.setEncodings(Self.encodings))
            requestUpdate(incremental: false)
            isReady.store(true, ordering: .releasing)
            Log.session.notice("connected to “\(info.name, privacy: .public)”, \(info.width)×\(info.height)")
            eventSink.yield(.connected(info))
            while true { try await readMessage() }
        } catch {
            Log.session.notice("session ended: \(String(describing: error), privacy: .public)")
            isReady.store(false, ordering: .releasing)
            transport.close()
            eventSink.yield(.disconnected(error))
        }
        eventSink.finish()
        frameSink.finish()
    }

    public nonisolated func sendKey(_ keysym: UInt32, down: Bool) {
        guard isReady.load(ordering: .acquiring) else { return }
        transport.send(ClientMessage.keyEvent(down: down, keysym: keysym))
    }

    public nonisolated func sendPointer(buttonMask: UInt8, x: UInt16, y: UInt16) {
        guard isReady.load(ordering: .acquiring) else { return }
        transport.send(ClientMessage.pointerEvent(buttonMask: buttonMask, x: x, y: y))
    }

    public nonisolated func disconnect() {
        transport.close()
    }

    /// Asks the server to change its desktop size. Ignored unless the server supports it, and for
    /// multi-monitor remotes, whose layout we'd otherwise collapse to one screen.
    public func requestDesktopSize(width: UInt16, height: UInt16) {
        guard resizeSupported, screens.count <= 1,
              Int(width) != framebuffer.width || Int(height) != framebuffer.height else { return }
        let base = screens.first
        let screen = Screen(id: base?.id ?? 0, x: 0, y: 0, width: width, height: height, flags: base?.flags ?? 0)
        transport.send(ClientMessage.setDesktopSize(width: width, height: height, screens: [screen]))
    }

    /// Offers local clipboard text to the server. Returns false if not connected yet.
    @discardableResult
    public func sendClipboard(_ text: String) -> Bool {
        guard isReady.load(ordering: .acquiring) else { return false }
        localClipboard = text
        if serverClipboard == nil {
            transport.send(ClientMessage.clientCutText(Latin1.encode(text)))
        } else {
            offerClipboard()
        }
        return true
    }

    // MARK: - Server messages

    private func readMessage() async throws {
        switch try await read(1)[0] {
        case 0:
            try await readFramebufferUpdate()
        case 1:
            var r = ByteReader(try await read(5))
            try r.skip(3)
            _ = try await read(Int(try r.u16()) * 6)
        case 2:
            eventSink.yield(.bell)
        case 3:
            try await readServerCutText()
        case let type:
            throw SessionError.unknownMessage(type)
        }
    }

    private func readFramebufferUpdate() async throws {
        var header = ByteReader(try await read(3))
        try header.skip(1)
        let count = try header.u16()
        var resized = false

        rects: for _ in 0..<count {
            var r = ByteReader(try await read(12))
            let x = Int(try r.u16()), y = Int(try r.u16())
            let w = Int(try r.u16()), h = Int(try r.u16())
            let encoding = try r.s32()

            switch encoding {
            case EncodingType.raw:
                let pixels = try await read(w * h * 4)
                pixels.withUnsafeBytes { framebuffer.blit(x: x, y: y, width: w, height: h, pixels: $0) }
            case EncodingType.copyRect:
                var src = ByteReader(try await read(4))
                framebuffer.copyRect(srcX: Int(try src.u16()), srcY: Int(try src.u16()), x: x, y: y, width: w, height: h)
            case EncodingType.zrle:
                var length = ByteReader(try await read(4))
                let compressed = try await read(Int(try length.u32()))
                try zrle.decode(compressed, x: x, y: y, width: w, height: h, into: framebuffer)
            case EncodingType.cursor:
                let pixels = try await read(w * h * 4)
                let mask = try await read((w + 7) / 8 * h)
                let image = Self.cursorImage(width: w, height: h, pixels: pixels, mask: mask)
                eventSink.yield(.cursor(CursorShape(image: image, hotspot: CGPoint(x: x, y: y))))
            case EncodingType.desktopSize:
                resized = resize(width: w, height: h) || resized
            case EncodingType.extendedDesktopSize:
                var r = ByteReader(try await read(4))
                let screenCount = Int(try r.u8())
                var layout = ByteReader(try await read(screenCount * 16))
                let newScreens = try (0..<screenCount).map { _ in try Screen(from: &layout) }
                // For this rect, x carries the reason (1 = our request) and y the status (0 = success).
                resized = handleExtendedDesktopSize(reason: x, status: y, width: w, height: h, screens: newScreens) || resized
            case EncodingType.lastRect:
                break rects
            default:
                throw SessionError.unknownEncoding(encoding)
            }
        }

        if !sawFirstUpdate {
            sawFirstUpdate = true
            // Servers that support ExtendedDesktopSize announce it in their first update.
            if !resizeSupported { eventSink.yield(.desktopResizeSupport(false)) }
        }
        if let image = framebuffer.makeImage() { frameSink.yield(image) }
        requestUpdate(incremental: !resized)
    }

    private func handleExtendedDesktopSize(reason: Int, status: Int, width: Int, height: Int, screens: [Screen]) -> Bool {
        if !resizeSupported, !resizeProhibited {
            resizeSupported = true
            eventSink.yield(.desktopResizeSupport(true))
        }
        guard status == 0 else {
            if reason == 1, status == 1, resizeSupported {
                resizeSupported = false
                resizeProhibited = true
                eventSink.yield(.desktopResizeSupport(false))
            }
            return false
        }
        self.screens = screens
        return resize(width: width, height: height)
    }

    private func resize(width: Int, height: Int) -> Bool {
        guard width != framebuffer.width || height != framebuffer.height else { return false }
        framebuffer.resize(width: width, height: height)
        eventSink.yield(.resized(width: framebuffer.width, height: framebuffer.height))
        return true
    }

    private func readServerCutText() async throws {
        var r = ByteReader(try await read(7))
        try r.skip(3)
        let length = try r.s32()
        let data = try await read(Int(length.magnitude))
        if length >= 0 {
            eventSink.yield(.clipboard(Latin1.decode(data)))
        } else if let message = try? ExtendedClipboard.decode(data) {
            handleExtendedClipboard(message)
        }
    }

    private func handleExtendedClipboard(_ message: ExtendedClipboard.Message) {
        switch message {
        case .caps(let flags, _):
            serverClipboard = flags
            sendExtended(ExtendedClipboard.clientCaps)
            // Text offered before caps went out as lossy Latin-1; offer it again as UTF-8.
            offerClipboard()
        case .notify(let formats):
            if formats.contains(.text), serverClipboard?.contains(.request) == true {
                sendExtended(.request(.text))
            }
        case .request(let formats):
            if formats.contains(.text), let text = localClipboard {
                sendExtended(.provide(text: text))
            }
        case .peek:
            sendExtended(.notify(localClipboard == nil ? [] : .text))
        case .provide(let text):
            if let text { eventSink.yield(.clipboard(text)) }
        }
    }

    // MARK: - Helpers

    private func offerClipboard() {
        guard let text = localClipboard, let caps = serverClipboard else { return }
        if caps.contains(.notify) {
            sendExtended(.notify(.text))
        } else if caps.contains(.provide) {
            sendExtended(.provide(text: text))
        }
    }

    private func sendExtended(_ message: ExtendedClipboard.Message) {
        transport.send(ClientMessage.extendedClientCutText(ExtendedClipboard.encode(message)))
    }

    private func requestUpdate(incremental: Bool) {
        transport.send(ClientMessage.framebufferUpdateRequest(
            incremental: incremental, x: 0, y: 0,
            width: UInt16(clamping: framebuffer.width), height: UInt16(clamping: framebuffer.height)
        ))
    }

    private func read(_ count: Int) async throws -> Data {
        guard count <= Self.maxPayload else { throw SessionError.malformed("payload of \(count) bytes") }
        return try await transport.read(exactly: count)
    }

    /// Cursor pseudo-encoding: bgrx32 pixels plus a 1-bit opacity mask (rows padded to bytes, MSB first).
    private static func cursorImage(width: Int, height: Int, pixels: Data, mask: Data) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let src = [UInt8](pixels), bits = [UInt8](mask)
        let maskStride = (width + 7) / 8
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width where bits[y * maskStride + x / 8] & (0x80 >> (x % 8)) != 0 {
                let i = (y * width + x) * 4
                bgra[i] = src[i]
                bgra[i + 1] = src[i + 1]
                bgra[i + 2] = src[i + 2]
                bgra[i + 3] = 0xFF
            }
        }
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
