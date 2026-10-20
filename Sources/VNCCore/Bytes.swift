import Foundation

public enum ByteError: Error, Equatable {
    case underflow(needed: Int, available: Int)
}

/// Sequential big-endian reader over an in-memory buffer (RFB is network byte order).
public struct ByteReader {
    private let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { remaining == 0 }

    public mutating func u8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    public mutating func u32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    public mutating func s32() throws -> Int32 {
        Int32(bitPattern: try u32())
    }

    public mutating func bytes(_ count: Int) throws -> Data {
        try require(count)
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    public mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }

    private func require(_ count: Int) throws {
        guard count >= 0, count <= remaining else {
            throw ByteError.underflow(needed: count, available: remaining)
        }
    }
}

/// Big-endian message builder.
public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    public mutating func u16(_ value: UInt16) {
        data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    public mutating func u32(_ value: UInt32) {
        data.append(contentsOf: [
            UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }

    public mutating func s32(_ value: Int32) {
        u32(UInt32(bitPattern: value))
    }

    public mutating func bytes(_ value: Data) {
        data.append(value)
    }

    public mutating func padding(_ count: Int) {
        data.append(contentsOf: [UInt8](repeating: 0, count: count))
    }
}
