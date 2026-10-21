import Testing
@testable import VNCCore

struct HostParserTests {
    @Test(arguments: [
        ("host", "host", 5900),
        ("  host \n", "host", 5900),
        ("Mac.Example.COM", "Mac.Example.COM", 5900),
        ("example.com:0", "example.com", 5900),
        ("example.com:1", "example.com", 5901),
        ("example.com:05", "example.com", 5905),
        ("example.com:99", "example.com", 5999),
        ("example.com:100", "example.com", 100),
        ("example.com:5901", "example.com", 5901),
        ("example.com:65535", "example.com", 65535),
        ("192.168.1.10:5", "192.168.1.10", 5905),
        ("example.com::1", "example.com", 1),
        ("example.com::5900", "example.com", 5900),
        ("example.com::65535", "example.com", 65535),
        ("vnc://host", "host", 5900),
        ("VNC://host:2", "host", 5902),
        ("vnc://host/", "host", 5900),
        ("vnc://host::22/", "host", 22),
        ("[::1]", "::1", 5900),
        ("[::1]:1", "::1", 5901),
        ("[::1]:5902", "::1", 5902),
        ("[::1]::22", "::1", 22),
        ("[fe80::1%en0]:5901", "fe80::1%en0", 5901),
        ("vnc://[2001:db8::1]:5902/", "2001:db8::1", 5902),
        ("::1", "::1", 5900),
        ("2001:db8::abcd", "2001:db8::abcd", 5900),
        ("fe80::1:2", "fe80::1:2", 5900),
        ("::ffff:192.0.2.1", "::ffff:192.0.2.1", 5900),
        ("2001:db8:0:0:0:0:0:1", "2001:db8:0:0:0:0:0:1", 5900),
        // Ambiguous: `name::digits` is always host::port, so IPv6 like this must be bracketed.
        ("fe80::1", "fe80", 1),
    ] as [(String, String, UInt16)])
    func parsesValidInput(_ input: String, host: String, port: UInt16) {
        #expect(HostParser.parse(input) == HostAddress(host: host, port: port))
    }

    @Test(arguments: [
        "", "   ", "vnc://", "vnc:///", ":5901", ":1",
        "host:", "host:abc", "host:+5", "host:-1", "host: 5", "host:5x", "host:٣",
        "host:65536", "host:99999999999999999999999",
        "host::", "host::abc", "host::0", "host::65536",
        "host:1:2", "a:b:c:d:e:f:g:h", ":::", "1.2.3.4:5:6", "a::b::1", "::1\u{0}x", "[::1%]", "[a::b::1]:5901",
        "[::1", "::1]", "host]", "[::1]]", "[[::1]]", "[]", "[]:5901",
        "[::1]x", "[::1]:", "[::1]::", "[::1]:abc", "[::1]::0", "[::1]:65536", "[host]",
        "my host", "my host:1", "host/path", "vnc://host/path",
        "host\u{0}x", "a\u{7}b", "host\u{7F}:1", "[::1%en\u{0}]", "user@host", "vnc://user@host:5901",
    ])
    func rejectsInvalidInput(_ input: String) {
        #expect(HostParser.parse(input) == nil)
    }

    @Test func formatsAddresses() {
        #expect(HostParser.format(HostAddress(host: "host", port: 5900)) == "host:5900")
        #expect(HostParser.format(HostAddress(host: "host", port: 5901)) == "host:5901")
        #expect(HostParser.format(HostAddress(host: "host", port: 100)) == "host:100")
        #expect(HostParser.format(HostAddress(host: "host", port: 99)) == "host::99")
        #expect(HostParser.format(HostAddress(host: "host", port: 1)) == "host::1")
        #expect(HostParser.format(HostAddress(host: "::1", port: 5900)) == "[::1]:5900")
        #expect(HostParser.format(HostAddress(host: "::1", port: 5901)) == "[::1]:5901")
        #expect(HostParser.format(HostAddress(host: "::1", port: 22)) == "[::1]::22")
    }

    @Test(arguments: ["localhost", "192.168.1.10", "mac.example.com", "fe80", "::1", "2001:db8::1", "fe80::1%en0"],
          [1, 99, 100, 5900, 5901, 65535] as [UInt16])
    func roundTrips(host: String, port: UInt16) {
        let address = HostAddress(host: host, port: port)
        #expect(HostParser.parse(HostParser.format(address)) == address)
    }
}
