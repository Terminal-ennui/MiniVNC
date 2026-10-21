import Foundation

public struct ServerInit: Equatable, Sendable {
    public var width: UInt16
    public var height: UInt16
    public var pixelFormat: PixelFormat
    public var name: String

    public init(width: UInt16, height: UInt16, pixelFormat: PixelFormat, name: String) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.name = name
    }
}

public enum HandshakeError: Error, Equatable {
    case unsupportedVersion(String)
    case serverRefused(String)
    case noSupportedSecurity([UInt8])
    case authenticationFailed(String)
    case cancelled
    case malformed(String)
    case timedOut
}

/// RFB 3.3/3.7/3.8 version, security (None or VNC password) and initialisation phases.
public enum Handshake {
    private static let securityNone: UInt8 = 1
    private static let securityVNC: UInt8 = 2

    /// `password` is asked only when the server requires VNC authentication; returning nil cancels.
    /// `timeout` bounds the wait for the server's greeting (a port that accepts but never speaks RFB).
    public static func run(
        on transport: Transport,
        password: @Sendable () async -> String?,
        shared: Bool = true,
        timeout: Duration = .seconds(15)
    ) async throws -> ServerInit {
        let minor = try await negotiateVersion(transport, timeout: timeout)
        let security = try await negotiateSecurity(transport, minor: minor)

        if security == securityVNC {
            let challenge = try await transport.read(exactly: 16)
            guard let secret = await password() else { throw HandshakeError.cancelled }
            transport.send(VNCAuth.response(challenge: challenge, password: secret))
        }
        if security == securityVNC || minor >= 8 {
            try await readSecurityResult(transport, minor: minor)
        }

        transport.send(Data([shared ? 1 : 0]))
        return try await readServerInit(transport)
    }

    private static func negotiateVersion(_ transport: Transport, timeout: Duration) async throws -> Int {
        let greeting = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await transport.read(exactly: 12) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let greeting = first else {
                transport.close() // unblocks the pending read so the group can finish
                throw HandshakeError.timedOut
            }
            return greeting
        }
        let text = String(decoding: greeting, as: UTF8.self)
        let parts = text.dropFirst(4).dropLast().split(separator: ".")
        guard text.hasPrefix("RFB "), text.hasSuffix("\n"), parts.count == 2,
              Int(parts[0]) == 3, let serverMinor = Int(parts[1])
        else { throw HandshakeError.unsupportedVersion(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let minor = serverMinor >= 8 ? 8 : (serverMinor == 7 ? 7 : 3)
        Log.session.notice("server speaks RFB 3.\(serverMinor), using 3.\(minor)")
        transport.send(Data("RFB 003.00\(minor)\n".utf8))
        return minor
    }

    private static func negotiateSecurity(_ transport: Transport, minor: Int) async throws -> UInt8 {
        if minor == 3 {
            let type = try await readU32(transport)
            switch type {
            case 0: throw HandshakeError.serverRefused(try await readString(transport))
            case UInt32(securityNone), UInt32(securityVNC): return UInt8(type)
            default: throw HandshakeError.noSupportedSecurity([UInt8(truncatingIfNeeded: type)])
            }
        }

        let count = try await transport.read(exactly: 1)[0]
        if count == 0 { throw HandshakeError.serverRefused(try await readString(transport)) }
        let offered = [UInt8](try await transport.read(exactly: Int(count)))
        guard let chosen = [securityNone, securityVNC].first(where: offered.contains) else {
            Log.session.error("no supported security type among \(offered, privacy: .public)")
            throw HandshakeError.noSupportedSecurity(offered)
        }
        Log.session.notice("security types \(offered, privacy: .public), using \(chosen == securityVNC ? "VNC password" : "none", privacy: .public)")
        transport.send(Data([chosen]))
        return chosen
    }

    private static func readSecurityResult(_ transport: Transport, minor: Int) async throws {
        guard try await readU32(transport) != 0 else {
            Log.session.notice("authentication accepted")
            return
        }
        Log.session.error("authentication rejected")
        let reason = minor >= 8 ? try? await readString(transport) : nil
        throw HandshakeError.authenticationFailed(reason ?? "Authentication failed")
    }

    private static func readServerInit(_ transport: Transport) async throws -> ServerInit {
        var reader = ByteReader(try await transport.read(exactly: 20))
        let width = try reader.u16()
        let height = try reader.u16()
        let format = try PixelFormat(from: &reader)
        return ServerInit(width: width, height: height, pixelFormat: format, name: try await readString(transport))
    }

    private static func readU32(_ transport: Transport) async throws -> UInt32 {
        var reader = ByteReader(try await transport.read(exactly: 4))
        return try reader.u32()
    }

    /// u32 length + text; servers send UTF-8 or Latin-1. Oversized lengths are rejected rather than allocated.
    static func readString(_ transport: Transport) async throws -> String {
        let length = Int(try await readU32(transport))
        guard length <= 1 << 20 else { throw HandshakeError.malformed("string of \(length) bytes") }
        let bytes = try await transport.read(exactly: length)
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }
}
