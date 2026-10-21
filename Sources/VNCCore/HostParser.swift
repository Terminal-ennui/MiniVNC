import Foundation

public struct HostAddress: Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// User-entered VNC addresses: `host`, `host:N` (N < 100 is a display number, port 5900+N; otherwise a
/// port), `host::port`, `[ipv6]` with the same suffixes, or a bare IPv6 address, optionally prefixed
/// with `vnc://`. A bare `name::digits` is always read as host::port, so IPv6 addresses such as
/// `fe80::1` must be bracketed.
public enum HostParser {
    public static let defaultPort: UInt16 = 5900
    /// After a single colon, numbers below this are display numbers; `format` uses `::` for ports below it.
    private static let displayLimit: UInt16 = 100

    public static func parse(_ input: String) -> HostAddress? {
        var s = Substring(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "@" }) else {
            return nil
        }
        if s.prefix(6).lowercased() == "vnc://" {
            s = s.dropFirst(6)
            if s.hasSuffix("/") { s = s.dropLast() }
        }

        let host: Substring, suffix: Substring
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            host = s[s.index(after: s.startIndex)..<close]
            suffix = s[s.index(after: close)...]
            guard isIPv6(host) else { return nil }
        } else if s.count(where: { $0 == ":" }) >= 2, !isNameColonColonDigits(s) {
            guard isIPv6(s) else { return nil }
            host = s
            suffix = ""
        } else {
            let colon = s.firstIndex(of: ":") ?? s.endIndex
            host = s[..<colon]
            suffix = s[colon...]
            guard isHostName(host) else { return nil }
        }
        guard let port = port(from: suffix) else { return nil }
        return HostAddress(host: String(host), port: port)
    }

    /// Inverse of `parse`: ports below `displayLimit` use `::` so they don't re-parse as display numbers.
    public static func format(_ address: HostAddress) -> String {
        let host = address.host.contains(":") ? "[\(address.host)]" : address.host
        // Always show the port, so what was typed (e.g. host:5900) is what the user sees again.
        return address.port >= displayLimit ? "\(host):\(address.port)" : "\(host)::\(address.port)"
    }

    private static func isNameColonColonDigits(_ s: Substring) -> Bool {
        guard let doubleColon = s.range(of: "::") else { return false }
        let name = s[..<doubleColon.lowerBound]
        return !name.isEmpty && !name.contains(":") && isDigits(s[doubleColon.upperBound...])
    }

    /// "" → default port, ":N" → display N (or port N from `displayLimit` up), "::N" → port N.
    private static func port(from suffix: Substring) -> UInt16? {
        if suffix.isEmpty { return defaultPort }
        let value: Int?
        if suffix.hasPrefix("::") {
            value = number(suffix.dropFirst(2))
        } else if suffix.hasPrefix(":") {
            value = number(suffix.dropFirst()).map { $0 < displayLimit ? Int(defaultPort) + $0 : $0 }
        } else {
            value = nil
        }
        guard let value, value > 0 else { return nil }
        return UInt16(exactly: value)
    }

    private static func number(_ s: Substring) -> Int? {
        isDigits(s) ? Int(s) : nil
    }

    private static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// An address `inet_pton` accepts, plus an optional non-empty `%zone`.
    private static func isIPv6(_ s: Substring) -> Bool {
        let parts = s.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts[0].contains("\0"), parts.count == 1 || isHostName(parts[1]) else { return false }
        var address = in6_addr()
        return inet_pton(AF_INET6, String(parts[0]), &address) == 1
    }

    private static func isHostName(_ s: Substring) -> Bool {
        !s.isEmpty && !s.contains { $0.isWhitespace || "/[]".contains($0) }
    }
}
