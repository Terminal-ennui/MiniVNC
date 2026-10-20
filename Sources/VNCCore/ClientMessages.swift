import Foundation

public struct PixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColor: Bool
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    public init(
        bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool, trueColor: Bool,
        redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
        redShift: UInt8, greenShift: UInt8, blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// 32 bpp, depth 24, little-endian, true colour, max 255, shifts R16 G8 B0 → memory bytes B,G,R,X.
    public static let bgrx32 = PixelFormat(
        bitsPerPixel: 32, depth: 24, bigEndian: false, trueColor: true,
        redMax: 255, greenMax: 255, blueMax: 255,
        redShift: 16, greenShift: 8, blueShift: 0)

    public func encode(into w: inout ByteWriter) {
        w.u8(bitsPerPixel)
        w.u8(depth)
        w.u8(bigEndian ? 1 : 0)
        w.u8(trueColor ? 1 : 0)
        w.u16(redMax)
        w.u16(greenMax)
        w.u16(blueMax)
        w.u8(redShift)
        w.u8(greenShift)
        w.u8(blueShift)
        w.padding(3)
    }

    public init(from r: inout ByteReader) throws {
        bitsPerPixel = try r.u8()
        depth = try r.u8()
        bigEndian = try r.u8() != 0
        trueColor = try r.u8() != 0
        redMax = try r.u16()
        greenMax = try r.u16()
        blueMax = try r.u16()
        redShift = try r.u8()
        greenShift = try r.u8()
        blueShift = try r.u8()
        try r.skip(3)
    }
}

public struct Screen: Equatable, Sendable {
    public var id: UInt32
    public var x: UInt16
    public var y: UInt16
    public var width: UInt16
    public var height: UInt16
    public var flags: UInt32

    public init(id: UInt32, x: UInt16, y: UInt16, width: UInt16, height: UInt16, flags: UInt32) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.flags = flags
    }

    public func encode(into w: inout ByteWriter) {
        w.u32(id)
        w.u16(x)
        w.u16(y)
        w.u16(width)
        w.u16(height)
        w.u32(flags)
    }

    public init(from r: inout ByteReader) throws {
        id = try r.u32()
        x = try r.u16()
        y = try r.u16()
        width = try r.u16()
        height = try r.u16()
        flags = try r.u32()
    }
}

public enum EncodingType {
    public static let raw: Int32 = 0
    public static let copyRect: Int32 = 1
    public static let zrle: Int32 = 16
    public static let cursor: Int32 = -239
    public static let desktopSize: Int32 = -223
    public static let lastRect: Int32 = -224
    public static let extendedDesktopSize: Int32 = -308
    public static let extendedClipboard = Int32(bitPattern: 0xC0A1_E5CE)
}

/// Client-to-server message encoders. Lists and payloads longer than their wire count field allows are truncated.
public enum ClientMessage {
    public static func setPixelFormat(_ format: PixelFormat) -> Data {
        var w = ByteWriter()
        w.u8(0)
        w.padding(3)
        format.encode(into: &w)
        return w.data
    }

    public static func setEncodings(_ encodings: [Int32]) -> Data {
        let list = encodings.prefix(Int(UInt16.max))
        var w = ByteWriter()
        w.u8(2)
        w.padding(1)
        w.u16(UInt16(list.count))
        list.forEach { w.s32($0) }
        return w.data
    }

    public static func framebufferUpdateRequest(
        incremental: Bool, x: UInt16, y: UInt16, width: UInt16, height: UInt16
    ) -> Data {
        var w = ByteWriter()
        w.u8(3)
        w.u8(incremental ? 1 : 0)
        w.u16(x)
        w.u16(y)
        w.u16(width)
        w.u16(height)
        return w.data
    }

    public static func keyEvent(down: Bool, keysym: UInt32) -> Data {
        var w = ByteWriter()
        w.u8(4)
        w.u8(down ? 1 : 0)
        w.padding(2)
        w.u32(keysym)
        return w.data
    }

    public static func pointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) -> Data {
        var w = ByteWriter()
        w.u8(5)
        w.u8(buttonMask)
        w.u16(x)
        w.u16(y)
        return w.data
    }

    public static func clientCutText(_ latin1: Data) -> Data {
        let text = latin1.prefix(Int(UInt32.max))
        var w = ByteWriter()
        w.u8(6)
        w.padding(3)
        w.u32(UInt32(text.count))
        w.bytes(text)
        return w.data
    }

    /// `payload` starts with the 4-byte flags word of the Extended Clipboard pseudo-encoding.
    public static func extendedClientCutText(_ payload: Data) -> Data {
        precondition(payload.count >= 4, "extended clipboard payload needs a flags word")
        let body = payload.prefix(Int(Int32.max))
        var w = ByteWriter()
        w.u8(6)
        w.padding(3)
        w.s32(-Int32(body.count))
        w.bytes(body)
        return w.data
    }

    public static func setDesktopSize(width: UInt16, height: UInt16, screens: [Screen]) -> Data {
        let list = screens.prefix(Int(UInt8.max))
        var w = ByteWriter()
        w.u8(251)
        w.padding(1)
        w.u16(width)
        w.u16(height)
        w.u8(UInt8(list.count))
        w.padding(1)
        list.forEach { $0.encode(into: &w) }
        return w.data
    }
}
